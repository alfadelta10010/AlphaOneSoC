# See LICENSE for details

import os
import sys
import pluggy
import shutil
from river_core.log import logger
import river_core.utils as utils
from river_core.constants import *
import random
import re
import datetime
import pytest


def gen_cmd_list(gen_config, jobs, randomize, output_dir, module_dir,
        git_branch, suite, env):

    run_command = []
    run_command.append("riscof arch-test --clone --get-version {1} --dir {0}".format( \
            output_dir+'/riscv-arch-test', git_branch))
    run_command.append("riscof testlist --config {0} --work-dir {1} --suite {2} --env {3} ".format(\
            gen_config, output_dir+'/riscof_work', f"{suite}/", 
            f"{env}/"))
    print(run_command)
    logger.debug(run_command)
    return run_command


def idfnc(val):
    return 'Generating Test-list using RISCOF'


def pytest_generate_tests(metafunc):
    if 'test_input' in metafunc.fixturenames:
        test_list = gen_cmd_list(metafunc.config.getoption("configfile"),
                                 metafunc.config.getoption("jobs"),
                                 metafunc.config.getoption("randomize"),
                                 metafunc.config.getoption("output_dir"),
                                 metafunc.config.getoption("module_dir"),
                                 metafunc.config.getoption("git_branch"),
                                 metafunc.config.getoption("suite"),
                                 metafunc.config.getoption("env"))
        metafunc.parametrize('test_input', test_list, ids=idfnc, indirect=True)


@pytest.fixture
def test_input(request, autouse=True):
    program = request.param
    (ret, out, err) = utils.sys_command(program,timeout=3000)
    return ret


def test_eval(test_input):
    assert test_input == 0
