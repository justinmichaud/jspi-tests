"""Paths and helpers shared by the tools. Everything comes from _tools/."""
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
T = ROOT / "_tools"
NODE = str(T / "node/bin/node")
SAMPLY = str(T / "bin/samply")
SYSTEM_JSC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc"
_CFT = T / "chrome/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
_SYSTEM_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# Pinned Chrome for Testing (bootstrap); the installed Chrome only as a fallback.
CHROME = str(_CFT) if _CFT.exists() else _SYSTEM_CHROME


def ensure(*profiles):
    """Install the toolchain if needed and build any missing/stale profiles."""
    args = [str(ROOT / "tools/ensure.sh")]
    if profiles:
        args += ["--build", *profiles]
    subprocess.run(args, check=True)


def jsc_env(jsc):
    """Environment for running a jsc: a WebKit build needs its frameworks."""
    env = dict(os.environ)
    d = os.path.dirname(os.path.abspath(jsc))
    if os.path.isdir(os.path.join(d, "JavaScriptCore.framework")):
        env["DYLD_FRAMEWORK_PATH"] = d
    return env


def chrome_version(chrome=None):
    try:
        out = subprocess.run([chrome or CHROME, "--version"], capture_output=True, text=True, timeout=30).stdout
        return out.strip()
    except Exception:
        return "?"
