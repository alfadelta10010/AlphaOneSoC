---
name: finding_setup_timing_postrtl_review_2026-10-14
description: Post-RTL review of setup-timing steps 1-8 (no fwd, ex_ph, ex_rf_ok, qspi t_we, run flop); read-only, no sims
metadata:
  type: project
---

Verdict: no Critical/Major. Read-only review of 406745b..HEAD + uncommitted step 8 (regFile always reads ifex_rf_rs*, ex_rf_ok).

Proven by reading:
- Step 8 timeline: I enters EX C0; macro takes ifex_rf_rs at end of C0 (regFile hit/byp covers a same-edge write by the one-cycle
  WB writer); rf_a valid C1; ex_ph <= ex_rf_ok && !use_hazard at end of C1; alu_r valid C2. Multi-cycle WB writers (load/AMO/LR)
  keep use_hazard high through their last WB cycle, the read on that edge hits byp. Younger writer cannot reach WB (only I is
  younger and it is stalled). Bubble stall can set ex_ph/ex_rf_ok for a bubble: harmless, load branch resets both.
- X on ifex_rf_rs* after reset: masked (NOP x0 mask), hit1 = 0&&X = 0.
- Step 3: ex_is_iter opcodes = OP/OP-IMM only (sweep in tb_controller); ex_trap_iter == ex_trap_decode there.
- Step 4: if_* only used in the load branch / last next_pc arm, both excluded when ex_nofetch.
- Step 7: use_d only matters on the start cycle (cs_sel, we sampled); t_we/t_psram set at every start incl. init (garbage,
  unused in init); split 2nd half: pick_d = d_req && !second; d_req cannot rise mid-fetch (WB op enters only on fetch ready).
- Step 6: run and rst_sync[1] change on the same (2nd) edge; async assert both; no-clock release holds pins in reset.

Efficiency (D) findings: rf_fields + ifex_rf_rs1/2 (10 flops) redundant now (ifex_instr is expanded: ra=ifex_instr[19:15],
rb=[24:20], also fixes X at reset); csr_wb_hazard now always inside ex_wait (CSR in WB only at C0) -> dead stall term;
regFile hit/byp (34 flops + 64 mux2) removable if ex_rf_ok <= !use_hazard (costs a cycle only on dependent chains);
mcycle_wr_q purposeless (reads now >=3 cycles later) but coupled to cnt_xhalf case 4 / cnt_xcycle (-2).

Test findings: mtip_stale fast line x22=0 no longer exercises stale window (only the waited store does); its 3rd line pins
x22=0x80 under DMEM_RANDOM (LFSR phase -> brittle; use DMEM_WAIT=3 w/o random). cnt_xhalf case 4 pinned to 3-cycle EX
latency (earlier = silently vacuous, later = loud); tb_csr covers it exactly. t_irq lower bound weaker (no upper bound pre-existing).
