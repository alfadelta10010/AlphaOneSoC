#!/bin/bash
# run.sh — directed regression for FyraCore against Spike.
#
#   ./run.sh build              rebuild the sim from ../../src and ../../tb
#   ./run.sh                    every run listed in MANIFEST
#   ./run.sh one <name> [+PLUSARG...]
#   ./run.sh refs [<name>...]   regenerate the Spike reference of every test,
#                               or only of the tests named
#   ./run.sh soc                every test in MANIFEST through the whole SoC
#   ./run.sh soc build | soc one <name> [+PLUSARG...]
#                               the same two, for the SoC build
#
# `soc` builds tb_rivercore with -DSOC_TB: the core runs through the bus
# fabric, memory controller and QSPI engine against a behavioural QSPI Pmod
# (tb/qspi_pmod_model.v) instead of tb/memory_model.v's ideal memory, and is
# compared against the same Spike references. The memory-timing plusargs
# (+IMEM_WAIT and friends) belong to memory_model and do nothing there, so
# each test runs once, with the first MANIFEST line that names it. Artifacts
# go to ./out/soc.
#
# MANIFEST has one run per line:
#
#   <name> spike  [+PLUSARG...]
#       Full-trace comparison: the DUT's commit log must equal <name>.ref
#       (Spike's commit log up to the tohost store) line for line, and must
#       itself reach the tohost store.
#
#   <name> expect <reg>=<hex>[|<hex>...]... [-- +PLUSARG...]
#       DUT only, for a deliberate, spec-legal divergence from Spike: the
#       final value of each listed register must be one of the values given.
#       The comment above the line says why the test cannot be
#       Spike-compared, and why more than one value is legal where it is.
#
#   <name> flash
#       SoC only: <name>.S is linked with <name>.ld into flash at
#       0x2000_0000 and loaded into the QSPI model's flash, which is where
#       the SoC boots. Then compared with Spike like `spike`, traced from
#       reset. (Other tests boot straight into their PSRAM image: the
#       testbench forces the core's boot_addr to 0x8000_0000.) The
#       core-level run skips it.
#
#   <name> soc <spike|expect ...>
#       SoC only, and run there even when an earlier line already ran the
#       test: the rest of the line is a `spike` or `expect` line as above.
#       For the SoC's own plusargs -- the QSPI Pmod model's hand-over states
#       and delays, the rd_late strap -- and for SoC-speed variants of
#       tests the SoC run otherwise skips. The core-level run skips it.
#
#   #soc-skip <name>... -- <reason>
#       The SoC-level run skips these tests. For tests whose point depends on
#       a fast memory (a timer period shorter than a QSPI-speed handler).
#
# Every run fails on: an assembly error, a testbench ERROR line (e.g. the
# memory handshake checker), a DUT-ABORT (watchdog), an empty dump, an X or
# Z digit anywhere in the dump, or not reaching tohost. Every .S in this
# directory must appear in MANIFEST, so a test cannot silently drop out of
# the suite.
#
# With RUN_PLUSARGS=+SOC_DDR=1 the SoC run puts the flash reads in DDR (EDh). A
# MANIFEST line that sets +QSPI_DELAY pairs the model's round-trip delay with the
# SDR capture point, which a forced DDR capture point cannot read, so the runner
# prints "SKIP <name> (DDR corner: fixed-delay line)" for it and counts it in the
# REGRESS line. The DDR timing corners are covered by `make test-qspi-ddr-sweep`
# and by tb/qspi_ddr_sweep.sh, which pair each delay with its capture point.
#
# RUN_PLUSARGS is added to every simulation, e.g. RUN_PLUSARGS=+RF_X starts
# the registers at X instead of 0 (src/regFile.v), so a test that reads a
# register it never wrote fails on the X it leaves in the dump -- unless
# the value only decides a branch that falls through on Spike as well
# (src/regFile.v says why). +RF_COLLIDE_X makes the register-file macro's
# model return X for a read of the word written on the same edge, which the
# core must never use (src/regFile.v bypasses it); the suite is run with
# RUN_PLUSARGS="+RF_X +RF_COLLIDE_X" as well as plain.
#
# Tests live beside this script, artifacts go to ./out (gitignored).
# Toolchain: riscv64-unknown-elf-*, spike and iverilog on PATH.
#
# For mutation testing (tb/mutate/run.py) three environment variables
# point a run somewhere else; none changes what a run checks:
#   FYRA_SRC=<dir>  build the simulator from this copy of src/
#   OUT_DIR=<dir>   artifacts there instead of ./out (./out/soc for soc)
#   FAILFAST=1      stop the suite at its first failing run
#   SIMULATOR=verilator  build with Verilator (--binary --timing) instead of
#                   Icarus; same testbench, same references (artifacts go to
#                   ./out/vl, ./out/vl/soc). Two-state: the X checks below are
#                   refused (an error) or not made; Icarus is their reference.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
SOC=0
[ "${1:-}" = soc ] && { SOC=1; shift; }
SRC="${FYRA_SRC:-$ROOT/src}"
OUT="${OUT_DIR:-$HERE/out}"
SIMULATOR="${SIMULATOR:-iverilog}"
if [ "$SIMULATOR" = verilator ]; then
  # Verilator is two-state: an X becomes a constant, so the checks that rest on X cannot run
  # on it (+RF_X, +RF_COLLIDE_X, the X-in-dump failure below, memory_model's NOTREADY_DATA=0
  # which drives X while not ready and here gives zeros). Icarus stays the reference for them.
  case " ${RUN_PLUSARGS:-} $* " in
    *RF_X*|*RF_COLLIDE_X*|*NOTREADY_DATA=0*)
      echo "ERROR: SIMULATOR=verilator cannot run X checks (RF_X, RF_COLLIDE_X, NOTREADY_DATA=0): use Icarus" >&2
      exit 2 ;;
  esac
  echo "NOTE: Verilator is two-state; the suite's X checks are not made on this run (Icarus makes them)" >&2
fi
[ "$SIMULATOR" = verilator ] && OUT="$OUT/vl"
[ $SOC = 1 ] && OUT="$OUT/soc"
mkdir -p "$OUT"
SPIKE_MEM="--hartids=0 --log-commits --priv=mu --isa=rv32imac_zicntr
            -m0x20000000:0x1000000,0x80000000:0x1000000 --pmpregions=4 --pmpgranularity=4"
SPIKE_ARGS="$SPIKE_MEM --pc=0x80000000"
TOHOST=80001000
# A test that needs a linker script of its own ships <name>.ld.
ld_for() { [ -f "$HERE/$1.ld" ] && echo "$HERE/$1.ld" || echo "$HERE/link.ld"; }

CORE_SRC=("$SRC"/{alu,branchCtrl,clint,compressed_decoder,controller,csr,decoder,fyracore,muldiv,pmp,regFile,rf_top,signExt}.v)
build() {
  local files defs=""
  if [ $SOC = 1 ]; then
    defs="-DSOC_TB"
    files=("${CORE_SRC[@]}" "$SRC"/{qspi_ctrl,mem_ctrl,soc_bus,uart,gpio,spi,syscon,alphaone_soc}.v
           "$ROOT"/tb/qspi_pmod_model.v "$ROOT"/tb/req_hold_check.v "$ROOT"/tb/tb_rivercore.v)
  else
    files=("${CORE_SRC[@]}" "$ROOT"/tb/memory_model.v "$ROOT"/tb/tb_rivercore.v)
  fi
  if [ "$SIMULATOR" = verilator ]; then
    # --timing keeps the models' # delays, so the run is timing-accurate.
    verilator --binary --timing -j 0 $defs -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH \
      -Wno-TIMESCALEMOD --top-module tb_rivercore -Mdir "$OUT/obj" -o ../sim \
      "${files[@]}" >"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; return 1; }
  else
    iverilog -g2012 $defs -o "$OUT/sim" -s tb_rivercore "${files[@]}" || return 1
  fi
  echo "build ok"
}

# Tests the MANIFEST boots from flash.
is_flash() { grep -qE "^$1 +flash( |\$)" "$HERE/MANIFEST"; }

asm() { # asm <name>
  local n=$1
  riscv64-unknown-elf-gcc -static -std=gnu99 -O0 -mcmodel=medany -nostdlib \
    -nostartfiles -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
    -T "$(ld_for "$n")" "$HERE/$n.S" -o "$OUT/$n.elf" 2>"$OUT/$n.asm.log" || return 1
  if is_flash "$n"; then
    # Only what lives in flash; the PSRAM side starts zeroed. (.straddle
    # is straddle_flash_end's last halfword of flash.)
    riscv64-unknown-elf-objcopy -O verilog -j .text.init -j .text -j .rodata -j .straddle \
      --change-addresses=-0x20000000 "$OUT/$n.elf" "$OUT/$n.hex"
  else
    riscv64-unknown-elf-objcopy -O verilog --change-addresses=-0x80000000 \
      "$OUT/$n.elf" "$OUT/$n.hex"
  fi
}

# Spike runs on past tohost (it only polls HTIF every few thousand steps),
# so the reference is cut four lines after the tohost store -- the testbench
# drains at most that many retires after it. Spike starts at --pc directly
# and logs no boot ROM, so nothing precedes the program. The mstatush/
# tcontrol/mtinst/mtval2 tokens Spike logs alongside trap entry and mstatus
# writes on RV32, for CSRs this core does not log, are dropped. A reference
# that never reaches tohost is capped instead.
ref() { # ref <name>
  local n=$1
  local args=$SPIKE_ARGS
  is_flash "$n" && args="$SPIKE_MEM --pc=0x20000000"
  ( ulimit -f 200000; timeout 60 spike $args --log "$OUT/$n.ref.raw" "$OUT/$n.elf" \
      </dev/null >/dev/null 2>&1 ) 2>/dev/null
  sed -E 's/ c[0-9]+_(mstatush|tcontrol|mtinst|mtval2) 0x[0-9a-f]+//g' "$OUT/$n.ref.raw" \
    | awk -v t="mem 0x$TOHOST " 'index($0, t) && !cut { cut = NR + 4 }
                                  { print } cut && NR >= cut { exit } NR >= 20000 { exit }' \
    > "$HERE/$n.ref"
}

# Every QSPI access costs about 60 clocks, so the SoC gets a larger backstop.
MAXC=400000
[ $SOC = 1 ] && MAXC=30000000

RUNSIM=vvp; [ "$SIMULATOR" = verilator ] && RUNSIM=
sim() { # sim <name> <plusargs...>
  local n=$1; shift
  local image=+INIT_FILE="$OUT/$n.hex"
  is_flash "$n" && image="+FLASH_FILE=$OUT/$n.hex"
  $RUNSIM "$OUT/sim" $image +DUMP_FILE="$OUT/$n.dut" \
      +TOHOST_ADDR=$TOHOST +MAX_CYCLES=$MAXC "$@" ${RUN_PLUSARGS:-} >"$OUT/$n.sim.log" 2>&1
}

# Spike pads single-digit register names to width 3 ("x8  0x..."), so both
# traces are compared with runs of spaces squeezed, and register values are
# extracted with ' +'. A single-space pattern silently matches x10-x31 only.
# rd() keeps x/z digits, so a register whose last write was X reads back as
# X rather than as its last hex value.
norm() { sed -E 's/ +/ /g' "$1"; }
rd()   { grep -oE "\b$2 +0x[0-9a-fxzXZ]+" "$1" 2>/dev/null | tail -1 | awk '{print $2}'; }

pass=0; fail=0; skipped=0
ok()  { pass=$((pass+1)); printf "  PASS %s\n" "$1"; }
bad() { fail=$((fail+1)); printf "  FAIL %s\n" "$1"; [ -n "${2:-}" ] && printf "%s\n" "$2"
        [ -n "${FAILFAST:-}" ] && { echo "REGRESS pass=$pass fail=$fail (FAILFAST: stopped at the first failure)"; exit 1; }
        return 0; }

# Checks common to both modes; prints a reason and returns 1 on failure.
sane() { # sane <name>
  local n=$1
  grep -q "ERROR" "$OUT/$n.sim.log" && { grep -m1 "ERROR" "$OUT/$n.sim.log"; return 1; }
  grep -q "DUT-ABORT" "$OUT/$n.dut" && { grep -m1 "DUT-ABORT" "$OUT/$n.dut"; return 1; }
  [ -s "$OUT/$n.dut" ] || { echo "    empty dump"; return 1; }
  grep -q "mem 0x$TOHOST 0x0*1\$" "$OUT/$n.dut" || { echo "    never reached tohost"; return 1; }
  # An X anywhere in the dump means a value came from a register (or memory)
  # nothing wrote; with +RF_X that is a read of an unwritten register. The
  # trace compare would see it, but an expect run only reads its listed
  # registers.
  local xline; xline=$(grep -m1 -E '0x[0-9a-f]*[xzXZ]' "$OUT/$n.dut") &&
    { echo "    X in the dump: $xline"; return 1; }
  return 0
}

run_spike() { # run_spike <name> <plusargs...>
  local n=$1; shift; local label="$n $*"
  asm "$n" || { bad "$label" "    assembly failed"; return; }
  [ -f "$HERE/$n.ref" ] || ref "$n"
  sim "$n" "$@"
  local why; why=$(sane "$n") || { bad "$label" "$why"; return; }
  local nd; nd=$(wc -l < "$OUT/$n.dut")
  local first; first=$(diff <(norm "$OUT/$n.dut") <(norm "$HERE/$n.ref" | head -n "$nd") | head -1)
  if [ -z "$first" ] && [ "$(norm "$HERE/$n.ref" | head -n "$nd" | wc -l)" = "$nd" ]; then
    ok "$label"
  else
    local ln; ln=$(echo "$first" | grep -oE '^[0-9]+' | head -1); ln=${ln:-$nd}
    bad "$label" "    line $ln
      dut: $(norm "$OUT/$n.dut" | sed -n "${ln}p")
      ref: $(norm "$HERE/$n.ref" | sed -n "${ln}p")"
  fi
}

run_expect() { # run_expect <name> <reg>=<hex>... [-- <plusargs...>]
  local n=$1; shift; local checks=() extra=() seen=0
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1
    elif [ $seen = 0 ]; then checks+=("$a"); else extra+=("$a"); fi
  done
  local label="$n ${extra[*]} (expect)"
  asm "$n" || { bad "$label" "    assembly failed"; return; }
  sim "$n" "${extra[@]}"
  local why; why=$(sane "$n") || { bad "$label" "$why"; return; }
  local c r alts a hit got msg=""
  for c in "${checks[@]}"; do
    r=${c%%=*}; alts=${c#*=}; got=$(rd "$OUT/$n.dut" "$r"); hit=0
    for a in ${alts//|/ }; do
      [[ $got =~ ^0x[0-9a-f]+$ ]] && [ $((got)) = $((a)) ] && hit=1
    done
    [ $hit = 1 ] || msg="$msg    $r = ${got:-<never written>}, want $alts
"
  done
  [ -z "$msg" ] && ok "$label" || bad "$label" "${msg%$'\n'}"
}

suite() {
  local missing
  for f in "$HERE"/*.S; do
    local t; t=$(basename "$f" .S)
    grep -qE "^$t( |\$)" "$HERE/MANIFEST" || missing="${missing:-} $t"
  done
  [ -n "${missing:-}" ] && bad "MANIFEST" "    not listed:$missing"
  local ran=" " skip=" "
  [ $SOC = 1 ] && skip=" $(sed -n 's/^#soc-skip \([^-]*\).*/\1/p' "$HERE/MANIFEST" | tr '\n' ' ') "
  while read -r name mode rest; do
    case "$name" in ''|\#*) continue ;; esac
    if [ "$mode" = soc ]; then
      [ $SOC = 1 ] || continue
      read -r mode rest <<< "$rest"
    elif [ $SOC = 1 ]; then
      case "$ran$skip" in *" $name "*) continue ;; esac
      ran="$ran$name "
    elif [ "$mode" = flash ]; then
      continue
    fi
    if [ $SOC = 1 ] && [[ " ${RUN_PLUSARGS:-} " == *" +SOC_DDR"* ]] && [[ " $rest " == *" +QSPI_DELAY="* ]]; then
      skipped=$((skipped+1)); printf "  SKIP %s (DDR corner: fixed-delay line)\n" "$name"
      continue
    fi
    # shellcheck disable=SC2086
    case "$mode" in
      spike|flash) run_spike "$name" $rest ;;
      expect) run_expect "$name" $rest ;;
      *)      bad "$name" "    unknown mode '$mode'" ;;
    esac
  done < "$HERE/MANIFEST"
  if [ $skipped = 0 ]; then echo "REGRESS pass=$pass fail=$fail"
  else echo "REGRESS pass=$pass fail=$fail skip=$skipped"; fi
  [ $fail = 0 ]
}

case "${1:-run}" in
  build) build ;;
  refs)  shift; names=("$@")
         [ ${#names[@]} = 0 ] && for f in "$HERE"/*.S; do names+=("$(basename "$f" .S)"); done
         for n in "${names[@]}"; do asm "$n" && ref "$n" && echo "ref $n"; done ;;
  one)   shift; t=$1; shift; asm "$t" && sim "$t" "$@"; tail -3 "$OUT/$t.sim.log" ;;
  *)     build && suite ;;
esac
