// Run a benchmark in a JS shell: node, jsc or d8.
//
//   node --experimental-wasm-jspi runner/shell.js <dist-dir> w=switch test=generator ...
//   jsc  <jsc flags> runner/shell.js -- <dist-dir> w=switch ...
//   d8   --experimental-wasm-jspi runner/shell.js -- <dist-dir> w=switch ...
//
// <dist-dir> is dist/<profile>/<workload>. Paths are relative to the repo
// root (run from there). The DOM-free workloads (switch, and the await tests
// that need no web API) run here; the app needs a browser.
"use strict";

(function () {
  const isNode = typeof process !== "undefined" && process.versions?.node;
  const argv = isNode ? process.argv.slice(2) : (globalThis.arguments || globalThis.scriptArgs || []);
  const out = (s) => (isNode ? process.stdout.write(s + "\n") : print(s));

  const readText = isNode
    ? (p) => require("node:fs").readFileSync(p, "utf8")
    : (p) => (typeof readFile === "function" ? readFile(p) : read(p));
  const readBytes = isNode
    ? (p) => new Uint8Array(require("node:fs").readFileSync(p))
    : (p) => new Uint8Array(typeof readFile === "function" ? readFile(p, "binary") : read(p, "binary"));
  const load = isNode ? (p) => require(require("node:path").resolve(p)) : (p) => globalThis.load(p);

  if (!isNode) {
    // Minimal environment for the wasm_of_ocaml browser loader in a shell.
    if (typeof globalThis.load === "undefined") throw new Error("shell has no load()");
    globalThis.load("runner/common.js");
    if (typeof queueMicrotask !== "function")
      globalThis.queueMicrotask = (f) => { Promise.resolve().then(f); };
    if (typeof performance === "undefined")
      globalThis.performance = { now: typeof preciseTime === "function" ? () => preciseTime() * 1000 : () => Date.now() };
    else if (typeof preciseTime === "function")
      globalThis.performance.now = () => preciseTime() * 1000; // epoch-based, for signposts
    if (typeof console === "undefined") globalThis.console = { log: print, error: print };
    if (typeof TextEncoder === "undefined") {
      // UTF-8 per WHATWG Encoding (lone surrogates become U+FFFD).
      const utf8 = (s, out, max) => {
        let i = 0, n = 0;
        for (; i < s.length; i++) {
          let c = s.charCodeAt(i);
          if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
            const d = s.charCodeAt(i + 1);
            if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); }
          }
          if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
          const len = c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
          if (n + len > max) break;
          if (out) {
            if (len === 1) out[n] = c;
            else if (len === 2) { out[n] = 0xc0 | (c >> 6); out[n + 1] = 0x80 | (c & 63); }
            else if (len === 3) { out[n] = 0xe0 | (c >> 12); out[n + 1] = 0x80 | ((c >> 6) & 63); out[n + 2] = 0x80 | (c & 63); }
            else { out[n] = 0xf0 | (c >> 18); out[n + 1] = 0x80 | ((c >> 12) & 63); out[n + 2] = 0x80 | ((c >> 6) & 63); out[n + 3] = 0x80 | (c & 63); }
          }
          n += len;
          if (c >= 0x10000) i++;
        }
        return { read: i, written: n };
      };
      globalThis.TextEncoder = class {
        encode(s = "") { const u = new Uint8Array(utf8(s, null, Infinity).written); utf8(s, u, u.length); return u; }
        encodeInto(s, u) { return utf8(s, u, u.length); }
      };
    }
    if (typeof TextDecoder === "undefined") {
      globalThis.TextDecoder = class {
        decode(u) {
          if (!u) return "";
          if (!(u instanceof Uint8Array)) u = new Uint8Array(u.buffer ?? u, u.byteOffset ?? 0, u.byteLength);
          let s = "", i = 0;
          const chunk = [];
          while (i < u.length) {
            let c = u[i++];
            if (c >= 0xf0) c = ((c & 7) << 18) | ((u[i++] & 63) << 12) | ((u[i++] & 63) << 6) | (u[i++] & 63);
            else if (c >= 0xe0) c = ((c & 15) << 12) | ((u[i++] & 63) << 6) | (u[i++] & 63);
            else if (c >= 0xc0) c = ((c & 31) << 6) | (u[i++] & 63);
            if (c >= 0x10000) { c -= 0x10000; chunk.push(0xd800 + (c >> 10), 0xdc00 + (c & 0x3ff)); }
            else chunk.push(c);
            if (chunk.length > 8192) { s += String.fromCharCode.apply(null, chunk); chunk.length = 0; }
          }
          return s + String.fromCharCode.apply(null, chunk);
        }
      };
    }
  } else {
    require("./common.js");
  }

  const dist = argv[0];
  const w = dist.replace(/\/+$/, "").split("/").pop();
  const params = applyPreset(w, parseArgs(argv.slice(1)));
  const manifest = JSON.parse(readText("corpus/manifest.json"));
  const n = Math.min(+(params.docs || 200), manifest.docs.length);
  const docs = manifest.docs.slice(0, n).map((d) => readText("corpus/" + d.path));

  let finished = false;
  const bench = makeBench({
    params, docs,
    now: () => performance.now(),
    // Epoch ms for signposts: node has timeOrigin; the shells' clock is
    // preciseTime() (epoch seconds), see the performance shim above.
    toEpoch: isNode ? (t) => performance.timeOrigin + t
      : typeof preciseTime === "function" ? (t) => t
      : ((off) => (t) => off + t)(Date.now() - performance.now()),
    // Exit as soon as the result is in: an open MessageChannel port (macro
    // test) would otherwise keep node alive forever.
    report: (s) => {
      finished = true;
      const o = JSON.parse(s);
      o.params = params;
      o.spans = bench.spans;
      o.engine = isNode ? `node ${process.version}` : (globalThis.__engine || "shell");
      out(JSON.stringify(o));
      if (isNode) setTimeout(() => process.exit(process.exitCode || 0), 0);
    },
    fail: (s) => { finished = true; out("FAILED: " + s); if (isNode) { process.exitCode = 1; setTimeout(() => process.exit(1), 0); } },
    env: { kind: isNode ? "node" : "shell" },
  });
  // module-load: the largest module of an app build (module=<file> overrides).
  if ((w === "await" || w === "micro") && (!params.test || params.test === "all" || params.test === "module-load")) {
    if (params.module) bench.helpers.wasmBytes = readBytes(params.module);
    else {
      const profile = dist.replace(/\/+$/, "").split("/").slice(-2)[0];
      const mode = profile.split("-").pop();
      // Always the same bytes (release-jspi's app), so checksums match across modes.
      for (const p of ["release-jspi", profile, "release-cps"]) {
        const dir = `dist/${p}/app`;
        let files;
        try { files = JSON.parse(readText(dir + "/wasm-files.json")); } catch { continue; }
        let best = null;
        for (const f of files) { const b = readBytes(`${dir}/main.bc.wasm.assets/${f}`); if (!best || b.length > best.length) best = b; }
        bench.helpers.wasmBytes = best;
        break;
      }
      void mode;
    }
  }
  globalThis.__bench = bench;

  const main = dist + "/main.bc.wasm.js";
  if (!isNode) {
    // The loader fetches its assets with fetch() relative to the script when
    // not under node; serve them from the file system.
    globalThis.fetch = async (url) => {
      const path = String(url).startsWith("/") ? String(url) : dist + "/" + url;
      const bytes = readBytes(path);
      return { ok: true, arrayBuffer: async () => bytes.buffer, then: undefined };
    };
    if (!WebAssembly.instantiateStreaming || !globalThis.Response)
      WebAssembly.instantiateStreaming = async (resp, imports, opts) =>
        WebAssembly.instantiate(await (await resp).arrayBuffer(), imports, opts);
  }
  if (!isNode) {
    // jsc/d8 drop unhandled rejections silently: report loader failures.
    for (const k of ["instantiate", "instantiateStreaming", "compile"]) {
      const f = WebAssembly[k];
      if (f) WebAssembly[k] = function (...a) {
        return f.apply(this, a).catch((e) => { bench.fail(`WebAssembly.${k}: ${e}\n${e && e.stack}`); throw e; });
      };
    }
  }
  // delay=<ms>: spin before starting, so tools/profile.py can attach samply.
  if (params.delay) { const end = Date.now() + +params.delay; while (Date.now() < end); }
  load(main);
  if (isNode) process.on("exit", () => { if (!finished) { out("FAILED: no report"); process.exitCode = 1; } });
})();
