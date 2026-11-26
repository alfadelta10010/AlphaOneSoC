---
name: finding-adv-tip-A-core-2026-11-25
description: ADV-tip slice A (f75a734): PX-6 shifter, PX-7 start-under-stall, PX-8 Booth/early-out, a48b21f, brcmp -- RTL clean; claim/evidence gaps
metadata:
  type: project
---

Slice A of the 2026-11-25 adversarial tip review (report localFiles/wo-4x4/reviews/adv-tip-2026-11-25/A-core.md).
No RTL defect. Python bit-accurate muldiv model (Booth digit, 35-bit adder, skip16/8/4) = 0 fails / ~352k vectors;
shifter and log-depth compare tree exhaustive-ish clean.

Durable facts:
- PX-7 start term `ex_rf_ok && !use_hazard && !ex_ifetch_hi_phase` == the cycle that sets ex_ph; sound because EX/WB
  bubbles on every stall (use_hazard can only fall) and every flush source is an EX property (FC49).
- Store-completion-edge stale fetch is a GENERAL, spec-legal (Zifencei) window: any EX insn with ex_ph leaving on the
  store's dmem_ready edge takes a same-edge fetch (memory_model imem read is combinational, write at posedge). a48b21f
  closes it only for M ops (authors' pr_add probe confirms). SoC +CACHE_EN reproduces it -> cache hit can complete on a
  store's completion cycle.
- ALTOPS blind spot: fv_altop and RVFI rs*_rdata are sampled at the leave-EX edge, so riscv-formal never sees the
  operands muldiv latched at start; PX-7 operand finality rests on sim only (PXS1/PXS2). Suggested ghost-snapshot prop.
- Real latencies: done = start + 17 (MUL), 18 (MULHU/MULHSU b31), divide 2 + negs + its (max 36); muldiv.v comment
  "1+4+1" and docs "3 + steps" are off by one.
- 380c0ad depths (MUL* 27, DIV 44) are computed, not measured; PX-tree riscv-formal was never collected (9/19).

**Why:** future reviews of fetch-hold / M timing should not re-derive these; A1 class matters for any Spike-lockstep SMC test.
**How to apply:** treat SMC-without-FENCE.I lockstep tests as fragile; ask for the ghost-operand property before
trusting formal on any muldiv start-timing change. Related: [[finding-trackb-rtl-2026-11-22]], [[finding-wo62-icache-k4-2026-11-21]].
