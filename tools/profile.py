"""samply-profile N runs of a workload and stitch the signposted samples.

  python3 -I tools/profile.py --engine jsc --jsc ~/WebKit/WebKitBuild/Release/jsc \
      --profile release-jspi --w switch --runs 10 test=generator
  python3 -I tools/profile.py --engine chrome --profile release-native --w switch --runs 10
  samply load profiles/<stamp>/stitched.json.gz

Each run is a fresh process. The workload signposts every timed iteration
(and every app phase) as "<test>/<variant>"; tools/stitch.py keeps only the
samples inside those spans and pools them across runs, one thread per span
name.

How samply gets in:
  jsc, arm64 (a WebKit build)   samply launches it, with JSC_useJITDump=1 so
                                JIT/Wasm frames get names
  jsc, arm64e (the system jsc)  samply's preload has no arm64e slice: the
                                shell spins for `delay` ms and samply attaches
                                (-p). Native frames only.
  chrome                        the page holds before starting (hold=1), samply
                                attaches to every renderer, then the page goes.
                                V8 writes no perf map on macOS: JIT/Wasm frames
                                stay unnamed, native V8 frames are symbolicated.

Use a profile-able build: release-* for timing fidelity (JSC names Wasm
functions only from the name section, which release builds strip), debug-*
for names. Knobs after the options go to the workload (preset=..., test=...).
"""
import argparse
import datetime
import json
import os
import pathlib
import signal
import subprocess
import sys
import time
import urllib.parse

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import run as browser  # noqa: E402
from common import ROOT, SAMPLY, SYSTEM_JSC, ensure, jsc_env  # noqa: E402


def is_arm64e(binary):
    out = subprocess.run(["lipo", "-archs", binary], capture_output=True, text=True).stdout
    return "arm64e" in out.split()


def stop(proc, timeout=60):
    """SIGINT a samply so it writes its profile."""
    try:
        proc.send_signal(signal.SIGINT)
        proc.wait(timeout)
    except Exception:
        proc.kill()


def run_jsc(args, i, out, knobs):
    prof = out / f"run-{i}.json.gz"
    env = jsc_env(args.jsc)
    shell = [args.jsc, *args.jsc_flag, "runner/shell.js", "--", f"dist/{args.profile}/{args.w}", *knobs]
    if is_arm64e(args.jsc):
        p = subprocess.Popen(shell + ["delay=1500"], cwd=ROOT, env=env, stdout=subprocess.PIPE, text=True)
        time.sleep(0.2)
        s = subprocess.Popen([SAMPLY, "record", "--save-only", "-r", str(args.rate), "-o", str(prof), "-p", str(p.pid)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stdout, _ = p.communicate()
        stop(s)
    else:
        jit = out / f"jitdump-{i}"  # kept: samply load reads it to name JIT frames
        jit.mkdir(exist_ok=True)
        env.update(JSC_useJITDump="1", JSC_jitDumpDirectory=str(jit))
        r = subprocess.run([SAMPLY, "record", "--save-only", "-r", str(args.rate), "-o", str(prof), "--", *shell],
                           cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        stdout = r.stdout
    line = (stdout.strip().splitlines() or [""])[-1]
    if not line.startswith("{"):
        raise SystemExit(f"run {i} failed: {line[:500]}")
    (out / f"run-{i}.result.json").write_text(line)
    return prof


def renderer_pids(user_data_dir):
    ps = subprocess.run(["ps", "-Ao", "pid=,args="], capture_output=True, text=True).stdout
    pids = []
    for l in ps.splitlines():
        if user_data_dir in l and "--type=renderer" in l and "--top-chrome-webui" not in l \
                and "--extension-process" not in l:
            pids.append(int(l.split()[0]))
    return pids


def run_chrome(args, i, out, knobs):
    srv = browser.serve()
    port = srv.server_address[1]
    q = {"w": args.w, "profile": args.profile, "post": "1", "hold": "1",
         **dict(k.split("=", 1) for k in knobs)}
    url = f"http://127.0.0.1:{port}/runner/run.html?" + urllib.parse.urlencode(q)
    ns = argparse.Namespace(browser="chrome", chrome=args.chrome, cmd="", headless=not args.headed,
                            js_flag=[], profile=args.profile)
    proc, udd = browser.launch(ns, url)
    try:
        if not srv.ready.wait(120):
            raise SystemExit(f"run {i}: page never became ready")
        samplers = []
        for pid in renderer_pids(udd):
            f = out / f"run-{i}-r{pid}.json.gz"
            samplers.append((f, subprocess.Popen(
                [SAMPLY, "record", "--save-only", "-r", str(args.rate), "-o", str(f), "-p", str(pid)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)))
        time.sleep(1.0)  # let samply attach
        srv.go.set()
        if not srv.got.wait(args.timeout):
            raise SystemExit(f"run {i}: no result")
        for _, s in samplers:
            stop(s)
    finally:
        os.killpg(proc.pid, signal.SIGTERM)
        srv.shutdown()
    res = srv.results[0]
    if res["kind"] != "done":
        raise SystemExit(f"run {i} failed: {res['payload'][:500]}")
    # The page's renderer is the profile with the most samples; keep that one.
    best = max((f for f, _ in samplers if f.exists()), key=lambda f: f.stat().st_size)
    for f, _ in samplers:
        if f != best and f.exists():
            f.unlink()
    prof = out / f"run-{i}.json.gz"
    best.rename(prof)
    (out / f"run-{i}.result.json").write_text(res["payload"])
    return prof


def stitch(out, runs, span):
    stitched = out / "stitched.json.gz"
    subprocess.run([sys.executable, "-I", str(ROOT / "tools/stitch.py"), str(stitched), *runs,
                    *(["--span", span] if span else [])], check=True)
    return stitched, json.loads((out / "stitched.summary.json").read_text())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engine", choices=["jsc", "chrome"], required=True)
    ap.add_argument("--jsc", default=SYSTEM_JSC)
    ap.add_argument("--jsc-flag", action="append", default=[])
    ap.add_argument("--chrome", default=browser.CHROME)
    ap.add_argument("--headed", action="store_true")
    ap.add_argument("--profile", required=True)
    ap.add_argument("--w", required=True, choices=["micro", "switch", "await", "app"])
    ap.add_argument("--runs", type=int, default=5, help="runs to start with")
    ap.add_argument("--min-samples", type=int, default=10000,
                    help="keep adding runs until every non-baseline section has this many samples")
    ap.add_argument("--max-runs", type=int, default=50)
    ap.add_argument("--rate", type=int, default=4000, help="samples/s")
    ap.add_argument("--span", default="", help="regex of span names to keep")
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--out")
    ap.add_argument("knobs", nargs="*")
    args = ap.parse_args()
    if args.engine == "jsc" and args.w == "app":
        raise SystemExit("the app needs a browser")
    ensure(args.profile)
    # Profiling wants long runs: more timed iterations per run by default.
    if not any(k.startswith("iters=") for k in args.knobs):
        args.knobs.append("iters=30")

    out = pathlib.Path(args.out or ROOT / "profiles" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    out.mkdir(parents=True, exist_ok=True)
    runs = []

    def record(i):
        f = (run_jsc if args.engine == "jsc" else run_chrome)(args, i, out, args.knobs)
        print(f"run {i}: {f}", flush=True)
        runs.append(str(f))

    for i in range(args.runs):
        record(i)
    stitched, summary = stitch(out, runs, args.span)
    # Each run adds about the same number of samples per section: estimate
    # how many more runs the thinnest section needs, add them, re-stitch.
    while True:
        low = {k: v for k, v in summary["sections"].items()
               if v["samples"] < args.min_samples and not v["baseline"]}
        if not low or len(runs) >= args.max_runs:
            break
        per_run = min(max(v["samples"], 1) / len(runs) for v in low.values())
        more = min(args.max_runs - len(runs), max(1, int(args.min_samples / per_run) - len(runs) + 1))
        print(f"\n{len(low)} section(s) under {args.min_samples} samples "
              f"({', '.join(f'{k}={v['samples']}' for k, v in low.items())}): {more} more run(s)", flush=True)
        for _ in range(more):
            record(len(runs))
        stitched, summary = stitch(out, runs, args.span)

    print(f"\nstitched {len(runs)} runs:")
    ok = True
    for name, v in summary["sections"].items():
        enough = v["samples"] >= args.min_samples
        flag = "baseline" if v["baseline"] else ("ok" if enough else f"LOW (< {args.min_samples})")
        ok &= enough or v["baseline"]
        print(f"  {name:28} {v['samples']:8} samples  {v['spans']:4} spans  {v['ms']:9.1f} ms  "
              f"{v['samples'] / max(v['ms'], 1e-9) * 1000:7.0f} samples/s  {flag}")
    print(f"\nsamply load {stitched}\npython3 -I tools/top.py {stitched}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
