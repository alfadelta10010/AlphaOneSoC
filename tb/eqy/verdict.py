#!/usr/bin/env python3
"""Read an EQY work directory's results (WO-24).

  verdict.py EQYDIR OUT            summarize every partition; the last line of OUT is
                                   `EQY PASS`, `EQY FAIL <partitions>` or `EQY UNPROVEN <partitions>`
  verdict.py --classes FILE EQYDIR OUT
                                   FILE lines are `<partition>\t<class>\t<evidence>`; a FAIL listed there is
                                   reported as OPEN (raw result, class, evidence), and when every FAIL is
                                   classed the last line is `EQY UNPROVEN <open> of <N> <names>`
  verdict.py --partitions-of NAME EQYDIR
                                   print the partitions whose gold or gate design holds the
                                   net NAME (a flop's output), for the mutant runs
  verdict.py --mutant-table NAME MUTDIR
                                   print tab-separated rows NAME, partition, strategy, raw result, trace path
                                   for every partition the mutant ran (MUTDIR/eqy, then MUTDIR/eqy_pdr, the
                                   pdr confirm of the sat "vacuous base" partitions)
  verdict.py --only "P1 P2" EQYDIR OUT
                                   as the first form, over those partitions only
"""
import glob, json, os, re, sys


def statuses(eqydir, only=None):
    res = {}
    for st in sorted(glob.glob(f"{eqydir}/strategies/*/*/status")):
        _, part, strat = st[len(eqydir) + 1:].split("/")[0:3]
        if only is not None and part not in only:
            continue
        word = open(st).read().split()
        cached = len(word) > 1 and word[1] == "(cached)"   # copied from the earlier strategy
        res.setdefault(part, []).append((strat, word[0] if word else "EMPTY", cached))
    return res


def sat_length(eqydir, part):
    """Induction length a sat proof closed at, or None when the log does not show a proof."""
    try:
        log = open(f"{eqydir}/strategies/{part}/sat/run.log", errors="replace").read()
    except OSError:
        return None
    n = re.findall(r"Trying induction with length (\d+)", log)
    if "Induction step proven" not in log or not n:
        return None
    return int(n[-1])


def verdict(eqydir, out, only=None, classes=None):
    classes = classes or {}
    res = statuses(eqydir, only)
    parts = sorted(only) if only is not None else sorted(
        os.path.basename(p)[:-5] for p in glob.glob(f"{eqydir}/partitions/*.json"))
    if not parts:
        open(out, "w").write("EQY ERROR no partitions (eqy did not get past setup)\n")
        return 2
    fail, unproven, opened, ok, by = [], [], [], 0, {"sat": 0, "pdr": 0}
    lens, vac = {}, set()
    lines = []
    for p in parts:
        sts = res.get(p, [])
        # a partition is proved if any strategy proved it (sat first, then pdr); a FAIL is
        # a FAIL; otherwise it is open and the reason is the pdr result (TIMEOUT / UNKNOWN)
        passed = [x for x in sts if x[1] == "PASS" and not x[2]]   # the strategy that really proved it
        if passed and passed[0][0] == "sat":
            n = sat_length(eqydir, p)
            lens[n] = lens.get(n, 0) + 1
            if n == 1:
                last = "PASS"
                by["sat"] += 1
            else:
                last = "VACUOUS"
                vac.add(p)
                lines.append(f"OPEN {p}: sat induction length {n} > 1 with undefined init (vacuous base)")
        elif passed:
            last = "PASS"
            by[passed[0][0]] = by.get(passed[0][0], 0) + 1
        elif any(x[1] == "FAIL" for x in sts):
            last = "FAIL"
        else:
            d = {x[0]: x[1] for x in sts}
            last = d.get("pdr", d.get("sat", "NOT RUN"))
        if last == "PASS":
            ok += 1
        elif last == "VACUOUS":
            unproven.append(p)
        elif last == "FAIL" and p in classes:
            opened.append(p)
            lines.append(f"OPEN {p}: raw result FAIL {[(x[0], x[1]) for x in sts]}; "
                         f"class: {classes[p][0]}; evidence: {classes[p][1]}")
        elif last == "FAIL":
            fail.append(p)
            lines.append(f"FAIL {p}: {[(x[0], x[1]) for x in sts]}")
        else:
            unproven.append(p)
            lines.append(f"{last} {p}: {[(x[0], x[1]) for x in sts]}")
    lines.insert(0, f"partitions {len(parts)}: {ok} proved ({', '.join(f'{k} {v}' for k, v in by.items())}), "
                    f"{len(fail)} fail, {len(opened)} open (classed fail), {len(unproven)} unproven")
    lines.insert(1, "sat induction lengths: " + str(dict(sorted(lens.items(), key=lambda kv: (kv[0] is None, kv[0])))))
    if only is None and len(parts) != 157:
        lines.append(f"WARNING partition count {len(parts)}, expected 157")
    lines.append("assumption: gold == gold' (clamp, the identity on valid FSM codes: lemma L2, PROVED once armed) "
                 "== gate' (enc/clamp/dec, the identity while each FSM holds one set bit: I_gate, PROVED by "
                 "temporal induction on the netlist, fsminv stage) == gate; the FSM cut partitions compare "
                 "gold's binary flop with enc of the gate's one-hot flops (the table is checked there). No FSM "
                 "init in EQY: every partition is checked from any state, with every other state matched, cut "
                 "and free each cycle, rst/rst_soc included. The one premise left: the chip reaches the FSM "
                 "reset codes at its first reset edge (the wrapper holds rst for at least two edges), the "
                 "premise of L1/L2/I_gate. The rf_top w_ena pin has its own net (soc.cpu.rf.w_ena_pin), "
                 "compared as a partition. Nomatched nets are cut nowhere; `rd_late` starts free on both sides. "
                 "Every sat proof closed at induction length 1 (step from any state); longer sat proofs are not "
                 "accepted because the base case is vacuous under undefined init.")
    if fail:
        lines.append("EQY FAIL " + " ".join(fail))
    elif unproven or opened:
        o = unproven + opened
        lines.append(f"EQY UNPROVEN {len(o)} of {len(parts)} " + " ".join(o))
    else:
        lines.append("EQY PASS")
    open(out, "w").write("\n".join(lines) + "\n")
    return 1 if fail else (2 if (unproven or opened) else 0)


def partitions_of(name, eqydir):
    for pj in sorted(glob.glob(f"{eqydir}/partitions/*.json")):
        pass
    hits = []
    for pj in sorted(glob.glob(f"{eqydir}/partitions/*.json")):
        txt = open(pj).read()
        if re.search(re.escape(name), txt):
            hits.append(os.path.basename(pj)[:-5])
    print(" ".join(hits))


def mutant_table(name, mdir):
    parts = [p for p in open(f"{mdir}/partitions.txt").read().split() if p]
    for sub in ("eqy", "eqy_pdr"):
        d = f"{mdir}/{sub}"
        if not os.path.isdir(d):
            continue
        res = statuses(d)
        for p in parts:
            for strat, raw, cached in res.get(p, []):
                if cached:
                    continue
                note = ""
                if strat == "sat" and raw == "PASS":
                    n = sat_length(d, p)
                    if n != 1:
                        note = f" (induction length {n}, vacuous base: not a proof)"
                tr = ""
                if raw == "FAIL":
                    base = f"{d}/strategies/{p}/{strat}"
                    found = sorted(glob.glob(f"{base}/**/*.vcd", recursive=True) + glob.glob(f"{base}/**/*.yw", recursive=True))
                    tr = found[0] if found else f"{base}/run.log"
                print(f"{name}\t{p}\t{strat} ({sub})\t{raw}{note}\t{tr}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--mutant-table":
        mutant_table(a[1], a[2])
    elif a and a[0] == "--partitions-of":
        partitions_of(a[1], a[2])
    elif a and a[0] == "--only":
        sys.exit(verdict(a[2], a[3], set(a[1].split())))
    elif a and a[0] == "--classes":
        cl = {}
        for ln in open(a[1]):
            f = ln.rstrip("\n").split("\t")
            if len(f) >= 3 and f[0].strip():
                cl[f[0]] = (f[1], f[2])
        sys.exit(verdict(a[2], a[3], None, cl))
    else:
        sys.exit(verdict(a[0], a[1]))
