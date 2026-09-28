---
name: finding-review-2026-09-27-counters-lrsc
description: Review of dce9568 (LR/SC keeps reservation across own stores), f4e4975/4f4e071 (counter write replaces increment) and the SoC tb boot_addr force -- cross-half counter read bug reproduced, area deltas in tiles
metadata:
  type: project
---

Reviewed 2026-09-27 at 9227527 (+ uncommitted tb/MANIFEST edits).

## dce9568 -- same-hart store/AMO no longer clears the reservation (USER DECISION)
- LEGAL. Zalrsc must-fail list names only other harts / other devices; RVWMO appendix
  (atomicity-axiom commentary, "Table 75") explicitly says SCs after same-hart stores, even
  overlapping ones, "may (but are not guaranteed to) succeed". Forward progress untouched
  (keeping a reservation can only make more SCs succeed). Linux: ret_from_exception dummy
  `REG_SC x0, a2, PT_EPC(sp)` still unconditional in mainline (checked 2026-09-27); no kernel
  LR/SC loop has a store inside. Trap clear (csr_trap_signal, WB) is now the only thing
  protecting bare-metal irq-handler-vs-LR/SC atomicity -- do not remove it as an area cut.
- Verified: lrsc_policy, lr_sb_sc, atomics, sc_trap, amo_chase, lrsc_io, t_amo full-trace
  MATCH Spike at 0/3/random+NOTREADY waits; lrsc_policy MATCH through the SoC.
- Area: -0.02 tiles (noise; the removed compare was already merged with sc_success's).
- Residual lockstep divergence: Spike yields the reservation every 5000-step INTERLEAVE chunk.
- Supersedes the "clear on local write" recommendation in [[finding-lrsc-policy-2026-09-22]].
  Don't re-propose.

## f4e4975 / 4f4e071 -- explicit counter write replaces the increment
- Storage rule correct (Zicsr "instead of"; Sail sets minstret_increment=false for B02 AND B82;
  riscv-tests rv32mi-instret_overflow test 3; Spike 51835fd7). mcycle rule legal either way.
- MAJOR (open): csr.v read port still returns `*_next` (increment NOT suppressed) for the half
  that is not being written, so `csrw minstreth; csrr minstret` back-to-back reads +1, and
  `csrw minstret` (old lo=ffffffff); `csrr minstreth` reads hi+1 then hi next insn (goes
  backwards). Reproduced vs Spike 7ab2efd6 (scratch cnt_xhalf.S). Only with zero-wait fetch
  (EX/WB adjacent); unreachable on the QSPI SoC; hits core-level lockstep/rrag. csrrs/csrrc
  on the other half can PERSIST the wrong value. Fix: gate the increment enable with
  `!(we && waddr is either half)` and read `cur + inc_en` (fix2) -- area-neutral.
- Area (flat core, mean of 2 file orders): 50436f7 12.315, dce9568 12.293, HEAD 12.367,
  HEAD+fix2 12.304 tiles. csr alone: +0.02 tiles for 2/3.

## SoC tb force boot_addr
- Sound: qspi_ctrl idle/done are masked by `init`, so the first PSRAM fetch waits for the
  start-up sequence; entry state all-zero and minstret match Spike (probed). Coverage note:
  only flash_boot/pma_flash now exercise init->flash and flash->PSRAM (silicon order).

## Suite (scratch copy, core-level, committed MANIFEST)
HEAD 101/105: fails = 3 stale lrsc_policy/lr_sb_sc `expect` lines (working tree already converts
them to `spike`, uncommitted) + csrlog_probe (new Spike logs pmpaddr4 writes; tb doesn't --
unrelated). Read-D-input fix variant: identical 101/105. Verilator -Wall lint clean.

Related: [[reference-spike-probed-behaviours]], [[finding-lrsc-policy-2026-09-22]].
