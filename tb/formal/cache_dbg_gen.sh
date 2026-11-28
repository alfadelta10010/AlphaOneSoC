#!/bin/bash
# WO-66: GEN script for cache_ind (run.sh calls it as: cache_dbg_gen.sh <src dir> <out dir>, takes the printed path as a source).
# Writes a copy of src/cache.v with the CACHE_DBG debug ports switched on, by deleting the two preprocessor lines around
# them; the RTL file is not edited. Refuses if cache.v holds any other conditional, so a new one cannot slip through.
set -e
f="$1/cache.v"; o="$2/cache_dbg.v"
[ "$(grep -c '^`ifdef' "$f")" = 2 ] && [ "$(grep -c '^`ifdef CACHE_DBG' "$f")" = 2 ] \
  && [ "$(grep -c '^`endif' "$f")" = 2 ] && ! grep -q '^`else\|^`ifndef\|^`elsif' "$f" \
  || { echo "cache_dbg_gen: unexpected conditionals in cache.v" >&2; exit 1; }
grep -v '^`ifdef CACHE_DBG\|^`endif' "$f" > "$o"
# WO-CF B1: ghost per-sector tag (gtags[s] = the tag of the fill that started on sector s) and the state it is compared with,
# added to the generated copy only: five more debug ports and one always block before endmodule.
sed -i -e 's/^    , output wire        dbg_act, dbg_hit_q, dbg_b_ph, dbg_fill, dbg_valid_any$/&\n    , output wire [15:0] dbg_valid, output wire [135:0] dbg_tags, output wire [271:0] dbg_gtags, output wire [16:0] dbg_fill_tag, output wire [3:0] dbg_fill_idx/' "$o"
grep -q 'dbg_gtags' "$o" || { echo "cache_dbg_gen: dbg port line not found in cache.v" >&2; exit 1; }
sed -i -e 's/^endmodule$/    reg [271:0] gtags;\n    always @(posedge clk) if (!rst \&\& start) gtags[17*kidx +: 17] <= ktag;\n    assign dbg_valid = valid, dbg_tags = tags, dbg_gtags = gtags, dbg_fill_tag = fill_tag, dbg_fill_idx = fill_idx;\nendmodule/' "$o"
grep -q 'assign dbg_gtags\|dbg_gtags = gtags' "$o" || { echo "cache_dbg_gen: endmodule not found" >&2; exit 1; }
echo "$o"
