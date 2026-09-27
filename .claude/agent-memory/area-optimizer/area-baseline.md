---
name: area-baseline
description: Measured sky130 synth area of AlphaOneSoC at HEAD 605b9d0 (2026-09-27), per block, measurement recipe and ABC noise level
metadata:
  type: project
---

Measured 2026-09-27 at HEAD 605b9d0 (branch soc-fabric_alfadelta10010; PSRAM QPI, flash-only boot).
Tool: local yosys 0.66, `libs/sky130_fd_sc_hd__tt_025C_1v80.lib`, `read_liberty -lib`,
`synth -flatten`, dfflibmap + abc `-dont_use *lpflow* *_0 *probe*`, opt_clean, stat -liberty.
Top = `alphaone_soc` (dbg_* unconnected, so exwb_instr/raw_instr prune).

- **SoC flat: 148,596 µm² = 13.15 tiles** (1 tile = 11,300 µm²), 2,619 flops
  (1,293 edfxtp + 1,326 dfxtp), seq 44%. (0d35be3 was 148,728.)
- Hier per block (µm² / flops): regFile 50,786/992 · fyracore glue 30,890/561 · csr 27,051/607 ·
  muldiv 18,254/308 · clint 7,629/130 · alu 6,077 · pmp 4,150 x2 · qspi_ctrl 2,646/53 ·
  soc_bus 1,536 (folds away flat) · branchCtrl 1,090 · compressed_decoder 1,075 · mem_ctrl 747 ·
  controller 656 · signExt 444 · decoder 297.
- Standalone costs: 64-bit writable counter 3.2k (mcycle, minstret, mtime all ~this);
  64-bit >= compare 1.18k; one bidirectional shifter 2.42k; 32-bit adder 0.96k; 33-bit
  sub+eq 0.97k; pc+2/4 0.44k; all 10 PMA in_win compares ~0.2k total; AMO block 2.68k.
- **ABC noise: functionally identical designs vary by up to ~450 µm² (0.04 tiles)** (file
  order, case-arm order). Measure every variant twice (normal + reversed file order) and
  compare means; anything under ~0.5k is noise.

**Why:** 7-tile budget = 79,000 µm²; SoC is ~1.9x over at HEAD.
**How to apply:** workspace + scripts (syn.sh, synrev.sh, syn_cg.sh, mkvar.sh, suite.sh, tab.py,
models/sky130_beh.v) live in `localFiles/area-audit/` (gitignored). Re-measure before quoting.
Related: [[area-optimizations-measured]], [[kianv-reference]].
