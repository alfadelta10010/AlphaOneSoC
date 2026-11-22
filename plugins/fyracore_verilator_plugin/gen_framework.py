# Pytest framework for running FyraCore tests via river_core.
# Parametrizes tests from Makefile targets and runs them in parallel.

import re
import pytest

from river_core.log import logger
from river_core.utils import sys_command


def compile_cmd_list(make_file, work_dir, key_list):
    """Build list of make commands from the key_list string."""
    run_commands = []

    # key_list arrives as a string repr of a Python list — clean it up
    replacements = {"[": "", "]": "", "'": "", " ": ""}
    replacements = dict((re.escape(k), v) for k, v in replacements.items())
    pattern = re.compile("|".join(replacements.keys()))
    str_key_list = pattern.sub(
        lambda m: replacements[re.escape(m.group(0))], key_list)
    key_list = str_key_list.split(",")

    for file_name in key_list:
        logger.debug(f'Creating Makefile command for {file_name}')
        run_commands.append(f'make -f {make_file} {file_name}')
    return run_commands


def idfnc(val):
    return val


def pytest_generate_tests(metafunc):
    if 'test_input' in metafunc.fixturenames:
        logger.debug('Generating commands from pytest_framework')
        test_list = compile_cmd_list(
            metafunc.config.getoption("make_file"),
            metafunc.config.getoption("work_dir"),
            metafunc.config.getoption("key_list"))
        metafunc.parametrize('test_input', test_list, ids=idfnc,
                             indirect=True)


@pytest.fixture
def test_input(request):
    """Execute a single test target and return (retcode, stderr, target)."""
    program = request.param
    stage = program.split()[-1]
    ret, out, err = sys_command(program, 5000)
    return ret, err, stage


def test_eval(test_input):
    assert test_input[0] == 0, (
        f"Test failed at {test_input[2]} stage: {test_input[1]}")
