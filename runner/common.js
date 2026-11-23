// Shared harness: builds globalThis.__bench, the only interface between the
// environment (browser page or JS shell) and the OCaml programs (lib/bench).
// Plain script, no modules, so it loads the same way in browsers, node, jsc
// and d8.
"use strict";

globalThis.makeBench = function makeBench({ params, docs, now, toEpoch, report, fail, env }) {
  // Signposts: [name, startEpochMs, endEpochMs], for tools/profile.py.
  const spans = [];
  const span = (name, t0, t1) => { spans.push([name, toEpoch(t0), toEpoch(t1)]); };
  const hasMessageChannel = typeof globalThis.MessageChannel === "function";
  let macroQueue = null;
  // A macrotask hop. MessageChannel avoids the 4ms setTimeout clamp after
  // nesting; shells fall back to setTimeout(0).
  function macro(v) {
    if (hasMessageChannel) {
      if (!macroQueue) {
        const ch = new MessageChannel();
        const q = [];
        ch.port1.onmessage = () => q.shift()();
        macroQueue = { q, post: () => ch.port2.postMessage(0) };
      }
      return new Promise((r) => {
        macroQueue.q.push(() => r(v));
        macroQueue.post();
      });
    }
    return new Promise((r) => setTimeout(() => r(v), 0));
  }
  const enc = new TextEncoder();
  const helpers = {
    resolved: (v) => Promise.resolve(v),
    micro: (v) => new Promise((r) => queueMicrotask(() => r(v))),
    macro,
    // Real promise-returning web APIs. Each resolves to a small number so
    // the OCaml side can checksum it without conversion cost dominating.
    digest: (s) =>
      globalThis.crypto.subtle
        .digest("SHA-256", enc.encode(s))
        .then((b) => new DataView(b).getInt32(0) & 0x3fffffff),
    responseText: (s) => new Response(s).text().then((t) => t.length),
    blobBytes: (s) =>
      new Blob([s]).arrayBuffer().then((b) => b.byteLength),
    // Module loading: compile the same bytes asynchronously or synchronously.
    // (Not Module.exports(): JSC throws on GC-typed exports, repro/module-exports.)
    wasmCompile: (bytes) => WebAssembly.compile(bytes).then((m) => (m instanceof WebAssembly.Module ? bytes.byteLength & 0xffff : -1)),
    wasmCompileSync: (bytes) => (new WebAssembly.Module(bytes) instanceof WebAssembly.Module ? bytes.byteLength & 0xffff : -1),
    wasmBytes: null, // set by the environment for bench/await module-load
    hasWebApis: typeof globalThis.crypto?.subtle?.digest === "function" &&
      typeof globalThis.Response === "function",
  };
  return { params, docs, now, span, spans, report, fail, helpers, env };
};

// Fixed workload sizes, so every engine and mode runs exactly the same work.
// preset=small|default|large; explicit parameters override the preset.
globalThis.PRESETS = {
  switch: {
    small: { docs: 50, warmup: 2, iters: 5, fibers: 200, yields: 50, depth: 20, performs: 5000 },
    default: { docs: 200, warmup: 3, iters: 10, fibers: 1000, yields: 100, depth: 20, performs: 20000 },
    large: { docs: 1350, warmup: 3, iters: 20, fibers: 5000, yields: 200, depth: 20, performs: 100000 },
  },
  await: {
    small: { docs: 50, warmup: 2, iters: 5, n: 5000, m: 3 },
    default: { docs: 200, warmup: 2, iters: 10, n: 20000, m: 5 },
    large: { docs: 1350, warmup: 3, iters: 20, n: 200000, m: 10 },
  },
  micro: {
    small: { n: 20000, warmup: 2, iters: 5, docs: 0 },
    default: { n: 200000, warmup: 3, iters: 10, docs: 0 },
    large: { n: 2000000, warmup: 3, iters: 20, docs: 0 },
  },
  app: {
    small: { docs: 50, warmup: 1, iters: 3, queries: 10, concurrency: 8 },
    default: { docs: 200, warmup: 1, iters: 5, queries: 50, concurrency: 8 },
    large: { docs: 1350, warmup: 1, iters: 10, queries: 200, concurrency: 8 },
  },
};
globalThis.applyPreset = function applyPreset(w, params) {
  const name = params.preset || "default";
  const preset = PRESETS[w]?.[name];
  if (!preset) throw new Error(`unknown preset ${name} for ${w}`);
  const out = { preset: name };
  for (const [k, v] of Object.entries(preset)) out[k] = String(v);
  return Object.assign(out, params);
};

// Parse "k=v" arguments (shells) into a params object.
globalThis.parseArgs = function parseArgs(list) {
  const p = {};
  for (const a of list) {
    const i = a.indexOf("=");
    if (i > 0) p[a.slice(0, i)] = a.slice(i + 1);
  }
  return p;
};
