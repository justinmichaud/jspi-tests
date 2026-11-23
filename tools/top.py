"""Text report of a (stitched) samply profile: top functions per thread.

  python3 -I tools/top.py profiles/<stamp>/stitched.json.gz [--top 25] [--thread REGEX]

Symbolicates through samply's own local symbol server (`samply load
--no-open`), so it runs on the machine that recorded the profile. For each
thread (in a stitched profile: each signposted section) prints self and
inclusive sample shares by function. Frames without a library (JIT code,
Wasm) are grouped as [jit].
"""
import argparse
import collections
import gzip
import json
import re
import socket
import subprocess
import sys
import time
import urllib.request

import pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import SAMPLY, ensure  # noqa: E402


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def symbol_server(path):
    port = free_port()
    proc = subprocess.Popen([SAMPLY, "load", "--no-open", "-P", str(port), path],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    deadline = time.time() + 60
    while time.time() < deadline:
        line = proc.stdout.readline()
        m = re.search(r"symbolServer=([^&\s]+)", line)
        if m:
            return proc, urllib.parse.unquote(m.group(1))
    proc.kill()
    raise SystemExit("samply load did not start")


def symbolicate(server, libs, addrs):
    """addrs: list of (lib index, address) -> list of function names."""
    used = sorted({l for l, _ in addrs})
    pos = {l: i for i, l in enumerate(used)}
    job = {"memoryMap": [[libs[l]["debugName"], libs[l]["breakpadId"]] for l in used],
           "stacks": [[[pos[l], a] for l, a in addrs]]}
    req = urllib.request.Request(server + "/symbolicate/v5", data=json.dumps({"jobs": [job]}).encode(),
                                 headers={"content-type": "application/json"})
    res = json.load(urllib.request.urlopen(req, timeout=300))
    out = []
    for (l, a), f in zip(addrs, res["results"][0]["stacks"][0]):
        name = f.get("function") or f"0x{a:x}"
        out.append(f"{name}  [{libs[l]['debugName']}]")
    return out


# --categories: self time bucketed by the first matching rule (JSC names; V8's
# are stripped on macOS, so Chrome mostly splits into jit / memmove / other).
CATEGORIES = [
    ("stack walk", r"StackVisitor|SlabSlicer::step|FragSlicer::step|StackSlicerFunctor|PCToCodeOriginMap|unwindTo|calleeSaveRegisters|readInlinableNativeCalleeFrame|readNonInlinedFrame|readFrame|lexicalGlobalObjectFromNativeCallee|RegisterSet::stackRegisters"),
    ("stack copy", r"_platform_memmove|memcpy|memmove"),
    ("slice evacuate/restore", r"EvacuatedStack|evacuatePendingSlice|commitPendingSlice|PinballCompletion|SlicerDriver|restoreSlice|Pinball|JSPIContext"),
    ("host fn per suspend", r"getHostFunction|WeakNativeExecutableHash|JITThunks|HashTable<JSC::Weak<JSC::NativeExecutable|JSFunctionWithFields|NativeExecutable|createPinball"),
    ("strings", r"StringImpl|WTF::equal\b|WTF::String"),
    ("promise/microtask", r"Promise|Microtask|runPromiseReactionJob|DeferredWork"),
    ("call/entry/exit", r"executeCall|JSToWasm|WasmToJS|operationJSToWasm|vmEntry|callToJavaScript|operationConvert|Interpreter::|getCallData|JSC::call\b"),
    ("malloc/free", r"^pas_|fastMalloc|fastFree|fastCompact|bmalloc|^malloc|^free|_xzm|libpas"),
    ("GC", r"Heap::|MarkedBlock|SlotVisitor|MarkedSpace|GCClient|Subspace|MarkedVector|LocalAllocator"),
    ("refcount", r"::deref\(|::ref\(|RefCounted"),
    ("wasm/JS JIT code", r"^\[jit\]|\[jit-|JSC-|Wasm|wasm-function|^0x[0-9a-f]+  \[jit"),
    ("chrome native (stripped)", r"\[Google Chrome Framework\]|\[Google Chrome for Testing Framework\]"),
    ("system libs", r"\[lib[^\]]*\.dylib\]"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("profile")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--thread", default="")
    ap.add_argument("--callees", action="append", default=[],
                    help="regex (repeatable): break the time under this function down by direct callee")
    ap.add_argument("--no-flat", action="store_true", help="only the --callees breakdowns")
    ap.add_argument("--categories", action="store_true", help="self time bucketed (see CATEGORIES)")
    args = ap.parse_args()
    ensure()
    p = json.load(gzip.open(args.profile))
    libs = p["libs"]
    proc, server = symbol_server(args.profile)
    try:
        for th in p["threads"]:
            if not re.search(args.thread, th["name"]):
                continue
            st, fr, fu, rt = th["stackTable"], th["frameTable"], th["funcTable"], th["resourceTable"]

            def key(frame):
                r = fu["resource"][fr["func"][frame]]
                lib = rt["lib"][r] if r is not None and r >= 0 else None
                return (lib, fr["address"][frame]) if lib is not None and fr["address"][frame] >= 0 else None

            self_c, incl_c, total = collections.Counter(), collections.Counter(), 0
            for s in th["samples"]["stack"]:
                if s is None:
                    continue
                total += 1
                self_c[key(st["frame"][s])] += 1
                seen = set()
                while s is not None:
                    seen.add(key(st["frame"][s]))
                    s = st["prefix"][s]
                for k in seen:
                    incl_c[k] += 1
            keys = [k for k in set(self_c) | set(incl_c) if k is not None]
            names = dict(zip(keys, symbolicate(server, libs, keys))) if keys else {}

            def by_name(c):
                agg = collections.Counter()
                for k, n in c.items():
                    agg[names.get(k, "[jit]")] += n
                return agg

            # inclusive by name must not double count a function seen at
            # several addresses in one stack: recompute per sample by name
            incl_name = collections.Counter()
            for s in th["samples"]["stack"]:
                if s is None:
                    continue
                seen = set()
                while s is not None:
                    seen.add(names.get(key(st["frame"][s]), "[jit]"))
                    s = st["prefix"][s]
                for n in seen:
                    incl_name[n] += 1
            print(f"\n== {th['name']}  ({total} samples)")
            if not args.no_flat:
                print("   self%  incl%  function")
                selfn = by_name(self_c)
                for n, c in selfn.most_common(args.top):
                    print(f"  {100 * c / total:6.1f} {100 * incl_name[n] / total:6.1f}  {n}")
                print("   top inclusive (frames in >95% of samples omitted):")
                for n, c in [x for x in incl_name.most_common() if x[1] < 0.95 * total][: args.top]:
                    print(f"  {100 * selfn[n] / total:6.1f} {100 * c / total:6.1f}  {n}")
            if args.categories:
                rules = [(c, re.compile(r)) for c, r in CATEGORIES]
                cat = collections.Counter()
                for n, c in by_name(self_c).items():
                    cat[next((name for name, r in rules if r.search(n)), "other")] += c
                print("   self time by category:")
                for c_name, c in cat.most_common():
                    print(f"  {100 * c / total:6.1f}  {c_name}")
                others = collections.Counter({n: c for n, c in by_name(self_c).items()
                                              if not any(r.search(n) for _, r in rules)})
                if others:
                    print("   largest in other: " + "; ".join(f"{n.split('  [')[0][:50]} {100 * c / total:.1f}"
                                                         for n, c in others.most_common(6)))
            for callee_re in args.callees:
                pat = re.compile(callee_re)
                under, kids = 0, collections.Counter()
                for s0 in th["samples"]["stack"]:
                    chain = []
                    s = s0
                    while s is not None:
                        chain.append(names.get(key(st["frame"][s]), "[jit]"))
                        s = st["prefix"][s]
                    chain.reverse()  # root first
                    for i, n in enumerate(chain):
                        if pat.search(n):
                            under += 1
                            kids[chain[i + 1] if i + 1 < len(chain) else "(self)"] += 1
                            break
                if under:
                    print(f"   under /{callee_re}/: {100 * under / total:.1f}% of samples; by direct callee:")
                    for n, c in kids.most_common(args.top):
                        print(f"  {100 * c / total:6.1f}  {n}")
    finally:
        proc.terminate()


if __name__ == "__main__":
    main()
