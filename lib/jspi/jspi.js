// Direct JSPI await for wasm_of_ocaml.
//
// wasm_of_ocaml builds its "js" import object from //Provides: values, so
// this Suspending object becomes the Wasm import itself (see jspi.wat), with
// no JavaScript frame in between. Calling it suspends the current
// WebAssembly.promising stack until the promise settles. Outside such a stack
// (a callback, or a build without JSPI) the engine throws SuspendError.

//Provides: caml_jspi_suspending_await
var caml_jspi_suspending_await =
  globalThis.WebAssembly && globalThis.WebAssembly.Suspending
    ? new globalThis.WebAssembly.Suspending(function (p) {
        return p;
      })
    : function (_p) {
        throw new Error("JSPI (WebAssembly.Suspending) is not available");
      };

//Provides: caml_jspi_available
function caml_jspi_available(_unit) {
  return globalThis.WebAssembly && globalThis.WebAssembly.Suspending ? 1 : 0;
}
