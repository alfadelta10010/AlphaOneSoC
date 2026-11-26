#!/usr/bin/env python3
"""Make consts.vh and consts.txt for the RTL lemma (tb/eqy/run.sh).

  lemma_gen.py CONSTS.cand RESET.log OUT_DIR

CONSTS.cand lists the removed flop bits (name[idx]), from accounting.py.
RESET.log is the yosys `sat` log of a one-edge reset from the all-zero state
that shows each of the registers; its step-2 rows are the reset values.
Writes OUT_DIR/consts.vh (a mask and a value per register, for
lemma_props.sv) and OUT_DIR/consts.txt (one `name[idx] <bit>` per bit, which
the gold script ties once the lemma is PROVED).

A register declared [N:K] with K != 0 (plic pend/insvc are [NSRC:1]) is a port
of width N-K+1 whose LSB is bit K: the sat trace prints it by position, and
lemma_props.sv declares the port [N-K:0], so the mask and the value are made
by position (index - K). K is read from OUT_DIR/exposed.il (the design the
reset trace ran on); a register missing there stops the script.
"""
import collections, os, re, sys

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
offset = {}
for l in open(os.path.join(sys.argv[3], "exposed.il")):
    m = re.match(r"^\s*wire (?:width (\d+) )?(?:offset (\d+) )?.*?\\(\S+)\s*$", l)
    if m and m.group(3) in regs:
        offset[m.group(3)] = (int(m.group(1) or 1), int(m.group(2) or 0))
vh, txt = [], []
for r in sorted(regs):
    if r not in vals:
        sys.exit(f"no reset value for {r} in {sys.argv[2]}")
    if r not in offset:
        sys.exit(f"no wire {r} in exposed.il")
    width, off = offset[r]
    bits = vals[r][::-1]            # position 0 = lsb = bit `off`
    if len(bits) != width or width > 32:
        sys.exit(f"{r}: trace width {len(bits)}, exposed.il width {width} (32 at most)")
    mask = val = 0
    for i in sorted(regs[r]):
        p = i - off
        if not 0 <= p < width:
            sys.exit(f"{r}[{i}] is outside [{off + width - 1}:{off}]")
        if bits[p] not in "01":
            sys.exit(f"{r}[{i}] reset value is {bits[p]}")
        mask |= 1 << p
        val |= int(bits[p]) << p
        txt.append(f"{r}[{i}] {bits[p]}")
    mid = r.replace(".", "_")
    vh.append(f"`define LM_{mid} 32'h{mask:08x}")
    vh.append(f"`define LV_{mid} 32'h{val:08x}")
# soundness: every register with removed bits must be checked by lemma_props.sv,
# or its bits would be tied in gold without a proof
props = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "lemma_props.sv")).read()
for r in sorted(regs):
    if "`LM_" + r.replace(".", "_") + ")" not in props:
        sys.exit(f"{r} has removed bits but lemma_props.sv does not check it")
open(sys.argv[3] + "/consts.vh", "w").write("\n".join(vh) + "\n")
open(sys.argv[3] + "/consts.txt", "w").write("\n".join(txt) + "\n")
print(f"{len(txt)} constant bits in {len(regs)} registers")
for r in sorted(regs):
    print(f"  {r:40s} {len(regs[r]):3d} bits")
