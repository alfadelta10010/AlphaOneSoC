#!/bin/bash
# Builds the programs the gate-level (and RTL) pins bench runs: the SoC programs
# of part A (tests/soc/tt_pins.S, tt_reboot.S), riscv-tests (part B) and arch
# tests (part C), relinked for the SoC.
#
#   build_isa.sh SUITES=<river_core conf dir, with test_list.yaml> OUT=<dir>
#                [TOOLCHAIN=riscv64-unknown-elf-] [PARTS="A B C D"] [BOOT_CLEAR_MSCRATCH=1]
#
# Writes under OUT: elf/<name>.elf, hex/<name>.hex (flash image at 0), and the
# lists list.A, list.B, list.C, list.D of `name|hex|plusargs` lines
# (run_gl.sh LIST=). Part D is the mailbox programs of tests/soc built with
# -DMB_UART (they report over the UART as well) and the chip's reset divisor 34,
# run at the chip's 19 ns clock (52.63 MHz): run_gl.sh TCLK=19.0. The table is below.
# Nothing from the suites is copied; they are read from SUITES' yaml paths.
# Tests that write code (rv32ui fence_i, arch Fencei) are linked to run from PSRAM
# (tests/isa/link_soc_ram.ld). The 3 arch tests with the smallest signature also
# get a `.uart` build that sends the signature over the UART as well.
set -u
for a in "$@"; do case $a in *=*) export "${a%%=*}=${a#*=}";; esac; done
: "${OUT:?OUT=<dir>}"; SUITES=${SUITES:-}
TOOLCHAIN=${TOOLCHAIN:-riscv64-unknown-elf-}; PARTS=${PARTS:-A B C}   # D is built on request only
R=$(cd "$(dirname "$0")/../.." && pwd); ISA=$R/tests/isa; HLP=$R/plugins/helpers
mkdir -p "$OUT/elf" "$OUT/hex" "$OUT/inc"; OUT=$(cd "$OUT" && pwd)
CC=${TOOLCHAIN}gcc; OC=${TOOLCHAIN}objcopy; NM=${TOOLCHAIN}nm
printf '#include "%s/riscv_test_soc.h"\n' "$ISA" > "$OUT/inc/riscv_test.h"
FLAGS="-march=rv32imac_zicsr_zifencei -mabi=ilp32 -static -std=gnu99 -O2 -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles"
[ "${BOOT_CLEAR_MSCRATCH:-0}" = 1 ] && FLAGS="$FLAGS -DBOOT_CLEAR_MSCRATCH"   # parts B and C: boot_flash.S zeroes mscratch (no reset on the 4x4 chip)
hexof() { # elf hex ram?
  local secs="-j .text.init -j .text -j .rodata -j .data"
  [ "$3" = 1 ] && secs="-j .text.boot -j .text_ram -j .rodata -j .data"
  $OC -O verilog $secs --change-addresses=-0x20000000 "$1" "$2"
}
: > "$OUT/list.A"; : > "$OUT/list.B"; : > "$OUT/list.C"; : > "$OUT/list.D"
case " $PARTS " in *" D "*)
  # The mailbox programs of tests/soc through the pins (tb_tt_um.v +TEST=soc +PROG=<name>), the table of WO-26 as
  # refreshed for the 4x4 chip (WO-GLN). One line per run: label|program|MB_DIV|cflags|plusargs.
  # All at the chip clock, 19 ns (run_gl.sh TCLK=19.0). The old 10 / 20 ns split is gone: the 20 ns clock was there for
  # the three SSD1331 programs (oled_spi, irq_stall, periph_access), and they PASS on the RTL at 19 ns (WO-GLN).
  # QSPI delays of the late runs are scaled by 19/10 from the 10 ns bench's (+QSPI_DELAY=25 +QSPI_HOLD=12 -> 47, 23): the
  # same position in the SCK period.
  # ddr_flash@n / ddr_sweep@FLAG as the Makefile's SYSCON_SOC_RUNS (ddr_flash points at 19 ns: capture at 9.5 (n + 1) ns).
  # gpio_irq is built with -DIP_CLEAR_FIRST: it W1Cs IN_IP before its first check (the pins bench's two-clock power-up reset
  # leaves phantom IN_IP bits, a documented property of the unreset input synchroniser).
  # Not here, with the reason: adv_* (their cues are raw syscon-mailbox writes read by tb_adv.v's own checks; nothing
  # of them reaches the pins as a UART frame), syscon_cfg (not a program of the pins bench: needs the SoC's strap
  # forcing in tb_syscon_soc), sd_init / spi_mixed / sd_reboot (the SD card bench: tb_soc_periph with sd_spi_model; at the
  # pins only sd_init has a row and needs -DTT_SD, 10-100 M cycles: too long for a gate-level run), uart_hello's variants.
  late='+RD_LATE +QSPI_DELAY=47 +QSPI_HOLD=23'
  while IFS='|' read -r label t div cf pa; do
    [ -n "$label" ] || continue
    df="-DMB_UART -DUART_DIV_RESET=34"; [ "$div" != - ] && df="$df -DMB_DIV=$div"
    $CC $FLAGS $df $cf -T $R/tests/soc/link.ld -I$R/tests/soc $R/tests/soc/$t.S -o "$OUT/elf/$label.elf" || exit 1
    $OC -O verilog -j .text.init -j .text -j .rodata --change-addresses=-0x20000000 "$OUT/elf/$label.elf" "$OUT/hex/$label.hex"
    pa=${pa//@LATE@/$late}
    echo "$label|$label|+TEST=soc +PROG=$t${pa:+ $pa}" >> "$OUT/list.D"
  done <<'EOT'
uart_hello|uart_hello|-||
uart_echo|uart_echo|4||
uart_linux|uart_linux|-||
oled_spi|oled_spi|1||
keypad|keypad|1||
irq_stall|irq_stall|4||
periph_access|periph_access|-||
clint_decode|clint_decode|1||
syscon_regs|syscon_regs|1||
syscon_reboot|syscon_reboot|-||
syscon_strap.0|syscon_strap|1||
syscon_strap.1|syscon_strap|1||@LATE@
syscon_fail|syscon_fail|1||
syscon_wdt|syscon_wdt|1||
syscon_wdt_split|syscon_wdt_split|1||
syscon_poweroff|syscon_poweroff|1||
syscon_pinreset|syscon_pinreset|1||
sd_cs|sd_cs|1||
pinmux|pinmux|1||
reboot_dirty|reboot_dirty|1||
audio|audio|1||
pwm_linux|pwm_linux|1||
pwm_timer|pwm_timer|1||
cache_ctl|cache_ctl|1||
gpio_irq|gpio_irq|1|-DIP_CLEAR_FIRST|
plic_uart|plic_uart|4||
gamepad|gamepad|1||
ddr_flash.0|ddr_flash|1|-DDDR_PT=0|
ddr_flash.1|ddr_flash|1|-DDDR_PT=1|+QSPI_DELAY=12 +QSPI_HOLD=6
ddr_flash.2|ddr_flash|1|-DDDR_PT=2|+QSPI_DELAY=22 +QSPI_HOLD=12
ddr_sweep.k2a|ddr_sweep|1||+QSPI_DELAY=18 +QSPI_HOLD=12 +WANT_K=2
ddr_sweep.k2b|ddr_sweep|1||+QSPI_DELAY=24 +QSPI_HOLD=18 +WANT_K=2
ddr_sweep.k3|ddr_sweep|1||+QSPI_DELAY=30 +QSPI_HOLD=24 +WANT_K=3
ddr_sweep.k4|ddr_sweep|1||+RD_LATE +QSPI_DELAY=42 +QSPI_HOLD=36 +WANT_K=4
ddr_sweep.off_launch1|ddr_sweep|1||+DTR_LAUNCH=1 +QSPI_DELAY=18 +QSPI_HOLD=12 +WANT_K=-1
ddr_sweep.off_launch2|ddr_sweep|1||+DTR_LAUNCH=1 +QSPI_DELAY=24 +QSPI_HOLD=18 +WANT_K=-1
ddr_sweep.off_window|ddr_sweep|1||+QSPI_DELAY=22 +QSPI_HOLD=6 +WANT_K=-1
EOT
  ;;
esac
case " $PARTS " in *" A "*)
  for t in tt_pins tt_reboot; do
    $CC $FLAGS -T $R/tests/soc/link.ld -I$R/tests/soc $R/tests/soc/$t.S -o "$OUT/elf/$t.elf" || exit 1
    $OC -O verilog -j .text.init -j .text -j .rodata --change-addresses=-0x20000000 "$OUT/elf/$t.elf" "$OUT/hex/$t.hex"
  done
  # Part A runs at the chip's 19 ns clock (night.sh TCLK=19.0); the 10 ns bench's QSPI delays are scaled by 1.9
  # (QSPI_LATE +RD_LATE +QSPI_DELAY=25 +QSPI_HOLD=12 -> 47, 23: the same place in the SCK period).
  # tt_pins.1 runs just under one SCK period: 19 at 10 ns left 1 ns of the 20 ns period and the 2-cell pad-to-flop
  # path is 2 ns at UNIT_DELAY=#1 (WO-40: PASS at 18 and 17 on fin-3x4), so 18 there; 36 of the 38 ns here, the same 2 ns.
  { echo 'tt_pins.0|tt_pins|'; echo 'tt_pins.1|tt_pins|+QSPI_DELAY=36'
    echo 'tt_pins.2|tt_pins|+RD_LATE +QSPI_DELAY=47 +QSPI_HOLD=23'
    echo 'tt_reboot.0|tt_reboot|+TEST=reboot'
    echo 'tt_reboot.1|tt_reboot|+TEST=reboot +RD_LATE +QSPI_DELAY=47 +QSPI_HOLD=23'; } > "$OUT/list.A";;
esac
case " $PARTS " in *" B "*|*" C "*) : "${SUITES:?SUITES=<dir with test_list.yaml> for parts B and C}";; esac
: > "$OUT/tests.tsv"
[ -n "$SUITES" ] && python3 - "$SUITES/test_list.yaml" > "$OUT/tests.tsv" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for k, v in sorted(d.items()):
    print("\t".join([k, v["generator"], v["asm_file"], ":".join(v["include"]), " ".join("-D"+m for m in v["compile_macros"])]))
PY
SIZES=$OUT/sigsizes.txt; : > $SIZES
while IFS=$'\t' read -r name gen asm inc macros; do
  case "$gen" in riscv_tests) part=B;; riscof) part=C;; *) continue;; esac
  case " $PARTS " in *" $part "*) ;; *) continue;; esac
  ram=0; case "$name" in rv32ui-fence_i-p|rv32uc-rvc-p|Fencei) ram=1;; esac
  if [ $ram = 1 ]; then ld=$ISA/link_soc_ram.ld; boot=$ISA/boot_flash_ram.S; else ld=$HLP/link_soc.ld; boot=$HLP/boot_flash.S; fi
  incs="-I$OUT/inc -I$ISA"
  IFS=: read -ra dirs <<< "$inc"
  for d in "${dirs[@]}"; do
    case "$d" in */fyracore/env) ;; *) incs="$incs -I$d -I$(dirname "$d")";; esac
  done
  n=$name; ldx=""; [ $part = C ] && ldx="-Wl,--defsym=_start=rvtest_entry_point"   # the arch tests enter there
  if ! $CC $FLAGS $incs $macros $ldx -T $ld $boot $asm -o "$OUT/elf/$n.elf" 2> "$OUT/elf/$n.cc.log"; then
    echo "BUILD FAIL $n (see $OUT/elf/$n.cc.log)"; continue; fi
  hexof "$OUT/elf/$n.elf" "$OUT/hex/$n.hex" $ram
  if [ $part = B ]; then echo "$n|$n|+TEST=isa" >> "$OUT/list.B"
  else
    b=$($NM "$OUT/elf/$n.elf" | awk '$3=="begin_signature"{print $1}'); e=$($NM "$OUT/elf/$n.elf" | awk '$3=="end_signature"{print $1}')
    echo "$n|$n|+TEST=sig +SIG_BEGIN=$b +SIG_END=$e +SIG_REF=$OUT/ref/$n.sig +SIG_OUT=@RUN@/$n.sig" >> "$OUT/list.C"
    echo "$(( 0x$e - 0x$b )) $n $ram $asm $inc | $macros" >> $SIZES
  fi
done < "$OUT/tests.tsv"
# the UART cross-check: the 3 smallest signatures, rebuilt to send them as well
sort -n $SIZES | head -3 | while read -r sz n ram rest; do
  IFS='|' read -r left macros <<< "$rest"; read -r asm inc <<< "$left"
  ld=$HLP/link_soc.ld; boot=$HLP/boot_flash.S
  incs="-I$OUT/inc -I$ISA"; IFS=: read -ra dirs <<< "$inc"
  for d in "${dirs[@]}"; do case "$d" in */fyracore/env) ;; *) incs="$incs -I$d -I$(dirname "$d")";; esac; done
  $CC $FLAGS $incs $macros -Wl,--defsym=_start=rvtest_entry_point -DSOC_SIG_UART -T $ld $boot $asm -o "$OUT/elf/$n.uart.elf" && hexof "$OUT/elf/$n.uart.elf" "$OUT/hex/$n.uart.hex" 0
  b=$($NM "$OUT/elf/$n.uart.elf" | awk '$3=="begin_signature"{print $1}'); e=$($NM "$OUT/elf/$n.uart.elf" | awk '$3=="end_signature"{print $1}')
  echo "$n.uart|$n.uart|+TEST=sig +SIG_UART +SIG_BEGIN=$b +SIG_END=$e +SIG_REF=$OUT/ref/$n.uart.sig +SIG_OUT=@RUN@/$n.uart.sig" >> "$OUT/list.C"
done
echo "built: A=$(wc -l < $OUT/list.A) B=$(wc -l < $OUT/list.B) C=$(wc -l < $OUT/list.C) (C counts the .uart builds) D=$(wc -l < $OUT/list.D)"
