---
name: finding-branch-review-2026-09-12
description: Findings from the adversarial review of fixing-verification_alfadelta10010 (PMA, misa.C, counters, mstatus WARL, tb retire budget) — IDs, status, repro method
metadata:
  type: project
---

Review of `git diff main...HEAD -- src/ tb/` (merge-base cb8f051, HEAD 93735c4), 2026-09-12.
All reproduced with a scratch harness (asm -> DUT tb_rivercore + local Spike
`/tools/rv32-isa-sim/bin/spike`, same flags as the flow, **without** `--instructions`).
Status of all: OPEN as of 2026-09-12. Locate by signal name; line numbers drift.

Silicon/spec (RTL):
- R1 MAJOR (pre-existing, not previously recorded): csr.v write block is `trap > mret > we`,
  and `mret` is the EX-stage MRET. A CSR write in WB is DISCARDED when MRET is in EX.
  `csrw mstatus,0x1880; mret` -> DUT mstatus 0x80, Spike 0x88. `csrw mepc,X; mret` -> mepc
  write lost (MRET still jumps right via mepc_fwd). tb dump still prints the dropped write.
- R2 MAJOR (new instance via PMA): `ex_is_mret` not gated by `ex_trap`; a fetch-faulting word
  that decodes as MRET applies MRET side effects (mstatus + priv_mode) before the cause-1
  trap commits. Repro: jump to unmapped alias of an MRET with mstatus=0x80 -> DUT trap
  mstatus 0x80 (MPP=U), Spike 0x1800.
- R3 MAJOR: misa.C not forwarded to IF (`ifex_c_illegal`) or `ex_inst_misalign`: 2-instruction
  stale window after csrci/csrsi misa. Repro: `csrci misa,4; c.addi; c.addi` — DUT executes
  both, Spike traps cause 2. Violates Zicsr "observable by the very next instruction".
- R4 MAJOR: misa now advertises U but mstatus lacks MPRV(17) and TW(21). Spike reads back
  0x00221888 for `csrw mstatus,-1`; DUT 0x1888. MPRV is mandatory when U is supported.
- R5 MINOR: 32-bit fetch straddling PMA_MEM_TOP not faulted (PMA and PMP only check ifex_pc).
  Repro at 0x81FFFFFE: DUT executes insn with X upper half (writes X to rd); Spike cause 1,
  mepc=0x81FFFFFE, mtval=0x82000000.
- R6 MINOR (new instance of known priority bug): illegal JALR (funct3!=0) with misaligned
  target under misa.C=0 -> DUT cause 0, Spike 2. Illegal load enc. at ANY aligned unmapped
  address -> DUT cause 5, Spike 2 (PMA widened reach of finding-exception-priority).
- R7 MINOR: forwarding path (`csr_fwd_data`) has no mask for 0x320 (reads 0xFFFFFFFF after
  `csrw mcountinhibit,-1`) and no IALIGN mask of mepc[1] (reads 0x80000102 with C=0; Spike 0x100).
- R8 MINOR/NIT: marchid=5 is Spike's registered open-source ID; mimpid 0. Parameterize, tb overrides.
- Dead ports: csr_mcounteren / csr_inhibit_cy / csr_inhibit_ir unused in fyracore.

Verification (tb + its contract with the Spike plugin):
- V1 CRITICAL (verif): Spike `--instructions=N` does not bound instructions. sim_t::idle()
  subtracts INTERLEAVE per chunk; processor step returns early at every trap. At 200005,
  Spike quits after ~40 traps (100-ecall loop: 248 lines, never reaches end). <5000 -> quits
  at first trap. So ab7bc82's "both stop on the same instruction" is false; trap-heavy tests
  fail spuriously. Mechanism is plugin-side but the tb MAX_INSTR design depends on it.
- V2 MAJOR (verif): tb PMA window narrower than Spike's device map: Spike maps boot ROM
  0x1000, CLINT 0x02000000+0xC0000, PLIC 0x0C000000+16MB, UART 0x10000000+0x100. Loads there
  succeed in Spike, cause 5 in DUT. Fetch from CLINT: Spike cause 2 (executes msip=0), DUT
  cause 1 — the RTL comment "which is also what the reference model does" is false.
- V3: illegal-instr mtval=0 comment "Spike reports mtval=0" is false: Spike writes insn bits
  (0xffffffff, 0x00229067). riscv-tests illegal.S uses `.word 0` so both are 0 there.
  Use ifex_raw_instr to match Spike exactly (spec-legal either way).
- V4: lockstep-only (DUT spec-legal): Spike lets misa M and A be cleared; Spike legalizes
  MPP=01 -> 00, DUT keeps old MPP; mcountinhibit toggle instruction counted per old value
  in DUT (spec: "CSR write takes effect after the writing instruction has otherwise
  completed") vs new value in Spike; minstret absolute values differ by Spike's 5 ROM insns.

Verified OK (do not re-raise): misa refuse-clear at PC[1]=1 matches Spike incl. no log;
minstret low-write carry into minstreth matches Spike; minstret_next read semantics;
C.LUI rd=x0 HINT; EBREAK mtval=PC; BASE>TOP window matches nothing; data PMA on first byte is
sufficient because misaligned traps first and windows are 4-byte aligned.

Related: [[finding-exception-priority-illegal-vs-misaligned]], [[finding-mret-multicommit-on-stall]],
[[reference-spike-probed-behaviours]], [[project-fyracore-overview]].
