---
name: finding_adv_tip_cache_2026-11-25
description: Adversarial slice B @f75a734 (cache832 sectored 8x32 B I-cache + neighbours + WO-76): 0 blocker/major; sector invariant only BMC 18, M-A5 unasserted, no RC/EQY on cache832, HM5 survivor, 4 doc NITs
metadata:
  type: project
---

Report: localFiles/wo-4x4/reviews/adv-tip-2026-11-25/B-cache.md. Verdict: no BLOCKER/MAJOR.

**Key correctness argument (don't re-derive):** tags written ONLY at `start` (cache.v:172), which clears own sector
and, on !tmatch, the sibling (l.170-171) => valid[s] -> data of tags[s>>1]. Snoop/fencei/off never write tags.
start needs look needs !snoop, so no same-edge tag write vs store. Straddle A/B never same line w/ different tag.
Word 3 of a filling sector never early-restarts (kword<fcnt impossible). WO-76: FENCE.I in EX => ex_nofetch => no
hold; if_kv 0 after a 32-bit FENCE.I.

Open (MINOR): B1 sector invariant only BMC 18 -> ghost gtag lemma in cache_ind; B2 cache side of mem_tcem_burst's
M-A5 (m_burst -> m_req, aligned, a31) asserted nowhere (harnesses leave m_burst unconnected); B3 no river_core/EQY/GL
on cache832 (RC-SOC ran on ff0b20f WO-77), tb/eqy EXPECT never refit for -136 tags; B4 HM5 (dead off for data_hi)
survives adv_trackb_mut, no proof tb_cache/formal kill it.
NITs: qspi_ctrl.v:146 says tCEM "bounded, pdr open" but mem_tcem_burst is sind PROVED (5ea36a0); miss-wait bound
476/581 omits straddle double-miss (+1 word, ~524); "EN 0->1 starts cold" false if EN rewritten 1 during a pending
fill (off never fires; harmless); "line" = 16 B in neighbours vs 32 B in cache.v.

**How to apply:** next review check B1-B4 status; related [[finding_cache832_plan_2026-11-24]],
[[finding_trackb_rtl_2026-11-22]] (M1/M2 now closed).
