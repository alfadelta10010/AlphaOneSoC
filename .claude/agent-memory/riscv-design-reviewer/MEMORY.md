# riscv-design-reviewer memory

Review logbook for the RISC-V CPU + SoC. Keep concise. Consult before each review;
update after each review with confirmed decisions, findings, and recurring patterns.

## Project target (confirmed)

- 32-bit RISC-V core + SoC, single hart, intended to boot mainline **NOMMU (M-mode) Linux**.
- sky130 PDK via TinyTapeout; external QSPI flash + PSRAM (memory-bound, ~30-50 MHz class).
- Verification intent: Spike as ISA golden reference (lockstep), riscv-dv, RTL testbench.
- Reference design: KianV uLinux SoC (splinedrive) — multicycle, no caches/on-chip RAM,
  RV32IMA. Boots Linux ~6.8 at ~30 MHz.

## This project's confirmed design decisions

- ISA: RV32IMACU_Zicsr_Zicntr_Zifencei; misa reset 0x40101105 (U advertised since 009ad74), only C writable.
- Hardware M: yes (multicycle muldiv). A: LR/SC + AMO, 2-cycle WB.
- Privilege: M + U (no S), single hart. marchid param default 0, tb overrides to 5 (21fbe65). mstatus has MPRV+TW.
- Memory map (ADOPTED e98761e): PMA_ROM flash 0x20000000 16MB RX; PMA_RAM PSRAM 0x80000000 16MB RWX+LR/SC
  (CS by addr[23]); IO0 CLINT 0x02000000 64KB; IO1 UART/GPIO/syscon 0x10000000-0x1002FFFF; IO takes AMO, not LR/SC.
  Reset PC = boot_addr INPUT (caa2d10); SoC ties it to 0x20000000 — FLASH-ONLY boot (81afe82), no strap,
  no boot ROM, PSRAM always reset at start-up. mtvec resets 0 (documented as deliberate).
  SoC BUILT (soc-fabric branch, PR #5): soc_bus stateless decode, mem_ctrl data-first + 1 KB page split,
  qspi_ctrl SCK=clk/2: PSRAM in QPI (0Bh 2+6+4 read, 38h 2+6 write, 97010f4); flash quad I/O EBh, cmd on IO0,
  M=FFh — USER DECISION (d8194db): no flash CRM/QPI, don't re-propose, don't call it "SPI mode".
  Start-up: F5h(QPI)/66h/99h PSRAMs, 8x1111, 16x1111 (dual CRM, d3cdb07) + FFh(QPI) flash, 35h PSRAMs. rd_late strap latched in reset,
  CS0 masked on writes, registered MTIP, mtime = core clock, no PLIC. TT wrapper written 2026-10-10: reset
  asserted asynchronously by rst_n and released on the 2nd clock edge, uio_oe = 0 and uo_out = 0x39 while it is high;
  pins-only bench `make test-wrapper`.
  UART (fbdcc03) 16550 subset @0x10000000, reg-shift 0, no FIFOs: THR back-pressure, RTS# RX flow control,
  polled; LCR.SBC + LSR.BI since 805324c/3f0d708, RBR resets 0. GPIO (40516d6) OUT/IN + SPI mode-3 TX @0x10010000. soc_bus ANDs IO readies (6a8d4c6).
- Microarchitecture: 3-stage pipeline IF/EX/WB; traps resolved in EX, committed at WB. EX/WB HOLDS on
  wb_mem_stall (2167485); other stalls bubble. imem_req = in_exec(pc) && !ex_nofetch (no fetch behind a CTI, ECALL/EBREAK/MRET/FENCE.I/PMP write);
  every redirect gated on !stall so pc only moves when imem_ready. Loads read the whole word.
- Area stack (branch area-opt_alfadelta10010, 2026-10-01): RF no reset + ONE read port (rs2_phase/rs2_hold),
  NO CSR forwarding (1-clk csr_wb_hazard stall, *_legal stores, mcycle_wr_q), one time-shared PMP checker,
  muldiv on one 34-bit add/sub also does the shifts serially, decompress in EX, link = pc (no ifex_pc_next).
- Straddling 32-bit fetch (PC[1]=1): extra EX cycle (ex_ifetch_hi_phase) for the hi-half PMP check, only in
  U-mode or with a locked entry (96ee78a). PMP CSR writes refetch the next insn like FENCE.I (2d02808).
- Verification: river_core + Spike trace diff; tb/tb_rivercore.v + tb/memory_model.v (core level) or -DSOC_TB
  (whole SoC vs tb/qspi_pmod_model.v); tests/directed/run.sh [soc] (MANIFEST-driven, full-trace compare);
  make test-qspi (tb_qspi x7 + tb_qspi_stress x2). Upstream Spike 7ab2efd6, no boot ROM.

## Reference designs (proven, compact, open)

- KianV uLinux SoC — primary precedent (multicycle RV32IMA, M-mode, NOMMU Linux on TT silicon).
  https://github.com/splinedrive/KianV-RV32IMA-RISC-V-uLinux-SoC
- SERV https://github.com/olofk/serv — minimal privilege; PicoRV32 https://github.com/YosysHQ/picorv32 —
  area/speed knobs; FemtoRV32 https://github.com/BrunoLevy/learn-fpga; VexRiscv
  https://github.com/SpinalHDL/VexRiscv — MMU Linux pipeline; NEORV32 https://github.com/stnolting/neorv32.
- TinyQV (MichaelBell) — same TT QSPI Pmod, see reference_qspi_pmod_datasheets.md.

## High-risk areas to check every review (project-specific)

- 64-bit mtime/mtimecmp rollover race; DIV/REM edge cases; FENCE.I vs fetch path.
- LR/SC: SC-always-clears is load-bearing; trap clear is the only irq protection. USER DECISION dce9568: own
  stores/AMOs KEEP the reservation -- don't re-propose a local-write clear (finding_lrsc_policy_2026-09-22.md).
- Misaligned access precise trap; interrupt mid-multicycle op; PSRAM/QSPI wait states; PMP reset state.
- QSPI device hand-over states (see finding_pr5_mempath_review_2026-09-29.md) and the Pmod model's AC checks.

## Findings log (one line each; detail in the linked file)

- 2026-09-05 WB-stall drops mem op (CRIT), MRET multicommit (CRIT), exc. priority (MAJ) — all fixed since.
- 2026-09-12 branch review R1-R8 + V1-V4 — finding_branch_review_2026-09-12.md
- 2026-09-22 rtl-fix review: muldiv livelock (CRIT), csrw+mret loss — finding_branch_review_2026-09-22.md
- 2026-09-24 full review 7cd1eb6: muldiv regressions, garbage-forward redirect — finding_branch_review_2026-09-24.md
- 2026-09-25 fix verification: all 09-24 fixed; pmpcfg R0W1, UNOPTFLAT — finding_branch_review_2026-09-25.md
- 2026-09-25b 0b6eabb + Linux memory map proposal — finding_branch_review_2026-09-25b_memmap.md
- 2026-09-26 pre-RTL SoC arch: A1-A4 Majors (all fixed later) — finding_soc_arch_review_2026-09-26.md
- 2026-09-26 post-RTL SoC 71a8514: no CRIT/MAJ — finding_soc_rtl_review_2026-09-26.md
- 2026-09-26 full-branch bc0baec: model blind spots, 77h wrap (m1) — finding_branch_review_2026-09-26_full.md
- 2026-09-27 peripherals 4d04809: SPI D/C race MAJ (fixed edae17c) — finding_periph_review_2026-09-27.md
- 2026-09-27b counters/LR/SC: cross-half read MAJ (fixed 97105f2) — finding_review_2026-09-27_counters_lrsc.md
- 2026-09-29 PR #5 memory-path slice 4b4ed8b: no CRIT/MAJ; dual-I/O CRM hand-over, flash BUSY, model lacks tRST,
  false-fails mixed PSRAM modes — finding_pr5_mempath_review_2026-09-29.md
- 2026-09-29 PR #5 periph + test-claims slice 4b4ed8b: no CRIT/MAJ; suites reproduce; CLINT-we mutant escapes all
  tests; mutation claim overstated — finding_pr5_review_2026-09-29.md
- 2026-09-30 PR #5 fix round 3f8a69f: no CRIT/MAJ; model misses step order + QPI-exit step, BI same-cycle,
  MTIP window upper bound (all PROVEN by mutant) — finding_pr5_fixround_review_2026-09-30.md
- 2026-10-04 area-opt stack 2209bb0: no CRIT/MAJ, RTL correct; suites miss SRA/MULHSU/SLTU values, PMP refetch,
  fetch-PMP vs MPRV, rs2 snoop (5 probes written) — finding_areaopt_review_2026-10-04.md
- 2026-10-09 PPA/claims 30eacb1: tile figures ~24% low vs TT cell set (12.52 t = 101% of 6x2), NO harden
  completes (RF self-loop hold buffers), #1b saves 0, tip slower at tt (muldiv) — finding_ppa_review_2026-10-09.md
- 2026-10-10 TT wrapper + pins bench (uncommitted): MAJ reset needs clocks, stock TT firmware resets with clock
  stopped (FIXED same day: async-assert reset); bench's 2nd reset mis-aimed, no-sync mutant passes (both fixed) — finding_tt_wrapper_review_2026-10-10.md
- 2026-10-11 rf_top macro integration (0367965+wip): no CRIT/MAJ; rf_hold exact; wfi_active term has no functional test (PROVEN),
  select bugs visible only in zero-IMEM-wait core runs; core 10.84 -> 7.07 t + 0.84 t macro — finding_rf_macro_review_2026-10-11.md
- 2026-10-11 rf-macro FINAL 88c18f3: MAJ load-use relies on the macro's same-edge write-through (model-only; read-first mutant
  fails SoC t_memstress); README macro at [450,45] not the precedent spot (routing wall, PDN stubs); 6x2 harden congested — same file

## Notes index

- [Recurring patterns](patterns_recurring.md) — bug classes and verification blind spots that escaped before; checklist
- [FyraCore / AlphaOneSoC overview](project_fyracore_overview.md) — ISA string, M+U privilege, 3-stage pipeline, sky130/TT + NOMMU Linux target
- [Verification flow (river_core + RISCOF + Spike)](verification_flow.md) — reproduce one test; real RTL bug vs empty dut.dump
- [CRITICAL: WB stall drops in-flight memory ops](finding_wb_stall_drops_memory_op.md) — historic (fixed)
- [CRITICAL: MRET multi-commits on stall](finding_mret_multicommit.md) — historic (fixed)
- [MAJOR: exception priority](finding_exception_priority.md) — illegal load/store enc. at misaligned addr, cause 4/6 vs 2
- [RTL area hotspots](rtl_area_hotspots.md) — regfile reset, 3 barrel shifters, duplicated CSR WARL logic, unshared muldiv
- [2026-09-12 branch review](finding_branch_review_2026-09-12.md) — CSR write lost under MRET, misa.C window, MPRV/TW, Spike truncation
- [Spike probed behaviours](reference_spike_probed_behaviours.md) — Spike device map, CSR WARL choices, mtval, --instructions not a bound
- [2026-09-22 rtl-fix review](finding_branch_review_2026-09-22.md) — muldiv livelock, csrw+mret write loss, reset-state probe
- [LR/SC policy decision](finding_lrsc_policy_2026-09-22.md) — spec citations, optional trap clear, phase-locked irq livelock
- [2026-09-24 full review](finding_branch_review_2026-09-24.md) — muldiv regressions, garbage-forward redirect, SC withdrawal, MRET+irq
- [2026-09-25 fix-verification](finding_branch_review_2026-09-25.md) — per-commit verdicts, pmpcfg R=0/W=1, UNOPTFLAT, bus-contract risks
- [2026-09-25b + Linux memory map](finding_branch_review_2026-09-25b_memmap.md) — toolchain/Spike gotchas, CSR probe, XIP removal, map
- [KianV memory map](reference_kianv_memory_map.md) — DT that boots NOMMU Linux on this silicon class: RAM 0x80000000, no PLIC
- [QSPI Pmod datasheets + precedents](reference_qspi_pmod_datasheets.md) — W25Q128JV-DTR/APS6404L timing, RBX, TinyQV/KianV QSPI
- [2026-09-26 SoC architecture review](finding_soc_arch_review_2026-09-26.md) — fabric/mem_ctrl/qspi_ctrl pre-RTL findings, perf ranking
- [2026-09-26 SoC RTL review](finding_soc_rtl_review_2026-09-26.md) — post-RTL verdicts, core-like stress tb + mutations, area
- [2026-09-26 full-branch review](finding_branch_review_2026-09-26_full.md) — QPI/flash-only verdicts, Pmod model mutation results
- [2026-09-27 peripheral review](finding_periph_review_2026-09-27.md) — UART/8250 verdicts, SPI D/C race + fix, area knobs
- [2026-09-27b counters + LR/SC](finding_review_2026-09-27_counters_lrsc.md) — keep-reservation legality, cross-half counter read bug
- [2026-09-29 PR #5 core](finding_pr5_core_review_2026-09-29.md) — no Crit/Major; registered MTIP stale mip + legal spurious irq; boot_addr[0] unmasked
- [2026-09-29 PR #5 memory path](finding_pr5_mempath_review_2026-09-29.md) — command/timing verdicts, rd_late sweep, reset stress, model gaps
- [2026-09-29 PR #5 periph + claims](finding_pr5_review_2026-09-29.md) — reproduced suite numbers, 8250 re-check, CLINT decode gap, keypad lag
- [2026-09-30 PR #5 fix round](finding_pr5_fixround_review_2026-09-30.md) — dual-CRM step verdict per hand-over state, UART SBC/BI, 4 proven check gaps
- [2026-10-04 area-opt review](finding_areaopt_review_2026-10-04.md) — 13 area/perf commits verdicts, 28 mutants, value-coverage gap, fast scratch flows
- [2026-10-09 area-opt compliance](finding_areaopt_compliance_2026-10-09.md) — ex_nofetch proven decode-only; repo misses that property; +RF_X blind spot; rgen2/rr.sh tools
- [2026-10-09 PPA/claims review](finding_ppa_review_2026-10-09.md) — TT-flow area/timing vs recipe, failed hardens, per-cut TT deltas, perf repro
- [2026-10-10 TT wrapper review](finding_tt_wrapper_review_2026-10-10.md) — TT firmware reset/clock order, async-latched reset fix proven, pin map verified, bench gaps
- [2026-10-11 RF macro review](finding_rf_macro_review_2026-10-11.md) — sync-read equivalence, rf_hold mutants, WFI-hold probe, macro lib/pin/area/timing facts
- [2026-10-12 RF macro timing changes](finding_rf_macro_timing_review_2026-10-12.md) — 7 uncommitted timing edits all SOUND; bypass/wb_fwd/cdec-in-IF/inc64 reasoning, area
- [2026-10-14 setup-timing note](finding_setup_timing_note_review_2026-10-14.md) — no-fwd + two-phase EX (alu_r/br_r/ex_ph): sound; claim true; cheaper verdict-flop cut
- [2026-10-14 setup-timing post-RTL](finding_setup_timing_postrtl_review_2026-10-14.md) — steps 1-8 sound; rf_fields/csr_wb_hazard/hit-byp redundant; mtip_stale/cnt_xhalf brittleness
