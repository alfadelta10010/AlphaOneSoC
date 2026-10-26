#!/usr/bin/env python3
"""Change one gate in the D cone of a flop of the hardened netlist (WO-24).

  mutate_netlist.py NETLIST OUT --kind {core,syscon} [--lib LIBERTY]

The equivalence check must FAIL on the result, so that a PASS on the real
netlist means something. One cell of the combinational cone behind a flop's D
pin changes its type and keeps its instance name and pins (the output pin
name changes with the type: Y -> X):

    nand2 -> and2     nor2 -> or2     inv -> buf     a21oi -> a21o

the cell nearest the flop first, in the same drive strength if the library
has it (else the next one down). --kind core: the cone of
\\soc.cpu.ifex_pc[4]; --kind syscon: the cone of a \\soc.syscon_inst.cause[*]
flop, or of \\soc.syscon_inst.rq. Prints the flop (`flop NAME`), the instance
and the change.
"""
import argparse, collections, re, sys

SWAP = {"nand2": "and2", "nor2": "or2", "inv": "buf", "a21oi": "a21o"}
OUTPUTS = {"X", "Y", "Q", "Q_N", "SUM", "COUT", "HI", "LO", "Z"}
PFX = "sky130_fd_sc_hd__"
INST = re.compile(r"^[ \t]*(sky130_fd_sc_hd__\w+)\s+(\S+)\s*\((.*?)\);", re.S | re.M)
PIN = re.compile(r"\.(\w+)\(([^()]*)\)")


def lib_cells(path):
    if not path:
        return None
    return set(re.findall(r'cell\s*\(\s*"?(sky130_fd_sc_hd__\w+?)"?\s*\)', open(path).read()))


def pick(base, size, cells):
    """the swapped cell: same size if it exists, else the largest smaller one"""
    for s in sorted({int(x) for x in [size, 16, 12, 8, 6, 4, 2, 1, 0]}, reverse=True):
        if s > int(size):
            continue
        c = f"{PFX}{base}_{s}"
        if cells is None or c in cells:
            return c
    raise SystemExit(f"no {base} cell of size <= {size}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("netlist"); ap.add_argument("out")
    ap.add_argument("--kind", choices=["core", "syscon"], required=True)
    ap.add_argument("--lib")
    a = ap.parse_args()
    txt = open(a.netlist).read()
    cells = lib_cells(a.lib)
    insts = {}
    drv = {}                       # net -> instance driving it
    for m in INST.finditer(txt):
        cell, name = m.group(1), m.group(2)
        pins = {p: " ".join(n.split()) for p, n in PIN.findall(m.group(3))}
        insts[name] = (cell, pins, m.span())
        for p, n in pins.items():
            if p in OUTPUTS:
                drv[n] = name

    def q_net(n):
        return rf"\{n} "[0:-1] if False else "\\" + n

    flops = {}
    for name, (cell, pins, _) in insts.items():
        if re.search(r"__df\w+", cell) and "Q" in pins:
            flops[pins["Q"]] = name
    if a.kind == "core":
        want = ["\\soc.cpu.ifex_pc[4]"]
    else:
        want = sorted(n for n in flops if n.startswith("\\soc.syscon_inst.cause[")) + ["\\soc.syscon_inst.rq"]
    for q in want:
        if q not in flops:
            continue
        fl = flops[q]
        seen = {fl}; queue = collections.deque([(insts[fl][1]["D"], 0)])
        while queue:
            net, depth = queue.popleft()
            if net not in drv:
                continue
            g = drv[net]
            if g in seen:
                continue
            seen.add(g)
            cell, pins, span = insts[g]
            if re.search(r"__df|__dl", cell):
                continue
            mm = re.match(PFX + r"(nand2|nor2|inv|a21oi)_(\d+)$", cell)
            if mm:
                new = pick(SWAP[mm.group(1)], mm.group(2), cells)
                old_out = "Y"
                body = txt[span[0]:span[1]]
                body2 = body.replace(cell, new, 1)
                body2 = re.sub(r"\.Y\(", ".X(", body2, count=1)
                txt2 = txt[:span[0]] + body2 + txt[span[1]:]
                open(a.out, "w").write(txt2)
                print(f"flop {q.lstrip(chr(92))}")
                print(f"cone depth {depth + 1}")
                print(f"instance {g}")
                print(f"change {cell} -> {new} (pin Y -> X)")
                return
            for p, n in pins.items():
                if p not in OUTPUTS:
                    queue.append((n, depth + 1))
    sys.exit(f"no nand2/nor2/inv/a21oi in the D cone of {want}")


main()
