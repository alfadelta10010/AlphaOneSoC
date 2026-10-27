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


def verdict(eqydir, out, only=None, classes=None):
    classes = classes or {}
    res = statuses(eqydir, only)
    parts = sorted(only) if only is not None else sorted(
        os.path.basename(p)[:-5] for p in glob.glob(f"{eqydir}/partitions/*.json"))
    if not parts:
        open(out, "w").write("EQY ERROR no partitions (eqy did not get past setup)\n")
        return 2
    fail, unproven, opened, ok, by = [], [], [], 0, {"sat": 0, "pdr": 0}
    lines = []
    for p in parts:
        sts = res.get(p, [])
        # a partition is proved if any strategy proved it (sat first, then pdr); a FAIL is
        # a FAIL; otherwise it is open and the reason is the pdr result (TIMEOUT / UNKNOWN)
        passed = [x for x in sts if x[1] == "PASS" and not x[2]]   # the strategy that really proved it
        if passed:
            last = "PASS"
            by[passed[0][0]] = by.get(passed[0][0], 0) + 1
        elif any(x[1] == "FAIL" for x in sts):
            last = "FAIL"
        else:
            d = {x[0]: x[1] for x in sts}
            last = d.get("pdr", d.get("sat", "NOT RUN"))
        if last == "PASS":
            ok += 1
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
    lines.append("assumption: partitions without FSM bits are checked from any state. Partitions holding "
                 "the FSM bits (soc.cpu.exwb_memSize, soc.cpu.muldiv_inst.st, soc.qspi.state) are checked "
                 "from the FSM reset state (gold 0, gate one-hot of state 0), with every other state "
                 "matched, cut and free each cycle, rst/rst_soc included. The chip reaches that state at "
                 "its first reset edge, since the wrapper holds rst for at least two edges, the same "
                 "premise as the 184-bit lemma. No other assumption or init. nomatched nets are cut "
                 "nowhere; `rd_late` starts free on both sides.")
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


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--partitions-of":
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
