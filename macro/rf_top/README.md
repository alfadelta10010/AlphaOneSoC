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
  either port.
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

The macro needs these in the submission's `src/config.json`, next to TT's
defaults. They are FemtoRV's (the integration that ran on sky25b silicon),
with this design's instance path; `dir::` is relative to `src/`, so the views
go in a `macro/` directory beside it. The location puts the macro in the middle
of a 6x2 die (its inputs and outputs are on opposite edges); for 8x2 it was
[620, 45]. Tried with LibreLane 3.0.5 (ttsky26c tools) on 2026-10-11: at 6x2
the flow got through placement, CTS and global routing -- 134 hold buffers
where the flop register file needed ~1,000 and failed placement (DPL-0036),
0 hold violations, setup slack +4.56 ns, std cells 11.1 tiles at 62.5 %
utilisation -- but global routing ended congested (85.8 %) and detailed
routing was not converging (77,435 -> 63,462 violations in four iterations).

```json
"MACROS": {
  "rf_top": {
    "instances": { "soc.cpu.rf.rf_macro": { "location": [450, 45], "orientation": "E" } },
    "gds": ["dir::../macro/rf_top.gds.gz"],
    "lef": ["dir::../macro/rf_top.lef"],
    "lib": { "*": ["dir::../macro/rf_top.lib"] }
  }
},
"PDN_MACRO_CONNECTIONS": ["soc.cpu.rf.rf_macro VPWR VGND VDPWR VGND"],
"RUN_IRDROP_REPORT": 0,
"MAGIC_NO_EXT_UNIQUE": 1,
"ERROR_ON_PDN_VIOLATIONS": 0,
"FP_PDN_HORIZONTAL_LAYER": "met3",
"FP_MACRO_HORIZONTAL_HALO": "3",
"FP_MACRO_VERTICAL_HALO": "0",
"FP_PDN_VOFFSET": "10"
```

`src/rf_top.v` must be listed in `info.yaml`'s `source_files` (LibreLane reads the
liberty as a blackbox first, so the cell is kept either way), and the gate-level
test must add `$(SRC_DIR)/rf_top.v` to its sources.
