---
name: finding-mret-multicommit-on-stall
description: CRITICAL open finding — MRET side effects are driven from an ungated EX-stage signal, so a stalled MRET commits mstatus updates once per stall cycle and returns to the wrong privilege mode
metadata:
  type: project
---

**Status: FIXED (760a524 one-shot commit; 15a23df csrw+mret). Verified 2026-09-24. New sibling: MRET + irq_inject same cycle, see finding_branch_review_2026-09-24.md.**

`src/fyracore.v:555` passes `.mret(ex_is_mret)` to `csr.v`. `ex_is_mret` (`:292`) is a purely
combinational EX-stage decode with **no `!stall` qualifier**, and `csr.v:239-241` applies the whole
MRET mstatus update every cycle it is high. Meanwhile `priv_mode <= (csr_mstatus_mpp == 2'b11)`
(`:814-815`) **is** gated by `!stall`, so it samples MPP *after* csr.v has already cleared it to 00.

Consequences when MRET is stalled for >=1 cycle:
- `mstatus.MIE` gets re-loaded from the already-updated MPIE (=1) → MIE ends up 1 when it should be 0.
- `priv_mode` drops to **U-mode** instead of returning to MPP.

Reproduced 2026-09-05: `amoadd.w` immediately before `mret` (AMO sets `wb_busy` → `stall`), with
mstatus preset to 0x1800 (MPP=M, MPIE=0, MIE=0):
- Spike: mstatus after mret = 0x00000080, next instruction runs at priv 3.
- FyraCore: mstatus after mret = **0x00000088**, next instruction traps illegal (cause 2) because
  priv dropped to 0. Control case (`nop; nop; mret`) matches Spike.

**Why it matters:** in the project TB the only stall source that coincides with MRET-in-EX is
`wb_busy` (AMO). On silicon, `if_mem_stall`/`wb_mem_stall` from QSPI/PSRAM will be asserted around
almost every MRET, so *every* trap return from the Linux kernel would fall to U-mode.

The same "EX-stage side effect held across stalls" pattern also affects `irq_inject`
(`fyracore.v:610`, ungated by `!stall`): an interrupt taken during a stall cycle is injected twice,
and the second injection latches MPIE <= the already-cleared MIE (0), so MRET restores MIE=0.
By contrast `fencei_flush` (`:740`) and the `wfi_active` set (`:820`) *are* correctly `!stall`-gated,
and traps are correctly committed one-shot at WB via `csr_trap_signal` (`:534`).

**How to apply:** the invariant to check for every new EX-stage side effect is "is it qualified by
`!stall` (or moved to WB) so it commits exactly once?"

Related: [[finding-wb-stall-drops-memory-op]], [[project-fyracore-overview]].
