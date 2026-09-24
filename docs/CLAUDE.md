# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FyraCore is a 3-stage pipelined RV32IMAC+Zicsr+Zifencei RISC-V processor targeting Skywater 180nm fabrication. It supports M-mode and U-mode privilege levels with PMP. The goal is to boot no-MMU Linux (uClinux). Area is the #1 priority, speed is #2.

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

# Clean build artifacts
make clean
```

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

The pipeline top-level is `src/fyracore.v` (~1100 lines). It instantiates all other modules.

### Key Architectural Patterns

**CSR write pre-computation:** EX computes the full read-modify-write CSR value and stores it in `exwb_csr_wdata`. The CSR unit always receives `op=CSRRW` — it never does CSRRS/CSRRC itself. This simplifies the write path and forwarding.

**CSR forwarding with WARL masks:** When WB writes a CSR that EX reads in the same cycle, forwarding applies the same bit masks as `csr.v` (mstatus masked with `0x221888` since MPRV and TW exist, mtvec `[1:0]` forced to `00`, mepc bit 1 masked when misa.C=0, pmpcfg0 per-byte lock, plus mie/mcounteren/mcountinhibit/mip). Any new writable CSR needs a forwarding entry in `csr_fwd_data` in `fyracore.v` — four CSRs were missing one and silently returned raw write data (`7babc48`).

**The same hazard applies to mstatus fields read outside `csr.v`.** MPRV and MPP are consumed by the data PMP check in EX, but a `csrw mstatus` does not commit until WB, so they need the same forward (`7cd1eb6`). This EX-consumes/WB-commits family has bitten three times; `misa.C` is still open. A test only catches it if the write and the dependent access are adjacent.

**Trap/MRET target forwarding:** `trap_target` and `mret_target` forward from WB CSR writes to avoid stale redirect targets. Both apply WARL masks.

**mstatus MIE forwarding for interrupt gating:** `mstatus_mie_eff` forwards MIE from WB to prevent a 1-cycle interrupt window after `csrci mstatus,8`.

**Multi-cycle operations stall the pipeline:** MulDiv (33-34 cycles) and AMO (2 cycles via `wb_busy`) hold the stall signal. Interrupts are never injected mid-multicycle — `irq_inject` excludes `muldiv_want` and `stall_other`. MulDiv completion is **sticky** (`muldiv_ready`), not a one-cycle pulse: the pulse version livelocked forever at every `IMEM_WAIT >= 2` because the result was dropped whenever the done cycle coincided with a fetch stall (`2e6718b`).

**Dual PMP instances:** `pmp_ifetch` checks ifex_pc with X permission; `pmp_data` checks ex_alu_result with R/W/R+W. AMO uses access_type `3'b011` (R+W).

### Memory Map (unified Von Neumann)

```
0x0000_0000 – 0x00FF_FFFF : Flash (16 MB, QSPI CS0)
0x0100_0000 – 0x01FF_FFFF : RAM   (16 MB, QSPI CS1)
0x0200_0000 – 0x0200_BFFF : CLINT
0x0300_0000 – 0x0300_000F : GPIO
```

Both instruction fetch and data access can target any address. The `memController` has two modes: `SIM_MODE=1` (flat 32MB array, always-ready) and `SIM_MODE=0` (QSPI FSM with address-tagged ifetch buffer). In simulation, CLINT lives in `tb/memory_model.v`; in hardware, it's inside `memController.v`.

## Critical Invariants

- **Trap cause priority** must match RISC-V spec Table 3.7: ifetch access fault (1) > illegal (2) > inst addr misaligned (0) > ecall (11/8) > ebreak (3) > misaligned (4/6) > data access fault (5/7). Locate the if-else chain by the `exwb_trap_cause` assignments, not by line number. Cause 2 is tested via `ex_illegal_insn`, which `ex_trap` also consumes so the two lists cannot drift; the fallthrough arm is cause 7, and it is reachable for exactly one condition. Reordered in `11384f8`.
- **Counter CSRs** (mcycle, minstret) have merged always blocks — auto-increment and CSR write live in the same block to avoid dual-driver synthesis failures. Never split them.
- **CSRRS/CSRRC with rs1=0** must NOT write. The pipeline uses `ex_csr_writes` (not `ex_csr_active`) to gate `exwb_csrWR`.
- **mtvec is direct-mode only** — `[1:0]` forced to `2'b00` on write (WARL). Both the CSR write path and trap_target forwarding must apply this mask.
- **IRQ MPP save:** `priv_mode` must NOT be set to M on `irq_inject` directly — it's updated via the `csr_trap_signal` path one cycle later so the CSR unit captures the correct old privilege for MPP.
- **PMP locked entries:** TOR lock propagates downward (entry i with TOR+L locks pmpaddr[i-1]). Both `csr.v` writes and `fyracore.v` forwarding must check these conditions.
- **pmpcfg A=2'b10 (NA4) is LEGAL and is stored as written.** It used to be masked to 2'b00 (OFF) on the grounds that it was reserved; it is not. NA4 is legal at granularity G=0, `src/pmp.v` implements it, and the reference model keeps it. What *is* masked is bits [6:5] of each byte, which are reserved and must read 0. All three copies of this masking must agree: `csr.v`, `csr_fwd_data` in `fyracore.v`, and `csr_committed` in `tb/tb_rivercore.v`. Fixed in `b7c5805`.

## Verilog Conventions

- All source is Verilog-2001 (`iverilog` compatible, no SystemVerilog).
- Forward-declared wires (e.g., `irq_inject`, `pmp_ifetch_allow`) are declared near the top of `fyracore.v` to satisfy iverilog's linear processing. If you add a new wire that's assigned later in the file but referenced earlier, declare it early.
- Pipeline registers use the naming convention `ifex_*` (IF→EX) and `exwb_*` (EX→WB).
- Controller outputs use `ctrl_*` prefix. CSR unit outputs use `csr_*` prefix.
- The `controller.v` is purely combinational — no state, no clk.
