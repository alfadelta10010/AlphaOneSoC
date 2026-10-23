# Spec ambiguities (open questions for the designer/user)

- SA-001 (2026-10-18) Interrupt vs synchronous exception at the same
  instruction. Priv spec 20260409 3.1.9 orders interrupts among themselves
  only; older versions (1.10/1.11) said "Synchronous exceptions are of lower
  priority than all interrupts". FyraCore lets the exception win (CPU ref
  8.4, irq_inject needs !ex_trap); Spike takes the interrupt. Read as legal
  interrupt latency. Tested both-ways-legal in tests/directed/irq_at_trap
  (expect mode). Harm if the stricter reading is meant: an interrupt is
  delayed by one handler run.
- SA-002 (2026-10-18) muldiv operand hold. muldiv.v's header says start is
  a one-cycle pulse but not whether a/b/op must stay stable afterwards.
  tb_muldiv takes the stricter reading (operands sampled with start; inputs
  scrambled from the next cycle). fyracore holds them anyway.
- SA-003 (2026-10-18) ALU / branchCtrl outputs for codes the controller
  never issues (ALU codes other than the 7 ops, branch funct3 010/011):
  unspecified. The old benches pinned the RTL's 0; the new ones do not
  check them (mutants ALU07, BR06 are equivalent at the core level).
- SA-004 (2026-10-19) Spike's CLINT aperture. tb_rivercore's IO0 window
  (0x02000000-0x020BFFFF) and memory_model's CLINT_TOP mirror Spike's old
  0xC0000 aperture. Spike 5a760667 (local since 2026-10-18) answers only
  offsets < 0xC000 (byte/half/word all fine there) and faults 0x0200C000
  and up -- including the testbench's MEIP hook address. Not a DUT issue
  (the window is a testbench parameter), but random programs that touch
  0x0200C000-0x020BFFFF now diverge from Spike for a testbench reason.
  Needs a decision: shrink IO0_TOP to 0x0200BFFF (and move the MEIP hook)
  or pin the old Spike. Probe: build/probe/clint/c.S.
  2026-10-22 verdict: the SoC RTL is legal as is (clint.v decodes addr[15:0];
  0x0200C000-0x0200FFFF inside PMA_IO0 is RAZ/WI, a platform choice; the
  SiFive/ACLINT layout ends at 0xBFFF). Linux NOMMU touches only msip 0x0,
  mtimecmp 0x4000, mtime 0xBFF8; DT reg size 0xC000 or 0x10000 both work.
  Fix belongs in the tb only (tb PMA_IO0_TOP -> 0x0200BFFF, MEIP hook moved
  below 0xC000) and in random-generator memory maps, or pin old Spike.
  CLOSED 2026-10-23 (user: testbench only): WO-11 narrows the tb window to
  0x0200BFFF, MEIP hook -> 0x02008000 (probe: Spike RAZ/WI there; dtb reg
  size ignored by Spike). Generators never touch the CLINT: no map change.
- SA-005 (2026-10-21; see SA-006 for the RTL side) Spike 5a760667 with --priv=mu does NOT trap a U-mode
  WFI with TW=0 (the earlier "Spike traps it" was wrong); it retires it and
  sleeps forever with mie=0, FyraCore NOPs it (CPU ref 8.5). Both legal
  (Priv 3.1.6.6, 3.3.3), so U-mode WFI tests must be expect mode.
- SA-006 (2026-10-22) U-mode WFI with TW=0: CPU ref 8.5 says it "retires and
  sets wfi_active, stalling ... until an individually enabled interrupt is
  pending"; the RTL decodes it as a NOP (fyracore.v ex_is_wfi requires
  priv_mode, comment at ~536-543 says so). Both are ISA-legal (Priv 3.1.6.6,
  3.3.3). Harm: U-mode software that idles with WFI spins instead of
  sleeping (power only; M-mode Linux unaffected). Doc fix or RTL fix is the
  user's call. wfi_umode (dcd3476) accepts both, with uncorrelated per-register
  alternatives (x20/x21/x24); tighten once decided.
  CLOSED 2026-10-23 as a doc fix (1a845f5); WO-10 pins wfi_umode to the NOP
  (x20=0x8 x21=0x4 x24=0x1), adds FC86 (U-mode WFI waits).
- SA-007 (2026-10-23) syscon decisions still open with the user, taken by
  the design WO (build/wo/WO-20-syscon-rtl.md) and assumed by WO-14..19
  (assumption table in WO-14): CHIP_ID 0x41315301; FAIL (0x3333) halts like
  power-off (ROADMAP silent); no flash B9h at power-off (ROADMAP says deep
  power-down); CLK_GATE/POWER reserved RAZ/WI (ROADMAP: R/W, reset by any
  reset); RESET_CAUSE only PIN/SOFT (ROADMAP: power-on/pin/software/watchdog;
  TT has no POR cell); watchdog deferred; reset generator inside
  alphaone_soc (ROADMAP sketched it in tt_um). FINISH acts on be[1:0]==11
  only, so a replicated `sb 0x77` (wdata 0x77777777, be 0001) does nothing:
  the hazard I raised is closed by that rule.
