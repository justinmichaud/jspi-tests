#!/usr/bin/env bash
# Make sure the toolchain (and optionally builds) exist; every tool calls this.
#   tools/ensure.sh                      bootstrap if _tools/ is missing/stale
#   tools/ensure.sh --build P1 P2 ...    ...and build profiles not in dist/
#   tools/ensure.sh --stamp              (bootstrap.sh) record a good toolchain
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAMP=$ROOT/_tools/.stamp
want=$(cat "$ROOT/tools/bootstrap.sh" "$ROOT/opam/switch.export" | shasum -a 256 | awk '{print $1}')

if [ "${1:-}" = --stamp ]; then
  echo "$want" > "$STAMP"
  exit 0
fi

if [ "$(cat "$STAMP" 2>/dev/null)" != "$want" ]; then
  echo "ensure: installing/updating the toolchain in _tools/ (tools/bootstrap.sh)..." >&2
  "$ROOT/tools/bootstrap.sh" >&2
fi

if [ "${1:-}" = --build ]; then
  shift
  missing=()
  for p in "$@"; do
    # rebuild when any source is newer than the last build of that profile
    if [ ! -f "$ROOT/dist/$p/.built" ] || [ -n "$(find "$ROOT/lib" "$ROOT/bench" "$ROOT/app" "$ROOT/spike" "$ROOT/runner" "$ROOT/dune" "$ROOT/dune-project" -newer "$ROOT/dist/$p/.built" -type f -print -quit)" ]; then
      missing+=("$p")
    fi
  done
  [ ${#missing[@]} -eq 0 ] || "$ROOT/tools/build.sh" "${missing[@]}" >&2
fi
