#!/bin/bash
# run.sh — build the DUT, then run every directed test against Spike.
#
#   ./run.sh build          rebuild sim from ../../src and ../../tb
#   ./run.sh refs           regenerate the Spike reference for every test
#   ./run.sh                run the regression
#   ./run.sh one <name> [+PLUSARG...]
#
# Tests live beside this script. Artifacts go to ./out (gitignored).
# Toolchain: riscv64-unknown-elf-* and spike on PATH. On the sandbox those are
# under /home/mempool/tools/{rv64-gcc-elf,rv32-isa-sim}/bin.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
OUT="$HERE/out"
mkdir -p "$OUT"
SPIKE_ARGS="--hartids=0 --log-commits --priv=mu --pc=0x80000000 --isa=rv32imac_zicntr
            -m0x80000000:0x2000000 --pmpregions=4 --pmpgranularity=4"

build() {
  iverilog -g2012 -o "$OUT/sim" -s tb_rivercore \
    "$ROOT"/src/{alu,branchCtrl,clint,compressed_decoder,controller,csr,decoder,fyracore,muldiv,pmp,regFile,signExt}.v \
    "$ROOT"/tb/memory_model.v "$ROOT"/tb/tb_rivercore.v || return 1
  echo "build ok"
}

asm() { # asm <name> [extra gcc flags]
  local n=$1; shift
  riscv64-unknown-elf-gcc -static -std=gnu99 -O0 -mcmodel=medany -nostdlib \
    -nostartfiles -march=rv32imac_zicsr_zifencei -mabi=ilp32 "$@" \
    -T "$HERE/link.ld" "$HERE/$n.S" -o "$OUT/$n.elf" 2>/dev/null || return 1
  riscv64-unknown-elf-objcopy -O verilog --change-addresses=-0x80000000 \
    "$OUT/$n.elf" "$OUT/$n.hex"
}

ref() { # ref <name>
  local n=$1
  spike $SPIKE_ARGS --log "$OUT/$n.ref.raw" "$OUT/$n.elf" >/dev/null 2>&1
  sed '1,5d' "$OUT/$n.ref.raw" > "$HERE/$n.ref"
}

# Spike pads single-digit register names to width 3 ("x8  0x..."), so the
# separator must be ' +'. A single-space pattern silently matches x10-x31 only.
rd() { grep -oE "\b$2 +0x[0-9a-fx]+" "$1" 2>/dev/null | tail -1 | awk '{print $2}'; }

pass=0; fail=0
chk() { # chk <name> <regs...> [-- <plusargs...>]
  local t=$1; shift; local regs=() extra=() seen=0
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1
    elif [ $seen = 0 ]; then regs+=("$a"); else extra+=("$a"); fi
  done
  asm "$t" || { printf "  BUILDFAIL %s\n" "$t"; fail=$((fail+1)); return; }
  [ -f "$HERE/$t.ref" ] || ref "$t"
  vvp "$OUT/sim" +INIT_FILE="$OUT/$t.hex" +DUMP_FILE="$OUT/$t.dut" \
      +TOHOST_ADDR=80001000 +MAX_CYCLES=400000 "${extra[@]}" >/dev/null 2>&1
  local d="" r=""
  for g in "${regs[@]}"; do d="$d $(rd "$OUT/$t.dut" $g)"; r="$r $(rd "$HERE/$t.ref" $g)"; done
  if [ "$d" = "$r" ]; then pass=$((pass+1)); printf "  PASS %-24s %s\n" "$t ${extra[*]}" "$d"
  else fail=$((fail+1)); printf "  FAIL %-24s\n    dut:%s\n    ref:%s\n" "$t ${extra[*]}" "$d" "$r"; fi
}

chk_exact() { # chk_exact <name> "<expected>" <regs...>  -- for intentional Spike divergences
  local t=$1 want=$2; shift 2
  asm "$t" || { printf "  BUILDFAIL %s\n" "$t"; fail=$((fail+1)); return; }
  vvp "$OUT/sim" +INIT_FILE="$OUT/$t.hex" +DUMP_FILE="$OUT/$t.dut" \
      +TOHOST_ADDR=80001000 +MAX_CYCLES=400000 >/dev/null 2>&1
  local d=""
  for g in "$@"; do d="$d $(rd "$OUT/$t.dut" $g)"; done
  if [ "$d" = " $want" ]; then pass=$((pass+1)); printf "  PASS %-24s %s (policy, not Spike)\n" "$t" "$d"
  else fail=$((fail+1)); printf "  FAIL %-24s\n    got :%s\n    want: %s\n" "$t" "$d" "$want"; fi
}

suite() {
  chk memops              x10 x11 x13 x15
  chk memops              x10 x11 x13 x15 -- +DMEM_WAIT=3
  chk memops              x10 x11 x13 x15 -- +IMEM_WAIT=3 +IMEM_RANDOM=1 +DMEM_WAIT=3 +DMEM_RANDOM=1
  chk atomics             x10 x11 x12 x13 x14 x15 x16
  chk atomics             x10 x11 x12 x13 x14 x15 x16 -- +DMEM_WAIT=3
  chk causes              x12
  chk causes              x12 -- +IMEM_WAIT=2 +DMEM_WAIT=2
  chk mret_stall          x10 x11
  chk mret_ctrl           x10 x11
  chk mret_fault          x10 x12 x13
  chk illegal_ld_misalign x12 x13
  chk illegal_sd_misalign x12 x13
  chk lw_misalign         x12 x13
  chk illegal_ld_aligned  x12 x13
  chk c_misalign          x12 x13
  chk pmpcfg              x10 x11
  chk csrfwd              x10 x11 x12 x13
  chk marchid             x10 x11 x12
  chk lrsc_io             x14
  chk mprv2               x11 x12 x14
  # lrsc_policy is NOT Spike-compared. Cases 1 and 2 (same-hart store / AMO
  # overlapping the reservation) clear it here and do not on Spike. Both are
  # conformant -- conservative clearing is explicitly permitted -- so this is
  # checked against the intended DUT policy instead. See commit 027a17d.
  chk_exact lrsc_policy "0x00000001 0x00000001 0x00000001 0x00000001 0x00000000" x10 x11 x12 x13 x14
  echo "REGRESS pass=$pass fail=$fail"
}

case "${1:-run}" in
  build) build ;;
  refs)  for f in "$HERE"/*.S; do n=$(basename "$f" .S); asm "$n" && ref "$n" && echo "ref $n"; done ;;
  one)   shift; t=$1; shift; asm "$t" && vvp "$OUT/sim" +INIT_FILE="$OUT/$t.hex" \
           +DUMP_FILE="$OUT/$t.dut" +TOHOST_ADDR=80001000 +MAX_CYCLES=400000 "$@" ;;
  *)     build && suite ;;
esac
