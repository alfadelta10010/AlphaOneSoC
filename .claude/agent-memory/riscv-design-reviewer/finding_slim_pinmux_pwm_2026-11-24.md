---
name: finding-slim-pinmux-pwm-2026-11-24
description: Review of slim/pinmux-pwm (d6439ff pinmux WARL, 2ceb953 PWM no sticky/oneshot/irq, e47132d audio removed, PWM1 tones) on base edaf17d -- verdicts, SiFive zerocmp period proof, FPGA pin break, stale docs
metadata:
  type: project
---

Branch slim/pinmux-pwm in clone AlphaOneSoC-dev/corepbslim, base edaf17d, head e47132d. Verdict: APPROVE WITH SHOULD-FIX, no RTL blocker.

**Why:** user decisions 2026-11-23/24 (fixed, do not relitigate): pins 0-4 fixed, pin 5 SD CS#|RTS# (code 2), pin 6 RES#|PWM0 (code 4),
pin 7 PWM1 fixed; PWM drops sticky/oneshot/irq; audio.v removed; GPIO irq (PLIC src 4) stays; cmp2/3 read 0xFFFF on purpose.

**How to apply (facts proven in this review):**
- RTL clean: pinmux alt5 on be[2] / alt6 on be[3], rdata comb from alt flops, uo D has no bus term (F12 ok), reset 0x39 and
  pin 7 = ip[1] resets 0. pwm.v matches sifive-blocks: Timer.scala `countReset = feed || (zerocmp && elapsed(0))`, elapsed
  from current s, count:=0 next edge -> period = cmp0*2^S + 1 clocks (NOT an off-by-one; the WO's "cmp0 = N-1" recipe was wrong).
  pwm-sifive never sets zerocmp (period 2^(16+S)), so Linux does not care.
- lint.sh PASS on all four trees (edaf17d, d6439ff, 2ceb953, e47132d); d6439ff alone: one extra WIDTHTRUNC pinmux.pwm 4->2
  (tolerated, functionally pwm_o[1:0]). Revert 3->2->1 clean and lands byte-identical on edaf17d; set 2 alone conflicts (expected).
- tb_pinmux@d6439ff/e47132d and tb_pwm@2ceb953 PASS seed 7 locally. Port patch applies (-p1 at tree/, -p2 in tree/test); needs
  the port RTL copy too.
- SHOULD-FIX found: fpga/up5k/srclist.txt drops src/audio.v but the UP5K build reads PIN=1f2a473 whose alphaone_soc.v
  instantiates `audio` -> hierarchy error; pin.sums still lists audio.v. Stale docs after set 3: pins-and-peripherals.md
  :58-60, :686 ("slot 3 only addr[8]"), :694, codes-table text "Three flops", :463 OUT bits 4/7 "GPIO source of the pinmux";
  devicetree-4x4.dtsi:155 "pin 7 code 5"; VPLAN REQ-PMX-001 still "7 = PWM1 code 5"; soc-architecture.md broken sentence;
  docs/CLAUDE.md "one-voice audio"/"[7] AUDIO".
- EQY by analysis checked: -21 / (-2 flops, +4 const pend/insvc src 5,6) / -41 (audio 40 + alt7) arithmetic consistent;
  renames(11) not re-verified (needs netlist).
- Gaps: no mutant for the alphaone_soc PLIC 5-8 tie (pwm_timer.S would kill it), none for the slot-3 decode alias; SoC tone check
  is +-1 though periods are exact; bus/pinmux_cov/pwm_cov sby not run by coder.

Related: [[finding-wo54-wo55-pwm-audio-2026-11-20]] (pwm-sifive polarity), [[finding-adv-c-periph-pins-2026-11-21]] (pinctrl-single mask).
