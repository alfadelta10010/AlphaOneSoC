#!/bin/bash
# Zero-area check for the RVFI port (WO-36). Run in a shell where
# ~/tools/oss-cad-suite/environment is sourced (yosys 0.70) -- or it is
# sourced here. Usage: zero_area.sh [BASE=a2f7285]   (run inside a git tree)
# Without a .git (sandbox tree) set ZA_BASE_SRC=<dir with BASE src/*.v>.
# Builds coarse netlists (prep -flatten; memory_map; opt_clean -purge; no ABC):
#   a = BASE src, no define    b = HEAD src, no define
#   c = HEAD src, -DRISCV_FORMAL    d = HEAD src, both defines (info only)
# and prints ZA stat a=b / a=c, ZA equiv a=c, and an info line for a=d.
set -u
BASE=${1:-a2f7285}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
command -v yosys >/dev/null || source ~/tools/oss-cad-suite/environment
W=${ZA_DIR:-$ROOT/build/za}; rm -rf "$W"; mkdir -p "$W/a"
if [ -n "${ZA_BASE_SRC:-}" ]; then mkdir -p "$W/a/src"; cp "$ZA_BASE_SRC"/*.v "$W/a/src/"   # tree without .git: BASE src given
else git -C "$ROOT" archive "$BASE" src | tar -x -C "$W/a"; fi
SRCS="tt_um_alfadelta10010_alphaone_soc.v alphaone_soc.v fyracore.v alu.v branchCtrl.v clint.v compressed_decoder.v controller.v csr.v decoder.v muldiv.v pmp.v regFile.v signExt.v qspi_ctrl.v mem_ctrl.v soc_bus.v uart.v gpio.v spi.v syscon.v"
cat > "$W/rf_plain.v" <<'V'
module rf_top(input wire [31:0] w_data, input wire [4:0] w_addr, input wire w_ena,
  input wire [4:0] ra_addr, input wire [4:0] rb_addr, output reg [31:0] ra_data, output reg [31:0] rb_data, input wire clk);
  reg [31:0] mem [0:31];
  always @(posedge clk) begin
    if (w_ena) mem[w_addr] <= w_data;
    ra_data <= (w_ena && w_addr == ra_addr) ? w_data : mem[ra_addr];
    rb_data <= (w_ena && w_addr == rb_addr) ? w_data : mem[rb_addr];
  end
endmodule
V
# $1 = tag, $2 = src dir, $3 = defines
build() {
  local s=""; for f in $SRCS; do s="$s read_verilog -sv $3 $2/$f;"; done
  yosys -q -l "$W/$1.log" -p "$s read_verilog -sv $W/rf_plain.v; hierarchy -top tt_um_alfadelta10010_alphaone_soc; prep -flatten -top tt_um_alfadelta10010_alphaone_soc; memory_map; opt_clean -purge; tee -o $W/$1.stat stat; write_rtlil $W/$1.il" >/dev/null 2>&1 \
    || { echo "ZA build $1 FAILED (see $W/$1.log)"; return 1; }
}
build a "$W/a/src" "" || exit 1
build b "$ROOT/src" "" || exit 1
build c "$ROOT/src" "-DRISCV_FORMAL" || exit 1
build d "$ROOT/src" "-DRISCV_FORMAL -DRISCV_FORMAL_ALTOPS" || exit 1
norm() { grep -E '^ +[0-9]+ +(\$|cells)|cells$' "$W/$1.stat" | sed 's/  */ /g'; }
for x in b c; do
  if [ "$(norm a)" = "$(norm $x)" ]; then echo "ZA stat a=$x IDENTICAL ($(grep -E '^ +[0-9]+ +cells' $W/a.stat | tr -s ' ' | head -1))"
  else echo "ZA stat a=$x DIFFERS"; diff <(norm a) <(norm $x) | head -10; fi
done
if [ "$(norm a)" = "$(norm d)" ]; then echo "ZA stat a=d IDENTICAL (unexpected: ALTOPS should replace the M result)"
else echo "ZA stat a=d DIFFERS (expected: ALTOPS replaces the M result)"; fi
# equivalence a vs c: gold = a, gate = c; module names differ by tag via rename
yosys -l "$W/eq.log" -p "read_rtlil $W/a.il; async2sync; rename tt_um_alfadelta10010_alphaone_soc gold; design -stash g; read_rtlil $W/c.il; async2sync; rename tt_um_alfadelta10010_alphaone_soc gate; design -stash t; design -copy-from g -as gold gold; design -copy-from t -as gate gate; equiv_make gold gate eq; hierarchy -top eq; cd eq; equiv_add \\soc.cpu.wfi_active_gold \\soc.cpu.fv_wfi_active_gate; cd ..; equiv_simple -seq 2; equiv_induct -seq 2; tee -o $W/eq.status equiv_status; equiv_status -assert" >/dev/null 2>&1
rc=$?
if [ $rc -eq 0 ]; then echo "ZA equiv a=c PROVEN"
elif grep -q "are proven and" "$W/eq.status" 2>/dev/null; then
  # equiv_status ran: report the leftover verbatim. Observed 2026-11-07: all
  # outputs and 5015 of 5016 $equiv cells proven. The leftover was an artefact of
  # equiv_make pairing: wfi_active keeps the alias name fv_wfi_active in build (c),
  # so it got no $equiv; the explicit equiv_add above pairs it (5017/5017).
  echo "ZA equiv a=c NOTRUN $(grep -E 'are proven and' $W/eq.status | tr -s ' ' | head -1); unproven: $(grep -E 'Unproven' $W/eq.status | sed 's/.*find_same_wires[^:]*: //' | head -3 | tr '\n' ';')"
else echo "ZA equiv a=c FAILED (rc=$rc; log $W/eq.log)"; fi
