---
name: area-baseline
description: Measured sky130 synth area of AlphaOneSoC at 10a37c3 (main, 2026-09-30) and earlier commits, per block, measurement recipe and the real ABC noise level (up to 0.11 tiles per run)
metadata:
  type: project
---

**10a37c3 (main after PR #5, 2026-09-30): SoC flat 13.60 t (6 seeds; seeds 1-4 13.61), 2,736 ff**
(1,443 dfxtp + 1,293 edfxtp). Hier per block unchanged from 4b4ed8b below (uart 0.29/77,
qspi 0.25/54). Pair deltas by seed (same synshuf seed on both sides): seed-to-seed spread of a
paired delta is ~0.05-0.1 t, much tighter than unpaired means. Workspace + scripts for this
round: `localFiles/area-opt-2026-09-30/` (synmean.sh, summ.sh, psuite.sh = parallel directed
suites, bench.sh = SoC CPI, synsta.sh = OpenSTA). See [[area-optimizations-measured]].

Tool: local yosys 0.66, `libs/sky130_fd_sc_hd__tt_025C_1v80.lib`, `read_liberty -lib`,
`synth -flatten`, dfflibmap + abc `-dont_use *lpflow* *_0 *probe*`, opt_clean, stat -liberty.
Top = `alphaone_soc` (dbg_* unconnected, so exwb_instr/raw_instr prune). 1 tile = 11,300 µm².

**4b4ed8b (PR #5 RTL tip, 2026-09-29): SoC flat 153,779 µm² = 13.61 t, 2,731 flops**
(mean of 6 file orders; range 153,347-154,095). b4f3f20: 153,075 = 13.55 t, same flops.
The +0.06 t is csr.v counter-write fix + LR/SC keep; split between them is below noise.
- Hier per block at 4b4ed8b (tiles / flops): regFile 4.50/992 · fyracore glue 2.72/561 ·
  csr 2.49/607 · muldiv 1.62/308 · clint 0.68/130 · alu 0.53 · pmp 0.37 x2 · uart 0.28/73 ·
  qspi_ctrl 0.23/53 · soc_bus 0.14 (hier only) · gpio 0.12/39 · c-dec 0.10 · branchCtrl 0.09 ·
  mem_ctrl 0.07/2. Hier sum 14.43 t / 2,765 ff (34 ff prune when flat).
- main 1535042 core+CLINT (wrapper `cw`, dbg open, boot const): 12.84 t / 2,563 ff; 4b4ed8b
  core+CLINT 12.89 t / 2,564 ff. So the SoC blocks cost 0.71 t flat (0.84 t by hier sum).
- 605b9d0: 148,596 = 13.15 t, 2,619 ff (pre UART/GPIO).
- Standalone costs: 64-bit writable counter 3.2k (mcycle, minstret, mtime all ~this);
  64-bit >= compare 1.18k; one bidirectional shifter 2.42k; 32-bit adder 0.96k; 33-bit
  sub+eq 0.97k; pc+2/4 0.44k; PMA in_win compares ~0 (hand-minimised decode measured +0.01 t).
- **ABC noise is bigger than first thought: 6 file orders of one design span 0.07 t; a
  fwd/rev pair spanned 0.11 t (h_c_1rp). A single module (csr) moved ±0.09 t between
  contexts.** Use >=4 orders (`synshuf.sh <src> <top> <out> <seed>`) and treat <0.1 t as noise.
  Quick zero-cost proof: compare generic cell counts after `synth -flatten` + `stat` (no
  liberty) -- identical counts = identical cost (used for boot_addr tie-off).

**Why:** 7-tile budget = 79,000 µm²; TT shapes 4x2 = 8.18 t, 6x2 = 12.35 t, 8x2 = 16.52 t
(tt-support-tools tile_sizes.yaml x 0.6; a lone 1x1 is only 10,773 µm² at 60%).
**How to apply:** workspace + scripts (syn.sh, synrev.sh, synshuf.sh, syn_cg.sh, mkvar.sh,
tab.py, models/sky130_beh.v) live in `localFiles/area-audit/` (gitignored); PR #5 review
prototypes in `localFiles/area-audit/pr5/`. Re-measure before quoting.
Related: [[area-optimizations-measured]], [[kianv-reference]], [[soc-performance-measured]].
