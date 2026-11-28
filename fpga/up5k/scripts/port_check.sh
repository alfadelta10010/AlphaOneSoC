#!/usr/bin/env bash
# Sandbox (yosys). Empty diff or non-zero exit.
set -eu
cd "$(dirname "$0")/.."
export PATH=/home/mempool/tools/oss-cad-suite/bin:$PATH
PINDIR=${PINDIR:-../pin}
mkdir -p build
yosys -q -p "read_verilog $PINDIR/src/fyracore.v; proc; write_json build/ref_core.json" > build/port_ref.log 2>&1
yosys -q -p "read_verilog rtl/fyracore_picorv32.v; proc; write_json build/wrap_core.json" > build/port_wrap.log 2>&1
python3 scripts/port_check.py build/ref_core.json build/wrap_core.json
