#!/usr/bin/env python3
"""Read an EQY work directory's results (WO-24).

  verdict.py EQYDIR OUT            summarize every partition; the last line of OUT is
                                   `EQY PASS`, `EQY FAIL <partitions>` or `EQY UNPROVEN <partitions>`
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
        res.setdefault(part, []).append((strat, word[0] if word else "EMPTY"))
    return res


def verdict(eqydir, out, only=None):
    res = statuses(eqydir, only)
    parts = sorted(only) if only is not None else sorted(
        os.path.basename(p)[:-5] for p in glob.glob(f"{eqydir}/partitions/*.json"))
    if not parts:
        open(out, "w").write("EQY ERROR no partitions (eqy did not get past setup)\n")
        return 2
    fail, unproven, ok, by = [], [], 0, {"sat": 0, "pdr": 0}
    lines = []
    for p in parts:
        sts = res.get(p, [])
        last = sts[-1][1] if sts else "NOT RUN"
        if last == "PASS":
            ok += 1
            by[sts[-1][0]] = by.get(sts[-1][0], 0) + 1
        elif last == "FAIL":
            fail.append(p)
            lines.append(f"FAIL {p}: {sts}")
        else:
            unproven.append(p)
            lines.append(f"{last} {p}: {sts}")
    lines.insert(0, f"partitions {len(parts)}: {ok} proved ({', '.join(f'{k} {v}' for k, v in by.items())}), "
                    f"{len(fail)} fail, {len(unproven)} unproven")
    if fail:
        lines.append("EQY FAIL " + " ".join(fail))
    elif unproven:
        lines.append("EQY UNPROVEN " + " ".join(unproven))
    else:
        lines.append("EQY PASS")
    open(out, "w").write("\n".join(lines) + "\n")
    return 1 if fail else (2 if unproven else 0)


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
    else:
        sys.exit(verdict(a[0], a[1]))
