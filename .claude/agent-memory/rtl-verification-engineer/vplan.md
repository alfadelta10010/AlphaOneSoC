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
