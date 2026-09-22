# FyraCore CPU Reference

## 1. Overview

**FyraCore** is a 3-stage pipelined RISC-V processor implementing the **RV32IMAC** ISA plus the **Zicsr** and **Zifencei** standard extensions. It supports **M-mode** (Machine) and **U-mode** (User) privilege levels with Physical Memory Protection (PMP). The core is designed for area-constrained fabrication on **Skywater 180nm** and targets booting no-MMU Linux (uClinux-style).

| Property | Value |
|---|---|
| ISA | RV32IMAC + Zicsr + Zifencei |
| Pipeline | 3 stages: IF / EX / WB |
| Privilege Modes | M (Machine) + U (User) |
| Memory Protection | PMP, 4 regions (TOR + NA4 + NAPOT) |
| Interrupts | Timer, External, Software (via CLINT) |
| Target Process | Skywater 180nm |
| Primary Goal | Boot no-MMU Linux with area as #1 priority |

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
                            | PMP Check        |        | AMO Phase 2     |
                            | Trap Detection   |        +-----------------+
                            +------------------+
```

**IF (Instruction Fetch):**
- Fetches instruction from `imem_addr` (= PC)
- Detects compressed instructions (bits `[1:0] != 2'b11`)
- Decompresses 16-bit RV32C instructions to 32-bit equivalents via `compressed_decoder`
- Computes `if_pc_next = pc + 2` (compressed) or `pc + 4` (normal)

**EX (Execute):**
- Decodes instruction fields via `decoder`
- Generates control signals via `controller`
- Reads register file (with WB->EX forwarding)
- Executes ALU operation or starts multi-cycle multiply/divide
- Evaluates branch conditions
- Performs PMP checks on both ifetch PC and data address
- Detects all trap conditions (illegal, misaligned, PMP fault, ecall, ebreak)
- Computes CSR read-modify-write value
- Detects and injects interrupts

**WB (Writeback):**
- Performs memory load/store
- Handles AMO two-phase operations (read then write)
- Commits CSR writes
- Writes back to register file
- Commits traps to CSR unit (mepc, mcause, mtval, mstatus)

### 2.2 Hazard Handling

| Hazard | Resolution |
|---|---|
| Data dependency (RAW) | WB -> EX forwarding via `fwd_rs1`/`fwd_rs2` |
| Load-use | 1-cycle pipeline stall |
| Branch/Jump | 1-cycle flush penalty |
| Multi-cycle MulDiv | Pipeline stall until `muldiv_done` |
| AMO | 2-cycle WB stall (read phase, write phase) |
| Memory not ready | `imem_ready` / `dmem_ready` stall |
| WFI | Pipeline stall until interrupt pending or NOP if no sources enabled in `mie` |

The stall signal hierarchy:
```
stall_other = load_use_hazard || wb_busy || if_mem_stall || wb_mem_stall || wfi_active
muldiv_stall = muldiv_want && (muldiv_start || muldiv_busy)
stall = stall_other || muldiv_stall
flush = ex_branch_taken || ex_is_mret || ex_trap || ex_is_fencei || irq_inject
```

### 2.3 CSR Forwarding

When WB writes a CSR that EX reads in the same cycle, the forwarding logic (`csr_fwd`) bypasses the CSR register file and applies the same per-CSR write masks that `csr.v` would apply:

- `mstatus` (0x300): masked with `0x0000_1888` (MIE, MPIE, MPP bits only)
- `mtvec` (0x305): bits `[1:0]` forced to `2'b00` (direct mode only, WARL)
- `mepc` (0x341): bit 0 forced to 0
- `pmpcfg0` (0x3A0): per-byte lock preservation, reserved `A=2'b10` masked to `2'b00`
- `pmpaddr[0-3]`: forwarding suppressed if entry is locked (own L bit or TOR lock from entry i+1)

### 2.4 Trap Target / MRET Target Forwarding

The pipeline forwards mtvec and mepc from WB CSR writes to avoid stale redirect targets. Without this, sequences like `csrw mepc, t5; mret` would use the old mepc value.

```verilog
wire [31:0] trap_target = mtvec_fwd ? {exwb_csr_wdata[31:2], 2'b00} : csr_mtvec;
wire [31:0] mret_target = mepc_fwd  ? {exwb_csr_wdata[31:1], 1'b0}  : csr_mepc;
```

Both forwarded values apply the same WARL masks as the CSR write path.

---

## 3. Module Inventory

### 3.1 Source Files (`src/`)

| File | Module | Description |
|---|---|---|
| `fyracore.v` | `fyracore` | Top-level 3-stage pipeline. Instantiates all other modules. ~920 lines. |
| `alu.v` | `alu` | RV32I-only ALU (ADD, SUB, SLL, SRL, SRA, SLT, SLTU, XOR, OR, AND). M-extension removed. |
| `muldiv.v` | `muldiv` | Iterative multi-cycle multiply/divide unit. Shift-add multiplier (33-34 cycles), restoring divider (34 cycles). Replaces ~10,000-gate combinational logic with ~800-1200 gates. |
| `controller.v` | `controller` | Combinational control signal decoder for all RV32IMAC+Zicsr+Zifencei opcodes. Outputs: `regWR`, `aluOp`, `memRD/WR`, `csrOp`, `isAmo/LR/SC`, `isEcall/Ebreak/Mret`, `isFence/FenceI`, `isMulDiv`, `illegal`. |
| `decoder.v` | `decoder` | Instruction field extractor: opcode, rd, rs1, rs2, funct3, funct7. |
| `signExt.v` | `signExt` | Immediate generation for all instruction formats (I, S, B, U, J, CSR zimm, FENCE). |
| `branchCtrl.v` | `branchCtrl` | Branch condition evaluator: BEQ, BNE, BLT, BGE, BLTU, BGEU. |
| `regFile.v` | `regFile` | 32x32-bit register file. x0 hardwired to zero. Synchronous write, combinational read. |
| `compressed_decoder.v` | `compressed_decoder` | RV32C 16-bit to 32-bit instruction expansion. Covers Q0, Q1, Q2 compressed encodings. Flags illegal encodings including `shamt[5]=1` on RV32 for C.SLLI/SRLI/SRAI. |
| `csr.v` | `csr` | M-mode CSR register file. Dual-port (EX reads, WB writes). Handles trap entry/exit, mstatus save/restore, PMP registers, performance counters, interrupt pending/enable. |
| `pmp.v` | `pmp` | Physical Memory Protection checker. 4 regions, supports OFF/TOR/NA4/NAPOT addressing modes. Two instances in fyracore: one for ifetch (X), one for data (R/W). |
| `clint.v` | `clint` | SiFive-compatible Core Local Interruptor. Provides mtime, mtimecmp, msip registers. Timer interrupt when `mtime >= mtimecmp`. Software interrupt when `msip[0] = 1`. |
| `memController.v` | `memController` | Dual-mode memory controller. SIM_MODE=1: internal 32MB byte array. SIM_MODE=0: QSPI FSM with address-tagged ifetch buffer, on-chip CLINT, GPIO. |
| `regs.v` | `regs` | Generic register module (used internally). |

### 3.2 Testbench Files (`tb/`)

| File | Description |
|---|---|
| `tb_cpu.v` | Full CPU integration testbench. Loads hex program, instantiates fyracore + memory_model, provides per-instruction trace output, detects halt loops. |
| `memory_model.v` | Simulation memory model. 32MB flat byte array + embedded CLINT instance. Dual-port: combinational reads, synchronous writes. Always-ready (no stalls). |
| `tb_alu.v` | ALU unit testbench |
| `tb_branchCtrl.v` | Branch controller unit testbench |
| `tb_controller.v` | Controller unit testbench |
| `tb_csr.v` | CSR unit testbench |
| `tb_compressed_decoder.v` | Compressed decoder unit testbench |
| `tb_decoder.v` | Decoder unit testbench |
| `tb_muldiv.v` | Multi-cycle multiply/divide unit testbench |
| `tb_regFile.v` | Register file unit testbench |
| `tb_signExt.v` | Sign extension/immediate generation unit testbench |

### 3.3 Test Programs (`tests/`)

All tests are RISC-V assembly (`.S`) assembled to hex via the toolchain scripts. They use a shared linker script (`tests/linker.ld`) placing `.text` at 0x00000000 (Flash) and `.data` at Flash as well (for simplicity; a Linux linker script would place `.data` at 0x01000000 in RAM).

| Test | Description |
|---|---|
| `rv32i_basic.S` | Basic RV32I instruction coverage |
| `rv32m_test.S` | M-extension multiply/divide operations |
| `rv32c_test.S` | RV32C compressed instruction execution |
| `rv32c_illegal_test.S` | Compressed illegal instruction trapping (12 test cases) |
| `rv32a_test.S` | A-extension atomic operations including edge cases (tests 16-22) |
| `csr_test.S` | CSR read/write, counters, forwarding, mconfigptr |
| `trap_test.S` | Trap handling (13 test cases): ecall, ebreak, illegal, misaligned, PMP |
| `pipeline_hazard_test.S` | Pipeline hazard verification (12 test cases) |
| `pmp_test.S` | PMP region configuration and access control |
| `umode_test.S` | U-mode privilege support: ecall cause, CSR access control, MRET |
| `timer_irq_test.S` | Timer interrupt via CLINT mtimecmp |
| `sw_irq_test.S` | Software interrupt via CLINT msip |
| `wfi_test.S` | WFI stall and wake behavior |
| `zifencei_test.S` | FENCE.I self-modifying code support |
| `fencei_smc_test.S` | FENCE.I flush for self-modifying code |

---

## 4. Memory Map

```
Address Range               Device      Size    Description
-----------------------------------------------------------------
0x0000_0000 - 0x00FF_FFFF   Flash       16 MB   XIP code, read-only data (QSPI CS0)
0x0100_0000 - 0x01FF_FFFF   RAM         16 MB   Stack, heap, .data/.bss (QSPI CS1)
0x0200_0000 - 0x0200_BFFF   CLINT       48 KB   Timer and software interrupt registers
0x0300_0000 - 0x0300_0007   GPO         8 B     GPIO output
0x0300_0008 - 0x0300_000F   GPI         8 B     GPIO input
0x0400_0000+                Reserved            Future peripherals (UART, SPI, etc.)
```

### Key Design Decisions

- **Flash at address 0**: PC resets to 0x0, bootloader/kernel lives at start of flash. XIP (execute-in-place) directly from flash.
- **Unified Von Neumann**: Both instruction fetch and data access can target either Flash or RAM. No hard IMEM/DMEM boundary. Critical for Linux which needs self-modifying code, XIP from flash, and data in RAM.
- **CLINT at 0x0200_0000**: Standard SiFive convention, discoverable by device tree.
- **QSPI address routing**: In hardware mode, bit 24 of the address selects chip (0=Flash, 1=RAM). The lower 24 bits are the offset within each 16MB QSPI device.

### CLINT Register Map (offsets from 0x0200_0000)

| Offset | Register | Description |
|---|---|---|
| 0x0000 | msip | Bit 0 = software interrupt pending (1-bit register) |
| 0x4000 | mtimecmp_lo | Low 32 bits of mtimecmp |
| 0x4004 | mtimecmp_hi | High 32 bits of mtimecmp |
| 0xBFF8 | mtime_lo | Low 32 bits of mtime (read-write, auto-increments every clock) |
| 0xBFFC | mtime_hi | High 32 bits of mtime |

- `timer_irq` asserted when `mtime >= mtimecmp`
- `sw_irq` asserted when `msip[0] = 1`
- `mtime` auto-increments every clock cycle; explicit write takes priority over increment

---

## 5. Memory Controller

### 5.1 Simulation Mode (`SIM_MODE=1`)

- Single 32MB byte-addressable array covers both Flash and RAM ranges
- Both `imem` and `dmem` ports index the same array (Von Neumann)
- Combinational reads, synchronous byte-masked writes
- `imem_ready` and `dmem_ready` always asserted (no stalls)
- CLINT is embedded in `memory_model.v` (testbench), not in the memory controller

### 5.2 Hardware Mode (`SIM_MODE=0`)

- QSPI FSM with 7 states: IDLE, IFETCH, IFETCH_W, DREAD, DREAD_W, DWRITE, DWRITE_W
- Address-tagged ifetch buffer: `ifetch_hit = ifetch_valid && (ifetch_addr == imem_addr)`. Only reports `imem_ready` on address match, preventing stale instruction consumption after branches/jumps.
- FENCE.I invalidates the ifetch buffer (`ifetch_valid <= 0`)
- On-chip CLINT instantiated inside the hw_mem generate block (single-cycle, no QSPI)
- GPIO reads/writes are single-cycle, no QSPI involvement
- Data access priority: GPO write > CLINT > QSPI data write > QSPI data read > QSPI ifetch
- Chip select: `bit[24]` of address determines Flash (0) vs RAM (1)

---

## 6. Privilege and Protection

### 6.1 Privilege Modes

Two privilege levels: M-mode (priv_mode=1) and U-mode (priv_mode=0).

- **Boot**: M-mode (`priv_mode <= 1'b1` on reset)
- **Trap entry**: Always to M-mode (no S-mode delegation)
- **MRET**: Restores privilege from `mstatus.MPP` (2'b11 -> M, 2'b00 -> U), then sets MPP to U (2'b00 per spec)
- **MRET from U-mode**: Traps as illegal instruction (`ex_is_mret` requires `priv_mode == 1`)
- **IRQ inject**: Sets `priv_mode <= 1'b1` via the `csr_trap_signal` path (no separate assignment, avoiding the MPP save race)

### 6.2 CSR Access Control

CSR address bits `[9:8]` encode minimum required privilege:
- `2'b00`: U-mode accessible (0x000-0x0FF, 0xC00-0xCFF user counters)
- `2'b01` or higher: M-mode only (0x300-0x3FF, 0x700-0x7FF, 0xB00-0xBFF, 0xF00-0xFFF)

User counter access (0xC00/C80/C01/C81/C02/C82) is additionally gated by `mcounteren` bits:
- Bit 0 (CY): cycle/cycleh access
- Bit 1 (TM): time/timeh access
- Bit 2 (IR): instret/instreth access

### 6.3 Physical Memory Protection (PMP)

4 PMP regions via `pmpcfg0` (0x3A0) and `pmpaddr0-3` (0x3B0-0x3B3).

**Config byte layout** (per entry, packed in pmpcfg0):
```
Bit  [7]    L  — Lock (applies to M-mode too; entry immutable until reset)
Bit  [6:5]  reserved (WIRI)
Bits [4:3]  A  — Address matching mode:
                 00 = OFF (entry disabled)
                 01 = TOR (Top of Range: addr >= baddr[i-1] && addr < baddr[i])
                 10 = RESERVED — masked to OFF on write (WARL)
                 11 = NAPOT (Naturally Aligned Power-of-Two)
Bits [2:0]  R/W/X permissions
```

**Matching rules:**
- Entry 0 has highest priority, entry 3 lowest (first match wins)
- No matching entry: M-mode allowed, U-mode denied
- Locked entry (L=1): enforces permissions on M-mode as well
- TOR locking: when entry i uses TOR+Lock, `pmpaddr[i-1]` is also locked

**PMP check instances in pipeline:**
- `pmp_ifetch`: Checks `ifex_pc` with Execute (3'b100) permission in EX stage
- `pmp_data`: Checks `ex_alu_result` with R (3'b001), W (3'b010), or R+W (3'b011 for AMO) in EX stage

---

## 7. CSR Register Set

### 7.1 Machine Information (Read-Only)

| Address | Name | Value | Description |
|---|---|---|---|
| 0xF11 | mvendorid | 0x0 | Vendor ID (non-commercial) |
| 0xF12 | marchid | 0x0 | Architecture ID |
| 0xF13 | mimpid | 0x1 | Implementation ID |
| 0xF14 | mhartid | 0x0 | Hart ID |
| 0xF15 | mconfigptr | 0x0 | Config data structure pointer (none) |

### 7.2 Machine ISA (Read-Only)

| Address | Name | Value | Description |
|---|---|---|---|
| 0x301 | misa | `{2'b01, 26'b...0001000100000101}` | XLEN=32, Extensions: I, M, A, C |

### 7.3 Machine Trap Setup

| Address | Name | Writable Bits | Description |
|---|---|---|---|
| 0x300 | mstatus | Mask `0x1888` (MIE[3], MPIE[7], MPP[12:11]) | Machine status |
| 0x304 | mie | Mask `0x0888` (MSIE[3], MTIE[7], MEIE[11]) | Machine interrupt enable |
| 0x305 | mtvec | `[31:2]` writable, `[1:0]` forced to `2'b00` | Machine trap vector (direct mode only, WARL) |
| 0x306 | mcounteren | Mask `0x0007` (CY[0], TM[1], IR[2]) | U-mode counter access control |

### 7.4 Machine Trap Handling

| Address | Name | Description |
|---|---|---|
| 0x340 | mscratch | Scratch register for M-mode trap handler |
| 0x341 | mepc | Exception PC (bit 0 forced to 0) |
| 0x342 | mcause | Trap cause (bit 31 = interrupt flag) |
| 0x343 | mtval | Trap value (faulting address or instruction) |
| 0x344 | mip | Interrupt pending. Bits MSIP[3], MTIP[7], MEIP[11] are read-only live wires from CLINT/external pins. Other bits writable but masked with `~0x0888`. |

### 7.5 Performance Counters

| Address | Name | Description |
|---|---|---|
| 0xB00 | mcycle | Cycle counter low 32 bits (auto-increments, writable) |
| 0xB80 | mcycleh | Cycle counter high 32 bits |
| 0xB02 | minstret | Retired instruction counter low 32 bits |
| 0xB82 | minstreth | Retired instruction counter high 32 bits |

Counter CSR writes are handled in dedicated `always` blocks (merged with auto-increment logic to avoid dual-driver synthesis failures). Write takes priority over increment.

### 7.6 User Counter Aliases

| Address | Name | Gate | Description |
|---|---|---|---|
| 0xC00 | cycle | mcounteren[0] | Read alias for mcycle (U-mode gated) |
| 0xC80 | cycleh | mcounteren[0] | Read alias for mcycleh |
| 0xC01 | time | mcounteren[1] | Reads mtime from CLINT (U-mode gated) |
| 0xC81 | timeh | mcounteren[1] | Reads mtime high from CLINT |
| 0xC02 | instret | mcounteren[2] | Read alias for minstret (U-mode gated) |
| 0xC82 | instreth | mcounteren[2] | Read alias for minstreth |

### 7.7 PMP CSRs

| Address | Name | Description |
|---|---|---|
| 0x3A0 | pmpcfg0 | 4 packed 8-bit PMP config bytes. Per-byte locked by L bit. A=2'b10 masked to 2'b00 on write. |
| 0x3B0-0x3B3 | pmpaddr0-3 | PMP address registers. Locked by own L bit or TOR lock from next entry. |
| 0x3A1-0x3A3 | pmpcfg1-3 | Hardwired to zero (WARL, only 4 regions implemented) |
| 0x3B4-0x3BF | pmpaddr4-15 | Hardwired to zero (WARL) |

### 7.8 CSR Write Value Computation

The pipeline pre-computes the CSR write value in EX and stores it in `exwb_csr_wdata`:
```
CSRRW/CSRRWI: csr_new = wdata (rs1 value or zero-extended uimm)
CSRRS/CSRRSI: csr_new = csr_rdata_eff | wdata
CSRRC/CSRRCI: csr_new = csr_rdata_eff & ~wdata
```

The CSR unit always receives `op=2'b01` (CSRRW) because the pipeline has already computed the final value. This simplifies the CSR write path.

### 7.9 CSR Write Suppression

CSRRS/CSRRC with `rs1=x0` and CSRRSI/CSRRCI with `uimm=0` do NOT perform a write (`ex_csr_writes = 0`). This is required by the spec to allow read-only CSR access without trapping.

---

## 8. Trap and Interrupt Handling

### 8.1 Synchronous Trap Priority

Trap cause assignment follows spec Table 3.7 priority (highest to lowest):

| Priority | Condition | Cause | mtval |
|---|---|---|---|
| 1 | PMP instruction fetch fault | 1 (Instruction access fault) | Faulting PC |
| 2 | Illegal instruction (controller, compressed, bad SYSTEM, bad WFI, CSR) | 2 (Illegal instruction) | Faulting instruction encoding |
| 3 | ECALL | 11 (M-mode) or 8 (U-mode) | 0 |
| 4 | EBREAK | 3 (Breakpoint) | 0 |
| 5 | Load address misaligned | 4 | Faulting address |
| 6 | Store/AMO address misaligned | 6 | Faulting address |
| 7 | Load PMP access fault | 5 | Faulting address |
| 8 | Store/AMO PMP access fault | 7 | Faulting address |

### 8.2 Trap Sources

All trap sources ORed into `ex_trap`:
- `ex_is_ecall` / `ex_is_ebreak`
- `ex_pmp_ifetch_fail` — PMP denied instruction fetch
- `ctrl_illegal && !ctrl_isFence` — controller flagged illegal opcode
- `ifex_c_illegal` — compressed decoder flagged illegal encoding
- `ex_bad_system` — malformed SYSTEM encoding (wrong rd/rs1/rs2 fields)
- `ex_wfi_umode` — WFI from U-mode (illegal per spec Section 3.3.3)
- `ex_bad_wfi` — WFI with non-zero rd or rs1
- `ex_csr_illegal` — invalid/read-only/privilege-fail CSR access
- `ex_misaligned` — misaligned memory access
- `ex_pmp_data_fail` — PMP denied data access

### 8.3 Trap Entry Sequence

On `csr_trap_signal` (WB stage detects `exwb_trap`):
1. `mepc <= trap_pc` (PC of trapping instruction)
2. `mcause <= trap_cause`
3. `mtval <= trap_val` (faulting address or instruction, or 0)
4. `mstatus.MPIE <= mstatus.MIE`; `mstatus.MIE <= 0`
5. `mstatus.MPP <= current_privilege` (2'b11 for M, 2'b00 for U)
6. `priv_mode <= 1'b1` (enter M-mode)
7. `PC <= trap_target` (mtvec, with forwarding and WARL mask)

### 8.4 MRET Sequence

On `ex_is_mret` (EX stage, M-mode only):
1. `mstatus.MIE <= mstatus.MPIE`; `mstatus.MPIE <= 1`
2. `mstatus.MPP <= 2'b00` (set to U-mode per spec)
3. `priv_mode <= (mstatus.MPP == 2'b11)` (restore from MPP before it's cleared)
4. `PC <= mepc` (with forwarding)

### 8.5 Interrupt Handling

**Interrupt sources:**
- Machine External Interrupt (MEIP, cause 11, priority 1 — highest)
- Machine Software Interrupt (MSIP, cause 3, priority 2)
- Machine Timer Interrupt (MTIP, cause 7, priority 3 — lowest)

**Global enable logic:**
```
irq_global_en = !priv_mode || mstatus_mie_eff
```
Per spec Section 3.1.6.1: MIE only gates M-mode interrupts. U-mode interrupts are always enabled (no delegation in M+U only system).

**mstatus.MIE forwarding:** The pipeline forwards mstatus.MIE from WB stage to avoid a 1-cycle window where an interrupt slips in after `csrci mstatus,8` (MIE 1->0) but before the write commits:
```verilog
wire mstatus_mie_eff = (exwb_valid && exwb_csrWR && !exwb_trap && exwb_csr_addr == 12'h300)
    ? (exwb_csr_wdata[3] != 1'b0)  // forwarded MIE bit
    : csr_mstatus_mie;
```

**Injection gating:**
```
irq_inject = any_irq_pend && ifex_valid && !ex_trap
           && !muldiv_busy && !wb_busy && !wfi_active
```
- Only when a valid instruction is in EX (gives clean mepc)
- Never mid-muldiv or mid-AMO
- Synchronous traps take priority over interrupts
- WFI has special handling (see below)

**Interrupt entry:**
- Suppresses all instruction side effects (regWR, memRD/WR, csrWR, AMO, LR/SC all zeroed)
- Sets `exwb_trap = 1` with `irq_cause` (bit 31 set + cause code)
- `mepc` = `ifex_pc` (re-execute interrupted instruction on MRET)
- Exception: if interrupted instruction is WFI, `mepc = ifex_pc_next` (advance past WFI)

### 8.6 WFI Behavior

- **M-mode WFI**: Sets `wfi_active`, stalls pipeline until:
  - An individually-enabled interrupt source fires (regardless of MIE global bit), OR
  - No interrupt sources are enabled in `mie` (degenerates to NOP to prevent infinite stall)
- **U-mode WFI**: Traps as illegal instruction (spec Section 3.3.3)
- **WFI with bad fields** (non-zero rd or rs1): Traps as illegal instruction
- When interrupt arrives during WFI: `wfi_active` clears, `irq_inject` fires next cycle, `mepc` points past WFI

---

## 9. Instruction Set Support

### 9.1 RV32I Base Integer

All 40 base integer instructions:
- **Arithmetic**: ADD, SUB, ADDI
- **Logical**: AND, OR, XOR, ANDI, ORI, XORI
- **Shift**: SLL, SRL, SRA, SLLI, SRLI, SRAI
- **Compare**: SLT, SLTU, SLTI, SLTIU
- **Upper immediate**: LUI, AUIPC
- **Load**: LB, LH, LW, LBU, LHU
- **Store**: SB, SH, SW
- **Branch**: BEQ, BNE, BLT, BGE, BLTU, BGEU
- **Jump**: JAL, JALR
- **System**: ECALL, EBREAK
- **Fence**: FENCE (NOP behavior)

### 9.2 M Extension (Multiply/Divide)

All 8 operations via iterative multi-cycle `muldiv` unit:

| Op | Instruction | Cycles | Description |
|---|---|---|---|
| 3'b000 | MUL | 33-34 | Lower 32 bits of rs1 x rs2 |
| 3'b001 | MULH | 33-34 | Upper 32 bits of signed x signed |
| 3'b010 | MULHSU | 33-34 | Upper 32 bits of signed x unsigned |
| 3'b011 | MULHU | 33-34 | Upper 32 bits of unsigned x unsigned |
| 3'b100 | DIV | 34 | Signed division |
| 3'b101 | DIVU | 34 | Unsigned division |
| 3'b110 | REM | 34 | Signed remainder |
| 3'b111 | REMU | 34 | Unsigned remainder |

**Edge cases per spec:** Division by zero returns all-ones (DIV/DIVU) or dividend (REM/REMU). Signed overflow (INT_MIN / -1) returns INT_MIN (DIV) or 0 (REM).

**Handshake:** `start` pulse for one cycle -> `busy` held -> `done` pulse when result valid. Pipeline stalls during `busy`.

### 9.3 A Extension (Atomics)

Load-Reserved / Store-Conditional:
- **LR.W**: Load word, set reservation on address
- **SC.W**: Store word if reservation valid and address matches; rd = 0 (success) or 1 (failure)

Atomic Memory Operations (2-cycle AMO via pipeline stall):
- AMOSWAP.W, AMOADD.W, AMOXOR.W, AMOAND.W, AMOOR.W
- AMOMIN.W, AMOMAX.W, AMOMINU.W, AMOMAXU.W

AMO execution: Phase 0 (read, wb_busy=1) -> Phase 1 (compute + write, wb_busy=0). rd receives the original memory value.

Reservation is invalidated on: SC execution (success or failure), any local
store or AMO overlapping the reservation address, trap, interrupt, or reset.
No external-agent invalidation is implemented: this SoC has a single hart and
no other bus master.

### 9.4 C Extension (Compressed)

The `compressed_decoder` expands 16-bit instructions to 32-bit equivalents:

**Quadrant 0:** C.ADDI4SPN, C.LW, C.SW
**Quadrant 1:** C.NOP, C.ADDI, C.JAL, C.LI, C.ADDI16SP, C.LUI, C.SRLI, C.SRAI, C.ANDI, C.SUB, C.XOR, C.OR, C.AND, C.J, C.BEQZ, C.BNEZ
**Quadrant 2:** C.SLLI, C.LWSP, C.JR, C.MV, C.EBREAK, C.JALR, C.ADD, C.SWSP

**Illegal encoding detection:**
- C.ADDI4SPN with nzuimm=0
- C.ADDI16SP with nzimm=0
- C.LUI with nzimm=0 or rd=x0
- C.LWSP with rd=x0
- C.JR with rd=x0
- C.SLLI/C.SRLI/C.SRAI with shamt[5]=1 (bit 12) on RV32

### 9.5 Zicsr Extension

CSR instructions: CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI

**Implementation details:**
- EX stage reads CSR and computes new value (with forwarding from WB)
- WB stage writes computed value using CSRRW (op=01) — simplifies CSR write path
- CSRRS/CSRRC with rs1=x0 suppresses write (spec-required for read-only CSR access)
- Write to read-only CSR (addr[11:10]=2'b11) with actual write traps as illegal

### 9.6 Zifencei Extension

`FENCE.I` instruction:
- Asserts `fencei_flush` for one cycle
- Flushes pipeline (PC redirected to next sequential instruction)
- In hardware mode: invalidates ifetch buffer, forcing QSPI re-fetch
- Critical for self-modifying code and Linux module loading

---

## 10. Top-Level Interface

### FyraCore Port Map

```verilog
module fyracore(
    input  wire        clk,
    input  wire        rst,
    // Instruction memory interface
    output wire [31:0] imem_addr,      // PC value
    input  wire [31:0] imem_rdata,     // Fetched instruction
    input  wire        imem_ready,     // Fetch data valid
    // Data memory interface
    output wire [31:0] dmem_addr,      // Word-aligned data address
    output wire [31:0] dmem_wdata,     // Store data (shifted to byte lane)
    output wire [3:0]  dmem_wmask,     // Byte lane write mask
    output wire        dmem_we,        // Write enable
    input  wire [31:0] dmem_rdata,     // Load data
    input  wire        dmem_ready,     // Data access complete
    // Interrupts (active-high, directly from CLINT/PLIC)
    input  wire        timer_irq,      // MTIP
    input  wire        external_irq,   // MEIP
    input  wire        sw_irq,         // MSIP
    // CLINT mtime (for CSR time/timeh reads)
    input  wire [63:0] mtime_in,
    // FENCE.I
    output wire        fencei_flush,   // 1-cycle pulse on FENCE.I
    // Debug/trace outputs
    output wire [31:0] dbg_pc,         // PC of retiring instruction
    output wire        dbg_retired,    // Instruction retired this cycle
    output wire [31:0] dbg_instr,      // Instruction encoding
    output wire        dbg_trap        // Trap occurred this cycle
);
```

---

## 11. Build System

### Toolchain

- **Simulator**: Icarus Verilog (`iverilog`) + `vvp`
- **Assembler**: `riscv64-unknown-elf-gcc` with `-march=rv32imac -mabi=ilp32`
- **Linker**: Custom linker script at `tests/linker.ld`

### Key Commands

```bash
# Run a single assembly test
bash scripts/run_asm_test.sh tests/<test>.S [--quiet] [--max-cycles N] [--vcd]

# Run all tests
make test-all

# Run specific component testbench
make test-alu
make test-csr
make test-muldiv
# etc.

# Assemble and run arbitrary .S file
make asm FILE=tests/rv32i_basic.S

# Clean build artifacts
make clean
```

### Assembly-to-Hex Pipeline

1. `scripts/asm2hex.sh` assembles `.S` -> `.elf` -> `.bin` -> `.hex`
2. `scripts/run_asm_test.sh` calls asm2hex, compiles testbench with iverilog, runs simulation
3. The hex file is loaded via `$readmemh` into the memory model at address 0

### Source Files in Build

All modules required for full CPU simulation:
```
src/alu.v  src/branchCtrl.v  src/clint.v  src/compressed_decoder.v
src/controller.v  src/csr.v  src/decoder.v  src/fyracore.v
src/muldiv.v  src/pmp.v  src/regFile.v  src/regs.v  src/signExt.v
tb/memory_model.v  tb/tb_cpu.v
```

---

## 12. Commit History (cpu-fix branch)

The cpu-fix branch contains 45 commits organized into development phases:

### Phase 1: Initial ISA Implementation (commits 1-8)

| Commit | Description |
|---|---|
| `f3dd946` | Extended ALU with M-extension multiply and divide operations (combinational) |
| `e7a61ac` | Updated decoder for all RV32IMCA+Zicsr+Zifencei instruction formats |
| `e1b5cd0` | Updated immediate generation for all instruction formats |
| `ddda767` | Cleaned up branch controller with named ports and expanded tests |
| `34dac44` | Extended controller for full RV32IMCA+Zicsr+Zifencei control signals |
| `c08cfde` | Simplified register file and mux31 |
| `3811956` | Added RV32C compressed instruction decoder |
| `dd0bfb7` | Added M-mode CSR register file with trap and mret handling |

### Phase 2: Pipeline Integration (commits 9-14)

| Commit | Description |
|---|---|
| `8ec0337` | Rewrote FyraCore as 3-stage pipelined RV32IMCA+Zicsr+Zifencei core |
| `03663c2` | Restored memory controller to hardware-calibrated 8MB+8MB address map |
| `2b0c300` | Added simulation memory model with 16 MB dual-port access |
| `6c98c96` | Added full CPU testbench with per-instruction trace output |
| `fbac448` | Added linker script and assembly test programs for all extensions |
| `dc95801` | Added build scripts and Makefile for test automation |

### Phase 3: Pipeline Hardening (commits 15-23)

| Commit | Description |
|---|---|
| `b804bce` | Added gitignore to not accidentally commit build artifacts |
| `59e3833` | Added SYSTEM decode validation and WFI handling in controller |
| `6ca0da9` | Added CSR dual-port interface and address validation |
| `b095210` | Added comprehensive pipeline trap handling, CSR forwarding, and memory handshake |
| `d9b80eb` | Added memory ready signals to memController and memory_model |
| `1bb7e8e` | Added halt loop termination and memory ready wiring in CPU testbench |
| `51f0f93` | Added trap handling test with 13 test cases |
| `ef2474e` | Added pipeline hazard test with 12 test cases |
| `3dbd701` | Added compressed illegal instruction CPU-level test with 12 test cases |

### Phase 4: Linux-Capability Features (commits 24-31)

| Commit | Description |
|---|---|
| `e9b7149` | Added atomic extension edge case tests (tests 16-22) |
| `e6074ed` | Replace combinational multiply/divide with iterative multi-cycle unit (~30-40% area reduction) |
| `0374338` | Fix CSR forwarding for masked registers and csr_test termination |
| `fafdcea` | Unify memory map: 16MB Flash + 16MB RAM, no IMEM/DMEM boundary |
| `fa06bf3` | Populate mtval with faulting address/instruction on traps |
| `a22268b` | Add U-mode privilege support with CSR access control |
| `9efc27c` | Add PMP with 4 regions (TOR+NAPOT) for U-mode memory protection |
| `fb8e107` | Add CLINT, timer/external/software interrupts, and WFI |

### Phase 5: Cleanup and FENCE.I (commit 32)

| Commit | Description |
|---|---|
| `c69509e` | Add FENCE.I memory flush signal and remove unused utility modules |

### Phase 6: Hypercritical Spec Compliance (commits 33-36)

Driven by a line-by-line spec review identifying privilege escalation bugs and interrupt handling errors.

| Commit | Description |
|---|---|
| `2d85c0a` | Fix critical spec violations: MRET from U-mode privilege check, U-mode interrupt gating (MIE only gates M-mode), IRQ MPP save race, mstatus forwarding mask, AMO PMP R+W check |
| `2223805` | Fix CSR spec compliance: unimplemented PMP CSRs read zero instead of trapping, TOR locking, mie/mip/mcounteren write masks |
| `d2d1c5e` | Area optimizations: msip 1-bit register (~700 gates), muldiv count 5-bit, simpler address decode |
| `6e71d49` | Add CLINT to hardware-mode memController and fix Makefile SRC_FILES |

### Phase 7: Spec Compliance Fixes (commits 37-45)

Based on detailed spec audit identifying 5 critical bugs, 5 significant gaps, and 4 minor issues.

| Commit | Description |
|---|---|
| `9769bea` | Fix mcycle/minstret dual-driver synthesis failure (merge counter always blocks) |
| `2a34612` | Fix mtvec mode bits leaking into trap target PC (force direct mode WARL) |
| `e7773bb` | Fix trap cause priority to match spec Table 3.7 |
| `8ab4b55` | Fix CSRRS/CSRRC with rs1=0 performing spurious CSR write |
| `34ec858` | Flag C.SLLI/SRLI/SRAI with shamt[5]=1 as illegal on RV32 |
| `1c816f3` | Trap WFI from U-mode and WFI with invalid fields as illegal instruction |
| `61acf71` | Add time/timeh CSR support by wiring mtime from CLINT |
| `75095cc` | Drive isEbreak in controller and use ctrl_isEbreak in pipeline |
| `1a3f47c` | Address-tag QSPI ifetch buffer to prevent stale instruction consumption |
| `dbf5c07` | Mask reserved pmpcfg A=2'b10 to OFF on write (WARL compliance) |
| `22669f4` | Forward mstatus MIE from WB stage for interrupt gating |
| `72219d6` | Add mconfigptr CSR (0xF15) as read-only zero |
| `14d38cb` | Fix csr_new forward reference error in counter always blocks |
| `5254dbc` | Fix trap_target forwarding missing mtvec WARL mask, fix tb_csr ports |

---

## 13. Design Decisions and Rationale

### 13.1 Why 3 Stages?

Area is the primary constraint for Sky 180nm. A 3-stage pipeline (IF/EX/WB) minimizes pipeline register count while still allowing single-cycle execution for most instructions. Deeper pipelines would add area for diminishing throughput gains on this in-order core.

### 13.2 Why Iterative MulDiv?

The combinational `*`, `/`, `%` operators in the original ALU produced ~10,000+ gate area. The iterative shift-add multiplier and restoring divider reduce this to ~800-1200 gates at the cost of 33-34 cycle latency per operation. This is the highest-impact single area optimization.

### 13.3 Why Direct Mode Only for mtvec?

Vectored mode (mtvec[1:0]=01) adds complexity (BASE + 4*cause for interrupts) with minimal benefit for a simple M+U system. Direct mode is sufficient for Linux boot. mtvec[1:0] is forced to 2'b00 on write (WARL).

### 13.4 Why 4 PMP Regions?

4 regions is the minimum useful count: enough for firmware (OpenSBI) to grant U-mode access to designated memory while protecting M-mode. More regions add area linearly (~2000-3000 gates for 4 regions). Both TOR and NAPOT are supported because NAPOT is needed by most firmware for efficient large-region grants.

### 13.5 Why Address-Tagged Ifetch Buffer?

In hardware mode (QSPI), the ifetch buffer could return stale instructions after a branch/jump. Rather than adding a dedicated `pc_changed` signal, the buffer is tagged with its address and only reports `imem_ready` when the tag matches the requested `imem_addr`. This is more robust and requires no extra port.

### 13.6 Why Unified Memory Map?

Linux requires a flat address space: code executes from flash (XIP), data lives in RAM, and the kernel must read/write/execute across the full space. The original hard IMEM/DMEM split was replaced with a unified Von Neumann view where both instruction fetch and data access can target either Flash or RAM.

### 13.7 Why CLINT in Both Sim and Hw Mode?

In simulation, the CLINT lives in `memory_model.v` (alongside the flat memory array). In hardware mode, it's instantiated inside the `memController.v` hw_mem generate block as an on-chip peripheral (single-cycle access, no QSPI). This ensures timer/software interrupts work identically in both modes.

### 13.8 Why Pre-Compute CSR Values in EX?

The pipeline computes the full CSR write value (read-modify-write) in EX and stores it in `exwb_csr_wdata`. The CSR unit always receives op=CSRRW. This eliminates the need for the CSR unit to implement CSRRS/CSRRC logic and simplifies forwarding (only one value to forward, not a read + modify operation).

### 13.9 IRQ MPP Save Race Fix

A subtle bug: when an interrupt fires from U-mode, the original code set `priv_mode <= 1'b1` immediately on `irq_inject`. The CSR unit (executing one cycle later on `csr_trap_signal`) would then see `priv_mode=1` and save `MPP=11` (M-mode) instead of `MPP=00` (U-mode). MRET after the interrupt would return to M-mode instead of U-mode. Fix: removed the separate `irq_inject` privilege assignment; the `csr_trap_signal` path handles both traps and interrupts, reading the correct old `priv_mode` via non-blocking assignment semantics.

---

## 14. Known Limitations

1. **No S-mode or MMU**: No virtual memory support. Linux must run in flat physical addressing mode (uClinux-style or CONFIG_RISCV_M_MODE).
2. **No interrupt delegation**: All traps go to M-mode. No medeleg/mideleg CSRs.
3. **No vectored interrupt mode**: mtvec mode bits forced to 00 (direct mode only).
4. **CSRRW with rd=x0 still reads the CSR**: Spec says suppress read to avoid side effects. No CSRs in this implementation have read side effects, so functionally harmless but technically non-compliant.
5. **4 PMP regions only**: Sufficient for basic M/U isolation but limits complex memory layouts.
6. **No hardware multiply optimization**: MulDiv takes 33-34 cycles for all multiply operations (no early termination).
7. **FENCE is NOP**: No data cache to fence. Only FENCE.I has functional effect (ifetch buffer invalidation).
8. **Single-hart only**: mhartid = 0, no multi-core support.
9. **No debug module**: No JTAG/debug interface (trace outputs only).
