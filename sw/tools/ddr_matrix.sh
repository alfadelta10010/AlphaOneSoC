#!/bin/bash
# The DDR sweep over a grid of Pmod timings (TIMEOUT=<s> per run, default 300: Verilator needs about 20 s, Icarus about
# 30 times that, so give it TIMEOUT=7200), on the bench that make -C sw bench built:
#   make -C sw ddr bench && sw/tools/ddr_matrix.sh [jobs]
# For every combination of the device's output delay (+QSPI_DELAY, +QSPI_HOLD), the rd_late strap and
# extra skew on the SCK and IO paths (+QSPI_SCK_DLY_PS, +QSPI_IO_DLY_PS) it boots the ddr payload and
# has ddr_check.py compare the loader's choice with the rule and check the flash read-back. The
# combinations the bench cannot boot at all (SDR itself cannot read the flash, so the loader never prints) are counted and listed, not failed:
# they are outside the SDR timing the bench's Pmod model supports at 62.5 MHz. Negative delays are not used: the bench cannot schedule them.
cd "$(dirname "$0")/.." || exit 1
B=$(cd ../build/sw && pwd)
JOBS=${1:-4}
OUT=$B/ddr-matrix
rm -rf "$OUT"; mkdir -p "$OUT"
combos=()
for d in 2 8 14 16 18 19 20 22 24 28 32; do
  for skew in "" "+QSPI_SCK_DLY_PS=3000" "+QSPI_IO_DLY_PS=3000" "+QSPI_SCK_DLY_PS=1500 +QSPI_IO_DLY_PS=1500"; do
    combos+=("+QSPI_DELAY=$d $skew")
  done
done
for pair in "36 30" "40 30" "44 30" "48 30" "36 20"; do
  set -- $pair
  combos+=("+RD_LATE +QSPI_DELAY=$1 +QSPI_HOLD=$2")
  combos+=("+RD_LATE +QSPI_DELAY=$1 +QSPI_HOLD=$2 +QSPI_SCK_DLY_PS=3000")
done
i=0
for c in "${combos[@]}"; do
  i=$((i+1))
  echo "$i|$c"
done > "$OUT/list"
run_one() {
  IFS='|' read -r i c <<< "$1"
  (cd "$OUT" && timeout ${TIMEOUT:-300} ${SIM:-$B/bench/sim} +FLASH_FILE="$B/ddr/flash.hex" +UART_DIV=29 $c +MAX_CYCLES=12000000 > "$OUT/run-$i.log" 2>&1)
  if ! grep -q "AlphaOne loader" "$OUT/run-$i.log" || grep -q "instret=0$" "$OUT/run-$i.log"; then
    echo "$i|NOBOOT|$c"            # SDR itself cannot read the flash: no banner, nothing retired
  elif ! grep -q "flash in DDR\|flash stays SDR" "$OUT/run-$i.log"; then
    echo "$i|FAIL|$c|the loader printed no DDR decision (a hang in the sweep)"
  else
    r=$(python3 tools/ddr_check.py "$OUT/run-$i.log"); rc=$?
    echo "$i|$([ $rc = 0 ] && echo OK || echo FAIL)|$c|$r"
  fi
}
export -f run_one; export OUT B
xargs -P "$JOBS" -I{} bash -c 'run_one "{}"' < "$OUT/list" | sort -n -t'|' -k1 > "$OUT/summary"
cat "$OUT/summary"
# the mask of every combination against the committed golden file (UPDATE=1 rewrites it)
awk -F'|' '$2 != "NOBOOT" { split($4, a, "mask "); split(a[2], b, " "); print $3 "|" b[1] }' "$OUT/summary" > "$OUT/masks"
G=tools/ddr_matrix.golden
if [ "${UPDATE:-0}" = 1 ]; then cp "$OUT/masks" "$G"; echo "wrote $G"
elif [ -f "$G" ]; then
  if ! diff <(sort "$OUT/masks") <(sort "$G") > "$OUT/golden.diff"; then
    echo "ddr matrix: the passing masks differ from $G:"; cat "$OUT/golden.diff"; echo "GOLDEN-MISMATCH|differs" >> "$OUT/summary"
  fi
fi
ok=$(grep -c '|OK|' "$OUT/summary"); fail=$(grep -c '|FAIL|' "$OUT/summary"); nb=$(grep -c '|NOBOOT|' "$OUT/summary")
dd=$(grep -c 'DDR cap' "$OUT/summary")
echo "ddr matrix: $ok ok ($dd with DDR on), $fail failed, $nb did not boot (of ${#combos[@]})"
golden=$(grep -c 'GOLDEN-MISMATCH' "$OUT/summary")
[ "$fail" = 0 ] && [ "$ok" -gt 0 ] && [ "$golden" = 0 ]
