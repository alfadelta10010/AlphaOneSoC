#!/bin/bash
# Builds the programs the gate-level (and RTL) pins bench runs: the SoC programs
# of part A (tests/soc/tt_pins.S, tt_reboot.S), riscv-tests (part B) and arch
# tests (part C), relinked for the SoC.
#
#   build_isa.sh SUITES=<river_core conf dir, with test_list.yaml> OUT=<dir>
#                [TOOLCHAIN=riscv64-unknown-elf-] [PARTS="A B C D"]
#
# Writes under OUT: elf/<name>.elf, hex/<name>.hex (flash image at 0), and the
# lists list.A, list.B, list.C, list.D10, list.D20 of `name|hex|plusargs` lines
# (run_gl.sh LIST=). Part D is the 16 mailbox programs of tests/soc built with
# -DMB_UART (they report over the UART as well) and the chip's divisor 27; the
# three that drive the SSD1331 (D20) run with a 20 ns clock, the rest (D10)
# with 10 ns: run_gl.sh TCLK=.
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
hexof() { # elf hex ram?
  local secs="-j .text.init -j .text -j .rodata -j .data"
  [ "$3" = 1 ] && secs="-j .text.boot -j .text_ram -j .rodata -j .data"
  $OC -O verilog $secs --change-addresses=-0x20000000 "$1" "$2"
}
: > "$OUT/list.A"; : > "$OUT/list.B"; : > "$OUT/list.C"; : > "$OUT/list.D10"; : > "$OUT/list.D20"
case " $PARTS " in *" D "*)
  # program MB_DIV image (T10: 10 ns clock, T20: 20 ns): the table of WO-26
  late='+RD_LATE +QSPI_DELAY=25 +QSPI_HOLD=12'
  while read -r t div img; do
    df="-DMB_UART -DUART_DIV_RESET=27"; [ "$div" != - ] && df="$df -DMB_DIV=$div"
    $CC $FLAGS $df -T $R/tests/soc/link.ld -I$R/tests/soc $R/tests/soc/$t.S -o "$OUT/elf/$t.elf" || exit 1
    $OC -O verilog -j .text.init -j .text -j .rodata --change-addresses=-0x20000000 "$OUT/elf/$t.elf" "$OUT/hex/$t.hex"
    if [ "$t" = syscon_strap ]; then
      echo "$t.0|$t|+TEST=soc +PROG=$t" >> "$OUT/list.D$img"; echo "$t.1|$t|+TEST=soc +PROG=$t $late" >> "$OUT/list.D$img"
    else echo "$t|$t|+TEST=soc +PROG=$t" >> "$OUT/list.D$img"; fi
  done <<'EOT'
uart_hello - 10
uart_echo 4 10
uart_linux - 10
oled_spi 1 20
keypad 1 10
irq_stall 4 20
periph_access - 20
clint_decode 1 10
syscon_regs 1 10
syscon_reboot - 10
syscon_strap 1 10
syscon_fail 1 10
syscon_wdt 1 10
syscon_wdt_split 1 10
syscon_poweroff 1 10
syscon_pinreset 1 10
EOT
  ;;
esac
case " $PARTS " in *" A "*)
  for t in tt_pins tt_reboot; do
    $CC $FLAGS -T $R/tests/soc/link.ld -I$R/tests/soc $R/tests/soc/$t.S -o "$OUT/elf/$t.elf" || exit 1
    $OC -O verilog -j .text.init -j .text -j .rodata --change-addresses=-0x20000000 "$OUT/elf/$t.elf" "$OUT/hex/$t.hex"
  done
  # test-wrapper's runs: QSPI_LATE is +RD_LATE +QSPI_DELAY=25 +QSPI_HOLD=12.
  # tt_pins.1 runs at QSPI_DELAY=18 here: 19 leaves only 1 ns of the 20 ns SCK period at
  # the 10 ns bench clock and the 2-cell pad-to-flop path is 2 ns at UNIT_DELAY=#1 (WO-40:
  # PASS at 18 and 17 on fin-3x4). The 19 ns case stays covered at RTL by test-qspi's
  # +QSPI_DELAY=19 run and test-wrapper's runs.
  { echo 'tt_pins.0|tt_pins|'; echo 'tt_pins.1|tt_pins|+QSPI_DELAY=18'
    echo 'tt_pins.2|tt_pins|+RD_LATE +QSPI_DELAY=25 +QSPI_HOLD=12'
    echo 'tt_reboot.0|tt_reboot|+TEST=reboot'
    echo 'tt_reboot.1|tt_reboot|+TEST=reboot +RD_LATE +QSPI_DELAY=25 +QSPI_HOLD=12'; } > "$OUT/list.A";;
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
echo "built: A=$(wc -l < $OUT/list.A) B=$(wc -l < $OUT/list.B) C=$(wc -l < $OUT/list.C) (C counts the .uart builds) D10=$(wc -l < $OUT/list.D10) D20=$(wc -l < $OUT/list.D20)"
