# vplan status (agent memory; the full plan is tb/VPLAN.md)

Branch verif-upgrade_alfadelta10010 (rebased by coordinator onto main
0d804cd on 2026-10-19; backup ref backup/verif-upgrade-pre-rebase).
Commits so far (post-rebase hashes): 1970429 memory_model no fill,
7b06255 run.sh knobs, 16ff33b mutate runner, f0f4dda RVC, 8d93fb7
controller, fddefbb ALU, 6024748 branchCtrl, 4308562 signExt, a2b0686
decoder, 6c01555 muldiv, 706ca5b CSR, 755af1e PMP bench, 80d4926 CLINT
bench, efdb840 PASS lines, (run_tb), b22129a qspi stress bound,
cb697a3 test-seeds, 5c51aea memory_model request checker, 0980c78
formal CSR, 3f86ab8 runner formal kind, 167f82e tb_rivercore bus check,
3021cfe run.sh refs <names>, 509b99d..34b5c6c eleven directed tests
(m_corners trap_nested irq_at_trap mem_align pma_edges amo_pmp sys_enc
imm_reach rvc_imm irq_umode irq_prio), a47a55b docs. Later commits: see
git log (sys_enc reserved-base extension, VPLAN, this memory).

Mutation (239 faults): before-campaign core files 206 scored, 155 killed
(75%), directed alone 138 (67%). Results: build/mut/before.tsv (keep!),
after unit: build/mut/after-unit.tsv, formal: build/mut/after-formal.tsv.
"Killed before => killed after" for the directed suite holds by
construction (checks and MANIFEST only grew); after-dir is run only on
before-dir survivors plus a sample.

Equivalent / unspecified survivors: ALU07, BR06, SE04, SE05, MD07, RG01,
RG04 (x0 masked in core), and probably FC02 (csr_wb_hazard redundant with
the 3-cycle EX: worth telling the designer -- dead stall term).

Lessons (2026-10-19):
- Never edit a test file while a campaign runs against the working tree:
  a sys_enc edit (an unwritten x1 read) gave false kills in the +RF_X
  pass; those mutants were rescored. Freeze the tree (git archive) for
  campaigns.
- Kill a process by exact PID only: pgrep -f patterns match your own shell.
- MANIFEST is read line by line by a running run.sh: do not edit it then.
- Survivors to report as equivalent: ALU07 BR06 SE04 SE05 MD07 CT13 CT17
  GP03 TT01 (and FC02/FC27/FC49 if they survive the after suite).

## 2026-10-21/22 session (thinking stage; no code written)
Work orders parked in build/wo/ (untracked; user: nobody implements now):
WO-00 mutants FC80-85 (power-up-only resets, `r <= (r===1'bx)?rv:r`; verified
apply+compile, pass a normal run) + RFF01-04 (rf_fields); WO-01 directed
load_signs (FC25) / wfi_umode (FC45) / pmpaddr_refetch (FC32) / core_reset;
WO-02 tb_uart late-break sweep (UA07); WO-03 tb_rivercore +RESETS; WO-04
rf_fields spec model; WO-05 Pmod RAM fill (bitmap keeps DUT-written X);
WO-06 core formal. Not written: WO-07 GL, WO-08 docs, INDEX.
Probes (scratchpad, 2026-10-21): FC32 killed by a pmpaddr0-move probe (both
directions; Spike agrees with RTL); FC45 killed by U-mode WFI TW=0 mie=0
(needs a PMP entry for U, else cause 1 on both).
Correction to record in tb/VPLAN.md s4 when docs are next touched: commit
0980c78's body says the CSR formal kills "seven" mutants but lists six
(CS01-04, CS07, CS11); the measured number is 6. VPLAN s5 "sat unused" is stale.

## Candidate verdicts (2026-10-22, read-only on RTL)
- FC02 EQUIVALENT, proved: k-induction (len 3) on the whole core that
  csr_wb_hazard => !ex_ph, so stall_nofetch is unchanged in every reachable
  state. The real ordering guarantee is ex_wait (instruction behind a CSR
  write is in its first EX cycle while the write is in WB). Removable,
  ~2 cells, not on a critical path; keep as a guard or drop + fix comments.
- FC49 EQUIVALENT, proved: k-induction (len 3) of !(flush && muldiv_want),
  muldiv_ready/busy/done => muldiv_want (plus ex_ph=>ex_rf_ok and muldiv FSM
  invariants). All three flush gates on the M handshake are dead; removing
  !flush from muldiv_start takes ex_trap's ALU/PMA/PMP cone off the muldiv
  start path (possible timing win, STA not run).
- FC27 EQUIVALENT (argument): garbage rd writes during a load wait are
  unobservable: the only reader is EX, held by use_hazard until the final
  write; after a reset that cuts the wait x1-x31 are UNSPECIFIED (Priv 3.4).
- MD07 EQUIVALENT, proved (muldiv k-induction len 3): in the divide loop
  acc < m when m != 0 so sum[33]==sum[32]; m == 0 gives equal arms. No dead
  adder bit (bit 33 used by multiply).
- RG01/RG04: KILLED by test-regfile (after-unit.tsv); core-equivalent only
  (fyracore masks x0 reads). Not survivors.
- ALU07 BR06 SE04 SE05 MD07: unspecified/equivalent (unchanged).
Formal probe recipe for internal invariants: copy src to scratch, add
`ifdef FORMAL assert` in the copy, harness = core_props.sv with rf_top stub.
- 2026-10-22 review of WO-03 (cf4af8c memory_model !rst writes, b5f0301
  +RESETS in tb_rivercore, on ac2860e): APPROVED. No dump-path change; without
  the plusargs only spin-streak reset and rf_chk_armed=!rst differ, both inert
  outside a reset. NOTE "dump lines" = instr_count = lines written. Reset-trace
  checker is acceptance-only (build/wo-03), not committed; core_reset (WO-01 B)
  self-checks via x11 = boots, so it does not need it. Non-blocking asks:
  ERROR if a reset is raised after saw_tohost; NOTE could add EX valid.
- 2026-10-22 review of WO-02 (7467761, tb_uart late-break sweep): APPROVED.
  Boundary 136*d = 8.5 bits x 16 (spec), L0 137/273/410 within +-(16d+4);
  UA07 killed at 136 (d1), 272/273 (d2), 408 (d3). fail() alone makes the
  bench FAIL (errors -> final FAIL line). Deterministic per seed, but rd8/idle
  consume $random(seed), so later sections' stimulus per seed changed.
  Non-blocking: comment the 136 derivation at tb_uart.v:1158.
- 2026-10-22 review of WO-01 Part B + WO-03 follow-ups (af75f21 ERROR on a
  reset after tohost, 7344de1 ", ex valid" on NOTE, 45690b5 core_reset):
  APPROVED. Kills FC80 FC82 FC83 FC85. FC81 EQUIVALENT (timing only: stale
  wfi_active clears on the first post-reset cycle because csr.v resets mie to
  0 and wfi_wake has !wfi_has_enabled_irq; costs <=1 stall cycle and maybe one
  repeated boot fetch, which CPU ref 5.1 allows; relies on mie's reset value,
  which tb_csr pins). FC84 EQUIVALENT (strict: every use of exwb_memWR --
  dmem_req, wb_mem_write, the tb bus check -- is gated by exwb_valid, which
  resets; the stale bit is overwritten on the first post-reset cycle).
  Loop changed to LR/DIV/SW/AMO/ECALL with an M-mode WFI in the ECALL
  handler because the RTL NOPs U-mode WFI (see SA-006); probe 2026-10-22
  (build/wo-01brev/cr_wfi.*) confirmed U-mode WFI falls through with MTIE=1
  and the timer not pending.
- 2026-10-22 review of WO-04 (cc92ed9, tb_rf_fields spec model): APPROVED.
  Per-instruction table (quadrant/funct3/fields), not rf_fields' sp/prime
  formulas; legality agrees with compressed_decoder on all 49,152 parcels;
  independence shown (shared rs1' fault: old PASS, new FAIL). Illegal words
  are not checked (correct: they trap, a macro read is harmless). SYSTEM rs1
  read only for funct3 001-011 is right. Non-blocking: MISC-MEM (line 118)
  models FENCE/FENCE.I as reading rs1; per Unpriv the field is ignored --
  my WO's over-spec, harmless (rf_fields always passes [19:15] for 32-bit).
  Status: REQ-RFF-001 now has an independent checker.
- 2026-10-22 review of WO-05 (399e93b Pmod RAM fill-free + bitmap) and small
  edits 3ebdd44 e68d01b cc1a78f: APPROVED. Unit probe (build/wo-05rev/t.v) on
  the committed model: DUT-written X -> X, never written -> 0, hier-loaded ->
  as loaded, set bit via variable bit-select works, an X bitmap bit takes the
  "not written" arm. Only semantic change vs zero-fill: a byte a bench pokes
  to X hierarchically now reads 0 (no bench does). Raw pmod.ram readers left:
  tb_qspi_stress (after its own full fill), tb_tt_um ram_word (written
  addresses, all-nonzero expected words), tb_rivercore MEMARR (load + X-aware
  check). Non-blocking: dead `integer k` (model:159), tb_tt_um could use ram_rd.
- 2026-10-22 review of WO-06 (3730072 stub, 813d77a core_hold, 49b8589
  core_req, bb2e36a run.py FORMAL map): APPROVED. Re-ran core_hold:
  PROVED length 1; init-attribute constraints imported once (base case only),
  8 asserts imported in base and step, so the induction is over the core's
  state, not pinned. No assume anywhere in tb/formal (so -set-assumes is a
  no-op, csr unchanged); rst_in and boot_addr free; free RF data is a sound
  over-approximation for these safety properties. run.py mapping checked:
  fyracore.v -> core_hold+core_req, regFile.v -> core_hold. Power-up-only
  mutants FC80/FC85 survive both harnesses (no X-semantics artefact kills).
  Non-blocking: run.sh:40-43/49-53 count a yosys error/timeout as FAILED,
  which run.py scores as KILLED; distinguish "no verdict".
  Status: REQ-MEM-001 formally proven (both ports); REQ-MEM-002 bounded 10.

## 2026-10-23 session (planning; no code, no commits): WO-10..WO-19
INDEX: build/wo/INDEX-2026-10-23.md (copy in localFiles/verif-reports-2026-10-23/wo/).
- WO-10 wfi_umode pinned to NOP + TB-006 handler fix + FC86 (probed: RTL x20=8
  x21=4 x24=1 both timing variants; FC86 x20=0x80000007 x21=0 x24=0).
- WO-11 tb CLINT window 0x0200BFFF, MEIP hook 0x02008000 (hart 2048's mtimecmp
  slot), pma_edges edge test (fails on old bench at line 68, probed), dtb reg
  0xc000 (inert), CPU ref 156/188. Only pma_edges.ref regenerates.
- WO-12 mailbox: FINISH QEMU codes at +0x0; EVENT/VALUE/VALUE2 +0x7F0/4/8,
  +0x7FC spare (coordinator correction: +0xF00 unreachable by 12-bit offset);
  DRAIN before FINISH; verdict at FINISH; req_hold_check rst || done. Must land
  before WO-20 (syscon RTL).
- WO-13 docs for 10-12. WO-14 unit bench + REQ-SYS-001..013 + assumptions
  A1-A13 (reconcile vs WO-20/WO-21). WO-15/16 tb_syscon_soc (alphaone_soc,
  model-checks every syscon load; multi-boot programs). WO-17 tb_tt_um
  tt_reboot (pins only). WO-18 mutants SY01-20, AS01-06. WO-19 formal
  (shadow model BMC 16, two-copy miter for rst_soc comb dependence,
  structural no-async-rst_soc), docs, final regression.
- Design side (riscv-design-reviewer): WO-20 syscon RTL, WO-21 docs. The
  run.sh line-96 `syscon` token belongs in WO-20's wiring commit.
- Order caveat: land WO-10/11 before WO-20 starts or after its A6 (it diffs
  run.sh soc dumps base vs head).

## 2026-10-23 evening: reviews and amendments
- WO-11 review (dfdd90a f2674bd f6fc76d 4ef3499 on 81934d7): APPROVED. Checked:
  committed dtb == dtc(new dts); pma_edges.ref == my probe ref; no stale
  window/hook address in tb/, tests/directed, plugins (left by design:
  ROADMAP 1.5 -> WO-13; fyracore.v:45 comment -> designer; core_reset's
  0x0200C000 is a base for -8 = mtime). Haiku: core 167/167 (+RF_X too),
  SoC 101/101, old bench fails pma_edges at line 68, FC62/FC63 killed.
  Non-blocking: pma_edges.S header line 11 too wide; memory_model checker
  comment mis-wrapped; tb_rivercore comment cites untracked
  build/wo/probes/clint-offsets.S (my WO's wording) -- describe in words.
- WO-22 (designer, user-added watchdog) amendments made in place to
  WO-14..19 (each says so at its top): SYS-014..018; A14-A17; unit bench
  drives wdt_tap (scaled counter), all 16 TOPs, sweep skips the window then
  sweeps it last + pin reset; WO-15 bench predicts fires from soc.mtime,
  alias probes drop bit 8 (+0x100/+0x104 are CR/TORR; use +0x200.., +0x300..),
  new syscon_wdt (TOP 0 real scale: reboot in (65536, 98305] clocks,
  RESET_CAUSE 0x5 after); WO-16 power-off arms the watchdog, 200k-clock
  watch, pin reset inside a watchdog hold (phases by GPIO IN[7:6]); WO-17
  tt_reboot gains a watchdog boot ('w', next boot reports 0x07); WO-18 41
  faults (SY01-20, WD01-14, AS01-07; --check total 291); WO-19 depth 24,
  miter lets wdt_tap differ, third harness syscon_wdt (tap = counter,
  never-early for TOP 0-1). Order: WO-20 -> WO-22 code -> WO-14..19.
- WO-12 review (d3cfd91 28e95bf 8e59169 on 4ef3499): APPROVED. Matches the
  WO: periph.h defines (0x000/0x7F0/0x7F4/0x7F8/0x7FC, FINISH_* codes),
  DRAIN (TEMT + OUT rewrite), EPILOGUE (code<<16|0x3333, drain, sw), exact
  decode with lane check, verdict at FINISH (rx_fin/oled_fin/res_fin),
  checkers on rst || done (done declared above them), periph_access probe
  at MB_SPARE, clint_decode comments. The `done` race at the FINISH edge is
  harmless: power-off resets the core at E1 and the checkers see done by E1.
  Non-blocking: periph_access.S header lines 3-4 mis-wrapped (113 chars).
  Coder's checks: test-soc-periph 8 PASS, wrapper 3 PASS, 4 negative
  controls FAIL as expected, 13 SoC mutants still killed (same kinds).

## 2026-10-23 late: reconcile before WO-14 (syscon verification next, user's choice)
- Committed: WO-20 8d54e14 + 8b29cf8, WO-22 a133652, docs 54a0cb5..23a0980,
  e5868dc, c0cbd49 (HEAD). WO-10..13 also landed (11f1bb2 d049196 81934d7;
  dfdd90a..4ef3499; d3cfd91 28e95bf 8e59169; 9dd59de 7834aee d42833a).
- syscon.v as built: ports clk rst rst_soc sel we be[3:0] addr[15:2]
  wdata rdata strap_rd_late rd_late wdt_tap[15:0]; flops rq rq2 off strap_q
  cause[2:0] boot_mode[7:0] (on rst), en top[3:0] cnt[1:0] tprev (on
  rst_soc); hit = addr[15:5]==0, whit = addr[15:8]==1; tprev <= w_torr|tap;
  fire = en & tick & cnt==2 (kick/TORR in the fire cycle do not stop it:
  SA-008). alphaone_soc: soc.rst_soc, soc.mtime[63:0], soc.syscon_inst,
  instances cpu bus memc qspi clint_inst uart_inst gpio_inst.
- Exact mutant catalogue: build/wo/probes/syscon_mutants_draft.py (42:
  SY01-20, WD01-15, AS01-07), each find once at c0cbd49, all compile.
  Designer smokes (WO-20-acc, WO-22-acc) miss SY03 SY12 WD11 AS06.
- AS06 (mem_ctrl on rst) only shows when a reboot lands while mem_ctrl's
  `second` flop is set (between the halves of a PSRAM fetch split at a 1 KB
  page): the stale flop replays a bogus second half as the next boot's
  first fetch. FINISH reboots never land there (store completes ~4 clocks
  into the next fetch); a pin reset clears mem_ctrl, so power-off can't
  show it. Probe (build/wo/probes/wdt_split_reboot.S, tb_wdt_split.v):
  watchdog reboots while spinning on `j .` at 0x800003FE: RTL 12/12 recover
  (8 with second=1); AS06 hangs after the first. -> WO-15 syscon_wdt_split.
- WO-14 ready: all dependencies merged.

## 2026-10-24: WO-14 review (8eeba2e, tb/tb_syscon.v + syscon_spec.vh) -> CHANGES REQUIRED
- Model independent (hold as a 2->0 counter, ticks saturate at 2, tprev
  reset 1, watchdog frozen on every held edge); shared terms fire =
  en&tick&ticks==2 and tprev = torr|tap are WO-22 W3/W6 text.
- Blocking: (1) no directed case for a FINISH/power-off store one clock
  BEFORE the predicted fire -> SA-009 (DUT fires on E1); random reaches it
  ~0.3x per seed (seed 1: 239 random fires x ~0.0016 acting FINISH/running
  clock), so test-seeds 1-8 is a latent flake; (2) offset sweep vacuous for
  W1C aliases (cause = 0 after the a=1 store) and never stores FINISH codes
  at +0x04..+0x1C (my WO text excluded them; random gives codes only to
  +0x00) -> a FINISH alias at +0x10 survives; (3) bench overrides CHIP_ID
  with the spec value, the shipped default is never read.
- Accepted: idle cut after fires (post-fire state TOP-independent, one
  200k idle > 3*P15+1), reset rate 1/6 in holds (~69% complete), sweep
  window top-down, reads during rst unchecked (rd_late still checked).
- Seeds 1-3 PASS (build/wo-14 logs); bad-kick counter counts attempts (4813).
- 2026-10-24: Haiku accepted 8eeba2e (seeds 1-4, 9/9 negs, test-all 43 vs 42).
  User decided SA-009 = RTL gate (WO-23). Wrote WO-14a (bench fix-ups B1-B3,
  N1-N4, negs WD16/NB2a/NB2b/NB3, test-seeds 8 seeds as the flake check).
  Amended WO-18 (WD16; WD03 find -> "tick & (cnt == 2'd2)", the old full line
  breaks after WO-23; 43 faults, --check 36 syscon.v / 293 total), WO-19
  (syscon_gate harness, induct, PROVED; WD16 must FAIL it), WO-14 (SYS-019,
  A18), INDEX. Draft mutants file updated (build/wo/probes/...draft.py).
- 2026-10-24: WO-23 accepted (f9c34a6, fire line now src/syscon.v:120). WO-14a
  review (a9d6115 f355714 7575c8b 369e90c c2ebe57, tb_syscon.v only):
  APPROVED with notes. B1-B3, N1-N4 as specified. Accepted deviations: kick
  steering from MODEL state (3/20 while m_en && ticks>0) and a SOFT-W1C
  steer + 1/3 FINISH bias toward 0x7777: model state is a function of the
  seed only (never of DUT outputs), so stimulus stays DUT-independent and
  reproducible. All 43 draft find strings occur once at f9c34a6. WO-14a
  acceptance amended: base f9c34a6, flake gate = tb_syscon seeds 1-8
  directly; make test-seeds informational (tb_uart +SEED=4 floor).
- 2026-10-24: WO-14a accepted by Haiku (13/13 negs, old bench NB2a/b/3 PASS
  = holes were real, seeds 1-8 PASS). WO-15 reconciled at bef364b: names
  and the 43 mutant strings hold; model now states "no fire on held edges"
  (A18); no SoC pre-fire case (unit + formal cover it); syscon_regs alias
  sweep moved before the PIN W1C (same vacuity as WO-14's sweep) and FINISH
  codes stored at +0x0C..+0x1C; no CHIP_ID override. Ready for the coder.
  WO-16 (power-off with the watchdog armed) inherits the same model rule:
  check it at its reconcile.
- 2026-10-24: WO-15 review (d53eeb4..4a28a5c): APPROVED with notes. Model
  from syscon_spec.vh (no syscon_inst refs; observes dmem port, soc.mtime,
  rst_soc), A18 explicit (held branch computes no fire). Lessons:
  * "a FINISH store completes ~4 clocks into the next fetch" was LAYOUT-
    dependent: after a sw whose next instruction is in the same fetched
    word (RVC), the engine is idle at E1. REBOOT_ON_FETCH (.option norvc,
    .balign 4, sw; nop) forces a fetch in flight. AS06 conclusion unchanged
    (a FINISH reboot never lands mid-split; wdt_split is the only killer).
  * QSPI_LATE (+QSPI_DELAY=25 +QSPI_HOLD=12) has no eye at a 20 ns clock;
    benches using it run at 10 ns (tb_qspi, tb_tt_um, tb_syscon_soc +RD_LATE).
  * wdt_split split-2nd hits 3/12 (my probe 8/12; different phase sweep).
  Notes: lo = 1 << (16+TOP) overflows at TOP 15 (tb_syscon_soc.v:358);
  no per-test syscon-load floor (a program that skips its body to
  test_pass would still PASS).
- 2026-10-24: WO-16 reconciled at 4a28a5c. Added B0 (64-bit lo :231/:358,
  min_loads per test replacing n_loads==0 at :463, :40-43 comment, syscon_
  reboot n_cut>=1), power-off watch as explicit bench edits (first poweroff
  = watch, cls_off floor, sck stable), two-edge pin resets timed from the
  MODEL (FINISH hold: rst over E2-E3; wdt hold: over E1-E2) -- the wrapper
  never gives a 1-edge rst. Insight: a watchdog fire during power-off is
  unobservable at SoC level (rst_soc already high, only rst exits and
  rewrites RESET_CAUSE); SYS-008 no-fire = unit + formal only. New SY21
  (rq/rq2 not reset by rst), draft 44 faults, --check 37/294; WO-18 + INDEX
  updated.
- 2026-10-24: WO-16 review (f512fd2 78e7772 a816d11): APPROVED with notes.
  User trimmed the watch to 5,000 clocks (mtime held at 0 while off). SY21
  as I drafted it was a bad mutant: deleting rq/rq2's rst assignments left
  them X from power-up (no initial) -> rst_soc X, all runs fail trivially.
  LESSON: a mutant that removes a reset must keep power-up defined; use
  `x <= (x === 1'b1)` (hold through rst, X->0) or an equivalent. Corrected
  SY21 in the draft + WO-18 (compiles, once). New user rules: target sky26d
  unless told otherwise; one sandbox harden + one river_core run after ALL
  remaining WOs, not per WO. WO-17 not reconciled (user: stop after WO-16).
- 2026-10-25: user decided the branch review (localFiles/review-2026-10-24/
  syscon-branch-review.html). Amended WO-17 (F6: 'w' cue before the kick,
  upper bound +CUE_TO_KICK 1000; every boot sets DLL=1 -- the wrapper's SoC
  resets the UART divisor to 27 at each reboot; +TEST=reboot uses prologue
  phase 1 only; AS08 neg control), WO-18 (45 faults, AS08 = cpu .rst(rst):
  find "    ) cpu (\n        .clk         (clk),\n        .rst         (rst_soc),";
  bench commit: held qspi_sck==0 + syscon_regs min_loads 302; sandbox
  campaign in 3 stages, ~4 h at -j1 from measured bench times: test-syscon
  40 s, soc-periph 30 s, syscon-soc 75 s, wrapper 6 s (+~25 s with WO-17);
  run.py works from any tree root, relative --results resolves to ROOT),
  WO-19 (trimmed to syscon_comb/syscon_gate/soc_rst_sync + docs F1/F2/F9/
  F13, VPLAN rescore incl FC86, CLAUDE.md). New trailer session
  019AGtNpvpJiU7zQxfhZUJEn. Order: 17 -> 18 (sandbox) -> 19 -> one sandbox
  harden (sky26d) + river_core -> SPI design.
- 2026-10-25: WO-17 review (c2d6698 04784ac cea9ee4): APPROVED with notes.
  "One transition per pin into the window" read per entry cycle (the run-up
  has SD-enable toggles from fetches); quiet pins (uo_out, ctl enables)
  could be counted from the cue -- non-blocking. SY12 at the pins dies by
  fetch failure (rd_late flips the sampling point), not by the STRAPS byte;
  SY18 exercises the STRAPS byte. 'w' cue->window 74957/74843 (bound
  65536 < d <= 99306). WO-18 unaffected (no src/run.py/syscon_soc change);
  test-wrapper ~+12-15 s per mutant (2 x 110k-cycle runs), within the ~30 s
  estimate.
- 2026-10-25: WO-19 part A review (4390e7c..48666ae): CHANGES REQUIRED, two
  one-line wording fixes (CLAUDE.md:68 overstates syscon_gate P2 -- EN can
  still read 1 in the first held cycle -- and "showing" for the bounded
  miter; soc-architecture RESET_CAUSE "our kernel and flash loader do so"
  claims software that does not exist yet). Harnesses match the WO.
  soc_rst_sync = python walk of write_json (yosys `select %co*` returned
  nothing in 0.66): conservative (whole-cell output propagation), stops at
  flops/$mem/latches; flattened SoC at HEAD has 143 $dff, 1 $mem_v2, no
  latch, no async flop (yosys stat, build/wo19rev/stat.txt), so it is a
  regression guard; non-vacuity = async CLINT copy FAILED.
- 2026-10-25: WO-19 part B review (660bf74 0e723d7 a4ac1d0): CHANGES
  REQUIRED, two VPLAN prose edits. Report on all-wo19.tsv reproduces
  report-all-wo19.txt byte for byte (283/295, 12 survivors with verdicts).
  MY ERROR, found here: the VPLAN's "directed core 193/206" (e4de29c,
  2026-10-20) was the core-files ANY-BENCH count copied into the directed
  row -- both rows read 193/206 in e4de29c. Files give directed 173/206
  (after-dir), 176/206 with WO-01's tests, 181/213 with FC80-86. CL01-07
  (clint.v, not in the core bench) and the unit-only CS faults can never be
  directed kills, so directed could not equal any-bench. The 95% figure
  (any bench: 206/216 then, 207/217 now) was right. Also stale prose:
  after-dir.tsv and after-soc.tsv (2026-10-22, regenerated after the
  10-21 build/ wipe) are full reruns, not "68 survivors only" / "before
  only". LESSON: derive every table cell with --report and name the file;
  never fill one row from another.
- 2026-10-25: wrote WO-24 (EQY RTL vs post-PnR nl netlist) and WO-25 (pnl
  netlist in tb_tt_um: A tt_pins/tt_reboot, B 75 riscv-tests, C 101 arch
  tests with PSRAM-read signatures vs Spike, RTL baseline, mutants; D the
  16 mailbox SoC programs only if the user approves). Netlist facts:
  1,307 flops (1,304 dfxtp, dfrtp run, dfstp rst_sync[0]/rst), instance
  names auto (_25567_) but 1,299 Q NETS carry RTL names (\soc.cpu...), 8
  named after output nets; 1,377 dlygate4sd3; harden src md5 == branch
  src (21 files, regs.v not in the list); TT GL defines GL_TEST FUNCTIONAL
  USE_POWER_PINS SIM UNIT_DELAY=#1 (UNIT_DELAY only on flops); pnl for GL,
  nl for EQY. GL speed ~10 instr/s: arch tests ~157k instr (river_core
  dump lines), riscv-tests ~27k. Sandbox suites: build/mywork-conf/riscof/
  riscv-arch-test, build/mywork-conf/riscv_tests.
- 2026-10-25: WO-24 amended with the pd-expert's facts: nl md5 fbf13f22...;
  liberty from PDK versions/8afc8346 (sky130A symlink -> 0536d02d, tt lib
  identical); fill_1/fill_2/tapvpwrvgnd_1 need stubs; NO SMT solvers
  (EQY sat + sby abc pdr only). Flop accounting: gold 1,485 = 1,286 name
  + 5 renames + 8 FSM bits (one-hot recode: exwb_memSize 2->3, muldiv st
  3->6, qspi state 3->7; 8 FALSE name pairs on the low bits) + 186 removed
  (184 constant CSR WARL bits via opt_dff X-init folding, 2 unused gpio);
  gate 1,307 = 1,286 + 5 + 16. MY DECISION: prove an RTL lemma (each of
  the 184 bits == its constant once armed, FSMs never hold unlisted codes;
  yosys sat -tempinduct), then tie the constants on gold from a generated
  list; untied-constant mutant must FAIL. WO-25: D skipped by the user;
  PSRAM signature readout approved; use 8afc8346 cell Verilog models; the
  RF macro is behavioural in GL and a black box in EQY (not covered).
- 2026-10-26: WO-24 prove-stage decision: drop [recode]; nomatch the 24
  FSM bits; init = RTL reset value (gold 0, gate one-hot bit0) on those
  24 only; sat then abc pdr 600 s; awk shim. Evidence plan-exp/real: the
  5 previously FAIL/UNKNOWN partitions PASS by pdr in 4-20 s; realneg
  (wrong one-hot init) FAILs. Soundness = equivalence from the FSM reset
  state (same premise as the 184-bit lemma). Stop rule in the WO.
- 2026-10-27: WO-24 amended (lean finish). Adopted the tie-order fix and 6 nomatch globs
  (reg2); q1 is void. FAIL classes: setup artefact / unreachable cut (both open, never
  proved) / finding (stop). Open partitions are referred to WO-25 and river_core.
- 2026-10-28: WO-24 closure plan (amendment 2026-10-28). FSM cut point: gold
  Q -> <cut>, readers clamp(<cut>); gate one-hot Q -> __oh, <cut> = enc(oh),
  readers onehot(clamp(<cut>)); plus an own net for the rf_top w_ena pin on
  both sides (hit1/hit2 read the computed w_ena). Soundness = L2 (gold, have)
  + new gate one-hot invariant (sat -tempinduct, k=1, PROVED) + EQY. A wrong
  table (qspi bits 1/2 swapped) FAILs soc.qspi.fsmcut_state. plan-exp3: 157
  partitions; hit1, hit2 and the former TIMEOUTs prove by sat in seconds to
  minutes (see WO amendment for the exact list).
  Result: 23 of 24 closed by sat (hit1, hit2, 21 TIMEOUTs; ifex_pc.1 is now
  ifex_pc.0). Residue: amo_old_val.0 (11.5k cells, combinational D cone of a
  32-bit reg): sat 19 min no answer, pdr TIMEOUT 600 s; `[collect] solo` does
  not split it. Next: per-bit combinational miter + yosys-abc &cec (WO-26).
  EQY sat has NO timeout (a hard partition hangs the run); strategy
  apply/noapply rules take only `*` or an exact partition name.

## WO-26 (planned 2026-10-29): WO-25 part D, 16 mailbox programs at the pins
- build/wo/WO-26-gl-soc-programs.md. Status: planned (no code). MB_UART frames 0x10-0x13
  (EVENT_P/VALUE/VALUE2/FINISH), +TEST=soc +PROG= in tb_tt_um, T20 image for oled_spi,
  irq_stall, periph_access; per-program MB_DIV; irq_stall logs to PSRAM 0x80FF_F000.
- Coverage at the pins: 7 fully, 9 partly, 0 none. Open user decision: C8 (floors re-measured
  on the MB_UART builds through tb_soc_periph/tb_syscon_soc).

## SPI controller (WO-29, planned 2026-10-30; build/wo/WO-29-spi-verification.md)
REQ-SPI-001..020 -> tb_spi (T01-T14, PROBE, RT sweep), test-soc-spi (sd_init,
sd_b1, spi_mixed, sd_reboot, 3 expected-fail controls), formal spi_core/dc/bus
(32 props, induct L1 via expose), spi_bb (BMC 40), spi_cover (6), spi_f12
(struct); mutants SPI01-SPI32. Status: planned (RTL WO-28 in progress).

## 2026-11-07 planner C
- VC-1 -> WO-35 (EQY refit to fin-3x4: derived accounting 1528/1349/1323/7/10-19/188; 186 constants incl. gpio out_r[1],[3]; 4th FSM cut; 7 mutants + pdr confirm). VC-8 -> WO-34 (glitch_mon on tb_tt_um, SDF pnl; non-vacuity = TT01 + SoC pin-gate inputs +2 ns must FAIL; the real TT01 netlist (N1) gives the verdict, either outcome legal).

## 2026-11-07 VC planner A (WOs only, no code)
WO-30 (run.sh sidecars/FORMAL_BIN/sby engine/--nonvac/--cover, deeper csr/syscon_comb/spi_bb/core_req),
WO-31 (bus BA1-5; mem MF1-3 MT1-2 MD1-3 ML1-2 by pdr; qspi_strap miter kills QS06; core_df BMC
discharges M-A4 DF_N=2), WO-32 (md07 pdr/len1 + md07_miter BMC; core_inv FC02/FC49 via expose),
WO-33 (floors by quota steering TB-007/TB-009; SA-008 K1-K4), WO-39 (run.py FORMAL map, formal-only
campaign, VPLAN/CLAUDE.md). Index build/wo/INDEX-VC-A.md. PROVED = length 1 or abc pdr PASS (user Q open).
SA-008 is now docs text (soc-architecture.md "SA-008" paragraph: fire wins) -> spec, not ambiguity.

## VC-5 riscv-formal (planned 2026-11-07, WO-36/37/38, build/wo/INDEX-VC-B.md)
Status: planned. RVFI port in fyracore.v under ifdef RISCV_FORMAL (+ALTOPS hook on
muldiv .result); wrapper tb/rvfi: full-RAM PMA, env = M-mode/no PMP lock/no MPRV-U/
misa.C=1 (assumes on fv_ taps), free mem data + bounded ready, RF model with free
init + free collision value, custom fyra_imem check. Depths: insn 20, shifts/M at
measured min+3, consistency 10-30, liveness ~62. Not verified "until WO-38 PASS +
non-vacuity matrix". Mutant map in WO-38 step 3.
- 2026-11-07 review WO-30 stage A (3ed605a 1d9a5dc be95413): APPROVED as base. Fixups: armed-gate
  syscon_comb + spi_bus (they relied on sat -set-init-zero; sby starts flops free); nonvac must be a
  real CEX (induct -> bmc NVDEPTH 24; "did not close" = MISS); sidecar covers via sby as <n>_cov
  (sat cover loop is spi_cover-only); PRE branch PROPN. sby bmc ~20x faster than sat (spi_bb 7 s vs 157 s).
  Finding: run.py counts "induction did not close" as a kill -> N3 35/35 may include non-CEX kills.
