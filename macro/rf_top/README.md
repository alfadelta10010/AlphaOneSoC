# rf_top: a 32 x 32 register-file hard macro for sky130

Sylvain Munaut's ("tnt", smunaut) register file for TinyTapeout: 32 words of 32 bits,
one write port and two read ports, a custom 12-transistor bit cell with latches at its
ports, 132.64 x 118.70 um. The GDS, LEF, liberty and model are vendored copies, not
modified; `rf_top.ff-hold-guard.lib` is the one file derived here (see *Hold guard band*).

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
  Its timing is not characterised. FyraCore needs write-first whenever an
  instruction reads what the one before it wrote, so `src/regFile.v` provides it
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
  keeps the EX instruction's register numbers on the read addresses, from
  flops, for as long as it is in EX (see `ex_rf_ok` there).
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
    "lib": {
      "*_tt_025C_1v80": ["dir::../macro/rf_top.lib"],
      "*_ss_100C_1v60": ["dir::../macro/rf_top.lib"],
      "*_ff_n40C_1v95": ["dir::../macro/rf_top.ff-hold-guard.lib"]
    }
  }
},
"PDN_MACRO_CONNECTIONS": ["soc.cpu.rf.rf_macro VPWR VGND VDPWR VGND"],
"FP_PDN_HORIZONTAL_LAYER": "met3"
```

The `lib` keys are corner wildcards, and LibreLane loads every file whose key
matches the corner, so they must not overlap: `"*"` next to an ff key would
read two models of `rf_top` at ff. Every run in the table below used
`{ "*": ["dir::../macro/rf_top.lib"] }` except the one marked "hold guard".

### Hold guard band

`rf_top.ff-hold-guard.lib` is `rf_top.lib` with the ten input `hold_rising`
values (`w_addr`, `ra_addr`, `rb_addr`, `w_data`, `w_ena`, rise and fall)
raised from 0.2 ns to 0.4 ns; nothing else differs. It is used at the ff
corners only. The macro's real hold has never been measured, and a hold
failure, unlike a setup one, does not go away with a slower clock.

The case for it, from every design that has fabricated this macro (survey of
2026-10-14; the shuttle repositories' `commit_id.json`, metrics and netlists,
and the CI logs that are still downloadable):

- All of them -- FemtoRV, KianV's regfile edition, SIC-1 and SPELL on sky25b,
  KianV and SIC-1 again on sky26c -- use this byte-identical liberty with
  `"*"`, so 0.2 ns at every corner, and TT's default hold margins. None has a
  guard band; nor have the unfabricated designs checked.
- The sky25b chips work: FemtoRV ran MicroPython up to 80 MHz, KianV "mostly
  works" (the write-first erratum above), SIC-1 and SPELL ran their demo
  programs (author's FSiC 2026 slides). Nobody has measured the macro's
  timing on them, and the slides give neither die counts nor conditions.
- Macro-input hold slack at min_ff: SIC-1 +0.234 ns (its own STA report),
  KianV sky26c +0.248 ns (OpenSTA on its SPEF), FemtoRV, KianV sky25b and
  SPELL at least +0.11 ns and an estimated +0.20 to +0.35 ns (their
  parasitics no longer exist anywhere; netlist-only STA, calibrated on the
  designs that have both). This design without the guard (`rfm2-a3fo`):
  +0.166 ns, the lowest of the set.
- Slack + 0.45 ns (the 0.2 ns hold plus TT's 0.25 ns clock uncertainty) is the
  real hold a design survives at that corner: 0.62 ns here, 0.68 and 0.70 ns
  for the two exact figures above.

With 0.4 ns the hold repair has to leave every macro input able to take at
least 0.75 ns. tt and ss keep the original file: there the same inputs
already had +0.58 and +1.60 ns of hold slack, and more hold delay at those
corners would land on the paths that limit the clock.

Measured on A + B below (`rfm2-a3fo-hg`, the "hold guard" row, against
`rfm2-a3fo`; OpenSTA 2.0.17 on each run's SPEF, all 48 macro inputs; LibreLane's
own reports agree within 0.01 ns):

| | without | with the guard |
|---|---|---|
| worst macro-input hold slack, min_ff | +0.173 ns (vs 0.2) | +0.316 ns (vs 0.4) |
| real hold the inputs survive, ff | 0.62 ns | 0.97 ns |
| same, tt | 1.03 ns | 1.55 ns |
| delay cells (`dlygate4sd*`) | 624 | 671 |
| std cells after PnR | 12.27 t | 12.31 t |

The fabricated designs survive 0.68 to 0.70 ns at ff and 1.09 to 1.14 ns at
tt by the same measure, so this design is now the most conservative of them
at both corners, for 0.04 tile. Setup changed only as much as placement
varies between runs (tt +6.80 -> +6.68 ns, ss -4.89 -> -3.53 ns), and hold
is still met at every corner (worst +0.106 ns, ff, flop to flop).

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
| 4d21e43 | A + B + hold guard (ff corners read `rf_top.ff-hold-guard.lib`) | 12.31 t | 60.8 % | +6.68 ns | -3.53 ns (257) | 307 / 3,347 | 0 | 57 min |

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
- Rows four to six differ by 0.15 ns at tt and by under 1 ns at ss:
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
every clock. On the hold-guard netlist the default, rd_late and 18 ns runs
pass, and every pin matches the RTL on every clock of the RTL's run (31,180,
31,705 and 31,182 clocks); each netlist run saw the program's last UART byte
one clock later and so ran one clock longer. `+QSPI_DELAY=19` is not a
usable gate-level run. By the Pmod model's timing it leaves 1 ns between the data landing and the host's
sampling edge. gl_test's cell models give every flop and latch a 1 ns
clock-to-output and every other cell none, so at gate level SCK reaches its
pin 1 ns later and the data lands in the very time step of the sampling edge:
a race inside the simulator, and since the model drives X between hold and
landing, the loser reads X. Two of the four netlists lose it and fail with X
on `uio_oe` a few clocks later (the X comes in through the read shift
register, which has no reset by design; everything that drives `uio_oe` is
reset). The two that win it pass; their pins differ from the RTL's from clock
171 on only because the bench's two aimed resets each land a clock later for
the same reason, and from there the traces match two clocks apart. On the
A + B netlist 14, 16, 17 and 18 ns all pass and match the RTL, so a gate-level
test of the "just under one SCK period" case should use 18.

### After EX was split over three cycles

The -4.89 ns at ss above was one path shape: `exwb_rd`, the forwarding
compare and mux select, the ALU, the PMP check, the trap chain and the
enables of the pipeline registers, all in one EX cycle (24.5 ns). The
`setup-timing` series took it apart in the RTL (no forwarding; the register
file read, the ALU and the decisions each in an EX cycle of their own; see
`src/fyracore.v`, `ex_rf_ok` and `ex_ph`) and found a second cause in the
flow. Same die, same LibreLane, A + B throughout; every run routed to 0,
DRC 0, LVS 0, antenna 0, no hold violation at any corner.

| RTL | Settings on top of A + B | Clock | Std cells | Util | Setup tt | Setup ss | Max-slew tt / ss | Hold, worst corner | Hold buffers | Run |
|---|---|---|---|---|---|---|---|---|---|---|
| 4d21e43 | none (the A + B row above) | 20 ns | 12.27 t | 60.6 % | +6.80 ns | -4.89 ns | 303 / 3,338 | +0.105 ns | 624 | 42 min |
| 2da5b5d | none | 20 ns | 12.61 t | 62.2 % | +8.64 ns | +2.38 ns | 249 / 2,597 | +0.108 ns | 668 | 45 min |
| b5077cd | none | 20 ns | 12.75 t | 62.8 % | +9.32 ns | +3.35 ns | 246 / 2,763 | +0.111 ns | 673 | 34 min |
| 2da5b5d | C | 20 ns | 13.53 t | 66.2 % | +9.42 ns | +3.41 ns | 22 / 108 | +0.027 ns | 407 | 36 min |
| 2da5b5d | C | 16 ns | 13.53 t | 66.2 % | +6.51 ns | +0.36 ns | 21 / 90 | +0.023 ns | 16 | 40 min |
| b5077cd | C with cap 2.16e-4, `PL_RESIZER_HOLD_SLACK_MARGIN` 0.2 | 16 ns | 14.34 t | 69.8 % | +6.44 ns | +0.52 ns | 16 / 97 | +0.180 ns | 97 | 36 min |
| b5077cd | hold guard | 20 ns | 12.77 t | 62.9 % | +9.19 ns | +3.28 ns | 234 / 2,762 | +0.110 ns | 703 | 36 min |
| b5077cd | C with cap 2.16e-4, `PL_RESIZER_HOLD_SLACK_MARGIN` 0.2, hold guard | 16 ns | 14.36 t | 69.9 % | +6.49 ns | +0.54 ns | 15 / 71 | +0.183 ns | 92 | 38 min |

C is `LAYERS_RC` `{"*": {met1, met2: res 8.929e-4, cap 2.4e-4; met3, met4:
res 1.567e-4, cap 2.4e-4}}`, `SIGNAL_WIRE_RC_LAYERS` and
`CLOCK_WIRE_RC_LAYERS` met1 to met4, `PL_RESIZER_SETUP_SLACK_MARGIN` 0.5.
"Hold guard" is the ff-corner `rf_top.ff-hold-guard.lib` mapping above; the
rows without it read `rf_top.lib` at every corner.

- The RTL alone moves the slow corner from 40 MHz to 60 MHz (b5077cd, 16.65 ns)
  and tt from 76 to 94 MHz, for half a tile.
- C is a calibration, not a tuning. LibreLane estimates wire capacitance
  before routing at the technology LEF's average, 0.0815 fF/um; extraction of
  the routed design gives 0.21 to 0.23 fF/um, and congested nets route up to
  2.3 times longer than placement suggests. Measured on the 4d21e43 run: with
  the flow's estimate the finished layout has +2.24 ns at max_ss, with its own
  extraction -4.89 ns. So the resizer reported "No setup violations", repaired
  nothing, and left 3,338 slow-corner slew violations it could not see.
  With the estimate at 2.4e-4 pF/um the design repair inserts 1,126 buffers
  instead of 495, the slew violations go from 2,597 to 108, and a 16 ns clock
  closes at every corner.
- It costs area: 0.9 tile at a 20 ns target, 1.6 at 16 ns with the hold
  margin raised. 69.8 % still routed in 22 iterations.
- It also moves hold. The larger estimate makes short paths look slower than
  they are at the min corner, so with TT's 0.1 ns hold margin the worst hold
  slack at signoff fell to +0.02 ns, and the paths at the bottom were the
  macro's `w_data` pins, whose 0.2 ns hold is a placeholder. With the margin
  at 0.2 ns the worst hold is +0.180 ns, on a macro pin again. Do not use C
  without it. (Only the `nom_*` key of a per-corner `LAYERS_RC` showed in the
  flow's RC report; whether the others reach the estimator was not
  established.)
- What limits the 16 ns run: the opcode through the trap decode to the next
  pc (+0.52 ns), and `pmpcfg0` through the PMP check, the trap chain and
  flush (+0.67 ns).
- The hold guard costs 0.02 tile on either flow and moves setup only by
  placement noise (+3.35 -> +3.28 ns at 20 ns, +0.52 -> +0.54 ns at 16 ns).

Hold at the macro's 48 inputs, by the measure of *Hold guard band*: OpenSTA
(LibreLane 3.0.14's) on each run's SPEF, with the liberty the run read at each
corner. It reproduces LibreLane's own min.rpt to the picosecond; on
`rfm2-a3fo-hg` it gives +0.305 ns (`w_data[29]`, also LibreLane's figure)
where that section, with OpenSTA 2.0.17, has +0.316 ns. "Survives" is slack plus
the liberty hold plus the 0.25 ns clock uncertainty.

| RTL | Settings on top of A + B | Clock | Worst slack, min_ff | Survives, ff | Worst slack, min_tt | Survives, tt | Worst pin |
|---|---|---|---|---|---|---|---|
| 4d21e43 | hold guard | 20 ns | +0.305 ns (vs 0.4) | 0.96 ns | +0.999 ns | 1.45 ns | `w_data` |
| b5077cd | none | 20 ns | +0.202 ns (vs 0.2) | 0.65 ns | +0.539 ns | 0.99 ns | `w_data` |
| b5077cd | C, hold margin 0.2 | 16 ns | +0.180 ns (vs 0.2) | 0.63 ns | +0.494 ns | 0.94 ns | `w_ena` |
| b5077cd | hold guard | 20 ns | +0.176 ns (vs 0.4) | 0.83 ns | +0.795 ns | 1.25 ns | `w_addr` |
| b5077cd | C, hold margin 0.2, hold guard | 16 ns | +0.183 ns (vs 0.4) | 0.83 ns | +0.806 ns | 1.26 ns | `w_addr` |

- Without the guard the split EX sits below the fabricated designs (0.68 to
  0.70 ns at ff, 1.09 to 1.14 ns at tt), with either flow. With it, both
  flows are above them at both corners, though short of the old RTL with the
  guard (0.13 ns at ff, 0.20 ns at tt).
- The guard is what sets these pins; the flow does not. Calibrated or not,
  the hold repair brings the worst macro input to the same +0.18 ns
  against 0.4 ns. On the calibrated 16 ns run that pin is the worst hold
  path in the design; on the 20 ns run a flop-to-flop path is lower
  (+0.110 ns).
- The calibrated run inserts a seventh of the hold buffers (92 against 703):
  its estimate gives the short paths more wire delay, more than routing then
  gives them (hence the 0.2 ns margin), so the repair pads fewer of them.

Gate level on the two b5077cd netlists without the guard (16 ns with C, and
20 ns), as above (TT's gl_test defines, `+RF_X +RF_COLLIDE_X`): the default
run, the 18 ns run and the rd_late run pass, and from the first reset on the
pins carry the same value as the RTL's on every clock (30,516, 30,518 and
31,041 changes).

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
