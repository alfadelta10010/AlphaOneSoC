---
name: finding-areaopt-compliance-2026-10-09
description: Compliance+hazard review of area-opt tip 30eacb1 incl. ef9037d ex_nofetch -- no Crit/Major; ex_nofetch decode-only proven; repo tests miss the decode-only property; +RF_X blind spot; refetch arms redundant
metadata:
  type: project
---

Reviewed 2026-10-09/10 at 30eacb1 (main 10a37c3). Artifacts: localFiles/area-opt-review-2026-10-09/compliance/
(REPORT.md was BLOCKED by the subagent harness -- the report went back in the handback text instead;
probes/, scripts/rgen2.py + rr.sh + mut2.py, out/mut_results.txt, out/phase2.txt).

Verdict: no Critical/Major. ex_nofetch (fyracore.v:503) uses only IF/EX-register decode; IF/EX and pc
change only on !stall, so imem_req never drops mid-fetch. ~3,000 lockstep runs (core 6 timings x
none/trap/mlock/umode/irq/uirq + 65 SoC) with the extended generator (MRET, malformed SYSTEM, PMP writes,
SMC+FENCE.I, WFI, MPRV, misa.C toggles): 0 mismatches, ~133k irq handler entries.

Findings:
- m1 PROVEN: mutants nf_illegal (nofetch |= ex_illegal_insn) and nf_trap (ex_trap) pass all 121 directed
  runs; killed only by probes/nf_misa_c.S at +IMEM_WAIT=2 (fixed phase; random wait missed it) and by the
  extended random flow; SoC req_hold_check fires on QSPI engine too. Fix: add nf_misa_c to directed suite.
- m2 PROVEN: +RF_X misses X used only by a branch whose not-taken arm equals Spike's 0-init outcome
  (rfx_blind bnez passes, rfx_caught beqz fails). docs/CLAUDE.md:128, regFile.v:26 overclaim.
- n1: PMP/FENCE.I refetch arms (flush terms + next_pc arm 1049) are redundant with ex_nofetch; each of
  pmp_noflush / nf_no_pmp alone survives, only both together fail pmp_refetch. Document which carries it.
- n2: dropping any nofetch term is functionally equivalent; only cycle counts (nf_sys @IMEM_WAIT=5: 2003
  vs 2045-2111) see it -- suggest tb assertion "no fetch completes behind an ex_nofetch insn".
- Held up: rs2_held reset redundant (self-clears), muldiv_ready reset required; no latches/UNOPTFLAT.

**Why:** gate before the area stack's PR to main. **How to apply:** next time, check whether nf_misa_c
landed in tests/directed and whether the RF_X wording changed. Related: [[finding-areaopt-review-2026-10-04]],
[[patterns-recurring]].
