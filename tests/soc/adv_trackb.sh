#!/bin/bash
# Track B adversarial driver (review 2026-11-22): builds tb_adv from <tree>/src, runs each program in the
# three cache modes (-DCMODE=0/1/2), compares the signatures across modes and, for adv_hold, with
# tests/soc/adv_hold_ref.py. One "VERDICT <prog> PASS|FAIL <why>" line per program.
# usage: tests/soc/adv_trackb.sh <tree> <outdir> [prog[:gcc-flags] ...]   (default: adv_c256 adv_hold)
# Needs riscv64-unknown-elf-gcc, iverilog/vvp on PATH. Run heavy jobs through the sandbox slot gate.
# ADV_PLUS = extra tb_adv plusargs for every run (e.g. "+MAX_CYCLES=4000000" for mutants: the clean runs
# finish in < 1.1 M cycles, a broken copy that hangs then FAILs in minutes instead of at the 40 M default).
set -u
T=$(cd "$1" && pwd); O=$2; shift 2
mkdir -p "$O"; O=$(cd "$O" && pwd)
progs=("$@"); [ ${#progs[@]} -eq 0 ] && progs=(adv_c256 adv_hold)
S=$T/src
iverilog -g2012 -o "$O/sim" -s tb_adv $S/alu.v $S/branchCtrl.v $S/clint.v $S/compressed_decoder.v $S/controller.v \
  $S/csr.v $S/decoder.v $S/fyracore.v $S/muldiv.v $S/pmp.v $S/regFile.v $S/rf_top.v $S/regs.v $S/signExt.v \
  $S/qspi_ctrl.v $S/mem_ctrl.v $S/cache.v $S/soc_bus.v $S/plic.v $S/uart.v $S/gamepad.v $S/pwm.v \
  $S/pinmux.v $S/gpio.v $S/spi.v $S/syscon.v $S/alphaone_soc.v $T/tb/qspi_pmod_model.v $T/tb/rp2350_uart_model.v \
  $T/tb/tb_adv.v > "$O/build.log" 2>&1 || { echo "VERDICT build FAIL (see $O/build.log)"; exit 1; }
rc=0
for pf in "${progs[@]}"; do
  p=${pf%%:*}; fl=""; [ "$pf" != "$p" ] && fl=${pf#*:}
  sigs=(); bad=""
  for m in 0 1 2; do
    n=${p}_m$m
    riscv64-unknown-elf-gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles -DCMODE=$m $fl \
      -T $T/tests/soc/link.ld -I$T/tests/soc $T/tests/soc/$p.S -o $O/$n.elf || { bad="$bad build-m$m"; continue; }
    riscv64-unknown-elf-objcopy -O verilog -j .text.init -j .text -j .rodata --change-addresses=-0x20000000 $O/$n.elf $O/$n.hex
    vvp -n $O/sim +TEST=$n +FLASH_FILE=$O/$n.hex ${ADV_PLUS:-} > $O/$n.log 2>&1
    grep -E '^(PASS|FAIL|ERROR|SIG|COV)|fatal|FATAL|rror' $O/$n.log | head -8 | sed "s/^/  [$n] /"
    grep -q "^PASS tb_adv" $O/$n.log || bad="$bad run-m$m"
    sigs+=("$(awk '/^SIG /{print $4}' $O/$n.log | tail -1)")
  done
  [ "${sigs[0]:-x}" = "${sigs[1]:-y}" ] && [ "${sigs[1]:-y}" = "${sigs[2]:-z}" ] || bad="$bad sig-mismatch(${sigs[*]})"
  if [ "$p" = adv_hold ]; then
    sd=$(echo "$fl" | sed -n 's/.*-DSEED=\([^ ]*\).*/\1/p'); nk=$(echo "$fl" | sed -n 's/.*-DNK=\([^ ]*\).*/\1/p')
    ref=$(python3 $T/tests/soc/adv_hold_ref.py ${sd:-0x2468ACE1} ${nk:-24})
    [ "${sigs[0]:-x}" = "$ref" ] || bad="$bad ref-mismatch(ref $ref)"
  fi
  if [ -z "$bad" ]; then echo "VERDICT $p PASS sig ${sigs[0]}"; else echo "VERDICT $p FAIL$bad"; rc=1; fi
done
exit $rc
