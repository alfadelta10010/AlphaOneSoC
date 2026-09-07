---
name: riscv-dv-pyflow-defects
description: Why upstream riscv-dv's pyflow (Python/PyVSC) generator fails on almost every test stream, the ten local patches that fix it, and which failures are unfixable missing features
metadata:
  type: reference
---

pyflow is a **partial** Python port of riscv-dv's SystemVerilog generator. It is not
maintained in step with `src/*.sv`, and several ported functions silently dropped logic.
Before the local patches, only `riscv_arithmetic_basic_test` generated at all.

Authoritative write-up (kept next to the patches, update it there):
`plugins/generator_plugins/riscv_dv_plugin/patches/README.md`.
The plugin applies `patches/*.patch` in sorted order, idempotently, after cloning,
so they survive a re-clone of `build/riscv-dv`.

## The headline bug: SolveFailure in randomize_gpr

`riscv_instr.get_rand_instr()` computes `disallowed_instr` and **never uses it**. The SV
original constrains the draw with `!(name inside {disallowed_instr})`
(`src/isa/riscv_instr.sv:230-232`); the Python `else` branch just calls
`random.choice(allowed_instr)`.

So when the load/store stream reserves SP as its base register
(`riscv_load_store_instr_lib.py:115`, `reserved_rd.append(rs1_reg)`),
`randomize_instr()` asks to exclude `C_ADDI16SP`, the exclusion is dropped, and
`C_ADDI16SP` comes back. Its own constraint pins `rd == SP`
(`isa/riscv_compressed_instr.py:52-53`, block `rvc_csr_c`) while `randomize_gpr()`
asserts `rd != reserved_rd[i]` (`riscv_instr_stream.py:252`). That is `rd == 2 AND rd != 2`.

**This is not a solver problem.** Any SMT solver fails on a literal contradiction.
Debug it with `vsc.model.randomizer.glbl_solvefail_debug = 1` before importing the test
module — that prints the unsat core ("Problem Set: N constraints").

## Do not chase a pyvsc version pin

`requirements.txt` leaves pyvsc unpinned. Installed 0.9.5.27214109393 is the newest on
PyPI. Downgrading does not help:

- The one genuine pyvsc bug involved (`vsc/model/rand_info_builder.py:317`,
  `visit_expr_array_subscript` does `self._randset_m.pop(idx)` with an `int` key where
  `_randset_m` is keyed by `RandSet` objects; line 407 does it correctly) is present
  **unchanged in 0.7.9, 0.8.9, 0.9.3, 0.9.4 and 0.9.5**. Verified by unpacking the wheels.
- Every other defect is plain Python logic in riscv-dv, not solver behaviour.

Workaround for that pyvsc bug: never subscript a **vsc list field** inside a
`randomize_with()` block — read the element into a plain Python int first. Plain Python
lists of `riscv_instr` objects are fine (the subscript resolves before the expression is
built). A scan of `pygen_src` found `riscv_loop_instr` was the only offender; every other
`self.x[i]` inside a constraint block indexes a plain list.

## The silent-hang trap

`pygen_src` has 41 `sys.exit(1)` call sites. `riscv_instr_base_test.run_phase()` caught
only `Exception`, so `SystemExit` escaped, killed the `multiprocessing.Pool` worker, and
left `pool.map()` blocked **forever** — observed as a `riscv_loop_test` generator stuck
21+ hours at 0% CPU with no error output. Patch 06 catches `BaseException`.

If a pyflow run ever appears to hang with no output, check
`ps -eo etime,args | grep riscv_instr_base_test` for 0%-CPU deadlocked workers.

## Config trap: late assignment to cfg does not reach constraints

`cfg` fields that are plain Python ints (e.g. `num_of_sub_program`, `instr_cnt`, set in
`riscv_instr_gen_config.__init__` from argv) are baked into the `default_c` constraint
when it is elaborated. Assigning them later — as
`riscv_rand_instr_test.randomize_cfg()` did (`cfg.num_of_sub_program = 5`) — changes the
Python attribute but **not** the solver's view, so `gen_sub_program()` looped 5 times over
a list sized from argv and raised `IndexError` (`riscv_asm_program_gen.py:217`).
Set these through the command line (`+num_of_sub_program=`, `+instr_cnt=`), never by
assignment after construction.

Consequence worth remembering: tests whose testlist entry omits `+instr_cnt` get the
argparse default of **200**, not the 10000 the old hardcode appeared to promise — the
hardcode never reached the constraint either. Add `+instr_cnt=` explicitly to any entry
that should be large.

## Verified state after the patches (10 local patches, 2026-09-07)

13 streams probed at `+instr_cnt=400`, each generated test then assembled with
`riscv64-unknown-elf-gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -I <riscv-dv>/user_extension`:

    12 / 13 generate, all with zero assembler errors.
    Only riscv_pmp_test fails (pyflow has no --pmp_* options at all).

Before the patches only `riscv_arithmetic_basic_test` generated.

**Always assemble the generated .S, not just check that generation exited 0.**
That is how patch 10 was found: `riscv_rand_instr_test` generated "successfully"
but emitted `c.swsp t2,23(sp)` / `c.swsp t2,-184(sp)`, encodings that do not
exist. Cause: `gen_load_store_instr()` `extend()`ed `allowed_instr` instead of
reassigning it per address, so alignment-gated instructions leaked from one
address to the next.

## Two more traps worth remembering

- **`riscv_illegal_instr` is ~50% flaky.** Its constraint model fails to solve on
  roughly half of all draws, on rv32imac and rv32imc alike (measured 4/10 vs
  5/10 with RV32A removed — noise, so not target-related). pyvsc cannot even
  produce an unsat core: `create_diagnostics()` bails with "internal error:
  system should solve" (`randomizer.py:443`), i.e. each randset solves alone and
  only the combination does not. Mitigated by retrying (patch 09), not by
  touching the 368-line constraint model — "fixing" that without a reproducible
  unsat core risks emitting encodings that are actually legal, which would look
  like false RTL failures.

- **Full-size probes are timeout-bound while a regression is running.** At
  `+instr_cnt=10000` on a machine already saturated by `vvp ./sim_fyracore`,
  even `riscv_arithmetic_basic_test` blows a 600 s timeout mid-generation with
  zero errors in its log. Probe at `+instr_cnt=400`; it exercises every directed
  stream and every failure mode above, in about a minute per test.

## Not fixable without a real port

- `riscv_pmp_test` — pyflow implements **none** of the `--pmp_*` options; `run.py` dies at
  argparse ("unrecognized arguments: --pmp_randomize=0"). `riscv_pmp_cfg` exists only in
  SystemVerilog; the pyflow config has one `pmp_reg` field and a commented-out TODO.
  Missing feature, not a defect. Keep at `iterations: 0`.
- `riscv_multi_page_load_store_instr_stream` and `riscv_mem_region_stress_test` are not
  ported; they are what `riscv_mmu_stress_test` asks for. Both exist to stress data-TLB
  switching and FyraCore is `SATP_MODE = BARE` with no MMU, so porting them buys nothing.
  Already dropped from `plugins/riscv_dv_target/rv32imac/testlist.yaml` (both from
  `riscv_rand_instr_test` and `riscv_mmu_stress_test`); with them gone both streams
  generate and assemble cleanly.

## Target settings are not implicated

The FyraCore `rv32imac` target (RV32A added, USER_MODE added, DIRECT-only interrupts,
`support_unaligned_load_store = 0`) does **not** cause any of this. Both `rv32imac` and
stock `rv32imc` build an identical 45-entry `basic_instr` pool containing `C_ADDI16SP`
and `C_ADDI4SPN`, so the SolveFailure precondition is the same on both. Any difference in
observed failure rate between the two is sampling noise.

## Note on line endings

Several `pygen_src` files (`riscv_instr_stream.py`, `riscv_loop_instr.py`) use **CRLF**.
Editing them with Python text-mode I/O silently rewrites the whole file to LF and turns a
three-line patch into a 270-line one. Read/write in binary, or restore CRLF before
generating the patch.
