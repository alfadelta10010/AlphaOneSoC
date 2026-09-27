# area-optimizer memory

- [Project target](project-target.md) — sky130 hd / TinyTapeout, ~79k µm² (7 tiles @60%), memory-bound ~45-57 clk per QSPI access.
- [Area baseline](area-baseline.md) — 2026-09-27 HEAD 605b9d0: SoC flat 148,596 µm² = 13.15 tiles, 2,619 flops; per-block table, recipe, ABC noise ±0.45k.
- [Optimizations measured](area-optimizations-measured.md) — low-risk combo 10.31 t (flop RF) / 9.14 t (ICG RF) / 8.75 t (latch RF); trades; rejected items.
- [Report in tiles](feedback-report-in-tiles.md) — user wants every area figure in TT tiles, 1 tile = 11,300 µm², factor stated once.
- [Spec legality notes](spec-legality-notes.md) — mandatory 64-bit mcycle/minstret, PMP0 legal, M/A not trap-emulable for M-mode Linux.
- [KianV reference](kianv-reference.md) — TT05/TT06 were 8x2 (not 6x2): 163.9k µm² synth, 2,554 flops; TT latch-RAM precedent.
