---
name: finding-exception-priority-illegal-vs-misaligned
description: MAJOR open finding — illegal-instruction (cause 2) is resolved last in fyracore's trap-cause chain, so an illegal load/store encoding with a misaligned address reports cause 4/6 instead of 2
metadata:
  type: project
---

**Status: OPEN (as of 2026-09-05 review). Reproduced against Spike.**

`src/fyracore.v:895-926` resolves simultaneous synchronous exceptions in this order:
`1 (I-fetch access fault) > 0 (inst addr misaligned) > 11/8 (ecall) > 3 (ebreak) > 4 > 6 > 5 > 7 > 2 (illegal)`.

Privileged spec v1.12 / 20211203, Table "Synchronous exception priority in decreasing priority
order" requires: `3 (inst bkpt) > 12/1 > 1 > **2 (illegal)** > 0 > 8/9/11 > 3 (ebreak) > [4,6] > [5,7]`.
Illegal instruction must outrank *everything* below instruction access fault; FyraCore puts it last.

The bug is reachable because `src/controller.v:115-129` and `:133-143` set `memRD`/`memWR` = 1 and
leave `memSize` at its block default `2'b10` (word) even on the `default: illegal = 1'b1` arms.
So an illegal LOAD (funct3 = 011/110/111) or STORE (funct3 = 011..111) still drives
`ex_mem_active` and can trigger `ex_misaligned` (`fyracore.v:343-347`).

Measured 2026-09-05 with a directed test:

| case | FyraCore mcause / mtval | Spike mcause / mtval |
|---|---|---|
| `.word 0x00053583` (illegal LD enc.) @ addr 0x80002001 | **4** / 0x80002001 | **2** / 0x00053583 |
| `.word 0x00b53023` (illegal SD enc.) @ addr 0x80002001 | **6** / 0x80002001 | **2** / 0x00b53023 |
| `lw` @ 0x80002001 (control) | 4 / 0x80002001 | 4 / 0x80002001 |
| illegal LD enc. @ aligned addr (control) | 2 / 0 | 2 / insn |

Same class of issue: a valid compressed instruction fetched while misa.C=0 expands normally, so a
misaligned `c.lw` reports 4 instead of 2.

Secondary (spec-legal, but a lockstep divergence): FyraCore writes `mtval = 0` on illegal
instruction (`fyracore.v:925`) where Spike writes the instruction bits. Permitted by the spec, and
the arch-tests do not compare it (cause 2 is absent from `SET_REL_TVAL_MSK`), so it only shows up in
a strict Spike lockstep.

**How to apply:** when reviewing the trap-cause chain, check that cause 2 is tested before the
data-access causes, and that illegal decodes do not leave `memRD`/`memWR` asserted.

Related: [[project-fyracore-overview]], [[verification-flow-river-core-riscof]].
