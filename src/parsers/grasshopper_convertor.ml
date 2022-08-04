(* Translation to input format of Grasshopper
 *
 * Author: Tomas Dacik (xdacik00@fit.vutbr.cz), 2022 *)

open SSL

module F = Format

let name = "grasshopper"

(* Header that includes list specification *)
let header = {|
struct Node {
  var next: Node;
}

predicate lseg(x: Node, y: Node) {
  acc({ z: Node :: Btwn(next, x, z, y) && z != y }) &*& Reach(next, x, y)
}
|}

(* Procedure header *)
let procedure_header phi =
  let signature =
    SSL.get_vars phi
    |> List.filter (fun v -> not @@ SSL.Variable.is_nil v)
    |> List.map (fun v -> F.asprintf "%a : Node" SSL.Variable.pp v)
    |> String.concat ", "
  in
  F.asprintf "procedure formula(%s)" signature

let convert_var var = match var with
  | Variable.Var _ -> Variable.show var
  | Variable.Nil -> "null"

let rec convert = function
  | And (f1, f2) -> F.asprintf "(%s && %s)" (convert f1) (convert f2)
  | Or (f1, f2) -> F.asprintf "(%s || %s)" (convert f1) (convert f2)
  | Not f ->  F.asprintf "(!%s)\n" (convert f)
  | Star (f1, f2) ->  F.asprintf "(%s &*& %s)" (convert f1) (convert f2)
  | LS (v1, v2) -> F.asprintf "(lseg (%s, %s))" (convert_var v1) (convert_var v2)
  | PointsTo (v1, v2) -> F.asprintf "(%s.next |-> %s)" (convert_var v1) (convert_var v2)
  | Eq (v1, v2) -> F.asprintf "(%s == %s)" (convert_var v1) (convert_var v2)
  | Neq (v1, v2) -> F.asprintf "(%s != %s)" (convert_var v1) (convert_var v2)
  | GuardedNeg (f1, f2) ->  failwith "TODO"
  | Septraction (f1, f2) -> failwith "Not supported"

let procedure_pre phi = match phi with
  (* Left-hand side of entailment *)
  | GuardedNeg (pre, _) -> F.asprintf "requires %s" (convert pre)
  (* Satisfiability *)
  | phi -> F.asprintf "requires %s" (convert phi)

let procedure_post phi = match phi with
  (* Right-hand side of entailment *)
  | GuardedNeg (_, post) -> F.asprintf "ensures %s" (convert post)
  (* Satisfiability: F --> F |= _|_ *)
  | _ -> "ensures false"

let convert_all phi =
  F.asprintf "// Generated by Astral\n%s\n\n%s\n\t%s\n\t%s\n{}"
    header
    (procedure_header phi)
    (procedure_pre phi)
    (procedure_post phi)

let convert phi _ = convert phi

let dump file phi status _ =
  let channel = open_out_gen [Open_creat; Open_wronly] 0o666 (file ^ ".spl") in
  Printf.fprintf channel "//status: %s\n\n" status;
  Printf.fprintf channel "%s\n" (convert_all phi);
  close_out channel
