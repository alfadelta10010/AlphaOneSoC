#!/usr/bin/env python3
"""fsmcut.py SIDE IN.il OUT.il  -- WO-24 closure experiment (plan-exp3).

Gold: each FSM flop's Q is moved to wire <cut>; an instance fsmcut_gold_<tag>
drives the original wire (all readers) with clamp(<cut>).
Gate: each one-hot flop bit's Q is moved to <name>__oh[k]; an instance
fsmcut_gate_<tag> drives <cut> = enc(oh) and the original scalar nets
<name>[k] (all readers) with onehot(clamp(<cut>)).
Both sides: the rf_top macro's w_ena pin gets its own net (kept $pos), so
no reader other than the macro sees the pin's cut.
Every edit is asserted to hit exactly one line."""
import re, sys
side, src, dst = sys.argv[1:4]
TOP = "tt_um_alfadelta10010_alphaone_soc"
FSMS = [("soc.cpu.exwb_memSize", 2, 3, "memsize", "soc.cpu.fsmcut_exwb_memSize"),
        ("soc.cpu.muldiv_inst.st", 3, 6, "muldiv", "soc.cpu.muldiv_inst.fsmcut_st"),
        ("soc.qspi.state", 3, 7, "qspi", "soc.qspi.fsmcut_state")]
text = open(src).read()
m = re.search(r"^module \\%s\n.*?^end\n" % re.escape(TOP), text, re.S | re.M)
assert m, "top module not found"
body = m.group(0)
add = []

def once(body, old, new):
    n = body.count(old)
    assert n == 1, f"{side}: {old.strip()!r} found {n} times"
    print(f"{side}: {old.strip()}  ->  {new.strip()}")
    return body.replace(old, new)

def alias_names(body, w):
    """w and every name joined to it by module-level single-wire connects."""
    pairs = re.findall(r"^  connect (\\\S+) (\\\S+)\n", body, re.M)
    names, grew = {w}, True
    while grew:
        grew = False
        for a, b in pairs:
            if (a in names) != (b in names):
                names |= {a, b}; grew = True
    return sorted(names)

for name, w, n, tag, cut in FSMS:
    if side == "gold":
        body = once(body, f"    connect \\Q \\{name}\n", f"    connect \\Q \\{cut}\n")
        add.append(f"  wire width {w} \\{cut}\n")
        add.append(f"  cell \\fsmcut_gold_{tag} \\fsmcutI_{tag}\n    connect \\q \\{cut}\n    connect \\y \\{name}\n  end\n")
    else:
        for k in range(n):
            # the flop's Q may sit on an alias (module-level `connect \\<bit> \\netNNN`): take the net's names
            names = alias_names(body, f"\\{name}[{k}]")
            hits = [a for a in names if body.count(f"    connect \\Q {a}\n") == 1]
            assert len(hits) == 1 and sum(body.count(f"    connect \\Q {a}\n") for a in names) == 1, (name, k, names, hits)
            body = once(body, f"    connect \\Q {hits[0]}\n", f"    connect \\Q \\{name}__oh [{k}]\n")
        dec = " ".join(f"\\{name}[{k}]" for k in reversed(range(n)))
        add.append(f"  wire width {n} \\{name}__oh\n  wire width {w} \\{cut}\n")
        add.append(f"  cell \\fsmcut_gate_{tag} \\fsmcutI_{tag}\n    connect \\oh \\{name}__oh\n"
                   f"    connect \\q \\{cut}\n    connect \\dec {{ {dec} }}\n  end\n")

# rf_top w_ena pin: own net through a kept $pos
cm = re.search(r"^  cell \\rf_top \\soc\.cpu\.rf\.rf_macro\n(.*?)^  end\n", body, re.S | re.M)
assert cm, "rf_macro cell not found"
cell = cm.group(0)
pm = re.findall(r"^    connect \\w_ena (.+)\n", cell, re.M)
assert len(pm) == 1, pm
sig = pm[0]
cell2 = cell.replace(f"    connect \\w_ena {sig}\n", "    connect \\w_ena \\soc.cpu.rf.w_ena_pin\n")
body = body.replace(cell, cell2)
print(f"{side}: rf_macro w_ena {sig} -> soc.cpu.rf.w_ena_pin (kept $pos)")
add.append("  wire width 1 \\soc.cpu.rf.w_ena_pin\n  attribute \\keep 1\n  cell $pos $eqy_wena_pinbuf\n"
           "    parameter \\A_SIGNED 0\n    parameter \\A_WIDTH 1\n    parameter \\Y_WIDTH 1\n"
           f"    connect \\A {sig}\n    connect \\Y \\soc.cpu.rf.w_ena_pin\n  end\n")
assert body.endswith("end\n")
# RTLIL needs a wire declared before its first use: wires right after the module line, cells at the end
wires = "".join(l + "\n" for a in add for l in a.splitlines() if l.startswith("  wire "))
cells = "".join(l + "\n" for a in add for l in a.splitlines() if not l.startswith("  wire "))
head = body.index("\n") + 1
body = body[:head] + wires + body[head:-4] + cells + "end\n"
open(dst, "w").write(text[:m.start()] + body + text[m.end():])
