(* Bitwuzla backend for Astral
 *
 * Author: Tomas Dacik (idacik@fit.vut.cz), 2023 *)

open Generic_smtlib

module Self = struct
  let name = "Bitwuzla"
  let binary = "bitwuzla"

  let supports_smtlib_options = true
  let supports_get_info = false

  let supports_sets = false
  let supports_quantifiers = true

  let translate_non_std = translate_std
  and translate_non_std_sort = translate_std_sort

  let declare_non_std_sort = declare_std_sort

end

include Smtlib_backend_builder.Make(Self)
