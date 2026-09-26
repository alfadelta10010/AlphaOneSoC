---
name: area-baseline
description: Measured sky130 synth area of FyraCore + AlphaOneSoC at HEAD 0d35be3 (2026-09-26), per block, plus how it was measured
metadata:
  type: project
---

Measured 2026-09-26 at HEAD 0d35be3 (branch soc-fabric_alfadelta10010).
Tool: local yosys 0.66, `libs/sky130_fd_sc_hd__tt_025C_1v80.lib`, `synth -flatten`,
dfflibmap + abc with `-dont_use *lpflow* *_0 *probe*` (approximates LibreLane dont-use).
Top = `alphaone_soc` (dbg_* ports unconnected, so exwb_instr/raw_instr are pruned).

- **SoC flat: 148,728 µm²**, 2,617 flops (1,324 edfxtp + 1,293 dfxtp), seq 44%.
- Core-only flat (fyracore top, dbg ports kept): 139,152.
- Hierarchical per block: regFile 50,859 (992 edfxtp = 29.8k, 960 and2 reset = 6.0k,
  read muxes ~14k) · fyracore glue 30,778 · csr 27,922 (607 flops!) · muldiv 18,321
  (308 flops) · pmp 4,150 ×2 · clint 7,676 · alu 6,005 · qspi_ctrl 2,387 · soc_bus 1,536
  (folds away flat) · branchCtrl 1,090 · compressed_decoder 1,075 · mem_ctrl 747 ·
  controller 656 · signExt 444 · decoder 297.
- No UART exists yet; a minimal 8N1 sizing sketch is ~3.8k µm².

**Why:** user has ~7 TT tiles ≈ 79,000 µm² usable at TT's 60% density; SoC is ~1.9x over.
**How to apply:** re-measure against this before claiming a delta; the harness scripts
lived in the session scratchpad (syn.sh/socsyn.sh) — recreate from the recipe above.
Related: [[area-optimizations-measured]], [[kianv-reference]].
