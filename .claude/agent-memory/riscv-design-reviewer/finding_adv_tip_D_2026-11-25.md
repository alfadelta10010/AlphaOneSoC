---
name: finding-adv-tip-D-2026-11-25
description: Adversarial slice D at 4x4 tip f75a734 (slim pinmux/PWM/audio integration + docs/DT/clock) -- RTL clean; variant-ambiguity and stale freq patches MAJOR; pwm-sifive 6.8 vs master facts
metadata:
  type: project
---

Report: localFiles/wo-4x4/reviews/adv-tip-2026-11-25/D-soc-docs.md. RTL of slim (c58d3bc/7dbe29b/a9dd769) CLEAN at tip;
pinctrl-single bits <0 0x200000 0xf00000> correct (dtc clean); gpio/uart/wrapper deltas comment-only.

**Why:** two ship candidates differ in hardware: A0-core (a0/core e603951) = audio, 8-code pinmux, PWM irqs live,
128 B cache, no PBURST, PMP G=0, mtvec reset; tip = slim + sectored 256 B + CSR-slim. a0/core has NO sw/, no
alphaone-4x4.dts, no boot-contract -> only the 4x4 branch carries board DT/loader/boot contract (describing tip RTL).

**How to apply (facts proven):**
- Freq patches (localFiles/wo-4x4/freq/{docs,sw}-4x4-{62,60}, sw-4x4-{50,55}) ALL fail `git apply --check` on f75a734
  (boot-contract section 1 after 506d97e, alpha.dts pmpgranularity after 512d681, pins section 9 after slim, sd.c after PR #19).
  Tip is self-consistent at 62.5 MHz (neither candidate). At 50 MHz divisor 34 = -20 % baud.
- pwm-sifive: v6.8 (project kernel 6.8-rc1, V13) = get_state duty=cmp, enabled=duty>0, polarity INVERSED, writes
  cmp=duty; master (fix series AUTOSEL'd to 6.12/6.15, 2025-08) = duty=0xFFFF-cmp, NORMAL. Probe counts cmp>0 as running
  in both. RTL polarity (pin = s >= cmp) right for both; the "0xFFFF = off/balanced" rationale is master-only.
  Neither driver touches STICKY/DEGLITCH/EN_ONCE or IRQs; update_clock clears zerocmp -> tones bare-metal only.
- UP5K twin pin 1f2a473 differs from tip in 11 files (qspi_ctrl, mem_ctrl, cache, gpio, pinmux, pwm, ...): README
  "proves" claims stale for tip.
- docs/CLAUDE.md:192 still says mtvec resets to 0; boot contract omits mscratch/mepc/mtval no-reset.
- tCEM-burst proof described 3 ways (boot-contract "BMC not proved" vs pins/VPLAN "PROVED sind").

Related: [[finding-slim-pinmux-pwm-2026-11-24]], [[finding-csrslim-adversarial-2026-11-24]], [[finding-adv-c-periph-pins-2026-11-21]].
