#!/bin/bash
# Re-scores a finished night's logs with night.sh's stage rule (read only). Usage:
#   rescore_night.sh D=<night dir> BUILD=<build_isa OUT used by that night> [ELF=<dir with the night's .elf, default $BUILD/elf>]
# The one exemption, for the 2026-11-26 cache-off night of the 4x4 pnl only: the 16 part-C programs of MSCRATCH_X below FAILed
# because mscratch has no reset, the riscof trap prologue spills it (csrrw s0,mscratch,t1; sw s0,..) and the PSRAM write puts the X on SD0..SD3.
# A FAIL is excused only if ALL hold: its name is one of the 16; the ELF has no `csrw mscratch,zero` (built without BOOT_CLEAR_MSCRATCH);
# every FAIL line of the log is "uio_out[n] is driven with an X"; those lines span at most 12 cycles (the spill store); the log
# says "NOTE signature: N words match" (signature == Spike). Any other X, or any other failure, still fails the stage.
for a in "$@"; do case $a in *=*) export "${a%%=*}=${a#*=}";; esac; done
: "${D:?}"; : "${BUILD:?}"; ELF=${ELF:-$BUILD/elf}
S=$(cd "$(dirname "$0")" && pwd)
MSCRATCH_X=" cebreak-01 ebreak ecall misalign2-jalr-01 misalign-beq-01 misalign-bge-01 misalign-bgeu-01 misalign-blt-01 misalign-bltu-01 misalign-bne-01 misalign-jal-01 misalign-lh-01 misalign-lhu-01 misalign-lw-01 misalign-sh-01 misalign-sw-01 "
st() { echo "   $*"; }
eval "$(sed -n '/^notpass()/,/^}/p' $S/night.sh)"
spill_x() { # name dir: 0 if the FAIL of this program is the mscratch spill
  local n=$1 d=$2 log=$2/$1.log
  case "$MSCRATCH_X" in *" $n "*) ;; *) return 1;; esac
  ! "${TOOLCHAIN:-riscv64-unknown-elf-}objdump" -d "$ELF/$n.elf" 2>/dev/null | grep -q 'csrw[[:space:]]*mscratch,zero' || return 1
  grep -q '^NOTE signature: [0-9]* words match' "$log" || return 1
  [ -z "$(grep '^FAIL' "$log" | grep -v -E '^FAIL uio_out\[[0-9]\] is driven with an X \(cycle [0-9]+\)$|^FAIL tb_tt_um: [0-9]+ errors$')" ] || return 1
  grep -oE '^FAIL uio_out\[[0-9]\] is driven with an X \(cycle [0-9]+\)' "$log" | grep -oE '[0-9]+\)$' | tr -d ')' | sort -n | awk 'NR==1{a=$1} {b=$1} END{exit !(b-a<=12)}'
}
rc=0
for x in "rtl-A rtl A" "rtl-B rtl B" "rtl-C rtl C" "rtl-D rtl-D D" "gl-A gl A" "gl-B gl B" "gl-C gl C" "gl-D gl-D D"; do
  set -- $x; d=$D/$2; l=$BUILD/list.$3
  [ -d "$d" ] || continue
  out=$(notpass "$d" "$l"); r=$?
  excused=0; left=""
  while IFS= read -r line; do
    n=$(echo "$line" | sed -n 's/^ *\([^:]*\): FAIL .*/\1/p')
    if [ -n "$n" ] && spill_x "$n" "$d"; then excused=$((excused + 1)); else left="$left$line"$'\n'; fi
  done <<< "$out"
  left=$(echo -n "$left" | grep -v '^$')
  if [ -n "$left" ]; then echo "$1: rc 1 ($excused excused as the mscratch spill)"; echo "$left"; rc=1; else echo "$1: rc 0 ($excused excused as the mscratch spill)"; fi
done
exit $rc
