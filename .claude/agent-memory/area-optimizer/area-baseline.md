---
name: area-baseline
description: Measured sky130 synth area of AlphaOneSoC (recipe ~20-24% below LibreLane; TT-flow 16.58 -> 12.52 t): applied stack 10.04 t (branch area-opt_alfadelta10010), 10a37c3 13.60 t and earlier commits, per block, measurement recipe and the real ABC noise level (up to 0.11 tiles per run)
metadata:
  type: project
---

**CORRECTION 2026-10-10 (pre-PR review): this recipe's tile figures run ~20-24% LOW.**
It lets yosys use `_1` cells and edfxtp_1, which LibreLane's SYNTH_EXCLUDED_CELL_FILE
(`no_synth.cells`, 199 cells for sky130A 8afc8346: 141 `_1` cells, edfxtp_1, every dlclkp)
excludes; TT netlists are dfxtp_2 + `_2` gates + mux2_1/buf_1. LibreLane synth: 10a37c3
16.58 t / 2,771 ff, branch 12.52 t / 2,238 ff (recipe 13.61 / 10.07). Add no_synth.cells to
the dont-use list (localFiles/area-opt-review-2026-10-09/ppa/synll.sh, within 0.5% of
LibreLane) for absolute numbers; paired deltas rank cuts either way, except edfxtp-only
savings (#1b RF reset: recipe -0.38, TT cells +0.08). Never quote "% of <shape>" from a
synth figure: post-CTS std-cell area was 1.32x LibreLane synth, and NO harden completes
(DPL-0036, ~1,000 hold buffers on RF enable loops) -- fit is tested in the TT submission repo.

**Branch area-opt_alfadelta10010 @3c25950 (stack applied, 2026-10-01): SoC flat 10.04 t,
2,205 ff** (4 seeds). Hier: regFile 3.28, glue 2.19/373, csr 2.08/461, muldiv 0.72/118,
clint 0.67, pmp 0.37 (one), uart 0.29, qspi 0.25, alu 0.16. Remaining big items: flop RF
(ICG patch held), CSR file, CLINT + counters (mandatory).

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
