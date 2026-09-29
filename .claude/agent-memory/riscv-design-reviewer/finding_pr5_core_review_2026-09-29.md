---
name: finding-pr5-core-review-2026-09-29
description: Adversarial PR #5 review of the core slice (fyracore/csr/clint) at 4b4ed8b -- no Critical/Major; registered MTIP gives a legal stale mip / spurious interrupt for two instructions after an mtimecmp store
metadata:
  type: project
---

Reviewed fyracore.v, csr.v, clint.v at 4b4ed8b, 2026-09-29 (written by the parent
session: the brief made the repo read-only for this agent). Probes (full-trace
vs Spike 7ab2efd6 at several I/D wait timings unless marked DUT-only) are kept in
localFiles/pr5-review-2026-09-29/scratch/rv5/.

- m1 (legal, PROVEN): registered MTIP (clint.v:75-81) -> after a store moves
  mtimecmp into the future, mip.MTIP still reads 1 for the next two instructions
  (one cycle WB commit + the register). mtip_stale: expired mtimecmp, MTIE=1,
  `sw -1 -> mtimecmp_hi; csrsi mstatus,8` takes mcause 0x80000007 with mip=0 in
  the handler; Spike takes none; main's combinational clint takes none.
  Priv 3.2.1 "eventually ... spurious timer interrupt might occur". Linux safe:
  MRET leaves >=1 bubble, clint_clock_next_event runs with MIE=0.
- m2: stale docs (CLAUDE.md:137 + pma_flash.S:22 flash stub; CPU reference
  156-157 UART/GPIO "reserved"; 3.1/3.2 tables missing uart/gpio/benches).
- n1: boot_addr[0] loaded into pc unmasked (fyracore.v:1006) vs the
  halfword-aligned imem_addr contract.
- n2: mtvec reset 0 is unmapped -> blank flash = silent cause-1 loop at 0.
  User decided 2026-09-29: keep 0, document it.
- Verified: PMA edges/causes (misaligned before access fault, straddle mtval =
  faulting half, U-mode too), full Zalrsc must-fail list, trap clear on every
  trap incl. interrupts, MRET keeps the reservation (= Spike), counter
  write-replaces-increment across carries/aliases/stalls/ecall.
- Gaps: no test pins the stale-MTIP window; cnt_xhalf zero-wait core-only;
  flash-end straddle (0x20FF_FFFE) untested; pma_flash word-only.

**Why:** gate before merging the SoC branch.
**How to apply:** re-check only if clint/csr counters/PMA change.
