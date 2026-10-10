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
make test-qspi          # memory controller + QSPI engine vs the QSPI Pmod model
make test-uart          # UART unit testbench (scoreboard + reference TX/RX)
make test-gpio          # GPIO + SPI transmitter unit testbench
make test-soc-periph    # tests/soc/ programs through the SoC vs UART/OLED/keypad models (and the CLINT decode)

# Clean build artifacts
make clean
```

`make test-all` fails if any unit testbench prints a FAIL or TIMEOUT line.

The directed regression against Spike lives in `tests/directed/` (full-trace comparison, every test listed in its `MANIFEST`):

```bash
cd tests/directed && ./run.sh build && ./run.sh      # all runs
./run.sh one <name> +DMEM_WAIT=3                      # one test, any plusargs
./run.sh refs                                         # regenerate Spike references
./run.sh soc                                          # the suite through the whole SoC
./run.sh soc one <name> +RD_LATE +QSPI_DELAY=25 +QSPI_HOLD=12   # one test through the SoC
```

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

- **IF**: Fetch and PC computation. No fetch is requested while EX holds an instruction that decides the next pc (`ex_nofetch`: branch, jump, ECALL, EBREAK, MRET, FENCE.I, PMP CSR write — decode-only terms, so the request never drops mid-fetch); a not-taken branch then costs one bubble.
- **EX**: RV32C expansion (`compressed_decoder`, from `ifex_raw_instr`), decode (`decoder`), control signals (`controller`), register read (`regFile`, one read port) with WB→EX forwarding, ALU execute, branch resolve, PMP check, trap detection, interrupt injection.
- **WB**: Memory access, CSR commit (`csr`), AMO phase 2, register writeback, trap entry.

The pipeline top-level is `src/fyracore.v` (~1350 lines). It instantiates all other modules.

**EX stall cycles that the SoC hides behind the ~42-clock fetch:** one after a CSR write (`csr_wb_hazard`), one to read rs2 (`rs2_phase`), one or two fetch PMP checks in U-mode or with a locked entry, the M-unit's iterations and serial shifts. In the core testbench (zero-wait memory) they are visible as extra cycles; in the SoC only a branch pays its rs2 phase (no fetch is in flight behind a branch).

### Key Architectural Patterns

**CSR write pre-computation:** EX computes the full read-modify-write CSR value and carries it in `exwb_rs2_data` (`exwb_csr_wdata` is an alias wire the testbench reads). The CSR unit always receives `op=CSRRW` — it never does CSRRS/CSRRC itself.

**EX/WB register sharing:** `exwb_alu_result` carries the ALU or M result, the link address and a CSR's old value; `exwb_rs2_data` the store data, the CSR write value and an AMO's new value; `exwb_trap_val` an AMO's old value (an AMO in WB never traps). There is no `ifex_pc_next`: while IF/EX holds an instruction, `pc` is its pc + 2/4.

**CSR state seen by EX:** CSR writes commit in WB, one stage behind the EX consumers, and Zicsr requires a write's effects to be visible to the very next instruction. Nothing is forwarded: the instruction behind a CSR write waits one cycle in EX (`csr_wb_hazard`) until the write has committed, so every EX consumer — a CSR read, `trap_target`/`mret_target`, interrupt gating, MPRV/MPP, TW, `misa.C` — reads stored state. That cycle would make an `rdcycle` right after `csrw mcycle` read written+1; `mcycle_wr_q` in `csr.v` skips the one increment so it reads the written value, as Spike does. Each WARL register stores its `*_legal` wire in `csr.v` (one per register, every WARL rule there and only there), so bits no write can set are constant and have no flops; `wval` selects the same wires and only feeds the testbench trace (`csr_wval`). PMP registers additionally refetch the next instruction after a write (`ex_pmp_csr_wr`). **A new CSR is added in `csr.v` only: the read case, its `*_legal` wire and `wval`.** Anything new read from CSR state in EX is covered by the stall only if it reads stored state — this EX-consumes/WB-commits family has produced six bugs (misa.C, mstatus MPP, MPRV, mie, the counter aliases, PMP).

**Redirects only on a non-stalled cycle.** Every `next_pc` arm is gated on `!stall`. During a stall EX may be looking at forwarded load data that is not valid yet (C3), and the fetch address must not move while a fetch is outstanding.

**Memory handshake:** both ports use request/ready. A request is outstanding while `*_req` is high; its address (and for data we/be/wdata) is held until the cycle `*_ready` is seen with it. `imem_req` is high only while PC is in the executable window (no fetch from IO or unmapped addresses); `dmem_req` excludes trapping accesses and a failing SC; `dmem_be` gives byte lanes for loads as well as stores. `tb/memory_model.v` checks this every cycle and stops the run on a violation.

**Multi-cycle operations stall the pipeline:** MulDiv and the shifts (one 34-bit add/sub and one shift register in `muldiv.v`: `done` comes 34 cycles after `start` on MUL*, 36 on DIV/REM, 2 + shamt on SLL/SRL/SRA, and the instruction occupies EX one cycle more; the ALU has no shifter) and AMO (2 phases via `wb_busy`). `muldiv_start` waits for every stall except a pending fetch (`stall_nofetch`), so the operation runs during the fetch wait. `muldiv_have = muldiv_ready | muldiv_done` gates start, stall and capture: the result is taken on the done cycle if the pipeline can take it and held otherwise, and the unit is never restarted on its own done cycle (`2e6718b` did that, and every M instruction after the first returned the previous result). `muldiv_want` excludes a trapping instruction, or a fetch fault on an M-op word deadlocks. Interrupts are never injected while an M instruction is in EX or during any stall.

**PMP:** one checker (`pmp_unit`), time-shared. When PMP could deny a fetch (U-mode, or a locked entry) the instruction spends one stalled EX cycle checking `ifex_pc` (X) and, if it straddles two words, one more on the upper half, latching the verdicts (`ifetch_lo/hi_denied`); the data access (`ex_alu_result`, R/W/R+W, at MPP's privilege when MPRV=1) is checked on the last EX cycle. Compares are on PA[33:2] (pmpaddr holds 34-bit addresses on RV32).

**Register file:** one read port. An instruction whose format has an rs2 field (R, S, B, AMO) not equal to x0 spends one stalled EX cycle (`rs2_phase`) reading rs2 into `rs2_hold`, which snoops register-file writes to rs2; the port reads rs1 otherwise. The registers have no reset (Priv: unspecified at reset); `plugins/helpers/boot_flash.S` zeroes x1-x31 first. In simulation `regFile.v` starts them at 0 like Spike; `+RF_X` (`RUN_PLUSARGS=+RF_X ./run.sh`) starts them at X, so a test that reads a register it never wrote fails on the X in its dump (`run.sh` fails any dump holding an X, in `spike` and `expect` runs alike). It does not catch an unwritten register that only decides a branch: the simulator takes the not-taken arm, which matches Spike's zeroed registers whenever Spike falls through too.

**LR/SC:** the reservation set is the aligned word. Set on LR retire; cleared on any SC retire, a trap/interrupt commit in WB, and reset. A local store/AMO leaves it alone, even to the reserved word (legal, and what Spike does, so lockstep stays aligned past the SC). No external-agent clear (one hart, no other master).

### Memory Map and SoC

```
0x2000_0000 – 0x20FF_FFFF : flash (16 MB, read + execute, QSPI CS0)
0x8000_0000 – 0x80FF_FFFF : PSRAM (16 MB, rwx + LR/SC, QSPI CS1 = A, CS2 = B by addr[23])
0x0200_0000 – 0x0200_FFFF : CLINT
0x1000_0000 – 0x1000_FFFF : UART (src/uart.v, 16550 subset, byte registers, polled)
0x1001_0000 – 0x1001_FFFF : GPIO OUT/IN + OLED SPI transmitter (src/gpio.v)
0x1002_0000 – 0x1002_FFFF : syscon (reserved, reads 0)
```

The core knows the map only through its PMA parameters (`PMA_ROM_*` fetch + plain loads, `PMA_RAM_*` everything, `PMA_IO0/1_*` data only, anything else faults). Stores/AMO/SC to flash fault (cause 7), LR to flash cause 5. The SoC boots from flash only: `src/alphaone_soc.v` ties the core's `boot_addr` input to 0x2000_0000 (the core-level testbench starts it at 0x8000_0000 instead, where Spike starts). There is no boot ROM, and the QSPI pins are released while `rst` is high so an external master can program the flash. SoC: `alphaone_soc.v` = core + `soc_bus.v` (stateless decode, the core's own req/ready, not APB) + `mem_ctrl.v` (data-first arbitration, PSRAM fetch split at every 1 KB page) + `qspi_ctrl.v` (PSRAM in QPI mode: 0x0B read / 0x38 write; flash unchanged: 0xEB quad I/O read, command on IO0, address/data on all four lines; SCK = clk/2, late sampling with an `rd_late` strap, a start-up sequence that resets the Pmod's devices and puts the PSRAMs in QPI, never selects the flash for a write) + `clint.v` (registered MTIP, mtime = core clock) + `uart.v` (TX back-pressure: a THR write stalls `ready` until the transmitter is free; RTS# flow control; break send/detect via LCR.SBC and LSR.BI; no FIFOs, no interrupt) + `gpio.v` (OUT/IN, SPI mode-3 transmitter for the OLED with the same back-pressure). An IO target may drop `ready` only while its own select is high; `soc_bus` ANDs them. Design notes: `docs/soc-architecture.md`. Chip pinout and peripherals: `docs/pins-and-peripherals.md` (the tt_um wrapper is not built; no PLIC).

Verification runs the core on this map (boot from PSRAM). Spike gets `-m0x20000000:0x1000000,0x80000000:0x1000000`; Spike has no read-only memory, so a store to flash is a known legal divergence. `tests/directed/run.sh soc` runs the directed suite through the whole SoC against a behavioural QSPI Pmod (`tb/qspi_pmod_model.v`): the testbench loads the test into the model's PSRAM and forces the core's `boot_addr` to 0x8000_0000 (registers start at 0 in simulation, as in Spike) and traces from there; `flash` tests boot from the model's flash instead. MANIFEST `soc` lines rerun tests through the SoC with the model's hostile hand-over states and late sampling. Flash/PSRAM protocol details: `docs/qspi-memories.md`.

## Critical Invariants

- **Trap cause priority** must match RISC-V spec Table 3.7: ifetch access fault (1) > illegal (2) > inst addr misaligned (0) > ecall (11/8) > ebreak (3) > misaligned (4/6) > data access fault (5/7). Locate the if-else chain by the `exwb_trap_cause` assignments, not by line number. Cause 2 is tested via `ex_illegal_insn`, which `ex_trap` also consumes so the two lists cannot drift; the fallthrough arm is cause 7, and it is reachable for exactly one condition. Reordered in `11384f8`.
- **Counter CSRs** (mcycle, minstret) have merged always blocks — auto-increment and CSR write live in the same block to avoid dual-driver synthesis failures. Never split them.
- **CSRRS/CSRRC with rs1=0** must NOT write. The pipeline uses `ex_csr_writes` (not `ex_csr_active`) to gate `exwb_csrWR`.
- **mtvec is direct-mode only** — `[1:0]` forced to `2'b00` on write (WARL), in `mtvec_legal`.
- **IRQ MPP save:** `priv_mode` must NOT be set to M on `irq_inject` directly — it's updated via the `csr_trap_signal` path one cycle later so the CSR unit captures the correct old privilege for MPP.
- **PMP locked entries:** TOR lock propagates downward (entry i with TOR+L locks pmpaddr[i-1]). Implemented once, in the `pmpcfg0_legal`/`pmpaddr*_legal` wires.
- **pmpcfg A=2'b10 (NA4) is LEGAL and is stored as written.** Bits [6:5] of each byte are reserved and read 0.
- **mstatus:** resets to 0 (MPP=U, matching Spike); a write of MPP=01/10 is legalised to U.
- **mip has no writable bits** on this M+U core; it reads the MSIP/MTIP/MEIP wires. MTIP is registered in the CLINT, so it lags an mtimecmp store by two clocks -- two instructions when the fetch is fast. MIE set by the instruction right after the store no longer catches the stale MTIP (the CSR-write stall outlasts it); a spurious timer interrupt stays legal. `mtip_stale` pins both.
- **mtvec resets to 0** (as Spike), which is unmapped on the SoC: boot code must set it before anything can trap.

## Verilog Conventions

- All source is Verilog-2001 (`iverilog` compatible, no SystemVerilog).
- Forward-declared wires (e.g., `irq_inject`, `pmp_allow`) are declared near the top of `fyracore.v` to satisfy iverilog's linear processing. If you add a new wire that's assigned later in the file but referenced earlier, declare it early.
- Pipeline registers use the naming convention `ifex_*` (IF→EX) and `exwb_*` (EX→WB).
- Controller outputs use `ctrl_*` prefix. CSR unit outputs use `csr_*` prefix.
- The `controller.v` is purely combinational — no state, no clk.
