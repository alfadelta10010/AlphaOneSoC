#!/usr/bin/env bash
# Sandbox entry point: manifest + port check + synth + PnR + bitstream. Run via scripts/launch.sh
# (thermal watchdog) for anything long:  M=~/regr/fpga-up5k/wo-f1/m1 scripts/launch.sh ./build.sh
set -eu
cd "$(dirname "$0")"
export PATH=/home/mempool/tools/oss-cad-suite/bin:$PATH
ulimit -v 4000000
mkdir -p build
make manifest
make ports
make -j1 all "$@"
echo "--- utilisation"; grep -E "Number of cells|SB_LUT4|SB_CARRY|SB_DFF|SB_RAM40|SB_SPRAM" build/synth.stat | head -12
