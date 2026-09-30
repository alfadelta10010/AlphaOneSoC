---
name: finding-lrsc-policy-2026-09-22
description: LR/SC reservation policy decision — spec citations from the local ratified copy, the trap-clear question, the phase-locked interrupt livelock (real but NOT critical), and the recommended signal list
metadata:
  type: project
---

Settled 2026-09-22 against `docs/RISCV-spec.html` (local ratified copy; convert with the
tag-strip snippet to /tmp/spec.txt). Supersedes the B4 section of
[[finding-branch-review-2026-09-22]], which over-claimed the trap clear.

## Normative sentences that decide this (Zalrsc, §7.2)

- SC always clears: *"Regardless of success or failure, executing an SC.W instruction
  invalidates any reservation held by this hart."*
- The **complete** must-fail list: address outside the reservation set; **another hart's**
  store to the reservation set; **another device's** write to the LR's bytes; another SC in
  between. **Same-hart stores/AMOs and traps are absent** — so clearing on them is
  permitted, not required.
- Blanket permission for conservatism: *"these definitions permit an implementation to fail
  an SC instruction occasionally for any reason, provided the aforementioned guarantee is
  not violated."*
- Constrained loop: *"The dynamic code executed between the LR and SC instructions can only
  contain instructions from the base ''I'' instruction set, excluding loads, stores,
  backward jumps, taken backward branches, JALR, FENCE, and SYSTEM instructions."*
  ⇒ a same-hart store, an AMO, or a trap handler between LR and SC all take the sequence
  **outside** the constrained set, and *"Implementations are permitted to unconditionally
  fail any unconstrained LR/SC sequence."* The "don't over-clear, you'll break forward
  progress" worry is therefore vacuous for all three of our clears.
- Eventuality guarantee lists **"H traps"** as a satisfying event ⇒ a trap can never violate
  it. Also means the spec never promised progress across our own interrupts.
- Software guidance: *"A store-conditional instruction to a scratch word of memory should be
  used to forcibly invalidate any existing load reservation: during a preemptive context
  switch"*. Reset: *"there is no valid load reservation."*

## Linux actually does the dummy SC

`arch/riscv/kernel/entry.S` `ret_from_exception`: `REG_L a2, PT_EPC(sp)` /
`REG_SC x0, a2, PT_EPC(sp)`, with a comment saying reservations can't be saved/restored.
**So Linux does not depend on our hardware trap clear** — my earlier "the one that actually
matters" was wrong. Keep the trap clear as defence for bare-metal/bootloader code, not
because Linux needs it.

## Measured policy matrix (DUT vs Spike, `t_lrsc_policy.S`)

| sequence | DUT | Spike |
|---|---|---|
| `lr; sw same addr; sc` | fail | **succeed** |
| `lr; amoadd same addr; sc` | **succeed** | succeed |
| `lr; ecall; sc` | fail | **fail** (Spike clears on trap too) |
| `lr; sc to unrelated word; sc` | fail | fail |

Both legal. The DUT's store-vs-AMO asymmetry is the only genuine defect.

## The interrupt livelock — REAL but NOT critical (retracted from CRITICAL)

4-instruction `lr/addi/sc/bnez` loop, timer rearmed `mtime+P` in the handler:
P=12 livelocks (60k retires, 3 stores) while an identical plain `lw/addi/sw` loop completes
100/100. Also locks at P=8, 6. Reproduced on post-fix RTL locally.

Closed form from the RTL: loop is **C=6 cycles** (lr EX, lr WB + load-use stall, addi, sc EX,
sc WB/branch resolve, flush). Reservation set end of cycle 1, sampled cycle 4. Vulnerable
cycles are only **2 and 3** (**W=2**) — cycle 1 is blocked because `load_use_hazard ∈
stall_other` gates `irq_inject`. Two regimes: a **floor** (P below handler-tail +
resume-to-sample ⇒ always locks) and a **congruence** (P in one residue class mod C).
Wait states add only `stall_other`-blocked cycles, so W stays 2 while C grows ~6+2d —
they *re-roll* which P are unsafe rather than widening the window: P=12 is safe at
DMEM_WAIT 1 and 3, locks again at 7.

**Unreachable by the target system:** `timer-clint.c` does
`clockevents_config_and_register(ce, clint_timer_freq, 100, ULONG_MAX)` ⇒ min delta **100
ticks**, 8x above the band even with mtime at the core clock; prescaling mtime (see B5)
puts it 4 orders of magnitude away. And it is **not policy-caused** — Linux's own dummy SC
recreates it. Treat as an extra argument for the mtime prescaler, not as a bug.

`timer-clint.c` rearms `clint_get_cycles64() + delta` — **relative**, same shape as both
test benches, so neither test was the wrong shape.

## Recommended policy (signal list)

`reservation_set  = LR retires` · `reservation_clear = SC retires (any outcome) | local
write overlapping the reservation (store OR AMO — drop `&& !exwb_isAmo`) | trap/interrupt
commit | reset`. No external/device term is needed: no DMA, no second hart, no debug
module; PSRAM self-refresh does not modify data.

`docs/FyraCore_CPU_Reference.md:502` documents the current (asymmetric) behaviour and must
be updated with whatever lands.

## Status at 7cd1eb6 (2026-09-24) — policy FINAL, two RTL gaps

027a17d dropped `!exwb_isAmo` and the ref doc was updated. Remaining gaps against the
policy above: (1) the trap clear is the EX-stage `ex_trap || irq_inject`, ungated by
stall — it fires while an older SC waits on dmem_ready and withdraws the SC's store
(reproduced, DMEM_WAIT>=2). Must be the WB commit (`csr_trap_signal`). (2) the
local-write compare is full 32-bit, so `sb` into bytes 1-3 of the reserved word does
not clear; compare [31:2] (and store only 30 bits). Spike's "trap keeps the
reservation" is false in effect: a trap ends processor_t::step early (`n = instret`),
sim_t::step still charges the whole chunk, so `yield_load_reservation()` runs before
the handler's first instruction. docs/LR-SC_decision.md's "reservation_clear =
executing_SC" is legal but loses the trap clear; its forward-progress argument is
wrong (other-hart stores are a SATISFYING event in `norm:constrained_lrsc_forward_progress`).
See [[finding-branch-review-2026-09-24]].

Related: [[finding-branch-review-2026-09-22]], [[reference-spike-probed-behaviours]].

## 2026-09-27: policy CHANGED by user decision (dce9568)

Same-hart stores and AMOs no longer clear the reservation (only SC, trap commit, reset). Legal
(must-fail list + RVWMO atomicity-axiom commentary: same-hart stores between LR/SC "may (but are
not guaranteed to) succeed"). Chosen to match Spike: the old clear made 1594/1594 rrag failures
diverge at the SC. The "Recommended policy" signal list above is superseded on the local-write
term; the trap clear stays. See [[finding-review-2026-09-27-counters-lrsc]].
