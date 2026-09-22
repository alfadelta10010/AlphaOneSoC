---
name: riscv-dv-pyflow-defects
description: Where the riscv-dv pyflow fixes live (a pinned fork, not local patches), what the generator now exercises on FyraCore, and the traps that still apply when reading its results
metadata:
  type: reference
---

pyflow is a **partial** Python port of riscv-dv's SystemVerilog generator; upstream
never kept it in step with `src/*.sv`. Before the fixes, most tests generated
nothing and the rest ran ~2% of themselves and still passed.

**The fixes live in a fork**, not in this repo: `alfadelta10010/riscv-dv-patched`,
branch `pyflow-fixes`, pinned by `version` in `plugins/river-config.ini`
(`[riscv_dv]`). One commit per defect, each quoting the SV it was checked against.
`docs/pyflow/README.md` in the fork lists every deliberate divergence from the SV
and everything not ported. The plugin clones/fetches the fork and checks out the
pin on every run; there is no patch series any more.

## What the generator exercises now

- Random boot mode (M:U = 6:4), U-mode programs, sub-programs/call stacks,
  loops, load/store and hazard streams, multi-page and memory-region streams.
- Illegal-instruction and HINT injection from the SV `riscv_illegal_instr` model.
- LR/SC and AMO streams (`riscv_amo_test`).
- PMP: directed regions, `+pmp_randomize=1`, and the PMP exception routine with
  instruction/load/store access-fault handlers.
- Unexpected traps end the test with `tohost = (mcause << 1) | 1`, so a program
  that faults no longer reports a pass.

**Known gaps in that stimulus (open generator defects, listed in the fork's
`docs/pyflow/README.md`):** M-mode boot skips its mstatus/mie setup and mret;
about half of the injected illegal/HINT words are placed where they never
execute; the numeric-corner stream never produces all-ones or INT_MIN; jump
streams never emit compressed jumps; several solves are skewed (rd x0/a3, loops
that never iterate, sub-programs pinned at 10 instructions). A passing riscv-dv
test can exercise less than its name says.

## Traps that still apply when reading results

- **Passed is not proof.** Check the trace ran the body: tohost line vs. the
  static size of `main`, handler hit counts, whether streams use what they set up.
- **Two known RTL defects show up in riscv-dv runs**, not generator bugs:
  a `csrrw` to mscratch immediately before `mret` is dropped (any handler that
  returns and traps again diverges at the next trap), and `pmpcfg` WARL (NA4
  turned into OFF, reserved bits 6:5 kept) on any test writing pmpcfg.
- **Nothing raises interrupts** in this flow: `riscv_full_interrupt_test` only
  enables them.
- **Config values are taken from the command line.** Plain-int cfg fields
  (`instr_cnt`, `num_of_sub_program`) are baked into constraints when cfg is
  built; assigning them later does not reach the solver. Every testlist entry
  passes them explicitly.
- **U-mode needs the region count.** Upstream's default single PMP region is
  TOR [0, main); every entry passes `+pmp_num_regions=4 +pmp_granularity=0`.
- **Randomized PMP can hang by design**: a locked entry denying writes over the
  kernel stack makes the trap handler re-fault forever (same upstream; ibex runs
  that test with timeouts non-fatal).
- A generator run that appears hung at 0% CPU: check
  `ps -eo etime,args | grep riscv_instr_base_test`.
- pyflow files are partly **CRLF**; binary-safe edits only.

## pyvsc

Generated with PyPI pyvsc 0.9.5.27214109393. Its `_randset_m.pop(idx)` and
empty-rangelist bugs are fixed in `alfadelta10010/pyvsc-patched` (riscv-dv-fixes);
see `requirements.txt` for which one the flow uses.
