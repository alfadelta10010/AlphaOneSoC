# River Core DUT Plugin for FyraCore using Icarus Verilog (iverilog + vvp)

import os
import shutil
import datetime
import pluggy
import pytest
import re

from river_core.log import logger
from river_core.utils import sys_command, load_yaml, makeUtil, str_2_bool

dut_hookimpl = pluggy.HookimplMarker('dut')

# FyraCore RTL source files (relative to src_dir)
FYRACORE_SRC = [
    'src/alu.v',
    'src/branchCtrl.v',
    'src/clint.v',
    'src/compressed_decoder.v',
    'src/controller.v',
    'src/csr.v',
    'src/decoder.v',
    'src/fyracore.v',
    'src/muldiv.v',
    'src/pmp.v',
    'src/regFile.v',
    'src/regs.v',
    'src/signExt.v',
]

FYRACORE_TB = [
    'tb/memory_model.v',
    'tb/tb_rivercore.v',
]


class fyracore_iverilog_plugin(object):
    """River Core DUT plugin for FyraCore on Icarus Verilog."""

    @dut_hookimpl
    def init(self, ini_config, test_list, work_dir, coverage_config,
             plugin_path, timeout):
        self.name = 'fyracore_iverilog'
        logger.info('FyraCore iverilog plugin: Pre-Compile Stage')

        # ----- Validate required tools -----
        for tool in ['iverilog', 'vvp']:
            if shutil.which(tool) is None:
                logger.error(f'{tool} not found in $PATH')
                raise SystemExit(1)

        if (shutil.which('riscv64-unknown-elf-gcc') is None and
                shutil.which('riscv32-unknown-elf-gcc') is None):
            logger.error('riscv-* toolchain not found in $PATH')
            raise SystemExit(1)

        if shutil.which('riscv64-unknown-elf-objcopy') is None:
            if shutil.which('riscv32-unknown-elf-objcopy') is None:
                logger.error('riscv-*-objcopy not found in $PATH')
                raise SystemExit(1)

        # ----- Parse config -----
        self.src_dir = os.path.abspath(ini_config['src_dir'])
        self.jobs = ini_config['jobs']
        self.riscv_isa = ini_config['isa']
        self.xlen = 64 if '64' in self.riscv_isa else 32
        self.timeout_period = timeout
        self.plugin_path = plugin_path + '/'
        self.filter = ini_config.get('filter', '')

        if 'stop_on_failure' in ini_config:
            self.stop_on_failure = str_2_bool(ini_config['stop_on_failure'])
        else:
            self.stop_on_failure = False

        # ----- Paths -----
        self.work_dir = os.path.abspath(work_dir) + '/'
        self.sim_path = self.work_dir + self.name
        os.makedirs(self.sim_path, exist_ok=True)

        self.json_dir = self.work_dir + '.json/'
        os.makedirs(self.json_dir, exist_ok=True)

        # ----- Load test list -----
        self.test_list = load_yaml(test_list)

        # ----- Build simulator binary (one-time) -----
        logger.info('Building FyraCore iverilog simulator')

        src_files = ' '.join(
            os.path.join(self.src_dir, f) for f in FYRACORE_SRC)
        tb_files = ' '.join(
            os.path.join(self.src_dir, f) for f in FYRACORE_TB)

        self.sim_binary = os.path.join(self.sim_path, 'sim_fyracore')

        iverilog_cmd = (
            f'iverilog -g2012 -o {self.sim_binary} '
            f'-s tb_rivercore '
            f'{src_files} {tb_files}'
        )
        logger.debug(f'iverilog command: {iverilog_cmd}')
        ret, out, err = sys_command(iverilog_cmd, 300)
        if ret != 0:
            logger.error(f'iverilog compilation failed:\n{err}')
            raise SystemExit(1)

        if not os.path.isfile(self.sim_binary):
            logger.error(
                f'Simulator binary not found at {self.sim_binary}')
            raise SystemExit(1)
        logger.info(f'Simulator built: {self.sim_binary}')

    @dut_hookimpl
    def build(self):
        logger.info('FyraCore iverilog plugin: Build Hook')
        make = makeUtil(
            makefilePath=os.path.join(self.work_dir,
                                      'Makefile.' + self.name))
        make.makeCommand = 'make -j1'
        self.make_file = os.path.join(self.work_dir, 'Makefile.' + self.name)
        self.test_names = []

        # Determine objcopy prefix
        if shutil.which('riscv64-unknown-elf-objcopy'):
            objcopy = 'riscv64-unknown-elf-objcopy'
        else:
            objcopy = 'riscv32-unknown-elf-objcopy'

        for test, attr in self.test_list.items():
            logger.debug(f'Creating Make target for {test}')
            abi = attr['mabi']
            arch = attr['march']
            work_dir = attr['work_dir']
            link_args = attr['linker_args']
            link_file = attr['linker_file']
            cc = attr['cc']
            cc_args = attr['cc_args']
            asm_file = attr['asm_file']

            # -- cd into the test's working directory --
            ch_cmd = f'cd {work_dir} && '

            # -- Cross-compile .S → .elf --
            compile_cmd = (
                f'{cc} {cc_args} -march={arch} -mabi={abi} '
                f'{link_args} {link_file} {asm_file}'
            )
            for x in attr.get('extra_compile', []):
                compile_cmd += ' ' + x
            for x in attr.get('include', []):
                compile_cmd += f' -I {x}'
            compile_cmd += ''.join(
                f' -D{m}' for m in attr.get('compile_macros', []))
            compile_cmd += f' -o {test}.elf && '

            # -- Convert .elf → verilog hex for $readmemh --
            # Tests are linked at 0x80000000 (Spike-compatible). Shift hex
            # addresses down by 0x80000000 so $readmemh writes into mem[0..]
            # (memory_model truncates address bits [24:0], aliasing 0x80000000
            # PCs back to mem[0] at runtime).
            hex_cmd = (
                f'{objcopy} -O verilog --change-addresses=-0x80000000 '
                f'{test}.elf {test}.hex && '
            )

            # -- Symlink simulator binary --
            sim_setup = (
                f'ln -f -s {self.sim_binary} ./sim_fyracore && '
            )

            # -- Extract tohost address from ELF for termination detection --
            # `riscv64-unknown-elf-readelf -s` lists the .tohost symbol address
            # in column 2.  Tests signal pass/fail by storing to this address.
            tohost_cmd = (
                f'TOHOST=$$(riscv64-unknown-elf-readelf -s {test}.elf '
                f'| awk \'$$8=="tohost"{{print $$2}}\') && '
            )

            # -- Run simulation --
            if self.timeout_period >= 0:
                timeout_cmd = (
                    f'timeout -k 10s {int(self.timeout_period) + 5} ')
            else:
                timeout_cmd = ''

            sim_cmd = (
                f'{timeout_cmd}vvp ./sim_fyracore '
                f'+INIT_FILE={work_dir}/{test}.hex '
                f'+DUMP_FILE=dut.dump '
                f'+TOHOST_ADDR=$$TOHOST '
                f'+MAX_CYCLES=1000000 '
                f'1> /dev/null'
            )

            # -- Post-sim: strip halt-loop retires so DUT dump aligns with
            # the Spike reference dump. Spike stops on tohost write and the
            # spike plugin sed-strips (0x00000063) beqz-self and (0x0000006f)
            # jal-self from ref.dump. RISCOF RVMODEL_HALT emits `me: beqz
            # x0, me` which our TB retires up to 3x post-tohost — drop the
            # same opcodes here so the diff aligns.
            strip_cmd = (
                " && sed -i -E '/\\(0x00000063\\)$$/d;"
                "/\\(0x0000006f\\)$$/d' dut.dump"
            )

            # -- Cleanup --
            clean_cmd = ' && rm -f sim_fyracore'

            target_cmd = (
                ch_cmd + compile_cmd + hex_cmd + sim_setup +
                tohost_cmd + sim_cmd + strip_cmd + clean_cmd
            )
            make.add_target(target_cmd, test)
            self.test_names.append(test)

    @dut_hookimpl
    def run(self, module_dir):
        logger.info('FyraCore iverilog plugin: Run Hook')
        pytest_file = os.path.join(
            module_dir, 'fyracore_iverilog_plugin', 'gen_framework.py')
        logger.debug(f'Pytest file: {pytest_file}')

        report_file_name = os.path.join(
            self.json_dir,
            f'{self.name}_{datetime.datetime.now().strftime("%Y%m%d-%H%M")}')

        pytest_args = [
            pytest_file,
            f'-n={self.jobs}',
            f'-k={self.filter}',
            f'--html={self.work_dir}/reports/{self.name}.html',
            f'--report-log={report_file_name}.json',
            f'--work_dir={self.work_dir}',
            f'--make_file={self.make_file}',
            f'--key_list={self.test_names}',
            '--log-cli-level=DEBUG',
            '-o', 'log_cli=true',
            f'--timeout={self.timeout_period}',
        ]
        if self.stop_on_failure:
            pytest_args.append('-x')

        pytest_state = pytest.main(pytest_args)
        if pytest_state in (pytest.ExitCode.INTERRUPTED,
                            pytest.ExitCode.TESTS_FAILED):
            logger.error(
                'FyraCore DUT plugin: some tests failed or were interrupted')

        return report_file_name

    @dut_hookimpl
    def post_run(self, test_dict, config):
        logger.info('FyraCore iverilog plugin: Post-Run Hook')

        if str_2_bool(config.get('river_core', {}).get(
                'space_saver', 'False')):
            logger.debug('Removing artifacts for passed tests')
            for test, attr in test_dict.items():
                if attr.get('result', '') == 'Passed':
                    work = attr['work_dir']
                    for pattern in ['*.elf', '*.hex', '*.vcd']:
                        for f in os.listdir(work):
                            if f.endswith(pattern.replace('*', '')):
                                try:
                                    os.remove(os.path.join(work, f))
                                except OSError:
                                    pass
