---
name: finding-adv-b-bus-irq-2026-11-21
description: Adversarial review B (bus/PLIC/PMA/IRQ sources) of 4x4 branch @d3eb898 -- 0 blocker/major; 2-edge TT reset leaves GPIO IN_IP phantom bits; stale plic.nonvac mutant; bus proof leans on BOUNDED core_req R6
metadata:
  type: project
---

Report: localFiles/wo-4x4/reviews/adv-4x4-2026-11-21/B-bus-irq.md (2026-11-21, HEAD d3eb898). Read-only, no sims.

**Verdict:** no BLOCKER/MAJOR. Two-phase bus exactly-once PROVED (pdr, ~/acc/wo69acc); core_hold H2 backs the hold
assume; PLIC P1-P7 PROVED (pdr); dw_wdt.c fetched: probe RMW CR->RMOD 0, ISR reads STAT only, never EOI, IRQF_SHARED|
TRIGGER_RISING (sifive plic has no set_type -> ok); RTL pulse matches.

**MINOR-1 (new):** gpio.v needs >=3 reset clocks to fill the unreset in_m/in_s/in_p chain; TT wrapper with the board's
clock-stopped reset gives exactly 2 -> at the first post-reset edge in_p = in_m from before the pulse -> random IN_IP
at cold power-up, and a set bit for any pin changed while the clock was stopped (straps ui_in[0]/[2]!). IE=0 so benign;
fix = 1 flop `rst_d` gating the set, or mandate clear-IP-before-IE. tb_gpio uses 3 edges. Same pattern may exist in
other unreset synchroniser + edge detectors (UART RX) -- check next time.
**MINOR-2:** plic.nonvac mutant 1 still uses loop var `i`; 1f2a473 renamed it `j` -> NONVAC-ERROR; last plic nonvac
ran on fix-dev (11-20 23:20, pre-rename). **MINOR-3:** bus PMA assume rests on core_req R6 = BOUNDED 150.
Nits: stale meip one cycle after claim/enable-clear (legal spurious MEI with MIE=1); byte read of claim+1..3 claims
(gate claim with be[0]); WDT stages (1,1.5]T + 1.5T vs driver's 2T (later, safe); stale header text.
Questions: fault AMOs on IO? keep pulse-lost-while-insvc?

Sandbox log map: ~/acc/wo69acc/logs (bus/plic/spi_bus PROVED + spi_bus nonvac), ~/acc/fixg1/nv.log (bus nonvac),
~/acc/fix-dev (only plic nonvac). Avoid `grep -r ~/acc` (timed out >120 s); grep named log dirs.
See [[finding-wo51-wo52-2026-11-21]], [[finding-wo58-wo61-wo63-2026-11-21]], [[finding-tt-wrapper-review-2026-10-10]].
