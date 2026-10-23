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
  | Fetch     |  ifex_*     | C-Decomp, Decode |  exwb_*| Memory Access   |
  |           | ---------> | Regfile Read     | -----> | Writeback       |
  | PC Update |             | ALU / MulDiv     |        | CSR Commit      |
  +-----------+             | Branch Resolve   |        | Trap Entry      |
                            | PMA + PMP Check  |        | AMO Phase 2     |
                            | Trap Detection   |        | LR/SC reservation|
                            +------------------+        +-----------------+
```

**IF (Instruction Fetch):**
- Requests the instruction at `imem_addr` (= PC) whenever PC is in the executable window and EX holds no instruction that decides the next pc (`ex_nofetch`: branch, jump, ECALL, EBREAK, MRET, FENCE.I, PMP CSR write); outside the window nothing is fetched and the instruction faults in EX
- The PC only changes on a cycle the fetch completes, so the address of an outstanding fetch is never withdrawn
- Detects compressed instructions (bits `[1:0] != 2'b11`) and expands them (`compressed_decoder`) on the way into IF/EX, which holds the 32-bit form (`ifex_instr`) and, for a compressed instruction, its own 16 bits (`ifex_raw16`, for the trace and mtval)
- Works out the numbers of the registers the fetched instruction reads (`rf_fields`, from the raw bits, compressed or not); IF/EX keeps them (`ifex_rf_rs1`/`ifex_rf_rs2`) as the register file's read addresses (section 2.2)
- Computes `if_pc_next = pc + 2` (compressed) or `pc + 4` (normal). While IF/EX holds an instruction, `pc` is that instruction's next PC (there is no `ifex_pc_next`)

**EX (Execute):**
- Decodes instruction fields (`decoder`) and control signals (`controller`)
- Reads rs1 and rs2 from the register file's two ports. The read is synchronous and the addresses are the EX instruction's own, so the data is its registers from its second cycle in EX (`ex_rf_ok`), read again on every edge. Nothing is forwarded from WB: an instruction that reads the register the WB instruction is still to write waits for the write (`use_hazard`)
- Takes at least three cycles: the register read; then the ALU and the comparator work from the operands and their results go into `alu_r` and `br_r`; from the next on (`ex_ph`) the address checks, the traps, the branch and the next PC are decided from those flops
- Executes the ALU operation, or runs the multi-cycle unit (`muldiv`: multiply, divide and the shifts)
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
| Data dependency (RAW) | No forwarding. The instruction that reads the register the WB instruction writes does not count its operands as read until the write has landed (`use_hazard`: any WB instruction with `exwb_regWR`, a load, LR and AMO included); the register file is write-first, so the cycle after the write its data includes it. After an instruction that spends one cycle in WB this costs nothing: that cycle is the reader's first in EX |
| ALU and comparator results | Registered (`alu_r`, `br_r`, free-running). An instruction waits in EX (`ex_wait`) until it has sat there for one whole cycle with its operands read and final; `ex_ph` marks the cycles on which the flops hold its own results |
| Branch/Jump, ECALL/EBREAK/MRET, FENCE.I, PMP CSR write | No fetch is requested while it is in EX (`ex_nofetch`); 1-cycle bubble, taken or not |
| Register read (synchronous, write-first `rf_top` macro) | The instruction's first cycle in EX. The read addresses are the EX instruction's register numbers as fetched (`ifex_rf_rs1`/`ifex_rf_rs2`, flops), whatever the pipeline is doing, so no stall term and no fetched bit reaches the macro's address pins. The data is the registers after the last edge's write, as a combinational read would give -- `regFile`'s one-entry bypass supplies the word written on that same edge, so the macro's own write-through is not relied on. Each read is masked to 0 where the decoded field is x0 |
| CSR write in WB | The next instruction waits one cycle in EX (`csr_wb_hazard`) |
| Multi-cycle MulDiv / shift | Stall until the result is available (`muldiv_done`, or the sticky `muldiv_ready`) |
| AMO | 2-phase WB (read phase holds `wb_busy`, write phase) |
| Memory not ready | Stall while `imem_ready` is low, or while a data request is outstanding |
| WFI | Stall until an enabled interrupt is pending; NOP if no source is enabled in `mie` |
| Fetch PMP check (U-mode or a locked entry) | One EX cycle to check `ifex_pc`, one more for a straddling instruction's upper half (`ex_ifetch_hi_phase`) |
| PMP CSR write | The next instruction is refetched, like FENCE.I |

```
use_hazard    = exwb_valid && exwb_regWR && !exwb_trap && exwb_rd != 0
                && (exwb_rd == ex_rs1 || exwb_rd == ex_rs2)
ex_rf_ok      : cleared when IF/EX loads, set after one held cycle
ex_ph         : cleared when IF/EX loads, set after a held cycle with ex_rf_ok && !use_hazard
ex_wait       = ifex_valid && !ex_ph
stall_nofetch = wb_busy || wb_mem_stall || wfi_active
                || ex_ifetch_hi_phase || csr_wb_hazard || ex_wait
                // use_hazard acts through ex_wait: it keeps ex_ph clear
stall_other   = stall_nofetch || if_mem_stall
wb_mem_stall  = dmem_req && !dmem_ready
muldiv_want   = ifex_valid && (ctrl_isMulDiv || ex_is_shift) && !ex_trap_iter
muldiv_have   = muldiv_ready || muldiv_done
muldiv_start  = muldiv_want && !muldiv_busy && !muldiv_have && !stall_nofetch && !flush
muldiv_stall  = muldiv_want && !muldiv_have
stall         = stall_other || muldiv_stall
flush        = ex_branch_taken || ex_is_mret || ex_trap || ex_is_fencei || ex_pmp_csr_wr
               || irq_inject
```

Every PC redirect (trap, interrupt, MRET, branch, FENCE.I / PMP refetch) is taken only on a `!stall` cycle. A trap detected while EX is stalled is ignored until the stall ends: during a `use_hazard` stall EX's operand is not the written value yet, and before `ex_ph` the address in `alu_r` is not the instruction's own.

`ex_rf_ok` is set at the end of the instruction's first cycle in EX, the edge on which the register file takes its addresses. `ex_ph` is set at the end of a held cycle with `ex_rf_ok` and without `use_hazard`. From that cycle on the operands cannot change: the WB stage can only take a bubble while EX is held, so no further register write can precede the instruction. `ex_trap_iter` is the part of the trap decode an M instruction or a shift can raise (a fetch fault, the controller's `illegal`, the two compressed-instruction causes); it keeps the SYSTEM and CSR checks out of `stall`.

The extra EX cycles exist for timing. In one cycle the path was operand, 32-bit add or compare, the PMP check, the trap chain, and the enables of the pipeline registers; at the slow corner that was 24.5 ns on the routed design, and forwarding added a 5-bit compare and a 32-bit mux select at its head. Reading the register file a cycle early instead (the addresses of the instruction about to enter EX) put `stall`, and with it every wait the pipeline knows, in front of the macro's address pins. All of the waits are hidden behind the next fetch (below) except on the `ex_nofetch` instructions.

An M instruction or a shift starts while the next fetch is still outstanding (`muldiv_start` ignores `if_mem_stall`), so behind a QSPI fetch (about 42 clocks) its iterations cost nothing. The other EX stall cycles (the read and compute cycles, the wait for a register write, CSR write, fetch PMP checks) are hidden the same way, except on the `ex_nofetch` instructions (branch, jump, ECALL, EBREAK, MRET, FENCE.I, PMP CSR write), which have no fetch in flight. No interrupt is injected while an M op or shift is in EX, so a run of them lengthens interrupt latency: the timer interrupt averages 433 clocks (max 550) in a loop of 31-bit shifts, against 108 in a loop of NOPs.

### 2.3 CSR Values Seen by EX

CSR writes commit in WB, one stage behind EX. Zicsr requires a write's effects to be visible to the very next instruction. Nothing is forwarded; the next instruction waits instead:

- **`csr_wb_hazard`**: while a CSR write is in WB, the instruction in EX stalls for that cycle, so every EX consumer -- a CSR read (including the U-mode counter aliases), `trap_target`/`mret_target`, interrupt gating, the MRET privilege restore, the data PMP check (MPRV/MPP), the U-mode WFI check (TW), compressed decode and branch-target alignment (misa.C) -- reads the stored value. No interrupt is injected during it.
- **Legal values**: each writable register stores its `*_legal` wire (`mie_legal`, `mtvec_legal`, `pmpcfg0_legal`, `pmpaddr0_legal`, ...; mstatus and misa store `mstatus_after_we` / `misa_after_we`). Every WARL rule lives there and only there: MPP legalisation, the misa.C refusal, mie/mcounteren/mcountinhibit masks, mtvec direct mode, per-byte pmpcfg locks, TOR/L locks on pmpaddr. Bits no write can set are constant, so they have no flops.
- **`wval_out` (`csr_wval`)**: the value the CSR at `waddr` reads back once the pending write commits (the same wires, plus the mepc IALIGN read mask, mip's live bits and read-zero CSRs). Only the testbench trace uses it; synthesis removes it.
- **mcycle**: the stall cycle would make an `rdcycle` right after `csrw mcycle` (or `mcycleh`) read the written value + 1. `mcycle_wr_q` skips the increment on the cycle after an mcycle write, so it reads the written value, as Spike does.
- **PMP registers** additionally refetch the next instruction after a write to `pmpcfg0` or `pmpaddr0-3` (`ex_pmp_csr_wr`), so its fetch is checked against the new values.

### 2.4 Trap Target / MRET Target

```verilog
wire [31:0] trap_target = csr_mtvec;
wire [31:0] mret_target = csr_mepc;
```

`csrw mepc, t0; mret` returns to the new mepc, and `csrw mtvec, t0` followed by a trapping instruction vectors to the new mtvec: the MRET or the trapping instruction waits in EX until the write has committed (`csr_wb_hazard`).

---

## 3. Module Inventory

### 3.1 Source Files (`src/`)

| File | Module | Description |
|---|---|---|
| `fyracore.v` | `fyracore` | Top-level 3-stage pipeline (~1350 lines). Instantiates the modules from `alu` to `pmp` below. |
| `alu.v` | `alu` | RV32I ALU: ADD, XOR, OR, AND, and SUB/SLT/SLTU from the shared comparator (`branchCtrl`). No shifter. |
| `muldiv.v` | `muldiv` | Iterative unit on one 34-bit adder/subtractor: signed-aware shift-add multiplier (34 cycles), restoring divider on magnitudes (36 cycles), and the RV32I shifts, one bit per cycle (2 + shamt cycles). |
| `controller.v` | `controller` | Combinational decode of opcode/funct3/funct7 into control signals. Rejects illegal LOAD/STORE/JALR encodings without requesting side effects; the pipeline completes the rs2/rd/rs1 checks for SYSTEM and LR. |
| `decoder.v` | `decoder`, `rf_fields` | Instruction field extractor: opcode, rd, rs1, rs2, funct3, funct7. `rf_fields`: the registers an instruction reads, from its raw fetched bits, compressed or not, for the register file's synchronous read. |
| `signExt.v` | `signExt` | Immediate generation for all formats. |
| `branchCtrl.v` | `branchCtrl` | The core's one comparator: rs1 - rs2 for a branch condition, rs1 - (ALU operand 2) for SUB/SLT/SLTU. |
| `regFile.v` | `regFile` | The register file: one `rf_top` macro, one write port, two synchronous read ports (address on a rising edge, data after it, write-first). Write-first comes from a one-entry bypass here (`hit1`/`hit2`, `byp`), not from the macro. x0 is never written; the caller masks reads of x0. No reset (boot code zeroes x1-x31). |
| `rf_top.v` | `rf_top` | Simulation model of Sylvain Munaut's 32x32 2R1W sky130 register-file macro (`macro/rf_top/`: GDS, LEF, liberty, provenance); an empty blackbox under `SYNTHESIS`. Starts at 0, or at X with `+RF_X`; with `+RF_COLLIDE_X` a read of the word written on the same edge returns X. |
| `compressed_decoder.v` | `compressed_decoder` | RV32C expansion. Its legal/illegal verdict matches the RV32IMAC rules on all 49,152 16-bit encodings. |
| `csr.v` | `csr` | M-mode CSR file: trap entry, MRET, counters, PMP registers, interrupt enable/pending, the `*_legal` write values and the post-write value `wval` (section 2.3). |
| `pmp.v` | `pmp` | PMP checker, 4 entries, OFF/TOR/NA4/NAPOT, compared in the 34-bit physical address space. One instance, time-shared between the fetch (X) and data (R/W/RW) checks. |
| `clint.v` | `clint` | SiFive-compatible CLINT: mtime, mtimecmp, msip. Instantiated by the SoC top (or the memory model in simulation), not by the core. |
| `alphaone_soc.v` | `alphaone_soc` | SoC top: core, bus fabric, memory controller, QSPI engine, CLINT, UART, GPIO, syscon. Boots from flash (0x2000_0000). |
| `soc_bus.v` | `soc_bus` | Bus fabric: the core's own request/ready fanned out by a stateless address decode, with a read-data/ready mux. No registers. |
| `mem_ctrl.v` | `mem_ctrl` | Joins the fetch and data ports onto the QSPI engine: data-first arbitration, chip select from the address, PSRAM fetch split at 1 KB pages. |
| `qspi_ctrl.v` | `qspi_ctrl` | QSPI engine for the TinyTapeout QSPI Pmod: PSRAMs in QPI mode (0x0B read, 0x38 write), flash unchanged (0xEB quad I/O read, command on IO0; never written), SCK = clk/2, late read sampling with an `rd_late` strap, a start-up sequence that resets the Pmod's devices and takes them out of any QPI or continuous-read mode another design left them in. |
| `uart.v` | `uart` | 16550-compatible UART at 0x1000_0000: byte registers, fixed 8N1, no FIFOs (TX back-pressure, RTS# flow control), break send (LCR.SBC) and detect (LSR.BI), polled. |
| `gpio.v` | `gpio` | GPIO OUT/IN at 0x1001_0000 and a mode-3 SPI transmitter for the OLED, with write back-pressure while a byte shifts. |
| `syscon.v` | `syscon` | Register block at 0x1002_0000: reboot and power-off (FINISH, QEMU sifive_test codes), reset cause, boot mode, chip ID, `rd_late` strap. Generates `rst_soc`, the reset of every other SoC block. |
| `regs.v` | `regs` | Generic register module. Not instantiated. |

### 3.2 Testbench Files (`tb/`)

| File | Description |
|---|---|
| `tb_rivercore.v` | Lockstep testbench for the verification flow. Emits a Spike-format commit log; CSR values are printed from `cpu.csr_wval`. Watchdogs: `+MAX_INSTR`, `+MAX_CYCLES`, spin detection. |
| `tb_cpu.v` | Older integration testbench used by `make asm` / `scripts/run_asm_test.sh`. |
| `memory_model.v` | 16 MB of PSRAM at 0x8000_0000, the flash window reading zeros, CLINT and a testbench-only MEIP hook (0x0200_8000). Wait states (`+IMEM_WAIT`, `+DMEM_WAIT`, `*_RANDOM`, `+MEM_SEED`), what read data carries while not ready (`+NOTREADY_DATA` = X / zeros / garbage), and a handshake checker that stops the run if the core withdraws or changes an outstanding request. |
| `qspi_pmod_model.v` | Behavioural QSPI Pmod (16 MB flash on CS0, PSRAMs on CS1/CS2). Stops the run on any command `qspi_ctrl` should not send, a flash mode byte with M5-4 = 10, PSRAM traffic before its 66h/99h reset or within tRST of it, bus contention, a tCEM/tCPH violation, or an SCK period or high/low time too short for the command. Takes the raw pins with their output enable and models released ones (chip selects pulled up, SCK floating), so a chip select falling before SCK is driven low fails. `+QSPI_DELAY` device delay and `+QSPI_HOLD` output hold (the pins read X between them); hand-over states `+PSRAM_QPI`, `+PSRAM_A_QPI`/`+PSRAM_B_QPI`, `+FLASH_CRM`, `+FLASH_DCRM`, `+FLASH_QPI`; `+PSRAM_WRAP`. |
| `req_hold_check.v` | Hold-until-done checker for a request handshake. The SoC build (`-DSOC_TB`) checks the core's two ports, the data port at `mem_ctrl` and `mem_ctrl`'s requests to `qspi_ctrl`; `tb_qspi*` check the last. |
| `tb_qspi.v` | `mem_ctrl` + `qspi_ctrl` against the Pmod model, including a store aimed at flash that must select no chip; `tb_qspi_stress.v` drives core-shaped request streams, with `+RESETS` dropping resets into them (`make test-qspi`). |
| `tb_uart.v` | `uart` against spec models: a register scoreboard, the TX pin predicted on every clock (break control included), a reference transmitter on RX (baud error, glitches, framing errors, breaks, overruns), RTS# (`make test-uart`). |
| `tb_gpio.v` | `gpio`: every pin on every clock, a mode-3 SPI checker at each DIV, the IN synchroniser's latency, write back-pressure (`make test-gpio`). |
| `tb_soc_periph.v` | The SoC booting `tests/soc/*.S` from the Pmod model's flash with the demo board's devices on its pins: `rp2350_uart_model.v`, `ssd1331_model.v` (PmodOLEDrgb), `keypad_model.v` (PmodKYPD) (`make test-soc-periph`). |
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
0x1000_0000 - 0x1000_FFFF   UART        64 KB   data only (src/uart.v)
0x1001_0000 - 0x1001_FFFF   GPIO        64 KB   data only (src/gpio.v)
0x1002_0000 - 0x1002_FFFF   syscon      64 KB   data only (src/syscon.v)
```

The core only knows the map through the PMA parameters: `PMA_ROM_*` (fetch and plain loads; a store, AMO or SC is a store access fault and an LR a load access fault), `PMA_RAM_*` (everything; the only window LR/SC may use), `PMA_IO0_*` and `PMA_IO1_*` (data only). Any other address raises an access fault (cause 1/5/7). PSRAM A and B are two 8 MB chips used contiguously; `addr[23]` picks the chip. The reset PC is the `boot_addr` input (section 10); the SoC ties it to 0x2000_0000, so it always boots from flash. SoC design, boot and QSPI details: `docs/soc-architecture.md`.

The verification testbench uses these windows for flash and PSRAM and boots from PSRAM. It narrows the CLINT window to the 48 KB Spike maps (0x0200_0000-0x0200_BFFF; the SoC's is 64 KB and reads 0 above the registers) and switches IO1 off, because Spike has no device there.

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

`imem_req` is high whenever PC lies in `PMA_ROM_*` or `PMA_RAM_*` and EX holds no branch, jump, ECALL, EBREAK, MRET, FENCE.I or PMP CSR write (`ex_nofetch`: the next PC is decided there; on a shared bus a speculative fall-through fetch would have to finish before a taken redirect). Outside the windows no fetch is requested (an IO read can have side effects, and an unmapped address would never answer); the fetched bits are forced to 0 and the instruction faults in EX with cause 1. When the pipeline is stalled with a fetch already completed, the same address is requested again.

`dmem_req` is high for a valid, non-trapping load, store or AMO in WB, except a failing SC, which retires without a transaction. `dmem_be` gives the byte lanes of every request, loads included; `dmem_we` says whether it is a write. An AMO is a read followed by a write, back to back.

For a memory controller: while a data request waits, the pipeline is stalled and `imem_req` stays up with the same address, so a controller sharing one bus must not starve the data port (serve data first or alternate) and should keep the last fetched word so a repeated request completes without a new transfer. A 32-bit fetch at the last halfword of a window asks for bytes past its end; anything may be returned for them. `imem_addr` is the halfword-aligned PC and the four bytes from it are wanted (`imem_rdata[7:0]` is the byte at `imem_addr`). Store data is replicated across the lanes (`{4{byte}}`, `{2{half}}`), so the first enabled byte of any store is also in `dmem_wdata[7:0]`.

### 5.2 Memory controller and QSPI engine

`src/mem_ctrl.v` serves both ports from one QSPI engine (`src/qspi_ctrl.v`): data first; a fetch reads 4 bytes from the halfword PC; a load reads the whole aligned word; a store sends only its enabled bytes; a PSRAM fetch that crosses a 1 KB page (which includes PSRAM A into B at 0x807F_FFFE) is split into two 2-byte reads, because PSRAM parts without row-boundary crossing wrap within the page. `qspi_ctrl` resets the Pmod's devices before its first request and puts the PSRAMs in QPI mode (a 4-byte PSRAM read is 20 SCK cycles, a flash read 28), never selects the flash for a write, and has a read-latency strap (`rd_late`). It does not keep the last fetched word, so a pipeline stalled with a fetch outstanding (WFI) refetches. See `docs/soc-architecture.md`.

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
- One checker (`pmp_unit`) serves the fetch and the data access in turn. Whenever PMP could deny a fetch (U-mode, or any entry locked) the instruction spends one stalled EX cycle checking `ifex_pc` with X permission and, for a 32-bit instruction at an address with bit 1 set, one more on the upper half at `{pc[31:2], 2'b00}` (`ex_ifetch_hi_phase`); the verdicts are latched in `ifetch_lo_denied` / `ifetch_hi_denied`. The upper half also has a dedicated PMA compare. A fault in only the upper half reports that half's address in mtval. An M-mode kernel with no locked entry never spends these cycles.
- On the instruction's last EX cycle the checker looks at the data address in `alu_r` with R (load, LR), W (store, SC) or R+W (AMO). With `mstatus.MPRV = 1`, the privilege checked is MPP.

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
| 0x305 | mtvec | [31:2] | Direct mode only. Resets to 0, as on Spike; 0 is unmapped on this SoC, so a trap before software writes mtvec -- erased flash (0xFFFFFFFF) at the reset vector, say -- becomes a silent cause-1 loop at 0 that rewrites mepc, mcause and mtval each time. Boot code sets mtvec first. |
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
| 0x344 | mip | MSIP[3], MTIP[7], MEIP[11] are the interrupt wires; nothing is writable. MTIP comes registered from the CLINT: after a store moves mtimecmp, it keeps its old value for two clocks, which is the next two instructions when the fetch is fast (section 8.4) |

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
- Enable: `irq_global_en = !priv_mode || mstatus.MIE`, with per-source `mie` bits. The instruction after a CSR write reaches EX only once the write has committed, so the instruction after `csrc mstatus, 8` or `csrc mie, …` is already masked, and the one after `csrs mie, …` is already interruptible.
- MTIP lags mtimecmp: the CLINT registers it, so after a store moves mtimecmp into the future `mip.MTIP` still reads 1 for two clocks (the store commits in WB, then the register updates) -- the next two instructions when the fetch is fast, fewer or none behind fetch waits. An interrupt enabled in that window would be taken with nothing pending by the time the handler reads mip; Priv 3.2.1 allows it ("reflected in MTIP eventually, but not necessarily immediately. A spurious timer interrupt might occur"). A `csrsi mstatus, 8` right after the store does not reach it: the CSR-write stall outlasts the window. Linux programs mtimecmp with MIE = 0 several instructions before re-enabling, and MRET always leaves a bubble. `tests/directed/mtip_stale.S` pins the window at both ends.
- Injection: `irq_inject = any_irq_pend && ifex_valid && !ex_trap && !muldiv_want && !stall_other`. It is never taken during a stall or while an M instruction or a shift is in EX, and a synchronous trap wins.
- Entry: the EX instruction's side effects are suppressed and its PC becomes mepc, so it re-executes after MRET.

### 8.5 WFI

- M-mode: WFI retires and sets `wfi_active`, stalling the next instruction until an individually enabled interrupt is pending (regardless of MIE). If no source is enabled in `mie`, WFI is a NOP. On wake, a taken interrupt's mepc is the instruction after the WFI.
- U-mode with TW = 0: WFI retires as a NOP and never waits (`ex_is_wfi` requires M-mode). Priv 3.3.3 allows WFI to be a NOP, and with no S-mode TW = 0 permits it in U-mode (3.1.6.6). U-mode software that idles in a WFI loop spins instead of sleeping; M-mode Linux is unaffected.
- U-mode with TW = 1: illegal instruction.

---

## 9. Instruction Set Support

### 9.1 RV32I

All base instructions. FENCE is a NOP (in-order core, blocking memory). FENCE fields and FENCE.TSO/PAUSE encodings execute as FENCE.

### 9.2 M Extension

| Op | Instruction | Cycles |
|---|---|---|
| MUL, MULH, MULHSU, MULHU | multiply | 34 |
| DIV, DIVU, REM, REMU | divide | 36 |
| SLL, SRL, SRA (and immediates) | shift | 2 + shamt |

Cycles are `muldiv`'s latency: `done` comes this many cycles after the `start` cycle, so the instruction occupies EX for one more (plus its rs2 read cycle when rs2 is not x0). They run during the next instruction's fetch, so behind the SoC's QSPI memory an M instruction costs no more than an ALU one. One 34-bit adder/subtractor serves all eight: a signed multiplicand is sign-extended into the accumulator and a signed multiplier's last step subtracts, so a multiply needs no operand or result negation; a divide negates its operands and result through the same adder. The RV32I shifts (SLL/SRL/SRA, SLLI/SRLI/SRAI) run through the same unit's shift register, one bit per cycle. Division by zero and signed overflow follow the spec. Handshake: `start` for one cycle, `busy` while computing, `done` for one cycle as `busy` drops. The pipeline takes the result on the done cycle if it can, otherwise it holds it in `muldiv_ready` until it can. It never restarts on the done cycle.

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
    input  wire [31:0] boot_addr,      // reset PC, loaded every cycle rst is high; bit 0 ignored
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
./run.sh soc build | soc one <name>  # the SoC build, and one test through it
```

`make test-all` includes `test-qspi`, `test-uart`, `test-gpio` and `test-soc-periph` (the `tests/soc/` programs through the SoC). MANIFEST lines marked `soc` run only through the SoC, with the QSPI Pmod model's plusargs (hand-over states, delays, `+RD_LATE`); `flash` tests boot from flash and run only there.

Memory-timing plusargs for the lockstep sim: `+IMEM_WAIT=n +DMEM_WAIT=n +IMEM_RANDOM=1 +DMEM_RANDOM=1 +MEM_SEED=n +NOTREADY_DATA=0|1|2`. Different settings expose different bugs; sweep them independently.

---

## 12. Design Decisions and Rationale

### 12.1 Why 3 Stages?
Area is the primary constraint. IF/EX/WB keeps pipeline registers minimal, and the QSPI memory bottleneck dominates throughput: a fetch is at least 40 clocks and the instruction in EX waits for the one behind it. That is why EX can spend three cycles -- register read, ALU, decision -- for the sake of the clock period at no cost in throughput, where a fourth pipeline stage would have cost registers and bypasses.

### 12.2 Why Iterative MulDiv?
The combinational operators cost more than 10k gates. The iterative unit, with one shared adder, costs about 0.9 tile (0.93 with TT's cells, 0.72 in the audit's yosys recipe) for 34-36 cycles per operation, which run during the next instruction's QSPI fetch. The shifts use it too, instead of a barrel shifter.

### 12.3 Why Direct-Mode mtvec?
Vectored mode adds logic for no benefit on an M+U system; Linux uses direct mode.

### 12.4 Why 4 PMP Entries?
Enough for M/U isolation (Linux M-mode programs one NAPOT entry covering everything). More entries cost area linearly.

### 12.5 Why Stall After a CSR Write Instead of Forwarding?
The WARL rules used to exist in four places (csr.v, the EX forward, the trap/MRET target masks, the testbench trace), and each copy that drifted produced a defect. With a one-cycle stall behind every CSR write, EX reads only stored state, the rules live once (the `*_legal` wires), and the forwarding muxes are gone. In the SoC the cycle is hidden behind the next fetch, unless the instruction after the write is one of the `ex_nofetch` ones (e.g. `csrw mepc` followed by `mret`).

### 12.6 Why Refetch After a PMP Write?
Forwarding pending PMP state into the checker would need a 160-bit mux, and the CSR-write stall alone does not cover a fetch verdict latched during that stall. PMP writes are rare, so refetching the next instruction (one fetch per write) is the cheaper way to make it see them.

### 12.7 Why One Time-Shared PMP Checker?
Checking the fetch, a straddling fetch's upper half and the data access at once took separate checkers. The extra EX cycles are only spent when PMP can actually deny a fetch (U-mode, or a locked entry), so an M-mode kernel never pays them. In the SoC they are hidden behind the next fetch, except on jumps and branches (no fetch is in flight behind them; see `ex_nofetch`), which pay +1 clock in U-mode: compiled C runs 0.23% slower in U-mode than in M-mode.

### 12.8 Why Pre-Compute CSR Values in EX?
EX computes the read-modify-write value, so the CSR unit only ever writes, and the value travels to WB in `exwb_rs2_data` (a CSR instruction has no rs2).

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
13. The memory controller keeps no fetch buffer: a stall with a fetch outstanding refetches, and every access costs a full QSPI transaction (about 42 clocks from PSRAM, 60 from flash).
14. x1-x31 are not reset; boot code must zero them (`plugins/helpers/boot_flash.S` does).
15. The register-file macro's timing is a placeholder liberty (setup 2.0, hold 0.2, clock-to-output 4.0 ns, minimum period 10 ns, one nominal corner), not a characterisation.
