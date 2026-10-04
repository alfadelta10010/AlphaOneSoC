# Area audit

Whole-design area audit of AlphaOneSoC, 2026-09-27. The prototypes were measured at
605b9d0. The SoC was re-measured at b4f3f20, after the UART and GPIO landed, to get
the difference. The core RTL did not change between the two commits, so every core
delta below applies at b4f3f20 unchanged.

**Unit.** Area is given in TinyTapeout tiles: **1 tile = 11,300 µm²** of standard-cell
area, which is a tile's die area at TT's default 60% placement density (seven tiles
≈ 79,000 µm²). Strictly that is a 2x2 slot's capacity divided by 4: a single 1x1 tile
(161 × 111.52 µm) at 60% holds 10,773 µm². The shape capacities below come from
TinyTapeout's `tile_sizes.yaml` and are exact. Flop counts are raw counts.

**Re-measured 2026-09-29** (PR #5 review, then its fixes): see the section of that
name. **Applied 2026-10-01**: thirteen of the cuts are in the RTL; see the last
section. The tables before those two sections are kept as first measured, as history.

## Method

- yosys 0.66 and `libs/sky130_fd_sc_hd__tt_025C_1v80.lib`.
- Script: `synth -flatten`, then `dfflibmap` and `abc`, both with
  `-dont_use *lpflow* *_0 *probe*` (close to LibreLane's dont-use list), then `opt_clean` and
  `stat -liberty`.
- The same script is used for every number here. Numbers from a different script are not
  comparable: plain `synth` gives about 4% less.
- Noise: ABC gives identical designs different areas depending on file order. This
  section first put it at 0.04 tiles and treated anything under 0.05 as noise; the
  2026-09-29 re-measurement found six file orders of one design spanning 0.07 tiles
  and one normal/reversed pair of a cut stack 0.11 apart. **Treat anything under about
  0.1 tile as noise**, and prefer the mean of four or more orders
  (`localFiles/area-audit/synshuf.sh`). Rows #10-#16 below (−0.10 to −0.15, from one or
  two runs) sit at that floor.
- These are synthesis areas. Placement, CTS and hold fixing add buffers after this; the 40%
  of each tile left free by the 60% density figure is the margin for that.
- Verification labels:
  - **core**: the directed suite (`tests/directed/run.sh`, 101 runs) passed on the variant.
  - **SoC**: `run.sh soc` (64 tests) passed as well.
  - **synth only**: the change was never simulated.
- The prototype trees are in `localFiles/area-audit/` (gitignored, not in the repo). The
  source under `src/` is unchanged.

## Where the area is (b4f3f20)

Flat SoC: **13.54 tiles, 2,731 flops**. The per-block numbers below come from a
hierarchical run, which adds up to 14.32 tiles and 2,765 flops; flattening removes the
difference (it merges 34 flops).

| block | tiles | flops |
|---|---|---|
| regFile | 4.50 | 992 |
| fyracore glue (pipeline registers, forwarding, PMA, trap, AMO, next PC) | 2.71 | 561 |
| csr | 2.39 | 607 |
| muldiv | 1.62 | 308 |
| pmp (two instances) | 0.74 | 0 |
| clint | 0.68 | 130 |
| alu | 0.53 | 0 |
| **uart** (new) | **0.28** | **73** |
| qspi_ctrl | 0.23 | 53 |
| soc_bus | 0.14 | 0 |
| **gpio + SPI transmitter** (new) | **0.12** | **39** |
| compressed_decoder | 0.10 | 0 |
| branchCtrl | 0.09 | 0 |
| mem_ctrl | 0.07 | 2 |
| controller | 0.06 | 0 |
| signExt | 0.04 | 0 |
| decoder | 0.03 | 0 |

### Difference 605b9d0 → b4f3f20

| | 605b9d0 | b4f3f20 | Δ |
|---|---|---|---|
| flat SoC | 13.15 tiles | 13.54 tiles | **+0.39** |
| flops | 2,619 | 2,731 | +112 |
| uart | — | 0.28 | +0.28 (73 flops) |
| gpio | — | 0.12 | +0.12 (39 flops) |
| soc_bus (IO ready AND) | 0.14 | 0.14 | 0.00 |
| every other block | | | within ±0.01 (noise) |

The UART and GPIO are already lean:
- The UART's transmitter needs no bit counter: an all-zeros shift register means done.
- The SPI shifter uses a marker bit instead of a bit counter.
- Only DLAB is stored of LCR, and only two bits of IER. (Since 2026-09-29, SBC too,
  for break support: 77 flops with its break detection.)

The one cut left is not storing DLM (the high divisor byte, which Linux leaves at 0 for
115200 baud), which would save about 0.04 tiles (estimate). That is under the noise
threshold, so no action.

## Ranked candidates

M = measured, E = estimate. Δ is against the baseline unless marked "on top of".

| # | candidate | where | kind | Δ tiles | cycle cost | spec risk | verified |
|---|---|---|---|---|---|---|---|
| 1 | Latch register file: one `dlclkp` per register, `dlxtp` latches | regFile.v | overengineered | −1.99 M | 0 | none architecturally; latches and ICGs in LibreLane CTS/STA unproven (TT latch-RAM precedent exists) | core + SoC |
| 1a | Alternative: flop register file with one ICG per register | regFile.v | logic | −1.62 M | 0 | ICG flow risk, no latches | core |
| 1b | Drop the register-file reset only | regFile.v:21-24 | logic | −0.32 M | 0 | none, see [Register file](#register-file) | in the combos |
| 2 | PMP 4 → 0 entries | pmp.v, csr.v, fyracore.v | trade | −1.35 M | 0 | legal (Priv §3.7.1), but drops PMP from the ISA | synth only |
| 2a | PMP 4 → 1 entry (4 → 2 saves 0.40) | csr.v | trade | −0.67 M on top of #1 | 0 | legal; M-mode Linux touches only pmpaddr0/pmpcfg0 | synth only |
| 3 | Multiply and divide on one shared 34-bit add/sub | muldiv.v | adder / reuse | −0.95 M (−193 ff) | 34–36 cycles per op, hidden behind the fetch only once an M op stops refetching (a follow-up fix; today it starts after a fetch completes and discards it) | none | 40.8k-op equivalence check + combos |
| 4 | Stall one cycle instead of forwarding CSR writes, plus read-side WARL masking | csr.v, fyracore.v | overengineered | −0.64 M (masking alone −0.51) | +1 cycle after a CSR write; 0 in the SoC | none (one extra flop keeps rdcycle-after-`csrw mcycle` equal to Spike) | core |
| 5 | EX/WB register consolidation | fyracore.v | reuse | −0.57 M (−191 ff) | 0 | none | core |
| 6 | Unpipelined multicycle core | fyracore.v | overengineered | −0.5 E | −2..4% SoC throughput | full re-verification | — |
| 7 | Drop C | fyracore.v, csr.v | trade | −0.28 M | 0 | breaks RV32IMAC | synth only |
| 8 | One PMP checker time-shared between fetch and data | fyracore.v | reuse | −0.27 M | +1 EX cycle, only in U-mode or with locked entries | none | core |
| 9 | Register file with one read port | regFile.v, fyracore.v | overengineered | −0.27 M on top of #1 | 0 SoC cycles (303,841 = 303,841 over 64 tests); +1 clock per branch once branches hold the fetch (a follow-up fix), which stops hiding a branch's EX stalls | none | core + SoC |
| 10 | Shifts done serially through the muldiv shift register | alu.v | reuse | −0.15 E | about +50 clk per shift | none | — |
| 11 | PMP granularity G ≥ 2 | pmp.v, csr.v | trade | −0.1..−0.2 E | 0 | legal; Spike `--pmpgranularity` and the small-region tests must change | — |
| 12 | LR/SC reservation set = all of memory | fyracore.v | trade | −0.14 M | 0 | legal; diverges from Spike | synth only |
| 13 | Branch compare shares the ALU SUB/SLT; one bidirectional shifter | alu.v, branchCtrl.v | adder / reuse | −0.12 M | 0 | none | core |
| 14 | mcause stored as interrupt bit + 4-bit code | csr.v | trade | −0.12 M | 0 | legal (WLRL) | synth only |
| 15 | yosys `clockgate` on the remaining enable flops | flow | logic | −0.11 M on top of #1 | 0 | ICG flow risk | synth only |
| 16 | Decompress in EX, dropping the duplicate `ifex_instr` | fyracore.v | reuse | −0.10 M (−31 ff) | 0 (decompressor moves onto the EX path) | none | core |

What #5 changes:
- `ifex_pc_next` equals `pc` whenever `ifex_valid`, so the register goes.
- The link address and the CSR read data travel in `exwb_alu_result`.
- The CSR write data and the AMO new value travel in `exwb_rs2_data`.
- The AMO old value travels in `exwb_trap_val`; an AMO in WB never traps.
- The testbench reads `exwb_csr_wdata` (tb_rivercore.v:565), so keep an alias wire.

How #8 works: fetch verdicts are latched in stalled EX cycles, the same way the existing
upper-half check (`ifetch_hi`) already works.

Measured at or under 0.05 tiles, not worth doing:
- PMP NA4 through the NAPOT tree, and sharing the TOR compare: 0.00, because ABC already
  shares these.
- AMO min/max on a single adder: +0.04, because ABC already merges the four compares.
- CLINT word-only writes and partial decode: −0.02.
- The ten PMA window compares: 0.02 tiles in total.

Estimated under 0.05 tiles, not prototyped:
- Reservation address narrowed from 30 to 22 bits.
- mtvec and mepc narrowed to the two memory windows.
- mem_ctrl `next_page` reusing the core's incrementer.
- signExt merged into the controller.
- Decoding RVC directly.
- Removing the datapath's synchronous resets.

### Adders and compares that are already minimal

- **The mandatory counters.** The mcycle and minstret incrementers (csr.v) and mtime
  (clint.v) are 64-bit and required: 0.29 tiles per counter.
- **The CLINT `mtime >= mtimecmp`.** It must stay a magnitude compare, because Linux can
  program mtimecmp in the past.
- **The qspi_ctrl counters.** Already 3-bit down-counters.
- **PC+2/+4.** It is 0.04 tiles; a 32-bit adder is 0.09.

Sharing adders is where the area is (#3, #13). Choosing adder cell types (ripple versus
Brent-Kung versus sky130 `fa`) buys at most 2%, and extracting half adders globally
costs 7.5%.

## The most overengineered parts

- **Register file: 4.50 tiles, a third of the SoC.** It uses flops, has a synchronous reset
  nobody needs, and has two 32:1 read muxes. At about 57 clocks per instruction, a single
  latch array with one read port is enough (#1 + #9, −2.26 tiles together).
- **muldiv: 1.62 tiles, 308 flops.** Separate multiply and divide datapaths, with about
  seven adders and negators, for an operation that is hidden behind the fetch (#3).
- **CSR block.**
  - It stores 1- to 6-bit WARL fields in 32 flops: 155 flops hold nothing.
  - It forwards CSR writes (post-write exports, `wval` forwarding, mtvec/mepc forward
    muxes) to save one cycle, which the fetch wait already hides (#4).
- **The 3-stage pipeline.** EX/WB carried nine 32-bit registers. Fetch and data share one
  QSPI bus, so pipelining buys about 2–4% (#5 has been done; #6 is the full version).
- **Duplicated hardware.**
  - Two PMP checkers evaluate every cycle (#8).
  - branchCtrl has its own subtractor next to the ALU's add, sub and SLT.
  - There are three separate shifters (#13).

**Not overengineered** (required by the spec or by Linux): the three 64-bit counters and
the 64-bit mtimecmp (about 1.1 tiles together), mtval, mscratch and the full mepc.

## Cut stacks at b4f3f20 against TinyTapeout shapes

Each stack was re-synthesised with the b4f3f20 SoC files (UART, GPIO, bus) on top of the
variant core.

| stack | tiles | 4x2 (8.18 t) | 6x2 (12.35 t) | 8x2 (16.52 t) | status |
|---|---|---|---|---|---|
| b4f3f20 as is | 13.54 | — | — | 82% | |
| Low-risk, standard cells only (#1b, 3, 4, 5, 8, 13, 16) | 10.77 | — | 87% | 65% | each part in core; combination synth only |
| + latch register file (#1) | 9.16 | — | 74% | | core + SoC at 605b9d0 |
| + one read port (#9) | **8.85** | over by 0.67 | **72%** | | core + SoC at 605b9d0 |
| + PMP 1 entry, reservation = all memory, mcause WLRL, `clockgate` | 7.87 | 96% | 64% | | synth only, one run |
| PMP 0 and no C instead | 7.31 | 89% | 59% | | synth only, one run |

The tile figure for each shape is its std-cell capacity at 60% density:
- 4x2 = 92,468 µm²
- 6x2 = 139,574 µm²
- 8x2 = 186,680 µm²

In short:
- **Full ISA** (RV32IMAC, M+U, 4-entry PMP) plus UART and GPIO fits 6x2 at 72% (#1–#9 low-risk).
- **4x2** needs feature trades and would be 89–96% full before placement growth. The
  resizer, CTS and hold buffers placement adds would push that past 100% at 60%
  density, so a 4x2 fit is **not demonstrated**; it would mean running denser.
- **b4f3f20 as it stands** needs 8x2.

## Register file

### One read port

The port count is structural. The prototype `regFile` has a single 32:1 read mux, so
there is no second port for anything to use. `fyracore` time-shares that port:

- An instruction with rs2 ≠ x0 spends one stalled EX cycle (`rs2_phase`) with the port
  addressed by rs2, and captures the value in a 32-bit `rs2_hold` register.
- On every other cycle the port reads rs1.
- `rs2_hold` snoops register-file writes (`wb_rd == ex_rs2`), so while EX is stalled it
  always holds the architectural value.
- `rs2_held` clears whenever IF/EX advances, so every instruction takes its own phase.

The net saving is the second 32:1 mux minus 32 hold flops and a small mux: −0.27 tiles.
The cost is one EX cycle per rs2 instruction when memory has zero wait states, as on the
core testbench. In the SoC every instruction already waits about 45 clocks in EX for the
next fetch, which is why the 64 SoC tests ran in exactly the same number of cycles.

### Reset

Today the register file is reset: `regFile.v` clears all 32 registers synchronously on
`rst`, and also has an `initial` block for simulation. The latch prototype has no reset
at all, and neither does #1b. A reset latch (`dlrtp`) is bigger, which cancels part of
the saving.

**Leaving the registers unreset is legal.** The privileged spec's reset section fixes the
privilege mode, mstatus.MIE/MPRV, pc, mcause and the PMP A/L fields, and leaves all other
hart state UNSPECIFIED. x1–x31 are other hart state.

**Boot code then has to set the registers it relies on.** In practice that means zeroing
x1–x31 once at the reset vector:
- **Cost.** It is 31 `c.li xN, 0` instructions, 62 bytes of flash, a few microseconds once
  per boot.
- **Where it goes.** The first lines of `plugins/helpers/boot_flash.S`, before the `.data`
  copy. Today that stub sets only t0–t3 and sp.
- **What it prevents in software.** Compiled C never reads a register it has not written.
  The exception is callee-saved registers, which prologues store and epilogues restore
  unchanged, and that is harmless.
- **Linux.** An M-mode kernel clears its GPRs itself (`reset_regs` in
  `arch/riscv/kernel/head.S`, under `CONFIG_RISCV_M_MODE`). So the stub's job is only to
  hand over a0 (hart ID) and a1 (DTB pointer).
- **Why do it anyway.** Zeroing makes the hardware deterministic and matches Spike, which
  starts every register at 0. Without it, trace comparison against Spike breaks.

**Verification gap.** The latch-RF runs above used a behavioural latch model
(`localFiles/area-audit/models/sky130_beh.v`) with `initial Q = 0`, so they checked a
register file that comes out of reset zeroed. With real power-up values, or X in
simulation, they would not have. Before #1 or #1b goes in:
1. Remove the `initial` from the model, or use the sky130 functional models, which start at X.
2. Add the zeroing to every program entry point the testbenches use.
3. Re-run both suites and the gate-level simulation, so that any read of an unwritten
   register shows up as X.

## Performance defect found on the way (not area)

Every MUL/DIV costs one extra QSPI read, about 45–56 clocks:
- `muldiv_start` needs `!stall_other`, which includes the pending fetch
  (fyracore.v:602-606). So the operation starts on the cycle the fetch completes.
- `muldiv_stall` then holds IF/EX and `pc`, and the completed fetch is thrown away.
- `mem_ctrl.v` keeps no last-word buffer, although fyracore.v:69-73 asks the controller
  for one. So the same word is fetched again.

The SoC tests are consistent with this: t_mul runs at 84 clocks per instruction, against
73 for the memory tests.

Two fixes:
- Let muldiv start during the fetch wait: about zero area.
- Add a one-word fetch buffer in `mem_ctrl`: about +0.1 tiles (estimate).

## Testbench notes

- `tb_rivercore.v:565` reads the internal `exwb_csr_wdata`. A refactor that removes it
  silently breaks misa logging, and t_warl then fails. Keep an alias wire.
- With the CSR-stall change (#4), rdcycle right after `csrw mcycle` reads the written value
  +1. That is spec-legal, but cnt_alias fails against Spike. One flop that skips the
  increment on the cycle after an mcycle write restores equality.
- A behavioural `dlclkp` model has to treat an X gate as closed. Before reset, `wrEn` and
  `rd` are X, and otherwise every register loads X.

## Re-measured 2026-09-29 (PR #5 review and its fixes)

Same recipe; each figure is the mean of four to six file orders.

| | tiles | flops |
|---|---|---|
| SoC at b4f3f20 (above: 13.54, one order) | 13.55 | 2,731 |
| SoC at 4b4ed8b (counter-write fix, LR/SC keep) | 13.61 | 2,731 |
| SoC with the review fixes (UART break, RBR reset; QSPI dual-I/O step) | 13.64 | 2,735 |
| ... and the second round (UART break after a framing error; QSPI reset wait, SCK-high window ends) | 13.61 | 2,736 |
| core + CLINT, main 1535042 → 4b4ed8b | 12.84 → 12.89 | 2,563 → 2,564 |

- Every change since b4f3f20 is inside the noise floor. The counter-write fix costs
  about +0.06 tiles, the price of Zicsr's "explicit write replaces the increment"; a
  carry-in rewrite recovers nothing measurable.
- CSR reads 2.49 tiles in the hierarchical run at 4b4ed8b (2.39 above); on its own the
  file is within noise of main's.
- The SoC blocks this branch added cost 0.71 tiles flat (the hierarchical sum is 0.84;
  `soc_bus` mostly folds away). The UART is 0.29 tiles and 77 flops (73 before break
  support), `qspi_ctrl` 0.24 tiles and 54 flops (53 before the dual-I/O step).
  Measured as zero: the `boot_addr` tie-off, the PMA `in_win()` compares against a
  hand-minimised decode (+0.01), the registered MTIP (1 flop) and the UART's own RX
  synchroniser (2 flops).
- The only cut above noise in the new blocks is a UART feature trade: an 8-bit divisor
  (−0.06 tiles, −16 flops; no rates below 12.2 kbaud at 50 MHz) or a fixed divisor
  (−0.09 tiles, −24 flops; software cannot change the baud rate).
- The full-ISA stack (#1-#9) with 4b4ed8b's core changes ported in is **8.92 tiles,
  72.2% of 6x2**: the conclusion above holds.
- Stacks and scripts: `localFiles/area-audit/pr5/`, `localFiles/area-audit/synshuf.sh`,
  `localFiles/pr5-fixes-2026-09-29/area/`.

## Applied 2026-10-01

Thirteen changes are in `src/` on top of 10a37c3, one commit each, measured with the
same recipe (mean of four file orders; each step's delta is paired by file order with
the step before it, which cancels most of ABC's order noise).

| step | change | candidate | tiles | Δ | flops |
|---|---|---|---|---|---|
| | 10a37c3 | | 13.61 | | 2,736 |
| 1 | M instruction starts during the fetch wait (performance) | | 13.60 | 0.00 | 2,736 |
| 2 | no fetch while a branch or jump is in EX (performance) | | 13.64 | +0.04 | 2,736 |
| 3 | register file without reset; `boot_flash.S` zeroes x1-x31 | #1b | 13.26 | −0.38 | 2,736 |
| 4 | four directed tests initialise what they read; `RUN_PLUSARGS` | #1b | 13.26 | 0.00 | 2,736 |
| 5 | multiply and divide on one 34-bit add/sub | #3 | 12.33 | −0.93 | 2,543 |
| 6 | CSRs store only their legal bits | #4 | 12.12 | −0.22 | 2,412 |
| 7 | stall after a CSR write instead of forwarding it | #4 | 11.77 | −0.35 | 2,405 |
| 8 | EX/WB register consolidation | #5 | 11.24 | −0.53 | 2,214 |
| 9 | one time-shared PMP checker | #8 | 10.99 | −0.25 | 2,216 |
| 10 | one comparator for branches and SLT, one shifter | #13 | 10.89 | −0.11 | 2,216 |
| 11 | decompress in EX | #16 | 10.81 | −0.08 | 2,185 |
| 12 | one register-file read port | #9 | 10.34 | −0.48 | 2,218 |
| 13 | shifts done serially in the muldiv shift register | #10 | **10.04** | −0.29 | **2,205** |

- **10.04 tiles, 2,205 flops: 81% of 6x2** (123% of 4x2), with the full ISA, UART
  and GPIO. The doc's low-risk set (#1b, 3, 4, 5, 8, 13, 16) lands at 10.81 (10.77
  estimated above).
- Where the estimates moved: #9 is −0.48 on a flop register file (−0.27 was on the
  latch one); #10, an estimate of −0.15, measured −0.29, because the multiply/divide
  shift register already shifts both ways; #4's masking alone is −0.33, because the
  flops only go once nothing else reads the shared post-write value.
- Speed: compiled C goes from 56.1 to 48.4 clocks per instruction (−14%; steps 1-2
  give 48.3). Behind the QSPI fetch, multiply, divide and a 31-bit shift all cost
  the same 42 clocks as an add. The one visible cost is a branch whose rs2 is not
  x0: 44 clocks instead of 43 (the rs2 read cycle, with no fetch in flight).
- In the core testbench (no wait states) the core is slower by design: one cycle
  after a CSR write, one per instruction with an rs2, one or two per instruction in
  U-mode or with a locked PMP entry, and 2 + shamt per shift.
- Verification: core directed 116/116 and SoC directed 75/75 at every step;
  the final tree also with every register starting at X (`RUN_PLUSARGS=+RF_X`) and
  `make test-all`.
- Pre-layout timing (OpenSTA, unbuffered netlist, default wire load): the worst
  register-to-register path falls from 47.8 to 27.8 ns as the large fanouts go
  (one read mux, one PMP checker, no CSR forwarding). These are unbuffered numbers,
  not fmax.

After the design review of these thirteen (no Critical or Major findings):

- The fetch is also held while ECALL, EBREAK, MRET, FENCE.I or a PMP CSR write is
  in EX (`ex_nofetch`), since each always redirects. SoC suite: −2.0% cycles over
  68 tests (trap-heavy PMP tests up to −12%); area 10.07 tiles (noise), 2,205 flops.
- Five Spike-compared directed tests close the coverage gaps the review proved with
  mutants: `pmp_refetch`, `mprv_lock`, `datapath`, `rs2_snoop`, `cjal_link`.
- Final tree: core directed 121/121, SoC directed 80/80, both again with
  `RUN_PLUSARGS=+RF_X`, and `make test-all` passes.
- river_core at cc95754 (conformance plus three random rounds, Spike 7ab2efd6):
  conformance 175/176 (`rv32ui-ma_data`, known), rrag 3000/3000, riscv-dv 225/228
  (one program that never terminates on either model, two Spike LR/SC
  interleave yields). No DUT divergence, no false pass.

**Held: flop register file with one clock gate per register (#1a).** One
`sky130_fd_sc_hd__dlclkp_1` per register replaces the 992 enable flops' muxes:
−1.01 tiles on top of step 13, to **9.03 tiles (73% of 6x2)**. The registers stay
flops; each clock gate contains a latch. It passes both directed suites in
simulation, but no TinyTapeout design is known to have finished hardening with
explicit clock gates, so it waits for a LibreLane run that checks clock-tree skew,
hold buffering, the clock-gating timing checks and a gate-level simulation. The
patch and its measurements are in `localFiles/area-opt-2026-09-30/`.

Feature trades, measured on top of #1a, not applied (they need the user's
decision): PMP with no entries 8.07 tiles, with one entry 8.36 tiles. Neither leaves
placement margin on 4x2.

