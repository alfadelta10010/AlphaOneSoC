# riscv-design-reviewer memory

Review logbook for the RISC-V CPU + SoC. Keep concise. Consult before each review;
update after each review with confirmed decisions, findings, and recurring patterns.

## Project target (confirmed)

- 32-bit RISC-V core + SoC, **M-mode only, single hart**, intended to boot mainline
  **NOMMU (M-mode) Linux**.
- sky130 PDK via TinyTapeout; external QSPI flash + PSRAM (memory-bound, ~30 MHz class).
- Verification intent: Spike as ISA golden reference (lockstep), riscv-dv, RTL testbench.
- Reference design: KianV uLinux SoC (splinedrive) — multicycle, no caches/on-chip RAM,
  RV32IMA (earliest TT chip rv32ia, dropped C and hardware M). Boots Linux ~6.8 at ~30 MHz.

## This project's confirmed design decisions

<!-- Fill in and keep current. The review depends on these. -->
- ISA: RV32IMACU_Zicsr_Zicntr_Zifencei; misa reset 0x40101105 (U advertised since 009ad74), only C writable.
- Hardware M: yes (multicycle muldiv). A: LR/SC + AMO, 2-cycle WB.
- Privilege: M + U (no S), single hart. marchid param default 0, tb overrides to 5 (21fbe65). mstatus has MPRV+TW (7cd1eb6/8485cf0).
- Memory map (ADOPTED e98761e): PMA_ROM flash 0x20000000 16MB RX; PMA_RAM PSRAM 0x80000000 16MB RWX+LR/SC
  (CS by addr[23]); IO0 CLINT 0x02000000 64KB; IO1 UART/GPIO/syscon 0x10000000-0x1002FFFF; IO takes AMO, not LR/SC.
  Reset PC = boot_addr INPUT (caa2d10), strap picks flash/PSRAM. No boot ROM. mtvec still resets 0.
  SoC BUILT (soc-fabric branch, 71a8514): soc_bus stateless decode, mem_ctrl data-first + 1 KB page split,
  qspi_ctrl EBh/38h SPI mode SCK=clk/2, start-up F5h(QPI)/66h/99h to PSRAMs + 8x1111 to flash, rd_late strap,
  CS0 masked on writes, registered MTIP, mtime = core clock (no prescaler), no PLIC, UART/GPIO/syscon read 0.
- Microarchitecture: 3-stage pipeline IF/EX/WB; traps resolved in EX, committed at WB. EX/WB HOLDS on wb_mem_stall
  (2167485); other stalls bubble. Since c579eeb: dmem_req (excl. trapping/failing-SC) + imem_req (constant 1);
  every redirect gated on !stall so pc only moves when imem_ready. Loads still carry NO byte-lane info.
- Straddling 32-bit fetch (PC[1]=1): extra EX cycle (ex_ifetch_hi_phase) for the hi-half PMP check, only in
  U-mode or with a locked entry (96ee78a). PMP CSR writes refetch the next insn like FENCE.I (2d02808).
- Verification: river_core + Spike trace diff; tb/tb_rivercore.v + tb/memory_model.v (wait states since 68d85b6;
  rdata=X while !ready HIDES garbage-data control bugs — also run a 0/LFSR-returning bus). Directed tests in
  tests/directed/ (since 5a50547: MANIFEST-driven, full-trace compare, ~90 runs incl. NOTREADY/straddle/PMP).

## Reference designs to benchmark against (proven, compact, open)

- KianV uLinux SoC (splinedrive) — primary precedent: multicycle RV32IMA, M-mode-only,
  boots mainline NOMMU Linux on sky130/TinyTapeout silicon. If this design diverges from
  KianV, ask why. https://github.com/splinedrive/kianRiscV ,
  https://github.com/splinedrive/KianV-RV32IMA-RISC-V-uLinux-SoC
- SERV (Olof Kindgren) — world's smallest, bit-serial RV32I, Zephyr/RTOS class (not
  Linux). Minimal-privilege reference. https://github.com/olofk/serv
- PicoRV32 (YosysHQ) — small, well-verified RV32IMC, configurable area/speed knobs.
  https://github.com/YosysHQ/picorv32
- FemtoRV32 (Bruno Levy, learn-fpga) — smallest correct RV32I datapaths.
  https://github.com/BrunoLevy/learn-fpga
- VexRiscv (SpinalHDL) — configurable pipeline, MMU Linux on FPGA; the "fuller" end.
  https://github.com/SpinalHDL/VexRiscv
- NEORV32 (Stephan Nolting) — well-documented RV32 SoC; strong CSR/interrupt/peripheral
  reference. https://github.com/stnolting/neorv32

## High-risk areas to check every review (project-specific)

- **64-bit mtime/mtimecmp on a 32-bit datapath** — high/low read rollover race.
- **DIV/REM edge cases** — divide-by-zero and INT_MIN/-1 signed overflow return values.
- **FENCE.I** — must flush instruction fetch so the bootloader/loader sees written code.
- **LR/SC reservation**: SC-always-clears is load-bearing (Linux's ret_from_exception dummy
  SC relies on it); the trap clear is optional. See finding_lrsc_policy_2026-09-22.md.
- **Misaligned access** — precise, re-executable trap (or correct hardware support).
- **Interrupt taken mid-multicycle op** — sampled only at safe boundaries; mepc correct.
- **PSRAM variable latency** — bus wait-state handling, no dropped/duplicated transfers.
- **PMP absent** — Linux probe must see a safe permissive reset and skip cleanly.

## Findings log

<!-- ID | severity | location | summary | status (open/fixed/accepted/wontfix) | date -->
- 2026-09-05: WB-stall drops mem op (CRIT), MRET multicommit (CRIT), exc. priority (MAJ) — open
- 2026-09-12 branch review: R1-R8 + V1-V4 — see finding_branch_review_2026-09-12.md
- 2026-09-22 rtl-fix branch review: 2167485/fce59af/760a524/f2e42b5/11384f8/6c564b3/b7c5805
  VERIFIED FIXED. NEW CRIT: muldiv livelock at IMEM_WAIT>=2 (C1); `csrw X; mret` loses the
  write (C2 = old R1, unfixed). R3/R4/R5 + WARL third-copy still open. See
  finding_branch_review_2026-09-22.md
- 2026-09-24 full review at 7cd1eb6: 2e6718b (muldiv fix) introduced 2 CRITICALs (stale M-op results — all
  8 RV32M arch tests fail; fetch-fault M-op deadlock). NEW CRIT: spurious trap redirect from garbage-forwarded
  load data during stall. MAJOR: SC store withdrawn by ungated EX trap clear; MRET+irq double commit; mie not
  forwarded to irq gating. See finding_branch_review_2026-09-24.md
- 2026-09-25 verification of 35 fix commits (7f7e6f9..39f6380; RTL same at 832e068): ALL 09-24 C/M/m items
  VERIFIED FIXED, no new CRITICAL. New: MINOR pmpcfg R=0/W=1 stored+honoured; MINOR UNOPTFLAT false loop
  (6dbf31d); MAJOR SoC-contract: no load byte lanes (8250 RBR pop), imem_req=1 (fetch-priority arbiter
  starves dmem). See finding_branch_review_2026-09-25.md
- 2026-09-25b review at 0b6eabb + memory-map proposal: 09-25 items VERIFIED FIXED (6aadc0f, bceaa5f,
  c641e76, d05e277, d83bff7). No new ISA CRITICAL. MAJOR SoC: single RWX exec window/flash writable/no bus
  error; halfword-aligned fetch contract. MINOR: mtvec reset 0. Proposed Linux map: flash 0x20000000,
  PSRAM 0x80000000 x16MB, CLINT 0x02000000, UART 0x10000000. See finding_branch_review_2026-09-25b_memmap.md
- 2026-09-26 pre-RTL SoC architecture review: no CRIT. MAJOR open: 1 KB page-wrap straddle (non-RBX PSRAM),
  device-state init (PSRAM 66/99, QPI/continuous-read leftovers, flash 38h=Enter QPI), ready-cycle arbitration
  invariant, read-sample margin at 66 MHz. See finding_soc_arch_review_2026-09-26.md
- 2026-09-26 post-RTL SoC review at 71a8514: A1-A4 VERIFIED FIXED; no CRIT/MAJ. MINOR: flash QPI exit not
  framed (QPI+CRM fails in own model), rd_late not latched, CS falls on first OE cycle, stale doc line.
  Q: PSRAM 66/99 vs preloaded data (boot_sel=1), CS pull-ups. See finding_soc_rtl_review_2026-09-26.md

## Recurring patterns observed

- EX-stage side effects not gated by `!stall` / `!ex_trap` (MRET is the repeat offender).
- CSR WARL masks re-implemented in csr.v, fyracore forwarding and tb dump — every new CSR
  forgets one copy (0x320 and mepc[1] in forwarding, 2026-09-12).
- Comments claiming "matches Spike" are often unverified — probe Spike before trusting.
- One-shot completion pulses dropped when the pipeline cannot advance (muldiv_done, 2026-09-22)
  — the mirror image of the level-signal-committed-twice pattern. Check both directions.
- Livelocks here are phase/congruence effects, not thresholds: a period that locks can be
  safe one wait-state setting later. Sweep contiguously and compare against a non-atomic
  control loop before calling it a defect.
- A "fix" that makes a pulse sticky must also block re-launch on the pulse cycle itself (register set at END
  of the cycle). 2e6718b swapped `!done` for `!ready` and silently broke every back-to-back M-op.
- Any redirect/side effect computed from EX operands must be gated by !stall: forwarded load data is garbage
  until dmem_ready. X-in-tb makes these invisible (iverilog `if (X)` = false).
- Exporting a post-write value from csr.v that its own read mux consumes makes a word-level loop
  (Verilator UNOPTFLAT, 6dbf31d). Run `verilator --lint-only -Wall` on every RTL review; yosys check won't flag it.
- Directed tests that retire a multi-cycle op but never check its VALUE (t_mul, t_mulirq, t_irq) pass through
  data-corruption bugs. Always full-trace diff against Spike, not final registers.
- Deterministic vs randomised wait states expose DIFFERENT bugs: randomised found the
  interrupt-vs-stall overlap, deterministic found the muldiv phase-lock livelock. Run both.
- req/ready slaves: in the ready cycle the core still shows the OLD request (imem_req=1, old pc). A slave that
  arbitrates in its own ready cycle refetches a stale address and can complete it against the NEW one.
- Device datasheets carry hidden state (PSRAM QPI/wrap, flash continuous-read/QPI) that survives a design reset
  and other TT designs set it. Always ask who establishes device state.
- Behavioural models encode the designer's reading of the datasheet (qspi_pmod_model accepts QPI FFh with 24
  trailing clocks). Check the MODEL against the datasheet, not only the RTL against the model.
- Spike cannot model read-only memory, so PMA ROM faults (cause 5/7 on flash) never appear in lockstep; they need
  a self-checking or SoC-only test. Likewise the SoC suite soc-skips timer tests — write SoC-speed variants.

## Notes index (2026-09-05 review)

- [FyraCore / AlphaOneSoC overview](project_fyracore_overview.md) — ISA string, M+U privilege, 3-stage pipeline, sky130/TT + NOMMU Linux target
- [Verification flow (river_core + RISCOF + Spike)](verification_flow.md) — how to reproduce one test, and how to tell a real RTL bug from an empty dut.dump
- [CRITICAL: WB stall drops in-flight memory ops](finding_wb_stall_drops_memory_op.md) — any wait-stated memory loses stores / returns garbage loads
- [CRITICAL: MRET multi-commits on stall](finding_mret_multicommit.md) — stalled MRET corrupts mstatus.MIE and falls to U-mode; reproduced vs Spike
- [MAJOR: exception priority puts illegal-instruction last](finding_exception_priority.md) — illegal load/store enc. at a misaligned addr reports cause 4/6 instead of 2
- [RTL area hotspots](rtl_area_hotspots.md) — ranked list of over-general structures (regfile reset, 3 barrel shifters, duplicated CSR WARL logic, unshared muldiv)
- [2026-09-12 branch review findings](finding_branch_review_2026-09-12.md) — CSR write lost under MRET, misa.C stale window, MPRV/TW missing, Spike --instructions truncation
- [Spike probed behaviours](reference_spike_probed_behaviours.md) — measured Spike device map, CSR WARL choices, mtval, and why --instructions is not a bound
- [2026-09-22 rtl-fix branch review](finding_branch_review_2026-09-22.md) — what the 14 commits actually fixed, the muldiv livelock, csrw+mret write loss, and the reset-state probe
- [LR/SC policy decision](finding_lrsc_policy_2026-09-22.md) — spec citations, why the trap clear is optional, the phase-locked interrupt livelock (real, not critical), recommended signal list
- [2026-09-24 full review at 7cd1eb6](finding_branch_review_2026-09-24.md) — muldiv regressions, garbage-forward redirect, SC withdrawal, MRET+irq, CSR gaps, run.sh coverage facts
- [2026-09-25 fix-verification review](finding_branch_review_2026-09-25.md) — per-commit verdicts, what was measured, pmpcfg R=0/W=1, UNOPTFLAT, bus-contract risks
- [2026-09-25b review + Linux memory map](finding_branch_review_2026-09-25b_memmap.md) — toolchain/Spike-master gotchas, CSR probe, XIP removal, proposed map
- [KianV memory map](reference_kianv_memory_map.md) — the DT that actually boots NOMMU Linux on this class of silicon: RAM at 0x80000000, no PLIC, 10 kHz timebase
- [QSPI Pmod datasheets + precedents](reference_qspi_pmod_datasheets.md) — W25Q128JV-DTR/APS6404L-3SQR timing, RBX page crossing, TinyQV/KianV QSPI choices
- [2026-09-26 SoC architecture review](finding_soc_arch_review_2026-09-26.md) — fabric/mem_ctrl/qspi_ctrl pre-RTL findings, verified-OK list, perf ranking
- [2026-09-26 SoC RTL review](finding_soc_rtl_review_2026-09-26.md) — post-RTL verdicts, core-like stress tb + mutations, PMA/timer SoC probes, new-block area
