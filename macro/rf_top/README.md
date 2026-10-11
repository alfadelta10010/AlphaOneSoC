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
  Its timing is not characterised. FyraCore depends on it on every load-use and
  every read two instructions after a write; a one-entry bypass around the macro
  (about 0.13 tile) would remove that dependence.
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
  path is `soc.cpu.rf.rf_macro`. It never writes word 0; `src/fyracore.v` masks
  reads of x0 and drives the read addresses a cycle ahead (see `rf_hold` there).

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

Result at 3x4: LibreLane synthesis 8.67 tiles of std cells and exactly one
`rf_top`; after PnR 11.08 tiles (125,220 um^2) plus the macro (15,744 um^2),
utilisation 55.4 %; detailed routing converged to 0 violations; DRC 0, LVS 0,
antenna 0, PDN 0, lint 0 errors; 592 hold buffers, 0 hold violations at every
corner (worst +0.10 ns, ff); setup at 20 ns +2.55 ns (tt, max), -13.28 ns at
ss_100C_1v60 (469 endpoints, the worst flop to flop), the macro's address
inputs -6.31 ns at ss and +5.76 ns at tt -- against a liberty that gives the
macro its nominal numbers at every corner.

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
