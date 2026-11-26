---
name: finding-adv-c-periph-pins-2026-11-21
description: ADV-C peripherals + TT pins review @d3eb898 -- 0 blocker/major; pinctrl-single mask bug (corrects FINAL SF2), IN_IP phantom, D13 derivation, driver-source facts
metadata:
  type: project
---

Report: localFiles/wo-4x4/reviews/adv-4x4-2026-11-21/C-periph-pins.md (2026-11-21, base d3eb898; HEAD 4290aeb only
comment changes). 0 BLOCKER / 0 MAJOR. RTL of uart/gpio/spi/pwm/audio/gamepad/pinmux/wrapper correct.

**M1 (PROVEN, DT):** pinctrl-single `bits` mask must cover the whole function-mask field: pcs_parse_bits_in_pinctrl_entry
does `if (submask != mask_pos) { dev_warn("Invalid submask"); continue; }` -> `(0x7 << 20)` with fmask 0xf = empty
group. Use `(0xf << 20)`. My FINAL-prelock-review.md:42 said 0x7 was legal -- WRONG, corrected here.
**M2 (REASONED):** gpio in_m/in_s/in_p never reset; demo-board stopped-clock reset gives only 2 edges with rst high ->
edge 3 sets IN_IP = pin ^ in_m(power-up). gpio.v "no phantom edge" claim false; gpio_irq.S assumes IN_IP=0. ADV-B
found it too. Fix: 1-flop arm, or doc-only.
**M3:** uart.v:35/52-54 + pins doc :392 say LSR read does not clear BI/FE; RTL err_ack does (correct 16550).
**M4:** code 2 -> 4 bytes kept (accepted); rx_trig_bytes=1 not in boot contract; V3 Linux-latency bench still open.

**Driver facts verified from source (sandbox ~/dt/src = torvalds copies; ~/v13/lx/linux-6.8-rc1 full tree):**
8250_of flags BOOT_AUTOCONF|FIXED_PORT|FIXED_TYPE; tx_loadsz fallbacks guarded `if (!up->tx_loadsz)`; tx_chars only
after LSR.THRE (8250_port.c:1940). pwm-sifive probe counts PWMCMP>0 as enabled when EN_ALWAYS set (inconsistent
with get_state 0xFFFF-cmp) -> loader should leave PWMCFG 0. mmc_spi forces mode 0 unless DT says mode 3;
spi-oc-tiny hw->mode global from last setup. gpio-mmio has wd,mbl-gpio + no-output + gpiochip_get_ngpios.
pwm-sifive.yaml: interrupts optional, maxItems 4. TT gamepad_pmod.v: rising clk/latch, pad0 = data_reg[11:0], no
bit-count check (ours filters 12/24 -> Q1).
**D13 derivation:** MISO captured in in_m at internal edge 2b+1 after the launch (edge 0); pin flop -> window 2b*T
(64 ns at BAUD 2, 62.5 MHz); doc 28/23/18 = 64-14(tODLY)-2-rt. tb_spi T14 rule (2B+1)T is at the gpio boundary.
See [[finding-final-prelock-2026-11-21]], [[finding-wo58-wo61-wo63-2026-11-21]].
