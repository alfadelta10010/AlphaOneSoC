# See LICENSE for details

import os
import sys
import pluggy
import shutil
import subprocess
import random
import re
import datetime
import pytest
import glob
import re
import configparser

from river_core.log import logger
import river_core.utils as utils
from river_core.constants import *
import riscof
from riscv_config.isa_validator import get_march_mabi, get_extension_list

gen_hookimpl = pluggy.HookimplMarker("generator")

this = os.path.abspath(os.path.dirname(__file__))
class riscof_plugin(object):
    @gen_hookimpl
    def pre_gen(self, spec_config, output_dir):
        '''
            Spec Config Fields and their meanings.
            jobs: number of parallel processes to spawn for riscof
            riscof_config: config file for riscof
        '''
        logger.debug("RISCOF Pre Gen.")
        self.name = 'riscof'
        output_dir = os.path.abspath(output_dir)
        if (os.path.isdir(output_dir)):
            logger.debug('Output Directory exists. Removing Contents.')
            shutil.rmtree(output_dir, ignore_errors=True)
        os.makedirs(output_dir)
        logger.debug(f"-- config is : {spec_config['suite']}")
        self.jobs = int(spec_config['jobs'])
        self.config_file = os.path.abspath(spec_config['riscof_config'])
        self.gitbranch = spec_config['version']
        self.isa = spec_config['isa']
        if 'suite' not in spec_config or spec_config['suite'] == '':
            self.suite = f'{output_dir}/riscv-arch-test/riscv-test-suite'
            self.env = f'{output_dir}/riscv-arch-test/riscv-test-suite/env'
        else:
            self.suite = os.path.abspath(spec_config['suite'])
            self.env = os.path.abspath(spec_config['env'])

        logger.info(f'RISCOF using suite : {self.suite}')
        (march, mabi_str,  march_list) = get_march_mabi(self.isa, opt_remove_custom_exts=True)
        if '32' in self.isa:
            self.xlen = 32
        else:
            self.xlen = 64
        self.march = march
        self.mabi = mabi_str
        self.helpers_path = spec_config['helper_files_path'] 

    @gen_hookimpl
    def gen(self, module_dir, output_dir):
        riscof_config = configparser.ConfigParser()
        riscof_config.read(self.config_file)
        output_dir = os.path.abspath(output_dir)
        logger.debug("CTG Gen phase.")
        asm_path = os.path.join(output_dir,"riscof/")
        pytest_file = os.path.join(this,'gen_framework.py')
        os.makedirs(asm_path, exist_ok=True)
        report_file_name = '{0}/{1}_{2}'.format(
            os.path.join(output_dir,".json/"), self.name,
            datetime.datetime.now().strftime("%Y%m%d-%H%M"))
        pytest.main([
            pytest_file, '-n=1',
            '--configfile={0}'.format(self.config_file), '-v',
            '--jobs={0}'.format(self.jobs),
            '--html={0}/reports/riscof.html'.format(output_dir),
            '--report-log={0}.json'.format(report_file_name),
            '--self-contained-html', '--output_dir={0}'.format(asm_path),
            '--module_dir={0}'.format(this),
            '--git_branch={0}'.format(self.gitbranch),
            '--suite={0}'.format(self.suite),
            '--env={0}'.format(self.env)]
            )
        work_dir = os.path.join(output_dir,"riscof/riscof_work/")
        includes = self.env
        model_include = os.path.abspath(riscof_config['RISCOF']['DUTPluginPath']+'/env/')
        riscof_test_list = utils.load_yaml(os.path.join(work_dir,"test_list.yaml"))
        if len(riscof_test_list) == 0:
            logger.error('No tests selected by RISCOF')
            raise SystemExit(1)
        test_list = {}
        xlen = 64 if '64' in self.isa else 32
        for entry in riscof_test_list.keys():
            key = os.path.basename(entry)[:-2]
            new_entry = {}
            new_entry["isa"] = self.isa
            new_entry['work_dir'] = riscof_test_list[entry]['work_dir']
            new_entry['asm_file'] = riscof_test_list[entry]['test_path']
            new_entry['generator'] = self.name
            new_entry['include'] = [includes, model_include]
            new_entry['cc'] = f'riscv64-unknown-elf-gcc'
            new_entry['result'] = "Unavailable"
            new_entry['cc_args'] = '-static -std=gnu99 -O2 -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles'
            new_entry['linker_args'] = '-lm -lgcc -T'
            new_entry['linker_file'] = os.path.join(model_include, 'link.ld')
            new_entry['mabi'] = self.mabi
            new_entry['compile_macros'] = riscof_test_list[entry]['macros']
            new_entry['extra_compile'] = []
            new_entry['march'] = self.march
            # Spike emits 5 bootrom instructions (auipc/addi/csrr/lw/jr)
            # before jumping to --pc=0x80000000. The DUT starts directly at
            # RESET_PC. Skip those leading ref.dump lines.
            new_entry['ignore_lines'] = 5
            test_list[key] = new_entry

        if 'C' not in self.isa:
            # RISCOF decides which tests the suite yields, so this one is not
            # guaranteed to be present -- a narrower suite, a different
            # riscv-arch-test version or a filtered run all drop it. An
            # unguarded del turned that into a KeyError that aborted the whole
            # generate stage.
            test_list.pop('misalign-jal-01', None)
        
        return test_list

    @gen_hookimpl
    def post_gen(self, output_dir):
        pass
