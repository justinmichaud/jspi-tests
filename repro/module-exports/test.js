// WebAssembly.Module.exports() on a module exporting a function with a GC
// reference type in its signature. wasm_of_ocaml modules all do (caml_callback).
// Expected (V8): [{"name":"f","kind":"function"}]. JSC throws:
//   TypeError: WebAssembly.Module.exports unable to produce export descriptors
const isNode = typeof process !== "undefined";
const read = isNode ? (p) => require("fs").readFileSync(require("path").join(__dirname, p))
                    : (p) => readFile(p, "binary");
const log = isNode ? console.log : print;
try {
  const d = WebAssembly.Module.exports(new WebAssembly.Module(read("m.wasm")));
  log(d.length === 1 && d[0].name === "f" && d[0].kind === "function" ? "ok" : "FAILED: " + JSON.stringify(d));
} catch (e) {
  log("FAILED:", e);
}
