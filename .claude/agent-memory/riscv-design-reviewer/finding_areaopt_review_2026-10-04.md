---
name: finding-areaopt-review-2026-10-04
description: Review of area-opt_alfadelta10010 (13 area/perf commits ff130fb..3c25950 on 10a37c3) -- no Crit/Major; RTL correct; directed suites miss the rewritten datapath (SRA/MULHSU/SLTU), PMP-write refetch, fetch-PMP under MPRV+lock, rs2 snoop
metadata:
  type: project
---

Reviewed 2026-10-04 at 2209bb0. Full report: localFiles/area-opt-2026-09-30/review/REVIEW.md
(probes/, mut.py, rgen.py, rrand.sh, rirq2.sh, trees/ there too).

Stack: muldiv during fetch wait; imem_req low while CTI in EX (ex_cti); RF no reset
(boot_flash zeroes, +RF_X sim); one 34-bit add/sub muldiv; CSR *_legal stores; 1-clk
csr_wb_hazard stall instead of CSR forwarding (+mcycle_wr_q); EX/WB consolidation (link=pc,
CSR rdata in exwb_alu_result, AMO old value in exwb_trap_val); one time-shared PMP checker
(fetch lo/hi phases only when U-mode or any lock); shared comparator; decompress in EX; one RF
read port (rs2_phase + snooping rs2_hold); serial shifts in muldiv.

Verdict: no Critical/Major. Evidence: core 116/116 reproduced; muldiv vs independent golden
39,120 ops 0 err; ~3,600 random lockstep runs (M, traps, timer irq, U-mode, U+irq, M+lock,
SoC) 0 mismatches.

Findings (all verification, PROVEN by mutant + probe):
- m1: no directed test runs SRA/SRAI, MULHSU/MULHU, MULH neg multiplier, SLTU mixed sign.
  mul_nosub, mulhsu_unsigned, sra_nofill, sra_wire0 (fyracore .sra(1'b0)), sltu_signed all
  pass 116/116; unit tbs catch 3, nothing in repo catches sra_wire0. river_core not run.
- m2: PMP-write refetch (ex_pmp_csr_wr) is NECESSARY (locked entry present -> lo phase latched
  in csr_wb_hazard cycle with old cfg) but untested; fetch-PMP privilege under MPRV untested
  since the time-share (mprv.S lost sensitivity: no lock -> no fetch phase in M).
- m3: rs2_nosnoop killed only by cnt_instret (3/116); link_plus4 (c.jal link) only by irq_stress.
- Nits: mcycle_wr_q loses one count per write (legal, tb-driven); stale "forwarding"/"both
  checkers"/"one cycle per PMP write" comments; exwb_instr dead.
- Efficiency: hold fetch behind ecall/ebreak/mret/fence.i too (decode-only terms, never ex_trap);
  refetch replaceable by gating phase latch with !csr_wb_hazard; mstatus_after_we dead in
  trap/MRET arms; compressed-pair fetch buffer would expose all the "hidden" EX stalls.

**Why:** gate before merging the area stack. **How to apply:** if asked again, check whether
the 5 probes landed in tests/directed and whether river_core ran on the stack.
Related: [[patterns-recurring]], [[verification-flow-river-core-riscof]].
