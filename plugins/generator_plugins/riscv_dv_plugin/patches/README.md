# Local patches to upstream riscv-dv (pyflow backend)

pyflow is a partial Python port of riscv-dv's SystemVerilog generator, and
these are genuine upstream defects, not FyraCore configuration problems. The
plugin applies them after cloning, idempotently, so they survive a re-clone.

Each is checked with `git apply --check` first and skipped if already applied.

- `01-callstack-gen-self.patch`
  `riscv_asm_program_gen.py` assigns `callstack_gen` to a local and then calls
  `self.callstack_gen.init(...)` on the next line, which does not exist:

      AttributeError: 'riscv_asm_program_gen' object has no attribute 'callstack_gen'

  Fires whenever `num_of_sub_program > 0`, which is most of the test list.

- `02-basic-instr-enum-names.patch`
  `riscv_instr.instr_template` is keyed by `riscv_instr_name_t` members, but
  `build_basic_instruction_list` appends the plain strings "EBREAK", "C_EBREAK",
  "DRET" and "WFI". `get_rand_instr` then does `instr_template[name]` and raises:

      KeyError: 'EBREAK'

  Only reachable when a test clears `no_ebreak`, `no_dret` or `no_wfi`, which is
  why the default streams do not hit it and `riscv_ebreak_test` does.
