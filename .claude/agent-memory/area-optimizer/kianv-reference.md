---
name: kianv-reference
description: KianV uLinux SoC hard size data from the TT05/TT06 shuttle repos (8x2, not 6x2) — the only Linux-booting TT design, use as the area reference point
metadata:
  type: reference
---

- TT05 and TT06 `info.yaml` both say `tiles: "8x2"` (16 tiles). Claims of "6x2" are wrong.
- TT06 stats (github.com/TinyTapeout/tinytapeout-06/tree/main/projects/
  tt_um_kianV_rv32ima_uLinux_SoC/stats): synth area **163,928 µm²** (mapped to `_2`
  drive cells, which inflates vs `_1`), **2,554 dfxtp_2 flops**, 15,505 cells,
  core area 302,420 µm², OpenDP util 55.3%, CLOCK_PERIOD 20 ns. 30 MHz on silicon.
- ISA RV32IMA (no C), multicycle, no caches, UART + SPI + CLINT, flash + PSRAM over QSPI.
- The 2025 wafer.space KianV (GF180, full die, caches, Sv32) is a different design.

**How to apply:** FyraCore baseline (2,617 flops, 148.7k µm²) is KianV-sized; a 7-tile
target is ~44% of KianV's tile count, so KianV-style design alone does not fit.
TT latch precedent: tt_um_MichaelBell_latch_mem (TT06, 512 latches, silicon-verified),
tt_um_rebelmike_femtorv (ttsky25b, latch register file test).
