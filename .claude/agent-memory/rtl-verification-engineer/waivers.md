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
