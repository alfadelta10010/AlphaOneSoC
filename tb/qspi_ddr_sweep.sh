#!/usr/bin/env bash
# DDR capture-point sweep with a verdict (docs/qspi-ddr.md 3.3).
#
# The 62.5 MHz clock (CLK_HALF_PS=8000, T = 16 ns), a device whose flash output is valid from R + 7 ns
# after the SCK edge to R + 17 ns (the model's +QSPI_DELAY=R+7 and +QSPI_HOLD=R+1: valid after
# R + tCLQV, held R + tCLQX past the next launch, one clock T = 16 ns later), for the round trips R
# below and every DDR_CAP 0..7 (capture point c = DDR_CAP + 1 half clocks after the launch edge,
# X_c = c * 8 ns). The window rule: R + 7 <= X_c < R + 1 + T = R + 17 (lower edge inclusive, upper
# exclusive); the expected passing set per R is every c with that holding. (docs/qspi-ddr.md 3.3's
# budget is being redone at 16 ns, so its rule is not restated here.)
# The sets are written out below and any difference from the measured set exits 1.
# Another clock: CLK_HALF_PS=<ps> in the environment (the Makefile passes CHIP_HALF_PS). The expected
# sets then come from the same window rule in ps, R + 7 <= c H < R + 1 + 2 H (H the half period), and
# the R list runs from 8 in steps of 3 until c = 8 has had its window; at 8000 the rule's sets must equal
# the table below (a check of the rule's arithmetic) and the R list is the table's.
# Only a data-mismatch `SWEEP FAIL` is an expected failure (a capture point outside the window);
# a `SWEEP ERROR` (pin checker, protocol or command-byte error), a model ERROR/$fatal, a TIMEOUT
# or a run with no verdict line at all fails the sweep.
# c = 8 needs R = 50 or 53 ([57,67) and [60,70) hold X = 64 only), so the sweep runs on to 53,
# which is what makes DDR_CAP 6 and 7 (the m1 index width) part of the check.
# With +DTR_LAUNCH=1 (a device launching the first nibble half an SCK late) the streamed suite must
# pass at no capture point, for every R.
#
#   usage: tb/qspi_ddr_sweep.sh <compiled tb_qspi.vvp> [vvp command (default vvp)]
set -u
BIN=$1; VVP=${2:-vvp}
declare -A EXP=(
  [8]="2 3"  [11]="3"  [14]="3"  [17]="3 4"  [20]="4"  [23]="4"  [26]="5"  [29]="5"  [32]="5 6"
  [35]="6"   [38]="6"  [41]="6 7"  [44]="7"    [47]="7"  [50]="8" [53]="8"
)
H=${CLK_HALF_PS:-8000}
rule() {   # the passing set for round trip $1 by the window rule, at half period H ps
  local r=$1 c s=""
  for c in 1 2 3 4 5 6 7 8; do
    if [ $(((r + 7) * 1000)) -le $((c * H)) ] && [ $((c * H)) -lt $(((r + 1) * 1000 + 2 * H)) ]; then s="$s $c"; fi
  done
  echo "${s# }"
}
if [ "$H" = 8000 ]; then
  RS="8 11 14 17 20 23 26 29 32 35 38 41 44 47 50 53"
  for r in $RS; do [ "$(rule $r)" = "${EXP[$r]}" ] || { echo "SWEEP ERROR: the rule gives '$(rule $r)' at R=$r, the table '${EXP[$r]}'"; exit 1; }; done
else
  unset EXP; declare -A EXP; RS=""; r=8
  while [ $(((r + 7) * 1000)) -le $((8 * H)) ]; do RS="$RS $r"; EXP[$r]=$(rule $r); r=$((r + 3)); done
fi
echo "CLK_HALF_PS=$H (T = $((2 * H)) ps)"
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
bad=0
for la in 0 1; do
  echo "DTR_LAUNCH=$la"
  for r in $RS; do
    got=""
    for cap in 0 1 2 3 4 5 6 7; do
      $VVP "$BIN" +SWEEP +DDR +DDR_CAP=$cap +CLK_HALF_PS=$H +QSPI_DELAY=$((r+7)) \
          +QSPI_HOLD=$((r+1)) +DTR_LAUNCH=$la > "$LOG" 2>&1
      if grep -q '^SWEEP PASS' "$LOG"; then got="$got $((cap+1))"
      elif grep -q '^SWEEP FAIL' "$LOG" && ! grep -qE '^(SWEEP ERROR|ERROR|TIMEOUT|FAIL pins)|\$fatal' "$LOG"; then :
      else
        bad=$((bad+1))
        echo "  HARD ERROR (R=$r cap=$cap la=$la): $(grep -m2 -E 'SWEEP ERROR|ERROR|TIMEOUT|FAIL' "$LOG" | tr '\n' ' ')"
        [ -z "$(grep -m1 -E 'SWEEP|ERROR|TIMEOUT' "$LOG")" ] && echo "  (no verdict line)"
      fi
    done
    got=${got# }
    if [ "$la" = 0 ]; then want=${EXP[$r]}; else want=""; fi
    if [ "$got" = "$want" ]; then v=ok; else v="MISMATCH"; bad=$((bad+1)); fi
    printf '  R=%-2s ns: passing c: %-6s expected: %-6s %s\n' "$r" "${got:-none}" "${want:-none}" "$v"
  done
done
if [ $bad -ne 0 ]; then echo "SWEEP FAIL: $bad rows differ or runs errored (see MISMATCH / HARD ERROR lines)"; exit 1; fi
echo "SWEEP OK: every row matches"
