#!/bin/bash
# Pack stub + DTB + Image into one payload, for the SoC bench (flash.hex) and for Spike (ELF).
# Blob layout, loaded at 0x8000_0000: Image @0 (the kernel's
# initramfs is inside the Image). Needs: $W/deliver/{Image,alpha.dtb,spike.dtb} (build.sh), the loader
# ($W/build/sw/loader/loader.bin: make -C $W/sw hello) and the toolchain in PATH.
#   pack.sh [workdir]     (default $LINUX_WORK or ~/linux-work, the same as build.sh and run-bench.sh)
set -euo pipefail
R=$(cd "$(dirname "$0")" && pwd)
W=${1:-${LINUX_WORK:-$HOME/linux-work}}; D=${DELIVER:-$W/deliver}; SW=${SW:-$W/sw}
BASE=0x80000000
# The NOMMU kernel is linked at 0x80000000 and cannot be moved: the Image goes at offset 0 and the
# stub and DTB sit behind _end (past the kernel's bss, which the kernel zeroes), page aligned.
END=$(awk '$3=="_end"{print $1}' $D/System.map)
STUB_OFF=$(( (0x$END - BASE + 0xfff) & ~0xfff )); DTB_OFF=$((STUB_OFF + 0x1000))
CC=riscv64-unknown-elf
for v in soc spike; do
  dtb=$D/alpha.dtb; [ $v = spike ] && dtb=$D/spike.dtb
  $CC-gcc -march=rv32imac_zicsr_zifencei_zihintpause -mabi=ilp32 -nostdlib -Wl,-Ttext=$((BASE+STUB_OFF)) -Wl,-N \
     -DDTB_ADDR=$((BASE+DTB_OFF)) -DKERNEL_ADDR=$BASE -o $D/stub.elf $R/stub.S 2>/dev/null
  $CC-objcopy -O binary $D/stub.elf $D/stub.bin
  python3 - $D/stub.bin $dtb $D/Image $D/blob-$v.bin $STUB_OFF $DTB_OFF <<'PY'
import sys
stub,dtb,img=[open(a,"rb").read() for a in sys.argv[1:4]]
out=sys.argv[4]; so,do=int(sys.argv[5]),int(sys.argv[6])
assert len(img)<=so and len(stub)<=0x1000 and len(dtb)<=0x10000
b=bytearray(do+len(dtb)); b[:len(img)]=img; b[so:so+len(stub)]=stub; b[do:do+len(dtb)]=dtb
open(out,"wb").write(bytes(b))
PY
done
# Spike ELF: blob at BASE, tohost/fromhost (the syscon of the Spike DTB) at 0x80ff0000
cat > $D/spike.ld <<LD
ENTRY(_start)
SECTIONS { . = $BASE; .blob : { *(.data) } . = 0x80ff0000; .tohost : { tohost = .; LONG(0); LONG(0); fromhost = .; LONG(0); LONG(0); } }
LD
$CC-ld -m elf32lriscv -r -b binary $D/blob-spike.bin -o $D/blob-spike.o
$CC-ld -m elf32lriscv -T $D/spike.ld -o $D/linux-spike.elf $D/blob-spike.o --defsym _start=$((BASE+STUB_OFF))
# SoC flash image
python3 $SW/tools/mkflash.py --loader $W/build/sw/loader/loader.bin --image $D/blob-soc.bin \
   --load $BASE --entry $((BASE+STUB_OFF)) --out $D/flash-linux.hex --bin $D/flash-linux.bin
