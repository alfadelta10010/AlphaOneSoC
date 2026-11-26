---
name: finding_trackb_rtl_2026-11-22
description: Track B RTL review @ff0b20f (WO-77 256 B cache 66a77e7, WO-76 fetch hold 16327b5, uart_linux b0e4805): 0 blocker/major; collision-argument gap, combined-SHA evidence gap, RDA check lost
metadata:
  type: project
---

Report: localFiles/wo-4x4/reviews/trackb-rtl-2026-11-22.md. Verdict: no BLOCKER/MAJOR; RTL == WO text.

Traced clean (don't re-raise): 256 B geometry (kidx addr[7:4], tag {a31,a[23:8]}, nxt[5]/nxt[4:0]
for B); 7->8 and 15->0 straddle per-port select; sync-read select valid because f_req drops only after
ready; w_ena split; M-A2 fill addr; snoop/dead/fencei statement order; snoop uses mem_d_ready so IO
stores never alias flash keys. WO-76: if_wv cleared on every !stall edge, irq_inject implies !stall,
ex_nofetch decode-only so no CTI/FENCE.I/PMP-write in EX while held; H-L2 because EX/WB stall arm
bubbles and wb_busy sets only on !stall; DF_N 3 max with hold (5 without the data terms);
lower-half mux depth unchanged, upper-half mux flop-D only (RF addressed from ifex_rf_* flops).

Open items: M1 cache.v:29-32 collision comment covers only port A/selected macro; port B
(aligned fetch, pc1=0 discards) and cross-macro (unselected macro, f_addr[7] mux discards) collisions
exist -> suggest cache_props assertion "selected port never collided before hit_q". M2 VALIDATION B2
has no WO-76 acceptance verdicts; WO-77 acceptance ran on 2a2978e (pre-WO-76) -> combined-SHA run.
M3 b0e4805 correct 16550A semantics but no SoC check that RDA 0xC4 ever fires (first IID of phase 5
is deterministically 0xC4). N1 extra mux on macro-Q fetch path + data_hi hold pins (STA gate).
N2 WO-76 leaves flash stream idle-open unbounded (WFI) -> run fh_* under soc with EN=0 flash code.

**Why:** single shuttle, freeze 2026-11-25. **How to apply:** next review check M1-M3/N1-N2 status;
related [[finding_wo76_wo77_plan_2026-11-22]], [[finding-wo62-icache-k4-2026-11-21]].
