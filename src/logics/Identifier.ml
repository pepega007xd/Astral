(* Identifiers.
 *
 * Author: Tomas Dacik (idacik@fit.vut.cz), 2024 *)

type t = Int.t * String.t
(** Identifier is represented by integer tag used for comparison and name used for printing. *)

let compare (tag1, _) (tag2, _) = Int.compare tag1 tag2
let equal (tag1, _) (tag2, _) = Int.equal tag1 tag2
let show (_, name) = name
let pp fmt (_, name) = Format.fprintf fmt "%s" name

let equal_with_string (_, name) str = String.equal name str

(** Identifier managment *)

module HT = struct
  
  include Hashtbl.Make(String)

  let find_tag table name = fst @@ find table name

  let find_index table name = snd @@ find table name
  
end

module Make () = struct
  
  let counter = ref 0
  let hash_table = ref (HT.create 97)

  type nonrec t = t

  let next_id () =
    counter := !counter + 1;
    !counter

  let mk name =
    let tag, index = 
      try HT.find !hash_table name
      with Not_found -> next_id (), 0
    in
    HT.add !hash_table name (tag, index);
    (tag, name)

  let mk_fresh name =
    let tag, index =
      try HT.find !hash_table name
      with Not_found -> next_id (), 0
    in
    HT.add !hash_table name (tag, index + 1);
    (next_id (), Format.asprintf "%s!%d" name index)

  let show = show
  let compare = compare
  let equal = equal
end
