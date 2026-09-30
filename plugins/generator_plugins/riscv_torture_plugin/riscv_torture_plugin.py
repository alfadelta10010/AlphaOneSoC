import re
import os
import sys
import shutil
import random
import pluggy
import subprocess
import shlex
import datetime
import pytest
import glob
import pprint

from river_core.log import logger
import river_core.utils as utils
from river_core.constants import *
from riscv_config.isa_validator import get_march_mabi, get_extension_list


gen_hookimpl = pluggy.HookimplMarker("generator")

class riscv_torture_plugin(object):

    @gen_hookimpl
    def pre_gen(self, spec_config, output_dir):

        logger.debug('RISC-V Torture Pre Gen Stage')
        self.output_dir = os.path.abspath(output_dir)
        self.name = 'riscv_torture'

        # riscv-torture pins sbt 1.8.2 / Scala 2.11.12, which cannot parse
        # class files from JDK 17 or newer -- the build dies with
        # NoClassDefFoundError in sbt.internal.parser.SbtParser$. Allow the
        # config to point at a JDK 8/11 install instead of whatever `java`
        # happens to be on PATH.
        java_home = spec_config.get('java_home', '').strip()
        if java_home:
            self.java = os.path.join(os.path.abspath(java_home), 'bin', 'java')
            if not os.path.isfile(self.java):
                logger.error(f'java_home does not contain bin/java: {java_home}')
                raise SystemExit(1)
        else:
            self.java = 'java'
            if shutil.which('java') is None:
                logger.error('Plugin requires java')
                raise SystemExit(1)
        logger.info(f'riscv-torture using java: {self.java}')

        if (os.path.isdir(self.output_dir)):
            logger.debug('exists')
            shutil.rmtree(self.output_dir, ignore_errors=True)
            os.makedirs(self.output_dir)
        logger.debug('Extracting info from list')
        # Extract plugin specific info
        self.jobs = spec_config['jobs']
        self.seed = spec_config['seed']
        self.count = spec_config['count']
        self.configs = os.path.abspath(spec_config['configs'])
        self.filter = spec_config['filter']

        if not os.path.isdir(f'{self.output_dir}/riscv-torture/'):
            subprocess.call(shlex.split(f'git clone \
                https://github.com/ucb-bar/riscv-torture.git --recursive \
                {self.output_dir}/riscv-torture'))
            cwd = os.getcwd()
            os.chdir(f'{self.output_dir}/riscv-torture/env')
            subprocess.call(shlex.split('git checkout master'))
            os.chdir(f'{self.output_dir}/riscv-torture')
            subprocess.call(shlex.split(f"{self.java} -Xmx1G -Xss8M -jar sbt-launch.jar 'generator/run'"))
            subprocess.call(shlex.split(f"rm -f output/*"))
            os.chdir(cwd)

        self.isa = spec_config['isa']
        self.json_dir = output_dir + '/../.json'
        if (os.path.isdir(self.json_dir)):
            logger.debug(self.json_dir + ' Directory exists')
        else:
            os.makedirs(self.json_dir)

        (march, mabi_str,  march_list) = get_march_mabi(self.isa, opt_remove_custom_exts=True)
        if '32' in self.isa:
            self.xlen = 32
        else:
            self.xlen = 64
        self.march = march
        self.mabi = mabi_str

    @gen_hookimpl
    def gen(self, module_dir, output_dir):

        logger.debug('RISC-V Torture Plugin gen phase')
        pytest_file = module_dir + '/riscv_torture_plugin/gen_framework.py'

        report_file_name = '{0}/{1}_{2}'.format(
            self.json_dir, self.name,
            datetime.datetime.now().strftime("%Y%m%d-%H%M"))
        pytest.main([
            pytest_file, 
            '-n={0}'.format(self.jobs), 
            '-k={0}'.format(self.filter), 
            '--configlist={0}'.format(self.configs), '-v',
            '--seed={0}'.format(self.seed), 
            '--count={0}'.format(self.count),
            '--html={0}/reports/riscv_torture.html'.format(output_dir),
            '--report-log={0}.json'.format(report_file_name),
            '--self-contained-html', 
            '--output_dir={0}'.format(f'{self.output_dir}/riscv-torture/'),
            '--module_dir={0}'.format(module_dir),
            '--java={0}'.format(self.java)
        ])
        asm_dir = self.output_dir + '/riscv-torture/output/'
        test_list = {}
        asm_test_list = glob.glob(asm_dir + '**/*.S')
    
        cwd = os.getcwd()
        os.chdir(f'{self.output_dir}/riscv-torture/env')
        result = subprocess.run(shlex.split(f'git apply --check {module_dir}/{self.name}_plugin/patch'), capture_output=True, text=True)
        if not result.stdout:
            logger.info(f'applying patch {module_dir}/{self.name}_plugin/patch')
            result = subprocess.run(shlex.split(f'git apply {module_dir}/{self.name}_plugin/patch'), capture_output=True, text=True)
        os.chdir(cwd)
        test_list =  {}
        entropy = 'bf12e4d'
        for test in  asm_test_list:
            base_key = test[:-7]
            config_name = "_".join(test.split('/')[-2].split('_')[:-1])
            march = self.march
            if 'virtual' in config_name:
                if 'f' not in march:
                    if 'a' in march:
                        march = march[:march.index('a')+1]+'f'+march[march.index('a')+1:]

                    elif 'm' in march:
                        march = march[:march.index('m')+1]+'f'+march[march.index('m')+1:]
                    elif 'i' in march: 
                        march = march[:march.index('i')+1]+'f'+march[march.index('i')+1:]
                linker_file = f'{self.output_dir}/riscv-torture/env/v/link.ld'
                include = [f'{self.output_dir}/riscv-torture/env/v/']
                extra_compile = [
                  f'{self.output_dir}/riscv-torture/env/v/vm.c',
                  f'{self.output_dir}/riscv-torture/env/v/string.c',
                  f'{self.output_dir}/riscv-torture/env/v/entry.S']
                compile_macros = [f'ENTROPY=0x{entropy}']
                # 9 v-mode setup instructions (Spike no longer logs the 5
                # boot-ROM instructions that used to precede them).
                ignore_lines = 9
            else:
                linker_file = f'{self.output_dir}/riscv-torture/env/p/link.ld'
                include = [f'{self.output_dir}/riscv-torture/env/p/']
                extra_compile = []
                compile_macros = []
                # Spike starts the hart at --pc directly (upstream c76d96d9, 2026-03):
                # the boot ROM is neither executed nor logged, so ref.dump begins with
                # the first program instruction, like dut.dump. Explicit 0 because
                # river_core's schema defaults ignore_lines to 4. (Spike before that
                # ran and logged 5 ROM instructions here, and this was 5.)
                ignore_lines = 0
                

            test_list[base_key] = {}
            test_list[base_key]['generator'] = self.name
            test_list[base_key]['work_dir'] = test.split('test.S')[0]
            test_list[base_key]['isa'] = self.isa
            test_list[base_key]['march'] = march
            test_list[base_key]['mabi'] = self.mabi
            test_list[base_key]['cc'] = f'riscv{self.xlen}-unknown-elf-gcc'
            test_list[base_key]['cc_args'] = ' -mcmodel=medany -nostartfiles -nostdlib -static -std=gnu99 -O2 -fno-common -fno-builtin-printf -fvisibility=hidden '
            test_list[base_key]['linker_args'] = '-lm -lgcc -T'
            test_list[base_key]['linker_file'] = linker_file
            test_list[base_key]['asm_file'] = f'{test}'
            test_list[base_key]['include']=include
            test_list[base_key]['compile_macros'] = compile_macros
            test_list[base_key]['extra_compile'] = extra_compile
            test_list[base_key]['result'] = 'Unavailable'
            test_list[base_key]['ignore_lines'] = ignore_lines
                

        return test_list

    @gen_hookimpl
    def post_gen(self, output_dir):
        pass



