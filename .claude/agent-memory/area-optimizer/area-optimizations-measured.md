---
name: area-optimizations-measured
description: Every area optimization prototyped on scratch copies (2026-09-26), measured flat-SoC delta, functional check status, kept/rejected and why
metadata:
  type: project
---

All deltas vs 148,728 µm² flat SoC ([[area-baseline]]). Prototypes were scratch-only;
nothing merged into src/ (report-only task).

Compliance-preserving:
- Latch regfile (992 dlxtp_1 + 31 dlclkp_1 ICGs + 32-bit write-data flop, DFFRAM style;
  write in cycle N visible to reads in N+1, same as flops): **−22,657**. Standalone RF
  50.9k -> 27.8k. Sim needs behavioural cell models (`ifndef SYNTHESIS`).
- Unified MUL/DIV (one 34-bit add/sub, acc/lo/m regs, signed MUL via final-step subtract,
  div operand/result negation through the same adder, 34/36 cycles): **−10,636**.
  Equivalent to old muldiv on 40,800 ops (8 ops x 100 corner pairs + 40k random).
- CSR read-side masking (`X = X_q & MASK` for mstatus/mie/mcounteren/mcountinhibit/mtvec/
  pmpcfg0, misa only C stored): **−5,859**. Root cause: the shared `wval` write mux in
  csr.v hides constant bits, so ~150 dead flops survive synthesis.
- Pipeline reg sharing (csr_wdata->rs2_data slot, pc_next->csr_rdata slot, AMO temps
  into those two): **−3,817**.
- Regfile sync-reset removal (flop RF): −4,131 (subsumed by latch RF).
- ALU one right shifter (SLL by bit-reverse) + one add/sub: **−1,202**, 400k-vector equiv.
- Combined c1b (latch RF + muldiv + CSR mask + sharing + ALU): **104,966 (−43.8k)**.
- REJECTED: datapath-reg reset removal ≈ 0 (−36; sync-reset ANDs just become edfxtp
  enables). Shared AMO add/sub +115 (yosys already shares).

Feature trades (spec-legal, need user decision):
- PMP 4 -> 0 entries: **−14,788**. Zero entries => U-mode accesses succeed (Priv 3.7.1).
- Drop C: −3,405 alone, −3.0k in combination. Every directed test is built rv32imac and
  aborts on the first compressed instr until the suite is rebuilt for rv32ima.
- CSR stall-instead-of-forward (1-cycle EX stall behind any CSR write, per-register D
  inputs, no wval mux): −7,123 but includes the masking win; incremental ≈ −1.3k.
- LR/SC reservation set = all memory (legal: set "subsumes" the word): −1,582.
- mcause WLRL to int bit + 4-bit code: −1,191.
- All trades c2b: **84,091**; all but C (c2c): 87,124.
- Estimated only: single-read-port latch RF ≈ −4.8k net (standalone −5.75k).

Directed suite (tests/directed/run.sh, scratch tree copy): baseline 99/99. See report
of 2026-09-26 for c1/c1b/c2c results.

**Why:** 79k µm² target (~7 TT tiles at 60% density).
**How to apply:** don't re-try the rejected items; start new work from c1b-equivalent RTL.
