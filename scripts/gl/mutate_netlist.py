#!/usr/bin/env python3
"""Stuck-at-0 on one flop's D, tied to the netlist's conb LO net.

  mutate_netlist.py PNL OUT --kind {csr,alu}

csr: bit 3 of \\soc.cpu.csr_unit.mscratch (a CSR the riscv-tests write and read).
alu: bit 0 of the writeback result flop, \\soc.cpu.exwb_alu_result[0].
Prints the flop instance, its type, the old D net and the LO net it now reads.
"""
import re, sys

KINDS = {"csr": r"\soc.cpu.csr_unit.mscratch[3]", "alu": r"\soc.cpu.exwb_alu_result[0]"}

def main():
    if len(sys.argv) != 5 or sys.argv[3] != "--kind" or sys.argv[4] not in KINDS:
        sys.exit(__doc__)
    src, dst, q = sys.argv[1], sys.argv[2], KINDS[sys.argv[4]]
    s = open(src).read()
    m = re.search(r"sky130_fd_sc_hd__conb_\d+ \S+ \([^;]*?\.LO\(([^)\s]+)\s*\)", s)
    if not m:
        sys.exit("no conb LO net")
    lo = m.group(1)
    pat = ".Q(" + q + " )"
    hits = [i for i in range(len(s)) if s.startswith(pat, i)]
    # the net is also read by logic and by hold buffers, but only a flop has it on .Q
    for i in hits:
        st = s.rfind("sky130_fd_sc_hd__", 0, i)
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
