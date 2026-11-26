---
name: findings-log
description: chronological one-line verdict log of every design review (2026-09-05 onward) with the finding file each points to
metadata:
  type: project
---

# Review findings log (moved out of MEMORY.md 2026-11-21 to keep the index short)

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
- 2026-10-23 syscon PLAN (WO-20 RTL, WO-21 docs, WO-22 DW-compatible watchdog +0.057 t): rst_soc for all but syscon, 2-edge reboot, strap mux, 0.087 t;
  mailbox +0xF04 unreachable from s11 (12-bit imm) -- finding_syscon_design_2026-10-23.md
- 2026-10-24 SA-009 (my WO-22 miss): wdt fires in the cycle after a FINISH store (rst_soc lags rq/off one edge);
  WO-23 gates fire with ~rst_soc, +0.0009 t; breaks mutant WD03's string -- same file
- 2026-10-29 WO-27 fetch word reuse DESIGN (worktree fetch-reuse): 24.6-26.1% fetches saved on C, CPI ~-19%, 17 flops,
  no tag; directed suite 0.57% hits; D1-D6 pending -- finding_fetch_reuse_wo27_2026-10-29.md
- 2026-10-29 WO-28 SPI controller DESIGN (worktree AlphaOneSoC-spi): tiny_spi map @0x1001_0020, F12 pin flops, OUT rst 0x89;
  15.6 MHz MISO margin 2-12 ns -> cap BAUD 2; +1,150 um2, 3x4 ~69.9% w/ fetch reuse -- finding_spi_wo28_2026-10-29.md
- 2026-10-30 WO-27 impl review f7f956b: RTL OK; BLOCK verif: fr_misa not RF_X-clean -> false FR12/FR14 kills, +rfx leg masks all
  survivors; core_fetch F1 32-bit clause vacuous (FR03 proves) -- finding_fetch_reuse_wo27_2026-10-29.md
- 2026-10-30 WO-28 SPI impl review 42e2fec: RTL APPROVE, +24 flops exact, sample point probed (D<=2B); verif gap until WO-29
  (no RX/modes 0-2/unit SPI bench; GP01-04 raise) -- finding_spi_wo28_2026-10-29.md

- 2026-11-07 WO-36 RVFI port 8976278: APPROVE w/ non-blocking, port correct; zero_area stall_nofetch unproven = purge renamed
  wfi_active->fv_wfi_active (equiv_add closes 5017/5017) -- finding_rvfi_wo36_2026-11-07.md
- 2026-11-08 REVIEW-53 qspi-stream ae6742c: 0 CRIT, MAJ m1 3-bit overflow (DDR_CAP 6/7 never capture, sim x), MAJ io_out
  mixed-edge pin cone; syscon_gate P3 stale; FC02/FC49 sound but unguarded -- finding_qspi_stream_ddr_review53_2026-11-08.md
- 2026-11-09 final pre-merge 2a97dcd: 0 BLOCKER/MAJOR; M-1/M-2/V-1..V-3 fixed; random ddr/cap-flip stress PASS (sandbox
  rev-6a); 2 stale comments (syscon.v:27-29, uart.v:24-25) -- same file

- 2026-11-20 WO-54 pwm 2bab221 + WO-55 audio ab3ad84: both ACCEPT-with-fixes, 0 blocking; pwm-sifive header polarity
  trap (pin = ip), audio harness mixer unpinned (uses DUT sum) -- finding_wo54_wo55_pwm_audio_2026-11-20.md
- 2026-11-20 WO-46 IO2 c60b579 ACCEPT (R6 one-sided, FC88 needs covers); WO-49 16550A ACCEPT (BI/RLS persist ->
  datasheet-ISR livelock, TX stall 0.95 ms); WO-47 PLIC: claim honours threshold = SPEC VIOLATION -- finding_wo46_wo47_wo49_2026-11-20.md
- 2026-11-21 WO-51/52 @4a6f88a: ACCEPT w/ should-fixes, 0 blockers; two-phase IO bus exactly-once holds, SB05 equivalent (c61cee8),
  ph_s shadow sound; S1 RTS# untested at pins, S2 plic_uart no Linux EOI cue, S3 harness over-assume -- finding_wo51_wo52_2026-11-21.md
- 2026-11-21 WO-58 ACCEPT, WO-61 S1 (level wdt_irq vs dw_wdt RISING -> PLIC storm), WO-63 S2 (trig code2->4 < Linux latency),
  S3 (pwm cmp2/3 read 0 -> "enabled"); 8250 fixed-type path verified -- finding_wo58_wo61_wo63_2026-11-21.md
- 2026-11-21 FINAL pre-lock whole-SoC @1f2a473 (+WO-68 in flight): READY w/ should-fixes, 0 RTL blockers; SF1 DT
  gpio-mmio compatible binds nothing (SPI/SD never probe), SF2 pinctrl-single bits w/o bit-per-mux, SF3 no board DTS/
  loader contract (SPICTL.EN), SF4 no dirty-reboot test, SF5 lint/V10, SF6 Linux never run; WO-68 RTL sound, PBURST=0
  equiv by inspection, tCEM floor ~12-15 MHz (97 clk) -- finding_final_prelock_2026-11-21.md
- 2026-11-21 ADV-B bus/PLIC/PMA/IRQ @d3eb898: 0 blocker/major; MINOR GPIO IN_IP phantom after 2-edge TT reset,
  stale plic.nonvac mutant (i->j), bus PMA assume on BOUNDED R6; prior S-items in slice all FIXED --
  finding_adv_b_bus_irq_2026-11-21.md
- 2026-11-21 ADV-C periph/pins @d3eb898: 0 blocker/major; MINOR DT pinctrl mask 0x7<<20 rejected by pinctrl-single
  (corrects FINAL SF2 "legal" claim), IN_IP phantom (= ADV-B), stale BI/FE-ack docs, code2->4 accepted; D13 holds
  (window 2b*T) -- finding_adv_c_periph_pins_2026-11-21.md
- 2026-11-21 ADV-A cache+PBURST @d3eb898: 0 blocker/major, RTL clean; stale window = fetch completing in the store's
  d_ready cycle only (d=2), doc "up to 3 words" wrong; tCEM "proved" = BMC ~1 window; no QB/C/cache-BMC mutant evidence
  -- finding_adv_a_cache_burst_2026-11-21.md
- 2026-11-22 Track B plan (WO-76/77): the two "prototyped" wasted fetches were already merged (9dc7443, ff130fb);
  WO-76 = residual discard fix (fetch hold if_wlo/if_wv, data-term guarded for DF_N 4 + no SMC staleness); WO-77 =
  256 B DM, data_hi on addr[7], per-port selects; third macro likely does not fit -- finding_wo76_wo77_plan_2026-11-22.md
- 2026-11-22 slice A core CPI review @2a2978e: 0 functional bugs; core-internal ~19 % of cache-on CoreMark time;
  A-1 posted stores ~2-3 %, A-2 shifter steps ~1.6-1.9 %, A-3 muldiv start on ex_rf_ok&&!use_hazard (sound), A-4
  cheaper WO-76 case-1 variant, A-5 not-taken fetch on c3; recommend stall-cause counters -- finding_perf_core_sliceA_2026-11-22.md
- 2026-11-22 slice B memory-path perf review @2a2978e: 0 bugs; PHY at its datasheet floor; B1 = fills that cannot be
  stopped and run in line order cost ~+130 clk per cold jump (+60 with PBURST); the 7-CPI gap is mostly the original
  model's 88-clk fill (K4 gives 22.35, ~2 CPI residual); all RTL items DROP under the sky26d-only rule -- finding_perf_mempath_sliceB_2026-11-22.md
- 2026-11-22 Track B RTL review @ff0b20f (WO-77 66a77e7, WO-76 16327b5, test b0e4805): 0 BLOCKER/MAJOR. MINOR: M1 cache
  collision comment covers only port A (port B + cross-macro collisions exist, discarded by muxes), M2 no WO-76 acceptance
  verdicts / no combined-SHA run, M3 uart_linux no longer pins RDA 0xC4. NOTEs: macro-Q mux timing, unbounded idle flash
  stream under the hold -- finding_trackb_rtl_2026-11-22.md
- 2026-11-24 WO-cache832 planning (8 x 32 B, base edaf17d): recommend sectored S (8 tags, 16 sector valid, 16 B fills;
  cache.v only, tCEM/WO-72 + cache formal depths unchanged) over whole-line L (qspi_ctrl + LPB 184 re-proof). Model S
  -3.8 % / L -8.3 % CoreMark (PB); synth S -6.26k / L -7.12k um2; S prototype formal + tb_cache clean, its negative
  control killed -- finding_cache832_plan_2026-11-24.md
- 2026-11-24 slim/pinmux-pwm review (d6439ff/2ceb953/e47132d on edaf17d): APPROVE WITH SHOULD-FIX, no RTL defect. zerocmp
  period cmp0*2^S+1 proven SiFive-consistent (Timer.scala countReset); lint PASS x4; revert 3-2-1 byte-identical; SF: fpga
  srclist drops audio.v under PIN 1f2a473 (build break), stale pin-7-code-5 docs/dtsi/VPLAN -- finding_slim_pinmux_pwm_2026-11-24.md
- 2026-11-24 CSR-slim adversarial (93a5e4c; trims A no-reset, B 4-bit mcause, D PMP G=10): A/B/D spec-sound, no RTL
  defect. MAJOR (verif): river_core Spike --dtb spike-fyracore.dtb says pmpgranularity 4 and overrides the CLI 4096 ->
  rv32mi-pmpaddr "PA-width" label is really a G=0 reference; rand1 untrusted until the DTS is fixed. MINOR: NA4->NAPOT lock
  amplification (32 MiB wedge demo), Zephyr doc scope, TOR lower-bound doc, no cause>=16 guard, EQY refit --
  finding_csrslim_adversarial_2026-11-24.md
- 2026-11-25 ADV-tip slice D (f75a734, slim integration + docs/DT/clock): RTL clean; MAJOR D1 no per-variant doc/DT/sw set (A0-core vs tip differ), MAJOR D2 tip at 62.5 MHz + all freq patches stale; pwm-sifive 6.8 vs master polarity. See finding_adv_tip_D_2026-11-25.md.
- 2026-11-25 ADV-tip slice A (f75a734, PX-6/7/8 + a48b21f + brcmp): RTL clean (muldiv model 0/352k fails). MINOR A1 a48b21f
  closes the spec-legal store-edge stale fetch only for M ops (add has same window); A2 ALTOPS blind to muldiv start
  operands; A3 rvfi depths unmeasured / PX run uncollected; A4 brcmp keep benefit unshown in LibreLane. See
  finding_adv_tip_A_core_2026-11-25.md.
- 2026-11-25 adv-tip slice B (cache832 sectored I-cache @f75a734): 0 BLOCKER/MAJOR. RTL sound (tags written only at
  start, sibling cleared there). MINOR: B1 sector invariant BMC 18 only; B2 M-A5 cache side unasserted; B3 no river_core/
  EQY/GL on cache832, EQY EXPECT not refit (-136 tags); B4 HM5 survivor. NIT: qspi_ctrl tCEM comment stale, miss-wait
  bound omits straddle double-miss, "EN 0->1 cold" corner, "line" 16 vs 32 B. See finding_adv_tip_cache_2026-11-25.md.
