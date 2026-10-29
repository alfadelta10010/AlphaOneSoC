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
- New register/mailbox offsets: check they fit a 12-bit signed store/load offset from the base register the
  programs already hold (+0xF04 from s11 = SYSCON does not assemble, 2026-10-23). Assemble a use before fixing a map.
- A new reset domain: list every block's .rst and say why it is on it; a sticky register on the wrong reset
  is wiped silently, a block on the wrong one runs through the reboot. Lockstep benches cannot see either.
- A sync reset made from flops (rst_soc = rst | rq | off) reaches the domain's flops one edge after its cause:
  any one-cycle event in that domain (watchdog fire, SA-009, 2026-10-24) must be gated by the reset, or
  "cannot X while held" is false for the first held cycle. Probe: aim the event at the cycle after the store.

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
- "Decode-only" / "never drops mid-fetch" claims: mutate to the named wrong alternative (ex_trap,
  ex_illegal_insn) -- 2026-10-09 both passed 121/121. Withdrawal needs a FIXED imem wait (IMEM_WAIT=2);
  random waits often complete the fetch first. misa.C flip under csr_wb_hazard is the canonical trigger.
- Redundant backstops (ex_nofetch + refetch arm): each single-removal mutant survives; mutate pairs.
- Perf-only features (fetch suppression) are equivalent mutants to every functional test; ask for a
  cycle/fetch-count assertion or they rot silently.
- +RF_X / X-init "proves unwritten reads are caught" is false for X that only steers a branch whose
  iverilog else-arm matches Spike's 0-init path (bnez on X passes). Use random-init vs Spike instead.
- Spike resets PMP permissive (entry0 RWX), the core all-off: random generators must zero PMP first.
  Spike WFI waits for mip&mie (hangs with mie=0): only emit WFI in interrupt modes; filter WFI lines.
- Any "present the next cycle's operands" select (sync RF macro, 2026-10-11): slow fetch (SoC, any
  IMEM_WAIT) keeps if_mem_stall high and hides every other hold term; only zero-wait core runs kill
  them. WFI-without-trap (mie=0, or MIE=0 + pending) is the hold nobody tests functionally.
- Hard-macro behaviour the design relies on but the precedents never exercise (rf_top same-edge
  write-through, 2026-10-11): the behavioural model is the only evidence, and the GL compare reuses it.
  Mutate the MODEL (e.g. read-first) to find what depends on it, then check how the precedents sequence it.
- The directed .ref suite is mostly `.option norvc`: a model of a C-path feature (fetch reuse, 2026-10-29) hit 0.57%
  of its instructions, 72/91 tests never. Count the feature's events per test before trusting a green suite.
- Macro placement "from the precedent" with a different location: re-derive the PDN alignment
  (isolated power-pin stubs vs strap offset/pitch) and the routing wall (OBS layers) for the new spot.

PPA / area claims
- Synthesis recipes that drop LibreLane's dont-use list (no_synth.cells: all common `_1` cells,
  edfxtp, dlclkp) understate TT-flow area ~24% and can invent savings (edfxtp-only cuts like RF reset
  removal). Re-measure with the TT cell set or LibreLane synth before believing a tile figure.
- "60% density leaves 40% for buffers" is false here: post-CTS std-cell area was 1.64x the recipe area.
- Flop banks with enable self-loops (Q->mux->D) each get a hold buffer under TT's 0.25 ns hold
  uncertainty; ~1000 on the RF broke detailed placement in every harden (2026-10-09).
- Unbuffered pre-layout STA is noise (a dead-code commit moved it 4.8 ns); only post-CTS/signoff
  numbers from the real flow can rank timing.

- New test not RF_X-clean -> mutation runner's +rfx second pass reports EVERY plain-suite survivor as killed by
  that test (WO-27 fr_misa, 2026-10-30). Check: run each new test on the UNMUTATED RTL with +RF_X +RF_COLLIDE_X.
