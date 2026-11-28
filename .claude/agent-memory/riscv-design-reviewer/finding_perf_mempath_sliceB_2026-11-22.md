---
name: finding-perf-mempath-sliceB-2026-11-22
description: Slice B perf review of the memory path (cache/mem_ctrl/qspi/soc_bus) @2a2978e - cycle reference, cold-jump fill penalty (B1), 7-CPI model gap explained, all RTL items DROP under the sky26d-only rule
metadata:
  type: project
---

Report: localFiles/rtl-review-2026-11-22/B-memory.md. 0 functional bugs. The triage rule (user, 11-22): sky26d is the
only shuttle, so every item is DO-NOW (lands by the 11-24 freeze) or DROP. The adoption bar is 5 % (U16).

**Cycle facts** (62.5 MHz, rd_late 0; PROVEN, reuse them):
- PSRAM read: 42 clk between starts (done at start+41).
- PSRAM write: word 34, half 26, byte 22. Flash EBh read: 58.
- Stream/burst continuation: 19 = IDLE + S_CHK + 16 + END.
- CS high: 2 clk = the tCPH 18 ns floor.
- Cache hit: aligned 4 clk per instruction, straddle 3. The aligned hit is ready during ex_wait and thrown away.
- Cache miss: uncached + 3, plus 42 per word before the target, plus whatever is left of the running fill.
- soc_bus memory: +0. IO: 2 clk.
- The W25Q128JV has no E7h/E3h. The APS6404L 0Bh in QPI has 4 wait cycles (the minimum) and no DDR.

**B1 (main finding):**
- What: fills run one at a time, from word 0, and cannot be stopped (cache.v:127, 151, 158).
- Cost: a cold taken branch is ~+130 clk over uncached (~+60 with PBURST). This explains hello 0.92x, Dhrystone 0.95x
  and Linux 1.19x.
- Fix: per-word valid (+48 flops), fill from the demand word, stop after the word in flight on a miss elsewhere. The
  prefix-count variant is +32 flops.
- Verdict: DROP for Track B. The only reversal is a csim_k4 run showing ≥10 %.
- Important: K4's critical-word-first (CWF) result does NOT cover B1. CWF still holds the bus for the whole line.

**7-CPI gap answered:**
- The "~17" is the original csim (one 88-clk fill transaction).
- RESULTS-K4 on the same trace gives CoreMark 22.35 CPI, so measured 24.4 leaves only a ~2 CPI residual.
- Likely contents of the residual: B5 per-miss overheads, the core terms, and the model's 20M-instruction init-heavy
  window.

**Other items (all DROP):**
- Posted stores (=A-1): 2-5 %.
- Short sub-word PSRAM load reads, from the first lane to the end of the word, no steering: ~1 %.
- Per-miss trims: ~1 %.
- Sticky hit_q (WO-76 class): ~1 %.
- Compressed instruction straddling into B: ≤0.3 %.

**No RTL needed:**
- The loader could enable the cache for the copy (~300 → ~65-110 clk/word). Trap: EN must be back at 0 before
  ddr_sweep's execute test.

**How to apply:** for later perf asks, use these cycle facts. Check whether B1 was modelled or built.
Related: [[finding-wo62-icache-k4-2026-11-21]], [[finding-adv-a-cache-burst-2026-11-21]],
[[finding-wo76-wo77-plan-2026-11-22]].
