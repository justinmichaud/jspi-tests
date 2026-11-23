#!/usr/bin/env bash
# Vendor the benchmark corpus at pinned upstream commits. Run once; the
# result is checked in, so builds and runs never touch the network.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

MDN_REPO=https://github.com/mdn/content.git
MDN_REF=${MDN_REF:-cdbd60eab97b1958837806b059a920f6da2f4e78}
MDN_PATH=files/en-us/web/javascript

git clone -q --filter=blob:none --no-checkout --depth 1 ${MDN_REF:+--revision "$MDN_REF"} "$MDN_REPO" "$WORK/mdn"
git -C "$WORK/mdn" sparse-checkout set --no-cone "/$MDN_PATH/" /LICENSE.md
git -C "$WORK/mdn" checkout -q
MDN_SHA=$(git -C "$WORK/mdn" rev-parse HEAD)

rm -rf "$HERE/mdn"
mkdir -p "$HERE/mdn"
(cd "$WORK/mdn/$MDN_PATH" && find . -name index.md | LC_ALL=C sort | while read -r f; do
  d="$HERE/mdn/$(dirname "$f")"; mkdir -p "$d"; cp "$f" "$d/"; done)
cp "$WORK/mdn/LICENSE.md" "$HERE/mdn/LICENSE.md"

SPEC_TAG=0.31.2
curl -fsSL -o "$HERE/commonmark-spec.md" \
  "https://raw.githubusercontent.com/commonmark/commonmark-spec/$SPEC_TAG/spec.txt"

cat > "$HERE/SOURCES" <<EOF
mdn/content $MDN_SHA $MDN_PATH (CC-BY-SA 2.5, see mdn/LICENSE.md)
commonmark/commonmark-spec $SPEC_TAG spec.txt (CC-BY-SA 4.0)
EOF

python3 -I "$HERE/../tools/manifest.py" "$HERE"
