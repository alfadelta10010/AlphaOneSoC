# See LICENSE for details
#
# river_core generator plugin for riscv-dv driven through its pyflow backend.
#
# pyflow is the Python + PyVSC generator, so it needs no commercial
# SystemVerilog simulator. That matters here: the stock riscv-dv flow is
# SV/UVM and would require VCS, Questa or Xcelium, and Verilator cannot run
# UVM. pyflow's only real dependency is pyvsc from PyPI.
#
# Upstream pyflow is a partial, defective port of the SV generator. The fixes
# live in a fork (alfadelta10010/riscv-dv-patched, branch pyflow-fixes), one
# commit per defect with the SV it was checked against; this plugin checks out
# a pinned revision of it. Upstream's own history is intact underneath.

import os
import sys
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

DEFAULT_REPO = 'https://github.com/alfadelta10010/riscv-dv-patched.git'


class riscv_dv_plugin(object):

    @gen_hookimpl
    def pre_gen(self, spec_config, output_dir):
        '''
            Spec config fields:
              jobs            : parallel pytest workers
              riscv_dv_dir    : where the riscv-dv checkout lives (cloned if absent)
              repo            : riscv-dv fork to clone/fetch from
              version         : revision of that fork to check out (enforced every run)
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

        self.repo = spec_config.get('repo', '').strip() or DEFAULT_REPO
        # The fork revision every measurement was taken on. Unpinned, a fresh
        # box would generate from whatever the branch head happens to be.
        self.version = spec_config.get('version', '').strip()

        # Clone the fork if it is not already there. Unlike the riscof plugin
        # this does not wipe and re-clone on every run: the checkout is large
        # and nothing in it is generated per-run.
        if not os.path.isdir(os.path.join(self.riscv_dv_dir, '.git')):
            os.makedirs(os.path.dirname(self.riscv_dv_dir), exist_ok=True)
            logger.info(f'Cloning {self.repo} into {self.riscv_dv_dir}')
            ret = subprocess.call([
                'git', 'clone', '--quiet', self.repo, self.riscv_dv_dir])
            if ret != 0:
                logger.error(f'Failed to clone {self.repo}')
                raise SystemExit(1)
        else:
            logger.info(f'Reusing riscv-dv checkout at {self.riscv_dv_dir}')
        if not self.version:
            logger.warning(
                'riscv_dv version is not pinned in the ini. The checkout at '
                f'{self.riscv_dv_dir} is on whatever revision it happens to '
                'be, so two machines can generate different stimulus from the '
                'same config.')

        self._checkout_pinned()

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

    def _checkout_pinned(self):
        """Reset the checkout and put it on the pinned fork revision.

        The directory is created and owned by the plugin, so local edits in it
        are discarded: tracked files are restored and untracked ones removed
        (the target files are copied in afterwards). The pin is enforced on
        every run, not only on the first clone, and a checkout that still
        points at another remote -- e.g. one cloned from upstream
        chipsalliance/riscv-dv by an earlier version of this plugin -- is
        re-pointed at the fork so the pinned commit can be fetched.
        """
        ret = subprocess.call(
            ['git', '-C', self.riscv_dv_dir, 'checkout', '--', '.'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if ret != 0:
            logger.error(f'Could not reset the riscv-dv checkout at '
                         f'{self.riscv_dv_dir}; delete it to force a fresh clone.')
            raise SystemExit(1)
        # `git checkout` restores tracked files but leaves untracked ones
        # (generated files, stale target copies). Clean those too. This runs
        # before the target files are copied in, so removing them is harmless.
        subprocess.call(
            ['git', '-C', self.riscv_dv_dir, 'clean', '-qfd'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        origin = subprocess.run(
            ['git', '-C', self.riscv_dv_dir, 'remote', 'get-url', 'origin'],
            capture_output=True, text=True).stdout.strip()
        if origin != self.repo:
            logger.info(f'Re-pointing riscv-dv checkout origin from '
                        f'{origin or "(none)"} to {self.repo}')
            subprocess.call(
                ['git', '-C', self.riscv_dv_dir, 'remote',
                 'set-url' if origin else 'add', 'origin', self.repo],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Enforce the pin on every run, not only on the first clone. Doing it
        # only at clone time left an existing checkout on whatever revision it
        # was created with, which is the failure the pin exists to prevent --
        # and it has to happen after the reset above, or local modifications
        # block the checkout.
        if self.version:
            head = subprocess.run(
                ['git', '-C', self.riscv_dv_dir, 'rev-parse', 'HEAD'],
                capture_output=True, text=True).stdout.strip()
            # --verify --quiet: without them rev-parse echoes an unresolvable
            # argument to stdout, which reads as a resolved revision and
            # skips the fetch below.
            want = subprocess.run(
                ['git', '-C', self.riscv_dv_dir, 'rev-parse', '--verify', '--quiet',
                 f'{self.version}^{{commit}}'],
                capture_output=True, text=True).stdout.strip()
            if not want:
                logger.info(f'Fetching riscv-dv {self.version}')
                subprocess.call(
                    ['git', '-C', self.riscv_dv_dir, 'fetch', '--quiet',
                     'origin', self.version],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                want = subprocess.run(
                    ['git', '-C', self.riscv_dv_dir, 'rev-parse', '--verify', '--quiet',
                     f'{self.version}^{{commit}}'],
                    capture_output=True, text=True).stdout.strip()
            if not want:
                logger.error(
                    f'riscv-dv revision {self.version} is not resolvable in '
                    f'{self.riscv_dv_dir}; delete the checkout to re-clone.')
                raise SystemExit(1)
            if head != want:
                logger.info(
                    f'Pinning riscv-dv to {self.version} (was {head[:12]})')
                ret = subprocess.call(
                    ['git', '-C', self.riscv_dv_dir, 'checkout', '--quiet',
                     '--detach', want],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if ret != 0:
                    logger.error(f'Could not check out riscv-dv {self.version}')
                    raise SystemExit(1)
        head = subprocess.run(
            ['git', '-C', self.riscv_dv_dir, 'rev-parse', 'HEAD'],
            capture_output=True, text=True).stdout.strip()
        logger.info(f'riscv-dv checkout at {head[:12]} from {self.repo}')

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

        gen_status = pytest.main([
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
            # Each test needs its own work_dir. river_core writes dut.dump and
            # ref.dump into work_dir, and every iteration of a stream lands in
            # the same asm_test/ directory -- so using dirname(asm) gave all
            # N iterations one directory and they overwrote each other's dumps.
            # Only the last iteration of each stream survived to be compared;
            # with 50 programs across 11 streams, 39 were generated, built,
            # simulated and then silently clobbered.
            work_dir = os.path.join(os.path.dirname(asm), key)
            os.makedirs(work_dir, exist_ok=True)
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
            # Spike starts the hart at --pc directly (upstream c76d96d9, 2026-03):
            # the boot ROM is neither executed nor logged, so ref.dump begins with
            # the first program instruction, like dut.dump. Explicit 0 because
            # river_core's schema defaults ignore_lines to 4. (Spike before that
            # ran and logged 5 ROM instructions here, and this was 5.)
            entry['ignore_lines'] = 0
            test_list[key] = entry

        if not test_list:
            logger.error('riscv-dv generated no tests')
            raise SystemExit(1)

        # A stream that fails to generate simply leaves no .S behind, so it
        # disappears from the test list and from the final report -- the run
        # then looks *better*, because a failing stream stops contributing
        # failures. Say so loudly instead. Deliberately not fatal: a partial
        # suite is still worth running, as long as nobody reads the scoreboard
        # as complete.
        expected = 0
        try:
            sys.path.insert(0, this)
            from gen_framework import _load_testlist
            expected = sum(int(e.get('iterations', 0))
                           for e in _load_testlist(self.testlist,
                                                   self.riscv_dv_dir))
        except Exception as e:  # noqa: BLE001 - never break the run over this
            logger.debug(f'could not compute expected riscv-dv count: {e}')
        if expected and len(test_list) < expected:
            logger.error(
                f'riscv-dv GENERATION GAP: {len(test_list)} programs produced, '
                f'{expected} requested by the testlist -- '
                f'{expected - len(test_list)} missing. Those tests are absent '
                f'from the results entirely; they are not counted as failures. '
                f'Check the generator log in reports/riscv_dv.html.')
        elif gen_status not in (0, pytest.ExitCode.OK):
            logger.error(
                f'riscv-dv generation reported failures (pytest exit '
                f'{gen_status}) even though {len(test_list)} programs exist. '
                f'Check reports/riscv_dv.html before trusting the suite.')
        logger.info(f'riscv-dv produced {len(test_list)} tests '
                    f'(testlist asks for {expected or "?"})')
        return test_list

    @gen_hookimpl
    def post_gen(self, output_dir):
        pass
