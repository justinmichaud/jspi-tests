"""Summarise benchmark result JSON (one object per line, or a results dir).

  python3 -I tools/summary.py results/*.jsonl
  node runner/shell.js ... | python3 -I tools/summary.py -

Prints per test/variant: median and min ms, and for the effects variant the
overhead over its direct twin (per switch when the test reports a switch
count).
"""
import json
import statistics
import sys


def load(paths):
    for p in paths:
        f = sys.stdin if p == "-" else open(p)
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("FAILED"):
                print(line)
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "payload" in obj:  # browser POST envelope
                if obj.get("kind") != "done":
                    print("FAILED:", obj.get("payload", "")[:2000])
                    continue
                meta = {k: obj.get(k) for k in ("ua", "engine")}
                obj = json.loads(obj["payload"])
                obj.update({k: v for k, v in meta.items() if v})
            yield obj


def main():
    for run in load(sys.argv[1:] or ["-"]):
        engine = run.get("engine") or run.get("ua") or ""
        print(f"# {run['workload']}  profile={run['profile']}  {engine}")
        by_test = {}
        for r in run["results"]:
            by_test.setdefault(r["test"], {})[r["variant"]] = r
        for test, variants in by_test.items():
            for name, r in variants.items():
                s = r["samples_ms"]
                med = statistics.median(s)
                line = f"  {test:12} {name:9} median {med:10.3f} ms  min {min(s):10.3f}  n={len(s)}  checksum={r['checksum']}"
                # await: compare against the nosuspend floor; switch: against
                # the no-effects direct twin.
                bname = "nosuspend" if "nosuspend" in variants else "direct"
                base = variants.get(bname)
                if name != bname and base:
                    bmed = statistics.median(base["samples_ms"])
                    over = med - bmed
                    line += f"  overhead {over:9.3f} ms"
                    sw = r["counters"].get("ops") or r["counters"].get("switches") or r["counters"].get("awaits") or r["counters"].get("yields") or r["counters"].get("performs")
                    if sw:
                        line += f"  ({over * 1e6 / sw:8.1f} ns/op over {sw} ops)"
                print(line)
                extra = {k: v for k, v in r["counters"].items()}
                if extra:
                    print(f"  {'':12} {'':9} {extra}")


if __name__ == "__main__":
    main()
