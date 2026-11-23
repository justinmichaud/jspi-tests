"""Keep only signposted samples from samply profiles and stitch runs together.

  python3 -I tools/stitch.py OUT.json.gz RUN.json.gz[:RESULT.json] ... [--span REGEX] [--thread NAME]

Each RUN is a samply profile (processed format, as `samply record --save-only`
writes it). Its RESULT is the workload's result JSON (default: RUN with
.json.gz replaced by .result.json), whose "spans" are signposts
[name, startEpochMs, endEpochMs].

From each run, keep the samples of one thread (the one with the most samples
inside spans, unless --thread picks one by name) that fall inside a span.
Then pool them across runs into one output thread per span name, laid end to
end, with a marker per span occurrence. One section's samples from many runs
end up in one call tree: resolution comes from the number of runs, not the
length of any one run.

Open the result with `samply load OUT.json.gz` (symbolication needs the
binaries that were profiled, so do it on the same machine).
"""
import argparse
import collections
import gzip
import json
import re
import sys

GAP_MS = 0.5  # between stitched spans


class Merger:
    """Accumulates threads' tables into one, deduplicating rows."""

    def __init__(self, libs):
        self.libs, self.lib_index = libs, {}
        self.strings, self.string_index = [], {}
        self.tables = {k: collections.defaultdict(list) for k in
                       ("resourceTable", "nativeSymbols", "funcTable", "frameTable", "stackTable")}
        self.index = {k: {} for k in self.tables}

    def lib(self, lib):
        key = json.dumps(lib, sort_keys=True)
        if key not in self.lib_index:
            self.lib_index[key] = len(self.libs)
            self.libs.append(lib)
        return self.lib_index[key]

    def string(self, s):
        if s not in self.string_index:
            self.string_index[s] = len(self.strings)
            self.strings.append(s)
        return self.string_index[s]

    def add_row(self, table, row):
        key = tuple(json.dumps(v) for v in row.values())
        idx = self.index[table].get(key)
        if idx is None:
            t = self.tables[table]
            idx = len(t["_rows"]) if "_rows" in t else 0
            for k, v in row.items():
                t[k].append(v)
            t["_rows"].append(None)
            self.index[table][key] = idx
        return idx

    def import_thread(self, profile, th):
        """Returns a function mapping the thread's stack index to ours."""
        libs = profile["libs"]
        sa = th["stringArray"]
        S = lambda i: None if i is None else self.string(sa[i])
        L = lambda i: None if i is None or i < 0 else self.lib(libs[i])

        def cols(t):
            return [k for k in t if k != "length"]

        # keep every column of the schema, even for tables with no rows
        for name, key in (("resourceTable", "resourceTable"), ("nativeSymbols", "nativeSymbols"),
                          ("funcTable", "funcTable"), ("frameTable", "frameTable"), ("stackTable", "stackTable")):
            for c in cols(th.get(key, {})):
                self.tables[name][c]
            self.tables[name]["_rows"]

        rt = th["resourceTable"]
        res = []
        for i in range(rt["length"]):
            row = {k: rt[k][i] for k in cols(rt)}
            if "lib" in row:
                row["lib"] = L(row["lib"])
            for k in ("name", "host"):
                if k in row:
                    row[k] = S(row[k])
            res.append(self.add_row("resourceTable", row))

        ns = th.get("nativeSymbols", {"length": 0})
        nat = []
        for i in range(ns["length"]):
            row = {k: ns[k][i] for k in cols(ns)}
            row["libIndex"] = L(row["libIndex"])
            row["name"] = S(row["name"])
            nat.append(self.add_row("nativeSymbols", row))

        ft = th["funcTable"]
        funcs = []
        for i in range(ft["length"]):
            row = {k: ft[k][i] for k in cols(ft)}
            row["name"] = S(row["name"])
            if row.get("fileName") is not None:
                row["fileName"] = S(row["fileName"])
            r = row.get("resource", -1)
            row["resource"] = res[r] if r is not None and r >= 0 else -1
            funcs.append(self.add_row("funcTable", row))

        fr = th["frameTable"]
        frames = []
        for i in range(fr["length"]):
            row = {k: fr[k][i] for k in cols(fr)}
            row["func"] = funcs[row["func"]]
            if row.get("nativeSymbol") is not None:
                row["nativeSymbol"] = nat[row["nativeSymbol"]]
            if isinstance(row.get("implementation"), int):
                row["implementation"] = S(row["implementation"])
            frames.append(self.add_row("frameTable", row))

        st = th["stackTable"]
        stacks = []
        for i in range(st["length"]):
            row = {k: st[k][i] for k in cols(st)}
            row["frame"] = frames[row["frame"]]
            if row["prefix"] is not None:
                row["prefix"] = stacks[row["prefix"]]
            stacks.append(self.add_row("stackTable", row))
        return lambda s: None if s is None else stacks[s]

    def table(self, name):
        t = {k: v for k, v in self.tables[name].items() if k != "_rows"}
        t["length"] = len(self.tables[name].get("_rows", []))
        return t


def load_run(arg):
    path, _, result = arg.partition(":")
    result = result or re.sub(r"\.json\.gz$", "", path) + ".result.json"
    prof = json.load(gzip.open(path))
    res = json.load(open(result))
    if "payload" in res:  # browser envelope
        res = json.loads(res["payload"])
    return path, prof, res.get("spans", [])


def thread_samples(prof, th, spans):
    """(sample index, epoch ms) of th's samples inside any span."""
    t0 = prof["meta"]["startTime"]
    times = th["samples"].get("time")
    if times is None:
        times, acc = [], 0.0
        for d in th["samples"]["timeDelta"]:
            acc += d
            times.append(acc)
    return [(i, t0 + t) for i, t in enumerate(times)], t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--span", default="", help="regex: keep only matching span names")
    ap.add_argument("--thread", default="", help="thread name (default: busiest inside spans)")
    args = ap.parse_args()
    keep = re.compile(args.span)

    libs = []
    merger = Merger(libs)
    out_threads = collections.OrderedDict()  # span name -> dict(samples, markers, cursor)
    template = None
    for arg in args.runs:
        path, prof, spans = load_run(arg)
        spans = sorted((s for s in spans if keep.search(s[0])), key=lambda s: s[1])
        if not spans:
            print(f"{path}: no spans", file=sys.stderr)
            continue
        # pick the thread
        best = None
        for th in prof["threads"]:
            if args.thread and th["name"] != args.thread:
                continue
            ts, _ = thread_samples(prof, th, spans)
            n = 0
            j = 0
            for _, t in ts:
                while j < len(spans) and spans[j][2] < t:
                    j += 1
                if j < len(spans) and spans[j][1] <= t:
                    n += 1
            if best is None or n > best[0]:
                best = (n, th, ts)
        n, th, ts = best
        prof_end = prof["meta"]["startTime"] + (ts[-1][1] - prof["meta"]["startTime"] if ts else 0)
        covered = [s for s in spans if s[1] >= prof["meta"]["startTime"] and s[2] <= prof_end]
        print(f"{path}: thread '{th['name']}' pid {th.get('pid')}: {n} samples in {len(covered)}/{len(spans)} spans",
              file=sys.stderr)
        template = template or th
        remap = merger.import_thread(prof, th)
        stacks = th["samples"]["stack"]
        weights = th["samples"].get("weight")
        cpu = th["samples"].get("threadCPUDelta")
        j = 0
        for name, s0, s1 in covered:
            o = out_threads.setdefault(name, {"stack": [], "time": [], "weight": [], "cpu": [],
                                              "markers": [], "cursor": 0.0})
            base = o["cursor"]
            while j < len(ts) and ts[j][1] < s0:
                j += 1
            while j < len(ts) and ts[j][1] <= s1:
                i, t = ts[j]
                o["stack"].append(remap(stacks[i]))
                o["time"].append(base + (t - s0))
                o["weight"].append(weights[i] if weights else 1)
                o["cpu"].append(cpu[i] if cpu else 0)
                j += 1
            o["markers"].append((name, base, base + (s1 - s0)))
            o["cursor"] = base + (s1 - s0) + GAP_MS

    if not out_threads:
        sys.exit("nothing to write: no samples inside spans")

    threads = []
    for k, (name, o) in enumerate(out_threads.items()):
        mname = merger.string(name)
        th = {key: template[key] for key in template
              if key not in ("samples", "markers", "stackTable", "frameTable", "funcTable",
                             "resourceTable", "nativeSymbols", "stringArray")}
        th.update({
            "name": name, "tid": 1000000 + k, "isMainThread": k == 0,
            "processName": f"stitched ({len(args.runs)} runs)",
            "registerTime": 0, "unregisterTime": None, "pausedRanges": [],
            "processStartupTime": 0, "processShutdownTime": None,
            "samples": {"length": len(o["time"]), "weightType": "samples", "stack": o["stack"],
                        "time": o["time"], "weight": o["weight"], "threadCPUDelta": o["cpu"]},
            "markers": {"length": len(o["markers"]), "name": [mname] * len(o["markers"]),
                        "startTime": [m[1] for m in o["markers"]], "endTime": [m[2] for m in o["markers"]],
                        "phase": [1] * len(o["markers"]), "category": [0] * len(o["markers"]),
                        "data": [{"type": "Text", "name": name} for _ in o["markers"]]},
        })
        threads.append(th)
        print(f"  {name:28} {len(o['time']):7} samples  {len(o['markers']):4} spans  {o['cursor']:9.1f} ms",
              file=sys.stderr)
    shared = {k: merger.table(k) for k in ("resourceTable", "nativeSymbols", "funcTable", "frameTable", "stackTable")}
    for th in threads:
        th.update(shared)
        th["stringArray"] = merger.strings
    _, first, _ = load_run(args.runs[0])
    out = {k: v for k, v in first.items() if k not in ("threads", "libs", "counters", "profilerOverhead")}
    out["meta"] = dict(first["meta"], product=f"stitched: {first['meta'].get('product', '')}")
    out["libs"] = libs
    out["threads"] = threads
    with gzip.open(args.out, "wt") as f:
        json.dump(out, f)
    # Baselines (the no-switch twins) are kept for comparison but are not
    # profiling targets: <test>/nosuspend, and <test>/direct when the test also
    # has an effects variant (in await tests "direct" is the direct JSPI await).
    tests_with_effects = {n.split("/")[0] for n in out_threads if n.endswith("/effects")}
    def baseline(name):
        test, _, variant = name.partition("/")
        return variant in ("nosuspend", "sync") or (variant == "direct" and test in tests_with_effects)
    summary = {"runs": len(args.runs), "sections": {
        name: {"samples": len(o["time"]), "spans": len(o["markers"]), "ms": o["cursor"],
               "baseline": baseline(name)}
        for name, o in out_threads.items()}}
    with open(re.sub(r"\.json\.gz$", "", args.out) + ".summary.json", "w") as f:
        json.dump(summary, f, indent=1)
    print(f"wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
