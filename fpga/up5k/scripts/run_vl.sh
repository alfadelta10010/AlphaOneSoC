#!/usr/bin/env bash
# Sandbox: the same bench and RTL as run_sim.sh under Verilator 5 (--timing), ~50x faster than Icarus on this
# SoC. Same output layout: build/vl/cfg$CFG/{golden.txt,sim.log}.   usage: scripts/run_vl.sh <cfg 0..3>
# env: F_MHZ, MAXCYC. The binary is built once per F_MHZ (build/vl/obj$F_MHZ).
set -eu
cd "$(dirname "$0")/.."
CFG=${1:?cfg 0..3}
export PATH=/home/mempool/tools/oss-cad-suite/bin:$PATH
F_MHZ=${F_MHZ:-$(sed -n 's/^F_MHZ *?= *//p' Makefile | head -1)}
F_HZ=$((F_MHZ * 1000000))
PINDIR=${PINDIR:-../pin}
D=build/vl; mkdir -p $D/cfg$CFG
make -s -C fw F_CLK=$F_HZ CFG=$CFG OUT=$PWD/$D/cfg$CFG/fw > $D/cfg$CFG/fw.log 2>&1
scripts/manifest.sh > $D/manifest.log
SRC="$(for f in $(grep -hv '^#' srclist.txt); do printf '%s/%s ' $PINDIR $f; done)"
OBJ=$D/obj$F_MHZ
if [ ! -x $OBJ/tb_vl ] || [ -n "$(find rtl sim third_party srclist.txt -newer $OBJ/tb_vl -type f 2>/dev/null)" ]; then
    verilator --binary --timing -j 2 -Wno-fatal -Wno-lint --top-module tb_up5k -DF_HZ=$F_HZ --Mdir $OBJ -o tb_vl $SRC \
        rtl/fyracore_picorv32.v rtl/rf_top_fpga.v rtl/fpga_top.v third_party/picorv32/picorv32.v \
        sim/sb_io_sim.v $PINDIR/tb/qspi_pmod_model.v $PINDIR/tb/rp2350_uart_model.v sim/tb_up5k.v \
        > $D/compile$F_MHZ.log 2>&1
fi
$OBJ/tb_vl +FLASH_FILE=$PWD/$D/cfg$CFG/fw.hex +GOLDEN=$D/cfg$CFG/golden.txt +MAXCYC=${MAXCYC:-300000000} \
    > $D/cfg$CFG/sim.log 2>&1 || true
grep -E "SIM DONE|SIM TIMEOUT" $D/cfg$CFG/sim.log || echo "no SIM DONE line"
echo "assertions/errors: $(grep -cE 'ASSERT|ERROR|FAIL ' $D/cfg$CFG/sim.log)"
