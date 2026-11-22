#!/bin/bash
# Boot the packed Linux payload on the SoC bench and type the session in sw/linux/session.txt.
#   run-bench.sh [workdir]     (default $LINUX_WORK or ~/linux-work)
# Needs: $W/deliver/flash-linux.hex (recipe/pack.sh), the bench ($W/build/sw/bench/sim, make -C sw bench) and Python 3.
# The session is typed one character per echo (sw/nuttx/tools/mkscript_slow.py), because the SoC UART's receiver
# is one byte deep and the bench sender ignores RTS#; the 8250 driver is polled, so this is also about 30
# characters a second at HZ 30. About 2.05 G clocks, 71 minutes of Verilator on an idle core.
set -eu
W=${1:-${LINUX_WORK:-$HOME/linux-work}}; D=$W/deliver; HERE=$(cd "$(dirname "$0")" && pwd)
python3 $HERE/../nuttx/tools/mkscript_slow.py $HERE/session.txt $D/in.hex
cd $D
stdbuf -oL nice -n 19 $W/build/sw/bench/sim +FLASH_FILE=$D/flash-linux.hex +UART_DIV=34 +UART_IN=$D/in.hex \
    +MAX_CYCLES=${MAXC:-6000000000} > $D/bench-boot.log 2>&1 || true
grep -q "^SW-RESULT: PASS" $D/bench-boot.log && echo "linux: PASS" || { echo "linux: FAIL"; exit 1; }
