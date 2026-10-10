# area-optimizer memory

- [Project target](project-target.md) — sky130 hd / TinyTapeout, ~79k µm² (7 tiles @60%), memory-bound: 42 clk per PSRAM fetch.
- [Area baseline](area-baseline.md) — recipe runs ~20-24% LOW vs LibreLane (TT-flow 16.58 -> 12.52 t); recipe: applied stack 10.04 t / 2,205 ff, 10a37c3 13.60 t; per-block; pair deltas by seed.
- [Optimizations measured](area-optimizations-measured.md) — patches 01-13 applied (recipe 10.04 t, LibreLane 12.52 t); ICG RF patch 14 held, fails TT lint as written; no harden completes; verdicts; rejected.
- [Report in tiles](feedback-report-in-tiles.md) — user wants every area figure in TT tiles, 1 tile = 11,300 µm², factor stated once.
- [Spec legality notes](spec-legality-notes.md) — mandatory 64-bit mcycle/minstret, PMP0 legal, M/A not trap-emulable for M-mode Linux.
- [KianV reference](kianv-reference.md) — TT05/TT06 were 8x2 (not 6x2): 163.9k µm² synth, 2,554 flops; TT latch-RAM precedent.
- [SoC performance measured](soc-performance-measured.md) — 42 clk/fetch floor; C bench 56.1 -> 48.3 (perf fixes) -> 48.4 (area stack).
- [ICG flow evidence](icg-flow-evidence.md) — dlclkp in LibreLane/OpenROAD: little-cpu PRs, TritonCTS doc, yosys 0.62 clockgate bug.
