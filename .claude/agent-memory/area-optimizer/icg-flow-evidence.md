---
name: icg-flow-evidence
description: What is known (2026-09-30) about sky130 dlclkp ICGs through LibreLane/OpenROAD CTS/STA on TinyTapeout -- evidence sources for the ICG register-file decision
metadata:
  type: reference
---

- sky130 `dlclkp_1`: 17.52 µm², liberty `clock_gating_integrated_cell : "latch_posedge"`,
  so OpenSTA infers gating setup/hold checks on GATE (verified pre-layout on the ICG RF:
  setup slack +16 ns, hold +0.74 ns at 20 ns).
- OpenROAD CTS README: gater sub-trees keep the feeding tree's level; `-balance_levels`
  covers clock-gate cells. No TT design found that finished hardening with explicit ICGs.
- github.com/thejefflarson/little-cpu (TT 4x2 core): PR #409 = 27 dlclkp via LibreLane
  `SYNTH_CLOCKGATE_*` (placed, routing never finished); PR #411 = GLS pass on it; PR #416
  removed clock gating: LibreLane 3.0.14's yosys 0.62 `clockgate` gated a sync-reset flop on
  its enable alone (fixed yosys >= 0.65). Same PRs claim the TT flow never uses edfxtp
  (enable flop = dfxtp + mux2), so our recipe slightly underestimates enable-flop area.
- open_pdks sky130 librelane synth_excluded.cells: clkbuf/clkinv/dly*/tap/decap/fill/diode/
  lpflow/probe/`s*` -- dlclkp and edfxtp are not in it.

**How to apply:** ICG RF (#1a) needs a sandbox hardening (CTS skew, hold buffers, signoff
gating checks, GLS) before it lands; avoid yosys `clockgate` on sync-reset flops. Related:
[[area-optimizations-measured]].
