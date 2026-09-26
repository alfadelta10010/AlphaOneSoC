# area-optimizer memory

- [Project target](project-target.md) — sky130 hd / TinyTapeout, ~79k µm² (7 tiles @60%), memory-bound ~60 clk per QSPI access.
- [Area baseline](area-baseline.md) — 2026-09-26 HEAD 0d35be3: SoC flat 148,728 µm², 2,617 flops; per-block table + measurement recipe.
- [Optimizations measured](area-optimizations-measured.md) — latch RF −22.7k, muldiv −10.6k, PMP0 −14.8k, CSR mask −5.9k...; combined 105.0k / 84.1k; rejected items.
- [Spec legality notes](spec-legality-notes.md) — mandatory 64-bit mcycle/minstret, PMP0 legal, M/A not trap-emulable for M-mode Linux.
- [KianV reference](kianv-reference.md) — TT05/TT06 were 8x2 (not 6x2): 163.9k µm² synth, 2,554 flops; TT latch-RAM precedent.
