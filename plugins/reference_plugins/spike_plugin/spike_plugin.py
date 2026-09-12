# See LICENSE for details

import os
import sys
import pluggy
import shutil
import random
import re
import glob
import datetime
import pytest

from river_core.log import logger
from river_core.utils import *
import riscv_config.isa_validator as isa_val

dut_hookimpl = pluggy.HookimplMarker('dut')


class spike_plugin(object):
    '''
        Plugin to set Spike as ref
    '''
    @dut_hookimpl
    def init(self, ini_config, test_list, work_dir, plugin_path, timeout):
        self.name = 'spike'
        logger.debug('Pre Compile Stage')

        # Get plugin specific configs from ini
        self.jobs = ini_config['jobs']

        self.filter = ini_config['filter']

        if 'archid' in ini_config:
          self.archid = ini_config['archid']
        else:
          self.archid = 0

        if 'impid' in ini_config:
          self.impid = ini_config['impid']
        else:
          self.impid = 0

        if 'hartid' in ini_config:
          self.hartid = ini_config['hartid']
        else:
          self.hartid = 0
        self.tcm = True if ini_config['tcm'].lower() in ['true'] else False
        self.mem = True if ini_config['mem'].lower() in ['true'] else False
        self.riscv_isa = ini_config['isa']
        self.mem_flags = ini_config['mem_flags']
        self.dtb = ini_config['dtb']
        self.isa = ini_config['isa']
        self.pmp_regions = ini_config['pmp_regions']
        self.pmp_granularity = ini_config['pmp_granularity']
        self.pmp_enabled = True if str(self.pmp_regions) != "0" else False
        self.resetpc = ini_config['resetpc']
        (ext_list, err, err_list) = isa_val.get_extension_list(self.isa)
        self.ext_list = ext_list
        if '64' in self.riscv_isa:
            self.xlen = 64
        else:
            self.xlen = 32
        self.timeout_period = timeout
        self.objdump_cmd = ''#riscv{0}-unknown-elf-objdump -D ref.elf > ref.disass && '.format( self.xlen)
        self.sim_cmd = 'spike'
        self.sim_args = f'--hartids={self.hartid} --log ref.dump --log-commits \
--priv={{0}} {self.mem_flags} {self.dtb} --pc={self.resetpc} --isa={{1}} \
--pmpregions={self.pmp_regions} --pmpgranularity={self.pmp_granularity} {{3}} {{2}}'

        # Hard ceiling on any file the reference run writes, in MiB. A program
        # that never terminates under spike writes ref.dump until the disk is
        # full: seven riscv_dv tests did exactly that on 2026-09-09 and wrote
        # 777 GB between them. The run timeout now bounds spike, but 600 s at
        # the observed ~1.85 GB/min is still ~18 GB per runaway, so bound the
        # file as well. 0 disables the guard.
        self.max_dump_mb = int(ini_config.get('max_dump_mb', 64))

        # Retire budget, matched to the DUT's +MAX_INSTR. It bounds the
        # COMPARISON -- ref.dump is cut to this many commit-log lines once the
        # boot-ROM prologue has been stripped -- so both models present the
        # same number of retired instructions. 0 disables the cut.
        #
        # It is deliberately NOT passed to spike as --instructions. That flag
        # is not a retire budget: sim_t::idle() charges a whole INTERLEAVE
        # (5000) chunk per call while processor_t::step() returns early on
        # every trap, so each trap forfeits the rest of its window. Measured
        # here: a program taking 39 traps still reaches its end under
        # --instructions=200005 and one taking 40 does not, and all 12 rrag
        # programs sampled (81-699 traps each) stopped at ~4k lines instead of
        # the 9k-75k they really retire. That turned passing tests into
        # failures, which is why the bound now lives in the line count.
        self.max_instr = int(ini_config.get('max_instr', 200000))

        # Runaway guard, in spike steps -- NOT retires, see above. It exists
        # for the one case the other guards miss: a program that traps forever
        # while retiring nothing, which writes no trace, so neither the file
        # cap nor the line cut can stop it. Set it far above any legitimate
        # run; timeout and the ulimit -f cap handle everything that does write.
        # 0 disables it.
        self.step_budget = int(ini_config.get('spike_step_budget', 10000000))

        self.work_dir = os.path.abspath(work_dir) + '/'
        self.test_list = load_yaml(test_list)

        self.json_dir = self.work_dir + '/.json/'
        # Check if dir exists
        if (os.path.isdir(self.json_dir)):
            logger.debug(self.json_dir + ' Directory exists')
        else:
            os.makedirs(self.json_dir)

        if shutil.which('spike') is None:
            logger.error('Spike not available in $PATH')
            raise SystemExit(1)

        self.self_test_lst = []

    @dut_hookimpl
    def build(self):
        logger.debug('Build Hook')
        make = makeUtil(makefilePath=os.path.join(self.work_dir,"Makefile." +\
            self.name))
        make.makeCommand = 'make -j1'
        self.make_file = os.path.join(self.work_dir, 'Makefile.' + self.name)
        self.test_names = []

        for test, attr in self.test_list.items():
            is_self_check = attr['self_checking']

            # skip self-checking tests
            if is_self_check:
                self.self_test_lst.append(test)
                continue

            logger.debug('Creating Make Target for ' + str(test))
            abi = attr['mabi']
            arch = attr['march']
            work_dir = attr['work_dir']
            link_args = attr['linker_args']
            link_file = attr['linker_file']
            cc = attr['cc']
            cc_args = attr['cc_args']
            asm_file = attr['asm_file']

            spike_isa = 'rv' + str(self.xlen)
            spike_isa += 'e' if 'E' in self.ext_list else ''
            spike_isa += 'i' if 'I' in self.ext_list or 'G' in self.isa else ''
            spike_isa += 'm' if 'M' in self.ext_list or 'G' in self.isa else ''
            spike_isa += 'a' if 'A' in self.ext_list or 'G' in self.isa else ''
            spike_isa += 'f' if 'F' in self.ext_list or 'G' in self.isa else ''
            spike_isa += 'd' if 'D' in self.ext_list or 'G' in self.isa else ''
            spike_isa += 'c' if 'C' in self.ext_list or 'G' in self.isa else ''
            spike_isa += 'p' if 'Zbpbo' in self.ext_list or 'Zpn' in self.ext_list or 'Zpsf' in self.ext_list else ''
            spike_isa += 'h' if 'H' in self.ext_list else ''
            spike_isa += '_zba' if 'Zba' in self.ext_list else ''
            spike_isa += '_zbb' if 'Zbb' in self.ext_list else ''
            spike_isa += '_zbc' if 'Zbc' in self.ext_list else ''
            spike_isa += '_zbs' if 'Zbs' in self.ext_list else ''
            spike_isa += '_smrnmi' if 'Smrnmi' in self.ext_list else ''
            spike_isa += '_zicntr' if 'Zicntr' in self.ext_list else ''
            spike_isa += '_zihpm' if 'Zihpm' in self.ext_list else ''
            spike_isa += '_zmmul' if 'Zmmul' in self.ext_list else ''

            spike_priv = 'm'
            if 'S' in self.ext_list:
                spike_priv += 'su'
            elif 'U' in self.ext_list:
                spike_priv += 'u'

            ch_cmd = 'cd {0} && '.format(work_dir)
            compile_cmd = '{0} {1} -march={2} -mabi={3} {4} {5} {6}'.format(\
                    cc, cc_args, arch, abi, link_args, link_file, asm_file)
            for x in attr['extra_compile']:
                compile_cmd += ' ' + x
            for x in attr['include']:
                compile_cmd += ' -I '+str(x)
            compile_cmd += ' '.join(map(' -D{0}'.format, attr['compile_macros']))
            compile_cmd += f' -o {test}.elf && '
            # The timeout must wrap the simulator, not the compiler.  It used
            # to prefix compile_cmd, which ends in '&&', so it bounded gcc --
            # a second's work -- and left spike running unbounded.  A
            # non-terminating program then ran until the disk filled.
            if self.timeout_period>=0:
                timeout_cmd = f'timeout -k 10s {int(self.timeout_period) + 5} '
            else:
                timeout_cmd = ''
            # ulimit -f counts 512-byte blocks under /bin/sh (dash), which is
            # the shell make runs recipes with, and 1 KiB blocks under plain
            # bash -- so *2048 is exactly max_dump_mb under make and at most
            # twice that if a bash ever runs it, never less. It applies to
            # every file the subshell writes, so it must wrap only the
            # spike invocation -- the compile above and the sed
            # post-processing below stay outside it. Exceeding the limit
            # kills spike with SIGXFSZ and leaves a
            # truncated ref.dump, which the comparison stage reports as a
            # failure: a bounded loss rather than a full disk.
            if self.max_dump_mb > 0:
                ulimit_cmd = f'ulimit -f {self.max_dump_mb * 2048}; '
            else:
                ulimit_cmd = ''
            n_skip = attr.get('ignore_lines', 0)
            if self.step_budget > 0:
                instr_flag = f'--instructions={self.step_budget}'
            else:
                instr_flag = ''
            target_cmd = ch_cmd + compile_cmd + self.objdump_cmd +\
                    '(' + ulimit_cmd + timeout_cmd + self.sim_cmd + ' ' + \
                    self.sim_args.format(spike_priv, spike_isa, f'{test}.elf',
                                         instr_flag) +\
                    ');'
            target_cmd += "([ -f ref.dump ]"
            if n_skip:
                target_cmd += f" && sed -i '1,{n_skip}d' ref.dump"
            # Cut to the DUT's retire budget, after the boot-ROM lines are gone
            # so both sides count the same thing. This is what actually keeps
            # the two traces comparable on a program that does not terminate.
            if self.max_instr > 0:
                target_cmd += (f" && head -n {self.max_instr} ref.dump"
                               " > ref.dump.cut && mv ref.dump.cut ref.dump")
            # Strip CSRs Spike emits but DUT does not implement (always read 0)
            target_cmd += r" && sed -i -E 's/ c[0-9]+_(mstatush|tcontrol|mtinst|mtval2|mscratchcsw|mscratchcswl|mtinstcsw) 0x[0-9a-fA-F]+//g' ref.dump"
            target_cmd += " && (sed -i '/(0x00000063)/d' ref.dump"
            target_cmd += "&& sed -i '/(0x0000006f)/d' ref.dump"
            if self.tcm or self.mem:
                target_cmd +=  " sed -i '$$d' ref.dump && "
                target_cmd +=  "sed -i '$$d' ref.dump"
            target_cmd += ") || echo \"Error: ref.dump not found\")"
            # Truncate the reference at the tohost write.
            #
            # riscv-dv ends every program with
            #     write_tohost: auipc/sw 1/c.j write_tohost
            # an intentional spin that expects the simulator to notice the
            # store and stop. The DUT's testbench stops on it immediately;
            # spike only polls HTIF every INTERLEAVE (5000) instructions, so
            # it spins ~4900 more retires first. Measured on
            # riscv_ebreak_test_0: the store is at line 202 of both dumps,
            # dut.dump ends at 206 lines, ref.dump runs to 5121 and repeats
            # the same store 1640 times. The traces agree on every
            # architectural fact and disagree only about where to stop, which
            # failed all 50 riscv_dv tests.
            #
            # Cutting both dumps at the first tohost store removes the spin
            # symmetrically. The DUT side does the same in its own plugin.
            # Keyed off the tohost *symbol*, not a '.tohost' section: riscv-dv
            # puts tohost in .data, which is why the older section-based
            # attempt below never fired for it.
            target_cmd += f" ; TOHOST=$$(riscv64-unknown-elf-readelf -s {test}.elf"
            target_cmd += " | awk '$$8==\"tohost\"{print $$2}')"
            target_cmd += " ; [ -n \"$$TOHOST\" ] && [ -f ref.dump ] &&"
            target_cmd += " awk -v p=\"mem 0x$$TOHOST\" 'index($$0,p){print; exit} {print}'"
            target_cmd += " ref.dump > ref.dump.tmp && mv ref.dump.tmp ref.dump"
            # if not self.is_tcm:
            #   target_cmd += " && sed -i '$$d' ref.dump;"
            # else:
            #   target_cmd += f'''; head -n $$(grep -n  $$(readelf -s {test}.elf | grep \'\.tohost\' | awk \'{{split($$0,a,\" \"); print a[2]}}\') ref.dump | awk \'{{split($$0,a,\":\"); print a[1]-1}}\') ref.dump > temp && mv temp ref.dump'''
            if self.tcm or self.mem:
                target_cmd += f"&& HEXVALUE=0x$$(readelf -S {test}.elf | grep '.tohost' | awk \'{{print $$5}}\')"
                target_cmd += f' && [ -n "$$HEXVALUE" ] &&'
                target_cmd += f'''awk -i inplace "/mem $$HEXVALUE/{{found=1}} found{{next}} {{print}}" ref.dump'''
                target_cmd += ";"
            make.add_target(target_cmd, test)
            self.test_names.append(test)

    @dut_hookimpl
    def run(self, module_dir):
        logger.debug('Run Hook')
        logger.debug('Module dir: {0}'.format(module_dir))
        pytest_file = module_dir + '/spike_plugin/gen_framework.py'
        logger.debug('Pytest file: {0}'.format(pytest_file))

        report_file_name = '{0}/{1}_{2}'.format(
            self.json_dir, self.name,
            datetime.datetime.now().strftime("%Y%m%d-%H%M"))

        # run only if there are tests to be run
        if self.test_names:

            # TODO Regression list currently removed, check back later
            # TODO The logger doesn't exactly work like in the pytest module
            pytest.main([
                pytest_file,
                '-n={0}'.format(self.jobs),
                '-k={0}'.format(self.filter),
                '--html={0}.html'.format(self.work_dir + '/reports/' + self.name),
                '--report-log={0}.json'.format(report_file_name),
                '--work_dir={0}'.format(self.work_dir),
                '--make_file={0}'.format(self.make_file),
                '--key_list={0}'.format(self.test_names),
                # TODO Debug parameters, remove later on
                '--log-cli-level=DEBUG',
                '-o log_cli=true',
                '--timeout={0}'.format(self.timeout_period)
            ])
            # , '--regress_list={0}'.format(self.regress_list), '-v', '--compile_config={0}'.format(compile_config),

            return report_file_name
        else:
            return None

    @dut_hookimpl
    def post_run(self, test_dict, config):
        if str_2_bool(config['river_core']['space_saver']):
            logger.debug("Removing artifacts for Spike")
            for test in test_dict:
                if test_dict[test]['result'] == 'Passed':
                    logger.debug("Removing extra files for Test: " + str(test))
                    work_dir = test_dict[test]['work_dir']
                    try:
                        os.remove(work_dir + '/ref.disass')
                        os.remove(work_dir + '/ref.dump')
                    except:
                        pass
#                        logger.info(
#                            "Something went wrong trying to remove the files")
