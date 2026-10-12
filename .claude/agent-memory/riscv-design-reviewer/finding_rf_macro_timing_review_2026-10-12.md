---
name: finding_rf_macro_timing_review_2026-10-12
description: Review of 7 uncommitted timing changes on rf-macro branch (bypass, wb_fwd w/o mem data, ex_trap_decode, IF-stage cdec, inc64); all SOUND, no Crit/Maj
metadata:
  type: project
---
Verdict: all 7 changes SOUND by reading; no Critical/Major.
- hit1/hit2 compare the exact address given to the macro (rf_hold ? ifex_rf_rs : if_rs) vs rd with w_ena: same condition as the macro's collision, so its answer is never used.
- wb_fwd: load_use_hazard (exwb_memRD, same ex_rs fields as fwd) holds the consumer for every WB cycle of a load/LR/AMO; stalled-cycle EX state (muldiv_start gated by stall_nofetch, wfi/fencei/pc redirects gated !stall, ifetch verdicts address-only). Only flush->muldiv_ready<=0 sees garbage operands, as before.
- ex_trap_decode / irq_inject / ifex_rf_rs: equal by construction (tb_controller 17-bit sweep; irq_inject needs !stall_other && !muldiv_want).
- cdec in IF: no comb loop (ex_nofetch -> imem_req -> mask -> cdec -> ifex_instr D only). Minor: new timing path ex decode -> ex_nofetch -> imem_req -> cdec -> ifex_instr; mask could be applied after cdec.
- inc64: q/c32 loaded from the same d every edge, reset d=0; tb_inc64 is standalone-module only.
Area est: bypass ~0.15 t, IF-cdec +17 flops ~0.05 t, ifex_rf_rs ~0.03 t.
