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
| REQ-RFF-001 | rf_fields names every register EX reads, 32-bit and every legal compressed encoding (CPU ref 2.1) | A | tb_rf_fields | model of the C chapter (per-instruction table, independent of the decoder, WO-04) and a cross-check against decoder(compressed_decoder) |
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
| REQ-RF-003 | x0 never written | A | tb_regFile; formal core_hold | shadow model; proof on the core (WO-06) |

### 1.2 CSR, PMP, CLINT

| ID | Requirement (source) | timing | Test | Checker |
|---|---|---|---|---|
| REQ-CSR-001 | reset values (CPU ref 6.1, 7) | A | tb_csr | model; also after every random reset |
| REQ-CSR-002 | read-only / read-zero CSRs (CPU ref 7.1, 7.3, 7.5, 7.7) | A | tb_csr | model |
| REQ-CSR-003 | WARL of mstatus, mie, mtvec, mcounteren, mcountinhibit, mepc (CPU ref 7.3-7.4) | A | tb_csr; formal csr | model, random writes; k-induction proof |
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
| REQ-WFI-001 | WFI: M-mode waits for an individually enabled pending interrupt (a NOP if none is enabled), mepc on wake = the next instruction; U-mode with TW=0 a NOP that never waits; U-mode with TW=1 illegal (CPU ref 8.5, 1a845f5; Priv 3.1.6.6, 3.3.3) | A | wfi_slow, wfi_umode, rf_wfi_hold, core_reset | expect |
| REQ-LRSC-001 | reservation policy (CPU ref 9.3) | A | lrsc_*, sc_trap, lr_sb_sc | Spike / expect |
| REQ-PMP-101 | PMP in the pipeline | A | pmp_*, mprv*, *_straddle | Spike |
| REQ-CNT-001 | counters through the pipeline | A | cnt_* | Spike / expect |
| REQ-MEM-001 | request held unchanged until ready (CPU ref 5.1) | C | every run; formal core_hold | memory_model handshake checker; k-induction proof on both ports (WO-06) |
| REQ-MEM-002 | fetch only inside flash/PSRAM and halfword-aligned; data only inside a mapped window and word-aligned; never a write to flash; byte lanes a legal size/offset pattern, loads included; store data replicated; read data only for a requested access (CPU ref 5.1, 4) | C | every run; formal core_req | memory_model request checker (new); bounded proof, 10 cycles from reset (WO-06); the core-level window for the CLINT is Spike's 48 KB (0x0200_0000-0x0200_BFFF, WO-11); pma_edges checks both of its edges |
| REQ-MEM-003 | every load/store/LR/SC/AMO retire is exactly its transaction: word address, lanes from size and offset, direction, the stored bytes in their lanes; no transaction without one; a failing SC makes none (CPU ref 5.1, 9.3) | C | every run | tb_rivercore bus check (new) |
| REQ-RST-001 | a reset in the middle of a program, on every phase of LR, DIV, a store, an AMO, ECALL, the M-mode WFI wait and the timer interrupt, restarts a clean boot at boot_addr | B | core_reset (160 resets, tb_rivercore +RESETS) | self-check: x11 counts the boots |
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
| REQ-SOCTB-001 | SoC program/bench contract: FINISH at syscon +0x0 with QEMU sifive_test codes (0x5555 pass, (code << 16) \| 0x3333 fail, 0x7777 reboot), word stores; EVENT/VALUE/VALUE2 at +0x7F0/+0x7F4/+0x7F8, +0x7FC spare; output drained before FINISH; requires the syscon to leave those words and 0x4004/0xBFF8 RAZ/WI (WO-12 R-MB-1..4) | - | tb_soc_periph (all eight programs) | four negative-control programs (WO-12 acceptance) |
| REQ-TT-001 | wrapper reset and pins (pinout table) | C | tb_tt_um | pin checks |

#### syscon (REQ-SYS-*, from WO-14's list)

Status per the legend above. "Killer" names a mutant of section 4 that the
test kills (`build/mut/syscon-all.tsv`).

| ID | Requirement (short; full text in WO-14) | timing | Test | Checker | Status |
|---|---|---|---|---|---|
| REQ-SYS-001 | register map: FINISH, RESET_CAUSE (W1C), BOOT_MODE, CHIP_ID, STRAPS, reserved words RAZ/WI | C | tb_syscon (WO-14), syscon_regs.S via tb_syscon_soc (WO-15) | spec model; per-load model in tb_syscon_soc | P (SY10, SY11, SY16-SY19) |
| REQ-SYS-002 | every other word reads 0, ignores writes, no alias (mailbox, 0x4004, 0xBFF8, 0x200..0x2FF) | C | tb_syscon exhaustive offset sweep (WO-14, 14a), syscon_regs.S | spec model | P (SY15, SY16, WD07) |
| REQ-SYS-003 | FINISH acts on 0x7777 / 0x5555 / 0x3333 only, and only with lanes 0 and 1 written | C | tb_syscon, syscon_regs.S, syscon_fail.S | spec model | P (SY01, SY02, SY03, SY07) |
| REQ-SYS-004 | reboot holds everything but syscon's sticky state for exactly two edges; every block restarts in its reset state | C | tb_syscon (timing), syscon_reboot.S (five boots), tb_tt_um | spec model; per-boot state checks | P (SY04, SY05, AS01-AS08) |
| REQ-SYS-005 | across a reboot RESET_CAUSE gains SOFT or WDT, BOOT_MODE and the strap latch are kept | C | tb_syscon, syscon_reboot.S, syscon_wdt.S | spec model | P (SY08, SY09, WD14) |
| REQ-SYS-006 | a pin reset sets RESET_CAUSE = PIN, BOOT_MODE = 0, re-latches the strap, ends a reboot or power-off in progress, disables the watchdog | C | tb_syscon, syscon_pinreset.S (WO-16) | spec model | P (SY11, SY21) |
| REQ-SYS-007 | the QSPI engine samples the strap only while the pin reset is high; STRAPS reads the latched value | C | tb_syscon, syscon_strap.S, tb_tt_um (WO-17) | spec model; flash and PSRAM read behaviour | P (SY12, SY13, SY18, AS05) |
| REQ-SYS-008 | power-off / fail: held until rst, QSPI pins released, no bus transfer, nothing but rst_n changes anything, no WDT | C | tb_syscon (inputs thrashed while off), syscon_poweroff.S, syscon_fail.S, tb_tt_um | spec model; pin checks | P (SY06, WD16) |
| REQ-SYS-009 | while the SoC is held no write reaches syscon or the watchdog | C | tb_syscon (WO-14) | spec model | P (SY14, killed by tb_syscon only) |
| REQ-SYS-010 | syscon never holds `ready` low | C | tb_syscon_soc (per clock) | bus check | p (no mutant) |
| REQ-SYS-011 | `rst_soc` is a function of rst and flops only, and a synchronous reset only | - | formal `syscon_comb` (bounded, 24 cycles), `soc_rst_sync` (structural) (WO-19) | miter; netlist walk | P (SY20 by syscon_comb; soc_rst_sync by a hand-made async CLINT copy, not a catalogue fault) |
| REQ-SYS-012 | at the pins a reboot looks like a pin reset after rst_n rises: uio_oe = 0, uo_out = 0x39 while held, one transition per pin | C | tb_tt_um, tt_pins.S (WO-17) | pin checks | P (SY04, SY05, SY06, AS02-AS05) |
| REQ-SYS-013 | Linux's syscon-poweroff / -reboot / -reboot-mode and dw_wdt sequences work unchanged | A | syscon_regs.S, syscon_wdt.S, tb_syscon | spec model | p (no mutant targets the driver sequences) |
| REQ-SYS-014 | watchdog window, DW layout, lane 0 only; CR EN, TORR, CRR key 0x76, COMP_PARAMS_1 | C | tb_syscon, syscon_wdt.S | spec model | P (WD02, WD07, WD08, WD11, WD12, WD13) |
| REQ-SYS-015 | timeout in mtime counts: after the last kick, more than 2^(16+TOP) and at most 1.5 x 2^(16+TOP) + 1 clocks (never early unless software writes mtime: time is counted in mtime counts) | C | tb_syscon (all 16 TOPs, scaled tap), syscon_wdt.S (TOP 0, real scale), syscon_wdt_split.S | spec model; reboot-time bounds | P (WD03, WD04, WD09, WD10, AS07) |
| REQ-SYS-016 | expiry = a two-edge reboot that sets WDT (sticky); the watchdog comes back disabled with TOP 15 | C | tb_syscon, syscon_wdt.S, tb_tt_um | spec model | P (WD05, WD06, WD14, WD15) |
| REQ-SYS-017 | once enabled, EN cannot be cleared by any write | C | tb_syscon | spec model | P (WD01) |
| REQ-SYS-018 | same-cycle cases: fire with a W1C of WDT, fire with a FINISH reboot, fire with a power-off | C | tb_syscon (WO-14, 14a) | spec model | p (no mutant isolates them) |
| REQ-SYS-019 | no fire while the SoC is held (SA-009) | C | tb_syscon k = 16..18 (WO-14a), formal `syscon_gate` (WO-19) | spec model; proof (P1, P2) | P (WD16, by both) |

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
| tb_rf_fields | rf_fields | all compressed + 65k 32-bit words, vs decoder(compressed_decoder) | cross-check of two DUT blocks: a fault shared by both passed (closed: tb_compressed_decoder covers the expansion independently, and WO-04 added a model of the C chapter; RFF01-04 are killed) |
| tb_controller | decode | 75 directed + three structural properties over 2^17 | memSize/memUnsigned, I-type aluOp, csrOp of CSRRS/C, csrSrc of the immediate forms and amoOp never checked |
| tb_regFile | regFile | shadow model, 20k random, write-first, x0, three variants | sound |
| tb_csr | CSR file | 28 checks | PMP CSRs, WARL masks, MPP legalisation, MRET's MPRV rule, mepc[1] masking, misa refusal, counter carries/inhibit, U aliases, mip, csr_addr_valid sweep: all unchecked |
| tb_inc64 | carry flop | 400k checks vs q+1 | sound |
| tb_compressed_decoder | RVC | 51 checks, mostly opcode+funct3 with zero immediates | immediate scrambles in almost every format passed; the C.ADD check used `&&` (failed only if rd and rs1 were both wrong) |
| tb_muldiv | M unit | 65 directed results | no handshake, latency, hold or reset checks; x/0 only with a positive dividend |
| tb_qspi | memory path | directed shapes, Pmod model protocol checks, shadow arrays | sound for what it covers |
| tb_qspi_stress | core-shaped traffic | 400k random clocks, shadow memory, resets | no wait bound or traffic floor: a deadlock part-way still printed PASS |
| tb_uart / tb_gpio | peripherals | spec models, seeds, coverage floors, check counts | sound |
| tb_soc_periph | SoC + devices | programs, per-clock bus checks | sound for what it covers; could pass broken because the mailbox decoded addr[3:2] only, aliasing the whole syscon window onto four words (closed by WO-12) |
| tb_tt_um | pins | reset, pins, three resets | sound |
| test-cpu | "compile and run CPU" (help text) | compiles tb_cpu only | runs nothing |
| tests/directed run.sh | full-trace Spike compare | ERROR line, DUT-ABORT, empty dump, X, tohost, full trace | the trace prints accesses from WB-stage internals, not the bus: wrong lanes, unreplicated store data or a stray transaction passed unless read back; 99% of each run was memory_model's zero-fill |
| memory_model | ideal memory + handshake checker | hold-until-ready on both ports | gave valid data and ready without a request; silently dropped writes to flash and unmapped space; never checked lanes, alignment or windows |

## 3. Threat model -> tests

| Threat | Where it is hunted |
|---|---|
| reset mid-operation / mid-transaction | tb_muldiv (every point of a divide), tb_csr (random resets), tb_clint, tb_qspi_stress +RESETS, tb_tt_um, tb_gpio, tb_uart, and at core level core_reset (tb_rivercore +RESETS) |
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
| a block left on the wrong reset (pin reset where `rst_soc` belongs) | tb_syscon_soc programs syscon_reboot, syscon_pinreset and syscon_wdt, tb_tt_um (AS01-AS08) |
| the strap re-sampled after the pin reset | tb_syscon, syscon_strap.S, tb_tt_um (SY12, SY13, SY18, AS05) |
| FINISH by a byte store, or a wrong lane | tb_syscon, syscon_regs.S (SY02, SY03) |
| an alias of a register (decode too wide) | tb_syscon exhaustive offset sweep, syscon_regs.S (SY15, SY16, WD07) |
| the pins during a reboot or power-off | tb_tt_um (SY04-SY06; the glitch check itself needs the SDF netlist, section 5) |
| a watchdog fire in a held cycle (SA-009) | tb_syscon k = 16..18, formal `syscon_gate` (WD16) |
| a combinational path from the bus to `rst_soc`; an asynchronous use of it | formal `syscon_comb` (SY20), `soc_rst_sync` (hand-made async CLINT copy) |

## 4. Mutation results

295 faults (250 + 45 syscon faults of WO-18; tb/mutate/mutants.py), runner `python3 tb/mutate/run.py`.
"before" = benches at 484ec59 frozen in build/before (plus only the
memory_model speed-up and runner knobs); "after" = this branch. after-dir.tsv
and after-soc.tsv were regenerated on 2026-10-22, after the 10-21 build/ wipe, and
score all 206 directed faults and all 33 SoC faults again. The 10 faults added by WO-00 and
WO-04 (FC80-85, RFF01-04) were scored on their own (build/mut/wo-*.tsv).

Every number below is `run.py --report` on the concatenation, in this order,
of build/mut/before.tsv, after-unit.tsv, after-dir.tsv, after-formal.tsv,
after-soc.tsv, after-dirsoc.tsv, wo-00.tsv, wo-01.tsv, wo-01b.tsv, wo-02.tsv,
wo-04.tsv, wo-06.tsv, wo-10.tsv, wo-12.tsv, wo-18.tsv (172 rows, the sandbox
campaign) and wo-19.tsv (82 rows, the formal harnesses on the syscon and AS
faults); a later row replaces an earlier one for the same fault and bench.
The result is build/mut/all-wo19.tsv and its report build/mut/report-all-wo19.txt.
FC86 (WO-10) was scored for this table: build/mut/wo-10.tsv, KILLED by
wfi_umode. The syscon rows use build/mut/syscon-all.tsv (wo-18.tsv plus
wo-19.tsv), whose report is the 45 faults alone.

| bench | before | after |
|---|---|---|
| test-alu | 10/14 | 9/14 (ALU07 now unchecked: unspecified) |
| test-branchctrl | 4/7 | 6/7 |
| test-signext | 4/8 | 6/8 |
| test-decoder (+rf_fields) | 11/29 | 15/33 (RFF01-04 killed by WO-04; the CD mutants change its reference too) |
| test-controller | 8/18 | 18/18 |
| test-compressed | 9/18 | 18/18 |
| test-muldiv | 10/16 | 15/16 |
| test-csr | 4/29 | 29/29 |
| test-pmp | - | 12/12 |
| test-clint | - | 8/8 |
| formal csr | - | 6/29 (the WARL-breaking ones: CS01-04, CS07, CS11) |
| formal core_hold / core_req | - | 4/9 and 3/8 of the 11 core mutants tried (9/11 by either; FC22, FC25 survive both: directed covers them) |
| test-uart (UA mutants of WO-02) | - | 7/7 |
| test-regfile | 5/5 | 5/5 |
| directed core | 138/206 | 181/213 (the 206 plus FC80-86; FC86 is killed by wfi_umode; the 193/206 shown from e4de29c to this commit was the core-files any-bench count copied into this row; directed was 173/206 (after-dir.tsv), 176/206 with WO-01's tests; the 95% any-bench figure was right) |
| core files, any bench | 155/206 (75%) | 207/217 (95%) (adds FC86, killed) |
| SoC files, any bench | 30/33 (before only) | 76/78: 31/33 of the old faults (UA07 killed by WO-02) and 45/45 syscon faults |
| unit test-syscon (the 37 faults in syscon.v) | - | 37/37 |
| soc test-syscon-soc (45 syscon faults) | - | 38/45 (survivors SY14 WD02 WD08 WD09 WD10 WD11 WD16: the unit bench kills them) |
| soc test-wrapper (45 syscon faults) | - | 23/45 |
| soc test-soc-periph (45 syscon faults) | - | 3/45 (SY01, SY06, SY16 only: it was not built to see syscon) |
| formal syscon_comb | - | 1/37 (SY20; bounded to 24 cycles) |
| formal syscon_gate | - | 2/37 (WD05, WD16) |
| formal soc_rst_sync | - | 0/8 on the AS faults (none makes a reset asynchronous); killed by a hand-made async CLINT copy (not in the catalogue) |

### 4.1 Work orders WO-00 to WO-06, WO-10 to WO-12 and WO-14 to WO-23 (all closed)

| WO | What | Result |
|---|---|---|
| WO-00 | mutants for resets that work from power-on only (FC80-85) and for rf_fields (RFF01-04) | 10 faults added (249 in all, 250 with FC86 of WO-10); FC80-85 survived the suite as it was |
| WO-01 A | directed `load_signs`, `wfi_umode`, `pmpaddr_refetch` | kill FC25, FC45, FC32 |
| WO-01 B | directed `core_reset`: 160 mid-program resets (needs WO-03) | kills FC80, FC82, FC83, FC85 |
| WO-02 | tb_uart late-break sweep across the 8.5-bit boundary (136 clocks per divisor unit) | UA07 killed (7/7 UA faults) |
| WO-03 | `+RESETS`/`+RESET_AT`/`+RESET_STRIDE`/`+RESET_LEN` in tb_rivercore; memory_model idle while rst is high | no change to the dump without the plusargs |
| WO-04 | tb_rf_fields checked against a per-instruction model of the C chapter | RFF01-04 killed (test-decoder 7/7 with DE01-03) |
| WO-05 | Pmod RAM no longer zero-filled (a 16 MB loop, about 6 s per run); never-written bytes read 0, DUT-written X stays X | wrapper and qspi benches unchanged |
| WO-06 | formal core harnesses: `core_hold` (k-induction, length 1) and `core_req` (bounded, 10 cycles), register file stubbed with free read data | REQ-MEM-001 proven on both ports; REQ-MEM-002 bounded |
| WO-10 | `wfi_umode` pinned to the NOP (U-mode WFI with TW=0 never waits); TB-006 handler fix; FC86 added | FC86 and FC45 killed by wfi_umode; core 167/167 (also +RF_X +RF_COLLIDE_X), SoC 101/101 (11f1bb2, d049196, 81934d7) |
| WO-11 | CLINT window narrowed to 48 KB in the testbench (0x0200_0000-0x0200_BFFF), MEIP hook at 0x0200_8000, pma_edges edge check with a negative control on the old bench, dtb reg 0xc000 | old bench fails pma_edges; FC62 killed by mul_fetchfault, FC63 by pma_edges; Spike identical with and without the dtb; core 167/167, SoC 101/101 (dfdd90a, f2674bd, f6fc76d, 4ef3499) |
| WO-12 | mailbox moved to syscon +0x7F0, FINISH on the sifive_test codes, UART and SPI drained before FINISH, verdict taken at FINISH | test-soc-periph 8/8, test-wrapper 3/3, four negative controls fail, the 13 SoC mutants still killed (d3cfd91, 28e95bf, 8e59169) |
| WO-14 | tb_syscon: unit bench against a model of the register map and the watchdog; REQ-SYS-001..019 | test-syscon kills all 37 faults in syscon.v (8eeba2e, then WO-14a) |
| WO-14a | bench fix-ups: stores, a kick and a TORR write aimed at the clock before a fire (k = 16..18), a sweep that sees aliases, the shipped CHIP_ID, floors (a9d6115..c2ebe57) | WD16 killed by the unit bench; SY14, WD02, WD08-WD11 are killed by it alone |
| WO-15 | tb_syscon_soc: every syscon load checked against a model; five reboots, strap, fail, watchdog hang (d53eeb4..4a28a5c) | test-syscon-soc 38/45 of the syscon faults; AS01-AS08 killed here (AS01, AS06 by it alone) |
| WO-16 | power-off holds until rst_n whatever the inputs do; a pin reset inside a reboot or watchdog hold (78e7772, a816d11) | SY21 and the power-off faults killed |
| WO-17 | tb_tt_um: a reboot and a watchdog reboot look like a pin reset at the pins; power-off holds every pin until rst_n (c2d6698, 04784ac, cea9ee4, 6bf2d0f) | test-wrapper 23/45 of the syscon faults |
| WO-18 | 45 syscon faults (SY01-21, WD01-16, AS01-08), run on the sandbox against a frozen tree (660bf74) | 45/45 killed by some bench, no survivor, no ERROR (`build/mut/wo-18.tsv`) |
| WO-19 | formal syscon_comb (bounded, 24), syscon_gate (k-induction), soc_rst_sync (structural); the review's docs fixes; this section (4390e7c..0e723d7) | SY20 killed by syscon_comb, WD05 and WD16 by syscon_gate; the AS faults survive formal by design (build/mut/wo-19.tsv) |
| WO-23 | the watchdog's `fire` gated by `~rst_soc` (SA-009, f9c34a6) | WD16 is the fault that removes the gate; killed by test-syscon and syscon_gate, survives test-syscon-soc |

Correction: commit 0980c78's body says the CSR proof kills seven mutants; it
lists six (CS01-04, CS07, CS11) and six is the measured number.

### 4.2 Survivors and verdicts

Faults no current bench kills, 12 of 295 (`build/mut/report-all-wo19.txt`): 10 in core files, 2 in SoC files. None of the 45 syscon faults survives every bench; the ones that survive some benches are in section 4.
None is waived; each is either equivalent (no observable difference) or
touches behaviour nothing specifies (section 5).

| Fault | Verdict | Basis |
|---|---|---|
| ALU07 | unspecified | ALU output for a code the controller never issues |
| BR06 | unspecified | branch result for a reserved funct3 |
| SE04 | equivalent in the core | SRLI/SRAI immediate sign-extended: only shamt, imm[4:0], is used |
| SE05 | equivalent in the core | the CSR-immediate zimm taken from the wrong field: fyracore takes zimm from rs1 |
| MD07 | equivalent | proved (k-induction, length 3): in the divide loop acc < m when m != 0, so sum[33] == sum[32]; with m == 0 both arms are equal |
| FC02 | equivalent | proved (k-induction, length 3): csr_wb_hazard implies !ex_ph, so stall_nofetch never changes; ex_wait gives the ordering. A dead stall term, removable |
| FC49 | equivalent | proved (k-induction, length 3): !(flush && muldiv_want), so the three flush gates on the M handshake are dead |
| FC27 | equivalent | argument: garbage rd writes during a load wait are unobservable, EX is held by use_hazard until the final write, and after a reset x1-x31 are unspecified (Priv 3.4) |
| FC81 | equivalent | timing only: a stale wfi_active clears on the first cycle after reset because mie resets to 0 (pinned by tb_csr); costs at most one stall cycle |
| FC84 | equivalent | every use of exwb_memWR is gated by exwb_valid, which resets, and the stale bit is overwritten on the first cycle |
| GP03 | equivalent | SoC file, as scored before |
| TT01 | equivalent in zero-delay RTL; kept by design (settled 2026-10-24) | `run` opening the pin gates on the first edge after `rst_n` rises instead of the second. It differs only on a reset with no clock edge while `rst_n` is low (the demo board firmware's first load of a project; the reset button with the clock stopped): there the SoC's flops first take their reset values on edge 1, so the mutant opens the gates on that same edge, a race of about a nanosecond on `uo_out` and `uio_oe`, and gives `run` D = 1 at the asynchronous release of `rst_n` (the design has D = 0 there, so `run` cannot go metastable). TinyTapeout (Discord, 2026-10-23): the clock is not guaranteed to toggle during reset, a few-ns glitch on a project output reaches the pin, and a few ns of `uio_oe` contention with the RP2350 is harmless. The second edge is therefore defence in depth for one flop. Only a gate-level run with SDF of tb_tt_um's stopped-clock reset can see it (section 5) |

RG01 and RG04 (x0 masked in the core) are killed by test-regfile, so they are
not survivors; they only cannot be seen from the core.

Spec ambiguities closed on 2026-10-23: SA-004 (CLINT aperture) with the
testbench narrowed to Spike's window (WO-11); SA-006 (U-mode WFI) as a doc fix
(1a845f5), with the behaviour pinned by wfi_umode (WO-10).

## 5. Not verified, and why

- Formal: no SMT solver for sby/smtbmc on this machine; yosys's own `sat`
  runs six harnesses (`tb/formal/run.sh`): csr, core_hold and syscon_gate
  by k-induction, core_req bounded to 10 cycles from reset (it is not
  inductive without internal invariants), syscon_comb bounded to 24 cycles
  (the two-copy miter says nothing about states deeper than that), and
  soc_rst_sync, a structural walk of the flattened netlist, not a proof about
  behaviour. The register file is a stub with
  free read data, so nothing is proved about its contents; the core's
  other properties (data path, traps, interrupts) are covered by
  simulation only.
- Core-level reset in the middle of a program: dropped into tb_rivercore
  (`+RESETS`) and used by `core_reset`, which is DUT-only because Spike's
  trace would not apply; not run through the SoC (a SoC reset restarts the
  PSRAM start-up, outside the datasheet subset in `docs/`).
- Gate level: no netlist runs in this pass. TT01 (section 4.2) can only be
  killed there: tb_tt_um's stopped-clock reset on the SDF-annotated netlist,
  with a monitor for a glitch on `uo_out` / `uio_oe` at the first edge.
- Behaviour nothing specifies is not checked: ALU output for codes never
  issued, branch result for reserved funct3, signExt's SYSTEM output,
  decoder funct3/funct7 for formats without them (spec-ambiguities in the
  agent memory).
- syscon, SA-008: a kick in the fire cycle does not stop the fire. No test.
- syscon, F1: writes to `mtime` can delay the watchdog or advance it (three
  writes that toggle the tapped bit fire it 10 clocks after a kick). Accepted
  2026-10-25; no test, and Linux never writes `mtime`.
- The pins' glitch check needs the SDF netlist: the zero-delay RTL runs cannot
  see a race of about a nanosecond on `uo_out` / `uio_oe` (after the harden).
- F11: the CS# pull-up timing at the reboot release is a board or silicon
  question; no simulation here can answer it.
- TB-007: tb_uart's seed-4 floor is still open; `test-seeds` is run with seeds
  1-3 until it is settled.
