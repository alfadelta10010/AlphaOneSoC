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
  `riscv_illegal_instr`'s constraint model does not solve under the installed
  pyvsc. Not intermittently: an *unconstrained*
  `riscv_illegal_instr.randomize()` fails **200/200** for this target, and 50/50
  on the stock `rv32imc` and `rv32i` targets too, so it is a pyflow/pyvsc
  incompatibility rather than anything about FyraCore or the A extension.

  `insert_illegal_hint_instr()` (`riscv_instr_sequence.py:285`) randomized once
  with no retry, so a failed draw aborted the entire test. The patch retries up
  to 20 times and skips that one injected instruction if it still fails.
  Retrying re-draws under the identical constraint set, so anything produced
  would still be a fully constrained, valid encoding — the retry only discards
  draws the solver gave up on, it cannot weaken the stimulus.

  **What the retry does and does not buy.** It converts an abort into a skip,
  which is worth keeping. It does not inject anything: with a real injection
  count every draw fails, ten times over, logging
  `Could not randomize riscv_illegal_instr in 20 attempts`. So
  `riscv_illegal_instr_test` and `riscv_hint_instr_test` are set to
  `iterations: 0` in the target testlist — see the note there. Watch for this
  shape when reading the log: the injection count is announced *before* the
  loop runs, so "Injecting 10 illegal instructions" says nothing about whether
  any were placed. Check the generated `.S` for `.4byte`/`.2byte` instead.

  The constraint model is left alone deliberately. pyvsc cannot produce an unsat
  core for it — `create_diagnostics()` gives up with "internal error: system
  should solve" (`randomizer.py:443`), meaning each randset solves individually
  and only the combination does not — and it is 368 lines of interlocking
  encoding constraints. "Fixing" it without a reproducible core risks emitting
  encodings that are actually legal, which would surface as false RTL failures,
  worse than no test at all.

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

- `11-testlist-override-dedupe.patch`
  `process_regression_list()` (`scripts/lib.py`) appends *every* entry whose test
  name matches, so a testlist that imports `base_testlist.yaml` and then
  overrides an entry queues that test **twice** -- once with upstream's
  `gen_opts` and once with the local ones. Both invocations are handed the same
  `--asm_file_name` and the same `--log_file_name`, so the first is pure waste
  and its output is clobbered by the second.

  For this target that was fatal rather than merely wasteful. Upstream's
  `riscv_mmu_stress_test` entry asks for `riscv_multi_page_load_store_instr_stream`
  and `riscv_mem_region_stress_test`, and every upstream entry uses
  `+num_of_sub_program=5`. The upstream copy ran first and ate the whole 1200s
  pyflow generation budget, so `run.py` was killed before the local entry ever
  started:

      $ ls build/mywork/riscv_dv/*/asm_test/*.S
      (nothing, for all 12 streams)

  A zero-iteration override also did not disable the imported entry, because the
  `entry['iterations'] > 0` guard skipped it before it could take effect -- so
  `riscv_ebreak_debug_mode_test` and `riscv_unaligned_load_store_test` were still
  live under `--test all` despite being explicitly zeroed in the target testlist.

  The patch makes a later entry replace an earlier one with the same test name,
  and makes a zero-iteration override remove it. After it, `riscv_ebreak_test`
  generates in 15s instead of timing out at 1200s.

- `12-pyflow-sim-cmd-placeholder.patch`
  `do_simulate()` (`run.py`) substitutes the `<test_name>` placeholder with
  `re.sub(..., sim_cmd)` and assigns the result **back to `sim_cmd`**. The
  placeholder is consumed on the first iteration, so every later test in the
  matched list re-runs the *first* test's generator script. Substituting into a
  local leaves the template intact. Only reachable with more than one entry in
  the list, which is why patch 11 and this one are separate defects with the same
  trigger.

- `13-privileged-csr-addresses.patch`
  18 entries in pyflow's `privileged_reg_t` (`riscv_instr_pkg.py`) carry the wrong
  CSR address. Checked against both `src/riscv_instr_pkg.sv` in the same tree and
  the privileged spec:

  * `MCOUNTINHIBIT = 0x320F`, should be `0x320`. That is not even a 12-bit CSR
    address, so any instruction generated for it fails to assemble outright.
    FyraCore implements `mcountinhibit`, so this is on the live path.
  * `MHPMCOUNTER16H` .. `MHPMCOUNTER31H` are each one too low (`0xB8F`..`0xB9E`
    instead of `0xB90`..`0xB9F`) -- an omitted entry shifted the whole block, so
    each name denotes its predecessor's register.
  * `SCONTEXT = 0x7AA`, should be `0x5A8` (the `0x7AA` encoding is from a
    superseded debug-spec draft).

  `MCONFIGPTR` (`0xF15`) was missing from the Python enum entirely though it is
  present in the SystemVerilog one. FyraCore implements it (`src/csr.v`, `12'hF15`),
  so it has to exist as a name before it can be listed in `implemented_csr`.

  These matter beyond assembling: `implemented_csr` is used as the *exclusion*
  list for illegal-CSR stimulus, so a CSR the enum cannot name is a CSR the
  generator will happily target as "illegal" against a core that implements it.

- `14-load-store-offset-in-page.patch`
  `randomize_offset()` must produce two things that agree: `offset`, emitted as
  the instruction's immediate, and `addr`, which `gen_load_store_instr()`
  consults to decide which access widths are alignment-legal. The SV solves them
  together (`src/riscv_load_store_instr_lib.sv`):

      addr_ == base + offset_;
      addr_ inside {[0 : max_load_store_offset - 1]};

  The port dropped both, drawing
  `addr_ = random.randrange(base + offset_ - 1, base + offset_ + 1)`, which
  returns `base + offset_ - 1` or `base + offset_` with equal probability and
  never bounds the result. Over 800k draws against a 4096-byte page:

  * 50.0% of addresses were one byte below the address the instruction really
    forms, so the alignment decision concerned the wrong address;
  * 12.5% were selected as 4-byte aligned when the real address is not --
    FyraCore has `support_unaligned_load_store = 0`, so those take a misaligned
    trap the stream never intended;
  * 7.3% fell outside the data page, where the DUT and Spike need not agree.

  Fixed by intersecting the locality range with the offsets that keep
  `base + offset` in the page, rather than rejection-sampling; `addr_c` already
  bounds `base`, so the interval always contains 0. The four locality bounds are
  also made inclusive at the top, as the SV `inside {[lo:hi]}` is.

  This makes the *inputs* to the alignment decision correct. It is not on its
  own enough to make the generated accesses aligned: patch 24 fixes a second
  defect that was bypassing the alignment gates entirely. Both are needed, and
  neither is visible to the assembler — measure alignment from the generated
  assembly, not from a clean build.

- `15-hazard-per-access-draw.patch`
  `riscv_load_store_hazard_instr_stream.randomize_offset()` hoisted the
  per-access hazard draw out of the loop. The SV has

      if ((i > 0) && ($urandom_range(0, 100) < hazard_ratio))

  inside `foreach`, so each access independently repeats its predecessor's
  address or picks a fresh one. With one draw deciding the whole stream and
  `hazard_ratio` constrained to `[20:100]`, roughly 60% of streams collapsed to
  every access using one identical address and the other 40% had no address
  hazard at all -- only the two degenerate cases, never the mix the stream
  exists to produce. Its fresh-address branch also carried the patch-14 defect.

- `16-port-multi-page-streams.patch`
  `riscv_multi_page_load_store_instr_stream` and `riscv_mem_region_stress_test`
  (`src/riscv_load_store_instr_lib.sv:355-438`) were never ported, so
  `riscv_utils.factory()` aborted with "Cannot Create object of ..." for any
  testlist requesting them -- including upstream's own `riscv_rand_instr_test`
  and `riscv_mmu_stress_test`.

  The SV randomises `num_of_instr_stream`, `data_page_id[]` and `rs1_reg[]`
  together under `unique` constraints over dynamically sized arrays, the shape
  pyvsc handles worst (the array-subscript `KeyError` behind patch 05). The
  selection is done in plain Python; the constraints are small and exact, so
  nothing is lost. Each sub-stream's 5..10 bound goes through `randomize_with`
  rather than by assigning `min_instr_cnt`/`max_instr_cnt` as the SV does --
  those are plain ints baked into `legal_c` at build time, so a later assignment
  would not reach the solver (the defect behind patch 07).

- `17-load-store-rs1-legal.patch`
  `rs1_c` (`src/riscv_load_store_instr_lib.sv:54-56`) constrains the base
  register of every load/store stream:

      !(rs1_reg inside {cfg.reserved_regs, reserved_rd, ZERO});

  The port left it commented out with a TODO, so nothing stopped the solver
  picking a register the stream must not touch:

  * `rs1_reg == ZERO` emits `la zero, region_1+3609`, which the assembler
    rejects -- the whole program is lost.
  * `rs1_reg` in `cfg.reserved_regs` -- which is `{cfg.tp, cfg.sp,
    cfg.scratch_reg}`, and those three are **themselves randomized per program**,
    so they are whichever registers this program chose for the stack pointer,
    thread pointer and trap scratch -- rewrites that register with a data page
    address. It still assembles and still runs, so it is reported as a pass,
    while everything after it executes on a stack pointer aimed into the data
    section, trap handlers included.

  Measured on a generated `riscv_mmu_stress_test` with 496 base-register
  initialisations and a reserved set of `{s9, a4, t6}`: 4 used `x0` and 21 used
  one of the three. A comparable program afterwards, with 589 initialisations,
  used neither.

  The companion guard in `pre_randomize` is wrong too. The SV asks
  `if (SP inside {cfg.reserved_regs, reserved_rd})`; the port wrote
  `SP in [cfg.reserved_regs, self.reserved_rd]`, which tests whether SP *is* one
  of those two list objects and is therefore always False.

  Read that guard carefully, because the names are misleading. It tests the
  architectural `SP`/x2, while `cfg.reserved_regs` holds `cfg.sp` — which is
  *itself a randomized GPR* (`sp_tp_c`; `fix_sp` defaults to 0), rarely x2.
  Across 60 generated programs `cfg.sp` was never x2, so the guard is meant to
  fire in roughly 2% of programs, and `C_LWSP`/`C_SWSP` stay reachable from
  these streams — the same corpus contains 145 `c.lwsp` and 192 `c.swsp`. The
  same distinction applies when reading generated assembly: the ABI name `sp`
  appearing as a load/store base is not by itself a defect, only a hit on that
  program's actual `cfg.reserved_regs` is.

  Verified after the fix: 0 of 1996 base-register initialisations use ZERO or
  the program's own reserved set.

  Enforcing `rs1_c` as a pyvsc constraint hits the build-order problem the
  original TODO describes, so it is applied to the solved value in
  `legalize_rs1()`, called first thing in `post_randomize()`.

- `18-port-pmp-cfg.patch`
  pyflow had no PMP support whatsoever. `riscv_instr_gen_config.py` carried only
  `# pmp_cfg = riscv_pmp_cfg  # TODO`, `setup_pmp()` and `gen_pmp_csr_write()` in
  `riscv_asm_program_gen.py` were `pass`, and none of the `--pmp_*` options
  existed. argparse rejects any command line containing options it does not
  know, so the test died before the generator started:

      unrecognized arguments: --pmp_randomize=0 --pmp_num_regions=4

  Ported from `src/riscv_pmp_cfg.sv`, deliberately not in full:

  * **Deterministic path only.** `pmp_randomize=1` is rejected with a clear
    message rather than silently generating nothing. The randomized path is ~90
    lines of interlocking constraints over a dynamically sized array -- the
    shape pyvsc handles worst -- and a subtly wrong region set produces access
    faults that look like RTL bugs.
  * **No ePMP.** `support_epmp` gates ~150 lines of `gen_pmp_instr`, all of it
    writing `mseccfg` for Smepmp, which FyraCore does not implement.
  * **No `gen_pmp_exception_routine`.** It exists to recover from a PMP fault by
    widening the offending region, which only matters under randomization.

  One deliberate deviation, marked in the code: `assign_default_addr_offset`
  divides by `(num_regions - 1)`, a division by zero in the default
  single-region case, so it is guarded to return 0.

  `gen_pmp_write_test` is the part that earns its keep here. It `csrrw`s a
  random value into every `pmpaddr` and `pmpcfg` and then restores it, so the
  previous contents land in a GPR each time and a WARL difference between the
  DUT and the reference shows up in the compared trace instead of being
  absorbed. The random `pmpcfg` values never set a lock bit, never encode
  `W=1` with `R=0`, and always leave byte 0 as `0x0f` so the safe region stays
  accessible.

- `19-rawmode-category-constraint.patch`
  `riscv_instr.pre_randomize()` does, inside `vsc.raw_mode()`:

      if self.category != riscv_instr_category_t.CSR:
          self.csr.rand_mode = False

  `self.category != <enum>` on a vsc field builds a constraint *expression*
  rather than a Python bool, and `pre_randomize()` runs inside the
  `randomize_with()` scope opened by `riscv_instr_stream.randomize_gpr()`. The
  expression was collected into that solve as a real constraint:

      vsc.model.solve_failure.SolveFailure: solve failure
      Problem Set: 1 constraints
        (category != 11);

  True for every non-CSR instruction, which is why it went unnoticed; category
  11 is CSR, so for a CSR instruction it is a flat contradiction. Use
  `get_val()`. (`int()` does not work -- a non-rand `enum_t` has no `__int__`.)

- `20-generate-csr-instructions.patch`
  Zicsr was entirely unexercised. Four independent defects, each sufficient on
  its own to prevent any CSR instruction being generated or being correct:

  * `build_basic_instruction_list` compares `cfg.init_privileged_mode`, a
    `privileged_mode_t`, against the **string** `"MACHINE_MODE"`. Always False.
  * the same line `append()`s `instr_category["CSR"]`, a *list*, as a single
    element (same for `"SYNCH"`); `get_rand_instr()` then indexes
    `instr_template` with a list. Changed to `extend()`.
  * `create_csr_filter` appends the strings `"MSCRATCH"`/`"SSCRATCH"`/
    `"USCRATCH"` where a `privileged_reg_t` is needed -- the value goes into the
    instruction's `csr` field -- compares against a string again, and aliases
    `rcs.implemented_csr` instead of copying it, so its own `clear()` would
    empty the core setting.
  * `convert2asm` formats the address as `'0x{}'` with the value in **decimal**,
    so mscratch (832 == 0x340) was emitted as the unrelated CSR `0x832`. Every
    CSR address the generator produced was wrong.

  `include_reg`/`exclude_reg` were also populated and read by nothing: pyflow
  has no `riscv_csr_instr` class and its `csr_c` is an empty `pass`, so the
  address was a uniform draw over all 4096 encodings -- a random value into
  whichever machine CSR it happened to land on. `legalize_csr()` applies
  `csr_addr_c` from `src/isa/riscv_csr_instr.sv` to the solved value, honouring
  the default filter (MSCRATCH only, chosen upstream precisely so a random
  stream cannot disturb machine state).

- `21-instruction-draw-off-by-one.patch`
  `random.randrange(0, n - 1)` yields `0..n-2`, so the last element was
  unreachable at four call sites. The worst is `get_load_store_instr()`:
  `gen_load_store_instr()` builds `allowed_instr` in alignment order and appends
  the widest legal access last, so the widest access for each address was never
  chosen -- and where only `[LB, LBU, SB]` was legal, `SB` was removed and the
  stream could not emit a byte store at all. The same expression also raises
  `ValueError` on a single-element list.

  These four are not all of them; patch 25 covers five more of the same
  mistranslation elsewhere in the port. Treat `$urandom_range(a, b)` — whose
  upper bound is inclusive — as a standing grep whenever touching pyflow.

- `22-fence-instruction-gating.patch`
  `create_instr_list` dropped the negation from the `enable_sfence` test and the
  `cfg.no_fence &&` guard from the FENCE/FENCE_I/SFENCE_VMA skip, so FENCE and
  FENCE.I were struck from the instruction set unconditionally. FyraCore
  implements Zifencei and asserts `fencei_flush` on FENCE.I; none of it was
  reachable. Corrected together with the missing `enable_sfence` implication
  from `src/riscv_instr_gen_config.sv:293-295`, because restoring the guard
  alone would emit `sfence.vma` on a core with `support_sfence = 0`.

- `23-no-fence-default.patch`
  `--no_fence` defaults to 1 in the port and 0 in the SystemVerilog, so fences
  were suppressed everywhere -- including in the streams meant to contrast with
  `riscv_no_fence_test`. After 22 and 23, a `riscv_rand_instr_test` program
  carries 210 fences and `riscv_no_fence_test` carries none.

- `24-unaligned-fallback-binding.patch`
  `src/riscv_load_store_instr_lib.sv:139-188` is

      if (!cfg.enable_unaligned_load_store) begin
        if (addr[i][0] == 1'b0)                 ... LH, LHU, SH
        if (addr[i] % 4 == 0)                   ... LW, SW
        if ((XLEN >= 64) && (addr[i] % 8 == 0)) ... LWU, LD, SD
      end else begin // unaligned load/store
        allowed_instr = {LW, SW, LH, LHU, SH, allowed_instr};

  The port indented that `else` one level deeper, binding it to the **XLEN**
  test. On RV32 `XLEN >= 64` is always false, so the unaligned fallback ran for
  every address on an aligned-only target and unconditionally re-added
  LW/SW/LH/LHU/SH, bypassing the two alignment gates above it.

  Measured over the 60 generated programs, counting only accesses inside a
  self-contained directed block: **65.3% of word and 40.9% of half-word accesses
  were misaligned**, on a core with `support_unaligned_load_store = 0`. Both DUT
  and reference trap and jump to `test_done`, so the run still reported a pass.
  After the fix, `riscv_rand_jump_test` (which mixes no streams) measures 0/52.

  This is what patch 14 was reaching for. Patch 14 corrected the `addr`/`offset`
  relationship — necessary, but the gates it made accurate were being bypassed
  entirely.

- `25-more-urandom-range-off-by-one.patch`
  Patch 21 fixed four `randrange(0, n-1)` sites; there were five more of the
  same `$urandom_range(a, b)` (inclusive) → `randrange(a, b)` (exclusive)
  mistranslation:

  * `riscv_amo_instr_lib.py` — `randrange(0, max_data_page_id - 1)` with
    `cfg.amo_region` holding exactly one region is `randrange(0, 0)`, which
    **raises ValueError**. Every AMO stream aborted on construction.
  * `riscv_instr_sequence.py` — `rand_lsb` always 0, so the odd-LSB path that
    checks JALR ignoring bit 0 of the target was never generated.
  * `riscv_directed_instr_lib.py` — `enable_branch` always 0; the push-stack
    sequence never contained a branch.
  * `riscv_callstack_gen.py` — `randrange(size, size+1)` always returns `size`,
    disabling the "duplicate a sub-program" case. **One line above a site patch
    21 did fix.**
  * `riscv_data_page_gen.py` — `randrange(0, 255)` never returns `0xFF`, so an
    all-ones byte never appeared in a random data page. That is exactly the
    value a sign-extension or mask bug shows up on.

- `26-instr-template-deepcopy.patch`
  **The one that made most of the suite meaningless.** `riscv_instr`'s operand
  fields (`rs1`, `rs2`, `rd`, `imm`) are pyvsc field objects living in the
  instance `__dict__`, so `copy.copy(cls.instr_template[name])` in
  `get_load_store_instr()` and `get_instr()` hands every instance of a mnemonic
  the *same* field objects as the template. `gen_load_store_instr()`'s
  `instr.rs1 = self.rs1_reg` therefore rewrites the base register of every
  load/store of that mnemonic already emitted, anywhere in the program.

  The visible symptom: each load/store stream starts with
  `la <regA>, region_N+<off>` to set up its base, and then its accesses use
  `<regB>` — whichever register the *last* stream to touch that mnemonic
  picked. Measured over the 36 regression programs that contain load/store
  streams: **3167 of 3322 streams (95.3%)** use a base register that is not
  their own `la`, and at instruction granularity 45,845 of 50,782 accesses
  (90.3%). The collapse is program-wide, not per-stream: `rand_instr_test_0`
  emits all 301 of its `lb` as `lb t1, imm(s9)` and all 287 `sb` as
  `sb t2, imm(s9)` — only the immediate varies — and whole programs use as few
  as **one** base register for every load and store in them. After the patch a
  freshly generated program uses 20 distinct base registers and 38/38, 44/44
  and 99/99 streams match their own `la`.

  Traced dynamically, 31 of 34 faulting accesses used a base register whose
  last write was in the `init:` preload block *before* `main` — never touched
  by any `la` at all.

  The consequence is not a weaker random address distribution, it is no test at
  all. The base register holds whatever `init` randomised into it — typically
  `0x80000000` — so accesses land in the program's own code or below the start
  of RAM. The first one faults, and because pyflow's `mmode_exception_handler`
  routes anything that is not ECALL or ILLEGAL straight to `test_done`
  (see patch 27), the program then *ends normally* and writes `tohost = 1`.
  Both models do exactly the same thing, so the traces match and the test is
  reported as **Passed** after running about 2% of itself: measured tohost at
  dump line 213, 234 and 370 of programs with 6k–14k instructions in `main`.

  Upstream already knows: `get_rand_instr()` right above uses `deepcopy` with a
  comment saying "rs1 rs2 values are overwriting and the last generated values
  are getting assigned for a particular instruction". The two sibling helpers
  never got the same treatment.

- `27-loop-limit-reg-collision.patch`
  `legal_loop_regs_c` keeps `loop_cnt_reg` and `loop_limit_reg` unique within
  themselves but drops the cross constraint
  `src/riscv_loop_instr.sv:53-55` has:

      foreach (loop_cnt_reg[i]) {
        foreach (loop_limit_reg[j]) { loop_cnt_reg[i] != loop_limit_reg[j]; }
      }

  so the solver may hand a loop the same register as counter and limit. The
  backward branch is then `beq a5, a5, <back>` — rs1 == rs2, always taken — and
  the loop cannot exit. This is the `bge x31, x31` family seen in earlier runs
  and written off as "riscv-dv generates programs that cannot terminate": it is
  not inherent, it is this missing constraint. Applied post-solve like
  `legalize_rs1()`, because the constraint form hits the same pyvsc
  randset-merge crash documented on the sibling constraints. C_BEQZ/C_BNEZ are
  skipped: `loop_c` pins their limit register to ZERO on purpose.

  After the patch, 246 loops in a generated `riscv_loop_test` and 27 in a
  `riscv_rand_instr_test` — none comparing a register with itself.

- `28-mix-instr-stream-order.patch`
  `mix_instr_stream(new_instr, contained=1)` draws an insert position per
  injected instruction from an *inclusive* `randint(0, current_instr_cnt)`,
  sorts them, then overwrites the last one with `current_instr_cnt - 1`. That
  overwrite can put the last position *below* an earlier one, so the list is no
  longer sorted and the injected stream is emitted out of order.

  For a loop that is fatal. `build_loop_instr_stream()` hands over
  `[init, init, target, update] + body + [branch]`; when the update's position
  ends up above the branch's, the generated code is

      main_63_0_t: andi ...        # loop body
                   bne a3, s8, main_63_0_t   # branch for loop 0
                   addi a3, a3, -8           # update loop 0 counter

  — the counter is updated after the branch, i.e. never, and the loop runs
  forever. Modelled over the generator's own `num_of_instr_in_loop` range
  (1..25): out of order in 54% of streams at body size 2, 20% at 5, 7% at 10,
  1.3% at 25. Re-establishing the non-decreasing invariant after the override
  fixes it without changing how the positions are drawn.

  Measured after patches 26-28 together: `riscv_loop_test` reaches tohost at
  trace line 15,401 and `riscv_rand_instr_test` at 8,342. Both previously ran
  until the testbench's instruction budget stopped them.

- `29-ebreak-handler.patch`
  `gen_ebreak_handler()` was a `# TODO` / `pass`, and
  `mmode_exception_handler` had no BREAKPOINT arm, so an `ebreak` fell through
  to `test_done` and ended the program at the first one — with `tohost = 1`,
  i.e. reported as a pass. `riscv_ebreak_test` therefore tested one breakpoint
  entry per program at best, and on the 2026-09-11 run it never reached an
  `ebreak` at all (the load/store defect behind patch 26 killed those programs
  first: no mcause 3 appears anywhere in the 50 dumps).

  Ported from `src/riscv_asm_program_gen.sv:1258-1272` (handler: read mcause,
  mepc += 4, restore GPRs, `mret`) plus the dispatch arm at
  `src/riscv_asm_program_gen.sv:1071`. `mepc + 4` is safe for `c.ebreak`
  because the generator always emits it followed by a `c.nop`, exactly as the
  SV comment states, and it is the same assumption the illegal-instruction
  handler already makes.

  With patches 26-29, a generated `riscv_ebreak_test` executes 59 `ebreak`s,
  takes 112 handler returns and runs to `tohost = 1` at trace line 13,369.
  Before: 273 lines, zero `mret`s.

- `30-unexpected-trap-fails.patch`  **(a deliberate divergence from upstream)**
  `mmode_exception_handler`'s fall-through — every cause it cannot resume from:
  access faults, misaligned accesses, an ecall from U — jumps to `test_done`,
  which does `li gp, 1` and exits through the *success* path. The program
  reports a pass having run only as far as the fault, and since both models
  take the same path the trace comparison agrees. That is how 30 of the 41
  "passing" riscv-dv tests on the 2026-09-11 run each verified a median of 7
  instructions of their generated body.

  Exit with `tohost = (mcause << 1) | 1` instead — the riscv-tests failure
  convention, so the cause is readable from the value — jumping straight to
  `write_tohost` because `test_done` would overwrite `gp` with 1. The DUT
  plugin's tohost check then turns it into a Failed verdict.

  Upstream does not do this: it treats an unexpected trap as a normal end of
  test. That is defensible for a flow whose signature comparison covers the
  handler, and wrong for this one, where an unexpected trap means the stimulus
  stopped being what the stream claims. Keeping it silent is what hid the
  defect behind patch 26 for three full regressions.

  Verified in two halves: the generated handler emits the fail sequence (read
  the `mmode_exception_handler` section of any generated `.S`), and a non-1
  tohost value produces the `DUT-FAIL` line and a Failed verdict from
  `compare_dumps`. With patches 26-30, a `riscv_mmu_stress_test` and a
  `riscv_rand_instr_test` both run to `tohost = 1` over ~7.2-7.5k trace lines
  and pass against Spike, so the new exit is not firing spuriously.

- `31-illegal-instr-fallback.patch`
  `riscv_illegal_instr.randomize()` does not solve under the pinned pyvsc —
  200/200 failures for this target, and 50/50 on the stock rv32imc and rv32i
  targets, so it is a pyflow/pyvsc incompatibility, not a FyraCore
  configuration problem. pyvsc cannot even produce an unsat core for it. Patch
  09 stopped a failed draw from aborting the whole program, but it then
  *skipped* the injection, and since every draw fails that meant
  `riscv_illegal_instr_test` and `riscv_hint_instr_test` emitted none of the
  stimulus they are named for — which is why both sat at `iterations: 0`.

  **Why not just fix the solve?** Measured, block by block. Disabling almost
  any *single* constraint block makes the model solve 6/6, and
  `solve_fail_debug=1` reports `internal error: system should solve`, i.e.
  pyvsc finds every randset individually satisfiable and only the merge fails.
  So there is no one bad constraint to repair — it is pyvsc's randset merge,
  in a package this repo pins. Disabling only `instr_bit_assignment_c` (which
  merely stitches the solved fields into `instr_bin`, and could be done in
  Python) does let it solve, but then only `kIllegalFunc7` is ever drawn, and
  pinning `exception` to any other shape still fails 0/8. A real repair means
  porting the constraint model, not tweaking it.

  So draw the shapes directly in Python when the solver gives up. Each is
  illegal on RV32IMAC by its encoding alone, so none can turn into a
  disagreement about which CSRs or extensions a model implements:

  * `kIllegalOpcode` — a major opcode RV32IMAC does not define: 0x0B, 0x2B,
    0x5B, 0x7B (custom) and 0x6B (reserved), remaining bits random.
  * `kIllegalFunc3` — a funct3 reserved for its opcode on RV32: the RV64-only
    widths of LOAD and STORE, and the two unused BRANCH encodings.
  * `kIllegalCompressedOpcode` — RVC quadrant 0 with funct3=100, reserved
    unless Zcb is implemented, which neither model claims.
  * `kReservedCompressedInstr` — the encodings the RVC chapter names as
    reserved: the all-zero halfword, `c.addi4spn` with nzuimm=0, `c.lui` with
    nzimm=0, `c.lwsp` with rd=0, `c.jr` with rs1=0.
  * `kHintInstr` — an RVC operation whose rd is x0: `c.lui`, `c.li`,
    `c.slli`, `c.mv`. Defined as HINTs, so both models must retire them with
    no architectural effect — including the `C.LUI rd=x0` case the decoder
    used to reject as illegal.

  Verified on Spike before wiring it in: 60 drawn illegal encodings, spread
  across all four illegal shapes, **all 60 trap with mcause 2 and none
  retires**; 20 drawn HINTs **all retire and none writes a register**.

  `kIllegalSystemInstr` is deliberately not drawn. Its shape is "a CSR address
  this core does not implement", which Spike may well implement — that is a
  difference between two correct models, and it would show up as a failing
  test. Reaching it needs a CSR list both models agree on.

  The generated assembly carries `(fallback draw)` in the comment so nobody
  mistakes this for the SV model's full taxonomy. `kIllegalFunc7` is still
  missing, and a proper port of the constraint model would still be worth
  doing.

## Still missing from pyflow (not patched)

- **`riscv_csr_test`.** Not an instruction-generator test at all: `run.py` hands
  it to `scripts/gen_csr_test.py`, which builds a *self-checking* test from a
  YAML description of every CSR's fields, reset values and WARL legalisation
  (`yaml/csr_template.yaml` shows the format, including `warl_legalize` Python
  fragments). That description does not exist for FyraCore, and writing it is
  the real work: it has to model `src/csr.v` exactly -- the `misa` C-bit rule,
  the `mstatus` MPP legal-value set, `mtvec`'s forced direct mode, the `mie`,
  `mcounteren` and `mcountinhibit` write masks, and the `pmpcfg`/`pmpaddr`
  locking -- or the generated self-check fails on a *correct* core. Left at
  `iterations: 0` deliberately rather than half-modelled.

- **PMP randomization.** Patch 18 ports the directed path only; `pmp_randomize=1`
  is rejected rather than silently doing nothing. The SystemVerilog constraint
  block (`sanity_c`, `xwr_c`, `address_modes_c`, `grain_addr_mode_c`,
  `addr_range_c`, `modes_before_addr_c`, `addr_legal_tor_c`,
  `addr_napot_mode_c`, `addr_na4_mode_c`) would need porting first, and
  `gen_pmp_exception_routine` with it -- without that routine a generated
  region that denies access re-faults forever.

- **RV32A / atomics.** `riscv_core_setting.py` declares `RV32A`, and the 60
  generated programs contain **no** `lr.w`, `sc.w` or any `amo*`: no testlist
  entry requests an AMO stream, and until patch 25 any that did would have died
  in `riscv_amo_instr_lib`'s `randrange(0, 0)`. Separately,
  `riscv_amo_base_instr_stream` still cannot be constructed under the installed
  pyvsc — `self.avail_regs = vsc.randsz_list_t(...)` raises
  `AttributeError: 'NoneType' object has no attribute 'size'`. So atomics remain
  unexercised by this generator even with patch 25; that needs its own port.

- **ePMP / Smepmp.** `mseccfg` and the `support_epmp` branch of `gen_pmp_instr`.
  FyraCore implements no `mseccfg`, so there is nothing to drive.

## Note for FyraCore: NA4 is unreachable in the RTL

Not a generator issue, but patch 18's stimulus will hit it. `src/pmp.v`
implements NA4 matching (`A_NA4 = 2'b10`, with match logic for all four
regions), but `src/csr.v` masks `A == 2'b10` to `2'b00` on every `pmpcfg0`
write, commented as "A=2'b10 is reserved". `A=2` is **NA4**, and the privileged
spec makes it unselectable only when the PMP granularity `G >= 1`. This core has
`G = 0` (4-byte grain, no read-only-zero bits in `pmpaddr`), so NA4 is a legal
mode here and the matching logic in `pmp.v` can never be reached.

`gen_pmp_write_test` writes random `pmpcfg` bytes, so it will produce `A = NA4`
and read the stored value straight back. Spike keeps NA4; FyraCore returns OFF.
Expect that to show up as a DUT/reference mismatch on `riscv_pmp_test` -- it is
a genuine finding, not a generator defect.

## pyvsc version

pyvsc is unpinned in riscv-dv's `requirements.txt`. The installed version,
0.9.5.27214109393, is the newest on PyPI. Pinning an older one does not help:
the `rand_info_builder.py` `_randset_m.pop(idx)` bug behind patch 05 is present
unchanged in 0.7.9, 0.8.9, 0.9.3, 0.9.4 and 0.9.5, and none of the other
defects above are solver-related at all.
