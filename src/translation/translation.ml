(* Translation of SL formulae to SMT
 *
 * Author: Tomas Dacik (xdacik00@fit.vutbr.cz), 2021 *)

open Z3
open Batteries

module Array = Z3Array
module Solver = Z3.Solver

open Results
open Context
open Quantifiers
open Quantifiers.Quantifier
open StackHeapModel
open Translation_sig

type result =
  | Sat of StackHeapModel.t * Model.model * Results.t
  | Unsat of Results.t * Expr.expr list
  | Unknown of Results.t * string

module Make (Encoding : ENCODING) = struct

  open Encoding

  (** Initialization of Z3 context and translation context *)
  let init phi info =
    let solver = Z3.mk_context [] in
    let locs_card = info.heap_bound + 1 in (* one for nil *)
    let locs_sort = Locations.mk_sort_s solver "Loc" locs_card in
    let locs = Locations.enumeration locs_sort in
    let fp_sort = Set.mk_sort solver locs_sort in
    let global_fp = Set.mk_const_s solver "global fp" locs_sort in
    let heap = Array.mk_const_s solver "heap" locs_sort locs_sort in
    Context.init info solver locs_sort locs fp_sort global_fp heap

  let init_solver ctx =
    (*let params = Params.mk_params ctx in
    Params.add_bool params (Symbol.mk_string ctx "smt.ematching") false;
    Params.add_int  params (Symbol.mk_string ctx "smt.mbqi.max_iterations") 1000;

    Printf.printf "Params: %s\n" (Params.to_string params);*)
    let solver = Solver.mk_solver ctx None in(*
    Solver.set_parameters solver params;
    Printf.printf "Actual params: %s\n" (Params.ParamDescrs.to_string
                                         @@ Solver.get_param_descrs solver);
    Printf.printf "Solver: %s\n" (Solver.to_string solver);*)
    solver

  (* ==== Helper functions for constructing common terms ==== *)

  let mk_heap_succ (context : Context.t) x = Array.mk_select context.solver context.heap x

  let mk_is_heap_succ context x y =
    let select = mk_heap_succ context x in
    Boolean.mk_eq context.solver select y

  let mk_range context domain range =
    Locations.forall context
    (fun l ->
      let in_domain = Set.mk_mem context.solver l domain in
      let succ_in_range = Set.mk_mem context.solver (mk_heap_succ context l) range in
      Boolean.mk_iff context.solver in_domain succ_in_range
    )

  let mk_strongly_disjoint context footprint1 footprint2 =
    let range1 = Set.mk_fresh_const context.solver "range" context.locs_sort in
    let range2 = Set.mk_fresh_const context.solver "range" context.locs_sort in

    let ls1 = Set.mk_fresh_const context.solver "locs" context.locs_sort in
    let ls2 = Set.mk_fresh_const context.solver "locs" context.locs_sort in

    let is_range1 = mk_range context footprint1 range1 in
    let is_range2 = mk_range context footprint2 range2 in

    let locs1 = Set.mk_union context.solver [footprint1; range1] in
    let locs2 = Set.mk_union context.solver [footprint2; range2] in

    let common_locs = Set.mk_inter context.solver [locs1; locs2] in
    let variables = Locations.vars_to_exprs context in
    let stack_image = Set.mk_enumeration context.solver context.locs_sort variables in
    let strongly_disjoint = Set.mk_subset context.solver common_locs stack_image in

    let axioms = Boolean.mk_and context.solver [is_range1; is_range2] in
    (axioms, strongly_disjoint)

  (** Create predicate \forall x \in fp. h1[x] = h2[x] *)
  let heaps_equal_on_footprint context h1 h2 fp =
    Locations.forall context
      (fun loc ->
        let in_fp = Set.mk_mem context.solver loc fp in
        let h1_select = Array.mk_select context.solver h1 loc in
        let h2_select = Array.mk_select context.solver h2 loc in
        let select_eq = Boolean.mk_eq context.solver h1_select h2_select in
        Boolean.mk_implies context.solver in_fp select_eq
      )

  let nonequalities (context : Context.t) =
    LengthGraph.fold_edges
      (fun x y acc ->
        if LengthGraph.must_neq context.length_graph x y then
          Boolean.mk_distinct context.solver
          [Locations.var_to_expr context x; Locations.var_to_expr context y] :: acc
        else acc
      ) context.length_graph []
    |> Boolean.mk_and context.solver

  let term_to_expr context x = match x with
    | SSL.Variable.Var _ | SSL.Variable.Nil -> Locations.var_to_expr context x
    | SSL.Variable.Term t -> LIA.translate context.solver t


  (* ==== Recursive translation of SL formulae ==== *)

  let rec translate context phi =
    let fp = Set.mk_const_s context.solver (formula_footprint context phi) context.locs_sort in
    match phi with
    | SSL.PointsTo (var1, var2) -> translate_pointsto context fp var1 var2
    | SSL.And (psi1, psi2) -> translate_and context fp psi1 psi2
    | SSL.Or (psi1, psi2) -> translate_or context fp psi1 psi2
    | SSL.Star (psi1, psi2) -> translate_star context fp psi1 psi2
    | SSL.Septraction (psi1, psi2) -> translate_septraction context fp phi psi1 psi2
    | SSL.Eq (var1, var2) -> translate_eq context fp var1 var2
    | SSL.Neq (var1, var2) -> translate_neq context fp var1 var2
    | SSL.LS (var1, var2) -> translate_ls context fp var1 var2
    | SSL.Not (psi) -> translate_not context fp psi
    | SSL.GuardedNeg (psi1, psi2) -> translate_guarded_neg context fp psi1 psi2

  and translate_pointsto context fp x y =
    let x = Locations.var_to_expr context x in
    let y = Locations.var_to_expr context y in

    let prefix = QuantifierPrefix.empty in
    let semantics = mk_is_heap_succ context x y in
    let axioms = Set.mk_eq_singleton context.solver fp x in
    (prefix, semantics, axioms, fp)

  and translate_ls context fp x y =
    let local_bound = Bounds.local_bound context x y in
    let x = Locations.var_to_expr context x in
    let y = Locations.var_to_expr context y in

    let prefix = QuantifierPrefix.empty in
    let semantics = ListEncoding.semantics context fp x y local_bound in
    let axioms = ListEncoding.axioms context fp x y local_bound in
    (prefix, semantics, axioms, fp)

  and translate_eq context fp x y =
    let x = term_to_expr context x in
    let y = term_to_expr context y in

    let prefix = QuantifierPrefix.empty in
    let semantics = Boolean.mk_eq context.solver x y in
    let axioms = Set.mk_eq_empty context.solver fp in
    (prefix, semantics, axioms, fp)

  and translate_neq context fp x y =
    let x = term_to_expr context x in
    let y = term_to_expr context y in

    let prefix = QuantifierPrefix.empty in
    let semantics = Boolean.mk_distinct context.solver [x; y] in
    let axioms = Set.mk_eq_empty context.solver fp in
    (prefix, semantics, axioms, fp)

  and translate_not context fp' phi =
    let prefix, psi, axioms, fp = translate {context with polarity = not context.polarity} phi in

    let prefix = QuantifierPrefix.concat [Exists fp'] (QuantifierPrefix.negate prefix) in
    let not_psi = Boolean.mk_not context.solver psi in
    let not_fp = Set.mk_distinct context.solver fp fp' in
    let semantics = Boolean.mk_or context.solver [not_psi; not_fp] in
    (prefix, semantics, axioms, fp')

  and translate_and context fp psi1 psi2 =
    let prefix1, phi1, axioms1, fp1 = translate context psi1 in
    let prefix2, phi2, axioms2, fp2 = translate context psi2 in

    let fp_equal = Set.mk_eq context.solver fp1 fp2 in
    let fp_def = Set.mk_eq context.solver fp fp1 in

    let prefix = QuantifierPrefix.concat prefix1 prefix2 in
    let semantics = Boolean.mk_and context.solver [phi1; phi2; fp_equal] in
    let axioms = Boolean.mk_and context.solver [axioms1; axioms2; fp_def] in
    (prefix, semantics, axioms, fp)

  and translate_or context fp psi1 psi2 =
    let prefix1, phi1, axioms1, fp1 = translate context psi1 in
    let prefix2, phi2, axioms2, fp2 = translate context psi2 in

    (* Semantics *)
    let case1_fp = Set.mk_eq context.solver fp fp1 in
    let case2_fp = Set.mk_eq context.solver fp fp2 in
    let case1 = Boolean.mk_and context.solver [phi1; case1_fp] in
    let case2 = Boolean.mk_and context.solver [phi2; case2_fp] in
    let semantics = Boolean.mk_or context.solver [case1; case2] in

    (* Axioms *)
    let fp_def = Boolean.mk_or context.solver [case1_fp; case2_fp] in
    let axioms = Boolean.mk_and context.solver [axioms1; axioms2; fp_def] in

    let prefix = QuantifierPrefix.concat prefix1 prefix2 in
    (prefix, semantics, axioms, fp)

and translate_star context fp psi1 psi2 =
  let prefix1, phi1, axioms1, fp1 = translate context psi1 in
  let prefix2, phi2, axioms2, fp2 = translate context psi2 in

  let separation = Set.mk_are_disjoint context.solver fp1 fp2 in
  let fp' = Set.mk_union context.solver [fp1; fp2] in

  let fp_def = Set.mk_eq context.solver fp fp' in

  let prefix = QuantifierPrefix.concat prefix1 prefix2 in
  let semantics = Boolean.mk_and context.solver [phi1; phi2; separation] in
  let axioms = Boolean.mk_and context.solver [axioms1; axioms2; fp_def] in

  (* Translation of negative formulas *)
  if SSL.has_unique_footprint psi1 && SSL.has_unique_footprint psi2 then
    (prefix, semantics, axioms, fp)
  else
    let prefix = QuantifierPrefix.concat [Exists fp1; Exists fp2] prefix in
    let axioms', disjoint = mk_strongly_disjoint context fp1 fp2 in
    let axioms = Boolean.mk_and context.solver [axioms; axioms'] in
    let semantics = Boolean.mk_and context.solver [semantics; disjoint] in
    (prefix, semantics, axioms, fp)

and translate_guarded_neg context fp psi1 psi2 =
  let prefix1, phi1, fp_defs1, fp1 = translate context psi1 in
  let prefix2, phi2, fp_defs2, fp2 = translate {context with polarity = not context.polarity} psi2 in

  let fp_def = Set.mk_eq context.solver fp fp1 in

  let prefix = QuantifierPrefix.concat prefix1 (QuantifierPrefix.negate prefix2) in
  let semantics_neg = Boolean.mk_or context.solver
    [Boolean.mk_not context.solver phi2;
     Boolean.mk_distinct context.solver [fp; fp2]
    ] in
  let semantics = Boolean.mk_and context.solver [phi1; semantics_neg] in
  let fp_defs = Boolean.mk_and context.solver [fp_defs1; fp_defs2; fp_def] in

  (prefix, semantics, fp_defs, fp)

and translate_septraction context fp phi psi1 psi2 =
  let h1_name = Context.formula_witness_heap context phi in
  let h1 = Array.mk_const_s context.solver h1_name context.locs_sort context.locs_sort in

  (* Positive septraction *)
  if SSL.has_unique_footprint psi1 && SSL.has_unique_footprint psi2 then
    let prefix1, phi1, axioms1, fp1 = translate {context with heap = h1} psi1 in
    let prefix2, phi2, axioms2, fp2 = translate {context with heap = h1} psi2 in

    (* \forall x \in fp. h(x) = h2(x) *)
    let eq_fp = heaps_equal_on_footprint context context.heap h1 fp in

    let prefix = QuantifierPrefix.concat prefix1 prefix2 in
    let fp_def = Set.mk_difference context.solver fp2 fp1 in
    let fp_def = Set.mk_eq context.solver fp fp_def in

    let subset = Set.mk_subset context.solver fp1 fp2 in
    let axioms = Boolean.mk_and context.solver [axioms1; axioms2; fp_def; eq_fp] in
    let semantics = Boolean.mk_and context.solver [phi1; phi2; subset] in

    (prefix, semantics, axioms, fp)

  (* Negative septraction, TODO: is eq_fp semantics or axiom? *)
  else
    let prefix1, phi1, axioms1, fp1 = translate {context with heap = h1} psi1 in
    let prefix2, phi2, axioms2, fp2 = translate {context with heap = h1} psi2 in

    (* Quantifiers *)
    let prefix = QuantifierPrefix.concat prefix1 prefix2 in
    let prefix = QuantifierPrefix.concat [Exists h1] prefix in

    let fp_def = Set.mk_difference context.solver fp2 fp1 in
    let fp_def = Set.mk_eq context.solver fp fp_def in
    let eq_fp = heaps_equal_on_footprint context context.heap h1 fp in
    let subset = Set.mk_subset context.solver fp1 fp2 in

    let ssl_axioms, ssl_disjoint = mk_strongly_disjoint context fp fp1 in
    let axioms = Boolean.mk_and context.solver [axioms1; axioms2; fp_def; eq_fp] in
    let semantics = Boolean.mk_and context.solver [phi1; phi2; subset] in
    (prefix, semantics, axioms, fp)

let translate_phi context phi =
  let prefix, phi', axioms, footprint = translate context phi in
  let global = Set.mk_eq context.solver footprint context.global_footprint in
  (*let locs_set = Set.mk_enumeration context.solver context.locs_sort context.locs in
  *)
  let nil = Expr.mk_const_s context.solver "nil" context.locs_sort in
  let nil_not_in_fp = Boolean.mk_not context.solver (Set.mk_mem context.solver nil context.global_footprint) in

  let heap_nil = Array.mk_select context.solver context.heap nil in
  let heap_intro = Boolean.mk_eq context.solver nil heap_nil in

  let diseqs = nonequalities context in
  let location_lemmas = Locations.location_lemmas context in

  let body = Boolean.mk_and context.solver
              [phi'; axioms; global; heap_intro; nil_not_in_fp; location_lemmas]
  in

  let prefix = QuantifierPrefix.drop_implicit prefix in
  Printf.printf "%s\n" (QuantifierPrefix.show prefix);
  QuantifierPrefix.apply context body prefix

  (* ==== Translation of SMT model to stack-heap model ==== *)

  let translate_loc expr =
    let name = Expr.to_string expr in
    try int_of_string @@ List.nth (String.split_on_char '|' name) 1
    with _ -> failwith ("Cannot convert numeral " ^ name)

  let nil_interp context model =
    let e = Expr.mk_const_s context.solver (SSL.Variable.show Nil) context.locs_sort in
    match Model.get_const_interp_e model e with
    | Some loc -> translate_loc loc
    | None -> failwith "No interpretation of nil"

  let translate_stack context model =
    List.fold_left
      (fun stack var ->
        let var_expr =
          Expr.mk_const_s context.solver (SSL.Variable.show var) context.locs_sort
        in
        match Model.get_const_interp_e model var_expr with
        | Some loc ->
            Stack.add var (translate_loc loc) stack
        (* If some variable is not part of the model, we can safely map it to nil *)
        | None ->
            let nil_loc = nil_interp context model in
            Stack.add var nil_loc stack
      ) Stack.empty context.vars

  let translate_heap context model heap fp =
    let fp = Set.inverse_translation context.solver model fp in
    match Model.get_const_interp_e model heap with
    | Some heap_expr ->
        List.fold_left
        (fun heap loc ->
          let heap_image = Array.mk_select context.solver heap_expr loc in
          let loc_name = translate_loc loc in
          let image_name = match Model.evaluate model heap_image false with
          | Some loc -> translate_loc loc
          | None -> failwith ("No interpretation of" ^ string_of_int @@ loc_name)
          in
          Heap.add loc_name image_name heap
        ) Heap.empty fp
    | None -> failwith ("No interpretation of heap")

  let translate_footprints context model =
    SSL.fold
      (fun psi acc ->
        let id = SSL.subformula_id context.phi psi in
        let fp_name = Format.asprintf "footprint%d" id in
        let fp_expr = Expr.mk_const_s context.solver fp_name context.footprint_sort in
        let set = Set.inverse_translation context.solver model fp_expr in
        let fp = Footprint.of_list @@ List.map translate_loc set in
        SSL.Map.add psi fp acc
      ) context.phi SSL.Map.empty

  let translate_witness_heaps context model =
    SSL.fold
      (fun phi acc -> match phi with
        | Septraction (_, psi2) ->
          let id = SSL.subformula_id context.phi phi in
          let heap_name = Format.asprintf "heap%d" id in
          let heap_expr = Expr.mk_const_s context.solver heap_name (Expr.get_sort context.heap) in
          let id = SSL.subformula_id context.phi psi2 in
          let fp_name = Format.asprintf "footprint%d" id in
          let fp_expr = Expr.mk_const_s context.solver fp_name context.footprint_sort in
          let heap = translate_heap context model heap_expr fp_expr in
          SSL.Map.add phi heap acc
        | _ -> acc
      ) context.phi SSL.Map.empty


  let translate_model context model =
    let s = translate_stack context model in
    let h = translate_heap context model context.heap context.global_footprint in
    let footprints = translate_footprints context model in
    let heaps = translate_witness_heaps context model in
    StackHeapModel.init ~footprints ~heaps s h

  (* ==== Solver ==== *)

  (*
  let to_assert_list phi =
    let phi = Expr.simplify phi None in
    if Boolean.is_and phi
    then Expr.get_args phi
    else [phi]
  *)

  let solve phi info =
    let context = init phi info in
    let translated = translate_phi context phi in
    let size = Z3_utils.expr_size translated in
    let solver = init_solver context.solver in

    Debug.translated (context.solver, translated);
    Debug.context context;

    Printf.printf "Translating
     - Stack bound: %d
     - Location bound:  %d\n"
      (snd info.stack_bound)
      info.heap_bound
     ;

    Printf.printf "Running Z3 solver\n";
    Timer.add "Astral";

    match Solver.check solver [translated] (*to_assert_list translated*) with
    | SATISFIABLE ->
      let model = Option.get @@ Solver.get_model solver in
      Debug.smt_model model;
      let sh = translate_model context model in
      let results = Results.create info (Some sh) size `SAT in
      Sat (sh, model, results)
    | UNSATISFIABLE ->
      let results = Results.create info None size `UNSAT in
      let unsat_core = Solver.get_unsat_core solver in
      Unsat (results, unsat_core)
    | UNKNOWN ->
      let reason = Solver.get_reason_unknown solver in
      let results = Results.create info None size `UNKNOWN in
      Unknown (results, reason)

end
