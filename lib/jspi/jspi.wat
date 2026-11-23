;; caml_jspi_await : Js.Unsafe.any -> Js.Unsafe.any
;; Calls the WebAssembly.Suspending import directly (no JS trampoline), so the
;; only cost on top of the promise itself is the JSPI suspend/resume.
;; User .wat files are linked against the prebuilt runtime as module "env"
;; (wasm_of_ocaml 6.5.0 compile.ml, link_runtime).
(module
   (import "env" "wrap" (func $wrap (param anyref) (result (ref eq))))
   (import "env" "unwrap" (func $unwrap (param (ref eq)) (result anyref)))
   (import "js" "caml_jspi_suspending_await"
      (func $suspending_await (param anyref) (result anyref)))

   (func (export "caml_jspi_await") (param $p (ref eq)) (result (ref eq))
      (return_call $wrap
         (call $suspending_await (call $unwrap (local.get $p)))))
)
