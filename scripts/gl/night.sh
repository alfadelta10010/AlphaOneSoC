#!/bin/bash
# One unattended gate-level night, resumable (a done.<stage> marker per stage):
#   1 rtl-*  the RTL baseline through the same bench, parts A B C
#   2 gl-*   the pnl netlist, parts A B C, MAX_CYCLES from the baseline
#   3 mut-*  non-vacuity: a mutated netlist must fail a program of the short list
#   night.sh D=<run dir> NETLIST=<pnl> BUILD=<build_isa OUT> [JOBS=auto]
# STATUS has a timestamped line per event; D/RUN_DONE is the last file written.
# The caller starts the thermal watchdog on D (see the launch command in the report).
for a in "$@"; do case $a in *=*) export "${a%%=*}=${a#*=}";; esac; done
: "${D:?}"; : "${NETLIST:?}"; : "${BUILD:?}"; JOBS=${JOBS:-auto}
export PATH=/home/mempool/tools/rv64-gcc-elf/bin:/home/mempool/tools/rv32-isa-sim/bin:/home/mempool/tt/iverilog13/usr/bin:$PATH
export PDK_ROOT=${PDK_ROOT:-/home/mempool/tt/pdk}
S=$(cd "$(dirname "$0")" && pwd); mkdir -p "$D"
ps -o sid= -p $$ | tr -d ' ' > "$D/driver.sid"; echo $$ > "$D/driver.pid"
st() { echo "$(date -Is) $*" >> "$D/STATUS"; }
stage() { # name command...
  local n=$1; shift
  [ -e "$D/done.$n" ] && return
  st "stage $n start"; "$@"; st "stage $n end rc=$?"; touch "$D/done.$n"
}
rtl() { bash $S/run_gl.sh RTL=1 LIST=$BUILD/list.$1 OUT=$D/rtl JOBS=$JOBS > /dev/null 2>&1; }
gl()  { bash $S/run_gl.sh NETLIST=$NETLIST LIST=$BUILD/list.$1 OUT=$D/gl BASE=$D/rtl JOBS=$JOBS > /dev/null 2>&1; }
cat $BUILD/list.A $BUILD/list.B $BUILD/list.C > $BUILD/list.all
{ md5sum $NETLIST; ls -l $NETLIST; spike --help 2>&1 | head -1; iverilog -V 2>&1 | head -1; } > "$D/env.txt" 2>&1
for p in A B C; do stage rtl-$p rtl $p; done
for p in A B C; do stage gl-$p gl $p; done
SHORT='^(rv32mi-csr-p|rv32mi-mcsr-p|rv32ui-add-p|rv32ui-addi-p|add-01|tt_pins\.0)$'
for k in csr alu; do
  mut() {
    python3 $S/mutate_netlist.py $NETLIST $D/mut-$k.v --kind $k > $D/mut-$k.txt 2>&1 || return
    bash $S/run_gl.sh NETLIST=$D/mut-$k.v LIST=$BUILD/list.all OUT=$D/mut-$k BASE=$D/rtl JOBS=$JOBS ONLY="$SHORT" > /dev/null 2>&1
  }
  stage mut-$k mut
done
st "all stages done"; touch "$D/RUN_DONE"
