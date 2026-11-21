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
echo "$o"
