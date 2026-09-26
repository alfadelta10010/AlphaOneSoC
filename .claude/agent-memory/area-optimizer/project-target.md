---
name: project-target
description: Confirmed physical target and governing constraint for AlphaOneSoC area work (sky130 hd, TinyTapeout, ~7 tiles, memory-bound QSPI SoC)
metadata:
  type: project
---

- PDK sky130, library `sky130_fd_sc_hd`; fabricated via TinyTapeout; Metal5 is TT power.
- Flow: LibreLane 3.0.5 pinned to ttsky26c on the mempool sandbox (see user memory
  "TinyTapeout sandbox runbook"); `SYNTH_STRATEGY` resolves to `AREA 0`, default
  `PL_TARGET_DENSITY_PCT` 60.
- Budget (2026-09-26, from the coordinator): 7 confirmed tiles ≈ 79,000 µm² usable
  std-cell area at 60% density (2x2 = 45,362 µm² usable reference).
- ISA today: RV32IMAC + U + Zicsr + Zicntr + Zifencei + 4-entry PMP; 3-stage pipeline
  (IF / EX / WB), no caches. Linux target: NOMMU M-mode; needs I, M, A in hardware.
- Memory-bound: a QSPI read is 8 cmd + 6 addr + 6 dummy + 8 data SCK at clk/2 ≈ 60 clk per
  fetch or load; stores ≈ 45 clk. Any EX-side change of a few cycles per instruction
  is hidden behind the next fetch.

**Why:** everything is priced against 79k µm² and the ~60-clock fetch.
**How to apply:** default to iterative/shared hardware; see [[area-baseline]].
