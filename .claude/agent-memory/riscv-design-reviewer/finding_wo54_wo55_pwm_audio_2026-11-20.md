---
name: finding-wo54-wo55-pwm-audio-2026-11-20
description: WO-54 PWM (sifive,pwm0) + WO-55 audio reviews on 4x4-alfadelta10010 -- driver contract facts, sifive-blocks semantics, harness gaps
metadata:
  type: project
---

Reviews: localFiles/wo-4x4/reviews/WO-54-review.md, WO-55-review.md (2026-11-20). Both ACCEPT-with-fixes, 0 blocking.

**WO-54 pwm.v @2bab221** -- RTL correct for pwm-sifive.c (torvalds master, last fn change 6df3aac763fa 2025-05).
- Driver contract: writes PWMCFG = 0x1000|scale (full word -> clears ip/sticky/zerocmp/oneshot), PWMCMP = 0xFFFF-frac;
  reads only PWMCFG bit 12 + PWMCMP; period 2^(16+scale); needs pin = ip (high while pwms >= cmp).
- TRAP: driver header (7dbc4432ea6b) claims silicon output high when pwms < cmp; its arithmetic requires pin = ip and
  sifive-blocks PWM.scala:62 gpio = ip ^ invert. Never invert the pin. (S1 = comment; S2 = WO-57 oracle = driver math.)
- sifive-blocks (silicon source): pwms is RegFieldAccessType.R (writes ignored = NOT a departure); oneShot :=
  write.running && !countReset (auto-clear wins, pwm.v chose write-wins); feed = count.carryOut(scale+16) = one bit
  above pwms MSB (clears after 2 periods, manual 20.8 says top pwms bit) -- my reading, unverified on silicon.
- DT: "vendor,x", "sifive,pwm0" fails dtbs_check (binding enum fu540/fu740); runtime fine.
- Timer use needs sticky (WO-47 gateway drops 1-clk ip pulses while insvc); clear ip via sb to +3 before complete.

**WO-55 audio.v @ab3ad84** -- RTL correct: mixer max 60 (6 b, no overflow), DAC L high clocks/256, frame always starts low,
EN-low holds lvl+LFSR. Harness gap S1: level_q uses DUT's exposed `sum` -> mixer unpinned (only sum<=60); fix sum_ref
assert + 2 nonvac lines. P3 ghost gh==min(dc,lvl) sound. Original design (not SN76489/AY register-compatible).

Sims not run for WO-54/55 (used mempool.lan, which does not resolve; real sandbox address in finding_wo46_wo47_wo49_2026-11-20.md).
