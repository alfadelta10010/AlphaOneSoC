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
