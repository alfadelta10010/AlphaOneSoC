#!/usr/bin/env bash
# Sandbox: random-power-up check. The iCE40 starts every flop at 0, the ASIC starts random. Build the bench with
# Verilator --x-assign unique --x-initial unique and run cfg1 with random reset values for each seed; pass = ALL PASS
# and non-INFO lines identical to golden/cfg1.txt.   usage: scripts/run_vl_rand.sh [seed ...]  (default: 1 2)
# Output: build/vlr/seed$S/{golden.txt,sim.log,verdict.txt}. Run through scripts/launch.sh.
set -eu
cd "$(dirname "$0")/.."
export PATH=/home/mempool/tools/oss-cad-suite/bin:$PATH
SEEDS=${*:-1 2}
CFG=1
F_MHZ=${F_MHZ:-$(sed -n 's/^F_MHZ *?= *//p' Makefile | head -1)}
F_HZ=$((F_MHZ * 1000000))
PINDIR=${PINDIR:-../pin}
D=build/vlr; mkdir -p $D
make -s -C fw F_CLK=$F_HZ CFG=$CFG OUT=$PWD/$D/fw > $D/fw.log 2>&1
SRC="$(for f in $(grep -hv '^#' srclist.txt); do printf '%s/%s ' $PINDIR $f; done)"
OBJ=$D/obj$F_MHZ
verilator --binary --timing -j 2 -Wno-fatal -Wno-lint --x-assign unique --x-initial unique \
    --top-module tb_up5k -DF_HZ=$F_HZ --Mdir $OBJ -o tb_vl $SRC \
    rtl/fyracore_picorv32.v rtl/rf_top_fpga.v rtl/fpga_top.v third_party/picorv32/picorv32.v \
    sim/sb_io_sim.v $PINDIR/tb/qspi_pmod_model.v $PINDIR/tb/rp2350_uart_model.v sim/tb_up5k.v > $D/compile.log 2>&1
for S in $SEEDS; do
    R=$D/seed$S; mkdir -p $R
    $OBJ/tb_vl +FLASH_FILE=$PWD/$D/fw.hex +GOLDEN=$R/golden.txt +MAXCYC=${MAXCYC:-300000000} \
        +verilator+rand+reset+2 +verilator+seed+$S > $R/sim.log 2>&1 || true
    {
      grep -E "SIM DONE|SIM TIMEOUT" $R/sim.log || echo "no SIM DONE line"
      echo "ALL PASS lines: $(grep -c 'ALL PASS' $R/golden.txt)"
      echo "assertions/errors: $(grep -cE 'ASSERT|ERROR|FAIL ' $R/sim.log)"
      if diff <(grep -v '^INFO' golden/cfg$CFG.txt) <(grep -v '^INFO' $R/golden.txt) > $R/diff.txt; then
          echo "non-INFO diff vs golden/cfg$CFG.txt: identical"
      else echo "non-INFO diff vs golden/cfg$CFG.txt: DIFFERS (see diff.txt)"; fi
    } > $R/verdict.txt
    cat $R/verdict.txt
done
