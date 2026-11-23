#!/usr/bin/env bash
# Install every dependency into _tools/: nothing global, `rm -rf _tools` undoes
# it. Idempotent. Every tool runs this automatically (via tools/ensure.sh) when
# _tools/ is missing or out of date, so there is normally no need to call it.
#
#   opam + OCaml + all OCaml packages   exact set from opam/switch.export
#                                       (full package definitions, frozen)
#   Binaryen, samply, node, Chrome for Testing   pinned, sha256-checked
#   wasm_of_ocaml sources               for reading the runtime's .wat
#
# Needs only: macOS arm64 (or Linux), a C compiler (Xcode CLT), curl, python3.
# UNLOCKED=1 resolves fresh versions instead and rewrites opam/switch.export.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$ROOT/_tools
mkdir -p "$T/bin" "$T/dl"

OPAM_VERSION=2.6.1
BINARYEN_VERSION=133
SAMPLY_VERSION=0.13.1
NODE_VERSION=24.7.0
CHROME_VERSION=157.0.8103.78
OCAML_VERSION=5.4.1

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=arm64-macos ;;
  Linux-x86_64) PLAT=x86_64-linux ;;
  Linux-aarch64) PLAT=aarch64-linux ;;
  *) echo "unsupported platform" >&2; exit 1 ;;
esac

for c in cc curl python3 tar; do
  command -v "$c" >/dev/null || { echo "bootstrap: need '$c' (on macOS: xcode-select --install)" >&2; exit 1; }
done

# fetch URL SHA256 NAME: download once into _tools/dl, verify, print the path.
fetch() {
  local url=$1 sha=$2 out=$T/dl/$3
  if [ ! -f "$out" ] || ! echo "$sha  $out" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl -fsSL -o "$out.part" "$url"
    echo "$sha  $out.part" | shasum -a 256 -c - >/dev/null || { echo "bootstrap: checksum mismatch for $url" >&2; exit 1; }
    mv "$out.part" "$out"
  fi
  echo "$out"
}
# sha256 published next to the artifact
remote_sha() { curl -fsSL "$1" | awk '{print $1; exit}'; }

# --- opam ---------------------------------------------------------------
if [ ! -x "$T/bin/opam" ]; then
  curl -fsSL -o "$T/bin/opam" \
    "https://github.com/ocaml/opam/releases/download/$OPAM_VERSION/opam-$OPAM_VERSION-$PLAT"
  chmod +x "$T/bin/opam"
fi

# --- Binaryen -----------------------------------------------------------
if [ ! -x "$T/binaryen/bin/wasm-opt" ]; then
  url=https://github.com/WebAssembly/binaryen/releases/download/version_$BINARYEN_VERSION/binaryen-version_$BINARYEN_VERSION-$PLAT.tar.gz
  f=$(fetch "$url" "$(remote_sha "$url.sha256")" "binaryen.tar.gz")
  rm -rf "$T/binaryen" "$T/dl/binaryen-version_$BINARYEN_VERSION"
  tar -C "$T/dl" -xzf "$f"
  mv "$T/dl/binaryen-version_$BINARYEN_VERSION" "$T/binaryen"
fi

# --- samply -------------------------------------------------------------
if [ ! -x "$T/bin/samply" ]; then
  case "$PLAT" in
    arm64-macos) st=aarch64-apple-darwin ;;
    x86_64-linux) st=x86_64-unknown-linux-gnu ;;
    aarch64-linux) st=aarch64-unknown-linux-gnu ;;
  esac
  url=https://github.com/mstange/samply/releases/download/samply-v$SAMPLY_VERSION/samply-$st.tar.xz
  f=$(fetch "$url" "$(remote_sha "$url.sha256")" "samply.tar.xz")
  rm -rf "$T/dl/samply-x" && mkdir -p "$T/dl/samply-x"
  tar -C "$T/dl/samply-x" -xJf "$f"
  cp "$(find "$T/dl/samply-x" -name samply -type f | head -1)" "$T/bin/samply"
  chmod +x "$T/bin/samply"
  # macOS: self-codesign with the task_for_pid entitlement (local binary only)
  if [ "$(uname -s)" = Darwin ]; then "$T/bin/samply" setup -y >/dev/null; fi
fi

# --- node (V8 shell for repro/ and shell runs) --------------------------
if [ ! -x "$T/node/bin/node" ]; then
  case "$PLAT" in arm64-macos) np=darwin-arm64 ;; x86_64-linux) np=linux-x64 ;; aarch64-linux) np=linux-arm64 ;; esac
  name=node-v$NODE_VERSION-$np.tar.xz
  sha=$(curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" | awk -v n="$name" '$2==n {print $1}')
  f=$(fetch "https://nodejs.org/dist/v$NODE_VERSION/$name" "$sha" "$name")
  rm -rf "$T/node" "$T/dl/node-v$NODE_VERSION-$np"
  tar -C "$T/dl" -xJf "$f"
  mv "$T/dl/node-v$NODE_VERSION-$np" "$T/node"
fi

# --- Chrome for Testing (pinned browser; macOS arm64) --------------------
if [ "$PLAT" = arm64-macos ] && [ ! -d "$T/chrome" ]; then
  f=$(fetch "https://storage.googleapis.com/chrome-for-testing-public/$CHROME_VERSION/mac-arm64/chrome-mac-arm64.zip" \
    bf3b49d0fe62a62397e98641aa736ef813c46014f03ec13d4913442e6966c7fc "chrome-mac-arm64.zip")
  rm -rf "$T/chrome.part" && mkdir -p "$T/chrome.part"
  (cd "$T/chrome.part" && unzip -q "$f")
  xattr -cr "$T/chrome.part" 2>/dev/null || true
  mv "$T/chrome.part" "$T/chrome"
fi

# --- OCaml toolchain and packages ----------------------------------------
# shellcheck source=env.sh
. "$ROOT/tools/env.sh"
[ -d "$OPAMROOT" ] || opam init --bare -n
if ! opam switch list --short | grep -qx jspi; then
  opam switch create jspi --empty
fi
if [ "${UNLOCKED:-0}" = 1 ]; then
  opam install --switch jspi --assume-depexts "ocaml-base-compiler.$OCAML_VERSION" \
    dune wasm_of_ocaml-compiler js_of_ocaml js_of_ocaml-compiler js_of_ocaml-ppx js_of_ocaml-lwt \
    lwt lwt_direct cmarkit yojson eio uucp uunf
  opam switch export --switch jspi --full --freeze "$ROOT/opam/switch.export"
else
  # Binaryen comes from _tools/binaryen, hence --assume-depexts.
  opam switch import --switch jspi --assume-depexts "$ROOT/opam/switch.export"
fi

# Sources of the compiler and its Wasm runtime (.wat), for reading next to
# debug builds and profiles.
if [ ! -d "$T/src/wasm_of_ocaml-compiler" ]; then
  mkdir -p "$T/src"
  v=$(opam show --switch jspi -f version wasm_of_ocaml-compiler)
  opam source --switch jspi "wasm_of_ocaml-compiler.$v" --dir "$T/src/wasm_of_ocaml-compiler"
fi

. "$ROOT/tools/env.sh"
"$ROOT/tools/ensure.sh" --stamp
echo "toolchain ready: OCaml $(ocaml -vnum), wasm_of_ocaml $(wasm_of_ocaml --version), $(wasm-opt --version), samply $(samply --version | awk '{print $2}'), node $(node --version)"
