---
name: finding-rf-macro-review-2026-10-11
description: Review of the rf_top (smunaut 32x32 2R1W macro) integration, branch rf-macro_alfadelta10010 (0367965 + uncommitted) -- no Crit/Major; rf_hold select exact; wfi_active term has no functional test; SoC/IMEM_WAIT runs blind to select bugs; area/timing numbers. FINAL review (88c18f3): MAJ same-edge write-through is model-only but load-use depends on it; README placement/PDN-stub risk; 6x2 harden congested
metadata:
  type: project
---

Reviewed 2026-10-11 (DESIGN.md in localFiles/rf-macro-2026-10-11/, RTL = 0367965 + uncommitted
fyracore/regFile/tb_rivercore edits). Scratch: /tmp/claude-1000/.../scratchpad/reviewer-a/
(scripts/mk_tree.py builds the proposal + mutants on cfdecbc, rrun.sh, syn.sh, sta.sh, probe.sh;
probes/wfi_hold.S). Scratch prototype is statement-identical to the worktree RTL.

Verdict: no Critical/Major. Equivalence (sync write-first read == comb flop read when the address
taken at edge E is EX's field in the cycle after E) holds; rf_hold = stall_other || M-term is exact:
stall_full (ex_trap included) equivalent; 121/121 directed (+RF_X too) with a per-cycle shadow check;
rgen2 lockstep trap/umode/irq/uirq 150/150 each (40,365 irq entries), SoC irqsoc 6/6 (mlock not run). Optional cheaper select
stall_nofetch || !imem_ready || M passes 121/121 with the shadow. Parent's tb checker (posedge, address +
data vs shadow) reviewed: sound; it is the only oracle for the wfi_active and M terms.

Findings:
- m1 PROVEN: drop wfi_active from rf_hold passes 121/121 functionally; probes/wfi_hold.S (WFI with
  mie=0 / MIE=0+MTIP, no trap) gives a2=0x44c vs 0xc. Only the tb read checker (wfi_slow) catches it.
  DESIGN.md section 3 has no WFI row. Linux idle = WFI with MIE=0.
- m2 PROVEN: every rf_hold stall term is killed only by zero-IMEM-wait core runs; IMEM_WAIT configs
  and the SoC pass (drop_csr_wb_hazard passes t_csrmret at SoC). In the SoC the terms matter only
  for ex_nofetch insns and WFI longer than a fetch.
- n: M-term functionally redundant (no_iter 121/121; operands sampled at muldiv_start) but needed for
  the checker's invariant. x0 write gate redundant (no_w0gate equivalent). Optional: rf_hold can use
  !imem_ready instead of if_mem_stall (imem_req=0 cycles are don't-care) for the 90 MHz path.
- Area (TT cell set, core only): 10.84 t -> 7.07 t std cells + macro 0.84 t (0.87 with 3 um halo);
  fetch-path extractor+select 0.04 t; a 2R1W flop RF_FLOPS model = 11.48 t (+0.64 t vs 1R base).
- Timing pre-layout tt: address pins arrive 8.5 ns (2 ns setup); worst RF path rb_data->comparator 13.2 ns
  (4.0+9.2), fails 20 ns if clk->q is 8 ns (derated lib); worst overall 17.4 ns vs base 18.3 (base worst IS
  the rs1 decode+32:1-mux path). 0308d06 (2 comb ports) = 11.54 t. Lib: one corner for all, max_transition 0.1 ns on clk/addr/w_ena, scalar outputs.
  Pins: all inputs left edge, outputs+clk right edge (precedents rotate E at die edge).

**Why:** gate before the macro RTL lands / harden. **How to apply:** next time check a functional
WFI-hold test landed, the checker runs in zero-wait configs, and a derated-liberty STA exists.
Related: [[patterns-recurring]], [[finding-ppa-review-2026-10-09]].

## Final review, same day (committed 9263ad3..88c18f3 + uncommitted README TT settings)

RTL committed unchanged. m1 CLOSED: rf_wfi_hold (20eca17) passes core x2, +RF_X and SoC; the
drop-wfi_active mutant is killed functionally (x12=x13=0x44c, checker off) and by the checker. The
parent's cited evidence (135/135, 85/85) PREDATES 20eca17 (no rf_wfi_hold in perf/rfm.*.runs).

NEW MAJOR (silicon assumption): the core relies on the macro's SAME-EDGE write-through, which only the
behavioural model asserts. load_use_hazard (fyracore.v:634) holds EX through the load's whole WB
cycle, so every load-use pair reads the loaded value from the macro on the edge the load writes it.
PROVEN with a read-first model mutant (checker off): 11 of 12 core rf/mem tests fail; at SoC level
t_memstress fails (lw x30 / bne x30 at 0x8000006e/72). Probe: SoC t_memstress has 1223 same-edge
collisions read by EX in 3027 instructions. Precedents never exercise it: FemtoRV quark captures
operands in WAIT_INSTR after its write state; KianV is a multicycle FSM. Fix direction: a 1-entry
bypass (flop hit_a/hit_b + wdata at the edge, mux after the macro), about 0.13 t, or get the macro
author to confirm write-through. The GL pin compare can't see it because it uses the same model.

README TT settings: location [450,45] is NOT FemtoRV's ([0.1,45] on 2x2) nor KianV-regfile's ([3,45]
on 6x2, default halos/VOFFSET, NO PDN/LVS waivers, fabbed). The macro's OBS covers li1-met3, so an
E-rotated macro mid-die is a 132.6 um horizontal routing wall (only met4 crosses). VDPWR/VGND have
short met3 stubs (N: x 109.8-116, y 1-23) disjoint from the long stripes in the LEF; after E they lie at
x' 1-23 from the macro's left edge. FemtoRV's x=0.1 + VOFFSET 10 lands straps on them; at x=450 that is
not guaranteed, and ERROR_ON_PDN_VIOLATIONS 0 + MAGIC_NO_EXT_UNIQUE 1 hide a miss from both checks.
Parent's 6x2 harden: 11.1 t std cells + macro, 62.5 % util, GRT 85.78 % congestion, DRT 77k->63k
after 4 iterations. Area: flat 12.46 -> 8.72 t + 0.88 t macro (with halo); PnR inflation 1.27x -> ~12.0 t,
which fills a 6x2; 8x2 is about 75 %.
