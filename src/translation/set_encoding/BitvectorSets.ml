(* Set encoding based on bitvetors
 *
 * Author: Tomas Dacik (xdacik00@fit.vutbr.cz), 2022 *)

module BV = Bitvector

open SMT

include Term

(* === Implementation of set interface === *)

let name = "bitvectors"

let mk_var = Variable.mk
let mk_fresh_var = Variable.mk_fresh

let get_elem_sort set = get_sort set

let mk_sort sort = sort

let mk_empty = function Sort.Bitvector n -> Bitvector.mk_zero n

(** Singleton set {x} is represented by `1` shifted to position x. *)
let mk_singleton elem =
  let n = Bitvector.get_width elem in
  Bitvector.mk_shift_left (Bitvector.mk_one n) elem

(** Create representation of set enumeration using bitwise disjunction of bit-vectors
    representing singleton sets. *)
let mk_enumeration sort elems = BitOr (List.map mk_singleton elems, sort)

(** Membership of `elem` in `set` is represented by extracting bit at position `elem`
    and testing it for being 1. *)
let mk_mem elem set = BitCheck (set, elem)

let mk_subset set1 set2 =
  let n = Bitvector.get_width set1 in
  let bv_impl = BitImplies (set1, set2) in
  mk_eq bv_impl (Bitvector.mk_full_ones n)

let mk_disjoint set1 set2 =
  let n = Bitvector.get_width set1 in
  let bv_and = BitAnd ([set1; set2], Sort.Bitvector n) in
  mk_eq bv_and (Bitvector.mk_zero n)

let mk_union sets sort = BitOr (sets, sort)
let mk_inter sets sort = BitAnd (sets, sort)
let mk_diff set1 set2 =
  let n = Bitvector.get_width set1 in
  BitAnd ([set1; BitCompl set2], Sort.Bitvector n)

let mk_compl set = BitCompl set

let mk_eq_empty set =
  try Equal (set, mk_empty (get_sort set))
  with _ -> failwith (Term.show set ^ " : " ^ (Sort.show @@ get_sort set) ^ " x " ^ Sort.show @@ get_elem_sort set)

let mk_eq_singleton set x = Equal (set, mk_singleton x)

let get_elems set = failwith "TODO: get_elems"

let may_disjoint _ _ = true

let hex_to_bin str = BatString.fold_left (fun acc digit ->
  let bits = match digit with
  | '0' -> "0000"
  | '1' -> "0001"
  | '2' -> "0010"
  | '3' -> "0011"
  | '4' -> "0100"
  | '5' -> "0101"
  | '6' -> "0110"
  | '7' -> "0111"
  | '8' -> "1000"
  | '9' -> "1001"
  | 'a' -> "1010"
  | 'b' -> "1011"
  | 'c' -> "1100"
  | 'd' -> "1101"
  | 'e' -> "1110"
  | 'f' -> "1111"
  | 'x' | '#' -> ""
  | other -> failwith (Format.asprintf "Hex digit: %c" other)
  in
  acc ^ bits
) "" str

(** Translate a bitstring to the set which it encodes. *)
let inverse_translation (bitstring : String.t) n =
  let acc = Set.mk_empty (Sort.Bitvector n) in
  Printf.printf "str: %s" bitstring;
  let set = match String.get bitstring 1 with
  | 'b' ->
    BatString.fold_lefti
      (fun acc index bit ->
        if bit == '1'
        then Bitvector.mk_const index n :: acc
        else acc
      ) [] (BatString.rev bitstring)
  | 'x' ->
    let bitstring = hex_to_bin bitstring in
    BatString.fold_lefti
      (fun acc index bit ->
        if bit == '1'
        then Bitvector.mk_const index n :: acc
        else acc
      ) [] (BatString.rev bitstring)

  in
  Set.mk_enumeration (Sort.Bitvector n) set

(** Rewriting of standart sets to bitvector sets.

    The function rewrites all set expressions to corresponding bitvector expressions and also
    need to correctly update all sorts. *)
let rec rewrite t =
  Term.map
    (fun t -> match t with
      | Membership (x, set) -> mk_mem (rewrite x) (rewrite set)
      | Subset (set1, set2) -> mk_subset (rewrite set1) (rewrite set2)
      | Disjoint (set1, set2) -> mk_disjoint (rewrite set1) (rewrite set2)
      | Union (sets, Set sort) -> mk_union (List.map rewrite sets) sort
      | Inter (sets, Set sort) -> mk_inter (List.map rewrite sets) sort
      | Diff (set1, set2) -> mk_diff (rewrite set1) (rewrite set2)
      | Compl set -> mk_compl (rewrite set)
      | Enumeration (elems, Set sort) -> mk_enumeration sort (List.map rewrite elems)
      | Variable (name, Set sort) -> Variable (name, sort)
      | Exists2 (binders, ranges, phi) ->
          Exists2 (List.map rewrite binders, List.map (List.map rewrite) ranges, phi)
      | Forall2 (binders, ranges, phi) ->
          Forall2 (List.map rewrite binders, List.map (List.map rewrite) ranges, phi)
      | other -> other
    ) t

(** Rewritting of models. *)
let rewrite_back phi_orig model =
  let rewrite_term = Term.map
    (fun t -> match t with
      | BitConst (n, width) ->
        let bvs = BV.to_set (n, width) in
        let bvs = List.map (fun bv -> BitConst bv) bvs in
        Enumeration (bvs, Bitvector width)
      | other -> other
    )
  in
  SMT.Model.map
    (fun (var, term) ->
      let name = SMT.Variable.get_name var in
      match SMT.get_sort_in_term name phi_orig with
      | Set _ -> rewrite_term term
      | _ -> term
    ) model
