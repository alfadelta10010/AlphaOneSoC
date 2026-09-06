# See LICENSE for details
#
# river_core generator plugin for upstream riscv-dv (CHIPS Alliance) driven
# through its pyflow backend.
#
# pyflow is the Python + PyVSC generator, so it needs no commercial
# SystemVerilog simulator. That matters here: the stock riscv-dv flow is
# SV/UVM and would require VCS, Questa or Xcelium, and Verilator cannot run
# UVM. pyflow's only real dependency is pyvsc from PyPI.

import os
import shutil
import glob
import datetime
import subprocess

import pluggy
import pytest

from river_core.log import logger
import river_core.utils as utils
from riscv_config.isa_validator import get_march_mabi

gen_hookimpl = pluggy.HookimplMarker("generator")

this = os.path.abspath(os.path.dirname(__file__))


class riscv_dv_plugin(object):

    @gen_hookimpl
    def pre_gen(self, spec_config, output_dir):
        '''
            Spec config fields:
              jobs            : parallel pytest workers
              riscv_dv_dir    : where the riscv-dv checkout lives (cloned if absent)
              version         : git ref to check out after cloning
              target          : pyflow target name (rv32imac)
              custom_target   : directory holding riscv_core_setting.py + testlist.yaml
              seed            : optional fixed seed
        '''
        logger.debug('riscv-dv Pre Gen')
        self.name = 'riscv_dv'
        self.output_dir = os.path.abspath(output_dir)
        self.jobs = spec_config['jobs']
        self.isa = spec_config['isa']
        self.seed = spec_config.get('seed', '').strip()
        self.target = spec_config.get('target', 'rv32imac').strip()

        (march, mabi, _) = get_march_mabi(self.isa, opt_remove_custom_exts=True)
        self.march = march
        self.mabi = mabi
        self.xlen = 64 if '64' in self.isa else 32

        # Pick a toolchain that actually exists. An rv32 ISA does not imply a
        # riscv32-* toolchain is installed -- the riscv64 multilib build
        # compiles rv32 fine with -march/-mabi, and is what the other
        # generator plugins use. Preferring the xlen-matching name and falling
        # back avoids emitting a compiler that is not on the machine.
        for cand in (f'riscv{self.xlen}-unknown-elf-gcc',
                     'riscv64-unknown-elf-gcc',
                     'riscv32-unknown-elf-gcc'):
            if shutil.which(cand):
                self.cc = cand
                break
        else:
            logger.error('No riscv*-unknown-elf-gcc found in $PATH')
            raise SystemExit(1)
        logger.info(f'riscv-dv using compiler: {self.cc}')

        # pyflow is pure Python; no simulator needed. It does need pyvsc.
        try:
            import vsc  # noqa: F401
        except ImportError:
            logger.error(
                'riscv-dv pyflow requires the pyvsc package '
                '(pip install pyvsc) in the environment river_core runs from')
            raise SystemExit(1)

        self.riscv_dv_dir = os.path.abspath(spec_config['riscv_dv_dir'])
        self.custom_target = os.path.abspath(spec_config['custom_target'])
        if not os.path.isdir(self.custom_target):
            logger.error(f'custom_target directory not found: {self.custom_target}')
            raise SystemExit(1)

        # Clone upstream riscv-dv if it is not already there. Unlike the
        # riscof plugin this does not wipe and re-clone on every run: the
        # checkout is large and nothing in it is generated per-run.
        if not os.path.isdir(os.path.join(self.riscv_dv_dir, '.git')):
            os.makedirs(os.path.dirname(self.riscv_dv_dir), exist_ok=True)
            logger.info(f'Cloning riscv-dv into {self.riscv_dv_dir}')
            ret = subprocess.call([
                'git', 'clone', '--quiet',
                'https://github.com/chipsalliance/riscv-dv.git',
                self.riscv_dv_dir])
            if ret != 0:
                logger.error('Failed to clone riscv-dv')
                raise SystemExit(1)
            version = spec_config.get('version', '').strip()
            if version:
                subprocess.call(['git', '-C', self.riscv_dv_dir,
                                 'checkout', '--quiet', version])
        else:
            logger.info(f'Reusing riscv-dv checkout at {self.riscv_dv_dir}')

        self._apply_patches()

        # Install the FyraCore target. pyflow imports the core settings as a
        # module -- riscv_instr_gen_config.py does
        #     import_module("pygen_src.target." + target + ".riscv_core_setting")
        # so the file has to live inside the checkout's package tree.
        # --custom_target only bypasses run.py's target allowlist; it does not
        # affect that import path.
        pygen_target = os.path.join(
            self.riscv_dv_dir, 'pygen', 'pygen_src', 'target', self.target)
        runpy_target = os.path.join(self.riscv_dv_dir, 'target', self.target)
        os.makedirs(pygen_target, exist_ok=True)
        os.makedirs(runpy_target, exist_ok=True)
        shutil.copy(os.path.join(self.custom_target, 'riscv_core_setting.py'),
                    pygen_target)
        shutil.copy(os.path.join(self.custom_target, 'testlist.yaml'),
                    runpy_target)
        # run.py spawns `python3 pygen/pygen_src/test/riscv_instr_base_test.py`,
        # which does `from pygen_src...`. That is only importable with
        # <riscv-dv>/pygen on the path, and relying on cwd is fragile because
        # pytest workers do not inherit a cwd we control. Export it instead.
        pygen_path = os.path.join(self.riscv_dv_dir, 'pygen')
        existing = os.environ.get('PYTHONPATH', '')
        if pygen_path not in existing.split(os.pathsep):
            os.environ['PYTHONPATH'] = (
                f'{pygen_path}{os.pathsep}{existing}' if existing else pygen_path)

        self.testlist = os.path.join(runpy_target, 'testlist.yaml')
        logger.info(f'riscv-dv target {self.target} installed into the checkout')

        if os.path.isdir(self.output_dir):
            shutil.rmtree(self.output_dir, ignore_errors=True)
        os.makedirs(self.output_dir)

    def _apply_patches(self):
        """Apply local fixes to upstream riscv-dv, idempotently.

        pyflow is a partial port of the SystemVerilog generator and has real
        defects that stop most of the test list generating at all. See
        patches/README.md for what each one is. Applying them here rather than
        editing the checkout keeps them alive across a re-clone.
        """
        patch_dir = os.path.join(this, 'patches')
        if not os.path.isdir(patch_dir):
            return
        for patch in sorted(glob.glob(os.path.join(patch_dir, '*.patch'))):
            name = os.path.basename(patch)
            # --check first: a patch already applied is not an error.
            already = subprocess.call(
                ['git', '-C', self.riscv_dv_dir, 'apply', '--check', '--reverse', patch],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if already == 0:
                logger.debug(f'riscv-dv patch already applied: {name}')
                continue
            ret = subprocess.call(
                ['git', '-C', self.riscv_dv_dir, 'apply', patch],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if ret == 0:
                logger.info(f'Applied riscv-dv patch: {name}')
            else:
                logger.error(
                    f'Failed to apply riscv-dv patch {name}. The checkout at '
                    f'{self.riscv_dv_dir} may have drifted from what the patch '
                    f'expects; delete it to force a fresh clone.')
                raise SystemExit(1)

    @gen_hookimpl
    def gen(self, module_dir, output_dir):
        logger.debug('riscv-dv Gen phase')
        output_dir = os.path.abspath(output_dir)
        asm_root = os.path.join(output_dir, 'riscv_dv')
        os.makedirs(asm_root, exist_ok=True)

        pytest_file = os.path.join(this, 'gen_framework.py')
        report_file_name = '{0}/{1}_{2}'.format(
            os.path.join(output_dir, '.json/'), self.name,
            datetime.datetime.now().strftime('%Y%m%d-%H%M'))

        pytest.main([
            pytest_file,
            f'-n={self.jobs}', '-v',
            f'--riscv_dv_dir={self.riscv_dv_dir}',
            f'--target={self.target}',
            f'--isa={self.march}',
            f'--mabi={self.mabi}',
            f'--output_dir={asm_root}',
            f'--testlist={self.testlist}',
            f'--seed={self.seed}',
            f'--module_dir={this}',
            f'--html={output_dir}/reports/riscv_dv.html',
            f'--report-log={report_file_name}.json',
            '--self-contained-html',
        ])

        # riscv-dv is self-contained: its scripts/link.ld already places the
        # image at 0x80000000, and the generated assembly defines both _start
        # and tohost itself. So no boot stub and no helper linker script --
        # only user_define.h / user_init.s need to be on the include path.
        link_file = os.path.join(self.riscv_dv_dir, 'scripts', 'link.ld')
        include_dir = os.path.join(self.riscv_dv_dir, 'user_extension')

        test_list = {}
        for asm in sorted(glob.glob(f'{asm_root}/**/asm_test/*.S', recursive=True)):
            key = os.path.basename(asm)[:-2]
            work_dir = os.path.dirname(asm)
            entry = {}
            entry['isa'] = self.isa
            entry['work_dir'] = work_dir
            entry['asm_file'] = asm
            entry['generator'] = self.name
            entry['include'] = [include_dir]
            entry['cc'] = self.cc
            entry['cc_args'] = ('-static -std=gnu99 -O2 -mcmodel=medany '
                                '-fvisibility=hidden -nostdlib -nostartfiles')
            entry['linker_args'] = '-lm -lgcc -T'
            entry['linker_file'] = link_file
            entry['mabi'] = self.mabi
            entry['march'] = self.march
            entry['compile_macros'] = []
            entry['extra_compile'] = []
            entry['result'] = 'Unavailable'
            # Spike emits 5 bootrom instructions before jumping to --pc, which
            # the DUT does not execute. Same adjustment the riscof plugin makes.
            entry['ignore_lines'] = 5
            test_list[key] = entry

        if not test_list:
            logger.error('riscv-dv generated no tests')
            raise SystemExit(1)
        logger.info(f'riscv-dv produced {len(test_list)} tests')
        return test_list

    @gen_hookimpl
    def post_gen(self, output_dir):
        pass
