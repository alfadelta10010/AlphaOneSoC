#!/usr/bin/env python3
"""fsmcut.py SIDE IN.il OUT.il  -- WO-24 closure experiment (plan-exp3).

Gold: each FSM flop's Q is moved to wire <cut>; an instance fsmcut_gold_<tag>
drives the original wire (all readers) with clamp(<cut>).
Gate: each one-hot flop bit's Q is moved to <name>__oh[k]; an instance
fsmcut_gate_<tag> drives <cut> = enc(oh) and the original scalar nets
<name>[k] (all readers) with onehot(clamp(<cut>)).
Both sides: the rf_top macro's w_ena pin gets its own net (kept $pos), so
no reader other than the macro sees the pin's cut; so do the I-cache data
macro's w_ena and rb_addr pins (soc.icache.pin_w_ena, pin_rb_addr; data_hi: pin_hi_*).
Every edit is asserted to hit exactly one line."""
import os, re, sys
side, src, dst = sys.argv[1:4]
TOP = "tt_um_alfadelta10010_alphaone_soc"
FSMS = [("soc.cpu.exwb_memSize", 2, 3, "memsize", "soc.cpu.fsmcut_exwb_memSize"),
        ("soc.cpu.muldiv_inst.st", 3, int(os.environ.get("MULDIV_N", "6")), "muldiv", "soc.cpu.muldiv_inst.fsmcut_st"),
        ("soc.qspi.state", 4, 10, "qspi", "soc.qspi.fsmcut_state"),
        ("soc.gpio_inst.spi_inst.st", 2, 3, "spi", "soc.gpio_inst.spi_inst.fsmcut_st")]
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
# I-cache data macros (soc.icache.data_mem and data_hi, WO-77: each gets its own nets): their two combinational input pins get their own
# nets the same way. EQY compares a black box's input pins and so cuts the nets wired to them for every reader.
# rb_addr is nxt[4:0] = f_addr[6:2] + 1, and synthesis shares that incrementer with the core's pc + 4, so with
# nxt cut the netlist's pc + 4 (and f_addr[2] = ~nxt[0]) read a free input that gold computes from the pc flops:
# the 23 FAILs of the first 4x4 prove run (2026-11-21), every one with nxt[0] == pc[2] in its trace. w_ena is
# word_in. soc.eqy.in nomatches soc.icache.nxt* and word_in, so only the pins are compared, and the logic is
# whole in every partition that reads it. The other pins (w_data = qspi sr, w_addr = fill_idx/fcnt, ra_addr =
# pc) are flop outputs, matched and cut anyway.
for inst, pfx, tag in (("soc.icache.data_mem", "pin_", "dm"), ("soc.icache.data_hi", "pin_hi_", "dh")):
    cm = re.search(r"^  cell \\rf_top \\%s\n(.*?)^  end\n" % re.escape(inst), body, re.S | re.M)
    assert cm, inst + " cell not found"
    cell = cm.group(0); cell2 = cell
    for port, width in (("w_ena", 1), ("rb_addr", 5)):
        pm = re.findall(r"^    connect \\%s (.+)\n" % port, cell, re.M)
        assert len(pm) == 1, (inst, port, pm)
        sig, pin = pm[0], f"soc.icache.{pfx}{port}"
        cell2 = cell2.replace(f"    connect \\{port} {sig}\n", f"    connect \\{port} \\{pin}\n")
        print(f"{side}: pin {inst.split('.')[-1]} {port} {sig} -> {pin} (kept $pos)")
        add.append(f"  wire width {width} \\{pin}\n  attribute \\keep 1\n  cell $pos $eqy_{tag}_{port}_pinbuf\n"
                   f"    parameter \\A_SIGNED 0\n    parameter \\A_WIDTH {width}\n    parameter \\Y_WIDTH {width}\n"
                   f"    connect \\A {sig}\n    connect \\Y \\{pin}\n  end\n")
    assert body.count(cell) == 1
    body = body.replace(cell, cell2)
assert body.endswith("end\n")
# RTLIL needs a wire declared before its first use: wires right after the module line, cells at the end
wires = "".join(l + "\n" for a in add for l in a.splitlines() if l.startswith("  wire "))
cells = "".join(l + "\n" for a in add for l in a.splitlines() if not l.startswith("  wire "))
head = body.index("\n") + 1
body = body[:head] + wires + body[head:-4] + cells + "end\n"
open(dst, "w").write(text[:m.start()] + body + text[m.end():])
