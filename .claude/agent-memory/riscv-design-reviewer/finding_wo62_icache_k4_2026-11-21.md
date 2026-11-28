---
name: finding-wo62-icache-k4-2026-11-21
description: WO-62 K4 I-cache review (src/cache.v d731917/856607c, SoC hookup 01bfad7): no RTL defect, accept with 6 should-fixes; report localFiles/wo-4x4/reviews/WO-62-review.md
metadata:
  type: project
---

K4 = 128 B DM, 16 B lines, I-only, tags/valid in flops, data in one rf_top, EN=0 pass-through (induction-proved),
snoop = completed store invalidates line (shares tag compare), fill 4 aligned reads line order + early restart.
SoC hookup is COMMITTED (01bfad7, 8dcd068, cba0e5f, 2891c95), not deferred any more.

Verdict 2026-11-21: accept with should-fixes, no blocker. Traced clean: request hold, hit_q one-shot ready,
on/off takeover, straddle (A/B checks, port collision impossible), snoop/dead fill, fencei, AMO/SC, collide rule.

Open should-fixes (check status next time):
- SF1 flash fills emit i_addr 0x00xx_xxxx (cache.v:180) -> violates mem_props M-A2; fix bit29 = ~fill_tag[17].
- SF2 mem_ctrl.v:11-24 bound 449/482 + mem_props M-A4/P_LI not discharged with EN=1 (fill starvable, harmless).
- SF3 contract props A/C/D only BMC 18/12 -> cheap induct harness with data free.
- SF4 no SoC run with +CACHE_EN=1, no SW writes CACHE_CTL, A5 CoreMark unmeasured.
- SF5 STA: macro clk->q (4 ns placeholder) into IF/EX+pc (fyracore.v:206 premise broken), EN=0 muxes on stall net
  (sbm setup +0.227), hold on zero-logic macro pins, snoop path.
- SF6 PSRAM fill = 4x42 clk vs model 88 (one transaction) -> 2.60x optimistic for PSRAM/Linux; critical-word-first option.

**Why:** cache is the user's priority (U2) but droppable; EN=0 proof bounds silicon risk to "leave EN off".
**How to apply:** on re-review, verify SF1-SF6 status; don't re-raise traced-clean corners. Area: logic is lean,
routing (macro blockage ~8 GRT pts) dominates; only geometry change (4x32 B, ~-2.9k synth) is a real logic cut.
Related: [[finding-qspi-stream-ddr-review53-2026-11-08]], [[finding-rf-macro-review-2026-10-11]].
