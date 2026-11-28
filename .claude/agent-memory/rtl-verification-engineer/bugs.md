# Bugs found

(none yet in this pass -- 2026-10-18)

## TB bugs found and fixed
- TB-001 Makefile run_tb piped vvp into tee (exit status lost) and grepped
  only ^FAIL/^TIMEOUT: a $fatal, an ERROR line, or a bench that ends early
  without a summary passed.
- TB-002 tb_compressed_decoder: C.ADD field check used && (failed only if
  rd AND rs1 were both wrong); most cases checked opcode/funct3 only, with
  zero immediates.
- TB-003 tb_qspi_stress: no progress floor or wait bound -- a deadlock
  part-way through the 400k random clocks still printed PASS (b22129a).
- TB-004 my own new benches (caught before commit): $random(seed) moves
  seed, so PASS lines printed the end state, not the reproducing seed;
  tb_csr's sweep/post-reset reads advanced time with the clock running
  (counters ran ahead of the model); the muldiv model divided unsigned
  inside ?: with unsigned arms; memory_model's first fill-free read
  helper read mem[] inside a function (continuous assign not sensitive).
- TB-006 (2026-10-23, found planning WO-10) tests/directed/wfi_umode: the
  handler's mret back to M-mode kept MIE=1 (MPIE=1 from the previous mret),
  so a core whose U-mode WFI waited re-took the still-pending timer at cont_b
  forever (FC86 copy: 13617 traps, DUT-ABORT). The "waits" alternative the
  MANIFEST accepted could never pass. Fix in WO-10 (clear MPIE).
- TB-005 tests/directed first drafts: .skip regions jumped into (label in
  front of the padding); .text.init over 4 KB moves tohost.

2026-10-22: candidate review (FC02 FC49 FC27 MD07 RG01 RG04, CLINT window): no DUT bug; see vplan.md "Candidate verdicts".

## 2026-10-24 candidate (pending SA-009 decision)
- BUG-001? [Low] syscon watchdog fires on E1 of a FINISH reboot / power-off
  hold (en still 1 for one clock). Reproducer build/wo14rev/probe_e1.v:
  `cd build/wo14rev && iverilog -o probe_e1 ../../src/syscon.v probe_e1.v
  && vvp -n probe_e1` -> RESET_CAUSE 0x7 after reboot, 0x5 in power-off.
  -> 2026-10-24: user decision = RTL fix (WO-23, fire gated by rst_soc).
     Close BUG-001 when WO-23 lands and WO-14a's k=16..18 pass (WD16 FAILs).
- TB-007? (2026-10-24, reported by the WO-14a coder) tb_uart +SEED=4 fails
  its own coverage floor `rx_breaks < 10` (tb/tb_uart.v:1583: "too few
  breaks: 8 sent"): a floor that the stimulus does not guarantee, so a seed
  can miss it. Unrelated to syscon. Stops default `make test-seeds` at s=4.
  Coordinator checking f9c34a6/main. Fix: steer breaks, or count/floor per
  stimulus. Not mine to fix in WO-14a.
- TB-008 (2026-10-25, planner/doc error, mine) tb/VPLAN.md 4 "directed core
  193/206" (e4de29c..a4ac1d0) was the any-bench count; correct directed
  181/213 (176/206 of the original faults). Told to the user at PR #11 as
  part of "193 (95% core)"; 95% (any bench) stands.
- TB-009 (2026-11-07, VC-3 8-seed run) tb_spi +SEED=5: "coverage floor missed: bytes B=79-253"
  (random-phase floor 5, tuned to seeds 1-4 per tb_spi.v:781). Same class as TB-007. Fix planned
  in WO-33 (quota steering). TB-007: seed 4 passes since 2dde982 but still luck-based -> WO-33.
- TB-010 (2026-11-09, tb_uart +SEED=1 at DIV_RESET 34, WO-61 acc1) model_read BI-link exclusions
  (tb/tb_uart.v:508-509) lack `!bi_val`: BI sticky from an unread-LSR earlier break + a second break
  pending -> zero hypotheses (want X). DUT correct (traced). Patch + checks in
  localFiles/qspi-stream-ddr/UART-SEED1.md; sandbox ~/regr/qs/uart-seed1. Status: proposed, not applied.
- TB-011 (2026-11-09, tb_uart +SEED=3 after WO-62 0637cda) model_write moves fr_hi_to (RTS# held-high
  window end) on a divisor-latch restart only if dr_pend; a dropped frame (oe_pend) whose RBR is popped
  mid-frame -> DUT asserts RTS# legally 1 tick early -> false FAIL. Also bi_lo never moved. Patch +
  checks in localFiles/qspi-stream-ddr/UART-SEED1.md (seed-3 section); sandbox ~/regr/qs/uart-seed3.

## 2026-11-21 WO-70 (adversarial 4x4) -- UNTRIAGED candidate A1
- adv_smc -DCMODE=0 (cache off) hits the 40M-cycle limit at pc 0x20000500 (the j . after ADV_PASS's FINISH store)
  with no SIG 2 / FINISH / C3-trap spare on the mailbox; CMODE=2 NITER=20 PASSES with C3 = mcause 1, mepc 0x80FFFFFE,
  mtval 0x81000000. Hypothesis: cache-off fetch straddling the PSRAM window end (0x80FFFFFE) is not PMA-faulted
  (page split carries to 0x81000000, aliasing PSRAM A[0]). Also SIG1 (pass-1) differs c0 vs c2. Details + repro:
  localFiles/wo-4x4/WO-70-RESULTS.md section 1; sandbox ~/acc/wo70/out/smc_c0.{log,elf}.

## 2026-11-22 WO-75 (WO-70 batch B triage) -- 0 DUT defects, 4 TB/test bugs fixed (tests/soc only)
- A1 (above) closed by WO-71 as a test bug (unaligned trap label; 9d0c7d6).
- TB-012 adv_irq cache-on hang = legal foreground livelock: the bench retriggers GPIO 0..255 clk after each W1C;
  cache-on W1C->mret 166 clk + refetch of the evicted interrupted line ~102 clk > 255, so the trap is always taken
  before the instruction retires (mepc/mcause/claims all correct, 301/301 serviced). Fixed 9e385c0 (ISR ends chain at 300).
- TB-013 adv_reboot 0x58: QSPI_CFG reset = 9 (DDR_CAP resets 2), test said 1. 15cfac9.
- TB-014 adv_reboot boot-2 0xC0 cue: fill already closed when word-2 store completes (cache on). 9076d41.
- TB-015 adv_ctl 0x82: last CACHE_CTL store = final a3 ^ 1 (xori after store). 9d5adc8.
- TB-016 smc_late: QSPI_LATE delays need +CLK_HALF_PS=5000 (10 ns); at 20 ns pc X. Run-command fix only.
  Report localFiles/wo-4x4/WO-75-RESULTS.md.
- 2026-11-22 PX-1/PX-3 triage (branch px/memctrl, clone AlphaOneSoC-dev/memctrl, base c529472): 0 DUT bugs. TB bugs:
  TB-017 cache_props stw_m set by a free reset-cycle store that sb ignores -> B fails step 1 (cache, cache_en). d3c59bf.
  TB-018 mem_props P_PW `ract` missing from the rst clause -> MR1 armed by a cycle-0 read, fails step 2. 9852477.
  TB-019 mutants.py: posted-store PX01-PX08 collided with pinmux PX01-PX08 -> nonvac "not applicable" (9 ERROR),
  MP1/2/3/5/6 never shown non-vacuous; renamed PS01-PS12. 75fff30.
  TB-020 tb_qspi backdoor checks right after the last store's ack (posted write not yet on the chip) + flash_wr
  window closed before the posted flash write ran; drain on pw_busy. 26d909d. Report localFiles/wo-4x4/px/memctrl-triage.md.

## 2026-11-24 formal triage (full run.sh on 4x4 head lineage) -- 0 DUT defects, 4 harness issues (patches only, not committed)
- TB-021 qspi_strap stale since WO-68 (662982d): `burst` unconnected (per-copy free after setundef -anyseq) and pstrm/t_bst
  not in x_all -> copies start apart, unreset t_top carries it through reset, line 50 fails at step 2. FAILS on 90c7341,
  3f43aa4, 7902a86; PROVED on 390d118/6d16849 (pre-burst engine, ship candidate). Patch strap.patch PROVED + nonvac 2/2.
  Side effect: run.py has no baseline check -> every qspi_ctrl.v mutant on PBURST trees is a false kill via qspi_strap.
- TB-022 qspi_burst_eq_cov: cover 3 (PSRAM CS low in done_r) UNREACHABLE (pdr proved; ref engine raises PSRAM CS into
  S_END); covers 1/2 need 345 steps > depth 300. beqcov.patch: ps_last cover + depth 360.
- TB-023 cache: run.sh default box 1800 s < 2353 s needed by the 256 B cache at depth 18 (load 15/6 cores). cache.patch.
- TB-024 mem_tcem: pdr 1260 s (11-22) / 1931 s (11-24) vs 2400 s box. tcem.patch: sind + WO-72 lemmas + H15
  `assert(!i_burst_ever)` (without H15 induction fails on MT1t) -> 8 s, nonvac 2/2. MT1t is only in mem_tcem.
  Report localFiles/wo-4x4/FORMAL-TRIAGE-2026-11-24.md; patches localFiles/wo-4x4/formal-triage-2026-11-24/.
  Follow-up 21:35: beqcov.patch COVERED 3/3 (min depth 345 confirmed by smtbmc on the committed harness, 2/3 at 360);
  cache.patch nonvac 15/15 OK. Branch head moved to 3543de3 (cache832) mid-triage: items 1/2/4 unchanged, cache timing unmeasured.
  Evidence archived in localFiles/wo-4x4/formal-triage-2026-11-24/evidence/; sandbox ~/dev/ftri deleted.
