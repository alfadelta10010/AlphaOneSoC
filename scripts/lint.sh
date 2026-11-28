#!/bin/bash
# lint.sh -- the lint gate over the whole SoC top (the Makefile's WRAPPER_SRC), three tools:
#   1. verilator --lint-only -Wall       2. iverilog -g2012 -Wall
#   3. yosys: hierarchy -check; proc; flatten; opt; check -assert (multi-driven nets, combinational loops,
#      used-but-undriven wires), then a latch count after proc and the same check after a full synth, which is
#      what LibreLane's Checker.YosysSynthChecks reads (it rejected a loop variable shared by two always blocks
#      that iverilog accepted silently).
# Usage: scripts/lint.sh [<outdir>]   (default build/lint). Logs: verilator.log iverilog.log yosys.log
# Exit 0 only when the yosys checks pass, verilator reports no warning of a defect class (MULTIDRIVEN, LATCH,
# UNOPTFLAT, UNDRIVEN, COMBDLY, BLKSEQ, ...), and the latch count is 0. The tolerated classes (UNUSEDSIGNAL,
# DECLFILENAME, PINCONNECTEMPTY, WIDTHEXPAND) are reported, not gating; WIDTHTRUNC needs a read. iverilog and the style-class verilator warnings are
# reported, not gating: read the logs.
# Needs verilator, iverilog and yosys on PATH.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/build/lint}
TOP=tt_um_alfadelta10010_alphaone_soc
mkdir -p "$OUT"
# The Makefile's WRAPPER_SRC, the harden's VERILOG_FILES list.
printf 'print-wrapper-src: ; @echo $(WRAPPER_SRC)\n' > "$OUT/wsrc.mk"
SRCS=$(make -s -C "$ROOT" -f Makefile -f "$OUT/wsrc.mk" print-wrapper-src | tr ' ' '\n' | sed "s|^src/|$ROOT/src/|" | tr '\n' ' ')
[ -n "$SRCS" ] || { echo "lint.sh: no WRAPPER_SRC in $ROOT/Makefile" >&2; exit 1; }
rc=0

echo "== verilator --lint-only -Wall"
verilator --lint-only -Wall -Wno-fatal --top-module $TOP $SRCS > "$OUT/verilator.log" 2>&1; vrc=$?
grep -c '^%Warning' "$OUT/verilator.log" | sed 's/^/   warnings: /'
grep -o '^%\(Warning\|Error\)[-A-Z0-9_]*' "$OUT/verilator.log" | sort | uniq -c | sed 's/^/   /'
[ $vrc -ne 0 ] && { echo "   verilator exit $vrc"; rc=1; }
# Classes that are real defects here (multi-driven, latch, loop, undriven, blocking/nonblocking mixing): gating.
gate=$(grep -E '^%Warning-(MULTIDRIVEN|LATCH|UNOPTFLAT|UNDRIVEN|COMBDLY|BLKSEQ|BLKANDNBLK|CASEINCOMPLETE|CASEOVERLAP|SYNCASYNCNET)' "$OUT/verilator.log" | head -20)
[ -n "$gate" ] && { echo "$gate" | sed 's/^/   /'; echo "   verilator: gating warning class present"; rc=1; }

echo "== iverilog -g2012 -Wall"
iverilog -g2012 -Wall -s $TOP -o /dev/null $SRCS > "$OUT/iverilog.log" 2>&1 || { echo "   iverilog failed"; rc=1; }
echo "   messages: $(grep -c -E 'warning|error' "$OUT/iverilog.log")"

echo "== yosys"
yosys -q -l "$OUT/yosys.log" -p "
  read_verilog -sv $SRCS
  hierarchy -check -top $TOP
  proc
  tee -o $OUT/latches.txt select -count t:\$dlatch t:\$_DLATCH_* t:\$adlatch t:\$dlatchsr
  flatten
  opt
  check -assert
  synth -top $TOP -flatten
  check -assert
  tee -o $OUT/stat.txt stat
" > /dev/null 2>&1 || { echo "   yosys check FAILED (see $OUT/yosys.log)"; rc=1; }
grep -E -i "warning|error|problem" "$OUT/yosys.log" | sort | uniq -c | sort -rn | head -20 | sed 's/^/   /'
nl=$(grep -oE '[0-9]+' "$OUT/latches.txt" 2>/dev/null | head -1)
echo "   latches after proc: ${nl:-unknown}"
[ "${nl:-1}" = 0 ] || rc=1
echo "lint: $([ $rc = 0 ] && echo PASS || echo FAIL)  (logs in $OUT)"
exit $rc
