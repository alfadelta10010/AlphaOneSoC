#!/bin/bash
# One unattended gate-level night, resumable (a done.<stage> marker per stage):
#   1 rtl-*  the RTL baseline through the same bench, parts A B C
#   2 gl-*   the pnl netlist, parts A B C, MAX_CYCLES from the baseline
#   3 mut-*  non-vacuity: a mutated netlist must fail a program of the short list
#   night.sh D=<run dir> NETLIST=<pnl> BUILD=<build_isa OUT> [JOBS=auto] [PARTS="A B C"]
# PARTS=D is the mailbox programs through the pins (WO-26): rtl-D10, rtl-D20 (the
# RTL baseline, a 10 ns and a 20 ns clock), gl-D10, gl-D20, then mut-D, a stuck
# SPI MOSI that only these programs (and tt_pins.0) can see. Each has its own
# done.<stage> marker and its own directory under D.
# STATUS has a timestamped line per event; D/RUN_DONE is the last file written.
# The caller starts the thermal watchdog on D (see the launch command in the report).
for a in "$@"; do case $a in *=*) export "${a%%=*}=${a#*=}";; esac; done
: "${D:?}"; : "${NETLIST:?}"; : "${BUILD:?}"; JOBS=${JOBS:-auto}; PARTS=${PARTS:-A B C}
has() { case " $PARTS " in *" $1 "*) return 0;; esac; return 1; }
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
cat $BUILD/list.A $BUILD/list.B $BUILD/list.C > $BUILD/list.all 2>/dev/null
{ md5sum $NETLIST; ls -l $NETLIST; spike --help 2>&1 | head -1; iverilog -V 2>&1 | head -1; } > "$D/env.txt" 2>&1
for p in A B C; do has $p && stage rtl-$p rtl $p; done
for p in A B C; do has $p && stage gl-$p gl $p; done
SHORT='^(rv32mi-csr-p|rv32mi-mcsr-p|rv32ui-add-p|rv32ui-addi-p|add-01|tt_pins\.0)$'
if has A || has B || has C; then
for k in csr alu; do
  mut() {
    python3 $S/mutate_netlist.py $NETLIST $D/mut-$k.v --kind $k > $D/mut-$k.txt 2>&1 || return
    bash $S/run_gl.sh NETLIST=$NETLIST LIST=$BUILD/list.all OUT=$D/mut-$k BASE=$D/rtl JOBS=$JOBS ONLY="$SHORT" > /dev/null 2>&1
  }
  stage mut-$k mut
done
fi
if has D; then
  tclk() { case $1 in D20) echo 20.0;; *) echo 10.0;; esac; }
  rtld() { bash $S/run_gl.sh RTL=1 LIST=$BUILD/list.$1 TCLK=$(tclk $1) OUT=$D/rtl-$1 JOBS=$JOBS > /dev/null 2>&1; }
  gld()  { bash $S/run_gl.sh NETLIST=$NETLIST LIST=$BUILD/list.$1 TCLK=$(tclk $1) OUT=$D/gl-$1 BASE=$D/rtl-$1 JOBS=$JOBS > /dev/null 2>&1; }
  # the mutant: the SPI MOSI flop's D tied low. Part D's oled_spi and periph_access
  # (20 ns) and part A's tt_pins.0 (10 ns, which never sees MOSI) must say so.
  mutd() {
    python3 $S/mutate_netlist.py $NETLIST $D/mut-spi.v --kind spi > $D/mut-spi.txt 2>&1 || return
    bash $S/run_gl.sh NETLIST=$D/mut-spi.v LIST=$BUILD/list.D20 TCLK=20.0 OUT=$D/mut-D20 BASE=$D/rtl-D20 JOBS=$JOBS ONLY='^(oled_spi|periph_access)$' > /dev/null 2>&1
    bash $S/run_gl.sh NETLIST=$D/mut-spi.v LIST=$BUILD/list.A OUT=$D/mut-A10 JOBS=$JOBS ONLY='^tt_pins\.0$' > /dev/null 2>&1
  }
  for l in D10 D20; do stage rtl-$l rtld $l; done
  for l in D10 D20; do stage gl-$l gld $l; done
  stage mut-D mutd
fi
st "all stages done"; touch "$D/RUN_DONE"
