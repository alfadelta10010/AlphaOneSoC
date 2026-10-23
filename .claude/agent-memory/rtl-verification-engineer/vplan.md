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
