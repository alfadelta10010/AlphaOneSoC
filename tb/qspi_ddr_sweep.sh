#!/usr/bin/env bash
# DDR capture-point sweep with a verdict (docs/qspi-ddr.md 3.3).
#
# The 60 MHz clock (CLK_HALF_PS=8333), a device whose flash output is valid from R + 7 ns after the
# SCK edge to R + 17.67 ns (the model's +QSPI_DELAY=R+7 and +QSPI_HOLD=R+1: valid after R + tCLQV,
# held R + tCLQX past the next launch, one clock T = 16.67 ns later), for the round trips R below and every DDR_CAP 0..7 (capture point
# c = DDR_CAP + 1 half clocks after the launch edge, X_c = c * 8.333 ns). The expected passing set
# per R follows from the window rule: R + 7 <= X_c < R + 17.67. (docs/qspi-ddr.md 3.3 gives
# R + 17.17: its 2 ns spread Delta is 1 ns tighter at that edge than the model, and the two rules differ only at
# R = 41, c = 7, X = 58.33 ns.) The sets are written out below and any difference from the measured set exits 1.
# R = 35, 38 and 41 give c = 6 only; c = 7 and 8 need R = 44..53, so the sweep runs on to 53,
# which is what makes DDR_CAP 6 and 7 (the m1 index width) part of the check.
# With +DTR_LAUNCH=1 (a device launching the first nibble half an SCK late) the streamed suite must
# pass at no capture point, for every R.
#
#   usage: tb/qspi_ddr_sweep.sh <compiled tb_qspi.vvp> [vvp command (default vvp)]
set -u
BIN=$1; VVP=${2:-vvp}
declare -A EXP=(
  [8]="2 3"  [11]="3"  [14]="3"  [17]="3 4"  [20]="4"  [23]="4"  [26]="4 5"  [29]="5"  [32]="5"
  [35]="6"   [38]="6"  [41]="6 7"  [44]="7"    [47]="7"  [50]="7 8" [53]="8"
)
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
bad=0
for la in 0 1; do
  echo "DTR_LAUNCH=$la"
  for r in 8 11 14 17 20 23 26 29 32 35 38 41 44 47 50 53; do
    got=""
    for cap in 0 1 2 3 4 5 6 7; do
      $VVP "$BIN" +SWEEP +DDR +DDR_CAP=$cap +CLK_HALF_PS=8333 +QSPI_DELAY=$((r+7)) \
          +QSPI_HOLD=$((r+1)) +DTR_LAUNCH=$la > "$LOG" 2>&1
      grep -q '^SWEEP PASS' "$LOG" && got="$got $((cap+1))"
    done
    got=${got# }
    if [ "$la" = 0 ]; then want=${EXP[$r]}; else want=""; fi
    if [ "$got" = "$want" ]; then v=ok; else v="MISMATCH"; bad=$((bad+1)); fi
    printf '  R=%-2s ns: passing c: %-6s expected: %-6s %s\n' "$r" "${got:-none}" "${want:-none}" "$v"
  done
done
if [ $bad -ne 0 ]; then echo "SWEEP FAIL: $bad rows differ from the expected passing set"; exit 1; fi
echo "SWEEP OK: every row matches"
