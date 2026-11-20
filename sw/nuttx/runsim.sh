#!/bin/bash
# runsim.sh <tag> <max_cycles> [uart_in.hex]   image the built nuttx, run on the bench, log to build/nuttx/<tag>.log
set -e
W=${NUTTX_WORK:-${NUTTX_WORK:-$HOME/nuttx-work}}; B=$W/build/nuttx; mkdir -p $B
export PATH=$HOME/tools/rv64-gcc-elf/bin:$PATH
cd $W/nx/nuttx
riscv64-unknown-elf-objcopy -O binary nuttx $B/nuttx.bin
ENTRY=$(riscv64-unknown-elf-nm nuttx | awk '$3=="__start"{print $1}')
python3 $W/sw/tools/mkflash.py --loader $W/build/sw/loader/loader.bin --image $B/nuttx.bin --load 0x80000000 --entry 0x$ENTRY --out $B/flash.hex
(nohup ~/swb/guard.sh >/dev/null 2>&1 &)
IN=; [ -n "$3" ] && IN="+UART_IN=$3"
stdbuf -o0 nice -n 19 $W/build/sw/bench/sim +FLASH_FILE=$B/flash.hex +UART_DIV=34 +MAX_CYCLES=$2 $IN > $B/$1.log 2>&1
