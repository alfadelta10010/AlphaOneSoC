---
name: finding-rvfi-wo36-2026-11-07
description: WO-36 RVFI port review (8976278, branch verif-close): APPROVE w/ non-blocking; stall_nofetch equiv artefact = purge renamed wfi_active to fv_wfi_active
metadata:
  type: project
---

WO-36 RVFI port review, 2026-11-07, 8976278 + tb/rvfi/{strip_ifdef.py,zero_area.sh}. Report:
localFiles/verif-close-2026-11-07/WO-36/REVIEW.md. Verdict APPROVE WITH NON-BLOCKING; no src edit.

- Spec lives at riscv-formal `docs/source/rvfi.rst` (pinned c992aa61; sandbox clone
  ~/regr/vc/plannerB/riscv-formal). `docs/rvfi.md` does not exist.
- The port is correct for every retire shape. Capture = EX/WB else-arm and IF/EX load arm; pc_wdata mirrors
  next_pc (pc = X.pc+len while X in EX). The rs mask `ex_rs==ifex_rf_rs` is a no-op on the correct core;
  use_hazard keys on ex_rs*, so any reported rs is fresh. ALTOPS constants match insns/insn_*.v.
- Minor: an interrupt at a WFI still in EX (mepc = WFI+4) gives the WFI no packet. No check sees it.
- Gaps: WO-37 D2 forces M-mode + misa.C=1, so U-mode and rvfi_mode=U are never exercised.
  Word-aligned mem_addr needs RISCV_FORMAL_ALIGNED_MEM in checks.cfg. ALTOPS bypasses the muldiv operand latch.
- **Equiv artefact (B-1):** `assign fv_wfi_active = wfi_active` + `opt_clean -purge` left the net named
  `soc.cpu.fv_wfi_active` in the gate, so equiv_make had no `wfi_active` pair. The free state bit made
  stall_nofetch unprovable. FC02 (csr_wb_hazard) is unrelated. `equiv_add \soc.cpu.wfi_active_gold
  \soc.cpu.fv_wfi_active_gate` gives 5017/5017 proven, rc 0, 11 s (sandbox ~/regr/vc/review36/za/eq2.log).
  Asked for this edit in zero_area.sh plus a comment fix. Status: open (tb edit).

**Why:** equiv_simple and equiv_induct proofs are conditional on every $equiv cell. One unmatched flop
leaves the whole "every output proven" claim conditional.
**How to apply:** when an equivalence leaves one cell unproven, trace that cell's cone back to the $equiv
cuts (`select w:X_gold %ci*:-$equiv`) and look for a `_gold` name with no `_gate` partner before blaming
logic. See [[patterns-recurring]].
