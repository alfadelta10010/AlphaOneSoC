# See LICENSE for details

#import riscv_config.checker as riscv_config
#from riscv_config.errors import ValidationError
import os
import sys
import pluggy
import shutil
import random
import re
import datetime
import pytest
import glob
from river_core.log import logger
import river_core.utils as utils
from river_core.constants import *
import re
import subprocess
import shlex
from glob import *
import pprint
import riscv_config.isa_validator as isa_val
from riscv_config.isa_validator import get_march_mabi, get_extension_list

gen_hookimpl = pluggy.HookimplMarker("generator")


class riscv_tests_plugin(object):
    """ Generator hook implementation """

    # creates gendir and any setup related things
    @gen_hookimpl
    def pre_gen(self, spec_config, output_dir):
        '''

         Pre-Gen Stage.

         Check if the output_dir exists

         Add load plugin specific config

        '''

        logger.debug('RISCV-TESTS Plugin Pre Gen Stage')
        output_dir = os.path.abspath(output_dir)
        self.output_dir = output_dir
        self.name = 'riscv_tests'

        logger.debug('Extracting info from list')
        # Extract plugin specific info
        self.jobs = spec_config['jobs']
        self.filter = spec_config['filter']
        self.helpers_path = spec_config['helper_files_path']

        self.pmp_enabled = True if str(spec_config['pmp_regions']) != "0" else False

        # The checkout is pinned. gen() parses the isa/rv32* directory names
        # and the per-directory Makefrag to decide which tests exist, so an
        # upstream reshuffle silently changes the test set -- and because the
        # clone is skipped when the directory already exists, two machines can
        # sit on different commits indefinitely and disagree about what a
        # "full riscv_tests run" means. This is the revision the current
        # results were produced against.
        # The pin is enforced on every run, not only on a fresh clone: doing it
        # at clone time alone left every machine that already had a checkout on
        # whatever revision it was created with, which is exactly the problem
        # the pin is for.
        riscv_tests_rev = '2ebecad997fa58cd9e5724340ba75aa4b59bd1d0'
        if not os.path.isdir(f'{self.output_dir}'):
            ret = subprocess.call(shlex.split(f'git clone --recursive \
               https://github.com/riscv/riscv-tests.git {self.output_dir}/'))
            if ret != 0:
                logger.error('Failed to clone riscv-tests')
                raise SystemExit(1)
        head = subprocess.run(
            shlex.split(f'git -C {self.output_dir} rev-parse HEAD'),
            capture_output=True, text=True).stdout.strip()
        if head != riscv_tests_rev:
            logger.info(
                f'Pinning riscv-tests to {riscv_tests_rev[:12]} '
                f'(was {head[:12] or "unknown"})')
            ret = subprocess.call(shlex.split(
                'git -C {0} checkout --quiet --recurse-submodules {1}'.format(
                    self.output_dir, riscv_tests_rev)))
            if ret != 0:
                logger.error(
                    f'Could not check out riscv-tests {riscv_tests_rev}; the '
                    f'test set is not the one results were measured against.')
                raise SystemExit(1)

        self.isa_dir = self.output_dir + '/isa'

        # TODO Might  be useful later on
        # Eventually add support for riscv_config
        self.isa = spec_config['isa']
        (ext_list, err, err_list) = isa_val.get_extension_list(self.isa)
        self.ext_list = ext_list

        self.json_dir = output_dir + '/../.json/'
        logger.debug(self.json_dir)
        # Check if dir exists
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

        cwd = os.getcwd()
        os.chdir(f'{self.output_dir}/env')
        patch_name = "init_pmp.patch" if self.pmp_enabled else "patch"
        result = subprocess.run(shlex.split(f'git apply --check {module_dir}/{self.name}_plugin/{patch_name}'), capture_output=True, text=True)
        if not result.stdout:
            logger.debug(f'applying patch: {patch_name}')
            result = subprocess.run(shlex.split(f'git apply {module_dir}/{self.name}_plugin/{patch_name}'), capture_output=True, text=True)
        os.chdir(cwd)

        logger.debug(f'isa_dir : {self.isa_dir}')
        isas = []
        for mydir in os.listdir(self.isa_dir):
            if mydir.startswith(f"rv{self.xlen}"):
                (xlen,mode,isa) = re.findall(r'rv(?P<xlen>64|32)(?P<mode>m|u|s)(?P<name>.*)$',mydir)[0]
                isa = isa.capitalize()
                mode = mode.capitalize()
                # p-mode tests boot in M-mode regardless of U/S support, so always
                # accept 'u' dirs; 'm' always; 's' only when S is in ext_list.
                # v-mode variant gating happens later via Makefrag + S check.
                if int(xlen,0) == self.xlen and isa in self.ext_list and (mode in ('M', 'U') or mode in self.ext_list):
                    isas.append(mydir)

        logger.debug(f'found : {isas}')
        test_list = {}
        for i in isas:
            with open(f'{self.isa_dir}/{i}/Makefrag', 'r') as file:
                data = file.read()
                if re.findall(r'.*_v_tests',data) and 'S' in self.ext_list:
                    virtual = True
                else:
                    virtual = False

            for t in os.listdir(self.isa_dir + '/' + i):
                if 'breakpoint' in t or ('wfi' in t):
                    continue
                if 'sbreak' in t and 'S' not in self.ext_list:
                    continue
                if self.xlen == 32 and 'D' in self.ext_list:
                    if i == 'rv32ud' and 'move' in t:
                        continue
                if 'zicntr' in t and ('Zicntr' not in self.ext_list or 'U' not in self.ext_list):
                    continue
                if t.endswith('.S'):
                    work_dir = f'{self.isa_dir}/p/{i}-{t[:-2]}'
                    base_key = f'{i}-{t[:-2]}-p'
                    test_list[base_key] = {}
                    test_list[base_key]['work_dir']= work_dir
                    test_list[base_key]['generator'] = self.name
                    test_list[base_key]['isa'] = self.isa
                    test_list[base_key]['march'] = self.march
                    test_list[base_key]['mabi'] = self.mabi
                    test_list[base_key]['cc'] = f'riscv64-unknown-elf-gcc'
                    test_list[base_key]['cc_args'] = '-static -std=gnu99 -O2 -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles'
                    test_list[base_key]['linker_args'] = f'-lm -lgcc -T'
                    test_list[base_key]['linker_file'] = f'{self.output_dir}/env/p/link.ld'
                    test_list[base_key]['asm_file'] = f'{self.isa_dir}/{i}/{t}'
                    test_list[base_key]['include'] = [\
                            f'{self.output_dir}/env/p/',
                            f'{self.isa_dir}/macros/scalar',]
                    test_list[base_key]['extra_compile'] = []
                    test_list[base_key]['compile_macros'] = []
                    test_list[base_key]['result'] = 'Unavailable'
                    # Spike starts the hart at --pc directly (upstream c76d96d9, 2026-03):
                    # the boot ROM is neither executed nor logged, so ref.dump begins with
                    # the first program instruction, like dut.dump. Explicit 0 because
                    # river_core's schema defaults ignore_lines to 4. (Spike before that
                    # ran and logged 5 ROM instructions here, and this was 5.)
                    test_list[base_key]['ignore_lines'] = 0
                    if (os.path.isdir(work_dir)):
                        logger.debug(f'{work_dir} exists')
                        shutil.rmtree(work_dir, ignore_errors=True)
                    os.makedirs(work_dir)
                    if virtual:
                        march = self.march
                        if 'f' not in march:
                            if 'a' in march:
                                march = march[:march.index('a')+1]+'f'+march[march.index('a')+1:]

                            elif 'm' in march:
                                march = march[:march.index('m')+1]+'f'+march[march.index('m')+1:]
                            elif 'i' in march:
                                march = march[:march.index('i')+1]+'f'+march[march.index('i')+1:]

                        work_dir = f'{self.isa_dir}/v/{i}-{t[:-2]}'
                        entropy = 'bf12e4d'
                        base_key = f'{i}-{t[:-2]}-v'
                        test_list[base_key] = {}
                        test_list[base_key]['work_dir']= work_dir
                        test_list[base_key]['generator'] = self.name
                        test_list[base_key]['isa'] = self.isa
                        test_list[base_key]['march'] = march
                        test_list[base_key]['mabi'] = self.mabi
                        test_list[base_key]['cc'] = f'riscv64-unknown-elf-gcc'
                        test_list[base_key]['cc_args'] = '-static -std=gnu99 -O2 -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles'
                        test_list[base_key]['linker_args'] = f'-lm -lgcc -T'
                        test_list[base_key]['linker_file'] = f'{self.output_dir}/env/v/link.ld'
                        test_list[base_key]['asm_file'] = f'{self.isa_dir}/{i}/{t}'
                        test_list[base_key]['include'] = [\
                                f'{self.output_dir}/env/v/',
                                f'{self.isa_dir}/macros/scalar',]
                        test_list[base_key]['extra_compile'] = [\
                                f'{self.output_dir}/env/v/vm.c',
                                f'{self.output_dir}/env/v/string.c',
                                f'{self.output_dir}/env/v/entry.S']
                        test_list[base_key]['compile_macros'] = [f'ENTROPY=0x{entropy}']
                        test_list[base_key]['result'] = 'Unavailable'
                        # v-mode: 9 v-mode setup lines (Spike no longer
                        # logs the 5 boot-ROM lines that used to precede them)
                        test_list[base_key]['ignore_lines'] = 9
                        if (os.path.isdir(work_dir)):
                            logger.debug(f'{work_dir} exists')
                            shutil.rmtree(work_dir, ignore_errors=True)
                        os.makedirs(work_dir)

        return test_list

    # generates the regress list from the generation
    @gen_hookimpl
    def post_gen(self, output_dir):
        pass
