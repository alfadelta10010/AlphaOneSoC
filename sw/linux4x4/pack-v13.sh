#!/bin/bash
# usage: pack-v13.sh <dtb> <loader.bin> <outprefix>
set -euo pipefail
export PATH=$HOME/tools/rv64-gcc-elf/bin:$PATH
V=$HOME/v13; IMG=$V/lx/linux-6.8-rc1/arch/riscv/boot/Image; SM=$V/lx/linux-6.8-rc1/System.map
BASE=0x80000000
END=$(awk '$3=="_end"{print $1}' $SM)
STUB_OFF=$(( (0x$END - BASE + 0xfff) & ~0xfff )); DTB_OFF=$((STUB_OFF + 0x1000))
cc=riscv64-unknown-elf
$cc-gcc -march=rv32imac_zicsr_zifencei_zihintpause -mabi=ilp32 -nostdlib -Wl,-Ttext=$((BASE+STUB_OFF)) -Wl,-N -DDTB_ADDR=$((BASE+DTB_OFF)) -DKERNEL_ADDR=$BASE -o $V/out/stub.elf $V/os/sw/linux/recipe/stub.S
$cc-objcopy -O binary $V/out/stub.elf $V/out/stub.bin
python3 - $V/out/stub.bin $1 $IMG $3-blob.bin $STUB_OFF $DTB_OFF <<'PY'
import sys
stub,dtb,img=[open(a,"rb").read() for a in sys.argv[1:4]]
out=sys.argv[4]; so,do=int(sys.argv[5]),int(sys.argv[6])
assert len(img)<=so and len(stub)<=0x1000 and len(dtb)<=0x10000
b=bytearray(do+len(dtb)); b[:len(img)]=img; b[so:so+len(stub)]=stub; b[do:do+len(dtb)]=dtb
open(out,"wb").write(bytes(b))
PY
python3 $HOME/swb5/sw/tools/mkflash.py --loader $2 --image $3-blob.bin --load $BASE --entry $((BASE+STUB_OFF)) --out $3-flash.hex --bin $3-flash.bin
