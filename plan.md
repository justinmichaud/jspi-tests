# OCaml + JSPI workload for Safari: plan

Goal: give JSC realistic OCaml/Wasm workloads that use JSPI in the two ways
real OCaml code does. The first is awaiting browser promises from direct-style
code. The second is JSPI standing in for stack switching to implement OCaml 5
effect handlers. Each workload has knobs that turn the JSPI share of runtime
up until it dominates, and each one builds in every effect strategy so they
can be compared.

Deliverables:

1. **`app/`**: one holistic web application that exercises everything together.
2. **`bench/await/`** (case 1): hammers *JSPI as an async bridge*. It covers
   promises, web APIs and large-module loading.
3. **`bench/switch/`** (case 2): hammers *JSPI as a stack-switching
   substrate*. Effects are used as control flow, with no real async involved.

All three build in these modes from the same source: `jspi`, `native`
(Wasm stack switching), and `cps` (the wasm-side CPS transform).

**The decision this informs.** JSC does not implement Wasm stack switching;
Chrome does (behind `--experimental-wasm-wasmfx`). The workloads have to
answer *should JSC implement it?*:

- **jspi vs native on Chrome** (same engine) gives the gain from stack
  switching over JSPI-as-substrate. If it is small, JSC can skip WasmFX
  and invest in JSPI.
- **jspi on JSC vs jspi on Chrome** shows how good JSC's JSPI is.
- **cps on both** gives the engine-independent fallback every non-WasmFX
  browser pays today.
- `native` builds are therefore run on Chrome only. On JSC they must fail
  fast and clearly, not silently fall back.

---

## 0. Hard requirements (apply to every workload)

**Fully local and hermetic.**
- The toolchain lives in `_tools/`: the opam binary, an opam root, Binaryen,
  and pinned versions recorded in `opam/lock`. Nothing is installed
  system-wide. `tools/bootstrap.sh` rebuilds it from scratch.
- All sources are vendored or pinned: opam package sources are cached in
  `_tools/`, and the corpus is checked into `corpus/` at a pinned upstream
  commit.
- After bootstrap, **no network access** happens at build or run time.
  "Fetch" goes to a local static server (`tools/serve.py`, loopback only), or
  to `blob:`/in-memory `Response`s in the benches. There are no CDNs, no
  service-worker network, and no external fonts.

**Two build flavours per mode** (`dist/<flavour>/<mode>/`):
- `debug`: `wasm_of_ocaml --debug-info --source-map --pretty`, no Binaryen
  optimisation, with source maps embedding the full OCaml sources
  (`--source-map-inline`/sourcesContent). Stack traces and profilers resolve
  to OCaml file:line. It is not timed.
- `release`: `--opt 3`, full Binaryen pipeline, no source maps, no debug
  names, no assertions or logging. This is the build that gets timed.
- Both are built from the same commit and record the toolchain versions and
  build flags in `dist/<flavour>/<mode>/build-info.json`.

**Noise elimination.**
- Same inputs every run: corpus, fixed PRNG seeds, a fixed workload size per
  preset (`small`/`default`/`large`), and no wall-clock-dependent behaviour.
- No network, no service worker, and no IndexedDB/Cache Storage in the
  timed path *unless that API is what the sub-test measures* (in which case
  the store is cleared and pre-seeded identically before each iteration).
- Benches never touch the DOM, so there's no layout/paint in the timed
  region. The app renders into a fixed-size offscreen container and is timed
  separately per phase.
- Timers are used only where they are the measured knob (`macrotask`).
  Otherwise there is no `setTimeout`, `requestAnimationFrame` or `requestIdleCallback`.
- Each run is a fresh process or page load. Warmup iterations are
  discarded, then a fixed number of timed iterations, reporting
  every sample (not just the mean). Loading is excluded from steady-state
  timings and measured separately by `module-load` and app `boot`.
- Correctness checksums are verified *outside* the timed region and must
  match across modes and engines.
- The runner launches browsers with a clean temporary profile, no
  extensions, and background throttling off. It records the engine version and
  flags, and follows the host's CPU-pinning rules from the jsc benchmarking
  skills.

---

## 1. Research findings that shape the design

### Toolchain: wasm_of_ocaml already has all three modes
`wasm_of_ocaml` (in the js_of_ocaml repo, latest 6.5.0, master checked
2026-11-20) has `--effects={jspi,cps,native}`:

| mode | how effects work | where it runs |
|---|---|---|
| `jspi` (default) | No code transform. Every fiber is its own JSPI stack. | Chrome ≥137, Node ≥25, Safari (our target) |
| `cps` | Partial CPS transform. Direct-style code is kept where the analysis proves no effect can occur. The analysis is weak for higher-order code such as Lwt. | everywhere |
| `native` | WasmFX typed continuations (`effect-native.wat`). The CPS pass is skipped. | Chrome ≥148 with `--experimental-wasm-wasmfx`, Node canary (V8 ≥14.7.100), Wizard |

Upstream docs: jspi is "comparatively slow when effects are used as core
control flow", and native "provides the best performance". Our workloads
measure exactly that gap.

### How the `jspi` effect mode works (read from `runtime/wasm/effect.wat` and `runtime.js`)
This is the hot path we will be optimizing, so it shapes the benchmarks:

- `_initialize` (all module top-level code) is wrapped in
  `WebAssembly.promising`, so the main program runs on a JSPI stack.
- `caml_start_fiber` is `WebAssembly.promising`. **Every new fiber
  (`match_with`/`try_with`/`continue` of a fresh fiber) is a new promising
  call, which allocates a new JSPI stack.**
- Every control transfer (`perform`, `continue`, `reperform`, `with_stack`)
  goes through `$capture_continuation`. That calls the import
  `suspend_fiber = new WebAssembly.Suspending((f, env) => new Promise(k => f(k, env)))`.
  The promise executor re-enters Wasm *synchronously* to run the target.
  The current stack then suspends on the returned promise.
- Resuming a suspended fiber calls the resolver of its promise
  (`resume_fiber: (k, v) => k(v)`). **The fiber therefore wakes up in a
  microtask.** So every OCaml-level context switch costs:
  1 Promise allocation, 1 JS→Wasm re-entry, 1 JSPI suspend, and 1
  microtask-driven JSPI resume. A new fiber also costs 1 promising entry.
- With native effects, JS frames block effects: callbacks clear
  `effect_allowed`, so `perform` raises `Effect.Unhandled`. Under JSPI, a
  callback is not on a promising stack at all. **Any code that performs or
  resumes has to start from the promising root stack, never from a DOM or
  Promise callback.** This constrains the app's architecture (§3) and is the
  first thing to verify (§6, Phase 0).

### What's missing upstream (small patches we carry)
- **No direct "await a JS promise" primitive.** Every await in OCaml today
  goes through effects (for example `Lwt_direct.await`, which performs an
  effect handled by `Lwt_direct.spawn`). To measure *pure* JSPI as an async
  bridge, with no fiber machinery, we add a ~10-line primitive
  `caml_jspi_await : 'a Promise.t -> 'a`. It is a Wasm import wrapped in
  `WebAssembly.Suspending`, using the `make_suspending` helper `runtime.js`
  already has. This lives in `patches/jsoo-direct-await.patch`. It is valid
  only when no effect handler sits between the caller and the promising root,
  so it is used only by the `jspi-direct` variant of `bench/await`.
- **Dynlink compiles plugins synchronously** (`new WebAssembly.Module(bytes)`
  in `runtime.js`). That is main-thread jank for large modules, and Chrome
  refuses it above 8 MB on the main thread. The real-world JSPI use is to
  `await WebAssembly.compile(...)` from direct-style OCaml.
  `patches/jsoo-async-dynlink.patch` adds that path behind a flag, so we can
  compare sync compile, JSPI-awaited compile, and effect-awaited compile.

Both patches are optional. The main matrix runs on stock wasm_of_ocaml.

### Real libraries we build on
All of these are pure OCaml and work with js_of_ocaml/wasm_of_ocaml:
- **js_of_ocaml 6.5** stdlib bindings: `Dom_html`, `Fetch`, `Promise`
  (added in 6.4), `Js_of_ocaml_lwt`. We use these rather than Brr, which
  needed a fork for wasm_of_ocaml.
- **lwt 6 + lwt_direct**: real-world direct-style async on effects
  (`Lwt_direct.spawn` / `await`). Under each mode it becomes JSPI fibers,
  WasmFX continuations, or CPS closures.
- **cmarkit**: CommonMark 0.31.2 parser and HTML renderer. This is the real
  compute.
- **uucp + uunf**: Unicode property and normalization tables. They are real
  and *large*, and they make the lazily loaded plugin a multi-MB Wasm module.
- **yojson**: manifest parsing.
- **eio (core) + `Eio_mock` backend**: a real effects-based scheduler with
  fibers, `Eio.Stream` and `Eio.Promise`, for case 2. Fallback if it doesn't
  build under wasm_of_ocaml: **picos + picos_mux.fifo**. Last resort:
  the ~150-line scheduler from the OCaml manual / `lib-effects/sched.ml`.

Corpus: a pinned subset of **MDN `content`** (`files/en-us/**/index.md`,
CC-BY-SA, about 10k real Markdown docs, so N scales freely), plus the
CommonMark spec. Vendored as static files and as one `.tar` for the bulk-load
path.

---

## 2. Build matrix

One dune workspace, one `dune-project`, one dune *profile* per mode:

| profile | wasm_of_ocaml flags | async library | used by |
|---|---|---|---|
| `jspi` | `--effects=jspi` | lwt_direct | app, await, switch |
| `native` | `--effects=native` | lwt_direct | app, await, switch |
| `cps` | `--effects=cps` | lwt_direct | app, await, switch |
| `jspi-direct` | `--effects=jspi` + patch | `caml_jspi_await` | await only |
| `lwt-monadic` *(optional)* | any | plain Lwt `>>=` | await only. Hand-written CPS as a ground-truth floor. |

Program code is written against a tiny `Async` signature (`await`, `spawn`,
`yield`, `Stream`). Variants differ only by which implementation is linked
(dune `(select …)` / virtual library). So the *same* OCaml source runs in
every mode.

Also emit the `js_of_ocaml` build with `--effects=cps` as a cross-check that
the work is identical. It is not timed in the headline numbers.

Toolchain, pinned in `opam` lock files: OCaml 5.4.x, js_of_ocaml /
wasm_of_ocaml 6.5.0, dune ≥3.19, Binaryen ≥119 (≥124 for `native`). OCaml
builds happen on the host. The *browser/JSC* runs follow the wk workspace
rules: the output is static files served to MiniBrowser/Safari, or `jsc`
for the shell runner.

---

## 3. Workload A: holistic app (`app/`)

**"Docs reader"**: an offline-capable Markdown documentation reader with
search. It is a realistic single-page OCaml client:

1. **Boot.** The `wasm_of_ocaml` loader fetches and instantiates the app. It
   is separately compiled, so many modules load concurrently. `_initialize`
   runs on a promising stack. The app main loop is spawned from there: a
   `Lwt_direct.spawn`'d root fiber. Per §1, *all* effectful work runs below
   it, and DOM events only push into an `Lwt_stream` the root fiber consumes.
2. **Sync corpus.** `fetch` manifest.json and decode it with yojson. Then,
   with concurrency `c`, for each doc:
   `crypto.subtle.digest` of the URL+etag gives a key. Next comes a Cache
   Storage lookup (`caches.open`/`match`). On a miss, `fetch` the doc,
   `response.text()`, and `cache.put`. Every step is a real promise-returning
   web API awaited from direct-style OCaml.
3. **Render.** Parse with cmarkit, render HTML into the DOM, and build an
   inverted index of tokens. Real compute runs between awaits.
4. **Lazy plugin.** The first search query dynlinks the **search plugin**
   (uucp/uunf case-folding + NFC normalization, which makes a large Wasm
   module). The app awaits its compile and instantiation, then runs a
   scripted query set.
5. **Interaction replay.** A scripted sequence of navigations, searches and
   cache revalidations. Each one is a DOM event, then the root-fiber queue,
   then awaits and render.

Knobs (URL params): `docs=N`, `concurrency=c`, `latency=ms` (served via a
Service Worker that delays responses, or `0`), `cache=cold|warm`,
`plugin=sync|jspi|effect`, `iterations=k`.

Reported: total time and per-phase time (boot, sync, render, plugin load,
replay), with counters for awaits, performs, resumes, and fibers created.
Defaults should be sized so a run takes about 2–5 s. That is big enough to
not be a microbenchmark and small enough to iterate on.

---

## 4. Workload B1: `bench/await` (case 1, JSPI as async bridge)

The same building blocks as the app, but in a tight loop and with the DOM
removed.

Sub-tests:
- **`resolved`**: await N already-resolved promises with `w` bytes of
  cmarkit work between awaits. This is the pure suspend/resume cost.
- **`microtask` / `macrotask`**: await promises resolved by
  `queueMicrotask` vs `MessageChannel`/`setTimeout(0)`. It separates JSPI
  cost from event-loop cost.
- **`webapi`**: a real-API mix of `crypto.subtle.digest`, Cache Storage
  `match`/`put`, `fetch` of a `blob:` URL, and `Response.text()`.
- **`depth`**: await at OCaml recursion depth `d` (1…10k frames). This
  matters if suspend/resume cost scales with stack size.
- **`fanout`**: `c` concurrent awaiters, which means c live suspended stacks.
- **`module-load`**: compile and instantiate the search plugin (size `S`:
  with or without the uucp tables) `M` times. Compare sync
  `new WebAssembly.Module`, `jspi-direct` await, and effect-based await.

Variants: `jspi-direct`, `jspi`, `native`, `cps`, plus optional
`lwt-monadic`.

**Isolation control.** Every sub-test has a `nosuspend` twin. It does the
same work, but `await` on an already-settled promise short-circuits through
a synchronous fast path. The difference is the per-await JSPI or effect
overhead. We report **ns per await** and **awaits/sec**, not just total
time.

---

## 5. Workload B2: `bench/switch` (case 2, JSPI as stack switching)

No real async: every switch is an OCaml effect. In `jspi` mode the program
still goes through Suspending, Promise and microtask machinery. That is the
overhead native stack switching removes and CPS trades for closure
allocation.

Sub-tests, all using real libraries and real data:
- **`generator`**: effect-based iterator→`Seq` inversion over a cmarkit AST
  of the corpus, with one switch per node. Knob: work per node.
- **`pipeline`**: an Eio (`Eio_mock` backend) or picos pipeline of K stages
  connected by `Eio.Stream` of capacity `q`. The stages are tokenize, parse,
  render and index over MDN docs. `q=0` forces a handoff (2 switches) per
  item. Knobs: `K`, `q`, items.
- **`fibers`**: spawn F short-lived fibers (`Fiber.fork`), each yielding y
  times. It stresses fiber creation, which means promising-entry and stack
  allocation under JSPI.
- **`deep`**: a stack of h nested handlers (state, reader, exception-like),
  with performs that are handled h levels up. It stresses `reperform`.

Variants: `jspi` vs `native` vs `cps`. These are the headline comparison.
A `noeffects` twin of each sub-test (direct calls, same work) gives the
compute floor.

**Runs in the `jsc` shell too.** B2 needs no DOM or network. A small
`shell-shim.js` provides `globalThis` bits, a microtask drain and
`print`-based output, so it can run under `jsc` for JSC profiling without a
browser. Through the shim, B1's `resolved`/`microtask`/`depth`/`fanout`
sub-tests can run in the shell too.

---

## 6. Phases

**Phase 0: spikes (decide before writing workloads).**
- Install the toolchain and build hello-effects in all 3 modes. Run in
  Chrome (with the wasmfx flag), Node canary, and the target Safari/JSC
  build.
- **Verify the callback constraint.** Resume a continuation from a
  `Promise.then` callback and a DOM event under each mode. If jspi traps
  with `SuspendError`, the root-fiber queue design in §3 is mandatory
  (expected). Also check that `Lwt_direct` + `Js_of_ocaml_lwt` wakeups land
  on the root fiber correctly.
- Check that eio core + `Eio_mock` builds with wasm_of_ocaml (Domain/Mutex
  usage, C stubs). If not, try picos, then the in-repo scheduler.
- Check that the `caml_jspi_await` patch works (Suspending import from a
  user `.wat` primitive).

**Phase 1: shared core.** `Async` signature and its 4 implementations, the
`corpus` fetch/cache module, the cmarkit render+index module, the
counters/timing harness, and the results JSON format.

**Phase 2: `bench/switch`.** This is the smallest piece and the fastest
route to a JSC profiling target. It is the shell-runnable one.

**Phase 3: `bench/await`**, including the module-load sub-test (needs the
async-dynlink patch).

**Phase 4: `app/`.** Glue the core pieces into the UI with the interaction
replay.

**Phase 5: runner.** `run.html?w=app|await|switch&mode=…&…` plus a script
that serves `dist/` and drives MiniBrowser/Safari through the mode × knob
grid. Each mode lives in its own directory (`dist/<mode>/`). Output is
JSON per run that `compare-results`-style tooling can consume. Correctness
check: each workload prints a checksum (index hash or render hash) that must
match across modes.

---

## 7. Layout (target: ~2–3k lines of OCaml + a few hundred of JS/HTML)

```
jspi/
  plan.md
  dune-project, dune-workspace (profiles: jspi native cps jspi-direct lwt-monadic)
  opam/ (lock files), patches/ (jsoo-direct-await, jsoo-async-dynlink)
  corpus/ (fetch script + pinned MDN subset manifest)
  lib/async/      Async sig + impls (lwt_direct, direct-jspi, monadic)
  lib/docs/       corpus fetch+cache, cmarkit render, indexer
  lib/search/     uucp/uunf plugin (dynlinked)
  app/            main.ml, index.html
  bench/await/    main.ml
  bench/switch/   main.ml (eio_mock|picos), shell-shim.js
  runner/         run.html, serve + drive script, results schema
```

## 8. Risks / open questions
- **Native mode is Chrome-only.** JSC has no WasmFX, so on JSC we compare
  jspi vs cps, and Chrome provides the jspi-vs-native delta.
- **CPS with Lwt/Eio.** The CPS transform is weak on higher-order code, so
  `cps` builds may be large and slow. That is a real finding, not a bug, but
  watch binary size and compile time.
- **Fiber-per-JSPI-stack memory.** `fanout`/`fibers` at high counts may hit
  stack-allocation limits in JSC. This is worth capturing as a result.
- **Library compatibility with wasm_of_ocaml** (eio, uucp size, lwt_direct
  version). Phase 0 covers it, and each one has a fallback.

## Sources
- wasm_of_ocaml effects modes: https://ocaml.org/p/js_of_ocaml/6.4.1/doc/effects.html
- wasm_of_ocaml overview (flags, browser support, dynlink): https://ocaml.org/p/js_of_ocaml/6.4.1/doc/wasm_overview.html
- "Wasm_of_ocaml: What Changed Since 6.1" (native effects, perf notes): https://ocaml.org/backstage/2026-04-16-wasm-of-ocaml-what-changed-since-6-1
- js_of_ocaml 6.4 announcement (`Promise`, `Fetch` modules): https://discuss.ocaml.org/t/ann-js-of-ocaml-wasm-of-ocaml-6-4/18282
- Native effects PR: https://github.com/ocsigen/js_of_ocaml/pull/1832
- js_of_ocaml source read for the JSPI mechanism: `runtime/wasm/effect.wat`, `runtime/wasm/runtime.js`, `compiler/tests-jsoo/lib-effects/` at commit 2931400
- Lwt 6 / lwt_direct: https://discuss.ocaml.org/t/ann-lwt-6-0-0-beta-direct-style-multi-domain-parallelism/17283, https://ocaml.org/p/lwt_direct/6.0.0/index.html
- cmarkit: https://github.com/dbuenzli/cmarkit

---

## 9. Status and deviations (implementation, 2026-11-23)

Built and running: `bench/switch`, `bench/await`, `app/` (+ `app/search`
plugin), `spike/`, the runner (`runner/`, `tools/run.py`, `tools/matrix.py`,
`tools/aggregate.py`), all in `release-*` and `debug-*` for jspi/cps/native.
Checksums agree across modes, variants and engines (Chrome 157, node 24,
macOS 27 system JSC).

Where the implementation departed from the plan, and why:

- **No runtime patches.** The direct-await primitive is a user `.wat`
  (`lib/jspi/jspi.wat`) importing a `//Provides:` JS value that *is* a
  `WebAssembly.Suspending` object (`lib/jspi/jspi.js`). wasm_of_ocaml links
  user `.wat` against its runtime as module `env`, and builds the `js` import
  object from provided values, so the Suspending import reaches Wasm with no
  JS frame in between. Stock wasm_of_ocaml 6.5.0.
- **lwt_direct replaced by `lib/fiber`.** Phase 0 (`spike/`) confirmed that
  under `--effects=jspi`, resuming a continuation from a JS callback throws
  `SuspendError: trying to suspend without WebAssembly.promising` (every
  switch is a Suspending call, and callbacks are not on a promising stack).
  Lwt wakes continuations from promise callbacks, so it cannot work there.
  `lib/fiber` never resumes from a callback: callbacks queue completions, and
  the scheduler either blocks the root promising stack with a direct JSPI
  await (jspi) or is re-entered from the callback (cps, native, where that
  is legal; native re-enables effects in `$resume_fiber`).
- **The search plugin is a second program loaded by `<script>`** (code
  splitting), not Dynlink. With whole-program DCE it is ~0.6 MB, not
  multi-MB, so `module-load` defaults to the largest module available and
  takes `module=` for any other. A genuinely large real module (the OCaml
  toplevel, as on ocaml.org/play) is the natural next step if module-load
  turns out to matter.
- **Async dynlink patch dropped** for the same reason. module-load compares
  `WebAssembly.compile` awaited through each strategy against sync
  `new WebAssembly.Module`.
- **Native runs on Chrome only.** Node 24's V8 rejects wasm_of_ocaml's
  stack-switching opcodes; Chrome 157 needs `--js-flags=--wasm-wasmfx` (the
  flag was renamed from `--experimental-wasm-wasmfx`).
- **Debug builds**: every OCaml module (ours, cmarkit, yojson, uucp, uunf,
  js_of_ocaml, stdlib) carries an inline source map with embedded sources
  (`tools/check_debug.py`). The prebuilt wasm_of_ocaml runtime gets names
  (`--debug-info` in `build_runtime_flags`) but no source map; its `.wat`
  sources are in `_tools/src/wasm_of_ocaml-compiler/runtime/wasm/`.
- **Noise**: COOP/COEP headers make pages cross-origin isolated
  (`performance.now()` at 5 µs instead of 100 µs). Every repeat runs in a
  fresh process (browser profile or shell). CPU frequency pinning is not
  automated here: follow the host's benchmarking rules when taking real
  numbers.

### Update (same day): parity, no-effects mode, profiling

- **Chrome-works/JSC-fails = bug**, each with a minimal standalone repro in
  `repro/` (`repro/run.sh`), and `tools/parity.py` checking every build:
  - `jspi-cross-instance-tail-call`: JSPI stack scan rejects the
    RestoreFrame JSC inserts for cross-instance tail calls
    (`EvacuatedStack.cpp`, "unrecognized type of Wasm frame:
    RestoreFrameMode"). Breaks all `debug-jspi` builds (separate compilation
    tail-calls into the runtime module). Present in trunk as of Oct 10.
  - `module-exports`: `WebAssembly.Module.exports` type reflection throws on
    GC reference types. Safari 27.0.1 only.
- **`none` mode** (`--effects=disabled`): the no-effects build, so the cost
  of effects support to ordinary code shows (cps's direct code is ~2x slower).
- **Profiling**: workloads signpost every timed iteration; `tools/profile.py`
  records N fresh runs under samply (launch + JITDump for a WebKit-build
  jsc, attach for the arm64e system jsc and Chrome renderers), and
  `tools/stitch.py` keeps only signposted samples, pooled per span across
  runs. `tools/top.py` prints a symbolicated report without the UI.
- **Safari automation** is left to the user (`--engines ...,safari` opens
  Safari); the agent was not permitted to drive the user's browser.
