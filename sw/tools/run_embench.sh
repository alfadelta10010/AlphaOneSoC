#!/bin/bash
# Run every built Embench payload on the software bench, JOBS at a time, check
# each run, and print the Embench speed score.
#
#   make bench embench && tools/run_embench.sh [jobs]
#
# At scale factor 1 one benchmark is about 150 to 500 million clocks, i.e.
# minutes of Verilator each; the whole suite wants the sandbox, not a laptop.
cd "$(dirname "$0")/.." || exit 1
BUILD=$(cd ../build/sw && pwd)
JOBS=${1:-4}
MAXC=${MAXC:-2000000000}      # tb_sw counts cycles in a 32-bit integer

ls -d "$BUILD"/embench-*/ | xargs -P "$JOBS" -I{} sh -c \
    'cd {} && ../bench/sim +FLASH_FILE=$PWD/flash.hex +MAX_CYCLES='"$MAXC"' > run.log 2>&1'

bad=0
for d in "$BUILD"/embench-*/; do
    n=$(basename "$d")
    python3 tools/check_run.py "$d/run.log" embench/expect.txt > "$d/check.txt" 2>&1 || { echo "$n: $(head -1 "$d/check.txt")"; bad=1; }
done
python3 tools/embench_report.py "$BUILD/third_party/embench-iot/baseline-data/speed.json" "${GSF:-1}" "$BUILD"
exit $bad
