#!/bin/bash
# Boot the Linux payload on Spike; input is fed after the boot, poweroff via the HTIF-mapped syscon.
cd "$(dirname "$0")"
( sleep ${BOOT_WAIT:-240}; printf "echo shell-ok\n"; sleep 10; printf "poweroff\n"; sleep 300 ) |   nice -n 19 spike --isa=rv32imac_zicsr_zifencei --priv=mu --pmpregions=4 --dtb=spike.dtb --dtb-discovery ${SPIKE_ARGS} linux-spike.elf
