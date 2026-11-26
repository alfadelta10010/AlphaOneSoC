---
name: finding-adv-a-cache-burst-2026-11-21
description: ADV-A review of the K4 I-cache + PSRAM line burst at d3eb898 -- no RTL defect; real coherence window (d=2 only), proof-strength facts, open verification items
metadata:
  type: project
---

Report: localFiles/wo-4x4/reviews/adv-4x4-2026-11-21/A-cache-burst.md. Verdict: 0 blocker / 0 major, RTL clean.

**Coherence fact (PROVEN, reuse):** stale fetch after a store is possible ONLY for the fetch that completes in the
store's own d_ready cycle (hit_q toggles 1/0 while the core is stalled in WB; parity decides) plus the EX instruction
and if_kbuf. WO-71 dump decoded by distance d=s-e: off NEW at d>=2; EN/EN+PBURST OLD at d=2 (24/24), NEW at d=3.
Docs d3eb898 "up to three words" is wrong (understates); property B of cache_props is the true contract.

**Proof-strength facts:** qspi_burst_eq PROVED + sound (asserted helpers, 1-inductive, ref == main qspi_ctrl).
mem_tcem_burst pdr TIMEOUT; bmc 250 ~ one window after init (wo68b cex at step 227); word-3-guard mutant never got a
verdict. cache data property B = BMC 18/12 only; cache_ind = handshake only. No QB/C mutation or cache-BMC nonvac
results in ~/acc logs (only QS09, survived all but unit qspi). C05 (FENCE.I flush ignored) is equivalent, not marked.

**Unreachable/invalid holes:** snoop+word_in same cycle (i_ready/d_ready exclusive); IO stores never snoop (mem_d_ready).

**Open asks:** PBURST coupled to STREAM (fallback coupling), 15 MHz floor SW-only, chain2 + 10 MHz tCEM negative
control + adv_ctl/reboot/irq not run; pins §12 / CLAUDE.md still say PBURST "not committed".

**How to apply:** on re-review check these open items; don't re-raise the traced-clean races listed in the report.
Related: [[finding-wo62-icache-k4-2026-11-21]], [[finding-final-prelock-2026-11-21]].
