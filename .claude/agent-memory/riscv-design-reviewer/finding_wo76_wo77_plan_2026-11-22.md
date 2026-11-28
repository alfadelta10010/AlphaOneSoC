---
name: finding_wo76_wo77_plan_2026-11-22
description: Track B planning (WO-76 fetch hold, WO-77 256 B I-cache): both 2026-09-29 wasted-fetch prototypes already merged (9dc7443, ff130fb); residual discard analysis, hold-register rules, DF_N trap, third-macro fit risk
metadata:
  type: project
---

Planning session 2026-11-22 for Track B (= gate-a-4x4 7902a86 + WO-76 + WO-77, ship only if full gate
by 2026-11-27). WOs: localFiles/wo-4x4/WO-76-wasted-fetches.md, WO-77-icache-256.md.

**Stale doc trap:** docs/soc-architecture.md ~l.885 "Stop the two wasted fetches (prototyped...)" is
stale. Branch hold = 9dc7443 (2026-10-01; d19ceed 10-04 added ECALL/EBREAK/MRET/FENCE.I/PMP: ex_nofetch l.672), M-op-during-fetch = ff130fb (muldiv_start on
stall_nofetch, l.903); both in gate-a-4x4. Don't re-plan them.

**Residual discard (real):** a fetch completing on a stalled cycle is thrown away and re-requested.
- cache on: aligned hit ready in EX cycle 2 (ex_wait) -> discarded; cache blocks look on the hit_q
  cycle -> re-ready 2 later: 4 clk/insn instead of 3 (straddle 3, kbuf hit 3 unaffected).
- cache off flash stream: M op (34-36 clk) outlives an 18-clk continuation; refetch of p-4 closes the
  stream -> 57-clk read, ~40 clk lost per M op.
- WFI: endless refetch (cache off: QSPI busy whole WFI); irq_inject waits for !if_mem_stall.
Fix = if_wlo[15:0] + if_wv (upper half already in if_kbuf); set only when stall && fetch completes
&& !dmem_req && !wb_busy; clear on every !stall edge (irq_inject implies !stall).
**Why the data terms:** without them DF_N (core_df / M-A4 of mem_li) goes 4 -> 5 (W AMO 2 + X AMO 2 +
kbuf c.lw/sw 1 after the held fetch handshake) and a store could complete under a held word (new
SMC-vs-Spike staleness). EX/WB bubbles on non-mem stalls, so no data request can start while held.
Upper-half mux only (lower half keeps depth: next-pc path). tb_rivercore C-musthit uses
imem_rdata[17:16] -> must become if_fetched[17:16].

**WO-77:** macro select addr[7] (index[3]) keeps each macro's pins = today's functions; per-port
selects (port A f_addr[7], port B nxt[5]) for 7->8 / 15->0 straddles. New instance named `data_hi`
(not data_mem_*: gls_sdf/prep.py str.replace on SDF would half-rename a prefixed name). fsmcut.py
must give BOTH macros own w_ena/rb_addr pin nets (f0ca0b2 failure mode). tb_rivercore lacks
+CACHE_PBURST (tb_soc_periph has it).
**Fit:** hd-r util 71.90 %, GRT 70.20/123 vs ceiling 71.83/117: a third macro (15,744 um2 + halo)
+ ~136 tag/valid flops ~ +7-8 util points -> planner says no fit without cuts; PD screen gates WO-77.

Recommendation given: two sequential WOs (76 first), one gate on the combined SHA, Track B RTL
freeze 11-24 EOD; WO-76 gain likely small (est. 3-8 % cache-on) -> measure before the gate.
