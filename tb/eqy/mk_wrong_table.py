#!/usr/bin/env python3
"""mk_wrong_table.py IN.v OUT.v: swap qspi bits 1 and 2 in fsmcut_gate_qspi's enc and dec (the fsmtable mutant)."""
import sys
t = open(sys.argv[1]).read()
a = t.index("module fsmcut_gate_qspi"); h, m = t[:a], t[a:]
for old, new in (("(oh[1] ? 3'b100 : 3'b000) | (oh[2] ? 3'b010 : 3'b000)", "(oh[1] ? 3'b010 : 3'b000) | (oh[2] ? 3'b100 : 3'b000)"),
                 ("c == 3'b010, c == 3'b100, c == 3'b000", "c == 3'b100, c == 3'b010, c == 3'b000")):
    assert m.count(old) == 1, old
    m = m.replace(old, new)
open(sys.argv[2], "w").write(h + m)
