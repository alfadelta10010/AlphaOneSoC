---
name: patterns-recurring
description: Recurring bug and verification-blind-spot patterns seen across FyraCore/AlphaOneSoC reviews (2026-09-05..09-29) -- read before every review and hunt for each one
metadata:
  type: feedback
---

Patterns that have produced real findings on this project. Check each on every review.

**Why:** each of these escaped at least one earlier review or regression.
**How to apply:** use as a checklist; add a line when a new class of escape turns up.

Core / pipeline
- EX-stage side effects not gated by `!stall` / `!ex_trap` (MRET is the repeat offender).
- CSR WARL masks re-implemented in csr.v, fyracore forwarding and tb dump -- every new CSR forgets one copy
  (0x320 and mepc[1] in forwarding, 2026-09-12).
- One-shot completion pulses dropped when the pipeline cannot advance (muldiv_done, 2026-09-22) -- mirror image
  of the level-signal-committed-twice pattern. Check both directions.
- A "fix" that makes a pulse sticky must also block re-launch on the pulse cycle itself (2e6718b broke every
  back-to-back M-op by swapping `!done` for `!ready`).
- Any redirect/side effect computed from EX operands must be gated by !stall: forwarded load data is garbage
  until dmem_ready. X-in-tb makes these invisible (iverilog `if (X)` = false).
- Exporting a post-write value from csr.v that its own read mux consumes makes a word-level loop (Verilator
  UNOPTFLAT, 6dbf31d). Run `verilator --lint-only -Wall` on every RTL review; yosys check won't flag it.
- Changing what a register STORES without changing what its bypass/read port RETURNS (csr.v counters read from
  *_next after 4f4e071, 2026-09-27b). Check read port, forwarding and tb export together.
- Livelocks are phase/congruence effects, not thresholds: sweep wait states contiguously and compare against a
  non-atomic control loop before calling it a defect.

Bus / SoC
- req/ready slaves: in the ready cycle the core still shows the OLD request. A slave that arbitrates in its own
  ready cycle refetches a stale address and can complete it against the NEW one.
- Device datasheets carry hidden state (PSRAM QPI/wrap, flash CRM/QPI/dual-CRM/BUSY) that survives a design
  reset; other TT designs set it. Always ask who establishes device state.
- Back-pressure on one register orders only writes to THAT register: sideband GPIO writes race the shifter.

Verification blind spots
- Comments claiming "matches Spike" are often unverified -- probe Spike first.
- Directed tests that retire a multi-cycle op but never check its VALUE pass data-corruption bugs; full-trace
  diff against Spike, not final registers.
- Deterministic vs randomised wait states expose DIFFERENT bugs. Run both.
- Behavioural models encode the designer's reading of the datasheet: check the MODEL against the datasheet.
  Delete each init step / change each magic byte in the RTL and see if the tb notices.
- Timing checks a model LACKS are invisible to mutating existing checks: walk the datasheet AC table row by row
  and try one RTL mutant per missing row (2026-09-29: tRST missing, 35h 2 clk after 99h passed).
- Lumped-delay device models schedule output-enable with #delay; a deselect must cancel it, or reset-mid-read
  stress reports false contention. No bench here ever resets mid-transaction -- do it in scratch.
- Self-checking probes need an external oracle (irq-on vs irq-off checksum can be equally wrong).
- Spike has no read-only memory: PMA ROM faults need DUT-only tests. SoC suite soc-skips timer tests.
- Both tbs switch PMA_IO1 off, so no regression touches UART/GPIO through the core lockstep flow.
- Scratch paths under /tmp/claude-1000/... are ~150 chars; check path-buffer truncation before blaming RTL.
- Nothing checks that a target is NOT written: a CLINT-we-on-every-store mutant passed every SoC test (2026-09-29).
  For each decoded target, mutate its select to "always" and see if any test notices.
- Slow simulated fetch (~57 clk/instr) hides every short hazard (sync lag, back-to-back IO). Probe peripherals
  with a zero-wait unit tb before trusting a "discard one read"-style rule.
- PR-body claims ("each commit names its mutants", mutant counts) drift from the commit log: grep the log.
- A device-state model that stops modelling once the exit condition is met (P_IGNORE) cannot check
  ORDER or LENGTH claims ("the 8-clock window must come first"): swap/remove each init step as a mutant
  (2026-09-30: swap and drop-QPI-exit both passed). Lenient models (exit despite trailing clocks)
  make the belt-and-braces step untestable -- ask for a pessimistic model option.
- Every new sticky status bit needs its own set-vs-clear same-cycle case (BI copied OE's RTL but not
  OE's test). Every "pins the window" test needs a read just past the window, not only inside it.
- Gating a check behind a condition (PMP time-share: fetch phase only if U-mode or a lock) silently
  removes an EXISTING test's sensitivity (mprv.S no longer sees fetch-vs-MPRV). Re-mutate old tests.
- The 116-run directed suite is pipeline/privilege-heavy and nearly value-free: no SRA, MULHSU/MULHU,
  mixed-sign SLTU (2026-10-04). Datapath rewrites need river_core or a values probe; unit tbs miss
  the fyracore wiring (sra_wire0 escaped everything in the repo).
- A mechanism kept "just in case" after a redesign (PMP-write refetch after csr_wb_hazard) may still
  be necessary only in a corner no test reaches -- write the probe that needs it before judging it.
