(* FNV-1a, 30-bit, for checksums that must match across modes and engines
   (OCaml ints are 31-bit under wasm_of_ocaml). *)

let init = 0x011c9dc5

let string h s =
  let h = ref h in
  for i = 0 to String.length s - 1 do
    h := (!h lxor Char.code (String.unsafe_get s i)) * 0x01000193 land 0x3fffffff
  done;
  !h

let int h i = (h lxor (i land 0x3fffffff)) * 0x01000193 land 0x3fffffff
