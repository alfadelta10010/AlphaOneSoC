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
  no boot ROM, PSRAM always reset at start-up. CSR-slim (93a5e4c, 4x4 branch): mtvec/mscratch/mepc/mtval/pmpaddr0-3 have NO
  reset; mcause = int + 4-bit code; PMP grain G=10 (4 KiB), pmpaddr[31:30] RO 0, NA4 stored as NAPOT.
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

## Findings log

- Chronological verdict log: [findings_log.md](findings_log.md). Latest: 2026-11-25 ADV-tip slice D (RTL clean; variant docs + stale freq patches MAJOR); 2026-11-24 CSR-slim adversarial (A/B/D sound; river_core DTB grain MAJOR); 2026-11-24 slim pinmux/PWM review (APPROVE w/ SF); 2026-11-24 WO-cache832 planning (S sectored recommended); 2026-11-22 Track B RTL review.

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
- [2026-10-23 syscon design](finding_syscon_design_2026-10-23.md) — WO-20/21 decisions, driver/QEMU facts, acceptance benches, review checklist
- [2026-10-29 WO-28 SPI controller](finding_spi_wo28_2026-10-29.md) — tiny_spi semantics, sample-point table, area, D1-D9
- [2026-10-29 WO-27 fetch reuse](finding_fetch_reuse_wo27_2026-10-29.md) — kv/kbuf rule, capture enable, measured saving, gaps, PicoRV32 precedent
- [2026-11-07 WO-36 RVFI port](finding_rvfi_wo36_2026-11-07.md) — per-shape RVFI verdicts, equiv name-alias artefact + fix, WO-37 env gaps
- [2026-11-08 REVIEW-53 qspi stream/DDR](finding_qspi_stream_ddr_review53_2026-11-08.md) — EDh P'' trace, m1 overflow, pin-cone hazard, FC02/FC49 argument
- [2026-11-21 WO-51/52 bus+PLIC+UART](finding_wo51_wo52_2026-11-21.md) — two-phase IO bus proof sketch, SB05 equivalence, open S1-S3
- [2026-11-21 WO-58/61/63](finding_wo58_wo61_wo63_2026-11-21.md) — pins/F12/TT01 table, dw_wdt edge storm, 8250 fixed-type facts, tiny_spi baud rounding
- [2026-11-20 WO-54/55 pwm+audio](finding_wo54_wo55_pwm_audio_2026-11-20.md) — pwm-sifive polarity trap, audio harness mixer unpinned
- [2026-11-20 WO-46/47/49](finding_wo46_wo47_wo49_2026-11-20.md) — IO2 window, PLIC threshold-vs-claim spec violation, 16550A BI/RLS livelock
- [2026-11-21 WO-62 K4 I-cache](finding_wo62_icache_k4_2026-11-21.md) — no RTL defect; SF1 flash fill addr vs M-A2, stale P_LI, BMC-only contract, no EN=1 SoC run, STA, PSRAM fill cost
- [2026-11-21 FINAL pre-lock](finding_final_prelock_2026-11-21.md) — whole-SoC verdict, DT gpio-mmio/pinctrl probe bugs, WO-68 equiv + tCEM floor, fallbacks
- [2026-11-21 ADV-B bus/PLIC/IRQ](finding_adv_b_bus_irq_2026-11-21.md) — 0 blk/major; IN_IP phantom w/ 2-edge TT reset, stale plic.nonvac, dw_wdt.c facts
- [2026-11-21 ADV-C periph+pins](finding_adv_c_periph_pins_2026-11-21.md) — pinctrl-single mask must span fmask (FINAL SF2 corrected), IN_IP phantom, driver facts, D13 2b*T
- [2026-11-21 ADV-A cache+PBURST](finding_adv_a_cache_burst_2026-11-21.md) — RTL clean; stale only at d=2 (store d_ready cycle); proof-strength + mutant gaps
- [2026-11-22 WO-76/77 Track B plan](finding_wo76_wo77_plan_2026-11-22.md) — wasted fetches already merged; residual hold rules + DF_N trap; 256 B cache data_hi, fit risk
- [2026-11-22 slice B mem-path perf](finding_perf_mempath_sliceB_2026-11-22.md) — cycle reference, cold-jump fill penalty B1, 7-CPI gap = model fill assumption, all DROP
- [2026-11-22 slice A core CPI review](finding_perf_core_sliceA_2026-11-22.md) — cache-on cycle budget, shifter 5+k, M start slack, why WO-76 gave -0.95 %
- [2026-11-22 Track B RTL review](finding_trackb_rtl_2026-11-22.md) — WO-77 256 B cache + WO-76 fetch hold clean; collision-comment gap, combined-SHA evidence, RDA check
- [2026-11-24 WO-cache832 plan](finding_cache832_plan_2026-11-24.md) — 8x32 B: sectored S (5 RTL lines, tCEM/proofs unchanged) vs L; model/area/formal numbers
- [2026-11-24 slim pinmux/PWM/audio](finding_slim_pinmux_pwm_2026-11-24.md) — WARL pinmux, PWM no irq, PWM1 tones: SiFive period proof, FPGA PIN break, stale docs
- [2026-11-24 CSR-slim adversarial](finding_csrslim_adversarial_2026-11-24.md) — no-reset/4-bit mcause/G=10 sound; Spike DTB overrides --pmpgranularity (river_core at G=0)
- [2026-11-25 tip slice C CSR/PMP](finding_adv_tip_C_csr_2026-11-25.md) — RTL unchanged+sound; Zephyr port lacks PMP_GRANULARITY, rand1 G=0 programs, +CSR_X X-optimism
- [2026-11-25 ADV-tip slice D](finding_adv_tip_D_2026-11-25.md) — slim RTL clean at f75a734; A0-core vs tip doc/DT/sw split, freq patches stale, pwm-sifive 6.8 vs master
- [2026-11-25 ADV-tip slice A core](finding_adv_tip_A_core_2026-11-25.md) — PX-6/7/8+a48b21f+brcmp clean; store-edge stale fetch general; ALTOPS start blind spot
- [2026-11-25 adv tip slice B cache](finding_adv_tip_cache_2026-11-25.md) — cache832 sound (tags only written at start); B1-B4 verif gaps (BMC-only sector inv, M-A5, no RC/EQY, HM5), doc NITs
