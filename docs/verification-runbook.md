# Verification runbook

How to re-run the whole verification closure after an RTL change, what each stage proves, and
what to update when the netlist changes. The plan and the per-item evidence are in
`tb/VPLAN.md`; this file is the procedure.

Nothing here runs on a laptop. Every stage runs on the regression machine (the sandbox: 6 cores,
OSS CAD Suite for the formal tools, docker for EQY, the TT PDK), from a frozen copy of the commit
under test, detached, under the thermal watchdog (a CPU above 80 C kills the run).

## One command

```
git archive <commit> | ssh <box> "mkdir -p regr/run1/tree && tar -x -C regr/run1/tree"
# on the box, in regr/run1/tree:
nice -n 10 setsid nohup bash scripts/verify-all.sh OUT=$HOME/regr/run1/out TREE=<commit> [FORCE=1] \
    [STAGES="unit directed formal rvfi mutation"] [BASE=main] [CHANGED="csr.v"] [LAST=<old results.tsv>] \
    [NETLIST=<nl.v>] [PNL=<pnl.v>] [SUITES=<river_core conf dir>] [SDFDIR=<work dir>] [JOBS=4] \
    > /dev/null 2>&1 < /dev/null &
M=$HOME/regr/run1/out setsid nohup bash <thermal-watch.sh> > /dev/null 2>&1 &
```

`TREE=<commit>` is required: pass the commit you archived. The driver records it in `OUT/TREE` and prints it in `OUT/SUMMARY`. A relaunch with the same OUT and a different TREE refuses to reuse the `done.<stage>` markers and exits 2, so a stale PASS cannot survive an RTL change; `FORCE=1` deletes the markers and reruns everything. The driver writes `OUT/driver.sid` (the watchdog reads it), then one `OUT/<stage>.verdict` per
stage (one line: PASS, FAIL, BOUNDED-OK, NO-BASELINE or ERROR, then counts), `OUT/<stage>.log`, and a marker
`OUT/done.<stage>`. A relaunch with the same OUT skips every stage that has a marker; delete the
marker to rerun that stage (an ERROR stage leaves none). `OUT/SUMMARY` is the last file written:
one line per stage and the wall time of the launch. Do not poll with `tail -f` or sleep loops:
look at `ls OUT` and `cat OUT/*.verdict` when you come back. Exit status 0 means every stage is
PASS or BOUNDED-OK; a mutation stage without LAST reports NO-BASELINE, which is not PASS, so a first run that includes mutation never exits 0 (record its results.tsv and pass it as LAST next time). After a reboot of the box (`uptime -s` changed) checksum-rsync the tree
before trusting it, because recently written files can be zeroed.

Stages default to `unit directed formal rvfi mutation`, plus `eqy` if NETLIST is given, `gl` if
PNL is given and `sdf` if SDFDIR is given (NETLIST is the synthesised `nl.v`, PNL the post-PnR
`pnl.v`, SDFDIR the work directory of the SDF run). The driver does not stop at the first failing
stage.

## What each stage proves

| Stage | Runs | Proves |
|---|---|---|
| unit | `make test-all`, then `test-seeds` with seeds 1 to 8, then `test-wrapper-soc` | Each block and the core against its self-checking bench; the seeded random benches over eight seeds; the mailbox programs through the TinyTapeout pins at a 10 ns and a 20 ns clock (RTL). Simulation: it finds bugs, it does not prove their absence. |
| directed | `tests/directed/run.sh` plain, with `+RF_X +RF_COLLIDE_X`, and `soc` | The directed programs against Spike, on the core alone, with the register file starting at X and colliding reads at X, and through the whole SoC (fabric, memory controller, QSPI engine, Pmod model). Gate: no X in a dump, the tohost store reached. |
| formal | `tb/formal/run.sh` (default list, 39 harnesses) on the `sat` and `sby` engines, then `--nonvac` on every default-list harness | The invariants of VPLAN 4.3; see the verdict words. Each full verdict line (minus trace and log paths) is compared with `scripts/verify-all.expected`, with every `*_DEPTH`/`*_TIMEOUT` override unset: a changed word, depth or cover count fails the stage, and so does a missing harness. Every default-list harness must also have its broken copies FAIL; opt-in harnesses (mem_li, mem_li_cov, mem_ld_cov, md07_miter) are not run. |
| rvfi | `tb/rvfi/run.sh` once per solver family (yices, bmc3, boolector), then the fault matrix `tb/rvfi/mutants.sh` | riscv-formal consistency and instruction checks on the core, bounded from reset (VPLAN 4.5). The matrix injects one fault per row; every row must FAIL some check except the known blind spots (FC51, MD01, MD03, MD10, RG05). |
| mutation | `tb/mutate/run.py` on the `src/` files changed since BASE | Every mutant of a changed file is run against the benches. FAIL on any ERROR or TIMEOUT row (a formal TIMEOUT is an ERROR, never a kill), on a partial run (a listed file with no rows, or a run.py that did not exit 0), or on a kill lost against `LAST`; without `LAST` the verdict is NO-BASELINE (lost kills cannot be checked). `BASE` defaults to `main`; in a tree without `.git` pass `CHANGED="a.v b.v"`. |
| eqy | `tb/eqy/run.sh NETLIST=<nl.v>`, all stages and mutants | The RTL and the hardened netlist have the same next-state function for every flop and the same outputs (VPLAN 4.4). Needs the refit below when the netlist is new. |
| gl | `scripts/gl/build_isa.sh`, `scripts/gl/night.sh` parts A B C D | The same programs run through the pins of the post-PnR netlist match the RTL run, and a mutated netlist fails. Known failures carry a `known:` label. |
| sdf | `tb/gls_sdf/run_glitch.sh` all variants and corners | The reset and pin behaviour at the first clock edge on the SDF-annotated netlist (TT01), with the Pmod timing checks. |

river_core (the full ISA, compliance and riscv-dv regression against Spike) is not part of this
driver. It runs through the river_core driver on the sandbox: `launch-multi.sh` starts
`run-multi.sh` and its thermal watchdog, with `ROUNDS=3` for the full three-round run (one round
is a smoke run). Read its verdicts with the failure labels in the project notes: an unlabelled
divergence is real.

## Verdict words

- PROVED: an unbounded result. Either k-induction at length 1 (the induction step starts from
  any state; a longer induction does not count), or pdr from a free power-up state, or
  structural (a netlist walk, not a SAT proof).
- BOUNDED n: no counterexample within n steps of reset. Never "proved". riscv-formal and BMC are
  always BOUNDED; the driver reports them as BOUNDED-OK.
- COVERED k/k: every cover of a `_cov` harness is reached, with a trace.
- NONVAC-OK: a broken copy of the harness FAILS with a real counterexample (NONVAC-MISS means the
  property does not see that fault; NONVAC-ERROR means no verdict).
- FAILED: a counterexample, or an induction that did not close. ERROR: no verdict (exit 2),
  which is never a pass and never a kill.

## Stated residuals

- mem_li: the worst fetch latency (LI = 449 with `rd_late` 0, 482 with 1, streaming on; 442 and 456 off) is measured by
  simulation, not proved; it also depends on at most four data handshakes between fetches
  (core_df, bounded to 32 steps).
- Bounded, not proved: mem_ld (366), core_req (150), spi_bb and spi_bb1 (96), core_df (32),
  and all of riscv-formal. md07_miter is an opt-in cross-check of md07 only.
- FC02 and FC49: removed from the RTL (2026-11-08), and core_inv with them.
- riscv-formal does not cover U-mode, PMP, MPRV, misa.C, CSRs and trap causes and targets,
  atomics, M arithmetic, illegal encodings other than the all-zero parcel, memory waits over two
  cycles, data-memory consistency, or unbounded histories.
- EQY: the counterexamples of the netlist mutants may start from unreachable states (they show
  that the check sees the gate); the qspi and spi FSM cuts have no gate-side mutant. The chip's
  reset reaching the FSM start states is the one premise left.
- Pmod model: CS hold for a select released by a pin release is counted and printed, not
  checked; SCK 0 to X is not a rise.

## Wall times (4 cores, the box otherwise idle)

Formal default list on the sby engine: about 40 min. riscv-formal (82 checks): about 47 min.
Gate-level night, parts A to C: about 5 h; EQY: hours (it is the long pole after a harden);
the unit, directed and seed runs take minutes; mutation depends on the number of changed files
(each mutant runs several benches). The times of the last run of each stage are in its
`OUT/<stage>.secs`.

## After a harden: the order

1. Harden (the TT flow, with the clock and macro settings of the project).
2. STA on the final netlist: setup and hold slack at every corner, including the macro pins.
3. EQY (`NETLIST` is `nl.v`): refit first if the netlist is new, then the stages.
4. GL (`PNL` is `pnl.v`), parts A to D, the references rebuilt for the new netlist.
5. SDF (`tb/gls_sdf/run_glitch.sh`), all variants and corners, on the same `pnl.v`.

## What to update when the netlist changes

**`scripts/eqy-refit.sh` has not been validated on a real netlist yet** (written after the 2026-11-01 netlist was removed from the sandbox): check its output by hand on its first run. Run `scripts/eqy-refit.sh NETLIST=<nl.v>`. It prints the new md5, runs the read, lemma and
fsminv stages on a scratch copy, prints the flop accounting (gold, gate, direct, rename, recode,
removed) and the partition count of the EQY setup, and writes `refit.patch` with:

- `NL_MD5` in `tb/eqy/run.sh`;
- the EXPECT tables of `tb/eqy/accounting.py` and `tb/eqy/matchreport.py`;
- the partition count in `tb/eqy/verdict.py`.

It applies nothing unless `APPLY=1`, and refuses even then (exit 3) when the accounting shows a
flop that nothing explains, an unmatched flop, a changed constant set (the 186 bits and the two
unused gpio bits) or a changed recoded FSM. Those need a person: a new flop gets a tie list
entry or a name rule, a new or changed FSM needs its enc/dec table in `tb/eqy/fsmcut.v` and a
negative control. Then run the eqy stage itself. Also update by hand: the md5 and the partition
count quoted in `tb/VPLAN.md` 4.4 and `docs/CLAUDE.md`; the pnl md5 and the paths in
`tb/gls_sdf/run_glitch.sh`; and rebuild the Spike signature references of GL part C. The refit
script compares `src/` with the harden's own copy comments aside; a functional difference stops
it, which is what you want.

## What to rerun after an RTL change, by file touched

| Touched | Rerun |
|---|---|
| any `src/*.v` | `verify-all.sh` unit, directed, mutation (the file), formal, rvfi if the core changed |
| `fyracore.v` | formal core_hold, core_req, core_fetch, core_df, md07; riscv-formal on `fyracore.v` (all families and the fault matrix); mutation for the file |
| `csr.v`, `clint.v`, `pmp.v` | formal csr; directed; mutation for the file; riscv-formal only if the retire interface changed |
| `muldiv.v`, `alu.v`, `branchCtrl.v`, `decoder.v`, `controller.v`, `compressed_decoder.v` | unit and seeds; directed; riscv-formal insn families; mutation for the file |
| `syscon.v` | formal syscon_comb, syscon_gate, soc_rst_sync; test-syscon and test-syscon-soc; mutation |
| `spi.v`, `gpio.v` | formal spi_core, spi_dc, spi_bus, spi_bb, spi_bb1, spi_f12; test-spi, test-gpio; mutation |
| `qspi_ctrl.v`, `mem_ctrl.v` | formal mem_flash, mem_tcem, mem_arb, mem_ld (and mem_li by name), qspi_strap; test-qspi with its sweep; the SoC directed suite; see "After a QSPI change" |
| `soc_bus.v`, `alphaone_soc.v`, `uart.v` | formal bus, soc_rst_sync; test-soc-periph; SoC directed suite; mutation |
| `regFile.v`, `rf_top.v` | directed with `+RF_X +RF_COLLIDE_X`; formal core harnesses (they read a stub of `rf_top.v`) |
| any file, after a harden | the post-harden order above: EQY, GL, SDF on the new netlist |
| a new flop or FSM | the refit by a person, plus a mutant and a cover for any new property |

A formal harness reads the files listed in its `FILES` entry in `tb/formal/run.sh` (or its
`.conf` sidecar); a change to any file in that list reruns that harness.

## After a QSPI change

A change in `src/qspi_ctrl.v` or `src/mem_ctrl.v` (streaming flash reads, the `EDh` DDR mode,
`QSPI_CFG`) is checked by:

1. The Pmod model, `tb/qspi_pmod_model.v`, with its DTR unit bench: `make test-pmod-dtr` runs
   pass cases, expected-fail cases and limit-raise cases (each limit raised past its measured
   margin must report). A change to the model's checks needs a case that fails without it.
2. `make test-qspi` with its `QSPI_RUNS` sweep, and `make test-qspi-ddr-sweep`: the passing capture
   points per round trip R (= 8 to 53 ns) against the window rule, for every `DDR_CAP`; it exits 1
   on any difference, and with `+DTR_LAUNCH=1` no point may pass.
3. The SoC directed suite, `tests/directed/run.sh soc`, and its DDR corner
   `RUN_PLUSARGS=+SOC_DDR=1 tests/directed/run.sh soc`. `+RD_LATE` is valid only with
   `+QSPI_DELAY=25 +QSPI_HOLD=12` (the MANIFEST `soc` lines pair them; given alone, every test aborts
   with 0 retires). Those fixed-delay lines pair a delay with the SDR capture point, which a forced
   DDR capture point cannot read, so the DDR corner prints `SKIP <name> (DDR corner: fixed-delay
   line)` for each and counts them in the `REGRESS` line; the DDR timing corners are covered by
   `test-qspi-ddr-sweep` and by `tests/soc/ddr_sweep.S` (the `ddr_sweep` lines in the Makefile).
4. Formal: mem_flash (the CS0 command set, `EDh` included), mem_arb (a stream yields to a data
   access; CS0 never low with CS1/CS2), mem_ld and mem_li (measure LD and LI again with
   `make bounds-qspi` and compare the printed LP/LF/S/LD/LI with the `define` values in
   `tb/formal/mem_props.sv` by hand: the target compares nothing itself), mem_tcem, qspi_strap
   (the two straps) and qspi_pins (the real engine with ddr free, through clk2fflogic: CS0 never
   low with CS1/CS2, CS gap of two clocks, an idle open stream has SCK low and io_oe 0, no `EDh`
   without DDR). The mem_* and qspi_strap harnesses read an SDR copy of the engine (negedge flops
   turned into posedge, ddr tied 0); see the header of `tb/formal/mem.conf`.
5. The mutation campaign on the new logic (`tb/mutate/run.py`, QS mutants) against a frozen tree.
6. EQY refit: new FSM states and flops are expected, so this one is manual.
7. GL parts A to D and SDF, with the Pmod checks at every corner. For DDR the half-cycle paths and
   the pin cone are the parts to look at (`docs/qspi-ddr.md`, section 5).
8. The `tb_sw` benchmarks on the Verilator branch, for the CPI gain.

`tb_rivercore` also checks two core invariants on every cycle (FC02, the CSR-write wait, and
FC49, the M-operation flush rule); a failure prints its name.

## After the Verilator branch merges

The Verilator build and the Pmod model's setup/hold checks have never run together. Once:
`make -C sw run-hello`, `make -C sw run-coremark`, and `SIMULATOR=verilator tests/directed/run.sh soc`
with the Pmod model's setup/hold checks on.
