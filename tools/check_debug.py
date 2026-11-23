"""Check that a debug build carries full OCaml sources in its source maps.

  python3 -I tools/check_debug.py dist/debug-jspi/app

Prints per Wasm module the number of OCaml source files its map references
and how many of them have their content embedded. Exits non-zero if a module
has no map, or a referenced source is missing its content.
"""
import glob
import json
import os
import sys

bad = 0
for d in sys.argv[1:]:
    for wasm in sorted(glob.glob(os.path.join(d, "main.bc.wasm.assets", "*.wasm"))):
        name = os.path.basename(wasm)
        if name.startswith("_link_info") or name.startswith("start-"):
            continue
        path = wasm + ".map"
        if not os.path.exists(path):
            print(f"  {name:44} NO MAP")
            bad += 1
            continue
        m = json.load(open(path))
        maps = [s["map"] for s in m.get("sections", [])] or [m]
        srcs, missing = 0, []
        for mm in maps:
            contents = mm.get("sourcesContent") or []
            for i, s in enumerate(mm.get("sources", [])):
                if s.startswith("/builtin/"):
                    continue
                srcs += 1
                if i >= len(contents) or not contents[i]:
                    missing.append(s)
        flag = "ok" if not missing else f"MISSING {missing[:3]}"
        print(f"  {name:44} {srcs:4} OCaml sources  {flag}")
        bad += bool(missing)
sys.exit(1 if bad else 0)
