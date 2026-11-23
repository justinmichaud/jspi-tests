"""Parity check: everything that runs in Chrome must run in JSC/Safari.

  python3 -I tools/parity.py [--jsc PATH] [--engines chrome,jsc[,safari]]

Runs every built profile (release and debug, every mode) x workload once at
preset=small on each engine and prints a pass/fail grid. A cell that passes in
Chrome and fails elsewhere is a bug; known ones point at their minimal repro
in repro/ (repro/run.sh runs those alone). Native mode is skipped off Chrome:
WasmFX is the feature under evaluation, not a bug. Exit status 1 if any
unexplained difference.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import NODE, ROOT, SYSTEM_JSC, ensure, jsc_env  # noqa: E402
KNOWN = {
    "unrecognized type of Wasm frame: RestoreFrameMode": "repro/jspi-cross-instance-tail-call",
    "unable to produce export descriptors": "repro/module-exports",
}
QUICK = ["preset=small", "warmup=0", "iters=1"]


def run(engine, profile, w, jsc):
    if engine in ("chrome", "safari"):
        cmd = [sys.executable, "-I", str(ROOT / "tools/run.py"), "--browser", engine, "--profile", profile,
               "--w", w, "--timeout", "300", *(["--headless"] if engine == "chrome" else []), *QUICK]
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if r.returncode == 0:
            return True, ""
        return False, (r.stderr.strip().splitlines() or ["?"])[-1]
    cmd = [jsc, "runner/shell.js", "--"] if engine == "jsc" else [NODE, "--experimental-wasm-jspi", "runner/shell.js"]
    try:
        r = subprocess.run(cmd + [f"dist/{profile}/{w}", *QUICK], cwd=ROOT, capture_output=True, text=True,
                           timeout=600, env=jsc_env(jsc) if engine == "jsc" else None)
        line = (r.stdout.strip().splitlines() or ["FAILED: no output"])[-1]
    except subprocess.TimeoutExpired:
        line = "FAILED: timeout"
    return line.startswith("{"), "" if line.startswith("{") else line


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engines", default="chrome,jsc")
    ap.add_argument("--jsc", default=SYSTEM_JSC)
    args = ap.parse_args()
    engines = args.engines.split(",")
    ensure(*[f"{f}-{m}" for f in ("release", "debug") for m in ("jspi", "native", "cps", "none")])
    profiles = sorted(p.name for p in (ROOT / "dist").iterdir() if p.is_dir())
    bad = 0
    print(f"{'profile':16} {'workload':8} " + " ".join(f"{e:8}" for e in engines))
    for profile in profiles:
        for w in ("micro", "switch", "await", "app"):
            if not (ROOT / "dist" / profile / w).exists():
                continue
            cells, errs = [], {}
            for e in engines:
                if (e in ("jsc", "node") and w == "app") or (e != "chrome" and profile.endswith("-native")):
                    cells.append("-")
                    continue
                ok, err = run(e, profile, w, args.jsc)
                cells.append("pass" if ok else "FAIL")
                if not ok:
                    errs[e] = err
            print(f"{profile:16} {w:8} " + " ".join(f"{c:8}" for c in cells), flush=True)
            if "chrome" in engines and cells[engines.index("chrome")] != "pass":
                for e, err in errs.items():
                    print(f"    {e}: {err[:200]}")
                continue
            for e, err in errs.items():
                repro = next((r for k, r in KNOWN.items() if k in err), None)
                if repro:
                    print(f"    BUG {e}: {repro}  ({err[:120]})")
                else:
                    bad += 1
                    print(f"    BUG {e} (NO REPRO YET): {err[:300]}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
