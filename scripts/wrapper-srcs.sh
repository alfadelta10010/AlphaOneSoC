#!/bin/bash
# Prints the RTL file names (src/ basenames) of the wrapper build in order: the Makefile's WRAPPER_SRC, which is
# also the harden's VERILOG_FILES (the submission's info.yaml source_files). The one list that tb/eqy/run.sh,
# scripts/gl/run_gl.sh and tb/rvfi/zero_area.sh read, so they cannot drift from it.
# Usage: wrapper-srcs.sh [<root>]   (default: the repository root)
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
printf 'print-wrapper-src: ; @echo $(WRAPPER_SRC)\n' > "${TMPDIR:-/tmp}/wsrc.$$.mk"
out=$(make -s -C "$ROOT" -f Makefile -f "${TMPDIR:-/tmp}/wsrc.$$.mk" print-wrapper-src); rc=$?
rm -f "${TMPDIR:-/tmp}/wsrc.$$.mk"
[ $rc -eq 0 ] && [ -n "$out" ] || { echo "wrapper-srcs.sh: no WRAPPER_SRC in $ROOT/Makefile" >&2; exit 1; }
for f in $out; do basename "$f"; done | tr '\n' ' ' | sed 's/ $//'; echo
