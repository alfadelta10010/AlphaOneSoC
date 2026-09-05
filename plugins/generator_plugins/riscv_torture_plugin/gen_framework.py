# See LICENSE for details

import os
import sys
import pluggy
import shutil
import shlex
import subprocess
from river_core.log import logger
import river_core.utils as utils
from river_core.constants import *
import random
import re
import datetime
import pytest
from envyaml import EnvYAML

def sys_command(command, cwd=None, timeout=3000):
    '''
        Wrapper function to run shell commands with a timeout.
        Uses :py:mod:`subprocess`, :py:mod:`shlex`, :py:mod:`os`
        to ensure proper termination on timeout

        :param command: The shell command to run.

        :param timeout: The value after which the framework exits. Default set to configured to 240 seconds

        :type command: list

        :type timeout: int

        :returns: Error Code (int) ; STDOUT ; STDERR

        :rtype: list
    '''
    logger.warning('$ timeout={1} {0} '.format(' '.join(shlex.split(command)),
                                               timeout))
    out = ''
    err = ''
    with subprocess.Popen(shlex.split(command),
                          stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE,cwd = cwd,
                          start_new_session=True) as process:
        try:
            out, err = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            pgrp = os.getpgid(process.pid)
            os.killpg(pgrp, signal.SIGTERM)
            return 1, "GuruMeditation", "TimeoutExpired"

    out = out.rstrip()
    err = err.rstrip()
    if process.returncode != 0:
        if out:
            logger.error(out.decode("ascii"))
        if err:
            logger.error(err.decode("ascii"))
    else:
        if out:
            logger.debug(out.decode("ascii"))
        if err:
            logger.debug(err.decode("ascii"))
    return (process.returncode, out.decode("ascii"), err.decode("ascii"))


def gen_cmd_list(configlist, seed, count, output_dir, module_dir):
    logger.debug(f"Now generating commands for riscv-torture {configlist}")
    pwd = os.getcwd()
    exec_dir = f"{output_dir}"
    torture_command = f"java -Xmx1G -Xss8M -jar sbt-launch.jar"

    run_command = []
    config_yaml = utils.load_yaml(configlist)
    for c in config_yaml['configs']:
        name = c.split('/')[-1].replace('.','_')
        config_path = os.path.abspath(c)
        for i in range(config_yaml['configs'][c]):
            logger.debug(i)
            os.makedirs(f'{exec_dir}/output/{name}_{i}/', exist_ok = True)
            run_command.append((f"{torture_command} \'generator/run --config {config_path} --output {name}_{i}/test\'", exec_dir))
    logger.debug(run_command)
    return run_command

def idfnc(val):
    template_match = re.search('--config (.*).config', '{0}'.format(val))
    logger.debug('{0}'.format(val))
    return 'Generating {0}'.format(template_match.group(1))


def pytest_generate_tests(metafunc):
    if 'test_input' in metafunc.fixturenames:
        test_list = gen_cmd_list(metafunc.config.getoption("configlist"),
                                 metafunc.config.getoption("seed"),
                                 metafunc.config.getoption("count"),
                                 metafunc.config.getoption("output_dir"),
                                 metafunc.config.getoption("module_dir"))
        metafunc.parametrize('test_input', test_list, ids=idfnc, indirect=True)


@pytest.fixture
def test_input(request, autouse=True):
    # compile tests
    (program, exec_dir) = request.param
    (ret, out, err) = sys_command(program, cwd=exec_dir)
    for x in range(3):
        if ret != 0 :
            (ret, out, err) = sys_command(program, cwd=exec_dir)
        else:
            break
    return ret


def test_eval(test_input):
    assert test_input == 0


