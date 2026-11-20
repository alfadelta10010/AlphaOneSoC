#!/bin/bash
# mkflash.sh <zephyr build dir> : builds <dir>/flash.hex from zephyr.bin with the ladder's loader
set -e
B=$1; SW=${ZEPHYR_WORK:-$HOME/zephyr-work}/sw
LOADER=${ZEPHYR_WORK:-$HOME/zephyr-work}/build/sw/loader/loader.bin
[ -f $LOADER ] || make -C $SW hello >/dev/null
ENTRY=0x$(${CROSS_COMPILE}nm $B/zephyr/zephyr.elf | awk '$3=="__start"{print $1}')
python3 $SW/tools/mkflash.py --loader $LOADER --image $B/zephyr/zephyr.bin --load 0x80000000 --entry $ENTRY --out $B/flash.hex
