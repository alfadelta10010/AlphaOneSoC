---
name: feedback-report-in-tiles
description: User wants all reported area figures in TinyTapeout tiles (1 tile = 11,300 µm²), not µm² or GE
metadata:
  type: feedback
---

Report every area figure (per-block tables, deltas, cumulative totals, gap to budget) in
TinyTapeout **tiles**, 2 decimals (e.g. −2.01 tiles), stating the factor once at the top:
1 tile ≈ 11,300 µm² usable std-cell area at TT's 60% density (7-tile budget ≈ 79,000 µm²).
Keep flop counts as counts. Measure internally in µm² with the same yosys script.

**Why:** user asked for it directly (2026-09-27, relayed by the coordinator) — tiles are
what they pay for.
**How to apply:** any area report or table for this project; see [[area-baseline]].
