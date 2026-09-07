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

  The companion guard in `pre_randomize` was wrong too. The SV asks
  `if (SP inside {cfg.reserved_regs, reserved_rd})`; the port wrote
  `SP in [cfg.reserved_regs, self.reserved_rd]`, which tests whether SP *is* one
  of those two list objects and is therefore always False. Note that because
  `cfg.sp` is randomized, the ABI name `sp` appearing as a load/store base in
  generated assembly is **not** by itself a defect -- only a hit on the
  program's actual `cfg.reserved_regs` is.

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
