#!/bin/bash
# Converts a LibreLane gate-level netlist (nl, no power pins) of the TT top into plain Verilog that Verilator can read
# (the PDK's cell models use UDPs, which it cannot). The cell functions come from the PDK's tt liberty, through yosys
# read_liberty; the netlist is flattened; rf_top stays a cell (src/rf_top.v models it, compile that next to the output).
#
#   gl2verilator.sh NETLIST=<nl.v> OUT=<dir> [PDKLIB=<sky130_fd_sc_hd dir>] [TOP=tt_um_alfadelta10010_alphaone_soc]
#
# Writes OUT/gate.v (the model), OUT/report.txt (the checks below) and OUT/yosys.log. Exit 1 when a check fails.
#   1. cell coverage: every cell type the netlist instantiates is either a logic cell whose function the liberty gives
#      (proved against the PDK's own Verilog model by cell_check.py, run separately) or a physical-only cell
#      (fill, decap, tap, diode) that has no output pin in the PDK's blackbox model; anything else fails here.
#   2. sequential cells: flops in (dfxtp/dfrtp/dfstp...) == flops out ($_DFF_* cells); no latch cell in or out.
#   3. rf_top instances in == out; top-level port list unchanged; the gate.v does not instantiate any sky130 cell.
set -u
for a in "$@"; do case $a in *=*) export "${a%%=*}=${a#*=}";; esac; done
: "${NETLIST:?NETLIST=}"; : "${OUT:?OUT=}"
TOP=${TOP:-tt_um_alfadelta10010_alphaone_soc}
R=$(cd "$(dirname "$0")/../.." && pwd)
PDKV=${PDKV:-8afc8346a57fe1ab7934ba5a6056ea8b43078e71}
PDKLIB=${PDKLIB:-/home/mempool/tt/pdk/ciel/sky130/versions/$PDKV/sky130A/libs.ref/sky130_fd_sc_hd}
LIB=$PDKLIB/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
BB=$PDKLIB/verilog/sky130_fd_sc_hd__blackbox.v
YOSYS=${YOSYS:-yosys}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd); REP=$OUT/report.txt; : > "$REP"
rep() { echo "$*" | tee -a "$REP"; }
fail=0; bad() { rep "FAIL: $*"; fail=1; }
md5sum "$NETLIST" "$LIB" "$R/src/rf_top.v" | tee -a "$REP"
# the cell types the netlist uses, with counts
grep -oE '^ *sky130_fd_sc_hd__[a-z0-9_]+' "$NETLIST" | tr -d ' ' | sort | uniq -c | sort -rn > "$OUT/cells.txt"
rep "cell types used: $(wc -l < "$OUT/cells.txt"), instances: $(awk '{s+=$1} END {print s}' "$OUT/cells.txt")"
# 1. physical-only cells: no output pin in the PDK's blackbox model
phys=$(awk '{print $2}' "$OUT/cells.txt" | grep -E '__(fill|decap|tap|tapvpwrvgnd|diode)_[0-9]+$' || true)
for c in $phys; do
  # the blackbox module's body: `output` lines between "module <c>" and endmodule
  if awk -v c="$c" '$0 ~ "^module "c"[ (]" {on=1} on && /^ *output/ {o=1} on && /endmodule/ {exit} END {exit !o}' "$BB"; then
    bad "$c has an output pin but is dropped as physical-only"; fi
done
rep "physical-only cells dropped (no output pin): $(for c in $phys; do echo -n "$c=$(awk -v c=$c '$2==c{print $1}' "$OUT/cells.txt") "; done)"
awk '{print $2}' "$OUT/cells.txt" | grep -vE '__(fill|decap|tap|tapvpwrvgnd|diode)_[0-9]+$' > "$OUT/logic_cells.txt"
rep "logic/sequential cell types to prove with cell_check.py: $(wc -l < "$OUT/logic_cells.txt") (list: $OUT/logic_cells.txt)"
for c in $(cat "$OUT/logic_cells.txt"); do case $c in
  *__df*|*__sdf*|*__edf*|*__sedf*) ;;                                  # flops, counted below
  *__dlx*|*__dlr*|*__dlclkp*|*__sdlclkp*|*__lpflow_inputisolatch*) bad "latch/clock-gate cell $c is used: not modelled";;
esac; done
nff_in=$(awk '$2 ~ /__(df|sdf|edf|sedf)/ {s+=$1} END {print s+0}' "$OUT/cells.txt")
nrf_in=$(grep -cE '^ *rf_top ' "$NETLIST")
# the conversion
cat > "$OUT/conv.ys" <<Y
read_liberty -overwrite -ignore_miss_func -ignore_miss_dir $LIB
read_verilog -DSYNTHESIS -sv $R/src/rf_top.v
read_verilog $NETLIST
hierarchy -top $TOP
flatten
delete t:\$scopeinfo
select -assert-none t:sky130_fd_sc_hd__* t:*__fill_* t:*__decap_* %u t:*__tapvpwrvgnd_* %u t:*__diode_* %u %d
delete t:sky130_fd_sc_hd__*
opt_clean
check
tee -o $OUT/stat.txt stat
write_verilog -noattr $OUT/gate.v
Y
$YOSYS -q -l "$OUT/yosys.log" "$OUT/conv.ys" || { bad "yosys failed (see $OUT/yosys.log)"; exit 1; }
nff_out=$(awk '$2 ~ /^\$_(DFF|SDFF|DFFE|ADFF)/ {s+=$1} END {print s+0}' "$OUT/stat.txt")
nlat_out=$(awk '$2 ~ /^\$_(DLATCH|SR|ALDFF|DFFSR)/ {s+=$1} END {print s+0}' "$OUT/stat.txt")
nrf_out=$(awk '$2=="rf_top" {print $1}' "$OUT/stat.txt")
rep "flops: netlist $nff_in, model $nff_out; latches in model $nlat_out; rf_top: netlist $nrf_in, model ${nrf_out:-0}"
[ "$nff_in" = "$nff_out" ] || bad "flop count differs"
[ "$nlat_out" = 0 ] || bad "latch-like cells in the model"
[ "$nrf_in" = "${nrf_out:-0}" ] || bad "rf_top count differs"
grep -qE '^ *\\?sky130_fd_sc_hd__[a-z0-9_]+ ' "$OUT/gate.v" && bad "gate.v still instantiates a sky130 cell"
grep -qE '^ *(wor|wand|tri)' "$OUT/gate.v" && bad "wired nets in gate.v"
grep -iE 'warning|multiple drivers|undriven|loop' "$OUT/yosys.log" | sort | uniq -c | head -20 | tee -a "$REP"
rep "model: $(wc -l < "$OUT/gate.v") lines, md5 $(md5sum < "$OUT/gate.v" | cut -c1-32)"
[ $fail = 0 ] && rep "RESULT: conversion checks passed" || rep "RESULT: conversion checks FAILED"
exit $fail
