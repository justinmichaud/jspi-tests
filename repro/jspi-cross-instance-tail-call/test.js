// JSPI suspension below a cross-instance tail call (return_call to an import
// from another instance), as wasm_of_ocaml separate compilation emits.
// Expected (V8): prints "ok". JSC: rejects with
//   "JSPI stack scan failed: unrecognized type of Wasm frame: RestoreFrameMode"
const isNode = typeof process !== "undefined";
const read = isNode ? (p) => require("fs").readFileSync(require("path").join(__dirname, p))
                    : (p) => readFile(p, "binary");
const log = isNode ? console.log : print;
const suspend = new WebAssembly.Suspending((p) => p);
const a = new WebAssembly.Instance(new WebAssembly.Module(read("a.wasm")), { js: { suspend } });
const b = new WebAssembly.Instance(new WebAssembly.Module(read("b.wasm")), { a: { g: a.exports.g } });
WebAssembly.promising(b.exports.f)(Promise.resolve(42)).then(
  (v) => log(v === 42 ? "ok" : "FAILED: got " + v), (e) => log("FAILED:", e));
