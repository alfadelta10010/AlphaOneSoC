# See LICENSE for details

import os
import yaml
import pytest

from river_core.log import logger
import river_core.utils as utils


def _load_testlist(testlist_path, riscv_dv_dir):
    """Expand a riscv-dv testlist, following its <riscv_dv_root> import."""
    entries = []
    with open(testlist_path) as fp:
        raw = yaml.safe_load(fp) or []
    for entry in raw:
        if 'import' in entry:
            imported = entry['import'].replace('<riscv_dv_root>', riscv_dv_dir)
            if os.path.isfile(imported):
                with open(imported) as fp:
                    entries.extend(yaml.safe_load(fp) or [])
            else:
                logger.warning(f'riscv-dv testlist import not found: {imported}')
        else:
            entries.append(entry)

    # Later entries win, so a target testlist can override the iteration count
    # of a test it imported from base_testlist.yaml.
    merged = {}
    for e in entries:
        if 'test' in e:
            merged[e['test']] = e
    return [e for e in merged.values() if int(e.get('iterations', 0)) > 0]


# Wall-clock budget for generating a single program, in seconds.
#
# pyflow's own default is 1200s, which is not enough here. A
# riscv_mmu_stress_test program takes about 4.5 minutes to generate on an idle
# machine, and the plugin runs `jobs` of them at once, so each is slowed by
# roughly the contention factor. Observed: 2 of 13 streams failed a full run
# purely on timeouts, with no error of any kind in their logs.
GEN_TIMEOUT_PER_PROGRAM = 1800


def gen_cmd_list(riscv_dv_dir, target, isa, mabi, output_dir, testlist, seed):
    """One `run.py --steps gen` invocation per test, so pytest can fan out.

    Returns (command, timeout) pairs. --batch_size 1 makes run.py generate the
    iterations sequentially, so the budget for the whole invocation scales with
    the iteration count.
    """
    run_commands = []
    tests = _load_testlist(testlist, riscv_dv_dir)
    logger.info(f'riscv-dv: {len(tests)} tests with non-zero iterations')

    # --start_seed, not --seed. run.py rejects --seed outright whenever
    # --iterations is greater than 1 ("--seed is incompatible with setting
    # --iterations"), and SeedGen.get() asserts test_iter == 0 for a fixed
    # seed, so the configured seed could never have reached a multi-iteration
    # test. --start_seed is the reproducible form riscv-dv intends for a run of
    # several programs: iteration i is generated with start_seed + i, so the
    # whole set is repeatable and the programs still differ from each other.
    seed_arg = f' --start_seed={seed}' if seed else ''

    for entry in tests:
        name = entry['test']
        iterations = int(entry['iterations'])
        out = os.path.join(output_dir, name)
        os.makedirs(out, exist_ok=True)

        # --custom_target bypasses run.py's hardcoded target allowlist, which
        # has no rv32imac. Doing so makes --isa and --mabi mandatory.
        # No shell compound here: river_core's sys_command uses shlex.split
        # without a shell, so `cd x && y` would try to exec "cd". run.py
        # resolves its own directory, and pygen_src is made importable via
        # PYTHONPATH (set in the plugin's pre_gen) rather than by cwd.
        # --batch_size 1 makes run.py generate one program per invocation.
        # Without it, riscv_instr_base_test.run() opens a
        # multiprocessing.Pool(processes=cfg.num_of_tests), so a test with 8
        # iterations forks 8 generator processes at once -- on top of the
        # pytest-xdist workers already running one such test each. With jobs=8
        # that is up to 64 concurrent processes on this 8-core machine, each
        # peaking around 3GB: the box swaps, every process slows by roughly the
        # oversubscription factor, and a full 56-program run was still less
        # than a third done after 70 minutes. Batching hands parallelism back
        # to pytest, which is the single place it is configured, and also makes
        # the 1200s pyflow generation timeout apply per program rather than to
        # a whole test's iterations at once.
        cmd = (
            f'python {os.path.join(riscv_dv_dir, "run.py")}'
            f' --simulator pyflow'
            f' --target {target}'
            f' --custom_target {riscv_dv_dir}/target/{target}'
            f' --isa {isa} --mabi {mabi}'
            f' --test {name}'
            f' --iterations {iterations}'
            f' --batch_size 1'
            f' --gen_timeout {GEN_TIMEOUT_PER_PROGRAM}'
            f' --output {out}'
            f' --steps gen'
            f'{seed_arg}'
        )
        # The outer budget has to cover every batch of this test, plus a little
        # for run.py's own start-up. river_core's sys_command previously capped
        # this at a flat 3000s, which a stream with eight iterations exceeded
        # on its own.
        run_commands.append(
            (cmd, iterations * GEN_TIMEOUT_PER_PROGRAM + 300))

    return run_commands


def idfnc(val):
    cmd = val[0]
    name = cmd.split('--test ')[1].split()[0] if '--test ' in cmd else cmd
    return f'Generating {name}'


def pytest_generate_tests(metafunc):
    if 'test_input' in metafunc.fixturenames:
        test_list = gen_cmd_list(metafunc.config.getoption("riscv_dv_dir"),
                                 metafunc.config.getoption("target"),
                                 metafunc.config.getoption("isa"),
                                 metafunc.config.getoption("mabi"),
                                 metafunc.config.getoption("output_dir"),
                                 metafunc.config.getoption("testlist"),
                                 metafunc.config.getoption("seed"))
        metafunc.parametrize('test_input', test_list, ids=idfnc, indirect=True)


@pytest.fixture
def test_input(request, autouse=True):
    (program, timeout) = request.param
    (ret, out, err) = utils.sys_command(program, timeout=timeout)
    return ret


def test_eval(test_input):
    assert test_input == 0
