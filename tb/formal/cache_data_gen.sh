#!/bin/bash
# WO-CF step 3: GEN script for cache_data (run.sh: cache_data_gen.sh <src dir> <out dir>, prints the generated source).
# Takes cache_dbg_gen.sh's copy of src/cache.v (CACHE_DBG ports + ghost tags) and adds, to the copy only, a tracked-word
# window into the two data macros: input g_cw (the word index inside a macro that the harness tracks), each rf_top
# instance gets .cw(g_cw) and .cmem(...) (the harness's macro model keeps just that word), plus debug ports for the two
# cmem values, dead and fcnt. Refuses if the instance lines are not exactly two.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
p=$(bash "$HERE/cache_dbg_gen.sh" "$1" "$2")
o="$2/cache_data.v"
[ "$(grep -c '^        \.clk     (clk)$' "$p")" = 2 ] || { echo "cache_data_gen: expected two rf_top .clk lines" >&2; exit 1; }
awk 'BEGIN{n=0} /^        \.clk     \(clk\)$/ {n++; print "        .clk     (clk), .cw(g_cw), .cmem(" (n==1 ? "cm_lo" : "cm_hi") ")"; next} {print}' "$p" > "$o"
sed -i -e 's/^\(    , output wire \[15:0\] dbg_valid, .*\)$/\1\n    , input wire [4:0] g_cw, output wire [31:0] dbg_cm_lo, output wire [31:0] dbg_cm_hi, output wire dbg_dead, output wire [1:0] dbg_fcnt/' \
       -e 's/^    reg         act;  /    wire [31:0] cm_lo, cm_hi;\n&/' \
       -e 's/^endmodule$/    assign dbg_cm_lo = cm_lo, dbg_cm_hi = cm_hi, dbg_dead = dead, dbg_fcnt = fcnt;\nendmodule/' "$o"
for k in 'input wire \[4:0\] g_cw' 'wire \[31:0\] cm_lo, cm_hi;' 'assign dbg_cm_lo' '.cmem(cm_hi)'; do
  grep -q "$k" "$o" || { echo "cache_data_gen: edit '$k' did not apply" >&2; exit 1; }
done
echo "$o"
