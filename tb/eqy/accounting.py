#!/usr/bin/env python3
"""Flop accounting for the RTL-vs-netlist equivalence check (WO-24).

  accounting.py GOLD.json GATE.json OUT_DIR

GOLD.json is the flattened RTL after the gold read (before the constants are
tied), GATE.json the flattened netlist, both from yosys write_json with
single-bit nets (gold: splitnets -format []). Classifies every gold flop bit:

  direct   a net name of the gold bit is the Q net name of a gate flop, and
           it is the bit's own (first, public) name
  rename   the same flop under another net name (an alias of the gold bit)
  recode   a bit of an FSM register that synthesis recoded one-hot
  removed  no gate flop: the constant CSR bits, the unused gpio bits

and writes OUT_DIR/accounting.txt, consts.cand (the removed bits that are
not the unused gpio bits, one `name[idx]` per line) and OUT_DIR/renames.txt.
Exit status 1 if a count differs from the table of the work order.
"""
import collections, json, re, sys

EXPECT = dict(direct=1377, rename=7, recode_gold=11, recode_gate=22, removed=188,
              gold=1583, gate=1406)
RECODE = {"soc.cpu.exwb_memSize": (2, 3), "soc.cpu.muldiv_inst.st": (3, 6),
          "soc.qspi.state": (4, 10), "soc.gpio_inst.spi_inst.st": (2, 3)}
INTERNAL = re.compile(r"^[A-Za-z_0-9$]+\.[A-Z][A-Z0-9_]*$")
# gold bit -> gate Q net, for a rename that no alias of the gold bit shows. In
# the RTL if_pc_next[0] = (pc + 2 or 4)[0] = pc[0], a combinational copy of the
# pc[0] flop; synthesis folded the two nets and kept the name if_pc_next[0].
EXPLICIT_RENAME = {"soc.cpu.imem_addr[0]": "soc.cpu.if_pc_next[0]"}
UNUSED = {"soc.gpio_inst.out_r[4]", "soc.gpio_inst.out_r[5]"}


def netbits(mod):
    names = collections.defaultdict(list)
    for n, d in mod["netnames"].items():
        for i, b in enumerate(d["bits"]):
            if isinstance(b, int):
                nm = n if len(d["bits"]) == 1 else f"{n}[{i + d.get('offset', 0)}]"
                if INTERNAL.match(nm):      # flattened cell pin wires: `_123_.B`, `hold12.A`
                    continue
                names[b].append((d.get("hide_name", 0), nm))
    return {b: sorted(v) for b, v in names.items()}


def flops(mod, names):
    out = []   # (cell, type, bit, [names])
    for cn, c in mod["cells"].items():
        t = c["type"]
        if "DFF" in t.upper() or "dff" in t:
            for b in c["connections"]["Q"]:
                out.append((cn, t, b, [n for _, n in names.get(b, [(1, f"?{b}")])]))
    return out


def main():
    g = json.load(open(sys.argv[1]))["modules"]["tt_um_alfadelta10010_alphaone_soc"]
    t = json.load(open(sys.argv[2]))["modules"]["tt_um_alfadelta10010_alphaone_soc"]
    out = sys.argv[3]
    gf = flops(g, netbits(g))
    tf = flops(t, netbits(t))
    gate_q = {}
    for cn, ty, b, ns in tf:
        for n in ns:
            gate_q[n] = (cn, ty)
    cls = collections.defaultdict(list)
    renames = []
    recode_gold, recode_gate = [], []
    for cn, ty, b, ns in gf:
        prim = ns[0]
        base = re.sub(r"\[\d+\]$", "", prim)
        if base in RECODE:
            recode_gold.append(prim)
        elif prim in gate_q:
            cls["direct"].append(prim)
        else:
            hit = [n for n in ns if n in gate_q]
            if not hit and prim in EXPLICIT_RENAME and EXPLICIT_RENAME[prim] in gate_q:
                hit = [EXPLICIT_RENAME[prim]]
            if hit:
                cls["rename"].append(prim)
                renames.append((prim, hit[0]))
            else:
                cls["removed"].append(prim)
    for cn, ty, b, ns in tf:
        hit = [n for n in ns if re.sub(r"\[\d+\]$", "", n) in RECODE]
        if hit:
            recode_gate.append(hit[0])
    cand = sorted(x for x in cls["removed"] if x not in UNUSED)
    unused = sorted(x for x in cls["removed"] if x in UNUSED)
    got = dict(direct=len(cls["direct"]), rename=len(cls["rename"]),
               recode_gold=len(recode_gold), recode_gate=len(recode_gate),
               removed=len(cls["removed"]), gold=len(gf), gate=len(tf))
    # gate flops with a Q net that no gold bit explains
    gold_names = {n for _, _, _, ns in gf for n in ns} | set(EXPLICIT_RENAME.values())
    stray = sorted(ns[0] for cn, ty, b, ns in tf
                   if not any(x in gold_names or re.sub(r"\[\d+\]$", "", x) in RECODE for x in ns))
    lines = ["flop accounting (gold = RTL, gate = hardened netlist)",
             f"  gold flop bits            {got['gold']:5d}  (expect {EXPECT['gold']})",
             f"  gate flops                {got['gate']:5d}  (expect {EXPECT['gate']})",
             f"  direct name match         {got['direct']:5d}  (expect {EXPECT['direct']})",
             f"  same flop, other name     {got['rename']:5d}  (expect {EXPECT['rename']})",
             f"  recoded FSM bits, gold    {got['recode_gold']:5d}  (expect {EXPECT['recode_gold']})",
             f"  recoded FSM bits, gate    {got['recode_gate']:5d}  (expect {EXPECT['recode_gate']})",
             f"  removed by synthesis      {got['removed']:5d}  (expect {EXPECT['removed']})",
             f"    constant bits (CSR + gpio out_r[1], [3]) {len(cand):5d}  (expect 186)",
             f"    unused gpio bits        {len(unused):5d}  (expect 2)",
             f"  gate flops no gold bit explains: {len(stray)} {stray}"]
    bad = [k for k in EXPECT if got[k] != EXPECT[k]] + (["cand"] if len(cand) != 186 else []) \
        + (["unused"] if len(unused) != 2 else []) + (["stray"] if stray else [])
    lines.append("renames: " + "; ".join(f"{a} -> {b}" for a, b in renames))
    lines.append("MATCH" if not bad else "DIFFERENCE in: " + ", ".join(bad))
    open(out + "/accounting.txt", "w").write("\n".join(lines) + "\n")
    open(out + "/consts.cand", "w").write("\n".join(cand) + "\n")
    open(out + "/renames.txt", "w").write("".join(f"{a} {b}\n" for a, b in renames))
    open(out + "/unused.txt", "w").write("".join(f"{a}\n" for a in unused))
    print("\n".join(lines))
    sys.exit(1 if bad else 0)


main()
