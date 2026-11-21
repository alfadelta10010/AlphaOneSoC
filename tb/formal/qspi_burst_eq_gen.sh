#!/bin/bash
# WO-68: GEN script for qspi_burst_eq (run.sh calls it as: qspi_burst_eq_gen.sh <src dir> <out dir>, takes the printed path as a source).
# Builds, in the out dir, the two engines of the miter with their state exported for the induction helper:
#   qspi_ctrl_tap_new  = <src dir>/qspi_ctrl.v (the RTL under test, mutated copies included), renamed, with eq_tap = every
#                        register the old engine also has, and eq_x = {pstrm, t_bst} (the burst-only state)
#   qspi_ctrl_tap_old  = tb/formal/qspi_ctrl_pre_burst.v (src/qspi_ctrl.v as of 22f7bc8, before the PSRAM line burst), eq_x = 0
# The RTL under test is not edited (the same instrumentation style as core_fetch in run.sh).
set -e
HERE=$(dirname "$0")
TAP='{state, cnt, sr, init, step, late, again, t_we, t_psram, strm, p, t_top, t_sel, t_ddr, t_cap, nib_p, nib_n, cap_n, dq, sck, cs_n, ctl_oe, io_oe}'
inst() {   # inst <in> <module> <new name> <eq_x expression>
    sed -e "s/^module $2 (\$/module $3 (\n    output wire [104:0] eq_tap,\n    output wire [1:0] eq_x,/" \
        -e "s/^endmodule\$/    assign eq_tap = $TAP;\n    assign eq_x = $4;\nendmodule/" "$1"
}
{ inst "$1/qspi_ctrl.v" qspi_ctrl qspi_ctrl_tap_new "{pstrm, t_bst}"
  inst "$HERE/qspi_ctrl_pre_burst.v" qspi_ctrl_pre_burst qspi_ctrl_tap_old "2'b00"; } > "$2/qspi_ctrl_tap.v"
grep -q "assign eq_tap" "$2/qspi_ctrl_tap.v" && [ "$(grep -c 'assign eq_x' "$2/qspi_ctrl_tap.v")" = 2 ] || { echo "cannot instrument" >&2; exit 1; }
echo "$2/qspi_ctrl_tap.v"
