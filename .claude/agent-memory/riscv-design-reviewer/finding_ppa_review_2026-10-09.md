---
name: finding-ppa-review-2026-10-09
description: PPA/claims review of area-opt_alfadelta10010 (10a37c3 -> 30eacb1) -- relative area cut real, but tile numbers ~24% low vs the TT flow cell set, no TT harden completes (RF self-loop hold buffers), tip slower than main at tt, #1b saves nothing
metadata:
  type: project
---

Reviewed 2026-10-09/10. Evidence: localFiles/area-opt-review-2026-10-09/ppa/ (scripts synll.sh,
synsta_buf.sh, xrun2.sh, irqrun.sh, cbmu.sh, socsuite.sh, steptab.py; harden/tt_um_alphaone_ppa.v).
Sandbox projects /home/mempool/tt/projects/ppa-rev-{main,tip,tip8,tip6d80,tipicg}.

- C1: the branch's syn recipe allows `_1` cells + edfxtp; LibreLane 3.0.5 (TT) excludes 199 cells
  incl. dfxtp_1/edfxtp_1/nand2_1/dlclkp_* (no_synth.cells). TT-flow synth: main 16.58 t, tip 12.52 t
  (=101% of 6x2) vs recipe 13.61/10.07. Relative cut holds (-24%). Post-CTS std-cell ~1.64x recipe area.
- C2: ALL hardens fail DPL-0036 in antenna repair (main@8x2, tip@6x2 d60/d80, tip@8x2 at 61% util).
  Failing instances = hold buffers on RF Q->mux2->D self-loops (~950-1000 dlygate4sd3_1); cause is
  TT SDC clock uncertainty 0.25 ns (hold too) + 0.1 margin. Pre-existing on main.
- M1: #1b RF no reset = +0.08 t in TT cells (claimed -0.38): reset folds into the enable a22o.
- M2: unbuffered OpenSTA metric is noise (dead-code commit moved it 4.8 ns). Real flow 8x2 post-CTS:
  tt WNS main +4.26 vs tip +2.90; ss -8.81 vs -9.45. Tip crit path = muldiv isdiv->34b ripple add/sub
  ->sum[33]->acc mux (shared adder #3). Fix: non-restoring div / registered add-sub control.
- M3: patch 14 (ICG RF) fails TT lint (MULTIDRIVEN x32) and synth checks (reg_file[0] undriven x32).
- Perf reproduces: C bench 56.10 -> 48.42; ex_nofetch -2.03% on directed suite, 0% on C bench.
  U-mode CTIs +1 clk (C bench in U +0.23%); shift runs block irq (avg 108 -> 433 clk); zero-wait CPI +52%.
- GRT routing demand: main@8x2 144%, tip@6x2 184%, tip@8x2 132%. tip+ICG RF @6x2 (lint/synth-check
  gates off): 420 hold buffers (vs 1,299), 70.9% util, tt WNS +4.41, GRT 104%, PASSED antenna/DPL, but
  detailed routing stuck at ~371k DRC violations after 3 iterations (stopped). ICG RF is necessary, not sufficient.
- Commit 9fcb21d smuggled 5.7 MB of datasheet PDFs/txt under a muldiv-doc message.

**Why:** area/shape claims gate the tapeout tile purchase. **How to apply:** never accept a tile
figure that wasn't produced with the TT cell set (synll.sh) or LibreLane; ask for a completed harden
before any shape claim; check RF hold-buffer count in any harden. Related: [[patterns-recurring]],
[[finding-areaopt-review-2026-10-04]].
