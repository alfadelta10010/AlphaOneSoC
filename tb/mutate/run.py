#!/usr/bin/env python3
"""Mutation testing for the FyraCore / AlphaOneSoC benches.

Each mutant (tb/mutate/mutants.py) is one fault applied to a throwaway copy
of src/ under build/mut/<ID>/src; src/ itself is never written. The benches
that cover the mutated file are then run against the copy, each through the
same command a developer runs (make SRC_DIR=... test-xxx, or
tests/directed/run.sh with FYRA_SRC=...), and a bench KILLS the mutant when
that command fails (a formal bench that exits 2 gave no verdict: ERROR, not a
kill, and left out of the survivors too). A mutant whose copy does not compile is STILLBORN and is
left out of every rate. A bench that has to be stopped by the timeout here
counts as a kill (a hang is a failure), and is labelled TIMEOUT.

  tb/mutate/run.py --check              every find string occurs once and
                                        every mutant compiles
  tb/mutate/run.py [-j 2] [--only CS01,CS02] [--file csr.v]
                   [--benches unit,dir,soc,dir-soc,formal] [--keep]
  tb/mutate/run.py --report             kill matrix from the results file

--tree DIR runs the benches of another verification tree -- DIR/Makefile,
DIR/tb and DIR/tests -- against the same mutants, e.g. a frozen copy of the
benches as they were before an upgrade (build/before); --results names the
results file (default build/mut/results.tsv).

Results are appended to build/mut/results.tsv (one line per mutant and
bench) and the mutant's directory is deleted once it is scored, unless
--keep. Run from the repository root.
"""
import argparse, os, re, shutil, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mutants import M  # noqa: E402

MUT = os.path.join("build", "mut")          # relative to ROOT (the Makefile wants it so)
RESULTS = os.path.join(ROOT, MUT, "results.tsv")
TREE = None     # --tree: the verification tree whose benches are run

# Unit benches (Makefile targets) that compile each source file.
UNIT = {
    "alu.v": ["test-alu"],
    "branchCtrl.v": ["test-branchctrl", "test-alu"],
    "signExt.v": ["test-signext"],
    "decoder.v": ["test-decoder"],
    "controller.v": ["test-controller"],
    "compressed_decoder.v": ["test-compressed", "test-decoder"],
    "muldiv.v": ["test-muldiv"],
    "regFile.v": ["test-regfile"],
    "csr.v": ["test-csr"],
    "pmp.v": [], "clint.v": [], "fyracore.v": [],
    "mem_ctrl.v": ["test-qspi"], "qspi_ctrl.v": ["test-qspi"],
    "soc_bus.v": [], "alphaone_soc.v": [],
    "uart.v": ["test-uart"], "gpio.v": ["test-gpio", "test-spi"], "spi.v": ["test-spi"],
    "syscon.v": ["test-syscon"],
    "tt_um_alfadelta10010_alphaone_soc.v": [],
}
# Optional unit benches added later; used when the Makefile has the target.
UNIT_EXTRA = {"pmp.v": ["test-pmp"], "clint.v": ["test-clint"]}
SOC_FILES = {"mem_ctrl.v", "qspi_ctrl.v", "soc_bus.v", "alphaone_soc.v", "uart.v",
             "gpio.v", "spi.v", "tt_um_alfadelta10010_alphaone_soc.v", "syscon.v"}

TIMEOUT = {"unit": 1800, "dir": 3600, "dir-soc": 14400, "soc": 3600, "formal": 1800}
# Formal harnesses (tb/formal/<name>_props.sv) per source file. soc_rst_sync is
# structural and has no _props.sv.
# Cover (*_cov), mem_li, md07_miter and the *_cov harnesses are left out: a cover
# harness FAILS on a mutant that merely makes a trace unreachable (not a bug
# found), and mem_li / md07_miter are opt-in (no engine closes them in the time
# box). Every pdr harness's PDR_TIMEOUT (1200 s) is below TIMEOUT["formal"].
MEM = ["mem_flash", "mem_tcem", "mem_arb", "mem_ld"]
FORMAL = {"csr.v": ["csr"],
          "fyracore.v": ["core_hold", "core_req", "core_fetch", "core_inv", "core_df"],
          "regFile.v": ["core_hold"],
          "syscon.v": ["syscon_comb", "syscon_gate"], "alphaone_soc.v": ["soc_rst_sync"],
          "spi.v": ["spi_core", "spi_dc", "spi_bb", "spi_bb1", "spi_cover"],
          "gpio.v": ["spi_bus", "spi_bb", "spi_bb1", "spi_f12", "bus"],
          "mem_ctrl.v": MEM, "qspi_ctrl.v": MEM + ["qspi_strap"],
          "soc_bus.v": ["bus"], "uart.v": ["bus"],
          "muldiv.v": ["md07"],
          "tt_um_alfadelta10010_alphaone_soc.v": ["spi_f12"]}
# No <name>_props.sv of their own: structural, or a define/PROPN variant of mem/spi_bb.
NO_PROPS = {"soc_rst_sync", "spi_f12", "spi_bb1"} | set(MEM)
FORMAL_BIN_DEFAULT = os.path.expanduser("~/tools/oss-cad-suite/bin")


SKIP_FORMAL = set()


def make_has(target):
    mk = os.path.join(TREE, "Makefile") if TREE else os.path.join(ROOT, "Makefile")
    with open(mk) as f:
        return re.search(r"^%s:" % re.escape(target), f.read(), re.M) is not None


def benches_for(f, kinds):
    out = []
    if "unit" in kinds:
        units = list(UNIT.get(f, []))
        units += [t for t in UNIT_EXTRA.get(f, []) if make_has(t)]
        out += [("unit", t) for t in units]
    if "formal" in kinds:
        out += [("formal", h) for h in FORMAL.get(f, []) if h not in SKIP_FORMAL
                if h in NO_PROPS or os.path.exists(os.path.join(ROOT, "tb/formal/%s_props.sv" % h))]
    if f in SOC_FILES:
        if "soc" in kinds:
            out += [("soc", "test-soc-periph"), ("soc", "test-wrapper")]
            if make_has("test-syscon-soc"):
                out.append(("soc", "test-syscon-soc"))
            if f in ("spi.v", "gpio.v") and make_has("test-soc-spi"):
                out.append(("soc", "test-soc-spi"))
        if "dir-soc" in kinds:
            out.append(("dir-soc", "soc"))
    else:
        if "dir" in kinds:
            out.append(("dir", "core"))
    return out


def apply(mid, f, find, rep, dst_src):
    shutil.copytree(os.path.join(ROOT, "src"), dst_src)
    p = os.path.join(dst_src, f)
    with open(p) as fh:
        text = fh.read()
    n = text.count(find)
    if n != 1:
        raise ValueError("%s: find string occurs %d times in %s" % (mid, n, f))
    with open(p, "w") as fh:
        fh.write(text.replace(find, rep))


def compiles(src):
    files = sorted(os.path.join(src, x) for x in os.listdir(src) if x.endswith(".v"))
    r = subprocess.run(["iverilog", "-g2012", "-o", os.devnull] + files,
                       cwd=ROOT, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[:3]


def run(cmd, env, timeout, log):
    t0 = time.time()
    with open(log, "w") as lf:
        try:
            r = subprocess.run(cmd, cwd=ROOT, env=env, stdout=lf, stderr=subprocess.STDOUT,
                               timeout=timeout)
            rc = r.returncode
        except subprocess.TimeoutExpired:
            rc = "TIMEOUT"
    return rc, time.time() - t0


def first_fail(log):
    pat = re.compile(r"^(FAIL|TIMEOUT|ERROR|FATAL)|  FAIL |DUT-ABORT|make: \*\*\*|^FAILED ")
    try:
        with open(log, errors="replace") as fh:
            for line in fh:
                if pat.search(line):
                    return line.strip()[:160]
    except OSError:
        pass
    return ""


def score(entry, kinds, keep):
    mid, f, find, rep, why = entry
    base = os.path.join(MUT, mid)
    absbase = os.path.join(ROOT, base)
    shutil.rmtree(absbase, ignore_errors=True)
    os.makedirs(absbase)
    rows = []
    try:
        apply(mid, f, find, rep, os.path.join(absbase, "src"))
    except ValueError as e:
        rows.append((mid, f, "-", "BROKEN", 0, str(e)))
        return rows
    ok, msg = compiles(os.path.join(absbase, "src"))
    if not ok:
        rows.append((mid, f, "-", "STILLBORN", 0, " | ".join(msg)))
    else:
        for kind, b in benches_for(f, kinds):
            env = dict(os.environ)
            nocex = False
            log = os.path.join(absbase, "%s-%s.log" % (kind, b))
            if kind == "formal":
                env["FYRA_SRC"] = os.path.join(absbase, "src")
                env["OUT_DIR"] = absbase
                if "FORMAL_BIN" not in env and os.path.isdir(FORMAL_BIN_DEFAULT):
                    env["FORMAL_BIN"] = FORMAL_BIN_DEFAULT
                rc, dt = run(["bash", "tb/formal/run.sh", b], env, TIMEOUT[kind], log)
                if rc == 1 and "did not close" in first_fail(log):
                    # Not a reachable violation: induction just failed to close.
                    # Rerun as bmc from reset (NONVAC_RUN, depth NVDEPTH, 24 by
                    # default): a counterexample is a real kill, else KILLED-NOCEX.
                    env2 = dict(env, NONVAC_RUN="1")
                    log2 = log.replace(".log", "-bmc.log")
                    rc2, dt2 = run(["bash", "tb/formal/run.sh", b], env2, TIMEOUT[kind], log2)
                    dt += dt2
                    if rc2 == 1 and "did not close" not in first_fail(log2):
                        log = log2
                    elif rc2 in (0, 1):
                        nocex = True
                    else:
                        rc = 2         # the bmc rerun gave no verdict
            elif kind in ("unit", "soc"):
                cmd = ["make", "-s", "SRC_DIR=%s/src" % base, "BUILD_DIR=%s/b" % base, b]
                if TREE:
                    cmd[1:1] = ["-f", os.path.join(TREE, "Makefile"),
                                "TB_DIR=%s/tb" % os.path.relpath(TREE, ROOT),
                                "TESTS_DIR=%s/tests" % os.path.relpath(TREE, ROOT)]
                rc, dt = run(cmd, env, TIMEOUT[kind], log)
                shutil.rmtree(os.path.join(absbase, "b"), ignore_errors=True)
            else:
                env["FYRA_SRC"] = os.path.join(absbase, "src")
                env["OUT_DIR"] = os.path.join(absbase, "dir")
                env["FAILFAST"] = "1"
                env.pop("RUN_PLUSARGS", None)
                runsh = os.path.join(TREE, "tests/directed/run.sh") if TREE else "tests/directed/run.sh"
                cmd = ["bash", runsh] + (["soc"] if kind == "dir-soc" else [])
                rc, dt = run(cmd, env, TIMEOUT[kind], log)
                if rc == 0 and kind == "dir":
                    # Survived plain: the suite is also run with the
                    # register-file X knobs, which kill a different class.
                    env["RUN_PLUSARGS"] = "+RF_X +RF_COLLIDE_X"
                    log2 = log.replace(".log", "-rfx.log")
                    rc2, dt2 = run(cmd, env, TIMEOUT[kind], log2)
                    dt += dt2
                    if rc2 != 0:
                        rc, log, b = rc2, log2, b + "+rfx"
                shutil.rmtree(os.path.join(absbase, "dir"), ignore_errors=True)
            if kind == "formal" and rc == 2:
                verdict = "ERROR"      # the checker gave no verdict: not a kill
            else:
                verdict = "TIMEOUT" if rc == "TIMEOUT" else ("SURVIVED" if rc == 0 else "KILLED")
                if verdict == "KILLED" and nocex:
                    verdict = "KILLED-NOCEX"   # induction did not close and bmc finds no counterexample
            rows.append((mid, f, "%s:%s" % (kind, b), verdict, int(dt),
                         first_fail(log) if verdict != "SURVIVED" else ""))
    if not keep:
        shutil.rmtree(absbase, ignore_errors=True)
    return rows


def report():
    best = {}
    benches = {}
    for line in open(RESULTS):
        mid, f, bench, verdict, dt, why = (line.rstrip("\n").split("\t") + [""] * 6)[:6]
        best[(mid, bench)] = verdict
        benches.setdefault(bench.split("+")[0], set()).add(mid)
    ids = sorted({k[0] for k in best})
    killed_any = {m for m in ids if any(v in ("KILLED", "TIMEOUT") for (mm, b), v in best.items() if mm == m)}
    still = {m for m in ids if any(v in ("STILLBORN", "BROKEN") for (mm, b), v in best.items() if mm == m)}
    live = [m for m in ids if m not in still]
    print("mutants scored: %d (stillborn/broken %d), killed by some bench: %d (%.0f%%)"
          % (len(live), len(still), len(killed_any & set(live)),
             100.0 * len(killed_any & set(live)) / max(1, len(live))))
    for b in sorted(benches):
        ms = [m for m in benches[b] if m not in still]
        k = [m for m in ms if any(best.get((m, bb)) in ("KILLED", "TIMEOUT")
                                  for bb in [x for (mm, x) in best if mm == m and x.split("+")[0] == b])]
        e = [m for m in ms if m not in k and any(
            best.get((m, bb)) == "ERROR" for bb in [x for (mm, x) in best if mm == m and x.split("+")[0] == b])]
        print("  %-28s %3d/%3d killed (%3.0f%%)  survivors: %s%s"
              % (b, len(k), len(ms), 100.0 * len(k) / max(1, len(ms)),
                 " ".join(sorted(set(ms) - set(k) - set(e))),
                 ("  ERROR: " + " ".join(sorted(e))) if e else ""))
    # per source file: a mutant counts once, as its strongest class
    fmap = {}
    for line in open(RESULTS):
        c = line.rstrip("\n").split("\t")
        fmap[c[0]] = c[1]
    rank = ["KILLED", "KILLED-NOCEX", "SURVIVED", "ERROR"]
    tab = {}
    for m in live:
        vs = [v for (mm, b), v in best.items() if mm == m]
        cls = "KILLED" if any(v in ("KILLED", "TIMEOUT") for v in vs) else \
              "KILLED-NOCEX" if "KILLED-NOCEX" in vs else \
              "ERROR" if "ERROR" in vs else "SURVIVED"
        tab.setdefault(fmap[m], {r: [] for r in rank})[cls].append(m)
    print("per file (counterexample kill / did-not-close only / survived / error):")
    for f in sorted(tab):
        t = tab[f]
        print("  %-38s %3d mutants  KILLED %3d  KILLED-NOCEX %3d (%s)  SURVIVED %3d (%s)  ERROR %3d (%s)"
              % (f, sum(len(v) for v in t.values()), len(t["KILLED"]), len(t["KILLED-NOCEX"]),
                 " ".join(sorted(t["KILLED-NOCEX"])), len(t["SURVIVED"]), " ".join(sorted(t["SURVIVED"])),
                 len(t["ERROR"]), " ".join(sorted(t["ERROR"]))))
    errd = {m for m in live if any(v == "ERROR" for (mm, b), v in best.items() if mm == m)}
    surv = [m for m in live if m not in killed_any and m not in errd]
    print("survived every bench: %s" % (" ".join(surv) or "none"))
    print("ERROR (a bench gave no verdict; counted neither killed nor survived): %d  %s"
          % (len(errd), " ".join(sorted(errd))))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--only")
    ap.add_argument("--file")
    ap.add_argument("--benches", default="unit,dir,soc")
    ap.add_argument("-j", type=int, default=1)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--tree")
    ap.add_argument("--skip-formal", default="", help="comma list of formal harnesses to leave out, e.g. spi_cover")
    ap.add_argument("--results")
    a = ap.parse_args()
    os.chdir(ROOT)
    global TREE, RESULTS, SKIP_FORMAL
    SKIP_FORMAL = {x for x in a.skip_formal.split(",") if x}
    if a.tree:
        TREE = os.path.abspath(a.tree)
    if a.results:
        RESULTS = os.path.abspath(a.results)
    if a.report:
        report()
        return
    sel = [e for e in M if (not a.only or e[0] in a.only.split(","))
           and (not a.file or e[1] == a.file)]
    if a.check:
        bad = 0
        for e in sel:
            d = os.path.join(ROOT, MUT, "check", e[0])
            shutil.rmtree(d, ignore_errors=True)
            try:
                apply(e[0], e[1], e[2], e[3], d)
                ok, msg = compiles(d)
                if not ok:
                    bad += 1
                    print("STILLBORN %s: %s" % (e[0], " | ".join(msg)))
            except ValueError as ex:
                bad += 1
                print("BROKEN %s" % ex)
            shutil.rmtree(d, ignore_errors=True)
        print("%d mutants, %d bad" % (len(sel), bad))
        sys.exit(1 if bad else 0)
    kinds = set(a.benches.split(","))
    os.makedirs(os.path.join(ROOT, MUT), exist_ok=True)

    def one(e):
        rows = score(e, kinds, a.keep)
        with open(RESULTS, "a") as fh:
            for r in rows:
                fh.write("\t".join(str(x) for x in r) + "\n")
        for r in rows:
            print("%-6s %-22s %-26s %-9s %5ss %s" % r, flush=True)
        return rows

    with ThreadPoolExecutor(max_workers=a.j) as ex:
        list(ex.map(one, sel))


if __name__ == "__main__":
    main()
