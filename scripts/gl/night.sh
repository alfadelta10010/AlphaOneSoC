#!/bin/bash
# One unattended gate-level night, resumable (a done.<stage> marker per stage):
#   1 rtl-*  the RTL baseline through the same bench, parts A B C (TCLK 19 ns, the 4x4 chip's clock)
#   2 mut-*  non-vacuity: a mutated netlist must fail a program of the short list
#            (the stage ends rc=1 and STATUS says so when every program passes)
#   3 gl-*   the pnl netlist, parts A D B C in that order, MAX_CYCLES from the baseline; each program of D must
#            take exactly the RTL's cycles (run_gl.sh)
#   night.sh D=<run dir> NETLIST=<pnl> BUILD=<build_isa OUT> [JOBS=auto] [PARTS="A B C"]
# PARTS=D is the mailbox programs through the pins (WO-26, refreshed for 4x4 in WO-GLN): rtl-D (the
# RTL baseline, a 19 ns clock), gl-D, then mut-D: stuck-at-0 flops that only these programs
# can see (SPI MOSI, a PLIC enable, a gamepad data bit, a PWM compare bit), each run on the program that must catch it.
# Each stage has its own done.<stage> marker and its own directory under D.
# CACHE_EN=1 (environment) forces the instruction cache on in every run, RTL baseline and netlist alike.
# TCLK is 19.0 (52.63 MHz) for every part.
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
  local n=$1 rc; shift
  [ -e "$D/done.$n" ] && return
  st "stage $n start"; "$@"; rc=$?
  # CHK="<run dir> <list>": a stage whose run left a program without log or PASS line, a TIMEOUT, or a FAIL that
  # known.txt does not label, ends non-zero, whatever the run script returned
  if [ $rc -eq 0 ] && [ -n "${CHK:-}" ]; then notpass $CHK || rc=1; fi
  st "stage $n end rc=$rc"; touch "$D/done.$n"
}
notpass() { # run dir, list file: every program of the list needs a non-empty log and a verdict; a PASS needs its PASS line in the log;
  # TIMEOUT, and FAIL without a known.txt label (verdict ' known:'), are not accepted. Names the offenders in STATUS, returns 1 if any.
  local d=$1 l=$2 n v bad=0
  while IFS='|' read -r n _; do
    [ -n "$n" ] || continue
    [ -s "$d/$n.log" ] || { st "$n: log empty or missing in $d"; bad=1; continue; }
    [ -s "$d/$n.verdict" ] || { st "$n: no verdict in $d"; bad=1; continue; }
    v=$(cat "$d/$n.verdict")
    case $v in
      PASS*) grep -q '^PASS tb_tt_um' "$d/$n.log" || { st "$n: verdict PASS but no PASS line in the log"; bad=1; } ;;
      *" known:"*) ;;
      *) st "$n: $v (not PASS and not labelled in known.txt)"; bad=1 ;;
    esac
  done < "$l"
  return $bad
}
caught() { # dir: some program of a mutant run must FAIL or TIMEOUT (a hang is a detection too)
  grep -qsE '^(FAIL|TIMEOUT)' "$1"/*.verdict || { st "$(basename "$1"): every program passed: the mutant was not caught"; return 1; }
}
evid() { # mutant evidence: md5 of both netlists and the number of changed lines, appended to mut-*.txt and STATUS
  local n=$1 c; c=$(diff $NETLIST $D/$n.v | grep -c '^>')
  { md5sum $NETLIST $D/$n.v; echo "changed lines: $c"; } >> $D/$n.txt
  st "$n: mutant $(md5sum < $D/$n.v | cut -c1-12) vs pnl $(md5sum < $NETLIST | cut -c1-12), $c changed line(s): $(head -1 $D/$n.txt | cut -c1-150)"
  [ "$c" = 1 ] || { st "$n: VOID mutant ($c changed lines, want exactly 1): no mutant simulated"; return 1; }
}
cat $BUILD/list.A $BUILD/list.B $BUILD/list.C > $BUILD/list.all 2>/dev/null
{ md5sum $NETLIST; ls -l $NETLIST; spike --help 2>&1 | head -1; iverilog -V 2>&1 | head -1; } > "$D/env.txt" 2>&1
# the Spike reference signatures of part C are part of the build (run_gl.sh refuses a list line whose
# SIG_REF file is missing or empty, so a night without them stops at once instead of failing 104 programs)
if has C; then
  bash $S/spike_sig.sh OUT=$BUILD > "$D/spike_sig.log" 2>&1
  for r in $(grep -oE 'SIG_REF=[^ ]+' $BUILD/list.C | cut -d= -f2); do
    [ -s "$r" ] || { st "no refs: $r missing or empty"; exit 1; }
  done
fi
TC=${TCLK:-19.0}
rtl() { bash $S/run_gl.sh RTL=1 LIST=$BUILD/list.$1 TCLK=$TC OUT=$D/rtl JOBS=$JOBS > /dev/null 2>&1; }
gl()  { bash $S/run_gl.sh NETLIST=$NETLIST LIST=$BUILD/list.$1 TCLK=$TC OUT=$D/gl BASE=$D/rtl JOBS=$JOBS > /dev/null 2>&1; }
for p in A B C; do has $p && CHK="$D/rtl $BUILD/list.$p" stage rtl-$p rtl $p; done
SHORT='^(rv32mi-csr-p|rv32mi-mcsr-p|rv32ui-add-p|rv32ui-addi-p|add-01|tt_pins\.0)$'
if has A || has B || has C; then
for k in csr alu; do
  mut() {
    python3 $S/mutate_netlist.py $NETLIST $D/mut-$k.v --kind $k > $D/mut-$k.txt 2>&1 || { st "mut-$k: COULD NOT MUTATE (no mutant simulated): $(tail -1 $D/mut-$k.txt)"; return 2; }
    evid mut-$k || return 2
    bash $S/run_gl.sh NETLIST=$D/mut-$k.v LIST=$BUILD/list.all TCLK=$TC OUT=$D/mut-$k BASE=$D/rtl JOBS=$JOBS ONLY="$SHORT" > /dev/null 2>&1
    caught $D/mut-$k
  }
  stage mut-$k mut
done
fi
if has D; then
  tclk() { echo $TC; }
  rtld() { bash $S/run_gl.sh RTL=1 LIST=$BUILD/list.$1 TCLK=$(tclk $1) OUT=$D/rtl-$1 JOBS=$JOBS > /dev/null 2>&1; }
  gld()  { bash $S/run_gl.sh NETLIST=$NETLIST LIST=$BUILD/list.$1 TCLK=$(tclk $1) OUT=$D/gl-$1 BASE=$D/rtl-$1 JOBS=$JOBS > /dev/null 2>&1; }
  # one mutant: stuck-at-0 on a flop's D, the program(s) that must FAIL or TIMEOUT (a mutated netlist that passes is a hole)
  #   mutd <name> <list> <ONLY regex> <mutate_netlist.py args...>
  mutd1() {
    local n=$1 l=$2 only=$3; shift 3
    python3 $S/mutate_netlist.py $NETLIST $D/mut-$n.v "$@" > $D/mut-$n.txt 2>&1 || { st "mut-$n: COULD NOT MUTATE (no mutant simulated): $(tail -1 $D/mut-$n.txt)"; return 2; }
    evid mut-$n || return 2
    bash $S/run_gl.sh NETLIST=$D/mut-$n.v LIST=$BUILD/list.$l TCLK=$(tclk $l) OUT=$D/mut-$n BASE=$D/rtl-$l JOBS=$JOBS ONLY="$only" > /dev/null 2>&1
    caught $D/mut-$n
  }
  mutd() {
    local rc=0 r
    worst() { [ "$1" -gt "$rc" ] && rc=$1; }     # the worst rc of the mutants (2 = void or not made, 1 = not caught)
    # the SPI MOSI flop (WO-40: part A's tt_pins.0 wants uo_out[1] too; part A is built here when PARTS has no A)
    rm -f $D/mut-spi.v                             # never run mut-A19 on a stale mutant of an earlier attempt
    mutd1 spi D '^(oled_spi|periph_access)$' --kind spi; r=$?; worst $r
    if [ $r -eq 0 ] || [ $r -eq 1 ]; then
      [ -s $BUILD/list.A ] || { bash $S/build_isa.sh PARTS=A OUT=$D/build-A > /dev/null 2>&1; }
      LA=$BUILD/list.A; [ -s $LA ] || LA=$D/build-A/list.A
      st "mut-A19: the mutant of mut-spi ($(md5sum < $D/mut-spi.v | cut -c1-12)) on tt_pins.0"
      bash $S/run_gl.sh NETLIST=$D/mut-spi.v LIST=$LA TCLK=$TC OUT=$D/mut-A19 JOBS=$JOBS ONLY='^tt_pins\.0$' > /dev/null 2>&1
      caught $D/mut-A19 || worst 1
    else st "mut-A19: not run, mut-spi was not made"; fi
    mutd1 plic D '^plic_uart$' --kind net --q '\soc.plic_inst.en[1]'; worst $?          # the UART's PLIC enable
    mutd1 pad D '^gamepad$' --kind net --q '\soc.gamepad_inst.d[0]'; worst $?           # a gamepad data bit (0x123 has bit 0)
    mutd1 pwm D '^pwm_linux$' --kind net --q '\soc.pwm_inst.cmp0[14]'; worst $?         # a PWM compare bit (periods 0x4001 / 0x10000)
    return $rc
  }
  CHK="$D/rtl-D $BUILD/list.D" stage rtl-D rtld D
  stage mut-D mutd
fi
# the gate-level stages last, the short ones first (the mutants above only need the RTL baselines)
for p in A D B C; do has $p || continue; if [ $p = D ]; then CHK="$D/gl-D $BUILD/list.D" stage gl-D gld D; else CHK="$D/gl $BUILD/list.$p" stage gl-$p gl $p; fi; done
st "all stages done"; touch "$D/RUN_DONE"
