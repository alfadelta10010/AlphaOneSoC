# FyraCore / AlphaOneSoC verification plan

Branch `verif-upgrade_alfadelta10010`, started 2026-10-18 at `484ec59`.
This file is the plan and its status: what every bench claims, what it
really checks, how it could pass on a broken design, the mutants that
measure it, and what is still open.

Sources of intent, in this order: the RISC-V Unprivileged and Privileged
specifications (`docs/RISCV-spec.html`, version 20260409), the W25Q128JV-DTR
and APS6404L datasheets in `docs/`, `docs/FyraCore_CPU_Reference.md` (cited
as "CPU ref"), `docs/soc-architecture.md`, `docs/pins-and-peripherals.md`,
`docs/qspi-memories.md`, `macro/rf_top/README.md`, and the interface
comments at the top of each module (the contract a caller codes against).
The RTL is never the source of an expected value. Spike
(`/tools/rv32-isa-sim/bin/spike`) is the independent ISA model for the
core. Where a contract is only a module's own comment, the requirement says
so; where nothing specifies a behaviour, nothing is checked for it (see
section 5).

Status column: **P** passing with a test that has been seen to fail (a
mutant it kills), **p** passing, never seen to fail, **O** open.

## 1. Requirements

`timing`: C = cycle-exact (a documented latency), B = bounded,
E = eventual, A = architectural (no clock count).

### 1.1 Datapath units

| ID | Requirement (source) | timing | Test | Checker |
|---|---|---|---|---|
| REQ-ALU-001 | ADD, SUB, SLT, SLTU, XOR, OR, AND per Unpriv 2.4 for the codes the controller issues | A | tb_alu | RV32I model; corners x corners, 200k seeded random |
| REQ-BR-001 | BEQ/BNE/BLT/BGE/BLTU/BGEU per Unpriv 2.5; the comparator's diff, lt_signed, lt_unsigned (branchCtrl header) | A | tb_branchCtrl | RV32I model; corners, 100k seeded random |
| REQ-IMM-001 | I/S/B/U/J immediates per Unpriv 2.3; OP-IMM shifts give shamt in imm[4:0] | A | tb_signExt | format model, 4096 random words x 128 opcodes |
| REQ-DEC-001 | rd/rs1/rs2/funct3/funct7 per format; a register field the format lacks reads 0 (fyracore masks reads with it) | A | tb_decoder | format model, 4096 random words x 128 opcodes |
| REQ-RFF-001 | rf_fields names every register EX reads, 32-bit and every legal compressed encoding (CPU ref 2.1) | A | tb_rf_fields | cross-check against decoder(compressed_decoder) |
| REQ-RVC-001 | every legal RV32C encoding expands to the instruction the C chapter defines | A | tb_compressed_decoder | field-decode/re-encode RVC model, all 49,152 encodings |
| REQ-RVC-002 | reserved/illegal: ADDI4SPN nzuimm=0 (incl. all-zero), ADDI16SP nzimm=0, LUI nzimm=0, LWSP rd=0, JR rs1=0, shamt[5]=1, SUBW/ADDW/reserved CA, F/D, Zcb slots; HINTs legal (CPU ref 9.4) | A | tb_compressed_decoder | same model |
| REQ-CTL-001 | legality of every {opcode, funct3, funct7} for RV32IMA+Zicsr+Zifencei, and every control output of every legal encoding (port contracts of controller/alu/muldiv) | A | tb_controller | ISA model over all 2^17 inputs |
| REQ-CTL-002 | an illegal encoding requests no memory access (controller.v; CPU ref 3.1) | A | tb_controller | same sweep |
| REQ-MD-001 | MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU per Unpriv M, incl. x/0, -x/0, INT_MIN/-1 | A | tb_muldiv, m_corners | model; 40k biased random; Spike |
| REQ-MD-002 | SLL/SRL/SRA by b[4:0] | A | tb_muldiv, m_corners | model; every shamt with junk above bit 4 |
| REQ-MD-003 | handshake: busy from the cycle after start to done; done one cycle as busy drops; one done per start; result held until the next start (muldiv.v header) | C | tb_muldiv | per-clock monitor, inputs scrambled after start |
| REQ-MD-004 | done 34 / 36 / 2+shamt cycles after start (CPU ref 9.2) | C | tb_muldiv | per-operation latency check |
| REQ-MD-005 | reset mid-operation leaves the unit idle and the next operation right | B | tb_muldiv | reset at every point of a divide |
| REQ-RF-001 | synchronous read, held until the next edge (regFile header) | C | tb_regFile | shadow model |
| REQ-RF-002 | write-first on both ports without the macro's own collision answer | C | tb_regFile (+RF_COLLIDE_X) | shadow model |
| REQ-RF-003 | x0 never written | A | tb_regFile | shadow model |

### 1.2 CSR, PMP, CLINT

| ID | Requirement (source) | timing | Test | Checker |
|---|---|---|---|---|
| REQ-CSR-001 | reset values (CPU ref 6.1, 7) | A | tb_csr | model; also after every random reset |
| REQ-CSR-002 | read-only / read-zero CSRs (CPU ref 7.1, 7.3, 7.5, 7.7) | A | tb_csr | model |
| REQ-CSR-003 | WARL of mstatus, mie, mtvec, mcounteren, mcountinhibit, mepc (CPU ref 7.3-7.4) | A | tb_csr | model, random writes |
| REQ-CSR-004 | misa: only C writable; a clear refused with a misaligned next pc (CPU ref 7.2) | A | tb_csr, misa_adjacent | model; Spike |
| REQ-CSR-005 | pmpcfg0 legalisation and locks, pmpaddr locks incl. TOR+L of i+1 (CPU ref 6.3, Priv 3.7.1) | A | tb_csr | model |
| REQ-CSR-006 | mcycle every clock / minstret per instret_inc, inhibits, 64-bit carry (CPU ref 7.5) | C | tb_csr | model each clock |
| REQ-CSR-007 | a counter write replaces that clock's increment, other half kept; the clock after an mcycle write not counted (CPU ref 9.5, csr.v) | C | tb_csr, cnt_xhalf, cnt_xcycle | model; Spike / expect |
| REQ-CSR-008 | trap entry: mepc, mcause, mtval, MPIE<-MIE, MIE<-0, MPP<-priv (Priv 3.1.6.1) | A | tb_csr, trap_nested | model; Spike |
| REQ-CSR-009 | MRET: MIE<-MPIE, MPIE<-1, MPP<-U, MPRV<-0 unless MPP=M (Priv 3.3.2) | A | tb_csr | model |
| REQ-CSR-010 | mip = the live MSIP/MTIP/MEIP wires, unwritable (CPU ref 7.4) | A | tb_csr, mip_ro | model; Spike |
| REQ-CSR-011 | csr_addr_valid exactly for the implemented CSRs, U aliases gated by mcounteren (CPU ref 7, 6.2) | A | tb_csr | all 4096 addresses x 2 privileges x 8 mcounteren |
| REQ-CSR-012 | time/timeh = mtime_in; cycle/instret aliases = the counters (CPU ref 7.6) | A | tb_csr | model |
| REQ-CSR-013 | wval_out (the trace's logged value) = the post-write value (CPU ref 2.3) | A | tb_csr | model on every write |
| REQ-PMP-001 | OFF/TOR/NA4/NAPOT matching on PA[33:2] (Priv 3.7.1) | A | tb_pmp | model counting trailing ones; edge-biased random |
| REQ-PMP-002 | lowest matching entry decides; no match M allowed / U refused; L binds M; all requested permissions needed | A | tb_pmp | same |
| REQ-CLINT-001 | register map, reset values, byte lanes, mtime write replaces the increment, 64-bit carry (CPU ref 4, clint.v) | C | tb_clint | cycle model |
| REQ-CLINT-002 | timer_irq = mtime >= mtimecmp, one clock late; sw_irq = msip | C | tb_clint | cycle model |

### 1.3 Core (directed suite against Spike, `tests/directed`)

| ID | Requirement (source) | timing | Test (MANIFEST) | Checker |
|---|---|---|---|---|
| REQ-ISA-001 | RV32IMAC+Zicsr+Zifencei results (Unpriv) | A | every `spike` line | full-trace compare with Spike |
| REQ-TRAP-001 | synchronous trap priority (CPU ref 8.1) | A | causes, illegal_*, c_misalign, enc_probe | Spike |
| REQ-TRAP-002 | mepc/mcause/mtval of every cause | A | causes, lw_misalign, pmp_straddle, u_straddle | Spike |
| REQ-TRAP-003 | a trap inside a trap handler | A | trap_nested (new) | Spike |
| REQ-IRQ-001 | interrupt priority and enables (Priv 3.1.9) | A | mie_enable, mret_irq, t_irq* | Spike / expect |
| REQ-IRQ-002 | interrupt at a trapping instruction, during an M op, during a stalled access, at MRET: each taken once, mepc an instruction boundary | A | irq_at_trap (new), mret_irq, t_mulirq, irq_stress, irq_stall (SoC) | expect / Spike / SoC bench |
| REQ-LRSC-001 | reservation policy (CPU ref 9.3) | A | lrsc_*, sc_trap, lr_sb_sc | Spike / expect |
| REQ-PMP-101 | PMP in the pipeline | A | pmp_*, mprv*, *_straddle | Spike |
| REQ-CNT-001 | counters through the pipeline | A | cnt_* | Spike / expect |
| REQ-MEM-001 | request held unchanged until ready (CPU ref 5.1) | C | every run | memory_model handshake checker |
| REQ-MEM-002 | fetch only inside flash/PSRAM and halfword-aligned; data only inside a mapped window and word-aligned; never a write to flash; byte lanes a legal size/offset pattern, loads included; store data replicated; read data only for a requested access (CPU ref 5.1, 4) | C | every run | memory_model request checker (new) |
| REQ-MEM-003 | every load/store/LR/SC/AMO retire is exactly its transaction: word address, lanes from size and offset, direction, the stored bytes in their lanes; no transaction without one; a failing SC makes none (CPU ref 5.1, 9.3) | C | every run | tb_rivercore bus check (new) |
| REQ-RF-101 | the macro is read with the EX instruction's registers from its second EX cycle | C | every run | tb_rivercore rf check |

### 1.4 SoC

| ID | Requirement (source) | timing | Test | Checker |
|---|---|---|---|---|
| REQ-QSPI-001 | PSRAM QPI 0x0B/0x38, flash 0xEB mode 0xFF, no flash write, tCPH/tCEM/tRST, SCK limits (soc-arch, datasheets) | C | tb_qspi, tb_qspi_stress | Pmod model |
| REQ-QSPI-002 | the start-up sequence undoes every hand-over state | B | tb_qspi hand-over runs, +RESETS | Pmod model |
| REQ-MEMC-001 | data-first; split PSRAM fetch at 1 KB pages; whole-word loads; enabled bytes only stored | A | tb_qspi, tb_qspi_stress | shadow memory |
| REQ-MEMC-002 | every request is served within a bound; no starvation | B | tb_qspi_stress | per-request wait bound + traffic floor (new) |
| REQ-UART-* | 16550 subset (pins-and-peripherals 2) | C | tb_uart | spec models |
| REQ-GPIO-* | GPIO + SPI mode 3 (pins-and-peripherals 3-4) | C | tb_gpio | spec models |
| REQ-BUS-001 | an IO target drops ready only while selected; only a CLINT store writes the CLINT | C | tb_soc_periph | per-clock checks, clint_decode |
| REQ-TT-001 | wrapper reset and pins (pinout table) | C | tb_tt_um | pin checks |

## 2. Audit of the benches as found (at 484ec59)

What each claimed, what it really checked, and how it could pass on a
broken design. "Mutants" refers to section 4.

| Bench | Claimed | Really checked | Could pass broken because |
|---|---|---|---|
| Makefile `run_tb` | fails on a failing unit bench | `vvp | tee`, then grep ^FAIL/^TIMEOUT | the pipe dropped vvp's exit status, so a `$fatal` passed; ERROR/FATAL lines and a bench that stopped without a summary passed (no PASS line was required) |
| tb_alu | ALU ops | 43 hand-picked vectors | no random; comparator outputs unchecked; "unused code = 0" pinned the RTL, not a requirement |
| tb_branchCtrl | branch conditions | 39 vectors | diff/lt outputs unchecked; reserved funct3 pinned to the RTL's 0 |
| tb_signExt | immediates | 32 vectors | few bit patterns: a misplaced J/B/S immediate bit whose two candidate positions were equal in every vector passed (4 of 8 mutants) |
| tb_decoder | fields | 26 vectors, one per class | register numbers below 16 wherever rs2 was checked; test-decoder still killed all 7 decoder mutants, DE01 only through tb_rf_fields' cross-check |
| tb_rf_fields | rf_fields | all compressed + 65k 32-bit words, vs decoder(compressed_decoder) | cross-check of two DUT blocks: a fault shared by both passes (tb_compressed_decoder now covers the expansion independently) |
| tb_controller | decode | 75 directed + three structural properties over 2^17 | memSize/memUnsigned, I-type aluOp, csrOp of CSRRS/C, csrSrc of the immediate forms and amoOp never checked |
| tb_regFile | regFile | shadow model, 20k random, write-first, x0, three variants | sound |
| tb_csr | CSR file | 28 checks | PMP CSRs, WARL masks, MPP legalisation, MRET's MPRV rule, mepc[1] masking, misa refusal, counter carries/inhibit, U aliases, mip, csr_addr_valid sweep: all unchecked |
| tb_inc64 | carry flop | 400k checks vs q+1 | sound |
| tb_compressed_decoder | RVC | 51 checks, mostly opcode+funct3 with zero immediates | immediate scrambles in almost every format passed; the C.ADD check used `&&` (failed only if rd and rs1 were both wrong) |
| tb_muldiv | M unit | 65 directed results | no handshake, latency, hold or reset checks; x/0 only with a positive dividend |
| tb_qspi | memory path | directed shapes, Pmod model protocol checks, shadow arrays | sound for what it covers |
| tb_qspi_stress | core-shaped traffic | 400k random clocks, shadow memory, resets | no wait bound or traffic floor: a deadlock part-way still printed PASS |
| tb_uart / tb_gpio | peripherals | spec models, seeds, coverage floors, check counts | sound |
| tb_soc_periph | SoC + devices | programs, per-clock bus checks | sound for what it covers |
| tb_tt_um | pins | reset, pins, three resets | sound |
| test-cpu | "compile and run CPU" (help text) | compiles tb_cpu only | runs nothing |
| tests/directed run.sh | full-trace Spike compare | ERROR line, DUT-ABORT, empty dump, X, tohost, full trace | the trace prints accesses from WB-stage internals, not the bus: wrong lanes, unreplicated store data or a stray transaction passed unless read back; 99% of each run was memory_model's zero-fill |
| memory_model | ideal memory + handshake checker | hold-until-ready on both ports | gave valid data and ready without a request; silently dropped writes to flash and unmapped space; never checked lanes, alignment or windows |

## 3. Threat model -> tests

| Threat | Where it is hunted |
|---|---|
| reset mid-operation / mid-transaction | tb_muldiv (every point of a divide), tb_csr (random resets), tb_clint, tb_qspi_stress +RESETS, tb_tt_um, tb_gpio, tb_uart. Not at core level (section 5) |
| first access right after reset | tb_csr reset sweep, tb_clint, t_reset |
| counters at max / wrap / 64-bit split | tb_csr (rollover-biased writes), tb_inc64, tb_clint, cnt_xhalf |
| signed/unsigned, x/0, INT_MIN/-1, shifts >= 32 | tb_alu, tb_branchCtrl, tb_muldiv, m_corners (new) |
| address window edges, straddles, misaligned | straddle_*, pmp_straddle, lw_misalign, memory_model request checker, tb_pmp |
| simultaneous events | irq_at_trap (new), mret_irq, t_mulirq, irq_stall, tb_csr (trap with write) |
| back-pressure, max throughput, ready held off | memory_model wait-state variants, tb_qspi_stress, tb_uart, tb_gpio |
| illegal / reserved encodings | tb_controller (2^17), tb_compressed_decoder (all), enc_probe, illegal_* |
| trap inside a handler | trap_nested (new) |
| x0 | tb_regFile, tb_decoder (absent fields), rf_* |
| hazards at every distance | rf_raw_stall, rf_capture, rs2_snoop, m_corners |
| byte lanes / store data on the bus | memory_model request checker, tb_rivercore bus check (new) |

## 4. Mutation results

239 faults (tb/mutate/mutants.py), runner `python3 tb/mutate/run.py`.
"before" = benches at 484ec59 frozen in build/before (plus only the
memory_model speed-up and runner knobs); "after" = this branch. Directed
"after" was rerun only on the 68 before-survivors (the suite only gained
tests and checks, so a before-kill stays a kill). SoC-file mutants were
scored "before" only.

| bench | before | after |
|---|---|---|
| test-alu | 10/14 | 9/14 (ALU07 now unchecked: unspecified) |
| test-branchctrl | 4/7 | 6/7 |
| test-signext | 4/8 | 6/8 |
| test-decoder (+rf_fields) | 11/29 | 11/29 (CD mutants change its reference too) |
| test-controller | 8/18 | 18/18 |
| test-compressed | 9/18 | 18/18 |
| test-muldiv | 10/16 | 15/16 |
| test-csr | 4/29 | 29/29 |
| test-pmp | - | 12/12 |
| test-clint | - | 8/8 |
| formal csr | - | 6/29 (the WARL-breaking ones) |
| test-regfile | 5/5 | 5/5 |
| directed core | 138/206 | 193/206 |
| core files, any bench | 155/206 (75%) | 193/206 (94%) |
| SoC files, any bench (before only) | 30/33 | - |

Core survivors after: equivalent or unspecified ALU07, BR06, SE04,
SE05, MD07, RG01, RG04 (x0 masked), FC02 (csr_wb_hazard subsumed by
ex_wait), FC27, FC49; real gaps FC25 (mem_align's bytes 2 and 3 share
a sign), FC45 (U-mode WFI with TW=0 needs an expect test; Spike traps
it), FC32 (pmpaddr refetch). SoC survivors before: GP03, TT01
(equivalent), UA07 (narrow timing).

## 5. Not verified, and why

- Formal: no SMT solver for sby/smtbmc on this machine; yosys's own `sat`
  is available but unused so far.
- Core-level reset in the middle of a program: tb_rivercore has no way to
  drop a reset mid-run, and Spike's trace would not apply.
- Gate level: no netlist runs in this pass.
- Behaviour nothing specifies is not checked: ALU output for codes never
  issued, branch result for reserved funct3, signExt's SYSTEM output,
  decoder funct3/funct7 for formats without them (spec-ambiguities in the
  agent memory).
