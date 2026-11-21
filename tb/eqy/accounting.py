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
  removed  no gate flop: the constant bits (CSR, gpio, PLIC), the unused gpio bits
  memaddr  the read-address register that yosys's memory_dff + memory_map build for a
           read port of a memory array (MEMRD below): a copy of the address flop, in gold
           named $\<mem>$rdreg[<port>]$q, in the netlist an anonymous flop (_NNNNN_ / netNNNN)

and writes OUT_DIR/accounting.txt, consts.cand (the removed bits that are
not the unused gpio bits, one `name[idx]` per line) and OUT_DIR/renames.txt.
Exit status 1 if a count differs from the table of the work order.
"""
import collections, json, re, sys

# 4x4 (hd netlist 757ba9e9, RTL 1f2a473): 1925 direct = 1861 named flops + the 64 bits of
# uart rx_mem (gold memory_map words rx_mem[k][b] = the netlist's rx_mem[k][b]); cand = 184 CSR
# + gpio out_r[1], [3] + PLIC pend/insvc of the tied-0 sources 4, 7, 8; unused = 0 (the pinmux
# reads gpio out_r[7:4] now); memaddr = rx_mem's read-address register, 3 bits on each side.
EXPECT = dict(direct=1925, rename=11, recode_gold=11, recode_gate=22, removed=192,
              gold=2142, gate=1961, cand=192, unused=0, memaddr_gold=3, memaddr_gate=3)
RECODE = {"soc.cpu.exwb_memSize": (2, 3), "soc.cpu.muldiv_inst.st": (3, 6),
          "soc.qspi.state": (4, 10), "soc.gpio_inst.spi_inst.st": (2, 3)}
INTERNAL = re.compile(r"^[A-Za-z_0-9$]+\.[A-Z][A-Z0-9_]*$")
# gold bit -> gate Q net, for a rename that no alias of the gold bit shows. In
# the RTL if_pc_next[0] = (pc + 2 or 4)[0] = pc[0], a combinational copy of the
# pc[0] flop; synthesis folded the two nets and kept the name if_pc_next[0].
EXPLICIT_RENAME = {"soc.cpu.imem_addr[0]": "soc.cpu.if_pc_next[0]"}
# gold flop bits with no fan-out that synthesis removed (3x4: gpio out_r[4], [5]; in 4x4 the pinmux
# reads them, so they are direct matches and the set is empty)
UNUSED = set()
# memory -> (address flop, address width): the read port's address register that memory_dff
# merges into the port and memory_map rebuilds as a plain flop, a copy of the address flop
# (rx_rp: same D, so the same value from any equal start). gold: Q net $\<mem>$rdreg[0]$q;
# netlist: anonymous. tb/eqy/run.sh's gold read maps memories the way the harden's synth does
# (memory -nomap; memory_map), so both sides hold the copy and EQY compares the read mux.
MEMRD = {"soc.uart_inst.rx_mem": ("soc.uart_inst.rx_rp", 3)}
MEMRD_GOLD = re.compile(r"^\$\\?(%s)\$rdreg\[\d+\]\$q(\[\d+\])?$" % "|".join(re.escape(m) for m in MEMRD))
ANON = re.compile(r"^(_\d+_|net\d+)$")


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
    memaddr_gold, memaddr_gate = [], []
    renames = []
    recode_gold, recode_gate = [], []
    for cn, ty, b, ns in gf:
        prim = ns[0]
        base = re.sub(r"\[\d+\]$", "", prim)
        if base in RECODE:
            recode_gold.append(prim)
        elif all(MEMRD_GOLD.match(n) for n in ns):
            memaddr_gold.append(prim)
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
               removed=len(cls["removed"]), gold=len(gf), gate=len(tf), cand=len(cand),
               unused=len(unused), memaddr_gold=len(memaddr_gold))
    # gate flops with a Q net that no gold bit explains; the anonymous ones are the memory read
    # address registers (their count must equal gold's), every other one is a stray
    gold_names = {n for _, _, _, ns in gf for n in ns} | set(EXPLICIT_RENAME.values())
    stray = []
    for cn, ty, b, ns in tf:
        if any(x in gold_names or re.sub(r"\[\d+\]$", "", x) in RECODE for x in ns):
            continue
        (memaddr_gate if all(ANON.match(x) for x in ns) else stray).append(ns[0])
    stray.sort()
    got["memaddr_gate"] = len(memaddr_gate)
    lines = ["flop accounting (gold = RTL, gate = hardened netlist)",
             f"  gold flop bits            {got['gold']:5d}  (expect {EXPECT['gold']})",
             f"  gate flops                {got['gate']:5d}  (expect {EXPECT['gate']})",
             f"  direct name match         {got['direct']:5d}  (expect {EXPECT['direct']})",
             f"  same flop, other name     {got['rename']:5d}  (expect {EXPECT['rename']})",
             f"  recoded FSM bits, gold    {got['recode_gold']:5d}  (expect {EXPECT['recode_gold']})",
             f"  recoded FSM bits, gate    {got['recode_gate']:5d}  (expect {EXPECT['recode_gate']})",
             f"  removed by synthesis      {got['removed']:5d}  (expect {EXPECT['removed']})",
             f"    constant bits (CSR + gpio out_r[1], [3] + PLIC pend/insvc 4, 7, 8) {len(cand):5d}  (expect {EXPECT['cand']})",
             f"    unused gpio bits        {len(unused):5d}  (expect {EXPECT['unused']})",
             f"  memory read-address register, gold {got['memaddr_gold']:5d}  (expect {EXPECT['memaddr_gold']}): {sorted(memaddr_gold)}",
             f"  memory read-address register, gate {got['memaddr_gate']:5d}  (expect {EXPECT['memaddr_gate']}): {sorted(memaddr_gate)}",
             f"  gate flops no gold bit explains: {len(stray)} {stray}"]
    bad = [k for k in EXPECT if got[k] != EXPECT[k]] + (["stray"] if stray else [])
    lines.append("renames: " + "; ".join(f"{a} -> {b}" for a, b in renames))
    lines.append("MATCH" if not bad else "DIFFERENCE in: " + ", ".join(bad))
    open(out + "/accounting.txt", "w").write("\n".join(lines) + "\n")
    open(out + "/consts.cand", "w").write("\n".join(cand) + "\n")
    open(out + "/renames.txt", "w").write("".join(f"{a} {b}\n" for a, b in renames))
    open(out + "/unused.txt", "w").write("".join(f"{a}\n" for a in unused))
    print("\n".join(lines))
    sys.exit(1 if bad else 0)


main()
