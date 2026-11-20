# River Core DUT Plugin for FyraCore using Verilator (--binary --timing)
#
# A subclass of the Icarus plugin (fyracore_iverilog_plugin): the config, the Make flow, the
# report and the clean-up are shared; only how the simulator is built and started differs.

import importlib.util
import os

from river_core.log import logger  # noqa: F401  (the base class logs through it)

_BASE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     'fyracore_iverilog_plugin', 'fyracore_iverilog_plugin.py')
_spec = importlib.util.spec_from_file_location('fyracore_iverilog_plugin_base', _BASE)
_base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_base)


class fyracore_verilator_plugin(_base.fyracore_iverilog_plugin):
    """River Core DUT plugin for FyraCore on Verilator."""

    SIM = 'verilator'
    TOOLS = ['verilator']
    START = './sim_fyracore'
    BUILD_TIMEOUT = 1200

    # --timing keeps the testbench's '#' delays and the memory model's event control as written,
    # so the model is timing-accurate and the traces are the ones Icarus gives. No rewrite to
    # clocked logic. The binary is rebuilt on every run, so it always matches the RTL on disk;
    # Verilator's own make is incremental and ccache is used when present, so an unchanged tree
    # costs seconds, not the ~40 s of a cold g++ build.
    def build_command(self, sim_binary, src_files, tb_files):
        obj_dir = os.path.join(self.sim_path, 'obj_dir')
        return (f'verilator --binary --timing -j 0 -Wno-fatal -Wno-lint '
                f'-Wno-style -Wno-WIDTH -Wno-TIMESCALEMOD '
                f'--top-module tb_rivercore -Mdir {obj_dir} '
                f'-o ../sim_fyracore '
                f'{src_files} {tb_files}')

    def before_build(self):
        # A stale binary must not survive a failed build.
        if os.path.isfile(self.sim_binary):
            os.remove(self.sim_binary)
