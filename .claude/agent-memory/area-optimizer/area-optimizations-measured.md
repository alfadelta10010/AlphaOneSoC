---
name: area-optimizations-measured
description: Every area optimization prototyped (2026-09-26/27), flat-SoC delta as mean of two file orders, directed-suite status, kept/rejected and why
metadata:
  type: project
---

Deltas vs 148,596 µm² flat SoC at 605b9d0 ([[area-baseline]]); mean of fwd+rev file order;
1 tile = 11,300 µm². All prototypes live in `localFiles/area-audit/v_*` / `c_*`; nothing in src/.
"101/101" = core-level tests/directed suite passes on the variant tree.

Compliance-preserving (low risk):
- Unified muldiv (one 34-bit add/sub): −10.8k (−0.95 t), −193 ff. 40,800-op equiv (09-26).
- EX/WB consolidation (ifex_pc_next==pc; link+CSR rdata into exwb_alu_result; csr_wdata and
  AMO new value into exwb_rs2_data; AMO old value into exwb_trap_val): −6.5k, −191 ff, 101/101.
  NB tb reads exwb_csr_wdata (tb_rivercore.v:535) — keep an alias wire or t_warl fails.
- CSR WARL read masking: −5.7k, −155 ff. CSR stall-instead-of-forward adds −1.5k (the old
  v10 tied wval=0 which the tb trace needs; keep wval for tb, it prunes in synth).
- RF sync-reset removal −3.6k; single time-shared PMP checker (fetch verdicts latched in
  stalled EX cycles) −3.0k 101/101; shared branch/SLT comparator + one shifter −1.4k;
  decompress in EX (drop ifex_instr) −1.1k 101/101.
- Combined c_low (all above, flop RF): 116.5k = 10.31 t. With ICG RF: 103.3k = 9.14 t.
  With latch RF: 99.2k = 8.78 t (c_low_latch: core 101/101 with v_csrstall3 csr.v, SoC 64/64,
  SoC cycle counts identical to base on 14 tests).
- CSR stall: rdcycle right after csrw mcycle reads written+1 (cnt_alias vs Spike); one flop
  (skip the increment the cycle after a mcycle write) restores Spike equality (v_csrstall3).
- ICG-RF sim: behavioural dlclkp must treat an X GATE as closed (pre-reset wrEn/rd are X),
  else every register loads X (models/sky130_beh.v). With that, failing tests pass.
- Trade stacks on c_low_latch (1-run): 1 PMP entry 8.08 t; +resv_all+mcause 7.87 t (7.74 w/
  clockgate); PMP 0 + resv_all + mcause 7.58 t (7.39 cg); + drop C, cg 7.26 t.
- Single-read-port RF (rs2 read into a hold reg in a stalled EX cycle, hold snoops RF writes):
  −0.27 t on c_low_latch -> c_1rp 8.51 t; core 101/101, SoC 64/64. Stacks on c_1rp: +PMP1e+resv_all+mcause 7.64 t
  (7.48 cg); PMP0 + drop C + all + cg 6.91 t (only config under 7 t; breaks RV32IMAC+PMP goal).
RF physical options: flop+ICG per register −18.3k (80% of latch win, no latches); latch
−22.5k; both need dlclkp in CTS (unhardened). yosys `clockgate` pass: −12.3k on baseline but
mostly the RF; only −1.2k on top of c_low_latch.
Feature trades: PMP 0 entries −15.3k; PMP 1 entry −7.5k / 2 entries −4.5k (on c_low_latch);
drop C −3.2k; resv set = all memory −1.6k; mcause WLRL −1.4k.
REJECTED (measured ~0): PMP NA4-via-NAPOT + TOR lt sharing (−0.05k), AMO single adder
(ABC already shares the 4 comparators), CLINT word-only writes (−0.3k, noise), PMA compares
(0.2k total), datapath reset removal.

Key insight: in the SoC every instruction waits ~45 clk in EX for the next fetch, so EX-side
serialization is free IF it runs during that wait. muldiv_start waits for !if_mem_stall, so an
M op serializes with the fetch and discards/refetches a completed fetch (perf, not area).
**How to apply:** start new work from c_low-equivalent RTL; don't re-try rejected items.
