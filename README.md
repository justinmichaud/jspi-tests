# OCaml JSPI workloads

OCaml (wasm_of_ocaml 6.5) workloads that use JSPI in two ways: to await JS
promises, and as the substrate for OCaml effects (stack switching). Each one
builds in four modes:

| mode | effects via | runs on |
|---|---|---|
| `jspi` | JSPI | Chrome, JSC/Safari |
| `native` | Wasm stack switching (WasmFX) | Chrome only (`--wasm-wasmfx`) |
| `cps` | CPS transform | everywhere |
| `none` | disabled (`--effects=disabled`): no-effects baseline | everywhere; no app |

Each mode has two flavours. `release-*` is timed: whole program, `--opt=3`,
stripped. `debug-*` uses separate compilation, keeps names, and has source maps
with embedded sources.

## Self-contained
Every command installs what it needs into `_tools/` on first use, then builds
what's missing or stale. Nothing is installed globally; `rm -rf _tools`
undoes it.
- **Pinned and sha256-checked:** opam with OCaml 5.4.1 and every package,
  from `opam/switch.export` (full definitions, frozen); Binaryen 133; samply
  0.13.1; node 24.7.0; Chrome for Testing 157.0.8103.78.
- **Needs:** macOS arm64, Xcode CLT, curl, python3.
- **Network:** only at first install. The corpus is checked in, and runs are
  loopback only.

## Workloads
| | what | needs |
|---|---|---|
| `bench/micro` | one minimal case per table row, nothing else in the loop | any shell |
| `bench/switch` | effects as control flow over real work: `generator`, `pipeline` (Eio), `fibers`, `deep` | any shell |
| `bench/await` | awaits over real work: `resolved`, `micro`, `macro`, `depth`, `fanout`, `webapi`, `module-load` | `webapi`: browser |
| `app/` | docs reader: fetch, `crypto.subtle`, Cache Storage, cmarkit, a lazy uucp/uunf plugin, DOM events | browser |

Variants:
- `effects` vs `direct`: the no-effects twin of a switch test.
- `direct`: one JSPI `Suspending` call per await (jspi builds only).
- `fiber`: one effect per await.
- `callback`: `.then` chains, no switching.
- `nosuspend`: the same work without awaiting, the floor.

Sizes come from `preset=small|default|large`; any knob can be overridden as
`k=v`. Checksums must match across variants, modes and engines.

## The table (one command)
```sh
python3 -I tools/matrix.py [--jsc PATH] [--repeat N] [--preset P] [--engines chrome,jsc,safari]
```
- Runs Chrome × {jspi, native, cps, none} and jsc × {jspi, cps, none},
  each run in a fresh process.
- Prints two tables with the same rows: the microbenchmarks and the
  realistic workloads. Cells are ns per op over the no-switch baseline, or ms.
- Then prints `repro/run.sh` and the parity grid, and writes
  `results/<stamp>/table.md`.
- `--jsc` takes any jsc. A WebKit build's `DYLD_FRAMEWORK_PATH` is set for
  you. The default is the system jsc.
- `safari` opens Safari with `open -a`; close the tabs yourself.

## Bugs (works in Chrome, not in JSC/Safari)
```sh
repro/run.sh [jsc]          # minimal standalone cases, PASS/FAIL per engine
python3 -I tools/parity.py  # every build x workload x engine; maps failures to repro/
```
- `jspi-cross-instance-tail-call`: a JSPI suspend under a cross-instance
  `return_call` fails with `RestoreFrameMode`. Breaks every `debug-jspi`
  build. Still in trunk (Oct 10).
- `module-exports`: `Module.exports` throws on GC-typed signatures. Seen in
  Safari 27.0.1; fixed in trunk.

## Profiling (samply, signposted, stitched)
```sh
python3 -I tools/profile.py --engine jsc|chrome [--jsc PATH] --profile release-jspi --w micro [test=generator]
python3 -I tools/top.py profiles/<stamp>/stitched.json.gz   # symbolicated CLI report
samply load profiles/<stamp>/stitched.json.gz              # UI
```
- **Signposts:** every timed iteration and app phase is a span named
  `<test>/<variant>`.
- **Stripping and stitching:** samples outside spans are dropped, and runs
  are pooled into one thread per span (`tools/stitch.py`).
- **Sample target:** runs are added until every section that isn't a
  baseline has `--min-samples` samples (default 10000; `--max-runs` 50). The
  final line per section prints `ok`, `LOW` or `baseline`, and the exit
  status is non-zero if any section is `LOW`.
- **Run length:** `iters=30` is the default. Raise `n=` or `iters=` for
  short cases.
- **WebKit-build jsc:** samply launches it with JITDump, so JIT/Wasm frames
  are named.
- **System jsc (arm64e):** samply attaches, so native frames only.
- **Chrome:** the page holds until samply has attached to the renderer.
  Chrome's frames are stripped, and V8 writes no perf map on macOS.
- **Wasm function names:** use `debug-*` builds.

## One-off runs
```sh
_tools/node/bin/node --experimental-wasm-jspi runner/shell.js dist/release-jspi/micro preset=small
$JSC runner/shell.js -- dist/release-cps/await test=resolved
python3 -I tools/run.py --profile release-native --w app --headless [--repeat N]
python3 -I tools/run.py --browser cmd --cmd '/path/MiniBrowser --url {url}' --profile release-jspi --w app
```

## Noise
- **Inputs:** fixed sizes and data, loaded before timing; checksums are
  verified outside timing.
- **Network:** loopback only, `no-store`, and COOP/COEP so the timer has 5 µs
  resolution.
- **Processes:** a fresh process or browser profile per run, with warmup
  discarded.
- **Load:** the matrix warns when the load average is above 2.
- **CPU frequency** is not pinned: pin it yourself for real numbers.

`plan.md` covers the design and how the implementation differs from it.
