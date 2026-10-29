---
name: finding-fetch-reuse-wo27-2026-10-29
description: WO-27 fetch word reuse (ROADMAP 1.3) design decisions, measured saving on compiled C, verification gaps, PicoRV32 precedent
metadata:
  type: project
---

WO-27 written 2026-10-29 in worktree AlphaOneSoC-fetch-reuse (branch fetch-reuse_alfadelta10010,
base sys-verif 18940e4), file build/wo/WO-27-fetch-word-reuse.md (build/ is disposable; the kit is in
build/wo/WO-27-measure: bench.c + count.py model). Status: design only, user decisions D1-D6 pending.

**Why:** the user asked "how would it handle two compressed instructions between two 32-bit ones" and
wanted measurement before building.
**How to apply:** when reviewing the RTL that implements it, check against these decisions.

- Measured (own kernel-like C mix, newlib-nano, Spike -l): 26.1% (-O2) / 24.6% (-Os) of fetches saved,
  65% of dynamic instructions compressed; per-function 18-46%. CPI est. 48.4 -> ~39 (-19%), about
  37.5 clk saved per hit (L - EX(C1) - 1). Zero-wait core tb CPI unchanged.
- Design: if_kbuf[15:0] (no reset) + if_kv; NO address tag (kv only survives sequential pc advance:
  stall and ex_nofetch&&!flush arms hold, every redirect is in flush on a !stall edge). kbuf captures on
  imem_req&&imem_ready (NOT imem_ready alone -- tb model raises ready with req low; NOT the IF/EX enable --
  keeps 16 loads off `stall`). imem_req gets !if_hit. Mux in FRONT of the if_exec mask (window-end
  halfword masked like a fetch). Kept only if upper [17:16] != 11.
- FENCE.I / PMP-write / MRET clears are structurally redundant (32-bit loads zero kv) -> equivalent mutants.
- Area est. ~0.75k um2 synth (0.065 t), ~1.2k placed; stays 3x4. IF path slack unknown (unnamed flops in
  the 2026-10-25 STA; worst paths are d_addr/opcode cones at 0.86 ns).
- Gaps: directed .ref suite gives only 160 hits / 27,935 instr (72 of 91 tests zero); perf-only mutants
  need a must-hit shadow checker; SoC now sees back-to-back EX (use_hazard, RF write-through) at speed.
- SMC without FENCE.I: stale window widens by one instruction (C1 or its predecessor storing to C2) -- legal.
- Precedent: PicoRV32 prefetched_high_word/mem_16bit_buffer, cleared on reset/trap/latched_branch/irq.
  KianV has no C. mem_ctrl header claim "data request only after a fetch completes" becomes "or a hit".

## 2026-10-30 implementation review (7d1404f..f7f956b): RTL APPROVED, acceptance BLOCKED on verification

- RTL matches the WO (no FETCH_REUSE param per D2). Every pc move except if_pc_next is a !stall flush edge;
  irq_inject implies !stall (needs !stall_other && !muldiv_want). Mux before mask; PMA/PMP stay on ifex_pc in EX.
- core_fetch formal: F2 (if_kv -> kbuf == h(pc)) is real and 1-inductive; FR01/05/10/12 fail it (reproduced).
  F3 is a tautology. F1's 32-bit clause is vacuous: the harness port answers from the table with no request, so
  FR03 PROVES. Gating imem_rdata on imem_req&&imem_ready (free otherwise) + lemma if_kv -> kbuf[1:0]!=11:
  real RTL still PROVED length 1 (15 s), FR03 FAILS. FR14 makes induction not close (equivalent, needs lemmas).
- BLOCKER: fr_misa.S:29 `c.addi a4,5` reads uninitialised a4 -> unmutated RTL FAILS under +RF_X. run.py's +rfx
  second pass (lines ~184-189) then "kills" every plain-suite survivor: FR12 + FR14 kills are false (sandbox
  ~/regr/fr/acc-f7f956b/out_a5/results.tsv). FR14 is equivalent after all (cdec illegal -> NOP).
  FR12 only killed by formal; core_reset is norvc so no sim reset lands with if_kv=1.
