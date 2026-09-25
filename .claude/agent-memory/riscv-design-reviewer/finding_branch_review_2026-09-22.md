---
name: finding-branch-review-2026-09-22
description: Adversarial review of riscv-compliance_alfadelta10010 (14 commits) — which prior findings are fixed, the two NEW criticals (muldiv livelock under IMEM wait states, csrw+mret write loss), and the reproduction recipes
metadata:
  type: project
---

Review of `git diff main..HEAD -- src/ tb/` in the worktree
`/home/alfadelta10010/projects/worktrees/riscv-compliance` (base fc24364, 14 commits),
2026-09-22. Scratch harness at `/tmp/rvscratch` (`run.sh` = asm -> DUT + Spike + diff).

## Verified FIXED by this branch (re-tested, do not re-raise)

- EX/WB hold across `wb_mem_stall` (2167485). Memory stress (64 iters of sb/lbu, sh/lhu,
  sw/lw, amoadd, lr/sc loop + muldiv) matches Spike bit-for-bit at DMEM_WAIT 0..7,
  IMEM_WAIT 0..1, and 9 random seeds on both ports. AMO 2-phase and LR/SC unchanged
  across all wait settings. Gated set (wb_regWR, instret_inc, dbg_retired, reservation,
  amo_phase/amo_old_val) is **complete**: CSR `we` and `trap` are mutually exclusive with
  memory ops so they need no gate.
- irq_inject gated by stall_other (fce59af). 2000-iteration ld/st loop with a 37-tick
  timer completes with 0 data errors and mstatus.MIE still 1 at DMEM_WAIT=3 and
  DMEM_RANDOM seeds 1/7. **No combinational loop** — verilator `--lint-only` reports no
  UNOPTFLAT on fyracore.
- MRET one-shot commit (760a524) and fetch-fault MRET (f2e42b5).
- Exception priority reorder (11384f8): chain is exhaustive (fallthrough is reachable
  only for `ex_data_fault && ex_misalign_is_store`) and matches Priv Table
  `norm:exc_priority` (1 > 2 > 0 > 8/11 > 3 > [4,6] > [5,7]).
- mtval = faulting encoding (6c564b3); pmpcfg WARL reserved [6:5]=0 + NA4 legal (b7c5805).

## NEW CRITICALS (this review)

**Update 2026-09-24:** C2 fixed by 15a23df (verified). C1's fix 2e6718b removed the livelock but
introduced two new CRITICALs (stale M-op results; fetch-fault M-op deadlock) — see
[[finding-branch-review-2026-09-24]]. R4 fixed (8485cf0/7cd1eb6).

- **C1 muldiv livelock under instruction-fetch wait states.** `muldiv_done` is a 1-cycle
  pulse; the result is only captured in the EX/WB `else` arm, which requires `!stall`.
  If `if_mem_stall` is high on the done cycle the result is dropped and `muldiv_start`
  re-launches the whole operation. Deterministic waits phase-lock it: progress needs
  `latency mod (IMEM_WAIT+1) == 0`. Measured: `mul a2,a0,a1` **never retires** at
  IMEM_WAIT 2,3,4,5,6,7,8,15 (works at 0 and 1). DIV/REM/MULH the same. Randomised waits
  always escape, so `IMEM_RANDOM` hides it — the inverse of the interrupt bug.
  Same shape under interrupts: with mtimecmp period <= 35 clocks no MUL ever completes.
  Fix: sticky `muldiv_result_ready` flag (1 FF) held until the pipeline consumes it, plus
  `!muldiv_want` in irq_inject.
- **C2 `csrw <any>; mret` loses the CSR write.** csr.v write block is still
  `trap > mret > we` (unchanged by this branch — prior finding R1). ex_mret_commit being
  one-shot does not help: with no stall both fire in the same cycle and `we` is skipped.
  Measured: `csrw mscratch,X; mret` -> DUT mscratch 0, Spike X. `csrw mstatus,0x1880; mret`
  -> mstatus write lost, MRET restores MPP=00 -> hart falls to U-mode -> next fetch takes
  cause 1 (no PMP entry). **Masked by IMEM_WAIT>=1**, so it only bites when fetch is fast.

## Still OPEN from 2026-09-12 (re-confirmed)

- R3 misa.C stale for 2 instructions (`ifex_c_illegal` samples csr_misa_c at IF).
  Linux never writes misa (head.S only `csrr t0, CSR_MISA`), so arch-test/lockstep only.
- R4 mstatus MPRV(17)/TW(21) missing while misa advertises U. Spec REQUIRES both writable:
  machine.adoc `norm:mstatus_mprv_rdonly0_no_umode` and `norm:mstatus_tw_acc`. Measured
  `csrw mstatus,-1` -> DUT 0x1888, Spike 0x221888.
- R5 straddling 32-bit fetch. Repro'd cleanly by appending `@01FFFFFE / 13 05 30 12` to the
  image: DUT **executes** `0xxxxx0513` at 0x81FFFFFE and writes X to x10, faulting only on
  the next fetch. Spec `norm:mtval_varlen_wr`: mtval = address of the faulting *portion*
  (0x82000000), mepc = start of the instruction.
- A5 WARL three-copy agreement is still NOT complete: tb `csr_committed` 0x341 lacks the
  IALIGN mask (prints 0x...102 where Spike prints 0x...100) and models no PMP lock
  (prints 0 for a locked pmpcfg0 write where Spike prints the preserved 0x9f; prints a
  pmpaddr0 line Spike omits entirely).

## Reset-state probe (new, measured)

| CSR | DUT | Spike |
|---|---|---|
| pmpcfg0 / pmpaddr0 | 0 / 0 | **0x1f / 0xffffffff** (Spike's legacy permissive PMP reset) |
| mstatus | 0x1800 (MPP=M) | 0x0 (MPP=U) |
| mip | 0 | **0x80** (MTIP: Spike's mtimecmp resets to 0) |
| misa/mtvec/mie/mcause | match | match |

Priv `norm:pmp_A_L_rst` requires PMP A and L reset to 0 — **the DUT is right and Spike is
non-conformant here.** mstatus MPP reset and mtimecmp reset are both UNSPECIFIED.

Related: [[finding-branch-review-2026-09-12]], [[reference-spike-probed-behaviours]],
[[project-fyracore-overview]], [[reference-kianv-memory-map]].
