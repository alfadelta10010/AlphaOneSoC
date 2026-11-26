---
name: csr-uart-slim-2026-11-24
description: 2026-11-24 measured CSR/PMP/UART trim menu at edaf17d (TT-cell synth, mean of 4 structural perturbations, core-level for CSR/PMP); what is zero, what is legal, recommended A+B+D
metadata:
  type: project
---

Report: localFiles/wo-4x4/CSR-SLIM-ANALYSIS.md (CSR + UART sections). Synth prototypes only, no functional check.

**Method facts (reuse):** yosys is deterministic and renames change nothing; noise comes from
structural rewrites (move read arms / reorder disjoint arms): CSR +-470, flat core +-520, UART +-60.
Average 4 such variants. Flat fyracore synth (rf_top blackbox) takes only ~10 s / 80 MB: do CSR/PMP
deltas at core level. Post-PnR ~= TT-cell synth x1.33 (CSR 36k/26.9k, UART 13.5k/9.96k).
The coordinator's 23,835/479 = csr as top, wval_out kept, _1 cells allowed.

**CSR baseline:** 26.9k TT-synth alone; 455 flops in the flat core (the standalone 471 includes 16
mstatus hold flops that the flat core removes, so an mstatus trim = 0). A stored bit is ~47 um2
(dfxtp_2 21.27 + mux2_1 enable + ~5.6 sync reset + read-mux share), ~64 if trap-captured.
Counters 9.0k (incrementers 3.0k), PMP regs 7.1k, read mux ~3.5k.

**Core-level deltas (base 87,950):** A reset removal on mtvec/mscratch/mepc/mtval/pmpaddr -1.42k;
B mcause int+4-bit code -0.97k (-27 ff); A+B -3.19k; D PMP G=10 + PA[33:32] RO-0 -3.69k;
A+B+D -6.56k (~-8.7k post-PnR, recommended); PMP 2 entries -6.61k, 2+G10 -8.54k, 1 entry -9.59k,
0 entries -13.85k. Zero/worse: one-hot or minimal-decode read mux, inc64 alternatives, misa RO,
time alias drop, mstatus/mcountinhibit/mcounteren trims. mtval RO-0 -1.77k breaks Linux misaligned
emulation. ICG on the CSR -2.5k (standalone) but dlclkp is in no_synth.cells.

**UART (9,960 / 201 ff):** RX path 46 % (FIFO ~0.46k/entry). Lean 16550 (no SCR, loopback/MSR,
BI/FE/FIFOERR, SBC, EDSSI) -1.74k; +8-bit divisor -2.53k; +FIFO4 -3.18k; all -3.99k.
SiFive-style sketch 7.42k (FIFO 8): only ~0.8k under the lean 16550, with full software ripple.
Linux of_serial sets UPF_FIXED_TYPE, so no autoconfig: no SCR or loopback test ever runs.

**How to apply:** start any CSR/UART area work from this; don't re-measure the zero items. See
[[review-2026-11-22-area]], [[spec-legality-notes]], [[area-optimizations-measured]].
