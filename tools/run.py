"""Run a workload in a browser and collect its result.

Serves the repo root on 127.0.0.1 (no other interface, no network access
needed), opens runner/run.html with the given knobs in a *fresh* browser
process with a throwaway profile per run, waits for the page to POST its
result, then closes the browser. Results are appended as JSON lines.

  python3 -I tools/run.py --browser chrome --profile release-native --w switch \
      --repeat 5 --out results/switch.jsonl test=generator docs=200

  --browser chrome     pinned Chrome for Testing from _tools/ (JSPI on by default; native mode gets
                       --js-flags=--wasm-wasmfx automatically)
  --browser safari     Safari via `open -a` (uses your Safari profile; close
                       other tabs to keep it quiet)
  --browser cmd --cmd 'path/to/MiniBrowser --url {url}'
                       any command line; {url} is substituted
  --browser none       just serve and print the URL; open it yourself (e.g.
                       in MiniBrowser from a wk workspace), result is
                       collected all the same
"""
import argparse
import http.server
import json
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import CHROME, ROOT, ensure  # noqa: E402


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(ROOT), **kw)

    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
        ".json": "application/json",
        ".md": "text/markdown; charset=utf-8",
    }

    def end_headers(self):
        # Every run must see the same network behaviour: never cache.
        self.send_header("Cache-Control", "no-store")
        # Cross-origin isolation: browsers only give performance.now() full
        # resolution (5us rather than 100us) to isolated pages.
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        super().end_headers()

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/go":
            # The page holds here (hold=1) until a profiler has attached.
            self.server.ready.set()
            self.server.go.wait(300)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"go")
            return
        super().do_GET()

    def do_POST(self):
        if self.path != "/result":
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(204)
        self.end_headers()
        self.server.results.append(json.loads(body))
        self.server.got.set()


def serve():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    srv.results = []
    srv.got = threading.Event()
    srv.ready = threading.Event()
    srv.go = threading.Event()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def launch(args, url):
    if args.browser == "none":
        print(f"open: {url}", flush=True)
        return None, None
    if args.browser == "chrome":
        prof = tempfile.mkdtemp(prefix="jspi-chrome-")
        js_flags = list(args.js_flag)
        if args.profile.endswith("-native"):
            js_flags.append("--wasm-wasmfx")
        cmd = [
            args.chrome, f"--user-data-dir={prof}", "--no-first-run",
            "--no-default-browser-check", "--disable-extensions",
            "--disable-background-networking", "--disable-component-update",
            "--disable-sync", "--disable-default-apps",
            "--disable-background-timer-throttling",
            "--disable-renderer-backgrounding",
            "--disable-backgrounding-occluded-windows",
            "--metrics-recording-only", "--no-pings",
        ]
        if args.headless:
            cmd.append("--headless=new")
        if js_flags:
            cmd.append("--js-flags=" + " ".join(js_flags))
        cmd.append(url)
        return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True), prof
    if args.browser == "safari":
        subprocess.run(["open", "-a", "Safari", url], check=True)
        return None, None
    if args.browser == "cmd":
        cmd = [c.replace("{url}", url) for c in shlex.split(args.cmd)]
        return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True), None
    raise SystemExit("unknown browser " + args.browser)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="chrome", choices=["chrome", "safari", "cmd", "none"])
    ap.add_argument("--chrome", default=CHROME)
    ap.add_argument("--cmd", default="")
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--js-flag", action="append", default=[])
    ap.add_argument("--profile", required=True)
    ap.add_argument("--w", required=True, choices=["micro", "switch", "await", "app"])
    ap.add_argument("--repeat", type=int, default=1, help="fresh browser per repeat")
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--out")
    ap.add_argument("knobs", nargs="*", help="k=v workload parameters")
    args = ap.parse_args()

    ensure(args.profile)
    knobs = dict(k.split("=", 1) for k in args.knobs)
    srv = serve()
    port = srv.server_address[1]
    out = open(args.out, "a") if args.out else None
    failed = False
    for i in range(args.repeat):
        q = {"w": args.w, "profile": args.profile, "post": "1", **knobs}
        url = f"http://127.0.0.1:{port}/runner/run.html?" + urllib.parse.urlencode(q)
        srv.got.clear()
        n0 = len(srv.results)
        proc, prof = launch(args, url)
        ok = srv.got.wait(args.timeout)
        if proc:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(10)
            except Exception:
                os.killpg(proc.pid, signal.SIGKILL)
        if prof:
            shutil.rmtree(prof, ignore_errors=True)
        if not ok:
            print(f"run {i}: timed out", file=sys.stderr)
            failed = True
            continue
        res = srv.results[n0]
        res["engine"] = args.browser
        res["run"] = i
        line = json.dumps(res)
        if out:
            out.write(line + "\n")
            out.flush()
        if res["kind"] != "done":
            failed = True
            print(f"run {i}: FAILED\n{res['payload'][:3000]}", file=sys.stderr)
        else:
            print(line, flush=True)
        time.sleep(1)  # let the previous browser fully exit
    srv.shutdown()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
