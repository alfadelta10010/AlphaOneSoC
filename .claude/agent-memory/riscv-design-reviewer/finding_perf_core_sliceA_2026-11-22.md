---
name: finding_perf_core_sliceA_2026-11-22
description: CPI review of the FyraCore core @2a2978e (slice A) -- cache-on cycle budget, the serial-shifter cost, the M-start slack, non-posted stores, why WO-76 measured only -0.95 %
metadata:
  type: project
---

Read-only perf review 2026-11-22. Report: localFiles/rtl-review-2026-11-22/A-core.md. No functional bug found.

**Cache-on timing (traced):**
- Plain op: 4 clk behind an aligned hit (the hit is discarded on c2; cache.v blocks lookup on the hit_q cycle),
  3 behind a straddle or kbuf.
- Branches: taken 5, not-taken 5 (4 with kbuf).
- Shift k: 5+k. MUL 37, DIV 39.
- Load-use: +2.
- Store: ~34 clk of full-pipeline stall (mem_ctrl d_ready = q_done).

**Budget:** CPI 24.4 cache on, from the 128 B build numbers (0.1293 = 1.78x); HEAD is 256 B.
- Core-internal ~4.7 CPI (~19 %).
- Loads ~6.1, stores ~1.5.
- Remainder ~12 = I-cache fills. PBURST removes 3.7.
- Against the csim model (CPI 16.6-17.1 at 128 B), ~4-7 CPI is unexplained and sits outside the core.
- Recommended stall-cause counters in tb_sw before any perf WO.

**Why WO-76 only gave -0.95 %:** case 1 fires on ~24 % of instructions × 1 clk = ~1 % of CPI 24.4.

**Ranked findings:**
- A-1: posted PSRAM stores, ~2-3 % (slice B / contract, high risk).
- A-2: shifter steps {16,4,1}, ~1.6-1.9 %; tb_muldiv checks the exact latency 2+shamt (REQ-MD-004).
- A-3: start muldiv on `ex_rf_ok && !use_hazard && !ex_ifetch_hi_phase` (drop ex_wait, wb_mem_stall, wb_busy).
  This is the same invariant that sets ex_ph, so it is sound. Also the dead S_SH done cycle and the S_FIX
  pass-through for MUL.
- A-4: a cheaper variant of WO-76 case 1 -- delay imem_req to ex_rf_ok when a `fetch_cached` input is set.
- A-5: not-taken branch requests the fall-through on c3 (ex_nofetch term with ex_ph && !br_r), -1 clk.
- A-6: kbuf hit idles the port (cache-off 1.4 %).

**Data sources worth reusing:**
- CoreMark instret 15,832,582 for 50 iterations = 316.6 k/iter.
- csim mix: loads 17.3 %, stores 4.6 %, reuse 20.9 %.
- Callgrind call counts in build/sw/third_party/coremark/docs/coremark_profile_o0_joined.png (crcu8 220/iter).
- objdump of build/sw/coremark/coremark.elf: the crcu8 loop has 4 shifts (1,16,16,1); zext/sext.h = slli/srli 16
  pairs (no Zbb).

Related: [[finding_wo76_wo77_plan_2026-11-22]], [[finding_fetch_reuse_wo27_2026-10-29]].
