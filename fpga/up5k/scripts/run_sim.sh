#!/usr/bin/env bash
# Sandbox: golden-reference run. Builds the firmware for CFG (bit0 STREAM, bit1 DDR), compiles the bench once,
# runs it, writes build/sim/cfg$CFG/{golden.txt,sim.log}.   usage: scripts/run_sim.sh <cfg 0..3>
# env: F_MHZ (core clock, default as the Makefile), MAXCYC.
set -eu
cd "$(dirname "$0")/.."
CFG=${1:?cfg 0..3}
F_MHZ=${F_MHZ:-$(sed -n 's/^F_MHZ *?= *//p' Makefile | head -1)}
F_HZ=$((F_MHZ * 1000000))
PINDIR=${PINDIR:-../pin}
D=build/sim; mkdir -p $D/cfg$CFG
make -s -C fw F_CLK=$F_HZ CFG=$CFG OUT=$PWD/$D/cfg$CFG/fw > $D/cfg$CFG/fw.log 2>&1
scripts/manifest.sh > $D/manifest.log
SRC="$(for f in $(grep -hv '^#' srclist.txt); do printf '%s/%s ' $PINDIR $f; done)"
if [ ! -s $D/tb.vvp ] || [ -n "$(find rtl sim third_party srclist.txt -newer $D/tb.vvp -type f 2>/dev/null)" ]; then
    /usr/bin/iverilog -g2012 -s tb_up5k -DF_HZ=$F_HZ -o $D/tb.vvp $SRC \
        rtl/fyracore_picorv32.v rtl/rf_top_fpga.v rtl/fpga_top.v third_party/picorv32/picorv32.v \
        sim/sb_io_sim.v $PINDIR/tb/qspi_pmod_model.v $PINDIR/tb/rp2350_uart_model.v sim/tb_up5k.v \
        > $D/compile.log 2>&1
fi
/usr/bin/vvp -n $D/tb.vvp +FLASH_FILE=$PWD/$D/cfg$CFG/fw.hex +GOLDEN=$D/cfg$CFG/golden.txt +MAXCYC=${MAXCYC:-300000000} \
    > $D/cfg$CFG/sim.log 2>&1 || true
grep -E "SIM DONE|SIM TIMEOUT" $D/cfg$CFG/sim.log || echo "no SIM DONE line"
echo "assertions/errors: $(grep -cE 'ASSERT|ERROR|FAIL ' $D/cfg$CFG/sim.log)"
