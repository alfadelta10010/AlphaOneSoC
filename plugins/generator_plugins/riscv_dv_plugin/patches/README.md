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

- `03-riscv-program-name-arg.patch`
  `riscv_callstack_gen.init()` constructs each program as `riscv_program(name)`,
  but `riscv_program.__init__` takes only `self`:

      TypeError: riscv_program.__init__() takes 1 positional argument but 2 were given

  Same trigger as 01: any test with `num_of_sub_program > 0`.

- `04-honor-exclude-instr.patch`  **(the SolveFailure)**
  `riscv_instr.get_rand_instr()` builds a `disallowed_instr` list and then never
  uses it. The SystemVerilog original constrains the draw with
  `!(name inside {disallowed_instr})` (`src/isa/riscv_instr.sv:230-232`); the
  Python `else` branch just does `random.choice(allowed_instr)`.

  Consequence: `riscv_instr_stream.randomize_instr()` correctly asks to exclude
  `C_ADDI16SP` / `C_ADDI4SPN` / `C_LWSP` / `C_LDSP` when SP is reserved, the
  exclusion is dropped, and `C_ADDI16SP` comes back. Its own constraint
  (`riscv_compressed_instr.py:52-53`, block `rvc_csr_c`) pins `rd == SP`, while
  `randomize_gpr()` (`riscv_instr_stream.py:252`) asserts `rd != reserved_rd[i]`
  where `reserved_rd[0]` is the SP the load/store stream just reserved
  (`riscv_load_store_instr_lib.py:115`). That is `rd == 2 AND rd != 2`:

      vsc.model.solve_failure.SolveFailure: solve failure
      Problem Set: 2 constraints
        if ((instr_name == 242)) { (rd == 2); }
        (rd != reserved_rd.reserved_rd[0]);

  The same patch fixes two things that made the exclusion unusable anyway:
  `randomize_instr()` put `.name` *strings* into `exclude_instr` while every
  other list holds `riscv_instr_name_t` members (same defect class as 02), and
  `setup_allowed_instr()` aliased the class-level `riscv_instr.basic_instr`
  instead of copying it, so each `.extend()` permanently grew the shared list.

  Not a pyvsc problem: the constraint set is a literal contradiction, so no
  solver version can satisfy it. Note upstream already guards the *global* case
  at `riscv_instr.py:154-156` (skip C_ADDI16SP when SP is in `cfg.reserved_regs`);
  it is the *per-stream* `reserved_rd` path that relied on the broken exclusion.

- `05-loop-instr-constraints.patch`
  Three defects in `riscv_loop_instr.post_randomize()`:

  1. The loop init/update instructions were drawn with a bare
     `get_rand_instr()` (any instruction at all) and then constrained to
     `rd == loop_cnt_reg`, `rs1 == ZERO`, `imm == <val>`. The SV original draws
     `include_instr({ADDI})`; the port commented that out. Most draws are
     unsatisfiable, giving "Cannot randomize loop init1/init2 instruction".
  2. The remaining constraints subscript vsc lists *inside* `randomize_with()`,
     which trips a real pyvsc bug — `rand_info_builder.py:317` in
     `visit_expr_array_subscript()` does `self._randset_m.pop(idx)` where `idx`
     is an `int` but `_randset_m` is keyed by `RandSet` objects (the equivalent
     code for a plain field reference, line 407, correctly pops by object):

         KeyError: 3

     This bug is present in every published pyvsc from 0.7.9 to 0.9.5, so it
     cannot be pinned around. The patch reads the solved list elements into
     plain Python ints *before* entering `randomize_with()`, which avoids
     building an array-subscript expression at all. That in turn lets the
     "update loop counter" and "branch rs2 == loop_limit_reg" constraints be
     restored, so generated loops actually count and have a real exit condition.
  3. `build_loop_instr_stream()` appended `self.loop_instr[i]` — an element of
     the list it was building, which for i == 0 is the *counter init*. That put
     "init loop counter" inside the loop body, so the counter was reset every
     iteration and the generated loop never terminated. Rewritten to wrap the
     inner loop the way `src/riscv_loop_instr.sv:194-199` does.

- `06-surface-worker-exit.patch`
  `riscv_instr_base_test.run_phase()` catches `Exception`, but `pygen_src` has
  41 `sys.exit(1)` call sites, which raise `SystemExit` — a
  `BaseException`. It escaped the handler, killed the `multiprocessing.Pool`
  worker outright, and left `pool.map()` blocked forever, so the generator hung
  silently with no error instead of failing. Observed in practice as a
  `riscv_loop_test` generator stuck for 21 hours at 0% CPU. Catching
  `BaseException` turns those into a normal "Test-generation jobs failed" in
  seconds. Worth keeping even if the underlying aborts are all fixed.

- `07-rand-instr-test-cfg.patch`
  `riscv_rand_instr_test.randomize_cfg()` hardcoded `cfg.instr_cnt = 10000` and
  `cfg.num_of_sub_program = 5`, discarding the `+instr_cnt` / `+num_of_sub_program`
  values the testlist passes. Worse, both are plain Python ints referenced from
  the `default_c` constraint (`riscv_instr_gen_config.py:319-323`), which pyvsc
  elaborated with the value the attribute held when `cfg` was built from argv —
  the late assignment never reached the solver. So `num_of_sub_program` was 5
  for `gen_sub_program()`'s loop while `sub_program_instr_cnt` was still sized
  from the command line, and every test with `gen_test: riscv_rand_instr_test`
  died at `riscv_asm_program_gen.py:217`:

      IndexError: list index out of range

  That was 6 of the 13 streams (no_fence, illegal_instr, ebreak, full_interrupt,
  non_compressed, hint). The command line already carries both values, so the
  fix is simply to honour it.

- `08-hazard-instr-stream.patch`
  `riscv_hazard_instr_stream` (`src/riscv_load_store_instr_lib.sv:283-301`) was
  never ported, so `riscv_utils.factory()` aborted with "Cannot Create object of
  riscv_hazard_instr_stream" for any testlist that requests it — including the
  stock `riscv_rand_instr_test`. Ported and registered in the factory. The SV
  version also narrows `num_of_avail_regs` to 6; that is deliberately not
  mirrored, because pyflow's `randomize_avail_regs()` is still an unimplemented
  `pass`, so it would have no effect.

- `09-illegal-instr-retry.patch`
  `riscv_illegal_instr`'s constraint model intermittently fails to solve — about
  half of all draws. Measured over 10 full generations each: rv32imac 4/10,
  rv32imac with RV32A removed 5/10. That is within noise of each other, so it is
  **not** caused by the A extension or any other FyraCore target setting, and it
  predates the local patches. pyvsc cannot produce an unsat core for it either:
  `create_diagnostics()` gives up with "internal error: system should solve"
  (`randomizer.py:443`), meaning each randset solves individually and only the
  combination does not — a solver-ordering artifact, not a real contradiction.

  `insert_illegal_hint_instr()` (`riscv_instr_sequence.py:285`) randomized once
  with no retry, so one unlucky draw aborted the entire test. The patch retries
  up to 20 times and skips that one injected instruction if it still fails.
  Retrying re-draws under the identical constraint set, so anything produced is
  still a fully constrained, valid encoding — the retry only discards draws the
  solver gave up on, it cannot weaken the stimulus.

  Result: `riscv_illegal_instr_test` went from 4/10 to 8/8, with no
  "Could not randomize" warnings (every retry succeeded well inside the budget).
  The underlying constraint model is left alone deliberately: it is 368 lines of
  interlocking encoding constraints, and "fixing" it without a reproducible unsat
  core risks emitting encodings that are actually legal, which would show up as
  false RTL failures — worse than a flaky generator.

- `10-load-store-allowed-instr-reset.patch`
  `riscv_load_store_base_instr_stream.gen_load_store_instr()` builds the list of
  instructions legal for each address. The SV original assigns it fresh at the
  top of every `foreach (addr[i])` iteration
  (`src/riscv_load_store_instr_lib.sv`, `allowed_instr = {LB, LBU, SB};`); the
  port `extend()`s a list created once before the loop, so the allowed set
  **accumulates across addresses**. An instruction whose alignment/offset
  precondition held for an earlier address stayed selectable for a later one
  that violated it, and the generator emitted encodings that do not exist:

      Error: illegal operands `c.swsp t2,23(sp)'     (C.SWSP takes uimm 0..252, x4)
      Error: illegal operands `c.swsp t2,-184(sp)'

  Only visible once the load/store streams could run at all, so it was masked by
  the SolveFailure. Caught by assembling the generated tests rather than just
  checking that generation exited 0 — worth doing routinely:

      riscv64-unknown-elf-gcc -c -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
          -I <riscv-dv>/user_extension -x assembler <test>.S -o /dev/null

  After the fix, 5/5 generated `riscv_rand_instr_test` programs assemble with
  zero errors (3 errors per program before).

## Still broken upstream (not patched)

- `riscv_multi_page_load_store_instr_stream` and `riscv_mem_region_stress_test`
  are also missing from pyflow. They are the two directed streams
  `riscv_mmu_stress_test` asks for. They were not ported: both exist to stress
  data-TLB switching, and FyraCore is `SATP_MODE = BARE` with no MMU, so the
  stimulus has no value here. Drop those two `+directed_instr_*` options from
  the testlist entry (or the whole entry) rather than porting them.

- `riscv_pmp_test` cannot work: pyflow implements none of the `--pmp_*` options,
  so `run.py` dies at argparse with "unrecognized arguments: --pmp_randomize=0".
  `riscv_pmp_cfg` exists only in the SystemVerilog source; the pyflow config has
  a single `pmp_reg` field and a commented-out `riscv_pmp_cfg` TODO. This is a
  missing feature, not a defect — leave the test at `iterations: 0` until
  someone ports `riscv_pmp_cfg`.

## pyvsc version

pyvsc is unpinned in riscv-dv's `requirements.txt`. The installed version,
0.9.5.27214109393, is the newest on PyPI. Pinning an older one does not help:
the `rand_info_builder.py` `_randset_m.pop(idx)` bug behind patch 05 is present
unchanged in 0.7.9, 0.8.9, 0.9.3, 0.9.4 and 0.9.5, and none of the other
defects above are solver-related at all.
