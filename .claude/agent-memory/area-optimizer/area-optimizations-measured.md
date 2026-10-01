---
name: area-optimizations-measured
description: Every area optimization prototyped (2026-09-26/27, PR #5 review 2026-09-29, 10a37c3 corroboration 2026-09-30), flat-SoC delta, directed-suite status, kept/rejected and why
metadata:
  type: project
---

**2026-09-30 corroboration at 10a37c3 (supersedes the numbers below for planning):** 14-patch
series in `localFiles/area-opt-2026-09-30/patches/` (report: corroboration.md there), each
step core 116/116 + SoC 75/75; finals also pass with `+RF_X` and `make test-all`.
Order and paired step deltas: mdfix 0, brhold +0.04 (noise), #1b -0.38, tests-x-clean 0,
#3 -0.93, #4 legal stores -0.22 + stall -0.35, #5 -0.53, #8 -0.25, #13 -0.11, #16 -0.08
(-0.10 as removal from final), #9 -0.48 (bigger on flop RF than the -0.27 latch claim),
#10 serial shifts in muldiv -0.29 (was -0.15 E) -> **10.04 t, 2,205 ff (81% of 6x2)**;
#1a ICG RF -1.01 -> **9.03 t (73% 6x2, 110% 4x2)**, lead/user decides (flow risk).
Individually on 10a37c3: #1b -0.31, #1a -1.58 (incl. 1b), #3 -0.91, #4 -0.66 (masking alone
-0.33), #5 -0.53, #8 -0.24, #13 -0.09, #16 -0.02, #9 -0.48, #3+#10 -1.17.
Trades on top of 9.03 t: PMP 0 -> 8.07 t, PMP 1 -> 8.36 t (4x2 not reached with margin).
REJECTED 2026-09-30: forwarding -> RAW stall (-0.07 t on final, no timing gain).
Gotchas found: CSR stall moves the mtip_stale spurious-IRQ window (MANIFEST pins updated);
mcycle skip-increment flop must cover mcycleh too; 4 directed tests read unwritten regs
(enc_probe a1, mie_enable s2, t_mstatus s11, u_straddle s1) -- fixed at entry; masking only
pays once `wval` stops feeding forwarding; tb_regFile/tb_alu/tb_muldiv need edits for
#1b/#9/#13/#10. User rule 2026-09-30: register file must NOT be latches.

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

PR #5 review (2026-09-29, vs 4b4ed8b = 13.61 t, 6-order mean; see [[area-baseline]]):
- Full-ISA stack c_1rp re-measured with 4b4ed8b's counter-write fix + LR/SC keep ported
  (`localFiles/area-audit/pr5/h2_1rp`): 8.92 t (4 orders) vs 8.87 t unported. 6x2 at 72%.
- UART divisor 16->8 bit: -0.06 t, -16 ff (standalone; min 12.2 kbaud @50 MHz). Fixed divisor
  (DLL/DLM writes ignored): -0.09 t, -24 ff (feature trade). Prototypes in pr5/uart8, pr5/uartfix.
- Zero-cost confirmed: boot_addr tie-off (generic netlist identical), in_win PMA vs hand-minimised
  bit decode (+0.01 t), counter carry-in reformulation (+0.02 t = noise, so the counter fix's
  ~+0.06 t is not recoverable by rewriting).
- Perf fixes mdfix + brhold ([[soc-performance-measured]]): 0.00 t (4 orders); core 106/106 and
  SoC 66/66 on both mdfix alone and mdfix+brhold (local, 2026-09-29).
- Duplicate RX synchroniser (UART vs GPIO IN[3]): 2 ff, ~0.004 t, not worth it.

Key insight: in the SoC every instruction waits ~45 clk in EX for the next fetch, so EX-side
serialization is free IF it runs during that wait. muldiv_start waits for !if_mem_stall, so an
M op serializes with the fetch and discards/refetches a completed fetch (perf, not area) --
fixed at ~0 area by mdfix. With brhold a CTI has no fetch in flight, so EX stalls on branches
(e.g. the 1-read-port rs2 phase) are no longer hidden: +1 clk per branch.
**How to apply:** start new work from c_low-equivalent RTL; don't re-try rejected items.
