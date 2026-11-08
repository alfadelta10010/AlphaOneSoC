# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FyraCore is a 3-stage pipelined RV32IMAC+Zicsr+Zifencei RISC-V processor targeting SkyWater 130nm (sky130, TinyTapeout). It supports M-mode and U-mode privilege levels with PMP. The goal is to boot no-MMU Linux (uClinux). Area is the #1 priority, speed is #2.

A comprehensive reference document lives at `docs/FyraCore_CPU_Reference.md` — read it before making non-trivial changes.

## Build and Test Commands

**Prerequisites:** Icarus Verilog (`iverilog`, `vvp`), RISC-V toolchain (`riscv64-unknown-elf-gcc`).

Use Makefile targets for all build and test operations. The Makefile wraps the shell scripts in `scripts/`.

```bash
# Always clean before running tests to avoid stale build artifacts
make clean

# Run all tests (clean first)
make clean && make test-all

# Run a single assembly test via Makefile
make asm FILE=tests/<test>.S

# Run individual component testbenches
make test-alu
make test-csr
make test-muldiv
make test-compressed
make test-controller
make test-decoder
make test-signext
make test-branchctrl
make test-regfile
make test-pmp           # PMP checker vs a Privileged 3.7.1 model
make test-clint         # CLINT vs its register map and timer rules
make test-syscon        # syscon + watchdog unit bench vs its spec model (+SEED=<n>)
make test-syscon-soc    # SoC programs through syscon: reboot, strap, power-off, pin resets, watchdog
make test-seeds SEEDS="1 2 3"   # the ten seeded unit benches, once per seed
make test-qspi          # memory controller + QSPI engine vs the QSPI Pmod model
make test-uart          # UART unit testbench (scoreboard + reference TX/RX)
make test-gpio          # GPIO + SPI transmitter unit testbench
make test-soc-periph    # tests/soc/ programs through the SoC vs UART/OLED/keypad models (and the CLINT decode)
make test-wrapper       # the TinyTapeout top level through its 24 pins only (tb/tb_tt_um.v, tests/soc/tt_pins.S)

# Clean build artifacts
make clean
```

`make clean` is `rm -rf build/`: it also deletes mutation results and frozen trees kept under build/. When build/ holds anything else, use `make BUILD_DIR=build/tb clean` (and build with the same `BUILD_DIR`).

`make test-all` fails a unit testbench unless it exits 0, prints a `PASS` line, and prints no FAIL, TIMEOUT, ERROR or FATAL line. Each prints its check count, and the seeded ones (`+SEED=`) the seed that reproduces the run.

The directed regression against Spike lives in `tests/directed/` (full-trace comparison, every test listed in its `MANIFEST`):

```bash
cd tests/directed && ./run.sh build && ./run.sh      # all runs
./run.sh one <name> +DMEM_WAIT=3                      # one test, any plusargs
./run.sh refs [<name>...]                             # regenerate Spike references (all, or the named tests)
./run.sh soc                                          # the suite through the whole SoC
./run.sh soc one <name> +RD_LATE +QSPI_DELAY=25 +QSPI_HOLD=12   # one test through the SoC
```

The runner also takes `FYRA_SRC=<dir>` (build from another copy of src/), `OUT_DIR=<dir>` (artifacts elsewhere) and `FAILFAST=1` (stop at the first failing run); none changes what a run checks. `tb/memory_model.v` and `tb/tb_rivercore.v` stop a run on any request outside the core's bus contract (CPU reference 5.1) and on any bus transaction that does not match the retiring access the trace shows (address, lanes, direction, store data).

Formal checks (`tb/formal/`) run with `bash tb/formal/run.sh [--nonvac] [-e DIR] [harness ...]`; with no name it runs the 37 harnesses of the default list (built-ins plus the `tb/formal/*.conf` sidecars). Two engines: `sat` (default, yosys's built-in solver) and `FORMAL_ENGINE=sby` (sby with bitwuzla/yices smtbmc; a harness with MODE `pdr` always uses sby with `abc pdr`, MODE `sbmc` is a bounded check that always uses sby). `FORMAL_BIN=<dir>` is prepended to PATH inside `run.sh` only: point it at an OSS CAD Suite (yosys 0.70) for sby, pdr and `tb/mutate/run.py`'s formal bench; the regressions run on the sandbox, not on the local machine. A sidecar `tb/formal/<n>.conf` adds a harness without editing `run.sh` (it sets FILES, MODE and the optional tables, and appends to ALL); one that redefines a built-in is an ERROR. Verdict words, as the logs print them: PROVED (k-induction at length 1 on `sat` or sby; pdr from a free power-up state, `$anyinit`; or structural), BOUNDED n (no counterexample within n steps of reset: `core_req` 150, `spi_bb`/`spi_bb1` 96, `core_df` 32, `mem_ld` 366), COVERED k/k (a `<n>_cov` harness: every cover reached), FAILED (a counterexample, or an induction that did not close) and ERROR (no verdict: exit 2). A longer induction does not count as PROVED. Non-vacuity: `bash tb/formal/run.sh --nonvac <harness>` runs the broken copies listed in `tb/formal/<harness>.nonvac`; each must FAIL, and the verdict is NONVAC-OK or NONVAC-MISS. Covers are the `*_cov` harnesses (`csr_cov`, `core_hold_cov`, `mem_arb_cov`...). `-e DIR` writes the generated `sby_<n>.sby` for a manual `sby -f` run. Harnesses: `csr` and `syscon_comb` (PROVED by pdr), `core_hold`, `core_fetch`, `syscon_gate`, `spi_core`, `spi_dc`, `spi_bus`, `bus` and `md07` (k-induction, length 1), `core_req`, `spi_bb`, `spi_bb1`, `core_df` (BOUNDED), `soc_rst_sync` and `spi_f12` (structural), `qspi_strap`, `mem_flash`, `mem_tcem`, `mem_arb` (pdr), `mem_ld` (BOUNDED 366). Opt-in, run by name and not in the default list: `mem_li` and its cover, `mem_ld_cov`, `md07_miter` and `md07_miter_cov`. The plan, per-harness evidence and residuals are in `tb/VPLAN.md` (4.3).

`tb/rvfi/` runs riscv-formal on FyraCore through an RVFI port (`bash tb/rvfi/run.sh`, resumable, in a shell with the OSS CAD Suite environment; `--list` shows the checks, `ONLY="regex"` selects some). Every PASS is BOUNDED (BMC from reset), never PROVED; results, fault matrix and the not-covered list are in `tb/rvfi/RESULTS.md`. `tb/eqy/run.sh` proves the RTL equivalent to a hardened netlist (EQY partitions, an FSM cut point, a constant-bit lemma, and netlist mutants that must be caught). `tb/gls_sdf/run_glitch.sh WORK=<dir>` runs `tb/tb_tt_um.v` on the SDF-annotated netlist with `tb/gls_sdf/glitch_mon.v` watching `uo_out` and `uio_oe` (variants D, D2, N2, N1; corners nom_tt, max_ss, min_ff, ...); it needs the hardened netlist and runs on the sandbox.

The QSPI Pmod model (`tb/qspi_pmod_model.v`) checks the host's data-in and chip-select setup and hold against the datasheet limits and prints samples, violations and minimum margins at the end of a run. The checks are on by default; `+QSPI_TCHECK=0` turns them off (diagnosis only). A violation makes the bench fail. `make test-seeds` runs the seeded unit benches over seeds 1-8 by default (`SEEDS="1 2 3"` to choose); the uart and SPI traffic floors are steered by construction, and a floor miss fails the run.

Mutation testing measures whether the benches can fail (`tb/mutate/`): `python3 tb/mutate/run.py --check` (every fault applies and compiles), `python3 tb/mutate/run.py -j 2 [--only ID,...] [--file csr.v] [--benches unit,dir,soc,dir-soc,formal]` (each mutant is a throwaway copy of src/ under build/mut/, scored and deleted), `--results <file>` names the results file and `--report` prints the kill matrix (ERROR is counted apart from killed and survived). `--tree <dir>` runs the benches of another tree, such as a frozen copy, against the same faults. A campaign must run against a frozen tree: `git archive HEAD | tar -x -C build/<dir>`, then `--tree build/<dir>`. Editing tests while it runs gives false kills. The syscon campaign runs on the sandbox, from the root of a frozen tree.

The core bench can reset the core in the middle of a program (`tb/tb_rivercore.v`; memory keeps its contents, the pc restarts at `boot_addr`): `+RESETS=n` drops n resets (default 0; `+RESET_AT` alone means 1), reset i is raised `+RESET_AT=c` (default 1000) plus i times `+RESET_STRIDE=s` (default 0) clocks after the previous release, and rst stays high `+RESET_LEN=l` clocks (default 2, at least 1). Each reset prints a NOTE line with the pc and the dump-line count. `core_reset` uses them and is `#soc-skip`.

Memory-timing plusargs: `+IMEM_WAIT=n +DMEM_WAIT=n +IMEM_RANDOM=1 +DMEM_RANDOM=1 +MEM_SEED=n +NOTREADY_DATA=0|1|2` (read data while not ready: X, zeros, garbage). Deterministic waits, random waits, zero waits and garbage data each expose different bugs; sweep them independently. A pipeline change is not verified until the directed suite and the relevant riscv-arch-test tests pass.

If you need script-level options not exposed by the Makefile (e.g., `--vcd`, `--max-cycles`), fall back to the script directly:

```bash
bash scripts/run_asm_test.sh tests/<test>.S --quiet
bash scripts/run_asm_test.sh tests/<test>.S --vcd
bash scripts/run_asm_test.sh tests/<test>.S --max-cycles 50000
```

Test programs are RISC-V assembly in `tests/*.S`. The build pipeline: `.S` → `asm2hex.sh` → `.hex` → `$readmemh` into simulation memory. Tests signal pass/fail by writing to specific registers and entering a halt loop (detected by the testbench).

## Development Workflow — Mandatory Atomic Commit Policy

**Every change MUST be committed immediately after it is made and verified.** No exceptions — this applies to bug fixes, refactoring, test updates, documentation changes, and small tweaks.

### Core Principle: Atomic Commits

**Each commit must be a single, indivisible logical unit.** This means:

- One commit = one bug fix, OR one refactor, OR one feature, OR one test update, OR one documentation change
- Never combine multiple unrelated changes into a single commit
- Never split a single logical change across multiple commits
- Each commit must be understandable and reviewable in isolation
- Each commit must leave the repo in a **working, test-passing state**

### Commit Rules

1. **Identify the atomic unit before making changes.** Ask yourself: "What is the single thing I'm changing?" If you can answer with one sentence, you've identified a commit-worthy unit. If your answer is "I'm fixing X and also refactoring Y and also adding Z", break it into three separate commits.

2. **One commit = one file modification pattern.** Most commits touch 1–3 files. Commits that touch 5+ files are a red flag — you've likely combined multiple changes.

3. **Test before every commit.** Run `make clean && make test-all` (or the relevant subset) before committing. Never commit failing tests, unverified code, or partial implementations (unless explicitly marked WIP).

4. **Coupled changes in one commit are OK.** Example: adding a CSR that EX consumes requires changes in both `csr.v` (register logic) and `fyracore.v` (the consumer). These are tightly coupled — one commit is appropriate. But adding a CSR and refactoring the PMP checker are NOT coupled — two separate commits.

5. **No uncommitted changes at task end.** When a task is complete, `git status` must show a clean working directory. Do not leave work-in-progress files uncommitted.

6. **Always `make clean` before running the full test suite** to ensure no stale artifacts influence results.

7. **Run regression tests after finishing changes** to ensure nothing previously working is broken.

## Architecture

### Pipeline: IF → EX → WB

- **IF**: Fetch and PC computation; RV32C expansion (`compressed_decoder`) on the way into IF/EX, so EX starts from the 32-bit form (`ifex_instr`; a compressed instruction's own 16 bits travel beside it in `ifex_raw16` for the trace and mtval); the numbers of the registers the fetched instruction reads (`rf_fields`, from the raw bits), which IF/EX keeps as the register file's read addresses. No fetch is requested while EX holds an instruction that decides the next pc (`ex_nofetch`: branch, jump, ECALL, EBREAK, MRET, FENCE.I, PMP CSR write — decode-only terms, so the request never drops mid-fetch); a not-taken branch then costs one bubble. **Fetch word reuse:** a fetch of a compressed instruction also returns the halfword behind it; `if_kbuf` (16 flops, no reset) keeps it and `if_kv` marks it as the instruction at `pc`, so the next instruction, if compressed, loads into IF/EX with `imem_req` low (a pair of compressed instructions costs one fetch). IF/EX can therefore load a cycle in which no fetch is requested.
- **EX**: decode (`decoder`, from `ifex_instr`, which IF already expanded if compressed), control signals (`controller`), register read (`regFile`, the `rf_top` macro, two ports, addresses `ifex_rf_rs1/2`; no WB→EX forwarding, a reader of the WB instruction's rd waits: `use_hazard`), ALU execute, branch resolve, PMP check, trap detection, interrupt injection. Three cycles at least: the synchronous register read (data is the instruction's from its second cycle, `ex_rf_ok`), then the ALU and comparator, whose results are registered (`alu_r`, `br_r`), then everything decided from them, which reads the flops on the cycles `ex_ph` is set (`ex_wait` holds the instruction until then).
- **WB**: Memory access, CSR commit (`csr`), AMO phase 2, register writeback, trap entry.

The pipeline top-level is `src/fyracore.v` (~1350 lines). It instantiates all other modules.

**EX stall cycles that the SoC hides behind the ~42-clock fetch:** the cycles a CSR write spends in WB (the next instruction is still in its 3-cycle EX), one or two fetch PMP checks in U-mode or with a locked entry, the M-unit's iterations and serial shifts. In the core testbench (zero-wait memory) they are visible as extra cycles: compiled C runs at 3.33 CPI there (3.88 with the one-port register file, 2.55 before the area cuts). In the SoC they show only where no fetch is in flight, i.e. on the `ex_nofetch` instructions: in U-mode (or with a locked entry) every jump and branch pays its fetch PMP check, +1 clock (compiled C in U-mode is 0.23% slower than in M-mode). Interrupts also wait for an M op or shift in EX: in a loop of 31-bit shifts the timer interrupt's latency averages 433 clocks (max 550), against 108 for a loop of NOPs.

### Key Architectural Patterns

**CSR write pre-computation:** EX computes the full read-modify-write CSR value and carries it in `exwb_rs2_data` (`exwb_csr_wdata` is an alias wire the testbench reads). The CSR unit always receives `op=CSRRW` — it never does CSRRS/CSRRC itself.

**EX/WB register sharing:** `exwb_alu_result` carries the ALU or M result, the link address and a CSR's old value; `exwb_rs2_data` the store data, the CSR write value and an AMO's new value; `exwb_trap_val` an AMO's old value (an AMO in WB never traps). There is no `ifex_pc_next`: while IF/EX holds an instruction, `pc` is its pc + 2/4.

**CSR state seen by EX:** CSR writes commit in WB, one stage behind the EX consumers, and Zicsr requires a write's effects to be visible to the very next instruction. Nothing is forwarded: the instruction behind a CSR write is still in its 3-cycle EX (`ex_wait`) while the write commits, until the write has committed, so every EX consumer — a CSR read, `trap_target`/`mret_target`, interrupt gating, MPRV/MPP, TW, `misa.C` — reads stored state. That wait would make an `rdcycle` right after `csrw mcycle` read written+1; `mcycle_wr_q` in `csr.v` skips the one increment so it reads the written value, as Spike does. Each WARL register stores its `*_legal` wire in `csr.v` (one per register, every WARL rule there and only there), so bits no write can set are constant and have no flops; `wval` selects the same wires and only feeds the testbench trace (`csr_wval`). PMP registers additionally refetch the next instruction after a write (`ex_pmp_csr_wr`). **A new CSR is added in `csr.v` only: the read case, its `*_legal` wire and `wval`.** Anything new read from CSR state in EX is covered by EX's 3 cycles only if it reads stored state — this EX-consumes/WB-commits family has produced six bugs (misa.C, mstatus MPP, MPRV, mie, the counter aliases, PMP).

**Redirects only on a non-stalled cycle.** Every `next_pc` arm is gated on `!stall`. During a `use_hazard` stall EX's operand is not the written value yet (C3) -- nothing is forwarded, the instruction reads it from the register file after the stall -- before `ex_ph` the address in `alu_r` is not the instruction's own, and the fetch address must not move while a fetch is outstanding.

**Memory handshake:** both ports use request/ready. A request is outstanding while `*_req` is high; its address (and for data we/be/wdata) is held until the cycle `*_ready` is seen with it. `imem_req` is high only while PC is in the executable window (no fetch from IO or unmapped addresses); `dmem_req` excludes trapping accesses and a failing SC; `dmem_be` gives byte lanes for loads as well as stores. `tb/memory_model.v` checks this every cycle and stops the run on a violation.

**Multi-cycle operations stall the pipeline:** MulDiv and the shifts (one 34-bit add/sub and one shift register in `muldiv.v`: `done` comes 34 cycles after `start` on MUL*, 36 on DIV/REM, 2 + shamt on SLL/SRL/SRA, and the instruction occupies EX one cycle more; the ALU has no shifter) and AMO (2 phases via `wb_busy`). `muldiv_start` waits for every stall except a pending fetch (`stall_nofetch`), so the operation runs during the fetch wait. `muldiv_have = muldiv_ready | muldiv_done` gates start, stall and capture: the result is taken on the done cycle if the pipeline can take it and held otherwise, and the unit is never restarted on its own done cycle (`2e6718b` did that, and every M instruction after the first returned the previous result). `muldiv_want` excludes a trapping instruction, or a fetch fault on an M-op word deadlocks. Interrupts are never injected while an M instruction is in EX or during any stall.

**PMP:** one checker (`pmp_unit`), time-shared. When PMP could deny a fetch (U-mode, or a locked entry) the instruction spends one stalled EX cycle checking `ifex_pc` (X) and, if it straddles two words, one more on the upper half, latching the verdicts (`ifetch_lo/hi_denied`); the data access (`ex_alu_result`, R/W/R+W, at MPP's privilege when MPRV=1) is checked on the last EX cycle. Compares are on PA[33:2] (pmpaddr holds 34-bit addresses on RV32).

**Register file:** Sylvain Munaut's 32x32 2R1W hard macro `rf_top` (views and provenance in `macro/rf_top/`, simulation model `src/rf_top.v`, wrapper `src/regFile.v`, instance `soc.cpu.rf.rf_macro`). Reads are synchronous and write-first: the addresses are taken on a rising edge and the data that follows is the registers as they stand after that edge's write, which is what a combinational read gives in the next cycle. The addresses are the EX instruction's own for as long as it is in EX, kept as fetched in `ifex_rf_rs1/ifex_rf_rs2` (from `rf_fields`, `src/decoder.v`, RVC-aware, checked exhaustively by `tb/tb_rf_fields.v`), so neither the decoder nor any stall term reaches the macro's address pins; the data is the instruction's from its second EX cycle (`ex_rf_ok`). Nothing is forwarded from WB: an instruction whose rd EX reads keeps EX from counting its operands as read until it has written (`use_hazard`), and the value comes from the register file through `regFile`'s write-first bypass. An operand is read once, in EX, and travels in EX/WB from there: an AMO, LR or SC never re-reads the register file after writing rd, so rd == rs1/rs2 is safe (`tests/directed/rf_amo_alias`). x0: the macro's word 0 is an ordinary, unreset word; it is never written (`w_ena` gated on rd != 0) and each port's data is masked with the decoded field. `tb/tb_rivercore.v` checks on every cycle from an instruction's second in EX that the macro took that instruction's registers and that the data equals a shadow register file, and prints how many reads it checked. The registers have no reset (Priv: unspecified at reset); `plugins/helpers/boot_flash.S` zeroes x1-x31 first. In simulation `src/rf_top.v` starts them at 0 like Spike; `+RF_X` (`RUN_PLUSARGS=+RF_X ./run.sh`) starts them at X, so a test that reads a register it never wrote fails on the X in its dump (`run.sh` fails any dump holding an X, in `spike` and `expect` runs alike). It does not catch an unwritten register that only decides a branch: the simulator takes the not-taken arm, which matches Spike's zeroed registers whenever Spike falls through too. The macro's liberty is a placeholder (setup 2 / hold 0.2 / clk->q 4 ns, one corner): STA through it is only as good as those numbers. Write-first is the model's behaviour, the author's stated design and what KianV's sky25b errata shows on silicon, but its timing is uncharacterised, and every load-use and every read two instructions after a write needs it. So `regFile` does it itself: on an edge that writes the word a port is reading, the written data is kept in `byp` and that port gives it for the cycle (`hit1`/`hit2`); the macro's own answer for such a read is never used. `+RF_COLLIDE_X` makes the model return X there (`RUN_PLUSARGS="+RF_X +RF_COLLIDE_X" ./run.sh`), and the directed suite must stay clean with it (`macro/rf_top/README.md`).

**LR/SC:** the reservation set is the aligned word. Set on LR retire; cleared on any SC retire, a trap/interrupt commit in WB, and reset. A local store/AMO leaves it alone, even to the reserved word (legal, and what Spike does, so lockstep stays aligned past the SC). No external-agent clear (one hart, no other master).

### Memory Map and SoC

```
0x2000_0000 – 0x20FF_FFFF : flash (16 MB, read + execute, QSPI CS0)
0x8000_0000 – 0x80FF_FFFF : PSRAM (16 MB, rwx + LR/SC, QSPI CS1 = A, CS2 = B by addr[23])
0x0200_0000 – 0x0200_FFFF : CLINT
0x1000_0000 – 0x1000_FFFF : UART (src/uart.v, 16550 subset, byte registers, polled)
0x1001_0000 – 0x1001_FFFF : GPIO OUT/IN + OLED SPI transmitter (src/gpio.v)
0x1002_0000 – 0x1002_FFFF : syscon (src/syscon.v: reboot, power-off, reset cause, boot mode, chip ID, straps; watchdog at +0x100)
```

The core knows the map only through its PMA parameters (`PMA_ROM_*` fetch + plain loads, `PMA_RAM_*` everything, `PMA_IO0/1_*` data only, anything else faults). Stores/AMO/SC to flash fault (cause 7), LR to flash cause 5. The SoC boots from flash only: `src/alphaone_soc.v` ties the core's `boot_addr` input to 0x2000_0000 (the core-level testbench starts it at 0x8000_0000 instead, where Spike starts). There is no boot ROM, and the QSPI pins are released while `rst` is high so an external master can program the flash. SoC: `alphaone_soc.v` = core + `soc_bus.v` (stateless decode, the core's own req/ready, not APB) + `mem_ctrl.v` (data-first arbitration, PSRAM fetch split at every 1 KB page) + `qspi_ctrl.v` (PSRAM in QPI mode: 0x0B read / 0x38 write; flash unchanged: 0xEB quad I/O read, command on IO0, address/data on all four lines; SCK = clk/2, late sampling with an `rd_late` strap, a start-up sequence that resets the Pmod's devices and puts the PSRAMs in QPI, never selects the flash for a write) + `clint.v` (registered MTIP, mtime = core clock) + `uart.v` (TX back-pressure: a THR write stalls `ready` until the transmitter is free; RTS# flow control; break send/detect via LCR.SBC and LSR.BI; no FIFOs, no interrupt) + `gpio.v` (OUT/IN, SPI mode-3 transmitter for the OLED with the same back-pressure) + `syscon.v` (reboot, power-off, reset cause, boot mode, chip ID, straps, and a DesignWare-layout watchdog at +0x100 that reboots through the same path; FINISH at +0x0 follows QEMU's sifive_test: 0x5555 power-off, 0x7777 reboot, 0x3333 fail). The chip reset `rst` resets only syscon's RESET_CAUSE, BOOT_MODE, strap and its reboot/power-off flops; every other block runs on `rst_soc` (= `rst`, or a syscon reboot for two edges, or power-off until `rst`). An IO target may drop `ready` only while its own select is high; `soc_bus` ANDs them. Design notes: `docs/soc-architecture.md`. Chip pinout and peripherals: `docs/pins-and-peripherals.md` (no PLIC). TinyTapeout top level: `src/tt_um_alfadelta10010_alphaone_soc.v` (reset asserted asynchronously by `rst_n` -- the demo board's firmware resets with the clock stopped -- and released on the second clock edge; while it is high `uio_oe` is 0 and `uo_out` is 0x39 without a clock; pins-only bench `make test-wrapper`).

Verification runs the core on this map (boot from PSRAM). Spike gets `-m0x20000000:0x1000000,0x80000000:0x1000000`; Spike has no read-only memory, so a store to flash is a known legal divergence. `tests/directed/run.sh soc` runs the directed suite through the whole SoC against a behavioural QSPI Pmod (`tb/qspi_pmod_model.v`): the testbench loads the test into the model's PSRAM and forces the core's `boot_addr` to 0x8000_0000 (registers start at 0 in simulation, as in Spike) and traces from there; `flash` tests boot from the model's flash instead. MANIFEST `soc` lines rerun tests through the SoC with the model's hostile hand-over states and late sampling. Flash/PSRAM protocol details: `docs/qspi-memories.md`.

## Critical Invariants

- **Trap cause priority** must match RISC-V spec Table 3.7: ifetch access fault (1) > illegal (2) > inst addr misaligned (0) > ecall (11/8) > ebreak (3) > misaligned (4/6) > data access fault (5/7). Locate the if-else chain by the `exwb_trap_cause` assignments, not by line number. Cause 2 is tested via `ex_illegal_insn`, which `ex_trap` also consumes so the two lists cannot drift; the fallthrough arm is cause 7, and it is reachable for exactly one condition. Reordered in `11384f8`.
- **EX is 3 cycles, and the CSR-write wait depends on it.** There is no stall term for a CSR write in WB (the former `csr_wb_hazard` was removed 2026-11-08 as dead). If EX ever gets shorter than 3 cycles, that stall must return, or an instruction behind a CSR write reads stale CSR state (Zicsr). The same goes for the M handshake, which has no `flush` gates because a flush never meets a live M operation.
- **Counter CSRs** (mcycle, minstret) have merged always blocks — auto-increment and CSR write live in the same block to avoid dual-driver synthesis failures. Never split them.
- **CSRRS/CSRRC with rs1=0** must NOT write. The pipeline uses `ex_csr_writes` (not `ex_csr_active`) to gate `exwb_csrWR`.
- **mtvec is direct-mode only** — `[1:0]` forced to `2'b00` on write (WARL), in `mtvec_legal`.
- **IRQ MPP save:** `priv_mode` must NOT be set to M on `irq_inject` directly — it's updated via the `csr_trap_signal` path one cycle later so the CSR unit captures the correct old privilege for MPP.
- **PMP locked entries:** TOR lock propagates downward (entry i with TOR+L locks pmpaddr[i-1]). Implemented once, in the `pmpcfg0_legal`/`pmpaddr*_legal` wires.
- **pmpcfg A=2'b10 (NA4) is LEGAL and is stored as written.** Bits [6:5] of each byte are reserved and read 0.
- **mstatus:** resets to 0 (MPP=U, matching Spike); a write of MPP=01/10 is legalised to U.
- **mip has no writable bits** on this M+U core; it reads the MSIP/MTIP/MEIP wires. MTIP is registered in the CLINT, so it lags an mtimecmp store by two clocks -- two instructions when the fetch is fast. MIE set by the instruction right after the store no longer catches the stale MTIP (the CSR-write stall outlasts it); a spurious timer interrupt stays legal. `mtip_stale` pins both.
- **The wrapper's pins leave reset on the second clock edge after `rst_n` rises** (`run` loads `!rst_sync[0]`), one edge after the SoC's flops first take their reset values. No RTL bench can tell that from the first edge (mutant TT01 survives), but the demo board resets with the clock stopped and a glitch at that edge would reach the pins (`tb/VPLAN.md` 4.2). Do not "simplify" `run` to load 1. Selecting a project on the board does not reset it (`docs/pins-and-peripherals.md` 1).
- **A new SoC block is reset from `rst_soc`, never from `rst`,** unless it must survive a reboot (only syscon's sticky state does). A block left on `rst` keeps running through a reboot.
- **`if_kv` (fetch word reuse) is only 1 while `pc` is the sequential successor of the fetch that filled `if_kbuf`; there is no address tag.** It is set by an IF/EX load of a compressed instruction from a fetch (its successor halfword not starting a 32-bit one), held only on edges where `pc` holds (the `stall` arm, a not-taken branch's bubble) and cleared by every other `pc` change (`flush`, all taken on `!stall` edges) and by the hit that uses it. Do not add a `next_pc` arm that is not in `flush`. The mux is in front of the `if_exec` mask. No store snoops it: a store to the kept halfword is seen only after FENCE.I (which has no compressed form, so it always drops it) -- legal by Zifencei, pinned by `fr_smc`. `tb_rivercore` checks the rule every cycle and prints `fetch-reuse: hits ...`; `bash tb/formal/run.sh core_fetch` proves what IF/EX loads is the memory's halfword at `pc`.
- **mtvec resets to 0** (as Spike), which is unmapped on the SoC: boot code must set it before anything can trap.

## Verilog Conventions

- All source is Verilog-2001 (`iverilog` compatible, no SystemVerilog).
- Forward-declared wires (e.g., `irq_inject`, `pmp_allow`) are declared near the top of `fyracore.v` to satisfy iverilog's linear processing. If you add a new wire that's assigned later in the file but referenced earlier, declare it early.
- Pipeline registers use the naming convention `ifex_*` (IF→EX) and `exwb_*` (EX→WB).
- Controller outputs use `ctrl_*` prefix. CSR unit outputs use `csr_*` prefix.
- The `controller.v` is purely combinational — no state, no clk.
