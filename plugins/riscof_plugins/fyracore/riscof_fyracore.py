import os
import shutil
import logging

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate
import riscv_config.isa_validator as isa_val

logger = logging.getLogger()


class fyracore(pluginTemplate):
    __model__ = "fyracore"
    __version__ = "0.1.0"

    def __init__(self, *args, **kwargs):
        sclass = super().__init__(*args, **kwargs)

        config = kwargs.get('config')
        if config is None:
            logger.error("fyracore RISCOF plugin: missing config section.")
            raise SystemExit(1)
        try:
            self.isa_spec = os.path.abspath(config['ispec'])
            self.platform_spec = os.path.abspath(config['pspec'])
            self.pluginpath = os.path.abspath(config['pluginpath'])
        except KeyError as e:
            logger.error("Missing key in [fyracore] config: " + str(e))
            raise SystemExit(1)
        return sclass

    def initialise(self, suite, work_dir, compliance_env):
        self.work_dir = work_dir
        self.compile_cmd = 'riscv64-unknown-elf-gcc -march={0} -mabi={1}\
         -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles\
         -T '+self.pluginpath+'/env/link.ld\
         -I '+self.pluginpath+'/env/\
         -I ' + compliance_env

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = ('64' if 64 in ispec['supported_xlen'] else '32')
        self.isa = ispec['ISA']
        (self.march, self.mabi, self.march_list) = isa_val.get_march_mabi(self.isa)
        if shutil.which("riscv64-unknown-elf-gcc") is None:
            logger.error("riscv64-unknown-elf-gcc not found in $PATH.")
            raise SystemExit(1)

    def runTests(self, testList):
        # river_core drives compile/run via its own DUT plugin; this hook is
        # unused because the river_core riscof generator only invokes
        # `riscof testlist`, not `riscof run`.
        pass
