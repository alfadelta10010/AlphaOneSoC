---
name: finding_setup_timing_note_review_2026-10-14
description: Pre-RTL review of no-WB-forwarding + two-phase EX (alu_r/br_r/ex_ph) timing change on branch setup-timing_alfadelta10010
metadata:
  type: project
---

Verdict: both changes SOUND as written; no Critical/Major. Operand-stability claim TRUE.
- regFile.v already bypasses via byp/hit1/hit2 (not the macro), so distance-1 reads after a held cycle are covered.
- Stale alu_r/br_r only reaches raw `flush` (muldiv_ready clear, harmless: ready is 0 when a new insn enters EX) and
  ex_trap/irq_inject/next_pc paths that are all !stall or !stall_other gated; ex_wait is in stall_nofetch.
- ex_ph must also gate on !csr_wb_hazard && !ex_ifetch_hi_phase ONLY if trap-decode terms get registered later
  (CSR state, ifetch_*_denied, pmp verdicts change at the end of those cycles).
- Suggested: add !exwb_trap to use_hazard (cosmetic; trap in WB is always followed by a bubble).
- Cheaper cut: register 1-bit verdicts (br_taken, data_ok, inst_misalign) instead of 32-bit alu_r; ~27 fewer flops.
- Core-level zero-wait tb CPI doubles (2 EX cycles/insn): max_cycles watchdogs, cycle-pinned directed tests.
