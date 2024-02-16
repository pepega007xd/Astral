open Convertor_sig

module Input = Context
open Input

module Make (Convertor : CONVERTOR_BASE) = struct

  include Convertor

  let comment str = Format.asprintf "%s %s" Convertor.comment_prefix str

  (** Conversion *)

  let header = comment "Generated by Astral (see https://github.com/TDacik/Astral)"

  let declarations input =
    let vars =
      List.map Convertor.declare_var input.vars
      |> List.filter (fun s -> s <> "")
      |> String.concat "\n"
    in
    let sorts =
      List.map SSL.Variable.get_sort input.vars
      |> List.sort_uniq Sort.compare
      |> List.map Convertor.declare_sort
      |> String.concat "\n"
    in
    Format.asprintf "%s\n%s"
      sorts
      vars

  let convert_formula input =
    if Convertor.supports_sat then Convertor.convert_benchmark input.phi
    else Convertor.convert_benchmark (Input.transform_to_entl input).phi

  let convert input =
    Format.asprintf ("%s\n\n%s\n\n%s\n\n%s\n\n%s")
      header
      (Convertor.set_status input)
      (declarations input)
      (Convertor.global_decls input)
      (convert_formula input)

  let dump file input =
    let converted = convert input in
    let target_name = Str.global_replace (Str.regexp "\\.smt2") Convertor.suffix file in
    let channel = open_out_gen [Open_creat; Open_wronly] 0o666 target_name in
    Printf.fprintf channel "%s" converted;
    close_out channel

end