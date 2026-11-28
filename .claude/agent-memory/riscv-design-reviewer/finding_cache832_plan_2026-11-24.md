---
name: finding_cache832_plan_2026-11-24
description: WO-cache832 planning (256 B I-cache as 8 x 32 B to halve tags for the top-left routing pocket): sectored variant S recommended over whole-line L; model, area, tCEM, formal facts
metadata:
  type: project
---

WO: localFiles/wo-4x4/WO-cache832.md. Notes, model and sketches: localFiles/wo-4x4/cache832/. Base edaf17d.

**Key design fact:** "8 x 32 B" can be built SECTORED (S: 8 tags x 17, 16 valid bits, one per 16 B sector, a miss
fills one sector). kidx/fill_idx = addr[7:4] stay the sector, so the macro addressing, m_addr, m_burst, PBURST,
the WO-72 tCEM proof (101 clk, LPB 104) and the cache formal depths are all UNCHANGED. The RTL delta is 5 lines:
tags[135:0], kline = kidx[3:1] for tmatch and the tag write, and at start `if (!tmatch) valid[{kline, ~kidx[0]}] <= 0`
(drop the sibling sector on a tag change). The whole-line variant L (8-word fills) needs a qspi_ctrl l.384 change
(addr[4:2] != 7), LPB 184 (E(7) = 173 + 8L = 181), PBURST floor 23 MHz -> rule 25 MHz, lemma widths p[3:2] -> p[4:2],
E3 -> E7, NVDEPTH ~270, bmc ~330, and cache BMC 18 / cover 34 become too shallow.

**Measured 2026-11-24:** model csim_px8 (PX-M + DF=1 data-first preemption; calibrated -0.25..-1.9 % on the CoreMark
RTL points), cache+PBURST vs 16x16: S CoreMark -3.8 %, Embench -2.2 %, FreeRTOS -10.2 %; L -8.3 / -4.0 / -13.5 %;
L with 2x4 bursts -10.3 %. syn1.sh area: today 17,243 um2 / 316 flops, S 10,982 / 180, L 10,118 / 172.
The S prototype passed tb_cache (with the floors redefined per line) and the formal set: cache BOUNDED 18,
cache_cov 16/16, cache_pt + cache_ind PROVED, cache_en 12. Its negative control (no sibling clear) FAILS cache
within 18 and tb_cache (5,852 errors). The "always clear sibling" mutant is perf-only and needs a white-box keep check.
RTL prototypes (sandbox ~/scr/px/c832{ref,S,L}, lad.sh quick): on+PB CoreMark ref 54,755,938 / S -4.34 % / L -8.59 %,
FatFs 44,448,707 / -3.95 % / -8.74 %; on-only S CoreMark -6.24 %, FatFs -5.19 %. The model is within 0.5 pt on CoreMark.
The 4x64 sectored variant (model: CM -7.6 %, -68 more flops) dominates L as the area fallback.

**Why:** the pocket is 85-90 % I-cache tag logic; the target is -9k post-PnR; S is ~-8k placed by x1.27 (at the edge).
**How to apply:** when reviewing the implementation, check the sibling clear and the tb keep check. Do not re-plan
L unless the user rejects S. Related: [[finding_wo76_wo77_plan_2026-11-22]], [[finding_trackb_rtl_2026-11-22]],
[[finding-adv-a-cache-burst-2026-11-21]].
