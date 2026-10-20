# Waivers (deliberately not verified, with justification)

- W-001 rf_top.v is the simulation model of a hard macro, not design RTL:
  no mutants of it; tb_regFile checks regFile around it, +RF_COLLIDE_X
  proves the bypass carries write-first.
- W-002 Gate-level simulation: no netlist work in this pass (brief: no
  synthesis/STA locally). tb_tt_um is pins-only so it can run on GL.
