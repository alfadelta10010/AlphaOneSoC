#!/bin/bash
# run_glitch.sh WORK=<dir> [CORNERS="nom_tt ..."] [VARIANTS="D D2 N2 N1"] [JOBS=1]   (WO-34, VC-8, closes TT01)
#
# tb/tb_tt_um.v, unchanged, on the SDF-annotated fin-3x4 pnl netlist (Icarus 12, -gspecify) with
# tb/gls_sdf/glitch_mon.v as a second top. Run on the sandbox, plain processes (no docker).
#
#   D   the netlist as hardened                                         9 corners   expected: monitor PASS, bench PASS
#   D2  D + 2.0 ns on the SoC-side input of every pin gate             3 corners   expected: monitor PASS, bench PASS
#   N2  D2 + TT01 (the `run` flop's D tied to 1)                       3 corners   expected: monitor FAIL in events 1 and 3
#   N1  D + TT01 only                                                  9 corners   either outcome: the TT01 verdict
#
# CORNERS (short: nom_tt, max_ss, min_ff, ... = {min,nom,max} x {ff,tt,ss}) overrides every variant's list.
# Per run one line: <variant> <corner> monitor [..] bench [..] sdf-warn <n> d_oe3 <ns> wall <s>; last line WO34 PASS|FAIL.
# Resumable (WORK/runs/<v>_<c>/done); the per-run pnl, vvp and sdf are deleted after the run (disk is tight).
# Timing models: the PDK's with every `wire X_delayed;` tied `= X` (Icarus does not drive $setuphold's
# delayed nets), compared with ~/regr/rfm/gls-sdf/gls_model_timing; rf_top_timing.v has the macro's 4.0 ns.
set -u
for a in "$@"; do case $a in *=*) export "${a%%=*}=${a#*=}";; esac; done
: "${WORK:?WORK=<dir>}"
R=$(cd "$(dirname "$0")/../.." && pwd); G=$R/tb/gls_sdf
VARIANTS=${VARIANTS:-"D D2 N2 N1"}; JOBS=${JOBS:-1}
PDKV=8afc8346a57fe1ab7934ba5a6056ea8b43078e71
NLDIR=/home/mempool/tt/projects/fin-3x4/runs/wokwi/final
NL=$NLDIR/pnl/tt_um_alfadelta10010_alphaone_soc.pnl.v
NLMD5=5862cf7620e7a1d8c053154ee426fd1c
CELLS=${PDK_ROOT:-/home/mempool/tt/pdk}/ciel/sky130/versions/$PDKV/sky130A/libs.ref/sky130_fd_sc_hd/verilog
REFM=$HOME/regr/rfm/gls-sdf/gls_model_timing
export PATH=/home/mempool/tools/rv64-gcc-elf/bin:$PATH
IVERILOG=/usr/bin/iverilog; VVP=/usr/bin/vvp
T=16; IN_DLY=3.2; RST_CHK=8
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd); mkdir -p "$WORK/runs" "$WORK/models"
SUM=$WORK/summary.txt; FAILS=""
log() { echo "$(date -Is) $*" >> "$WORK/STATUS"; }
fail() { FAILS="$FAILS; $*"; }
full() { case $1 in
  min_ff) echo min_ff_n40C_1v95;; nom_ff) echo nom_ff_n40C_1v95;; max_ff) echo max_ff_n40C_1v95;;
  min_tt) echo min_tt_025C_1v80;; nom_tt) echo nom_tt_025C_1v80;; max_tt) echo max_tt_025C_1v80;;
  min_ss) echo min_ss_100C_1v60;; nom_ss) echo nom_ss_100C_1v60;; max_ss) echo max_ss_100C_1v60;;
  *) echo "$1";; esac; }
ALL9="nom_tt max_ss min_ff min_tt max_tt nom_ss min_ss nom_ff max_ff"; THREE="nom_tt max_ss min_ff"
corners_of() { if [ -n "${CORNERS:-}" ]; then echo "$CORNERS"; else case $1 in D|N1) echo "$ALL9";; *) echo "$THREE";; esac; fi; }

# 1. the netlist
m=$(md5sum "$NL" | awk '{print $1}'); echo "netlist md5 $m $NL"
[ "$m" = "$NLMD5" ] || { echo "WO34 FAIL netlist md5 is not $NLMD5"; exit 1; }

# 2. the timing models
sed 's/wire \([A-Za-z0-9_]*\)_delayed *;/wire \1_delayed = \1;/' "$CELLS/sky130_fd_sc_hd.v" > "$WORK/models/sky130_fd_sc_hd.v"
cp "$CELLS/primitives.v" "$WORK/models/primitives.v"
# The 10-18 copy differs from a fresh sed only by its first (comment) line and by the 485-line
# sky130_ef_sc_hd decap/fill block it lacks (PDK lines 92-576); the netlist instantiates none of them.
hunks=$(diff "$WORK/models/sky130_fd_sc_hd.v" "$REFM/sky130_fd_sc_hd.v" | grep -E '^[0-9]' | tr '\n' ' ')
if cmp -s "$WORK/models/primitives.v" "$REFM/primitives.v" && [ -z "$hunks" ]; then
  echo "models identical to ~/regr/rfm/gls-sdf/gls_model_timing"
elif cmp -s "$WORK/models/primitives.v" "$REFM/primitives.v" && [ "$hunks" = "0a1 92,576d92 " ] && ! grep -q 'sky130_ef_' "$NL"; then
  echo "models identical to ~/regr/rfm/gls-sdf/gls_model_timing (up to its header comment and the unused sky130_ef_sc_hd block, diff hunks: $hunks)"
else
  echo "WO34 FAIL models differ from ~/regr/rfm/gls-sdf/gls_model_timing"
  diff "$WORK/models/sky130_fd_sc_hd.v" "$REFM/sky130_fd_sc_hd.v" | head -20; exit 1
fi

# 3. the program
if [ ! -s "$WORK/tt_pins.hex" ]; then
  ( cd "$WORK" && riscv64-unknown-elf-gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
      -T $R/tests/soc/link.ld -I$R/tests/soc $R/tests/soc/tt_pins.S -o tt_pins.elf && \
    riscv64-unknown-elf-objcopy -O verilog -j .text.init -j .text -j .rodata --change-addresses=-0x20000000 tt_pins.elf tt_pins.hex ) \
    || { echo "WO34 FAIL tt_pins build"; exit 1; }
fi
HEX=$WORK/tt_pins.hex

# 4. one run
run_one() { # variant corner
  local v=$1 c=$2 cf d s0 w line
  cf=$(full "$c"); d=$WORK/runs/${v}_$c; mkdir -p "$d"; cd "$d" || return
  [ -e done ] && return
  s0=$(date +%s)
  local sdf=$NLDIR/sdf/$cf/tt_um_alfadelta10010_alphaone_soc__$cf.sdf
  python3 "$G/prep.py" "$NL" "$sdf" pnl0.v cells.sdf > prep.log 2>&1 || { echo "prep failed" >> prep.log; touch done; echo "$v $c PREP-FAILED" >> "$SUM"; return; }
  # one IOPATH line: the three values of a triplet are equal, so the file alone picks the corner
  grep -m1 -E '\(IOPATH [^ ]+ [^ ]+ \([0-9.]+:[0-9.]+:[0-9.]+\)' "$sdf" > iopath.txt
  : > edit.log
  case $v in
    D)  mv pnl0.v pnl.v;;
    D2) python3 "$G/edit_netlist.py" pnl0.v pnl.v --pin-delay 2.0 > edit.log 2>&1;;
    N2) python3 "$G/edit_netlist.py" pnl0.v pnl.v --tt01 --pin-delay 2.0 > edit.log 2>&1;;
    N1) python3 "$G/edit_netlist.py" pnl0.v pnl.v --tt01 > edit.log 2>&1;;
  esac
  rc=$?; rm -f pnl0.v
  [ -s pnl.v ] || { echo "$v $c EDIT-FAILED" >> "$SUM"; touch done; return; }
  $IVERILOG -g2012 -gspecify -I "$R/src" -o sim.vvp -s tb_tt_um -s glitch_mon -DGL_TEST -DUSE_POWER_PINS -DSIM \
    -DTCLK_NS=$T -DIN_DLY_NS=$IN_DLY -DRST_CHK_NS=$RST_CHK -DSDF_FILE=\"$d/cells.sdf\" \
    "$WORK/models/primitives.v" "$WORK/models/sky130_fd_sc_hd.v" "$G/rf_top_timing.v" pnl.v \
    "$R/tb/qspi_pmod_model.v" "$R/tb/rp2350_uart_model.v" "$R/tb/ssd1331_model.v" "$R/tb/keypad_model.v" "$R/tb/tb_tt_um.v" "$G/glitch_mon.v" > compile.log 2>&1 \
    || { echo "$v $c COMPILE-FAILED" >> "$SUM"; rm -f pnl.v cells.sdf sim.vvp; touch done; return; }
  rm -f pnl.v
  timeout -s KILL 1200 $VVP -n sim.vvp +FLASH_FILE=$HEX +RF_X +RF_COLLIDE_X > sim.log 2>&1
  rm -f sim.vvp cells.sdf
  local mon bench warn d1
  mon=$(grep -E '^GLITCH-MON (PASS|FAIL)' sim.log | tail -1)
  bench=$(grep -hE '^(PASS|FAIL|ERROR|TIMEOUT)' sim.log | head -1)
  warn=$(grep -c 'SDF WARNING' sim.log)
  d1=$(grep -E '^GLITCH-MON event 1 ' sim.log | sed -n 's/.*d_oe3=\([-0-9.]*\):.*/\1/p')
  line="$v $c monitor [$mon] bench [$bench] sdf-warn $warn d_oe3 ${d1:-none} wall $(( $(date +%s) - s0 ))"
  echo "$line" >> "$SUM"; echo "$line"
  touch done
}

# 5. all runs, JOBS at a time
rm -f "$SUM.new"
for v in $VARIANTS; do for c in $(corners_of "$v"); do
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
  log "start $v $c"
  nice -n 10 bash -c "$(declare -f full run_one); G=$G; R=$R; WORK=$WORK; SUM=$SUM; NL=$NL; NLDIR=$NLDIR; HEX=$HEX; IVERILOG=$IVERILOG; VVP=$VVP; T=$T; IN_DLY=$IN_DLY; RST_CHK=$RST_CHK; run_one $v $c" &
done; done
wait

# 6. the acceptance reading of the logs
ev() { # log k field
  grep -E "^GLITCH-MON event $2 " "$1" | head -1 | sed -n "s/.*$3=\([-0-9.]*\).*/\1/p"; }
evverdict() { grep -E "^GLITCH-MON event $2 " "$1" | head -1 | grep -oE '(PASS|FAIL)$'; }
nviol() { # log k : violation lines (M0/M1/M2) printed before event k's summary line
  awk -v k="$2" '/^  M[0-9]/{n++} /^GLITCH-MON event /{ if ($3==k) {print n+0; exit} n=0 }' "$1"; }
declare -A DOE
for v in $VARIANTS; do for c in $(corners_of "$v"); do
  d=$WORK/runs/${v}_$c; L=$d/sim.log
  [ -e "$L" ] || { fail "$v $c no log"; continue; }
  grep -q 'Unable to open' "$L" && fail "$v $c Unable to open"
  grep -q 'SDF ERROR' "$L" && fail "$v $c SDF ERROR"
  grep -q 'INTERCONNECTs' "$d/prep.log" || fail "$v $c prep.log has no INTERCONNECT count"
  [ "$(grep -c 'SDF WARNING' "$L")" -ge 0 ] || true
  tr=$(sed -n 's/.*(\([0-9.]*\):\([0-9.]*\):\([0-9.]*\)).*/\1 \2 \3/p' "$d/iopath.txt" | awk '{print ($1==$2 && $2==$3) ? "equal" : "DIFFER"}')
  [ "$tr" = equal ] || fail "$v $c IOPATH triplet not equal"
  case $v in
    D|D2)
      grep -qE '^GLITCH-MON PASS [0-9]+ events' "$L" || fail "$v $c monitor not PASS"
      n=$(sed -n 's/^GLITCH-MON PASS \([0-9]*\) events.*/\1/p' "$L" | tail -1); [ "${n:-0}" -ge 3 ] || fail "$v $c fewer than 3 events"
      grep -q '^PASS tb_tt_um' "$L" || fail "$v $c bench not PASS"
      [ "$(ev "$L" 1 clk_in_reset)" = 0 ] || fail "$v $c event 1 clk_in_reset not 0"
      [ "$v" = D ] && DOE[$c]=$(ev "$L" 1 d_oe3);;
    N2)
      for k in 1 3; do
        [ "$(evverdict "$L" $k)" = FAIL ] && [ "$(nviol "$L" $k)" -ge 1 ] || fail "$v $c event $k did not FAIL with a violation"
      done
      [ "$(evverdict "$L" 2)" = PASS ] || fail "$v $c event 2 not PASS";;
  esac
done; done
if [ -n "${DOE[max_ss]:-}" ] && [ -n "${DOE[nom_tt]:-}" ] && [ -n "${DOE[min_ff]:-}" ]; then
  awk -v a="${DOE[max_ss]}" -v b="${DOE[nom_tt]}" -v c="${DOE[min_ff]}" 'BEGIN{exit !(a>b && b>c && c>0.05)}' \
    && echo "D event 1 d_oe3: max_ss ${DOE[max_ss]} > nom_tt ${DOE[nom_tt]} > min_ff ${DOE[min_ff]} ns" \
    || fail "D d_oe3 not ordered max_ss > nom_tt > min_ff > 0.05 (${DOE[max_ss]} ${DOE[nom_tt]} ${DOE[min_ff]})"
fi
for v in $VARIANTS; do
  [ "$v" = D2 ] || [ "$v" = N2 ] || [ "$v" = N1 ] || continue
  for c in $(corners_of "$v"); do
    [ -s "$WORK/runs/${v}_$c/edit.log" ] || continue
    [ "$v" = D2 ] || { [ "$(grep -c '^--tt01: ' "$WORK/runs/${v}_$c/edit.log")" = 1 ] && grep -q '1 replacement' "$WORK/runs/${v}_$c/edit.log"; } || fail "$v $c --tt01 did not edit exactly one flop"
    [ "$v" = N1 ] || grep -q 'ports covered: 16 of 16' "$WORK/runs/${v}_$c/edit.log" || fail "$v $c pin-gate list does not cover 16 ports"
  done
done
if [ -z "$FAILS" ]; then echo "WO34 PASS"; else echo "WO34 FAIL$FAILS"; fi
