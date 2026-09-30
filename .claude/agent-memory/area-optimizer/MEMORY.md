# area-optimizer memory

- [Project target](project-target.md) — sky130 hd / TinyTapeout, ~79k µm² (7 tiles @60%), memory-bound: 42 clk per PSRAM fetch.
- [Area baseline](area-baseline.md) — 4b4ed8b (2026-09-29): SoC 13.61 t, 2,731 ff (6-order mean); per-block; ABC noise up to 0.11 t/run.
- [Optimizations measured](area-optimizations-measured.md) — low-risk combo 10.31/9.14/8.75 t; full-ISA stack 8.92 t at 4b4ed8b; UART trims; rejected items.
- [Report in tiles](feedback-report-in-tiles.md) — user wants every area figure in TT tiles, 1 tile = 11,300 µm², factor stated once.
- [Spec legality notes](spec-legality-notes.md) — mandatory 64-bit mcycle/minstret, PMP0 legal, M/A not trap-emulable for M-mode Linux.
- [KianV reference](kianv-reference.md) — TT05/TT06 were 8x2 (not 6x2): 163.9k µm² synth, 2,554 flops; TT latch-RAM precedent.
- [SoC performance measured](soc-performance-measured.md) — 42 clk/fetch floor; M op and taken branch 84; two ~0-area fixes = -14% cycles.
