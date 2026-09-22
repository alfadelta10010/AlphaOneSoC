#!/usr/bin/env python3
"""Cross-check river_core's verdict against a stricter independent one.

river_core's compare_dumps has two known ways to report a test as passing when
the RTL was not actually verified:

  1. It runs `diff -iw` first, so an EMPTY dut.dump against an EMPTY ref.dump
     returns 0 and the test passes. A test that never executed looks identical
     to a test that matched perfectly.

  2. It pairs the per-line change tokens two at a time with zip(), so a line
     with an odd token count silently loses its last one. Spike logs an AMO as
     `mem <addr> mem <addr> <value>` -- odd -- so the STORE VALUE was never
     compared on any atomics test. A wrong AMO result compared equal.

This audits every test three ways and reports the disagreements:

  3. Both retire budgets end in `$finish` (exit status 0), so a program that
     never terminated used to produce two equally truncated traces that
     compared equal and were reported as passing. The testbench now appends a
     DUT-ABORT line to the dump, and sim.log names which bound fired; this
     script checks both.

  river_core : what compare_dumps says
  strict     : exact `diff -iw`, no token normalisation
  sanity     : dump non-empty, same length as the reference, DUT retired a
               plausible number of instructions, and the run neither spun,
               aborted, nor ran out of its instruction or cycle budget

Usage: audit-regression.py <test_list.yaml> [--csv out.csv]
"""
import os, subprocess, sys, yaml

sys.path.insert(0, os.path.expanduser(
    '~/.pyenv/versions/rivercore/lib/python3.10/site-packages'))

MIN_LINES = 5   # a real test retires more than a handful of instructions


def load(p):
    return yaml.safe_load(open(p)) or {}


def audit(test_list_path):
    from river_core import utils
    tl = load(test_list_path)
    rows = []
    for name, v in tl.items():
        wd = v.get('work_dir', '')
        gen = v.get('generator', '?')
        dut, ref = os.path.join(wd, 'dut.dump'), os.path.join(wd, 'ref.dump')
        have = os.path.isfile(dut) and os.path.isfile(ref)
        nd = sum(1 for _ in open(dut)) if os.path.isfile(dut) else 0
        nr = sum(1 for _ in open(ref)) if os.path.isfile(ref) else 0

        if not have:
            rows.append((name, gen, 'MISSING', 'MISSING', 'MISSING', nd, nr, 'dump absent'))
            continue

        # 1. river_core's own verdict
        try:
            rc_status, _, _ = utils.compare_dumps(dut, ref)
        except Exception as e:
            rc_status = 'Failed(%s)' % type(e).__name__

        # 2. strict byte comparison, whitespace/case-insensitive only
        strict = 'Passed' if subprocess.run(
            ['diff', '-iw', '-q', dut, ref], capture_output=True).returncode == 0 \
            else 'Failed'

        # 3. did the DUT actually run, and did it finish?
        notes = []
        if nd == 0:
            notes.append('EMPTY dut.dump')
        if nr == 0:
            notes.append('EMPTY ref.dump')
        if 0 < nd < MIN_LINES:
            notes.append('dut retired only %d' % nd)
        if nd and nr and nd != nr:
            notes.append('length mismatch dut=%d ref=%d' % (nd, nr))

        # The testbench writes its diagnostics to sim.log (it was vvp.log in an
        # early draft of this script and /dev/null before that, so the checks
        # below had never once fired).
        for name in ('sim.log', 'vvp.log'):
            log_path = os.path.join(wd, name)
            if not os.path.isfile(log_path):
                continue
            try:
                log = open(log_path, errors='replace').read()
            except OSError:
                continue
            if 'spinning at PC' in log:
                notes.append('SPUN (hang aborted)')
            if 'no program loaded' in log:
                notes.append('PROGRAM NOT LOADED')
            # Both bounds end in $finish, i.e. exit status 0, so nothing else
            # in the flow distinguishes "ran out of budget" from "finished".
            if 'Max instructions' in log:
                notes.append('HIT max_instr (did not terminate)')
            if 'Max cycles' in log:
                notes.append('HIT max_cycles (pipeline made no progress)')
            break

        # Belt and braces: the testbench appends this to the dump itself, so it
        # survives even when sim.log was not kept.
        try:
            with open(dut, errors='replace') as fh:
                fh.seek(max(0, os.path.getsize(dut) - 4096))
                if 'DUT-ABORT' in fh.read():
                    notes.append('DUT-ABORT marker in dump')
        except OSError:
            pass

        sanity = 'Failed' if notes else 'Passed'
        rows.append((name, gen, rc_status, strict, sanity, nd, nr, '; '.join(notes)))
    return rows


def main():
    rows = audit(sys.argv[1])
    tot = len(rows)
    rc_pass = [r for r in rows if r[2] == 'Passed']
    # The thing actually being hunted: river_core happy, stricter checks not.
    false_pass = [r for r in rows if r[2] == 'Passed' and (r[3] != 'Passed' or r[4] != 'Passed')]
    strict_only = [r for r in rows if r[2] == 'Passed' and r[3] != 'Passed']
    unverified = [r for r in rows if r[2] == 'Passed' and r[4] != 'Passed']

    print('total %d | river_core PASS %d | FAIL %d' % (tot, len(rc_pass), tot - len(rc_pass)))
    print()
    print('=== river_core PASSED but the RTL was not really verified: %d ===' % len(false_pass))
    if not false_pass:
        print('  none -- every reported pass also survives a strict diff and a sanity check')
    for name, gen, rc, st, sa, nd, nr, note in sorted(false_pass):
        print('  [%s] %-52s strict=%-6s sanity=%-6s dut=%-7d ref=%-7d %s'
              % (gen, name[:52], st, sa, nd, nr, note))
    print()
    print('  of which differ only under the strict diff (token-normalisation masking): %d'
          % len(strict_only))
    print('  of which the DUT did not meaningfully execute (empty/spun/unloaded): %d'
          % len(unverified))

    if len(sys.argv) > 3 and sys.argv[2] == '--csv':
        with open(sys.argv[3], 'w') as fh:
            fh.write('test,generator,river_core,strict,sanity,dut_lines,ref_lines,notes\n')
            for r in rows:
                fh.write('%s,%s,%s,%s,%s,%d,%d,"%s"\n' % r)
        print('\nfull table -> %s' % sys.argv[3])


if __name__ == '__main__':
    main()
