---
name: finding-branch-review-2026-09-24
description: Full review of riscv-compliance_alfadelta10010 at 7cd1eb6 (19 commits) — 2e6718b muldiv fix introduced two CRITICAL regressions, spurious trap redirect from garbage-forwarded load data, SC store withdrawn by trailing trap, MRET+irq double commit, CSR conformance gaps, repro recipes
metadata:
  type: project
---

Reviewed 2026-09-24 at HEAD 7cd1eb6 (checked out in the main repo, not a worktree).
**Status 2026-09-25: every item below verified FIXED — see [[finding-branch-review-2026-09-25]].**
Scratch harness pattern: copy src/tb to scratchpad, `iverilog` build, `run1.sh`
(asm -> DUT + Spike wrapped in `ulimit -f` + `timeout`), `tracecmp.sh` (first
divergence). **Never `pkill spike` globally** — the user runs other sessions.

## CRITICAL (all reproduced DUT vs Spike)

- **C1 muldiv phantom restart (regression, 2e6718b).** `muldiv_start` swapped
  `!muldiv_done` for `!muldiv_ready`, but ready is set at the END of the done cycle,
  so start fires again on the done cycle. The phantom op's `done` later sets ready
  (not gated by want) and the NEXT M-op captures it => every M-op after the first
  returns the previous op's result. `mul 3*5; mul 7*11` -> 15,15. **All 8 RV32M
  arch tests fail at HEAD; parent 4437a41 passes with 0 diff lines.** Masked at
  IMEM_WAIT>=2 (fetch stall covers the done cycle).
- **C2 fetch-fault on an M-op word deadlocks (regression, 2e6718b).**
  `muldiv_stall = want && !ready` no longer depends on start; start is blocked by
  flush (ex_trap) => stall forever. Repro: PMA (jump to 0x82000000 alias of a mul)
  and PMP (U-mode jump to X-denied mul). Parent traps correctly.
- **C3 spurious trap redirect during load-use stall.** `next_pc = trap_target` on
  `ex_trap` is NOT gated by stall; the consumer in EX computes with dmem_rdata
  forwarded before dmem_ready. Garbage address -> PMA/misalign ex_trap -> pc jumps
  to mtvec with no trap taken (handler runs with stale mcause). **tb/memory_model.v
  drives X while !ready and iverilog treats `if (X)` as false, which HIDES it**;
  reproduced by building a scratch tb returning 0 / LFSR garbage while !ready
  (`lw a0,0(s0); lw a1,0(a0)`, and via the AMO read phase). Pre-existing design,
  now reachable because loads legitimately wait.

## MAJOR

- SC store withdrawn: reservation clear uses EX-stage `ex_trap || irq_inject`,
  ungated by stall. `sc.w` waiting on dmem_ready + trapping insn behind it => clear
  mid-handshake, sc_success drops, dmem_we deasserts before ready, rd=1. DMEM_WAIT>=2.
  Fix: clear on WB trap commit (`csr_trap_signal`), not EX.
- MRET + irq in same cycle: `ex_mret_commit` not gated by `irq_inject`; MRET side
  effects AND the interrupt both commit (handler sees MPP=U, 0x80 vs Spike 0x1880).
  Only reachable with MIE=1 at MRET (Linux never). Fix: `!ex_is_mret` in irq_inject.
- mie write not forwarded to irq gating (only MIE is): enabling mie takes the irq one
  instruction late; after `csrc mie` an irq can still be taken (mepc after the csrc).
  Priv 3.1.9 "must also be evaluated immediately following ... an explicit write to
  ... mie". Reproduced both directions with msip.
- No request strobe on dmem/imem; memController.v SIM_MODE=0 infers a read from
  `dmem_wmask != 0`, which the core never drives for loads => hardware-mode loads
  return 0. Pre-existing, memController not instantiated.

## MINOR (reproduced)

- mip writable mask ~0x888 (should be 0: no S-mode, no Sscofpmf): `csrw mip,-1`
  reads 0xfffff777 (Spike 0x80). Forward path for 0x344 also drops the LIVE bits.
- mstatush, mhpmcounter3-31(h), mhpmevent3-31, menvcfg/menvcfgh trap (Spike 0).
  mstatush "mandatory RV32-only CSR"; menvcfg exists whenever U exists.
- SRET and funct7=0001000 rs2!=5 execute as NOP; MRET with rs2!=2 executes as MRET;
  LR.W with rs2!=0 executes. SRET "should raise illegal"; others reserved (UNSPECIFIED).
- `csrw minstret; csrr instret` stale (alias not forwarded).
- pmp.v ignores pmpaddr[31:30]: TOR pmpaddr=0x40000000 matches nothing (Spike all),
  NAPOT 0x9fffffff matches all (Spike none).
- Reservation compare full 32-bit: `sb` into bytes 1-3 of the reserved word does not
  clear, `sw` does — the "overlapping write" policy is only half implemented.
- R3 misa.C lag and R5 straddle re-confirmed at HEAD (straddle mtval 0x82000002 vs
  0x82000000). PMP straddle is the same hole (only ifex_pc checked).

- PMP straddle reproduced too: U-mode 32-bit insn at the last halfword of an X region executes
  (a0=0x123); Spike cause 1, mepc=start, mtval=start+2.

## Local arch-test at 7cd1eb6 (zero wait states)

101 applicable rv32i_m tests: 93 PASS, 8 FAIL — exactly the RV32M set. No PMP or interrupt
tests exist in 3.9.1, so arch-test cannot see C2/C3, SC withdrawal, MRET+irq, mie forwarding.

## Directed-test infrastructure facts

- run.sh suite = 21 chk calls over 17 tests; measured 20 PASS + 1 FAIL (lrsc_policy,
  legal divergence). 17 of 34 .S files are never invoked. chk compares only the LAST
  value of named registers — csrfwd and lrsc_io pass while their traces diverge.
- t_div and t_memstress (not wired in) expose C1 on a full-trace compare.
- t_straddle is vacuous: memory at 0x81FFFFFE is 0 -> c.illegal on both models.

Related: [[finding-branch-review-2026-09-22]], [[finding-lrsc-policy-2026-09-22]],
[[reference-spike-probed-behaviours]], [[reference-kianv-memory-map]].
