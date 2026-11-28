#!/usr/bin/env python3
"""Stuck-at-0 on one flop's D, tied to the netlist's conb LO net.

  mutate_netlist.py PNL OUT --kind {csr,alu,spi}
  mutate_netlist.py PNL OUT --kind net --q '<Q net of a flop, e.g. \\soc.plic_inst.en[1]>'

csr: bit 3 of \\soc.cpu.csr_unit.mscratch (a CSR the riscv-tests write and read).
alu: bit 0 of the writeback result flop, \\soc.cpu.exwb_alu_result[0].
spi: the SPI transmitter's MOSI flop (RTL soc.gpio_inst.spi_inst.mosi_r, p_mosi, GPIO out bit 1).
     Synthesis renamed it, so it is found by tracing uo_out[1]'s driver back through the
     combinational cells (inverter, nand with `run`) and, on the 4x4 netlist, the pinmux's pin flop
     to the flops behind it; of those the one whose Q net is \\gpio_out[1] (the pin's own bit) is taken. Anything else: the candidates are
     printed and the exit is 1. Only a program that sends SPI bytes sees it (part D).
net: the flop whose Q net is the one given (4x4 part D: PLIC enable, gamepad data, PWM compare bits).
Prints the flop instance, its type, the old D net and the LO net it now reads.
"""
import re, sys

KINDS = {"csr": r"\soc.cpu.csr_unit.mscratch[3]", "alu": r"\soc.cpu.exwb_alu_result[0]",
         "spi": None,   # traced from uo_out[1]
         "net": None}   # --q

FLOP = r"sky130_fd_sc_hd__(dfxtp|dfrtp|dfstp|dfxbp|edfxtp)\w*"

def trace_mosi(s, pin="uo_out[1]", want=r"\gpio_out[1]"):
    insts, drv = {}, {}
    for m in re.finditer(r"\n (sky130_fd_sc_hd__\w+)\s+(\S+)\s+\((.*?)\);", s, re.S):
        t, n, body = m.groups()
        pins = {a: b.strip() for a, b in re.findall(r"\.(\w+)\(([^)]*)\)", body)}
        insts[n] = (t, pins)
        for o in ("Y", "X", "Q", "Q_N"):
            if o in pins:
                drv[pins[o]] = n
    flops, seen, todo = {}, set(), [(pin, 0)]
    while todo:
        net, d = todo.pop()
        if net in seen or net not in drv:
            continue
        seen.add(net)
        t, pins = insts[drv[net]]
        if re.match(FLOP, t):
            flops[drv[net]] = pins.get("Q")
            # 4x4: the pinmux registers the pin (\soc.pinmux_inst.uo[1]); look through that flop to the GPIO bit behind it
            if pins.get("Q") != want and "D" in pins:
                todo.append((pins["D"], d + 1))
        elif d < 6:
            todo += [(v, d + 1) for k, v in pins.items()
                     if k not in ("VGND", "VNB", "VPB", "VPWR", "X", "Y")]
    cand = {n: q for n, q in flops.items() if q == want}
    if len(cand) != 1:
        sys.exit("ambiguous MOSI trace from %s: flops reached %s; wanted Q net %s" % (pin, flops, want))
    return list(cand.values())[0]

def main():
    ok = len(sys.argv) == 5 or (len(sys.argv) == 7 and sys.argv[4] == "net" and sys.argv[5] == "--q")
    if not ok or sys.argv[3] != "--kind" or sys.argv[4] not in KINDS:
        sys.exit(__doc__)
    src, dst, q = sys.argv[1], sys.argv[2], KINDS[sys.argv[4]]
    if sys.argv[4] == "net":
        q = sys.argv[6]
    s = open(src).read()
    m = re.search(r"sky130_fd_sc_hd__conb_\d+ \S+\s+\([^;]*?\.LO\(([^)\s]+)\s*\)", s)
    if not m:
        sys.exit("no conb LO net")
    lo = m.group(1)
    if q is None:
        q = trace_mosi(s)   # kind spi
    pat = ".Q(" + q + " )"
    hits = [i for i in range(len(s)) if s.startswith(pat, i)]
    # the net is also read by logic and by hold buffers, but only a flop has it on .Q
    for i in hits:
        st = s.rfind("\n sky130_fd_sc_hd__", 0, i) + 2     # the instance's line (net names contain "sky130_fd_sc_hd__" too)
        end = s.index(";", i)
        inst = s[st:end + 1]
        if not re.match(r"sky130_fd_sc_hd__(dfxtp|dfrtp|dfstp|dfxbp|edfxtp)\w* ", inst):
            continue
        d = re.search(r"\.D\(([^)]*)\)", inst)
        if not d:
            continue
        new = inst.replace(d.group(0), ".D(" + lo + ")", 1)
        open(dst, "w").write(s[:st] + new + s[end + 1:])
        print("flop %s (%s): Q %s, D %s -> %s" % (inst.split()[1], inst.split()[0], q, d.group(1), lo))
        return
    sys.exit("no flop with Q " + q)

main()
