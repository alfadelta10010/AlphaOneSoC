#!/bin/bash
# Runs a list of programs through tb/tb_tt_um.v on a gate-level netlist (or the RTL).
#
#   run_gl.sh NETLIST=<pnl.v> | RTL=1   LIST=<list file> OUT=<run dir>
#             [JOBS=<n>|auto] [BASE=<RTL run dir>] [ONLY=<regex>] [PDK_ROOT=<dir>] [CELLS=<dir>]
#
# LIST lines are `name|hex|plusargs` (build_isa.sh). The hex is looked up in HEXDIR
# (default: the list's own directory/hex); @RUN@ in the plusargs is OUT.
# One compile, then the list with JOBS vvp processes (auto: 2 while the file
# Q3DONE is missing, else 5). Resumable: a test with a <name>.verdict is skipped.
# Per test OUT/<name>.log and OUT/<name>.verdict:
#   `PASS|FAIL|TIMEOUT <cycles> cycles <wall> s [known: <label>]`
# MAX_CYCLES = BASE's cycles * 2 + 50000, else DEFMAX (5,000,000). The last
# step is OUT/summary (counts, wall time, slowest test).
# The cell models are PDK_ROOT's ciel version 8afc8346 (the harden's), or CELLS=<dir>
# (primitives.v, sky130_fd_sc_hd.v) for the local smoke run.
set -u
for a in "$@"; do case $a in *=*) export "${a%%=*}=${a#*=}";; esac; done
: "${LIST:?LIST=}"; : "${OUT:?OUT=}"
R=$(cd "$(dirname "$0")/../.." && pwd)
IVERILOG=${IVERILOG:-iverilog}; VVP=${VVP:-vvp}
JOBS=${JOBS:-auto}; DEFMAX=${DEFMAX:-5000000}; WALL=${WALL:-14400}
Q3DONE=${Q3DONE:-$HOME/regr/eqy/runs/q3/RUN_DONE}
HEXDIR=${HEXDIR:-$(dirname "$LIST")/hex}
LIST=$(realpath "$LIST"); HEXDIR=$(realpath "$HEXDIR"); [ -n "${BASE:-}" ] && BASE=$(realpath "$BASE")
PDKV=${PDKV:-8afc8346a57fe1ab7934ba5a6056ea8b43078e71}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
t0=$SECONDS
log() { echo "$(date -Is) $*" >> "$OUT/STATUS"; }
if [ "${RTL:-0}" = 1 ]; then
  SRC="$R/src/alu.v $R/src/branchCtrl.v $R/src/clint.v $R/src/compressed_decoder.v $R/src/controller.v $R/src/csr.v $R/src/decoder.v $R/src/fyracore.v $R/src/muldiv.v $R/src/pmp.v $R/src/regFile.v $R/src/regs.v $R/src/rf_top.v $R/src/signExt.v $R/src/qspi_ctrl.v $R/src/mem_ctrl.v $R/src/soc_bus.v $R/src/uart.v $R/src/gpio.v $R/src/syscon.v $R/src/alphaone_soc.v $R/src/tt_um_alfadelta10010_alphaone_soc.v"
  DEFS=""
else
  : "${NETLIST:?NETLIST= or RTL=1}"
  CD=${CELLS:-${PDK_ROOT:?PDK_ROOT=}/ciel/sky130/versions/$PDKV/sky130A/libs.ref/sky130_fd_sc_hd/verilog}
  DEFS="-DGL_TEST -DFUNCTIONAL -DSIM -DUNIT_DELAY=#1"
  grep -qm1 'inout VPWR' "$NETLIST" && DEFS="$DEFS -DUSE_POWER_PINS"
  SRC="$CD/primitives.v $CD/sky130_fd_sc_hd.v $NETLIST $R/src/rf_top.v"
  md5sum $CD/primitives.v $CD/sky130_fd_sc_hd.v "$NETLIST" > "$OUT/files.md5"
fi
if [ ! -e "$OUT/done.compile" ]; then
  log "compile ($DEFS)"
  $IVERILOG -g2012 -I "$R/src" $DEFS -o "$OUT/sim" -s tb_tt_um $SRC $R/tb/qspi_pmod_model.v $R/tb/rp2350_uart_model.v $R/tb/tb_tt_um.v > "$OUT/compile.log" 2>&1 \
    || { log "COMPILE FAILED"; exit 1; }
  touch "$OUT/done.compile"; log "compiled"
fi
limit() { if [ "$JOBS" = auto ]; then [ -e "$Q3DONE" ] && echo 5 || echo 2; else echo "$JOBS"; fi; }
run_one() { # name hex args
  local name=$1 hex=$2 args=${3//@RUN@/$OUT} mc=$DEFMAX s=$SECONDS c v lab=""
  if [ -n "${BASE:-}" ] && [ -s "$BASE/$name.verdict" ]; then
    c=$(awk '{print $2}' "$BASE/$name.verdict"); [[ $c =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] && mc=$(( c * 2 + 50000 ))
  fi
  ( cd "$OUT" && timeout -k 10 $WALL $VVP -n sim +FLASH_FILE="$HEXDIR/$hex.hex" +RF_X +RF_COLLIDE_X $args +MAX_CYCLES=$mc > "$name.log" 2>&1 )
  if grep -q '^PASS tb_tt_um' "$OUT/$name.log" && ! grep -qE '^(FAIL|ERROR)' "$OUT/$name.log"; then v=PASS
  elif grep -q '^TIMEOUT' "$OUT/$name.log"; then v=TIMEOUT; else v=FAIL; fi
  c=$(grep -oE '[0-9]+ cycles\)$|stuck at cycle [0-9]+|\(cycle [0-9]+\)' "$OUT/$name.log" | grep -oE '[0-9]+' | tail -1)
  [ -n "${KNOWN:-}" ] && lab=$(awk -v n="$name" '$1==n{$1="";print}' "$KNOWN")
  echo "$v ${c:-0} cycles $((SECONDS - s)) s${lab:+ known:$lab}" > "$OUT/$name.verdict"
  log "$name $(cat "$OUT/$name.verdict")"
}
KNOWN=${KNOWN:-$R/scripts/gl/known.txt}
log "start $(basename "$LIST") jobs=$JOBS"
while IFS='|' read -r name hex args; do
  [ -n "$name" ] || continue
  [ -n "${ONLY:-}" ] && ! [[ $name =~ $ONLY ]] && continue
  [ -e "$OUT/$name.verdict" ] && continue
  while [ "$(jobs -rp | wc -l)" -ge "$(limit)" ]; do sleep 3; done
  run_one "$name" "$hex" "$args" &
done < "$LIST"
wait
{ echo "run $OUT  list $LIST  wall $((SECONDS - t0)) s"
  for v in PASS FAIL TIMEOUT; do echo "$v $(cat "$OUT"/*.verdict | grep -c "^$v")"; done
  # isa/sig PASS must show the power-off seen at the pins (tb prints POWEROFF); a PASS without it counts as FAIL
  pm=0; pn=0
  for f in "$OUT"/*.verdict; do n=$(basename "$f" .verdict)
    if grep -q '^PASS' "$f" && grep -qE '^PASS tb_tt_um (isa|sig) ' "$OUT/$n.log"; then
      pn=$((pn + 1)); if grep -q '^POWEROFF seen at cycle' "$OUT/$n.log"; then pm=$((pm + 1)); else echo "FAIL (no POWEROFF line): $n" >> "$OUT/summary.nopo"; fi
    fi
  done
  echo "poweroff-logged: $pm of $pn"
  [ "$pm" -eq "$pn" ] || { echo "FAIL: $((pn - pm)) isa/sig PASS without a POWEROFF line:"; sed 's/^/  /' "$OUT/summary.nopo"; }
  rm -f "$OUT/summary.nopo"
  echo "known-labelled: $(grep -l ' known:' "$OUT"/*.verdict 2>/dev/null | wc -l)"
  echo "slowest: $(for f in "$OUT"/*.verdict; do echo "$(awk '{print $4}' "$f") $(basename "$f" .verdict)"; done | sort -rn | head -1)"
  echo "not PASS:"; grep -L '^PASS' "$OUT"/*.verdict 2>/dev/null | xargs -r -n1 basename | sed 's/.verdict//' | while read -r n; do echo "  $n: $(cat "$OUT/$n.verdict")"; done
} > "$OUT/summary"
log "done $(basename "$LIST")"; touch "$OUT/done.run.$(basename "$LIST")"
