#!/usr/bin/env python3
"""Make consts.vh and consts.txt for the RTL lemma (tb/eqy/run.sh).

  lemma_gen.py CONSTS.cand RESET.log OUT_DIR

CONSTS.cand lists the removed flop bits (name[idx]), from accounting.py.
RESET.log is the yosys `sat` log of a one-edge reset from the all-zero state
that shows each of the registers; its step-2 rows are the reset values.
Writes OUT_DIR/consts.vh (a mask and a value per register, for
lemma_props.sv) and OUT_DIR/consts.txt (one `name[idx] <bit>` per bit, which
the gold script ties once the lemma is PROVED).
"""
import collections, re, sys

cand = [l.strip() for l in open(sys.argv[1]) if l.strip()]
vals = {}
for l in open(sys.argv[2]):
    m = re.match(r"^\s+2\s+\\(\S+)\s+\S+\s+\S+\s+([01x]+)\s*$", l)
    if m:
        vals[m.group(1)] = m.group(2)
regs = collections.defaultdict(list)
for c in cand:
    m = re.match(r"^(.*)\[(\d+)\]$", c)
    regs[m.group(1)].append(int(m.group(2)))
vh, txt = [], []
for r in sorted(regs):
    if r not in vals:
        sys.exit(f"no reset value for {r} in {sys.argv[2]}")
    bits = vals[r][::-1]            # index 0 = lsb
    mask = val = 0
    for i in sorted(regs[r]):
        if bits[i] not in "01":
            sys.exit(f"{r}[{i}] reset value is {bits[i]}")
        mask |= 1 << i
        val |= int(bits[i]) << i
        txt.append(f"{r}[{i}] {bits[i]}")
    mid = r.replace(".", "_")
    vh.append(f"`define LM_{mid} 32'h{mask:08x}")
    vh.append(f"`define LV_{mid} 32'h{val:08x}")
open(sys.argv[3] + "/consts.vh", "w").write("\n".join(vh) + "\n")
open(sys.argv[3] + "/consts.txt", "w").write("\n".join(txt) + "\n")
print(f"{len(txt)} constant bits in {len(regs)} registers")
for r in sorted(regs):
    print(f"  {r:40s} {len(regs[r]):3d} bits")
