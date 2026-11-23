"""Aggregate result files across repeated runs (each a fresh process).

  python3 -I tools/aggregate.py results/<stamp>/*.jsonl            # every cell
  python3 -I tools/aggregate.py --table results/<stamp>/*.jsonl    # the table

Every number is the median over runs of each run's median sample. The full
listing shows [min..max] over runs, so run-to-run noise is visible.

The table's "per op" rows are the extra time per switch/await over the
same test's no-switch baseline (switch: the `direct` twin; await: the
`nosuspend` floor), in ns. The "no effects" rows are absolute ms of code that
performs no effects at all, which is what each mode costs ordinary code.
"""
import collections
import json
import statistics
import sys

# (label, workload, test, variant, kind) kind: "op" = ns/op over baseline,
# "opms" = ms over baseline, "ms" = absolute
ROWS = [
    ("generator, per switch", "switch", "generator", "effects", "op"),
    ("fibers, per yield", "switch", "fibers", "effects", "op"),
    ("deep handlers, per perform", "switch", "deep", "effects", "op"),
    ("pipeline (Eio), total over no-effects", "switch", "pipeline", "effects", "opms"),
    ("await resolved: direct JSPI", "await", "resolved", "direct", "op"),
    ("await resolved: fiber (effect)", "await", "resolved", "fiber", "op"),
    ("await resolved: callback (no switch)", "await", "resolved", "callback", "op"),
    ("await microtask: fiber", "await", "micro", "fiber", "op"),
    ("await fanout x16: fiber", "await", "fanout", "fiber", "op"),
    ("no effects: generator twin, ms", "switch", "generator", "direct", "ms"),
    ("no effects: pipeline twin, ms", "switch", "pipeline", "direct", "ms"),
    ("no effects: await floor, ms", "await", "resolved", "nosuspend", "ms"),
    ("module-load: sync compile, ms", "await", "module-load", "sync", "ms"),
    ("app: total per iteration, ms", "app", "total", "fiber", "ms"),
    ("app: boot, ms", "app", "boot", "fiber", "ms"),
]
# bench/micro: one minimal case per row (same labels)
MICRO_ROWS = [
    ("generator, per switch", "micro", "generator", "effects", "op"),
    ("fibers, per yield", "micro", "fibers", "effects", "op"),
    ("deep handlers, per perform", "micro", "deep", "effects", "op"),
    ("pipeline, per handoff", "micro", "pipeline", "effects", "op"),
    ("await resolved: direct JSPI", "micro", "await-resolved", "direct", "op"),
    ("await resolved: fiber (effect)", "micro", "await-resolved", "fiber", "op"),
    ("await resolved: callback (no switch)", "micro", "await-resolved", "callback", "op"),
    ("await microtask: fiber", "micro", "await-micro", "fiber", "op"),
    ("await fanout x16: fiber", "micro", "await-fanout", "fiber", "op"),
    ("no effects: generator loop, ms", "micro", "generator", "direct", "ms"),
    ("no effects: await floor, ms", "micro", "await-resolved", "nosuspend", "ms"),
    ("module-load: sync compile, ms", "micro", "module-load", "sync", "ms"),
    ("module-load: compile awaited in a fiber, ms", "micro", "module-load", "fiber", "ms"),
]
MODES = ["jspi", "native", "cps", "none"]


def runs(paths):
    for p in paths:
        for line in open(p):
            line = line.strip()
            if not line.startswith("{"):
                if line:
                    print(f"{p}: {line[:200]}", file=sys.stderr)
                continue
            obj = json.loads(line)
            if "payload" in obj:  # browser envelope from tools/run.py
                if obj.get("kind") != "done":
                    print(f"{p}: FAILED {obj.get('payload', '')[:200]}", file=sys.stderr)
                    continue
                engine = obj.get("engine", "browser")
                obj = json.loads(obj["payload"])
                obj["engine"] = engine
            yield obj


def load(paths):
    # (engine, workload, test) -> effects -> variant -> [run medians]
    table = collections.defaultdict(lambda: collections.defaultdict(lambda: collections.defaultdict(list)))
    ops = {}
    for r in runs(paths):
        engine = r.get("engine", "?").split(" (")[0].split()[0]
        for res in r["results"]:
            key = (engine, r["workload"], res["test"])
            table[key][r["effects"]][res["variant"]].append(statistics.median(res["samples_ms"]))
            c = res.get("counters", {})
            n = c.get("ops") or c.get("switches") or c.get("awaits") or c.get("yields") or c.get("performs")
            if n:
                ops[key] = n
    return table, ops


def cell(table, ops, engine, mode, w, test, variant, kind):
    vs = table.get((engine, w, test), {}).get(mode)
    if not vs or variant not in vs:
        return None
    med = statistics.median(vs[variant])
    if kind == "ms":
        return med
    base_name = "nosuspend" if (w == "await" or test.startswith("await")) else "direct"
    if base_name not in vs:
        return None
    over = med - statistics.median(vs[base_name])
    if kind == "opms":
        return over
    n = ops.get((engine, w, test))
    return over * 1e6 / n if n else None


def print_table(table, ops, rows=ROWS):
    engines = sorted({k[0] for k in table}, key=lambda e: (e != "chrome", e))
    cols = [(e, m) for e in engines for m in MODES
            if any(m in table[k] for k in table if k[0] == e)]
    print("| | " + " | ".join(f"{e} {m}" for e, m in cols) + " |")
    print("|" + "---|" * (len(cols) + 1))
    for label, w, test, variant, kind in rows:
        vals = [cell(table, ops, e, m, w, test, variant, kind) for e, m in cols]
        if all(v is None for v in vals):
            continue
        fmt = (lambda v: f"{v:.0f}") if kind == "op" else (lambda v: f"{v:.2f}")
        unit = " (ns)" if kind == "op" else (" (ms)" if kind == "opms" else "")
        print(f"| {label}{unit} | " + " | ".join("–" if v is None else fmt(v) for v in vals) + " |")


def print_all(table):
    print("median of per-run medians, ms  [min..max over runs]  (runs)")
    for key in sorted(table):
        engine, w, test = key
        for eff in sorted(table[key]):
            for variant, meds in sorted(table[key][eff].items()):
                m = statistics.median(meds)
                print(f"  {engine:8} {w:7} {test:12} {eff:7} {variant:10} {m:10.3f}  [{min(meds):.3f}..{max(meds):.3f}]  ({len(meds)})")


def main():
    args = sys.argv[1:]
    paths = [a for a in args if a != "--table"]
    table, ops = load(paths)
    if "--table" not in args:
        print_all(table)
        print()
    if any(k[1] != "micro" for k in table):
        print("realistic workloads (bench/switch, bench/await, app):\n")
        print_table(table, ops)
    if any(k[1] == "micro" for k in table):
        print("\nmicrobenchmarks (bench/micro, one minimal case per row):\n")
        print_table(table, ops, MICRO_ROWS)


if __name__ == "__main__":
    main()
