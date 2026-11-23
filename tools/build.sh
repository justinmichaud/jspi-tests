#!/usr/bin/env bash
# Build every workload in every profile into dist/<profile>/<workload>/.
#   tools/build.sh                 all profiles
#   tools/build.sh release-jspi    just one
# Profiles: {release,debug}-{jspi,cps,native,none}. See ./dune for the flags.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
tools/ensure.sh
. tools/env.sh

WORKLOADS=(bench/micro bench/switch bench/await app app/search spike)
PROFILES=("$@")
[ ${#PROFILES[@]} -eq 0 ] && PROFILES=(release-jspi release-cps release-native release-none debug-jspi debug-cps debug-native debug-none)

mkdir -p _build
for p in "${PROFILES[@]}"; do
  # The app and the spike need effects; the "none" builds skip them.
  ws=()
  for w in "${WORKLOADS[@]}"; do
    case "$p:$w" in *-none:app|*-none:spike) continue ;; esac
    [ -f "$w/dune" ] && ws+=("$w")
  done
  targets=()
  for w in "${ws[@]}"; do targets+=("./$w/main.bc.wasm.js"); done
  dune build --profile "$p" --build-dir "$ROOT/_build/$p" "${targets[@]}"
  for w in "${ws[@]}"; do
    src="_build/$p/default/$w"
    dst="dist/$p/$(basename "$w")"
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$src/main.bc.wasm.js" "$dst/"
    cp -R "$src/main.bc.wasm.assets" "$dst/"
    chmod -R u+w "$dst"
    # Static assets the app serves itself.
    [ -d "$w/static" ] && cp -R "$w/static/." "$dst/"
    (cd "$dst/main.bc.wasm.assets" && ls *.wasm) | python3 -I -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))' > "$dst/wasm-files.json"
    python3 -I - "$dst" "$p" <<'PY'
import json, os, subprocess, sys
dst, profile = sys.argv[1], sys.argv[2]
def out(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(dst) for f in fs)
info = {
  "profile": profile,
  "ocaml": out("ocamlc", "-version"),
  "wasm_of_ocaml": out("wasm_of_ocaml", "--version"),
  "binaryen": out("wasm-opt", "--version"),
  "bytes": size,
}
json.dump(info, open(os.path.join(dst, "build-info.json"), "w"), indent=1)
PY
  done
  date > "dist/$p/.built"
  echo "built $p"
done
