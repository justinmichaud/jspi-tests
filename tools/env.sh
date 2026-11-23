# Source this to use the hermetic toolchain: . tools/env.sh
_jspi_root=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
export OPAMROOT="$_jspi_root/_tools/opam"
export OPAMYES=1
export OPAMNOENVNOTICE=1
export OPAMSWITCH=jspi
export OPAMJOBS=4
export DUNE_JOBS=4
# Project-local make shim (nice'd); see tools/shim/make.
export PATH="$_jspi_root/tools/shim:$_jspi_root/_tools/bin:$_jspi_root/_tools/binaryen/bin:$_jspi_root/_tools/node/bin:$PATH"
if [ -d "$OPAMROOT/jspi/bin" ]; then
  export PATH="$OPAMROOT/jspi/bin:$PATH"
  export OCAMLFIND_CONF="$OPAMROOT/jspi/lib/findlib.conf"
fi
unset _jspi_root
