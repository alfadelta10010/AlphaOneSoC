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
- ISA string actually implemented: (confirm — e.g. rv32imac_zicsr_zifencei vs rv32ima)
- Hardware M present or trap-emulated: (confirm)
- A extension LR/SC + AMO: (confirm present)
- Privilege model: M-mode only, single hart (assumed)
- Memory map / reset vector: (confirm)
- Microarchitecture: multicycle or pipelined? (confirm)
- Verification flow + where the testbench lives: (confirm)

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
- **LR/SC reservation** invalidation across traps/interrupts even on one hart.
- **Misaligned access** — precise, re-executable trap (or correct hardware support).
- **Interrupt taken mid-multicycle op** — sampled only at safe boundaries; mepc correct.
- **PSRAM variable latency** — bus wait-state handling, no dropped/duplicated transfers.
- **PMP absent** — Linux probe must see a safe permissive reset and skip cleanly.

## Findings log

<!-- ID | severity | location | summary | status (open/fixed/accepted/wontfix) | date -->
- (none yet)

## Recurring patterns observed

- (none yet)

## Notes index (2026-09-05 review)

- [FyraCore / AlphaOneSoC overview](project_fyracore_overview.md) — ISA string, M+U privilege, 3-stage pipeline, sky130/TT + NOMMU Linux target
- [Verification flow (river_core + RISCOF + Spike)](verification_flow.md) — how to reproduce one test, and how to tell a real RTL bug from an empty dut.dump
- [CRITICAL: WB stall drops in-flight memory ops](finding_wb_stall_drops_memory_op.md) — any wait-stated memory loses stores / returns garbage loads
- [CRITICAL: MRET multi-commits on stall](finding_mret_multicommit.md) — stalled MRET corrupts mstatus.MIE and falls to U-mode; reproduced vs Spike
- [MAJOR: exception priority puts illegal-instruction last](finding_exception_priority.md) — illegal load/store enc. at a misaligned addr reports cause 4/6 instead of 2
- [RTL area hotspots](rtl_area_hotspots.md) — ranked list of over-general structures (regfile reset, 3 barrel shifters, duplicated CSR WARL logic, unshared muldiv)
