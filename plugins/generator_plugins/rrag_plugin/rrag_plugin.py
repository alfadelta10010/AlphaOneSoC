# See LICENSE for details

#import riscv_config.checker as riscv_config
#from riscv_config.errors import ValidationError
import os
import pluggy
import shutil
import datetime
import pytest
import glob

from river_core.log import logger
import river_core.utils as utils
from river_core.constants import *

from riscv_config.isa_validator import get_march_mabi

from enum import Enum

gen_hookimpl = pluggy.HookimplMarker("generator")

class gen_type_enum(Enum):
    RAND_CONFIG = 0
    CONFIG = 1
    INVALID = -1

class rrag_plugin(object):
    """ Generator hook implementation """

    # creates gendir and any setup related things
    @gen_hookimpl
    def pre_gen(self, spec_config, output_dir):
        '''
            Pre-Gen Stage.
            Check if the output_dir exists
            Add load plugin specific config
        '''

        # Check if the path exists or not
        logger.debug('rrag Pre Gen Stage')
        output_dir = os.path.abspath(output_dir)
        self.name = 'rrag'

        ## initial checks

        # Check if rrag is there on path
        if shutil.which('rrag') is None:
            logger.error('Plugin requires rrag to be installed')
            raise SystemExit

        if shutil.which('spike') is None:
            logger.error('rrag requires spike to be installed')
            raise SystemExit

        if (os.path.isdir(output_dir)):
            logger.debug('exists')
            shutil.rmtree(output_dir, ignore_errors=True)

        # Generate output directory
        os.makedirs(output_dir)

        # generate config directory
        self.config_dir = output_dir + '/configs/'
        os.makedirs(self.config_dir)

        # Extract plugin specific info
        logger.debug('Extracting info from list')
        self.jobs = spec_config['jobs']
        self.seed = spec_config['seed']
        self.filter = spec_config['filter']
        self.isa = spec_config['isa']
        self.gen_type_str = spec_config['gen_type']
        self.count = spec_config['count']
        self.helpers_path = spec_config['helper_files_path']
        self.tcm = eval(spec_config['tcm'])

        self.gen_type = gen_type_enum.INVALID

        # gather inputs
        if self.gen_type_str == 'random_config':
            self.gen_type = gen_type_enum.RAND_CONFIG
            self.num_configs = spec_config['num_configs']
            self.base_config_path = spec_config['base_config']
        elif self.gen_type_str == 'config':
            self.gen_type = gen_type_enum.CONFIG
            self.config_dir = spec_config['config_dir']
        else:
            assert False, "gen_type should be random_config, config"

        self.json_dir = output_dir + '/../.json/'
        logger.debug(self.json_dir)

        # rrag isa update
        logger.info('Updating riscv-opcodes metadata')
        code, _, _ = utils.sys_command(f'rrag isa-update')
        assert code == 0

        # rrag setup
        logger.info(f'Running rrag setup command')
        code, _, _ = utils.sys_command(f'rrag setup --setup_dir={output_dir}')
        assert code == 0

        if self.gen_type == gen_type_enum.CONFIG:
            shutil.copytree(src=self.config_dir, dst=output_dir + '/configs/', dirs_exist_ok=True)
        
        rand_isa = self.isa
        # ISA string filtering
        if 'Zbpbo' in self.isa:
            rand_isa = rand_isa.replace('Zbp_', '')
            rand_isa = rand_isa.replace('Zbt_', '')

        from ruamel.yaml import YAML
        yaml = YAML()
        
        # edit base config if tcm is enabled
        # place access sections around _end label
        if self.tcm:
            with open(self.base_config_path, 'r') as fp:
                base_yaml = yaml.load(fp)
                if spec_config['tcm_type'] == 'split':
                    dend = int(spec_config['dtcm_base']) + int(spec_config['dtcm_size'], 0)
                    del base_yaml['access-sections']['begin_signature']
                    base_yaml['access-sections'] = {'_end' : f'{hex(dend-0x10000)},{hex(dend-1)},rw'}
                else:
                    dend = int(spec_config['tcm_base']) + int(spec_config['tcm_size'], 0)
                    del base_yaml['access-sections']['begin_signature']
                    base_yaml['access-sections'] = {'_end' : f'{hex(dend-0x10000)},{hex(dend-1)},rw'}
                
                with open(self.base_config_path, 'w') as fp:
                    yaml.dump(base_yaml, fp)

        # generate random configs if random configs
        if self.gen_type == gen_type_enum.RAND_CONFIG:
            logger.info(f'Generating {self.num_configs} randomized configurations')
            code, _, _ = utils.sys_command(f'rrag randomise-configs --n={self.num_configs} \
                              --isa_string={rand_isa} \
                              --source={self.base_config_path} \
                              --destination={self.config_dir}', logging=False)
            assert code == 0
        
        # Check if dir exists
        if (os.path.isdir(self.json_dir)):
            logger.debug(self.json_dir + ' Directory exists')
        else:
            os.makedirs(self.json_dir)

    # gets the yaml file with list of configs; test count; parallel
    @gen_hookimpl
    def gen(self, module_dir, output_dir):

        logger.debug('rrag Plugin gen phase')
        logger.debug(module_dir)
        pytest_file = module_dir + '/rrag_plugin/gen_framework.py'
        logger.debug(pytest_file)

        output_dir = os.path.abspath(output_dir)

        report_file_name = '{0}/{1}_{2}'.format(
            self.json_dir, self.name,
            datetime.datetime.now().strftime("%Y%m%d-%H%M"))

        pytest.main([
            pytest_file, '-n={0}'.format(self.jobs), '-k={0}'.format(
                self.filter), '--configlist={0}'.format(self.config_dir), '-v',
            '--seed={0}'.format(self.seed), '--count={0}'.format(self.count),
            '--html={0}/reports/rrag.html'.format(output_dir),
            '--report-log={0}.json'.format(report_file_name),
            '--self-contained-html', '--output_dir={0}'.format(output_dir),
            '--module_dir={0}'.format(module_dir)
        ])
        
        # Generate Test List
        # Get the rrag dir from output
        asm_dir = output_dir + '/rrag/asm/'
        test_list = dict()
        asm_test_list = glob.glob(asm_dir + '**/*[!_template].S')
        
        # asm_templates = glob.glob(asm_dir+'/**/*.S')
        for test in asm_test_list:

            march_str, mabi_str, _ = get_march_mabi(self.isa)
            
            # Create the base key for the test i.e. the main file under which everything is stored
            # NOTE: Here we expect the developers to probably have the proper GCC and the args, objdump as well
            base_key = os.path.basename(test)[:-2]
            test_list[base_key] = {}
            test_list[base_key]['generator'] = self.name
            test_list[base_key][
                'work_dir'] = output_dir + '/rrag/asm/' + base_key
            test_list[base_key]['isa'] = self.isa
            test_list[base_key]['march'] = march_str
            test_list[base_key]['mabi'] = mabi_str
            test_list[base_key]['cc'] = f'riscv64-unknown-elf-gcc'
            test_list[base_key][
                'cc_args'] = '-static -std=gnu99 -O2 -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles'
            test_list[base_key][
                'linker_args'] = f'-lm -lgcc {self.helpers_path}/boot.bo -Wl,--entry="_boot_start" -T'
            test_list[base_key][
                'linker_file'] = f'{self.helpers_path}/link.ld'
            test_list[base_key][
                'asm_file'] = output_dir + '/rrag/asm/' + base_key + '/' + base_key + '.S'
            test_list[base_key]['include']=[]
            test_list[base_key]['compile_macros'] = []
            test_list[base_key]['extra_compile'] = [
                output_dir + '/rrag/common/crt.S'
            ]

            test_list[base_key]['result'] = 'Unavailable'

        return test_list

    @gen_hookimpl
    def post_gen(self, output_dir):
        pass
