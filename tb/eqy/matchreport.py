#!/usr/bin/env python3
"""Match report of an EQY work directory against the flop accounting (WO-24).

  matchreport.py GOLD.json GATE.json EQYDIR CONSTS.txt OUT

GOLD.json and GATE.json are the pre-tie gold and the gate of the read stage
(single-bit nets), EQYDIR the eqy work directory after setup (matched.ids),
CONSTS.txt the tied bits. Every gold flop bit is classified as accounting.py
does (by its names against the gate flops' names) and then looked up in
EQY's matches:

  direct    a gold name of the bit is the gate flop's name, the bit's own
  rename    the same flop under another name (an alias, or the explicit rule)
  recode    a bit of an FSM register (nomatch on both sides, init = reset state)
  tied      one of the constant bits of CONSTS.txt (no gate flop, none expected)
  unused    out_r[4], out_r[5] of the gpio block (no fan-out, none expected)
  UNMATCHED a direct or rename flop that EQY did not match: reported, never patched

Exit status 1 if the counts differ from the work order's table.
"""
import collections, json, re, sys

EXPECT = dict(direct=1323, rename=7, recode=10, tied=186, unused=2, UNMATCHED=0)
RECODE = {"soc.cpu.exwb_memSize", "soc.cpu.muldiv_inst.st", "soc.qspi.state",
          "soc.gpio_inst.spi_inst.st"}
UNUSED = {"soc.gpio_inst.out_r[4]", "soc.gpio_inst.out_r[5]"}

INTERNAL = re.compile(r"^[A-Za-z_0-9$]+\.[A-Z][A-Z0-9_]*$")
EXPLICIT_RENAME = {"soc.cpu.imem_addr[0]": "soc.cpu.if_pc_next[0]"}


def netnames(m):
    out = collections.defaultdict(list)
    for n, d in m["netnames"].items():
        for i, b in enumerate(d["bits"]):
            if isinstance(b, int):
                nm = n if len(d["bits"]) == 1 else f"{n}[{i + d.get('offset', 0)}]"
                if not INTERNAL.match(nm):
                    out[b].append((d.get("hide_name", 0), nm))
    return out


g = json.load(open(sys.argv[1]))["modules"]["tt_um_alfadelta10010_alphaone_soc"]
t = json.load(open(sys.argv[2]))["modules"]["tt_um_alfadelta10010_alphaone_soc"]
names = netnames(g)
tnames = netnames(t)
gate_q = set()
for cn, c in t["cells"].items():
    if "dff" in c["type"].lower():
        for b in c["connections"]["Q"]:
            gate_q.update(n for _, n in tnames.get(b, []))
gate_q.update(EXPLICIT_RENAME.values())
matched = {}
for l in open(sys.argv[3] + "/matched.ids"):
    if l.startswith("#") or not l.strip():
        continue
    f = l.split()
    if len(f) == 3:
        matched.setdefault(f[1], f[2])          # gold name -> gate name
tied = {l.split()[0] for l in open(sys.argv[4]) if l.strip()}
cls = collections.defaultdict(list)
for cn, c in g["cells"].items():
    if "dff" not in c["type"]:
        continue
    for b in c["connections"]["Q"]:
        ns = [n for _, n in sorted(names[b])]
        prim = ns[0]
        base = re.sub(r"\[\d+\]$", "", prim)
        if base in RECODE:
            cls["recode"].append(prim)     # not matched by design: init + nomatch
        elif prim in tied or any(n in tied for n in ns):
            cls["tied"].append(prim)
        elif prim in UNUSED:
            cls["unused"].append(prim)
        else:
            kind = "direct" if prim in gate_q else ("rename" if any(n in gate_q for n in ns)
                                                      or prim in EXPLICIT_RENAME else None)
            if kind is None:
                cls["UNMATCHED"].append(prim)         # no gate flop and not a known removal
            elif any(n in matched for n in ns) or prim in EXPLICIT_RENAME and prim in matched:
                cls[kind].append(prim)
            else:
                cls["UNMATCHED"].append(prim)
lines = ["match report (EQY matched.ids against the gold flop bits)"]
bad = []
for k in EXPECT:
    got = len(cls[k])
    lines.append(f"  {k:10s} {got:5d}  (expect {EXPECT[k]})")
    if got != EXPECT[k]:
        bad.append(k)
if cls["UNMATCHED"]:
    lines.append("  unmatched flop bits: " + ", ".join(sorted(cls["UNMATCHED"])[:40]))
if cls["rename"]:
    lines.append("  renames: " + ", ".join(sorted(cls["rename"])))
lines.append("MATCH" if not bad else "DIFFERENCE in: " + ", ".join(bad))
open(sys.argv[5], "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(1 if bad else 0)
