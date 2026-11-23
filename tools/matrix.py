"""The one command: run the engine x mode x workload matrix and print the table.

  python3 -I tools/matrix.py                                   # Chrome + system JSC
  python3 -I tools/matrix.py --jsc ~/WebKit/WebKitBuild/Release/jsc --repeat 10
  python3 -I tools/matrix.py --engines chrome,jsc,safari       # + Safari (opens it)

Builds missing release profiles, runs every cell in a fresh process per
repeat, then writes results/<stamp>/{*.jsonl,summary.txt,table.md} and prints
the table, repro/run.sh against the same jsc, and the parity grid.

Engines: chrome (all modes; native gets --wasm-wasmfx), jsc (a shell: switch
and await; the app needs a browser; no native: JSC has no WasmFX), safari
(via `open -a Safari`; you close the tabs), node.
Modes: jspi, native, cps, none (--effects=disabled: the no-effects build; no app).
"""
import argparse
import datetime
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import NODE, ROOT, SYSTEM_JSC, chrome_version, ensure, jsc_env  # noqa: E402


def supported(engine, mode, w):
    if mode == "native" and engine != "chrome":
        return False  # WasmFX: Chrome only
    if w == "app" and (engine in ("jsc", "node") or mode == "none"):
        return False
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engines", default="chrome,jsc")
    ap.add_argument("--modes", default="jspi,native,cps,none")
    ap.add_argument("--workloads", default="micro,switch,await,app")
    ap.add_argument("--preset", default="default")
    ap.add_argument("--repeat", type=int, default=5)
    ap.add_argument("--jsc", default=SYSTEM_JSC)
    ap.add_argument("--jsc-flag", action="append", default=[])
    ap.add_argument("--headed", action="store_true", help="chrome with a window")
    ap.add_argument("--no-parity", action="store_true", help="skip tools/parity.py")
    ap.add_argument("--out")
    ap.add_argument("knobs", nargs="*")
    args = ap.parse_args()

    load = os.getloadavg()[0]
    if load > 2:
        print(f"WARNING: load average {load:.1f}: other work is running, numbers will be noisy", flush=True)

    modes = args.modes.split(",")
    ensure(*[f"release-{m}" for m in modes])

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = pathlib.Path(args.out or ROOT / "results" / stamp)
    out.mkdir(parents=True, exist_ok=True)
    knobs = [f"preset={args.preset}", *args.knobs]
    files = []
    for engine in args.engines.split(","):
        for mode in modes:
            for w in args.workloads.split(","):
                if not supported(engine, mode, w):
                    continue
                profile = f"release-{mode}"
                f = out / f"{engine}-{profile}-{w}.jsonl"
                print(f"== {engine} {profile} {w}", flush=True)
                if engine in ("chrome", "safari"):
                    cmd = [sys.executable, "-I", str(ROOT / "tools/run.py"), "--browser", engine,
                           "--profile", profile, "--w", w, "--repeat", str(args.repeat), "--out", str(f)]
                    if engine == "chrome" and not args.headed:
                        cmd.append("--headless")
                    if subprocess.run(cmd + knobs, cwd=ROOT, stdout=subprocess.DEVNULL).returncode:
                        print("   FAILED (see " + str(f) + ")")
                else:
                    if engine == "jsc":
                        base, env = [args.jsc, *args.jsc_flag, "runner/shell.js", "--"], jsc_env(args.jsc)
                    else:
                        base, env = [NODE, "--experimental-wasm-jspi", "runner/shell.js"], None
                    with open(f, "a") as fh:
                        for _ in range(args.repeat):
                            r = subprocess.run(base + [f"dist/{profile}/{w}"] + knobs, cwd=ROOT, env=env,
                                               capture_output=True, text=True)
                            line = (r.stdout.strip().splitlines() or ["FAILED: no output " + r.stderr[-500:]])[-1]
                            if engine == "jsc" and line.startswith("{"):
                                line = line.replace('"engine":"shell"', f'"engine":"jsc {args.jsc}"', 1)
                            fh.write(line + "\n")
                            if line.startswith("FAILED"):
                                print("   " + line[:300])
                files.append(f)
    agg = lambda *a: subprocess.run([sys.executable, "-I", str(ROOT / "tools/aggregate.py"), *a, *map(str, files)],
                                    capture_output=True, text=True).stdout
    (out / "summary.txt").write_text(agg())
    table = agg("--table")
    repro = subprocess.run([str(ROOT / "repro/run.sh"), args.jsc], capture_output=True, text=True).stdout
    if not args.no_parity:
        engines = ",".join(e for e in args.engines.split(",") if e != "node")
        repro += "\nparity (tools/parity.py, every build at preset=small):\n" + subprocess.run(
            [sys.executable, "-I", str(ROOT / "tools/parity.py"), "--jsc", args.jsc, "--engines", engines],
            cwd=ROOT, capture_output=True, text=True).stdout
    header = (f"preset={args.preset} repeat={args.repeat} jsc={args.jsc} load={load:.1f}\n"
              f"chrome={chrome_version()}\n")
    text = header + "\n" + table + "\nrepro/run.sh (works in Chrome/V8; must pass in JSC):\n" + repro
    (out / "table.md").write_text(text)
    print("\n" + text)
    print(f"results: {out}")


if __name__ == "__main__":
    main()
