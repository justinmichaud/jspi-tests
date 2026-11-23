type effects = Jspi | Cps | Native | None_
(** [None_]: built with --effects=disabled; performing an effect fails. *)

let profile = Profile.profile

let flavour, effects =
  match String.index_opt profile '-' with
  | None -> "dev", Jspi
  | Some i -> (
      let flavour = String.sub profile 0 i in
      match String.sub profile (i + 1) (String.length profile - i - 1) with
      | "jspi" -> flavour, Jspi
      | "cps" -> flavour, Cps
      | "native" -> flavour, Native
      | "none" -> flavour, None_
      | e -> failwith ("unknown effects mode in profile: " ^ e))

let effects_name = function Jspi -> "jspi" | Cps -> "cps" | Native -> "native" | None_ -> "none"
let has_effects = effects <> None_
