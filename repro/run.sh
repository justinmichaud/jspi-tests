#!/usr/bin/env bash
# Minimal repros of things that work in Chrome/V8 but not in JSC/Safari.
#   repro/run.sh [jsc-path]     each test prints "ok" when the engine is correct
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
JSC=${1:-${JSC:-/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc}}
"$HERE/../tools/ensure.sh"
WASM_AS="$HERE/../_tools/binaryen/bin/wasm-as"
NODE="$HERE/../_tools/node/bin/node"
# A WebKit build's jsc needs its frameworks.
d=$(dirname "$JSC"); [ -d "$d/JavaScriptCore.framework" ] && export DYLD_FRAMEWORK_PATH="$d"
status=0
for t in "$HERE"/*/; do
  name=$(basename "$t")
  for w in "$t"*.wat; do "$WASM_AS" --all-features "$w" -o "${w%.wat}.wasm"; done
  j=$(cd "$t" && "$JSC" test.js 2>&1 | tail -1)
  n=$(cd "$t" && "$NODE" --experimental-wasm-jspi test.js 2>&1 | tail -1)
  printf '%-34s jsc: %-6s node: %s\n' "$name" "$([ "$j" = ok ] && echo PASS || echo FAIL)" "$([ "$n" = ok ] && echo PASS || echo FAIL)"
  [ "$j" = ok ] || { echo "    $j"; status=1; }
done
exit $status
