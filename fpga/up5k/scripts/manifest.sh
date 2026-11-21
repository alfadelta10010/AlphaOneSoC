#!/usr/bin/env bash
# Sandbox: verify every pin file the build uses against pin.sums (which gen_pin_sums.sh derives from
# git $PIN) and write build/MANIFEST. Fails if any file differs or is missing.
set -eu
cd "$(dirname "$0")/.."
PINDIR=${PINDIR:-../pin}
mkdir -p build
M=build/MANIFEST
{ echo "PIN $(cat PIN)"; echo "PINDIR $PINDIR"; } > $M
bad=0
while read -r sum f; do
    got=$(sha256sum "$PINDIR/$f" | cut -d' ' -f1)
    if [ "$got" = "$sum" ]; then echo "pin  $got  $f" >> $M
    else echo "MISMATCH $f: $got != $sum" | tee -a $M >&2; bad=1; fi
done < pin.sums
for f in rtl/fyracore_picorv32.v rtl/rf_top_fpga.v rtl/fpga_top.v third_party/picorv32/picorv32.v; do
    echo "own  $(sha256sum $f | cut -d' ' -f1)  $f" >> $M
done
[ "$bad" = 0 ] && echo "manifest ok: $(grep -c '^pin ' $M) pin files identical to $(cat PIN)"
exit $bad
