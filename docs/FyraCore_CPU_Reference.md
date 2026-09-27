# FyraCore CPU Reference

## 1. Overview

**FyraCore** is a 3-stage pipelined RISC-V processor implementing the **RV32IMAC** ISA plus the **Zicsr**, **Zicntr** and **Zifencei** standard extensions. It supports **M-mode** (Machine) and **U-mode** (User) privilege levels with Physical Memory Protection (PMP). The core is designed for area-constrained fabrication on **Skywater 130nm** (sky130, TinyTapeout) and targets booting NOMMU M-mode Linux.

| Property | Value |
|---|---|
| ISA | RV32IMAC + Zicsr + Zicntr + Zifencei |
| Pipeline | 3 stages: IF / EX / WB |
| Privilege Modes | M (Machine) + U (User) |
| Memory Protection | PMP, 4 entries (OFF / TOR / NA4 / NAPOT), plus a fixed PMA map |
| Interrupts | Timer, Software (CLINT), External (one input pin) |
| Memory interface | Separate fetch and data ports, request/ready handshake |
| Primary Goal | Boot NOMMU Linux with area as #1 priority |

---

## 2. Architecture

### 2.1 Pipeline Stages

```
  IF                        EX                          WB
  +-----------+             +------------------+        +-----------------+
  | Fetch     |  ifex_*     | Decode           |  exwb_*| Memory Access   |
  | C-Decomp  | ---------> | Regfile Read     | -----> | Writeback       |
  | PC Update |             | ALU / MulDiv     |        | CSR Commit      |
  +-----------+             | Branch Resolve   |        | Trap Entry      |
                            | PMA + PMP Check  |        | AMO Phase 2     |
                            | Trap Detection   |        | LR/SC reservation|
                            +------------------+        +-----------------+
```

**IF (Instruction Fetch):**
- Requests the instruction at `imem_addr` (= PC) whenever PC is in the executable window (`imem_req`); outside it nothing is fetched and the instruction faults in EX
- The PC only changes on a cycle the fetch completes, so the address of an outstanding fetch is never withdrawn
- Detects compressed instructions (bits `[1:0] != 2'b11`) and expands them via `compressed_decoder`
- Computes `if_pc_next = pc + 2` (compressed) or `pc + 4` (normal)

**EX (Execute):**
- Decodes instruction fields (`decoder`) and control signals (`controller`)
- Reads the register file with WB->EX forwarding
- Executes the ALU operation or runs the multi-cycle multiply/divide unit
- Evaluates branches
- Checks the fetch (both halves of a straddling 32-bit instruction) and the data address against the PMA map and PMP
- Detects all synchronous traps and injects interrupts
- Computes the CSR read-modify-write value

**WB (Writeback):**
- Performs the data memory access (a load, a store, or the two phases of an AMO)
- Writes back the register file
- Commits CSR writes and traps (mepc, mcause, mtval, mstatus)
- Sets and clears the LR/SC reservation

### 2.2 Hazard Handling

| Hazard | Resolution |
|---|---|
| Data dependency (RAW) | WB -> EX forwarding via `fwd_rs1`/`fwd_rs2` |
| Load-use | Stall until the load's data returns |
| Branch/Jump | 1-cycle flush penalty |
| Multi-cycle MulDiv | Stall until the result is available (`muldiv_done`, or the sticky `muldiv_ready`) |
| AMO | 2-phase WB (read phase holds `wb_busy`, write phase) |
| Memory not ready | Stall while `imem_ready` is low, or while a data request is outstanding |
| WFI | Stall until an enabled interrupt is pending; NOP if no source is enabled in `mie` |
| Straddling fetch with PMP live | One extra EX cycle to PMP-check the upper half (`ex_ifetch_hi_phase`) |
| PMP CSR write | The next instruction is refetched, like FENCE.I |

```
stall_other  = load_use_hazard || wb_busy || if_mem_stall || wb_mem_stall || wfi_active
               || ex_ifetch_hi_phase
wb_mem_stall = dmem_req && !dmem_ready
muldiv_want  = ifex_valid && ctrl_isMulDiv && !ex_trap
muldiv_have  = muldiv_ready || muldiv_done
muldiv_stall = muldiv_want && !muldiv_have
stall        = stall_other || muldiv_stall
flush        = ex_branch_taken || ex_is_mret || ex_trap || ex_is_fencei || ex_pmp_csr_wr
               || irq_inject
```

Every PC redirect (trap, interrupt, MRET, branch, FENCE.I / PMP refetch) is taken only on a `!stall` cycle. A trap detected while EX is stalled is ignored until the stall ends, because EX can briefly see not-yet-valid forwarded load data during a load-use or AMO-read stall.

### 2.3 CSR Values Seen by EX

CSR writes commit in WB, one stage behind EX. Zicsr requires a write's effects to be visible to the very next instruction, so `csr.v` exposes post-write state:

- **`wval_out` (`csr_wval`)**: the value the CSR at `waddr` reads back once the pending write commits. Every WARL rule lives here and only here: MPP legalisation, the misa.C refusal, mie/mcounteren/mcountinhibit masks, mtvec direct mode, the mepc IALIGN read mask, mip's live bits, per-byte pmpcfg locks, TOR/L locks on pmpaddr, read-zero CSRs. The register update stores this value.
- **CSR read forwarding**: an EX read of the CSR being written in WB (or of its U-mode counter alias: `cycle`/`instret`/`cycleh`/`instreth`) gets `csr_wval`.
- **Post-write exports**: `mstatus_mie`, `mstatus_mpp`, `mstatus_mprv`, `mstatus_tw`, `mie_out` and `misa_c` all reflect a pending WB write, because their consumers (interrupt gating, the MRET privilege restore, the data PMP check, the U-mode WFI check, compressed decode and branch-target alignment) sit in EX.
- **PMP registers are not forwarded.** A write to `pmpcfg0` or `pmpaddr0-3` refetches the next instruction instead (`ex_pmp_csr_wr`), so it reaches EX after the write has committed. This costs one cycle per PMP write instead of a 160-bit forwarding mux.

### 2.4 Trap Target / MRET Target Forwarding

```verilog
wire [31:0] trap_target = mtvec_fwd ? csr_wval : csr_mtvec;
wire [31:0] mret_target = mepc_fwd  ? csr_wval : csr_mepc;
```

`csrw mepc, t0; mret` returns to the new mepc; `csrw mtvec, t0` followed by a trapping instruction vectors to the new mtvec.

---

## 3. Module Inventory

### 3.1 Source Files (`src/`)

| File | Module | Description |
|---|---|---|
| `fyracore.v` | `fyracore` | Top-level 3-stage pipeline (~1280 lines). Instantiates the modules from `alu` to `pmp` below. |
| `alu.v` | `alu` | RV32I ALU (ADD, SUB, SLL, SRL, SRA, SLT, SLTU, XOR, OR, AND). |
| `muldiv.v` | `muldiv` | Iterative multiply/divide unit: shift-add multiplier (33-34 cycles), restoring divider (34 cycles). |
| `controller.v` | `controller` | Combinational decode of opcode/funct3/funct7 into control signals. Rejects illegal LOAD/STORE/JALR encodings without requesting side effects; the pipeline completes the rs2/rd/rs1 checks for SYSTEM and LR. |
| `decoder.v` | `decoder` | Instruction field extractor: opcode, rd, rs1, rs2, funct3, funct7. |
| `signExt.v` | `signExt` | Immediate generation for all formats. |
| `branchCtrl.v` | `branchCtrl` | Branch condition evaluator. |
| `regFile.v` | `regFile` | 32x32-bit register file, x0 hardwired to zero. |
| `compressed_decoder.v` | `compressed_decoder` | RV32C expansion. Its legal/illegal verdict matches the RV32IMAC rules on all 49,152 16-bit encodings. |
| `csr.v` | `csr` | M-mode CSR file: trap entry, MRET, counters, PMP registers, interrupt enable/pending, and the post-write value `wval` (section 2.3). |
| `pmp.v` | `pmp` | PMP checker, 4 entries, OFF/TOR/NA4/NAPOT, compared in the 34-bit physical address space. Two instances: fetch (X) and data (R/W/RW). |
| `clint.v` | `clint` | SiFive-compatible CLINT: mtime, mtimecmp, msip. Instantiated by the SoC top (or the memory model in simulation), not by the core. |
| `alphaone_soc.v` | `alphaone_soc` | SoC top: core, bus fabric, memory controller, QSPI engine, CLINT. Boots from flash (0x2000_0000). |
| `soc_bus.v` | `soc_bus` | Bus fabric: the core's own request/ready fanned out by a stateless address decode, with a read-data/ready mux. No registers. |
| `mem_ctrl.v` | `mem_ctrl` | Joins the fetch and data ports onto the QSPI engine: data-first arbitration, chip select from the address, PSRAM fetch split at 1 KB pages. |
| `qspi_ctrl.v` | `qspi_ctrl` | QSPI engine for the TinyTapeout QSPI Pmod: PSRAMs in QPI mode (0x0B read, 0x38 write), flash unchanged (0xEB quad I/O read, command on IO0; never written), SCK = clk/2, late read sampling with an `rd_late` strap, a start-up sequence that resets the Pmod's devices. |
| `regs.v` | `regs` | Generic register module. Not instantiated. |

### 3.2 Testbench Files (`tb/`)

| File | Description |
|---|---|
| `tb_rivercore.v` | Lockstep testbench for the verification flow. Emits a Spike-format commit log; CSR values are printed from `cpu.csr_wval`. Watchdogs: `+MAX_INSTR`, `+MAX_CYCLES`, spin detection. |
| `tb_cpu.v` | Older integration testbench used by `make asm` / `scripts/run_asm_test.sh`. |
| `memory_model.v` | 16 MB of PSRAM at 0x8000_0000, the flash window reading zeros, CLINT and a testbench-only MEIP hook. Wait states (`+IMEM_WAIT`, `+DMEM_WAIT`, `*_RANDOM`, `+MEM_SEED`), what read data carries while not ready (`+NOTREADY_DATA` = X / zeros / garbage), and a handshake checker that stops the run if the core withdraws or changes an outstanding request. |
| `qspi_pmod_model.v` | Behavioural QSPI Pmod (flash on CS0, PSRAMs on CS1/CS2). Stops the run on any command `qspi_ctrl` should not send, a flash mode byte with M5-4 = 10, PSRAM traffic before its 66h/99h reset, bus contention, or a tCEM/tCPH violation. Takes the raw pins with their output enable and models released ones (chip selects pulled up, SCK floating), so a chip select falling before SCK is driven low fails. `+QSPI_DELAY` device delay. |
| `req_hold_check.v` | Hold-until-done checker for a request handshake. The SoC build (`-DSOC_TB`) checks the core's two ports, the data port at `mem_ctrl` and `mem_ctrl`'s requests to `qspi_ctrl`; `tb_qspi*` check the last. |
| `tb_qspi.v` | `mem_ctrl` + `qspi_ctrl` against the Pmod model, including a store aimed at flash that must select no chip; `tb_qspi_stress.v` drives core-shaped request streams (`make test-qspi`). |
| `tb_alu.v` … `tb_signExt.v` | Component unit testbenches (`make test-components`). A FAIL line fails the make target. |

### 3.3 Test Programs

- `tests/*.S`: legacy self-checking programs for `make asm`, linked and booted at 0x8000_0000.
- `tests/directed/`: the directed regression suite, run against Spike with full-trace comparison. See section 11.

---

## 4. Memory Map

```
Address Range               Device      Size    Attributes
-----------------------------------------------------------------
0x2000_0000 - 0x20FF_FFFF   Flash       16 MB   read, execute (QSPI CS0)
0x8000_0000 - 0x80FF_FFFF   PSRAM       16 MB   read, write, execute, LR/SC (QSPI CS1 / CS2)
0x0200_0000 - 0x0200_FFFF   CLINT       64 KB   data only
0x0C00_0000                 PLIC        -       reserved, not implemented (faults)
0x1000_0000 - 0x1000_FFFF   UART        64 KB   data only, reserved (reads 0)
0x1001_0000 - 0x1001_FFFF   GPIO        64 KB   data only, reserved (reads 0)
0x1002_0000 - 0x1002_FFFF   syscon      64 KB   data only, reserved (reads 0)
```

The core only knows the map through the PMA parameters: `PMA_ROM_*` (fetch and plain loads; a store, AMO or SC is a store access fault and an LR a load access fault), `PMA_RAM_*` (everything; the only window LR/SC may use), `PMA_IO0_*` and `PMA_IO1_*` (data only). Any other address raises an access fault (cause 1/5/7). PSRAM A and B are two 8 MB chips used contiguously; `addr[23]` picks the chip. The reset PC is the `boot_addr` input (section 10); the SoC ties it to 0x2000_0000, so it always boots from flash. SoC design, boot and QSPI details: `docs/soc-architecture.md`.

The verification testbench uses these windows for flash and PSRAM and boots from PSRAM. It still overrides the CLINT window to Spike's 0xC0000 aperture (0x0200_0000-0x020B_FFFF) and switches IO1 off, because Spike has no device there.

### CLINT Register Map (offsets from 0x0200_0000)

| Offset | Register | Description |
|---|---|---|
| 0x0000 | msip | Bit 0 = software interrupt pending |
| 0x4000 | mtimecmp_lo | Low 32 bits of mtimecmp (resets to all ones) |
| 0x4004 | mtimecmp_hi | High 32 bits of mtimecmp |
| 0xBFF8 | mtime_lo | Low 32 bits of mtime (increments every clock) |
| 0xBFFC | mtime_hi | High 32 bits of mtime |

- `timer_irq` = `mtime >= mtimecmp`, registered (one cycle late), so the 64-bit compare is not in front of the core's interrupt and next-PC logic; `sw_irq` = `msip[0]`
- mtimecmp resets to all ones so no timer interrupt is pending out of reset (Spike resets it to 0).
- mtime ticks at the core clock, with no prescaler: the device tree's `timebase-frequency` is the core clock.

---

## 5. Memory Interface

### 5.1 Handshake

Both ports follow the same contract:

- A request is outstanding on every cycle `*_req` is high.
- From the cycle a request is raised until the cycle `*_ready` is seen high with it, the core holds its address (and for data `we`, `be`, `wdata`) stable. That ready cycle completes the transfer; read data is taken on it.
- Nothing transfers while `*_req` is low, whatever `*_ready` is.

`imem_req` is high whenever PC lies in `PMA_ROM_*` or `PMA_RAM_*`. Outside it no fetch is requested (an IO read can have side effects, and an unmapped address would never answer); the fetched bits are forced to 0 and the instruction faults in EX with cause 1. When the pipeline is stalled with a fetch already completed, the same address is requested again.

`dmem_req` is high for a valid, non-trapping load, store or AMO in WB, except a failing SC, which retires without a transaction. `dmem_be` gives the byte lanes of every request, loads included; `dmem_we` says whether it is a write. An AMO is a read followed by a write, back to back.

For a memory controller: while a data request waits, the pipeline is stalled and `imem_req` stays up with the same address, so a controller sharing one bus must not starve the data port (serve data first or alternate) and should keep the last fetched word so a repeated request completes without a new transfer. A 32-bit fetch at the last halfword of a window asks for bytes past its end; anything may be returned for them. `imem_addr` is the halfword-aligned PC and the four bytes from it are wanted (`imem_rdata[7:0]` is the byte at `imem_addr`). Store data is replicated across the lanes (`{4{byte}}`, `{2{half}}`), so the first enabled byte of any store is also in `dmem_wdata[7:0]`.

### 5.2 Memory controller and QSPI engine

`src/mem_ctrl.v` serves both ports from one QSPI engine (`src/qspi_ctrl.v`): data first; a fetch reads 4 bytes from the halfword PC; a load reads the whole aligned word; a store sends only its enabled bytes; a PSRAM fetch that crosses a 1 KB page (which includes PSRAM A into B at 0x807F_FFFE) is split into two 2-byte reads, because PSRAM parts without row-boundary crossing wrap within the page. `qspi_ctrl` resets the Pmod's devices before its first request and puts the PSRAMs in QPI mode (a 4-byte PSRAM read is 20 SCK cycles, a flash read 28), never selects the flash for a write, and has a read-latency strap (`rd_late`). It does not keep the last fetched word, so a pipeline stalled with a fetch outstanding (M ops, WFI) refetches. See `docs/soc-architecture.md`.

---

## 6. Privilege and Protection

### 6.1 Privilege Modes

- **Reset**: M-mode, `mstatus` = 0 (MIE=0, MPRV=0, MPP=U).
- **Trap entry**: always to M-mode (no delegation). `priv_mode` is set on the WB trap commit (`csr_trap_signal`), so MPP captures the old privilege.
- **MRET** (`ex_mret_commit = ex_is_mret && !stall && !ex_trap && !irq_inject`): MIE <- MPIE, MPIE <- 1, privilege <- MPP, MPP <- U, and MPRV <- 0 when returning below M. MRET in U-mode is illegal.
- **An interrupt pending at an MRET is taken instead of it**, as for any instruction: mepc = the MRET's PC.

### 6.2 CSR Access Control

CSR address bits `[9:8]` encode the minimum privilege; bits `[11:10] = 11` mark read-only CSRs, whose write attempts are illegal. U-mode reads of `cycle`/`time`/`instret` (and high halves) are gated by `mcounteren` CY/TM/IR.

### 6.3 Physical Memory Protection (PMP)

4 entries via `pmpcfg0` (0x3A0) and `pmpaddr0-3` (0x3B0-0x3B3).

**Config byte** (per entry, packed in pmpcfg0):
```
Bit  [7]    L  — Lock (applies to M-mode too; entry immutable until reset)
Bits [6:5]  reserved, read 0
Bits [4:3]  A  — 00 OFF, 01 TOR, 10 NA4, 11 NAPOT (all legal at G=0)
Bits [2:0]  R/W/X — R=0,W=1 is reserved and is written as W=0 (WARL)
```

**Matching:**
- On RV32, pmpaddr holds PA[33:2]. All compares are on word addresses `{2'b00, addr[31:2]}` against the full 32-bit pmpaddr, so region bounds above 4 GB behave correctly.
- TOR: `pmpaddr[i-1] <= waddr < pmpaddr[i]` (entry 0 lower bound 0). NA4: `waddr == pmpaddr`. NAPOT: `((waddr ^ pa) & ~(pa ^ (pa+1))) == 0`, so only the bits above the trailing ones and their terminating zero are compared; pmpaddr = all ones covers everything.
- Entry 0 has highest priority. No match: M allowed, U denied. L=1 applies the permissions to M-mode too. Entry i with TOR+L also locks pmpaddr[i-1].
- Reset: all entries OFF (Spike resets permissive; see the riscv-dv notes).

**Checks in the pipeline:**
- `pmp_ifetch` (X) checks `ifex_pc`. For a 32-bit instruction at an address with bit 1 set, the upper half at `{ifex_pc_next[31:2], 2'b00}` is checked too: by a dedicated PMA compare, and by the same PMP checker during one extra EX cycle (`ex_ifetch_hi_phase`) whenever PMP could deny it (U-mode, or any entry locked). A fault in only the upper half reports that half's address in mtval.
- `pmp_data` checks `ex_alu_result` with R (load, LR), W (store, SC) or R+W (AMO). With `mstatus.MPRV = 1`, the privilege checked is MPP.

---

## 7. CSR Register Set

### 7.1 Machine Information (Read-Only)

| Address | Name | Value |
|---|---|---|
| 0xF11 | mvendorid | 0 |
| 0xF12 | marchid | parameter `MARCHID`, default 0 (the testbench sets 5 to match Spike) |
| 0xF13 | mimpid | 0 |
| 0xF14 | mhartid | 0 |
| 0xF15 | mconfigptr | 0 |

### 7.2 Machine ISA

| Address | Name | Value | Writable |
|---|---|---|---|
| 0x301 | misa | 0x4010_1105 (RV32 I M A C U) | C only. Clearing C is refused when the next PC would be misaligned. |

### 7.3 Machine Trap Setup

| Address | Name | Writable Bits | Notes |
|---|---|---|---|
| 0x300 | mstatus | MIE[3], MPIE[7], MPP[12:11], MPRV[17], TW[21] | MPP is legalised to U unless written 11. Resets to 0. |
| 0x310 | mstatush | none | Reads 0 (little-endian only) |
| 0x304 | mie | MSIE[3], MTIE[7], MEIE[11] | |
| 0x305 | mtvec | [31:2] | Direct mode only |
| 0x306 | mcounteren | CY[0], TM[1], IR[2] | |
| 0x30A / 0x31A | menvcfg / menvcfgh | none | Read 0 (FIOM read-only zero without S-mode) |
| 0x320 | mcountinhibit | CY[0], IR[2] | TM reads 0 |
| 0x323-0x33F | mhpmevent3-31 | none | Read 0 |

### 7.4 Machine Trap Handling

| Address | Name | Description |
|---|---|---|
| 0x340 | mscratch | Scratch |
| 0x341 | mepc | Bit 0 always 0; bit 1 stored but reads 0 while misa.C = 0 |
| 0x342 | mcause | Trap cause (bit 31 = interrupt) |
| 0x343 | mtval | Faulting address, faulting instruction encoding, or 0 |
| 0x344 | mip | MSIP[3], MTIP[7], MEIP[11] are the live interrupt wires; nothing is writable |

### 7.5 Counters

| Address | Name | Description |
|---|---|---|
| 0xB00 / 0xB80 | mcycle / mcycleh | Cycle counter |
| 0xB02 / 0xB82 | minstret / minstreth | Retired-instruction counter |
| 0xB03-0xB1F, 0xB83-0xB9F | mhpmcounter3-31(h) | Read 0 |

Counter auto-increment and CSR writes share one `always` block per counter (never split them). A write replaces the written half and keeps a carry from this cycle's increment into the other half.

### 7.6 User Counter Aliases

| Address | Name | Gate |
|---|---|---|
| 0xC00 / 0xC80 | cycle / cycleh | mcounteren[0] |
| 0xC01 / 0xC81 | time / timeh | mcounteren[1] (reads CLINT mtime) |
| 0xC02 / 0xC82 | instret / instreth | mcounteren[2] |

`hpmcounter3-31` are not implemented (no Zihpm) and trap.

### 7.7 PMP CSRs

| Address | Name | Description |
|---|---|---|
| 0x3A0 | pmpcfg0 | 4 config bytes, each locked by its own L bit |
| 0x3B0-0x3B3 | pmpaddr0-3 | Locked by own L bit or entry i+1's TOR lock |
| 0x3A1-0x3A3 | pmpcfg1-3 | Read 0, writes ignored |
| 0x3B4-0x3BF | pmpaddr4-15 | Read 0, writes ignored |

### 7.8 CSR Write Value Computation

EX computes the read-modify-write value into `exwb_csr_wdata`, and `csr.v` always receives op=CSRRW:
```
CSRRW/CSRRWI: wdata
CSRRS/CSRRSI: csr_rdata_eff |  wdata
CSRRC/CSRRCI: csr_rdata_eff & ~wdata
```
CSRRS/CSRRC with rs1=x0 (and the immediate forms with uimm=0) do not write (`ex_csr_writes = 0`).

---

## 8. Trap and Interrupt Handling

### 8.1 Synchronous Trap Priority

| Priority | Condition | Cause | mtval |
|---|---|---|---|
| 1 | Instruction access fault (PMA or PMP, either half) | 1 | Address of the faulting portion |
| 2 | Illegal instruction | 2 | Instruction encoding (16-bit for compressed) |
| 3 | Instruction address misaligned (branch/jump target with misa.C = 0) | 0 | Target |
| 4 | ECALL | 11 (M) / 8 (U) | 0 |
| 5 | EBREAK | 3 | PC |
| 6 | Load / store-AMO address misaligned | 4 / 6 | Address |
| 7 | Load / store-AMO access fault (PMA or PMP) | 5 / 7 | Address |

LR/SC to an IO window is an access fault (no reservation set there); an AMO to an IO window is allowed.

### 8.2 Illegal Instruction Sources (`ex_illegal_insn`)

- `ctrl_illegal` (unknown opcode/funct fields; FENCE excepted)
- `ifex_c_illegal`: a reserved compressed encoding
- a compressed instruction while misa.C = 0 (checked in EX against the post-write misa.C)
- `ex_bad_system`: ECALL/EBREAK/MRET with wrong fields, or MRET in U-mode
- `ex_bad_wfi`: anything in the funct7=0001000 family except a well-formed WFI (includes SRET)
- `ex_wfi_umode`: WFI in U-mode with mstatus.TW = 1
- `ex_bad_lr`: LR.W with rs2 != 0
- `ex_csr_illegal`: nonexistent CSR, write to a read-only CSR, or insufficient privilege

### 8.3 Trap Entry (`csr_trap_signal`, WB)

1. `mepc <= trap_pc`, `mcause <= trap_cause`, `mtval <= trap_val`
2. `MPIE <= MIE`, `MIE <= 0`, `MPP <= current privilege`
3. `priv_mode <= M`
4. The LR/SC reservation is cleared
5. The redirect to `trap_target` was already taken when the trap left EX

### 8.4 Interrupts

- Sources: MEIP (cause 11) > MSIP (3) > MTIP (7).
- Enable: `irq_global_en = !priv_mode || mstatus.MIE`, with per-source `mie` bits. Both are the post-write values, so the instruction after `csrc mstatus, 8` or `csrc mie, …` is already masked, and the one after `csrs mie, …` is already interruptible.
- Injection: `irq_inject = any_irq_pend && ifex_valid && !ex_trap && !muldiv_want && !stall_other`. It is never taken during a stall or while any M instruction is in EX, and a synchronous trap wins.
- Entry: the EX instruction's side effects are suppressed and its PC becomes mepc, so it re-executes after MRET.

### 8.5 WFI

- M-mode (or U-mode with TW = 0): WFI retires and sets `wfi_active`, stalling the next instruction until an individually enabled interrupt is pending (regardless of MIE). If no source is enabled in `mie`, WFI is a NOP. On wake, a taken interrupt's mepc is the instruction after the WFI.
- U-mode with TW = 1: illegal instruction.

---

## 9. Instruction Set Support

### 9.1 RV32I

All base instructions. FENCE is a NOP (in-order core, blocking memory). FENCE fields and FENCE.TSO/PAUSE encodings execute as FENCE.

### 9.2 M Extension

| Op | Instruction | Cycles |
|---|---|---|
| MUL, MULH, MULHSU, MULHU | multiply | 33-34 |
| DIV, DIVU, REM, REMU | divide | 34 |

Division by zero and signed overflow follow the spec. Handshake: `start` for one cycle, `busy` while computing, `done` for one cycle as `busy` drops. The pipeline takes the result on the done cycle if it can, otherwise it holds it in `muldiv_ready` until it can. It never restarts on the done cycle.

### 9.3 A Extension

AMOs (SWAP, ADD, XOR, AND, OR, MIN, MAX, MINU, MAXU): phase 0 reads (`wb_busy`), phase 1 computes and writes; rd gets the old value.

**LR/SC reservation policy:**

| Event | Effect |
|---|---|
| LR.W retires in WB | reservation set; the reservation set is the aligned word (`reservation_addr` = addr[31:2]) |
| SC.W retires (success or failure) | cleared |
| A local store or AMO retires, even to the reserved word | **no effect** |
| A trap or interrupt commits in WB | cleared |
| Reset | cleared |

- SC succeeds iff the reservation is valid and the word matches; rd = 0 on success, 1 on failure. A failing SC issues no bus transaction.
- LR/SC outside `PMA_RAM_*` (PSRAM) fault (cause 5/7). Misaligned LR/SC trap (cause 4/6).
- There is no external-agent clear: one hart, no DMA, no debug system-bus access. Add one if any of those appear.
- The spec's must-fail list covers stores by other harts and writes by other devices; what a hart's own store does is left to the implementation. Keeping the reservation across it is what Spike does, so the lockstep comparison stays aligned past the SC (clearing it made every unconstrained LR..store..SC sequence in the random suites diverge there). Forward progress is unaffected: a constrained LR/SC loop contains no loads, stores, AMOs or SYSTEM instructions.
- Traps are not required to clear the reservation either; clearing on them is permitted and kept as defence in depth.

### 9.4 C Extension

Quadrants 0-2 of RV32C. Reserved encodings (illegal): C.ADDI4SPN with nzuimm=0, C.ADDI16SP with nzimm=0, C.LUI with nzimm=0, C.LWSP with rd=x0, C.JR with rs1=x0, shift amounts with shamt[5]=1, the all-zero word, and the RV64/FPU/Zcb/Zcmop encodings. HINT encodings execute.

### 9.5 Zicsr / Zicntr

See section 7. `CSRRW` with rd=x0 still reads the CSR; no CSR here has read side effects.

An explicit write to either half of `mcycle` or `minstret` is done instead of that cycle's increment (Zicsr: "the explicit write is done instead of the update from the side effect"): the half not written keeps its current value, and writing the high half does not bump the low half. So the value written to `minstret`/`minstreth` is exactly what the next instruction reads (riscv-tests `rv32mi-instret_overflow`; Spike since 51835fd7).

### 9.6 Zifencei

FENCE.I asserts `fencei_flush` for one cycle (a fetch-buffer invalidate for a memory controller) and refetches the next instruction.

---

## 10. Top-Level Interface

```verilog
module fyracore #(
    parameter [31:0] MARCHID      = 32'h0000_0000,
    parameter [31:0] PMA_ROM_BASE = 32'h2000_0000,  // flash: fetch + plain loads
    parameter [31:0] PMA_ROM_TOP  = 32'h20FF_FFFF,
    parameter [31:0] PMA_RAM_BASE = 32'h8000_0000,  // PSRAM: everything, LR/SC
    parameter [31:0] PMA_RAM_TOP  = 32'h80FF_FFFF,
    parameter [31:0] PMA_IO0_BASE = 32'h0200_0000,  // data only (CLINT)
    parameter [31:0] PMA_IO0_TOP  = 32'h0200_FFFF,
    parameter [31:0] PMA_IO1_BASE = 32'h1000_0000,  // data only (UART, GPIO, syscon)
    parameter [31:0] PMA_IO1_TOP  = 32'h1002_FFFF   // BASE > TOP disables a window
)(
    input  wire        clk, rst,
    input  wire [31:0] boot_addr,      // reset PC, loaded every cycle rst is high
    // Instruction port (section 5.1)
    output wire [31:0] imem_addr,
    output wire        imem_req,
    input  wire [31:0] imem_rdata,
    input  wire        imem_ready,
    // Data port (section 5.1)
    output wire        dmem_req,
    output wire [31:0] dmem_addr,      // word-aligned
    output wire [31:0] dmem_wdata,     // shifted to byte lanes
    output wire [3:0]  dmem_be,        // byte lanes, loads included
    output wire        dmem_we,
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_ready,
    // Interrupts
    input  wire        timer_irq,      // MTIP
    input  wire        external_irq,   // MEIP
    input  wire        sw_irq,         // MSIP
    input  wire [63:0] mtime_in,       // for time/timeh
    output wire        fencei_flush,
    // Trace
    output wire [31:0] dbg_pc,
    output wire        dbg_retired,
    output wire [31:0] dbg_instr,
    output wire        dbg_compressed,
    output wire        dbg_trap
);
```

---

## 11. Build and Test

```bash
make clean && make test-all          # unit testbenches (fail on any FAIL line) + CPU compile
make asm FILE=tests/<test>.S         # legacy self-checking programs

cd tests/directed
./run.sh build                       # build the lockstep sim from ../../src and ../../tb
./run.sh                             # every test in MANIFEST, full-trace compare with Spike
./run.sh one <name> [+PLUSARGS]      # a single test
./run.sh refs                        # regenerate the Spike references
./run.sh soc                         # the same suite through the whole SoC (QSPI path)
```

Memory-timing plusargs for the lockstep sim: `+IMEM_WAIT=n +DMEM_WAIT=n +IMEM_RANDOM=1 +DMEM_RANDOM=1 +MEM_SEED=n +NOTREADY_DATA=0|1|2`. Different settings expose different bugs; sweep them independently.

---

## 12. Design Decisions and Rationale

### 12.1 Why 3 Stages?
Area is the primary constraint. IF/EX/WB keeps pipeline registers minimal while most instructions still take one cycle; the QSPI memory bottleneck dominates throughput anyway.

### 12.2 Why Iterative MulDiv?
The combinational operators cost more than 10k gates. The iterative unit costs about 1k, for 33-34 cycles per operation.

### 12.3 Why Direct-Mode mtvec?
Vectored mode adds logic for no benefit on an M+U system; Linux uses direct mode.

### 12.4 Why 4 PMP Entries?
Enough for M/U isolation (Linux M-mode programs one NAPOT entry covering everything). More entries cost area linearly.

### 12.5 Why a Post-Write Value in csr.v?
The WARL rules used to exist in four places (csr.v, the EX forward, the trap/MRET target masks, the testbench trace), and each copy that drifted produced a defect. `wval` is the single copy; forwarding, the targets and the trace all use it.

### 12.6 Why Refetch After a PMP Write?
Forwarding pending PMP state into both checkers would need a 160-bit mux. PMP writes are rare, so a one-cycle refetch is the cheaper way to make the next instruction see them.

### 12.7 Why Check a Straddling Instruction's Upper Half With the Same PMP Checker?
A second fetch PMP checker would double the comparator area. The extra EX cycle is only spent when PMP can actually deny a fetch (U-mode, or a locked entry), so an M-mode kernel never pays it.

### 12.8 Why Pre-Compute CSR Values in EX?
EX computes the read-modify-write value, so the CSR unit only ever writes and the forwarded value is a single word.

### 12.9 IRQ MPP Save
`priv_mode` is set to M on the WB trap commit, never directly on `irq_inject`, so the CSR unit saves the pre-interrupt privilege into MPP.

---

## 13. Known Limitations

1. No S-mode or MMU; Linux must be NOMMU M-mode.
2. No interrupt delegation; all traps go to M-mode.
3. Direct-mode mtvec only.
4. `CSRRW` with rd=x0 still reads the CSR (harmless: no read side effects).
5. 4 PMP entries.
6. MulDiv has no early termination.
7. FENCE is a NOP.
8. Single hart; no external reservation-clear path.
9. No debug module and no trigger CSRs (Sdtrig); `tselect` traps.
10. No Zihpm: `hpmcounter3-31` trap; `mhpmcounter3-31`/`mhpmevent3-31` read 0.
11. mtime ticks every clock (no prescaler); MTIP is registered, one cycle behind the compare.
12. One external interrupt input and no PLIC.
13. The memory controller keeps no fetch buffer: a stall with a fetch outstanding refetches, and every access costs a full QSPI transaction (about 60 clocks).
