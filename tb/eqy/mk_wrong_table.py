#!/usr/bin/env python3
"""mk_wrong_table.py IN.v OUT.v [TAG]: the wrong-table mutants of the FSM cut point.

TAG qspi (default): swap bits 1 and 2 in fsmcut_gate_qspi's enc and dec (fsmcut_neg.v).
TAG spi: swap the 2'b10 and 2'b01 codes in fsmcut_gate_spi's enc and dec (fsmcut_neg_spi.v).
Each is exactly two changed lines."""
import sys
tag = sys.argv[3] if len(sys.argv) > 3 else "qspi"
SWAPS = {
    "qspi": (("(oh[1] ? 4'b1000 : 4'b0000) | (oh[2] ? 4'b0100 : 4'b0000)", "(oh[1] ? 4'b0100 : 4'b0000) | (oh[2] ? 4'b1000 : 4'b0000)"),
             ("c == 4'b0100, c == 4'b1000, c == 4'b0000", "c == 4'b1000, c == 4'b0100, c == 4'b0000")),
    "spi": (("(oh[1] ? 2'b10 : 2'b00) | (oh[2] ? 2'b01 : 2'b00)", "(oh[1] ? 2'b01 : 2'b00) | (oh[2] ? 2'b10 : 2'b00)"),
            ("{c == 2'b01, c == 2'b10, c == 2'b00}", "{c == 2'b10, c == 2'b01, c == 2'b00}")),
}
t = open(sys.argv[1]).read()
a = t.index("module fsmcut_gate_" + tag); b = t.find("module ", a + 10)
h, m, r = t[:a], t[a:b if b > 0 else len(t)], (t[b:] if b > 0 else "")
for old, new in SWAPS[tag]:
    assert m.count(old) == 1, old
    m = m.replace(old, new)
open(sys.argv[2], "w").write(h + m + r)
