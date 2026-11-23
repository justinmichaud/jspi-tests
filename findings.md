# Findings: JSPI and Wasm stack switching in JSC

The question: **should JSC implement Wasm stack switching (WasmFX), or invest
in JSPI?** Answered with real OCaml programs (wasm_of_ocaml 6.5) built three
ways from one source:
- `jspi`: OCaml effects on top of JSPI;
- `native`: WasmFX;
- `cps`: a compiler transform, no engine support.

There is also a `none` build with effects disabled. Engines: JSC (Safari
27.0.1's system jsc and WebKit trunk), Chrome 157 (JSPI and WasmFX), node 24.

The method and how to reproduce are in `README.md`; the profile deep-dive is
in `analysis.md`.

## Summary

1. **JSC's JSPI is 4–6× slower than V8's per suspend/resume.** This holds
   both for awaiting promises and for using JSPI as a stack-switching
   substrate. The cost sits in JSC's suspend/resume machinery, not in Wasm
   execution:
   - Wasm code is 11–14% of JSC's time in switch-heavy code, against 80% on
     Chrome.
   - The rest is stack walking, two stack copies per switch, per-suspend
     allocation, and a VM re-entry.
2. **On V8, WasmFX beats JSPI by 3–5× on switch-heavy code** (generators,
   fibers, channels), but only **1.4–1.9× on await-heavy code**, where promise
   and microtask work is shared.
3. **At application scale the effects strategy doesn't matter.** The docs
   reader app (fetch, Cache Storage, rendering, search, DOM events) runs
   within noise in jspi, native and cps on Chrome.
4. **CPS is the cheapest per switch but taxes all other code.** Code that
   never performs an effect runs about 2× slower under `cps` than under
   `none`/`jspi`/`native`.
5. **Two Chrome-works/JSC-fails bugs were found, both fixed in trunk.** Safari
   27.0.1 still has both.

**Recommendation.**
- **Fix JSPI first.** Closing the gap to V8 is worth more than WasmFX adds on
  top of a good JSPI, and it also speeds up plain async interop, which
  WasmFX doesn't touch.
- **The fixes are concrete:** see below and `analysis.md`.
- **Reconsider WasmFX after that.** The remaining case for it is
  switch-heavy code (generators, schedulers), where it would still be 3–5×
  faster than V8-class JSPI. It doesn't help ordinary awaits, and whole apps
  don't notice.

## Measurements

Per-operation cost in ns over the same test's no-switch baseline, from
`bench/micro` (one minimal case per row). The figures come from profiled runs
(samply attached) on a quiet machine: absolute values include profiler
overhead, but the ratios are stable. `tools/matrix.py` produces the unprofiled
table.

| | JSC jspi | Chrome jspi | Chrome native | Chrome cps* | JSC ÷ Chrome (jspi) | Chrome jspi ÷ native |
|---|---|---|---|---|---|---|
| generator, per switch | 751 | 128 | 24 | 1–4 | 5.9× | 5.3× |
| fibers, per yield | 1717 | 299 | 76 | 116 | 5.7× | 4.0× |
| deep handlers (20), per perform | 12189 | 2780 | 1015 | 124 | 4.4× | 2.7× |
| pipeline, per handoff | 1737 | 299 | 87 | – | 5.8× | 3.4× |
| await resolved, direct JSPI | 917 | 167 | – | – | 5.5× | – |
| await resolved, through a fiber | 3068 | 671 | 354 | 117 | 4.6× | 1.9× |
| await microtask, through a fiber | 3139 | 1147 | 799 | 216 | 2.7× | 1.4× |
| await resolved, `.then` callback | 237 | 160 | 197 | 8 | 1.5× | – |

\* The cps figures come from the realistic-workload matrix (unprofiled,
`preset=small`). CPS switches are cheap, but the cost moves to every
non-effect function. The no-effects generator twin took 2.6 ms under cps
against 1.2–1.3 ms in the other modes on Chrome, and 5.5 ms against 1.9 ms on
JSC.

The realistic workloads (`bench/switch`, `bench/await`) show the same ordering
with real work in the loop. In the app the modes are within noise: 125, 127
and 134 ms per iteration for jspi, native and cps on Chrome.

## Why JSC's JSPI is slow

Generator case on WebKit trunk. 78.5% of all time is under
`runWebAssemblySuspendingFunction`.

| share | what | fix |
|---|---|---|
| 28% | generic `StackVisitor` walk on every suspend (`readInlinableNativeCalleeFrame`, `PCToCodeOriginMap::findPC`, callee-save unwinding). Fixed cost, not per frame | walk the frame-pointer chain of known Wasm frames, or record the promising entry's bounds |
| 15% | the `Suspending` target is called through `Interpreter::executeCall` (VM re-entry) | direct JIT call, as for other imports |
| 12% | two new JS functions per suspend (`createPinballCompletion{Fulfill,Reject}Handler` → `VM::getHostFunction` hash lookup + allocation) | resume through an internal promise reaction, or at least cache the `NativeExecutable` |
| 11% | the stack is copied out on suspend and back on resume (`memmove`) | switch stacks instead (a separate stack per promising call, pooled), as V8 does |
| 9% | malloc/free (slice `unique_ptr`s, `Vector` growth) | goes away with stack switching; otherwise inline storage |
| 3% | strings built on the success path, `NameSection` ref/deref | build only on failure; avoid the churn |

Fixes 1, 2 and 4 are one change: give each `WebAssembly.promising` call its
own stack. That also makes depth-independent suspend O(1) by construction.

## Bugs (work in Chrome, fail in JSC)

Each has a minimal standalone repro; run them with `repro/run.sh [jsc]`.
`tools/parity.py` runs every build and workload per engine and maps
failures to these.

| repro | symptom | Safari 27.0.1 | WebKit trunk (2026-11-23) |
|---|---|---|---|
| `jspi-cross-instance-tail-call` | a JSPI suspend under a cross-instance `return_call` throws `JSPI stack scan failed: unrecognized type of Wasm frame: RestoreFrameMode`. Breaks every separately compiled wasm_of_ocaml build (`debug-jspi`) | fails | fixed (bug 329633, b31098b98f7b) in the default slab slicer; the frag slicer still has a FIXME but is compiled out |
| `module-exports` | `WebAssembly.Module.exports()` throws on functions with GC reference types in their signature (type reflection) | fails | fixed |

On trunk, `tools/parity.py` is clean: every build and workload that runs in
Chrome runs in jsc. Native/WasmFX is excluded, since it's the feature under
evaluation.

## Other observations

- **Resuming from callbacks doesn't work with JSPI.**
  - Under wasm_of_ocaml's JSPI mode, resuming an OCaml continuation from a JS
    callback throws `SuspendError` in every engine: callbacks don't run on a
    promising stack.
  - Lwt-style libraries that wake continuations from `.then` therefore can't
    use the JSPI backend as-is.
  - `lib/fiber` works around it: callbacks only queue work, and the root
    stack blocks with a direct JSPI await.
  - With WasmFX this works.
- **Direct JSPI awaits are cheap relative to fiber awaits.** In every engine
  that has both, a direct await (one `Suspending` call) costs 3–4× less than
  awaiting through an effect handler. With JSPI as the substrate, each OCaml
  switch is itself a JSPI suspend plus a microtask.
- **Module loading is not a JSPI cost.** Awaiting `WebAssembly.compile` via
  JSPI costs the same as compiling synchronously plus a small constant. The
  app's real modules are 0.4–0.6 MB after whole-program dead-code
  elimination.

## Caveats

- **CPU frequency was not pinned.** Several runs overlapped other work on the
  machine. The profiled table comes from a quiet window (load average about
  2); earlier unprofiled numbers came from loaded windows and are only
  indicative.
- **Safari itself was not automated here.** JSC was measured through the
  `jsc` shell, so the app and web-API tests ran on Chrome only.
  `tools/matrix.py --engines ...,safari` runs them in Safari.
- **Chrome's native frames are stripped on macOS,** so its profile breakdown
  is only JIT code against native code. The JSC breakdown is fully
  symbolicated.
