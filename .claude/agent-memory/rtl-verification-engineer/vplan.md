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
