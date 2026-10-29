#!/bin/bash
# Spike signatures for the arch-test ELFs build_isa.sh made: OUT/ref/<name>.sig
#   spike_sig.sh OUT=<dir> [SPIKE=spike]
# One ELF serves Spike and the chip: the store to tohost ends the Spike run
# before any MMIO access. Spike 5a760667 has no boot ROM, so --pc is given.
set -u
for a in "$@"; do case $a in *=*) export "${a%%=*}=${a#*=}";; esac; done
: "${OUT:?OUT=<dir>}"; SPIKE=${SPIKE:-spike}
mkdir -p "$OUT/ref"
while IFS='|' read -r name hex args; do
  [ -n "$name" ] || continue
  [ -s "$OUT/ref/$name.sig" ] && continue
  timeout -k 5 300 $SPIKE --isa=rv32imac_zicsr_zifencei_zicntr --priv=mu --pmpregions=4 --pmpgranularity=4 \
    -m0x20000000:0x1000000,0x80000000:0x1000000 --pc=0x20000000 \
    +signature="$OUT/ref/$name.sig" +signature-granularity=4 "$OUT/elf/$name.elf" > "$OUT/ref/$name.log" 2>&1
  echo "$name $(wc -l < "$OUT/ref/$name.sig" 2>/dev/null || echo 0) words"
done < "$OUT/list.C"
