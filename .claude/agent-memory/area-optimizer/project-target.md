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
- Target (2026-10-25): **3x4** on sky26d, die 508.76 x 511.36 µm = 260,160 µm².
  Branch upgrading_alfadelta10010 @857883c hardens there: std cells 164,259 µm²,
  placement utilisation 68.8 %, all corners clean. (The 2026-09-26 "7 tiles ≈ 79,000 µm²
  usable at 60 %" budget is obsolete; see [[feedback-report-in-tiles]].)
- ISA today: RV32IMAC + U + Zicsr + Zicntr + Zifencei + 4-entry PMP; 3-stage pipeline
  (IF / EX / WB), no caches. Linux target: NOMMU M-mode; needs I, M, A in hardware.
- Memory-bound: PSRAM QPI read = 20 SCK at clk/2 = 42 clk per fetch or load (measured);
  flash read 28 SCK ≈ 60 clk; stores 22-34 clk. See [[soc-performance-measured]]. Any EX-side change of a few cycles per instruction
  is hidden behind the next fetch.

**Why:** everything is priced against fitting 3x4 and the ~60-clock fetch.
**How to apply:** default to iterative/shared hardware; see [[area-baseline]].
