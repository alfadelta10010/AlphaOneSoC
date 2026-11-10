# Waivers (deliberately not verified, with justification)

- W-001 rf_top.v is the simulation model of a hard macro, not design RTL:
  no mutants of it; tb_regFile checks regFile around it, +RF_COLLIDE_X
  proves the bypass carries write-first.
- W-002 Gate-level simulation: no netlist work in this pass (brief: no
  synthesis/STA locally). tb_tt_um is pins-only so it can run on GL.
- W-003 (2026-10-21) Pipeline formal limits: request legality (alignment,
  lanes, windows, no flash store, replication) is not k-inductive at the
  ports without internal invariants -> BMC depth 10 only (~50 s; depth 14
  > 175 s locally). The hold-until-ready rule is 1-inductive (full proof).
  muldiv handshake formal waived (tb_muldiv checks it per clock). No
  encoded FSM in fyracore, so no one-hot proofs apply.
- W-004 (2026-10-25, user decision on review F1) The watchdog is "never
  early unless software writes mtime": writes that toggle the tapped bit
  are ticks (probe: 3 writes fire it 10 clocks after a kick). No test, no
  prescaler (+0.06 t). Linux never writes mtime.
- W-RVFI-1 (2026-11-07, planned): riscv-formal runs on a full-RAM PMA; PMA faults stay with directed + core_req + tb_rivercore bus checks.
- W-RVFI-2 (planned): riscv-formal env excludes U-mode, PMP lock, MPRV-to-U, misa.C=0 (assumptions); covered by directed, tb_pmp, csr formal. Spurious entry into those states is invisible to riscv-formal.
- W-RVFI-3 (planned): no data-memory consistency / bus model in riscv-formal (FC51 survives there); directed memory_model + core_hold cover it. M arithmetic under ALTOPS is unchecked by riscv-formal (tb_muldiv + directed).
