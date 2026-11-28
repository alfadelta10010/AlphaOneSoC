#!/usr/bin/env python3
"""One matched name per net, for EQY (WO-24).

  matchrules.py GOLD.json GATE.json OUT.rules OUT.report

EQY matches gold and gate by identical net names. A net usually has several
names, and when two of them are common to both designs EQY has two matched
nets on one net, whose buffer chains (insbuf -chain) can run in a different
order in the two designs; the cut points then no longer correspond and the
check fails on logic that is equivalent. This writes, for every (gold net,
gate net) pair that shares more than one name, a `gold-nomatch` line for all
but one name (a port name if there is one, else the smallest), so that each
net has exactly one matched name. Also written, apart from the renames that
need a rule (EXPLICIT below), a report of the pairs that are cut:

  * a gold net that shares names with two different gate nets (or the other
    way round) is listed as CONFLICT; the lower-priority names are cut

The same names are then the only public names left on those nets: for every
net that has a matched name, all its other public names are made private
(OUT.gold_hide / OUT.gate_hide, `rename -hide` scripts), so that yosys keeps
the matched name as the net's one wire and the cells read it. Without that,
a matched name can be an alias behind a buffer chain that EQY inserts
(insbuf -chain), a cut there leaves the cells reading the net upstream of
it, and a flop inside the cone is then compared against its own cut point.

The FSM registers (kept as buses for [recode]) are left alone.
"""
import collections, json, re, sys

FSM = ("soc.cpu.exwb_memSize", "soc.cpu.muldiv_inst.st", "soc.qspi.state",
       "soc.gpio_inst.spi_inst.st")
# gold net named like this is the same flop as the gate net named like that
# (the pc[0] flop; the RTL's if_pc_next[0] is a combinational copy of it).
EXPLICIT = [("soc.cpu.imem_addr[0]", "soc.cpu.if_pc_next[0]")]
EXPLICIT_CUT = ["soc.cpu.if_pc_next[0]"]
# Used only when the gate needs them (a gate flop carries the name and the gold flop's own name is
# not in the gate): the 256 B AREA 2 netlists (Fp190n2j, SYNTH_AUTONAME) name the pmpaddr flops
# after the cpu wire csr_pmpaddrN = pmpaddrN_vis (accounting.py EXPLICIT_RENAME). In gold that
# name is the mux output of pmpaddr_vis, a different net: the name is cut on the gold side and
# the gold flop is matched to the gate flop. Where gold has the name as an alias of the flop
# itself (A0-core RTL), EQY matches it by name and no rule is added. Bits [29:10] are st[29:10]; bit 0 is
# napot = pmpcfg0[8N+4].
# branchCtrl's log-depth compare tree (l0..l5, e0..e5, `(* keep *)` wires in branchCtrl.v) is
# never matched by name. The keep attribute keeps the names, but ABC still rewrites a level across
# them: the Fp190n2j gate has l1[13] = (l0[27] | l0[26]) & !gt (o21ba, nl.v:69038), gt = r1[27] &
# ~r2[27] taken from l0[27]'s own driver cone, for the RTL's l0[27] | (e0[27] & l0[26]) (equal
# only while l0/e0 agree with the operands). A cut at a tree name makes l0/e0 free inputs of the
# partition while the gate cone also reads the operand logic behind them: sat finds an assignment
# no circuit can reach (e0[27] = 0 with equal operand bits) and FAILs on equivalent logic (13
# bcmp partitions and alu_r.0, whose slt/sltu bit reads lt_unsigned). Unmatched, the tree is
# compared whole, from the operand cuts to lt_signed / lt_unsigned / eq / diff. Gold names only;
# a netlist of RTL without the tree (A0-core) has none, and its rules are unchanged.
NOMATCH_TREE = re.compile(r"^soc\.cpu\.bcmp\.[le][0-5]$")
COND_EXPLICIT = [(f"soc.cpu.csr_unit.pmpaddr{n}[{k}]", f"soc.cpu.csr_pmpaddr{n}[{k}]")
                 for n in range(4) for k in range(10, 30)] + \
                [(f"soc.cpu.csr_pmpcfg0[{8 * n + 4}]", f"soc.cpu.csr_pmpaddr{n}[0]") for n in range(4)]


def load(path):
    m = json.load(open(path))["modules"]["tt_um_alfadelta10010_alphaone_soc"]
    ports = set(m["ports"])
    names = collections.defaultdict(set)         # bit id -> names
    tree = set()                                 # NOMATCH_TREE names, one per bit
    for n, d in m["netnames"].items():
        if n.startswith("$") or re.match(r"^[A-Za-z_0-9$]+\.[A-Z][A-Z0-9_]*$", n):
            continue
        base = re.sub(r"\[\d+\]$", "", n)
        if base in FSM or n in FSM:
            continue
        if NOMATCH_TREE.match(base):
            tree.update(n if len(d["bits"]) == 1 else f"{n}[{i + d.get('offset', 0)}]" for i in range(len(d["bits"])))
            continue
        for i, b in enumerate(d["bits"]):
            if isinstance(b, int):
                names[b].add(n if len(d["bits"]) == 1 else f"{n}[{i + d.get('offset', 0)}]")
    isport = lambda n: re.sub(r"\[\d+\]$", "", n) in ports or n in ports
    return names, isport, tree


def esc_sel(n):
    """a yosys select pattern for exactly this wire name"""
    return re.sub(r"([\[\]\\*?])", r"\\\1", n)


def esc(n):
    return re.sub(r"([\[\]\\*?])", r"\\\1", n)


def main():
    gnames, gport, gtree = load(sys.argv[1])
    tnames, tport, _ = load(sys.argv[2])
    gname_bit = {n: b for b, ns in gnames.items() for n in ns}
    tname_bit = {n: b for b, ns in tnames.items() for n in ns}
    active = [(g, t) for g, t in COND_EXPLICIT if g in gname_bit and t in tname_bit and g not in tname_bit
              and gname_bit.get(t) != gname_bit[g]]   # in gold the name is another net, not an alias of the flop
    explicit = EXPLICIT + active
    explicit_cut = EXPLICIT_CUT + [t for _, t in active]
    gate_by_name = collections.defaultdict(set)
    for b, ns in tnames.items():
        for n in ns:
            gate_by_name[n].add(b)
    pair = collections.defaultdict(set)          # (gold bit, gate bit) -> common names
    for b, ns in gnames.items():
        for n in ns:
            for t in gate_by_name.get(n, ()):
                pair[(b, t)].add(n)
    # a gold bit (or gate bit) in more than one pair: conflict
    per_g = collections.defaultdict(list)
    per_t = collections.defaultdict(list)
    for (g, t), ns in pair.items():
        per_g[g].append((g, t)); per_t[t].append((g, t))
    cut, report = [], []
    prio = lambda n: (0 if gport(n) else 1, n)
    for key, ns in sorted(pair.items(), key=lambda kv: sorted(kv[1])[0]):
        g, t = key
        confl = len(per_g[g]) > 1 or len(per_t[t]) > 1
        ordered = sorted(ns, key=prio)
        if confl:
            report.append(f"CONFLICT gold bit {g} / gate bit {t}: {ordered}")
        for n in ordered[1:]:
            cut.append(n)
    # a bit in two pairs keeps only the pair with the best name
    for g, ps in per_g.items():
        if len(ps) > 1:
            best = min(ps, key=lambda p: prio(sorted(pair[p], key=prio)[0]))
            for p in ps:
                if p != best:
                    cut.extend(pair[p])
    for t, ps in per_t.items():
        if len(ps) > 1:
            best = min(ps, key=lambda p: prio(sorted(pair[p], key=prio)[0]))
            for p in ps:
                if p != best:
                    cut.extend(pair[p])
    cut = sorted(set(cut) | set(explicit_cut))
    # representative names: the common names that stay matched
    reps_g = collections.defaultdict(set)         # gold bit -> matched names
    reps_t = collections.defaultdict(set)
    cutset = set(cut)
    for (g, t), ns in pair.items():
        for n in ns:
            if n not in cutset:
                reps_g[g].add(n); reps_t[t].add(n)
    for gn, tn in explicit:
        reps_g[gname_bit[gn]].add(gn); reps_t[tname_bit[tn]].add(tn)
    hide_g = sorted(n for b, ns in gnames.items() if b in reps_g for n in ns if n not in reps_g[b] and not gport(n))
    hide_t = sorted(n for b, ns in tnames.items() if b in reps_t for n in ns if n not in reps_t[b] and not tport(n))
    for path, hide in ((sys.argv[3] + ".gold_hide", hide_g), (sys.argv[3] + ".gate_hide", hide_t)):
        with open(path, "w") as f:
            for n in hide:
                f.write(f"rename -hide w:{esc_sel(n)}\n")
    with open(sys.argv[3], "w") as f:
        for n in cut:
            f.write(f"gold-nomatch {esc(n)}\n")
        for n in sorted(gtree):
            f.write(f"gold-nomatch {esc(n)}\n")
        for g, t in explicit:
            f.write(f"gold-match {esc(g)} {esc(t)}\n")
    with open(sys.argv[4], "w") as f:
        f.write(f"net pairs sharing a name: {len(pair)}; names cut ({len(cut)}) so that one name per net is matched\n")
        f.write("\n".join(report) + "\n")
    print(f"{len(pair)} pairs, {len(cut)} names cut, {len(report)} conflicts, {len(active)} conditional explicit pairs, {len(gtree)} compare-tree names unmatched, "
          f"{len(hide_g)} gold and {len(hide_t)} gate names made private")


main()
