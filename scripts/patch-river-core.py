#!/usr/bin/env python3
"""patch-river-core.py — apply the local fixes to the installed river_core.

river-core is pinned in requirements.txt (1.9.7) and installed from PyPI, so
these two defects cannot be fixed in this repository.  Run this once per
environment (control machine and sandbox) after `pip install -r
requirements.txt`.  It is idempotent.

Both defects live in river_core/utils.py and both abort a full-suite
comparison:

  1. sys_command() calls os.getpgid(process.pid) in its TimeoutExpired
     handler, after process.kill() + process.communicate() have already
     reaped the child.  The resulting ProcessLookupError escapes the
     multiprocessing.Pool worker and takes down every verdict in the run,
     not just the timed-out test.

  2. compare_dumps() builds its diagnostic string without bound.  On a
     diverging trace it starts from the whole `diff -iw` output and then
     appends one record per mismatched line.  Measured on this suite: a
     51 MB dut.dump against a 0.36 MB ref.dump yields a 290 MB string in
     136 s, and the ratio holds at 5.6-8.5x dut.dump across the range.
     rivercore_comparison() uses Pool.map, so every test's string is held
     in the parent at once -- ~48 GB for this suite on a 29 GB machine --
     and is then written to result_list.yaml and again to
     failed_list.yaml.

     The cap is verdict-preserving: `status` is only ever assigned
     'Failed' inside the walk, never back to 'Passed', so stopping once it
     is 'Failed' cannot change the result.  Only the log is shortened.

  3. compare_dumps() calls change1.remove('mem') whenever the token count
     of a commit's change field is odd.  list.remove raises ValueError if
     'mem' is not in the list, and that escapes the Pool worker and aborts
     every verdict in the run -- the same failure class as (1).  Guard it.

     Note, deliberately NOT changed: the odd-token fix-up is applied to
     file1 only, never to file2, so a store's change field normalises to
     {addr: value} on one side and {'mem': addr} on the other.  In practice
     this only reaches lines `diff -iw` already called different, where
     'Failed' is the right answer anyway, and the 2026-09-10 audit found 0
     of 289 passes with a dut/ref length mismatch.  Making it symmetric
     would change verdicts, so it is left alone and recorded here.
"""
import io
import os
import sys

MAX_LOG_BYTES = int(os.environ.get('RIVER_CORE_MAX_LOG_BYTES', 256 * 1024))
MAX_RECORDS = int(os.environ.get('RIVER_CORE_MAX_MISMATCH_RECORDS', 200))

SYS_COMMAND_OLD = """        except subprocess.TimeoutExpired:
            process.kill()
            out, err = process.communicate()
            out = out.rstrip()
            err = err.rstrip()
            pgrp = os.getpgid(process.pid)
            os.killpg(pgrp, signal.SIGTERM)
"""

SYS_COMMAND_NEW = """        except subprocess.TimeoutExpired:
            # Resolve the process group *before* reaping the child.  kill() +
            # communicate() below wait on the process, after which its pid is
            # gone and os.getpgid() raises ProcessLookupError -- which escapes
            # the multiprocessing.Pool worker and aborts every verdict in the
            # run rather than just this test.
            try:
                pgrp = os.getpgid(process.pid)
            except ProcessLookupError:
                pgrp = None
            process.kill()
            out, err = process.communicate()
            out = out.rstrip()
            err = err.rstrip()
            if pgrp is not None:
                try:
                    os.killpg(pgrp, signal.SIGTERM)
                except ProcessLookupError:
                    pass
"""

WALK_OLD = """        logger.warning(f"Possible Differences found in {file1} and {file2}")
        rout += '\\nMismatch infos:'
        mismatch_str_lst = list(filter(lambda x: x[0] in ['<', '>'], rout.split('\\n')))
        start_val = -1
        flag_found_corr_file1 = False
"""

WALK_NEW = """        logger.warning(f"Possible Differences found in {file1} and {file2}")
        mismatch_str_lst = list(filter(lambda x: x[0] in ['<', '>'], rout.split('\\n')))
        # Bound the diagnostic string.  Unbounded it reaches hundreds of MB per
        # diverging test, and rivercore_comparison() holds them all at once.
        # The head of the diff is the useful part: it carries the first
        # divergence.
        if len(rout) > _RIVER_MAX_LOG_BYTES:
            rout = (rout[:_RIVER_MAX_LOG_BYTES] +
                    f'\\n... diff truncated at {_RIVER_MAX_LOG_BYTES} bytes')
        rout += '\\nMismatch infos:'
        n_records = 0
        start_val = -1
        flag_found_corr_file1 = False
"""

BREAK_OLD = """            if not flag_found_corr_file2:
                status = 'Failed'
                rout += f'\\nBM: {file1} at PC: {file1_dat[2]} and missing in {file2}'
                logger.debug(f"-- Missing corresponding entry in {file2} for PC: {file1_dat[2]}")

        if not flag_found_corr_file1:
"""

BREAK_NEW = """            if not flag_found_corr_file2:
                status = 'Failed'
                rout += f'\\nBM: {file1} at PC: {file1_dat[2]} and missing in {file2}'
                logger.debug(f"-- Missing corresponding entry in {file2} for PC: {file1_dat[2]}")

            # Verdict-preserving early exit: nothing in this walk ever assigns
            # 'Passed', so once the status is 'Failed' the remaining records can
            # only lengthen the log.
            n_records += 1
            if status == 'Failed' and n_records >= _RIVER_MAX_MISMATCH_RECORDS:
                rout += (f'\\n... walk stopped after {n_records} mismatch '
                         f'records; verdict is already Failed')
                break

        if not flag_found_corr_file1:
"""

MEM_REMOVE_OLD = """                    change1 = file1_dat[-1].split()
                    if len(change1) % 2:
                        change1.remove('mem')
"""

MEM_REMOVE_NEW = """                    change1 = file1_dat[-1].split()
                    # list.remove raises ValueError when 'mem' is absent, and
                    # that escapes the multiprocessing.Pool worker and aborts
                    # every verdict in the run rather than just this test.
                    if len(change1) % 2 and 'mem' in change1:
                        change1.remove('mem')
"""

CONST_ANCHOR = "def compare_dumps(file1, file2, start_hex=''):\n"
CONST_BLOCK = """_RIVER_MAX_LOG_BYTES = int(os.environ.get('RIVER_CORE_MAX_LOG_BYTES', {max_log}))
_RIVER_MAX_MISMATCH_RECORDS = int(
    os.environ.get('RIVER_CORE_MAX_MISMATCH_RECORDS', {max_rec}))


"""


def main():
    try:
        import river_core
    except ImportError:
        sys.exit('river_core is not importable; activate the rivercore env first')

    path = os.path.join(os.path.dirname(river_core.__file__), 'utils.py')
    src = io.open(path, encoding='utf-8').read()
    original = src

    edits = [
        ('sys_command ProcessLookupError guard', SYS_COMMAND_OLD, SYS_COMMAND_NEW),
        ('compare_dumps log cap', WALK_OLD, WALK_NEW),
        ('compare_dumps early exit', BREAK_OLD, BREAK_NEW),
        ("compare_dumps remove('mem') ValueError guard",
         MEM_REMOVE_OLD, MEM_REMOVE_NEW),
        ('module constants',
         CONST_ANCHOR,
         CONST_BLOCK.format(max_log=MAX_LOG_BYTES, max_rec=MAX_RECORDS) + CONST_ANCHOR),
    ]

    # Each edit is checked on its own so this script stays usable when a new
    # fix is added to an install that already carries the earlier ones.
    applied, present = [], []
    for name, old, new in edits:
        if new in src:
            present.append(name)
            continue
        n = src.count(old)
        if n != 1:
            sys.exit(f'{name}: expected exactly 1 match, found {n}. '
                     f'river-core version mismatch? Expected 1.9.7.')
        src = src.replace(old, new)
        applied.append(name)

    if not applied:
        print(f'already patched: {path}')
        return

    backup = path + '.orig'
    if not os.path.exists(backup):
        io.open(backup, 'w', encoding='utf-8').write(original)
    io.open(path, 'w', encoding='utf-8').write(src)

    for name in present:
        print(f'  already present: {name}')
    for name in applied:
        print(f'  applied: {name}')
    print(f'patched: {path}  (original saved as {backup})')


if __name__ == '__main__':
    main()
