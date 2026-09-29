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

4. **Coupled changes in one commit are OK.** Example: adding a new writable CSR requires changes in both `csr.v` (register logic) and `fyracore.v` (forwarding logic). These are tightly coupled — one commit is appropriate. But adding a CSR and refactoring the PMP checker are NOT coupled — two separate commits.

5. **No uncommitted changes at task end.** When a task is complete, `git status` must show a clean working directory. Do not leave work-in-progress files uncommitted.

6. **Always `make clean` before running the full test suite** to ensure no stale artifacts influence results.

7. **Run regression tests after finishing changes** to ensure nothing previously working is broken.

## Architecture

### Pipeline: IF → EX → WB

- **IF**: Fetch + RV32C decompression (`compressed_decoder`). PC computation.
- **EX**: Decode (`decoder`), control signals (`controller`), register read (`regFile`) with WB→EX forwarding, ALU execute, branch resolve, PMP checks, trap detection, interrupt injection.
- **WB**: Memory access, CSR commit (`csr`), AMO phase 2, register writeback, trap entry.

The pipeline top-level is `src/fyracore.v` (~1250 lines). It instantiates all other modules.

### Key Architectural Patterns

**CSR write pre-computation:** EX computes the full read-modify-write CSR value and stores it in `exwb_csr_wdata`. The CSR unit always receives `op=CSRRW` — it never does CSRRS/CSRRC itself. This simplifies the write path and forwarding.

**CSR state seen by EX:** CSR writes commit in WB, one stage behind the EX consumers, and Zicsr requires a write's effects to be visible to the very next instruction. `csr.v` therefore computes `wval` — the value the CSR being written reads back after the write — and every WARL rule lives there and only there. fyracore forwards it (`csr_wval`) to an EX read of the same CSR or its U-mode counter alias and to `trap_target`/`mret_target`; the testbench trace prints it. The mstatus fields (MIE, MPP, MPRV, TW), `mie` and `misa.C` are exported post-write for the same reason. PMP registers are not forwarded: a write to `pmpcfg0`/`pmpaddr0-3` refetches the next instruction (`ex_pmp_csr_wr`). **A new CSR is added in `csr.v` only: the read case and `wval`.** Anything new read from CSR state in EX needs a post-write export or a refetch — this EX-consumes/WB-commits family has produced six bugs (misa.C, mstatus MPP, MPRV, mie, the counter aliases, PMP).

**Redirects only on a non-stalled cycle.** Every `next_pc` arm is gated on `!stall`. During a stall EX may be looking at forwarded load data that is not valid yet (C3), and the fetch address must not move while a fetch is outstanding.

**Memory handshake:** both ports use request/ready. A request is outstanding while `*_req` is high; its address (and for data we/be/wdata) is held until the cycle `*_ready` is seen with it. `imem_req` is high only while PC is in the executable window (no fetch from IO or unmapped addresses); `dmem_req` excludes trapping accesses and a failing SC; `dmem_be` gives byte lanes for loads as well as stores. `tb/memory_model.v` checks this every cycle and stops the run on a violation.

**Multi-cycle operations stall the pipeline:** MulDiv (33-34 cycles) and AMO (2 phases via `wb_busy`). `muldiv_have = muldiv_ready | muldiv_done` gates start, stall and capture: the result is taken on the done cycle if the pipeline can take it and held otherwise, and the unit is never restarted on its own done cycle (`2e6718b` did that, and every M instruction after the first returned the previous result). `muldiv_want` excludes a trapping instruction, or a fetch fault on an M-op word deadlocks. Interrupts are never injected while an M instruction is in EX or during any stall.

**PMP:** `pmp_ifetch` checks `ifex_pc` (X), plus the upper half of a straddling 32-bit instruction during one extra EX cycle when PMP could deny it; `pmp_data` checks `ex_alu_result` with R/W/R+W (AMO R+W), at MPP's privilege when MPRV=1. Compares are on PA[33:2] (pmpaddr holds 34-bit addresses on RV32).

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

Verification runs the core on this map (boot from PSRAM). Spike gets `-m0x20000000:0x1000000,0x80000000:0x1000000`; Spike has no read-only memory, so a store to flash is a known legal divergence. `tests/directed/run.sh soc` runs the directed suite through the whole SoC against a behavioural QSPI Pmod (`tb/qspi_pmod_model.v`): the testbench loads the test into the model's PSRAM and forces the core's `boot_addr` to 0x8000_0000, so every register is 0 on entry as in Spike, and traces from there; `flash` tests boot from the model's flash instead. MANIFEST `soc` lines rerun tests through the SoC with the model's hostile hand-over states and late sampling. Flash/PSRAM protocol details: `docs/qspi-memories.md`.

## Critical Invariants

- **Trap cause priority** must match RISC-V spec Table 3.7: ifetch access fault (1) > illegal (2) > inst addr misaligned (0) > ecall (11/8) > ebreak (3) > misaligned (4/6) > data access fault (5/7). Locate the if-else chain by the `exwb_trap_cause` assignments, not by line number. Cause 2 is tested via `ex_illegal_insn`, which `ex_trap` also consumes so the two lists cannot drift; the fallthrough arm is cause 7, and it is reachable for exactly one condition. Reordered in `11384f8`.
- **Counter CSRs** (mcycle, minstret) have merged always blocks — auto-increment and CSR write live in the same block to avoid dual-driver synthesis failures. Never split them.
- **CSRRS/CSRRC with rs1=0** must NOT write. The pipeline uses `ex_csr_writes` (not `ex_csr_active`) to gate `exwb_csrWR`.
- **mtvec is direct-mode only** — `[1:0]` forced to `2'b00` on write (WARL), in `wval`.
- **IRQ MPP save:** `priv_mode` must NOT be set to M on `irq_inject` directly — it's updated via the `csr_trap_signal` path one cycle later so the CSR unit captures the correct old privilege for MPP.
- **PMP locked entries:** TOR lock propagates downward (entry i with TOR+L locks pmpaddr[i-1]). Implemented once, in `wval`.
- **pmpcfg A=2'b10 (NA4) is LEGAL and is stored as written.** Bits [6:5] of each byte are reserved and read 0.
- **mstatus:** resets to 0 (MPP=U, matching Spike); a write of MPP=01/10 is legalised to U.
- **mip has no writable bits** on this M+U core; it reads the MSIP/MTIP/MEIP wires. MTIP is registered in the CLINT, so it lags an mtimecmp store by two instructions (a legal spurious interrupt; `mtip_stale` pins it).
- **mtvec resets to 0** (as Spike), which is unmapped on the SoC: boot code must set it before anything can trap.

## Verilog Conventions

- All source is Verilog-2001 (`iverilog` compatible, no SystemVerilog).
- Forward-declared wires (e.g., `irq_inject`, `pmp_ifetch_allow`) are declared near the top of `fyracore.v` to satisfy iverilog's linear processing. If you add a new wire that's assigned later in the file but referenced earlier, declare it early.
- Pipeline registers use the naming convention `ifex_*` (IF→EX) and `exwb_*` (EX→WB).
- Controller outputs use `ctrl_*` prefix. CSR unit outputs use `csr_*` prefix.
- The `controller.v` is purely combinational — no state, no clk.
