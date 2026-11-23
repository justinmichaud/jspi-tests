# JSPI profile analysis (2026-11-23)

The `bench/micro` suite, `release-jspi`/`release-native`, profiled with
samply. Only signposted samples are kept, pooled per section across runs.

| config | engine | runs | samples per measured section |
|---|---|---|---|
| jsc jspi | WebKit trunk 5b65d918e3c7, Release `jsc`, launch mode + JITDump | 19 | 10k–780k |
| chrome jspi | Chrome for Testing 157.0.8103.78, attached | 50 | 47k–356k |
| chrome native | same, `--wasm-wasmfx` | 50 | 49k–231k |

All measured sections passed 10k samples except `module-load/fiber` on
Chrome. V8 compiles off the main thread, so the sampled thread is idle there.

Reproduce:
```sh
python3 -I tools/profile.py --engine jsc --jsc ~/Development/WebKit/WebKitBuild/Release/jsc --profile release-jspi --w micro --runs 3 --out profiles/analysis/jsc-jspi
python3 -I tools/profile.py --engine chrome --profile release-{jspi,native} --w micro --runs 3 --out profiles/analysis/chrome-{jspi,native}
python3 -I tools/top.py profiles/analysis/jsc-jspi/stitched.json.gz --no-flat --categories
python3 -I tools/top.py profiles/analysis/jsc-jspi/stitched.json.gz --no-flat --thread generator/effects \
    --callees runWebAssemblySuspendingFunction --callees 'SlicerDriver<JSC::SlabSlicer>::slice'
```

## Cost per operation (ns, under the profiler)

| section | jsc jspi | chrome jspi | chrome native | jsc / chrome jspi | chrome jspi / native |
|---|---|---|---|---|---|
| generator (per switch) | 751 | 128 | 24 | 5.9× | 5.3× |
| fibers (per yield) | 1717 | 299 | 76 | 5.7× | 4.0× |
| deep (per perform, 20 handlers) | 12189 | 2780 | 1015 | 4.4× | 2.7× |
| pipeline (per handoff) | 1737 | 299 | 87 | 5.8× | 3.4× |
| await resolved, direct JSPI | 917 | 167 | – | 5.5× | – |
| await resolved, fiber | 3068 | 671 | 354 | 4.6× | 1.9× |
| await microtask, fiber | 3139 | 1147 | 799 | 2.7× | 1.4× |
| await fanout ×16, fiber | 1983 | 519 | 350 | 3.8× | 1.5× |
| await resolved, `.then` callback | 237 | 160 | 197 | 1.5× | – |

- **JSC's JSPI is 4–6× slower than V8's per suspend/resume.** The gap is the
  same whether JSPI is used directly (direct await) or as the stack-switching
  substrate (generator, fibers, pipeline).
- **On Chrome, WasmFX is 3–5× faster than JSPI for switch-heavy code, and
  1.4–1.9× faster for awaits,** where promise and microtask work is shared by
  both modes.
- **Closing JSC's JSPI gap to V8 would recover more than WasmFX adds on top
  of V8's JSPI.** V8's JSPI already spends about 80% of its time in generated
  code.

## Where JSC's time goes

Self time by category, as a % of the section (`tools/top.py --categories`).
V8 symbols are stripped on macOS, so Chrome splits only into JIT code and
native.

| section | stack walk | stack copy | evacuate/restore | host fn per suspend | call/entry | malloc | promise/microtask | strings + refcount | wasm/JS JIT | other |
|---|---|---|---|---|---|---|---|---|---|---|
| generator | 28.1 | 11.3 | 5.6 | 7.2 | 4.7 | 9.2 | 4.2 | 3.0 | 10.8 | 14.7 |
| fibers | 28.2 | 13.9 | 4.9 | 6.1 | 4.2 | 7.9 | 3.8 | 3.0 | 11.4 | 15.3 |
| deep | 21.2 | 5.8 | 6.6 | 8.9 | 6.0 | 9.3 | 4.9 | 3.1 | 13.7 | 18.7 |
| pipeline | 31.8 | 12.3 | 4.8 | 5.9 | 4.1 | 7.5 | 3.7 | 3.1 | 12.0 | 13.6 |

On Chrome, the same sections run 80–82% in JIT code (jspi) and 55–65%
(native). On JSC, wasm/JS code is only 11–14%: the rest is the suspend and
resume machinery.

Under `runWebAssemblySuspendingFunction`, the generator case spends **78.5%**
of all its time. That breaks down as:

1. **Stack slicing, 46.6%** (`SlicerDriver<SlabSlicer>::slice`).
   - **Stack walk, 28%:** a full `StackVisitor` walk on every suspend. It
     includes `readInlinableNativeCalleeFrame` (9.6%),
     `PCToCodeOriginMap::findPC` (5.8%), `calleeSaveRegistersForUnwinding`
     and `unwindToMachineCodeBlockFrame`.
   - **Evacuation, 9.7%:** 4.9% `memmove` plus slice allocation.
   - The cost is per suspend, not per frame. wasm_of_ocaml fibers are
     shallow, and the await `depth` test changes little between depth 1
     and 1000. The generic visitor's per-frame code-origin lookups are what
     cost.
2. **`Interpreter::executeCall`, 14.7%:** the function wrapped by
   `WebAssembly.Suspending` is called through a full VM re-entry, every
   suspend.
3. **Two new JS functions per suspend, 11.6%:**
   `createPinballCompletion{Fulfill,Reject}Handler`. Each goes through
   `VM::getHostFunction`, which looks the `NativeExecutable` up in `JITThunks`'
   weak hash map (`WeakNativeExecutableHash::hash` alone is 4.8%). Each also
   allocates a `JSFunctionWithFields` and a name string.
4. **Resume:** `pinballHandlerImplantSlice` copies the slice back (6.8%,
   mostly `memmove`). The promise reaction and microtask hop add about 4%.
5. **Overall:**
   - `malloc`/`free` is 8–9%: slice `unique_ptr`s, `Vector` growth, strings.
   - `StringImpl` create and destroy is about 2%, even on the success path.
   - Refcount churn on `Wasm::NameSection` is about 1.2%.

## What would close the gap (ranked by share of time)

1. **Avoid the generic stack walk on suspend, about 28%.**
   - Every frame between `WasmToJS` and the promising entry is a Wasm frame
     that JSC itself laid out.
   - The slicer could walk the frame-pointer chain and classify callees
     cheaply, without `StackVisitor`'s inline-frame and code-origin
     machinery.
   - Better still, record the promising entry's stack bounds so the slab is
     known without walking.
2. **Stop copying the stack twice per switch, about 11%.**
   - Slab slicing evacuates on suspend and implants on resume.
   - V8 instead runs each promising call on its own secondary stack and
     switches the stack pointer.
   - A separate stack per promising context (allocated lazily, pooled) would
     remove both copies, the slice allocation, and most of items 1 and 5.
3. **Cache or eliminate the per-suspend handler functions, about 12%.**
   - Fetch each `NativeExecutable` once per VM, not per suspend.
   - Better, resume through an internal promise reaction (`InternalMicrotask`
     with the `PinballCompletion` as context) instead of two JS function
     objects.
4. **Call the Suspending target without `Interpreter::executeCall`, about
   15%.** A direct JIT call from the Wasm-to-JS path, like other imports,
   would avoid a VM entry per suspend.
5. **Smaller items, about 10% together:**
   - Build error-message strings only on failure.
   - Avoid `NameSection` ref/deref per frame.
   - Keep slice vectors inline.

Items 1–4 are each larger than the whole JIT-code share. If they were fixed
by switching stacks the way V8 does, JSC's JSPI should land near V8's
128 ns/switch. That would leave Wasm stack switching's advantage at V8's 3–5×
on switch-heavy code, and under 2× on await-heavy code.
