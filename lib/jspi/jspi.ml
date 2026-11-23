(* Direct JSPI await: suspend the current WebAssembly.promising stack until a
   JS promise settles. Valid only in a JSPI build, and only when no OCaml
   effect handler (fiber) sits between the caller and the promising root, i.e.
   from top-level code or from the root scheduler loop. A rejection surfaces as
   a JavaScript exception. *)

open Js_of_ocaml

external await_any : Js.Unsafe.any -> Js.Unsafe.any = "caml_jspi_await"
external available_ : unit -> bool = "caml_jspi_available"

let available () = available_ ()
let await (p : 'a Js.t) : Js.Unsafe.any = await_any (Js.Unsafe.inject p)
