# rf_top: a 32 x 32 register-file hard macro for sky130

Sylvain Munaut's ("tnt", smunaut) register file for TinyTapeout: 32 words of 32 bits,
one write port and two read ports, a custom 12-transistor bit cell with latches at its
ports, 132.64 x 118.70 um. These are vendored copies; nothing here is modified.

## Provenance

Taken from **MichaelBell/ttsky25b-femtorv-soc @ 50aa37fdb7befa4fe2fac69f71a10d64d102df3c**
("Update register file macro", 2025-11-08), the FemtoRV SoC that ran MicroPython at
80 MHz on this macro:

| file here | file there | sha256 |
|---|---|---|
| `rf_top.gds.gz` | `macro/rf_top.gds.gz` | `525fb010215ba3400689c0c40a4bf97415910f40498f6882d7cd027cad1d01e2` |
| `rf_top.lef` | `macro/rf_top.lef` | `b8d2dfd70500fc79bf921dba9e643da7ecb95ca1d1198f6581ab498571d11dcb` |
| `rf_top.lib` | `macro/rf_top.lib` | `4c85936bb8a29385b9953ab8797041570082bdd860f0a46a28644be7c8e8ccb8` |
| `rf_top.upstream.v` | `src/rf_top.v` (behavioural model) | `4383d71915abd1c0e301f6dced3315760a6b99cea32eec6a25112c377f79cc39` |
| `LICENSE` | `LICENSE` (Apache-2.0) | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` |

The GDS, LEF and liberty are byte-identical to the copies in the KianV regfile edition
(`ttsky26c-kianv-regfile/regfile_macro/`). That repository's behavioural model differs
only in starting the storage at zero; FemtoRV's, kept here, leaves it unset. The macro's
own design and validation chip is smunaut/ttsky25b-rf-validation (@1146ae7, "gds: Update
with 0p1 RF release"), which publishes no macro views and no measurements.

## License

**The macro has no license of its own.** smunaut's own repositories for it carry no
LICENSE file. The repositories that integrate it -- FemtoRV, KianV's regfile edition and
georgc4/rv32-linux-soc -- are Apache-2.0, and `LICENSE` here is FemtoRV's, the terms
under which these copies were obtained. Whether the author has granted those terms for
his work is not stated anywhere; settle that before the macro ships in a submission.

## What the views say

- Synchronous read: `ra_addr`/`rb_addr` are captured on the rising edge of `clk`, and
  `ra_data`/`rb_data` follow about 4 ns later and hold until the next edge.
- Write-first: `w_data` is written to `w_addr` while `clk` is high after an edge that
  saw `w_ena`; a read of that word captured on the same edge returns the new data, on
  either port. The behavioural model does this, the author's slides describe the
  design as "read-after-write" (the read word line is enabled after the write
  completes), and KianV's sky25b errata (AMO with rd == rs2) shows it on silicon.
  Its timing is not characterised. FyraCore needs write-first on every load-use
  and every read two instructions after a write, so `src/regFile.v` provides it
  with a one-entry bypass of its own and never uses what the macro returns for
  such a read; all it asks of the macro is that the write lands.
- Word 0 is an ordinary word: writable and unreset. There is no reset at all.
- The liberty is a placeholder, not a characterisation: setup 2.0 ns, hold 0.2 ns,
  clock-to-output 4.0 ns, minimum period 10 ns, one nominal corner (25 C, 1.8 V),
  re-used for every corner. No silicon timing has been published.
- The LEF names the power pin `VDPWR`, the liberty `VPWR`; the ground is `VGND` in both.

## Use in this repository

- `src/rf_top.v` is the simulation model (the upstream model plus a 0-or-X start
  under `+RF_X`); under `SYNTHESIS` it is an empty `(* blackbox *)`, so synthesis
  keeps one `rf_top` cell and never builds the storage. TinyTapeout's gate-level
  test compiles it next to the netlist with `GL_TEST`, which gives it its power pins.
- `src/regFile.v` wraps the one instance, `rf_macro`; in the TinyTapeout top its
  path is `soc.cpu.rf.rf_macro`. It never writes word 0, and bypasses a read of
  the word written on the same edge; `src/fyracore.v` masks reads of x0 and
  drives the read addresses a cycle ahead (see `rf_hold` there).
- `+RF_COLLIDE_X` makes the model return X for a read of the word written on
  the same edge, which the macro's own model answers with the new data. Every
  simulation must be clean with it: it shows that nothing uses that answer.

## TinyTapeout harden settings

What hardened clean: KianV's sky26c regfile edition config (the one that taped
this macro out at 3x4), with this design's instance path and TT's 20 ns clock,
at **3x4**, on the sandbox's LibreLane 3.0.14 (2026-10-11). In the submission's
`src/config.json`, next to TT's defaults (`dir::` is relative to `src/`, so the
views go in a `macro/` directory beside it):

```json
"PL_TARGET_DENSITY_PCT": 56,
"MACROS": {
  "rf_top": {
    "instances": { "soc.cpu.rf.rf_macro": { "location": [3, 189.0], "orientation": "E" } },
    "gds": ["dir::../macro/rf_top.gds.gz"],
    "lef": ["dir::../macro/rf_top.lef"],
    "lib": { "*": ["dir::../macro/rf_top.lib"] }
  }
},
"PDN_MACRO_CONNECTIONS": ["soc.cpu.rf.rf_macro VPWR VGND VDPWR VGND"],
"FP_PDN_HORIZONTAL_LAYER": "met3"
```

No waivers: PDN violations stay errors and Magic keeps same-named nets apart,
so LVS proves every macro power pin is connected. `src/rf_top.v` must be in
`info.yaml`'s `source_files` (LibreLane reads the liberty as a blackbox first,
so the cell is kept either way), and the gate-level test must add
`$(SRC_DIR)/rf_top.v` to its sources.

Results at 3x4, 20 ns, LibreLane 3.0.14 on the sandbox. Every run: detailed
routing converged to 0, DRC 0, LVS 0, PDN 0, lint 0 errors, exactly one
`rf_top`, and no hold violation at any corner (worst +0.09 ns, ff). "tt" is
max_tt_025C_1v80 and "ss" max_ss_100C_1v60; the cell area is after PnR and
leaves out the macro (15,744 um^2).

| RTL | Settings on top of the block above | Std cells | Util | Setup tt | Setup ss (endpoints) | Max-slew tt / ss | Antenna | Run |
|---|---|---|---|---|---|---|---|---|
| 0c0ec3c | none (TT's `AREA 0`) | 11.08 t | 55.4 % | +2.55 ns | -13.28 ns (469) | 1,399 / 5,599 | 0 | 58 min |
| 4d21e43 | none | 11.72 t | 58.2 % | +5.14 ns | -8.09 ns (459) | 1,929 / 6,171 | 1 | 60 min |
| 4d21e43 | A: `SYNTH_STRATEGY` `"AREA 3"`, `PL_TARGET_DENSITY_PCT` 65 | 12.54 t | 61.8 % | +5.89 ns | -6.41 ns (330) | 449 / 3,364 | 0 | 43 min |
| 4d21e43 | A + `PL_TIMING_DRIVEN` 1, `RUN_POST_GRT_RESIZER_TIMING` 1 | 12.31 t | 60.8 % | +6.82 ns | -5.35 ns (252) | 351 / 2,324 | 0 | 59 min |
| 4d21e43 | A + B: `EXTRA_EXCLUDED_CELLS` `["sky130_fd_sc_hd__clkdlybuf4s*", "sky130_fd_sc_hd__dlymetal6s*"]`, `MAX_FANOUT_CONSTRAINT` 20 | 12.27 t | 60.6 % | +6.80 ns | -4.89 ns (259) | 303 / 3,338 | 0 | 42 min |
| 4d21e43 | all of the above | 12.17 t | 60.2 % | +6.67 ns | -5.83 ns (315) | 427 / 4,779 | 0 | 54 min |

- 4d21e43 is the tree with the write-first bypass in `regFile.v` and the
  timing changes in `fyracore.v`, `csr.v` and `clint.v`: 9.03 tiles at
  LibreLane synthesis where 0c0ec3c had 8.67.
- `AREA 3` is ABC's script with buffering and sizing. It costs about 0.8 tile
  after PnR and removes three quarters of the max-slew violations at tt.
- B is for what TT's default flow does to a high-fan-out net: its fan-out
  repair picks the smallest buffer it is allowed, which is a delay cell
  (`clkdlybuf4s25_1`, 0.3 to 1.3 ns each at tt), and chains them. With A alone
  the worst path was the data address register through three of them, the bus
  decode, the read mux and five more as wire repeaters: 4.8 of its 13.1 ns.
  With B that path has slack at ss. `dlygate4sd*` stays available, so hold
  repair is unchanged.
- The last three rows differ by 0.15 ns at tt and by under 1 ns at ss:
  adding the timing-driven settings to A + B bought nothing. A + B has the
  best ss and is the quickest to harden.
- What limits the clock now is EX. At tt the worst path starts at the macro's
  outputs, behind its 4 ns clock-to-output, and runs through operand select
  and the compare to the next pc; at ss it starts at the forwarding compare
  (`exwb_rd`) or the instruction register and ends in the EX/WB registers.
  With A + B every macro input has slack at both corners -- the address
  inputs +9.97 ns at tt and +2.94 ns at ss, where 0c0ec3c had -6.31 ns at ss
  -- against a liberty that still gives the macro its nominal numbers at
  every corner.

Gate level (TT's gl_test defines, `tb/tb_tt_um.v` through the pins, RTL and
netlist both with `+RF_X +RF_COLLIDE_X`): on the netlists of rows two to five
the default run and the rd_late run pass and match the RTL pin for pin on
every clock. `+QSPI_DELAY=19` is not a usable gate-level run. By the Pmod
model's timing it leaves 1 ns between the data landing and the host's
sampling point, and gl_test gives every cell a 1 ns delay: two of the four
netlists sample X, and two pass with pins that differ from the RTL's from
clock 171 on. On the A + B netlist 14, 16, 17 and 18 ns all pass and match
the RTL, so a gate-level test of the "just under one SCK period" case should
use 18.

Placements that did not route, both with FemtoRV's settings (halos 3/0, PDN
offset 10, `ERROR_ON_PDN_VIOLATIONS` 0, `MAGIC_NO_EXT_UNIQUE` 1) and the macro
in the middle of the die, where rotated E it walls off li1-met3 across 133 of
the die's 226 um height:
- 6x2, [450, 45]: placement, CTS and global routing completed (134 hold
  buffers, where the flop register file needed ~1,000 and failed placement
  with DPL-0036; 11.1 tiles at 62.5 %), but global routing ended congested
  (85.8 %) and detailed routing stalled (77,435 -> 63,462 violations in four
  iterations) before a power loss ended it.
- 8x2, [620, 45]: 11.4 tiles at 47.9 %, 51 hold buffers; global routing
  congested (overflow 9,270), detailed routing 70,910 -> 50,554 violations in
  seven iterations (~3.5 h), stopped. The flop register file at 8x2 converges
  (658 -> 1 violation by iteration 27 on GitHub), so the 2-row failures are
  this placement, not the cell area. A 2-row retry belongs at the left edge,
  as FemtoRV ([0.1, 45]) and KianV place it.
- 4x2, [3, 45] (0c0ec3c; the next shape down from twelve tiles): utilisation
  83.4 % after CTS and 89.4 % after post-CTS resizing, and global routing
  ended at 105.6 % usage with an overflow of 14,603. Stopped. This design
  does not fit eight tiles: at 60 % they hold about 6.5 tiles of cells
  beside the macro, after PnR, and it has 11 to 12.
