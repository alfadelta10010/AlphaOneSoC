---
name: finding-periph-review-2026-09-27
description: Review of uart.v/gpio.v/soc_bus ready/alphaone_soc (fbdcc03..f62f8a1, docs 1353f27/b0bd738) at 4d04809 — no Critical; MAJOR SPI DATA vs OUT (D/C, CS#) ordering race reproduced; UART/8250 subset verified correct; area knobs measured
metadata:
  type: project
---

Reviewed 2026-09-27 at 4d04809 (branch soc-fabric_alfadelta10010). tt_um wrapper deliberately not built (user
decision) -- don't flag it.

**Why:** first review of the peripheral RTL; decides whether the console/OLED path is tapeout-ready.
**How to apply:** re-check the open items when gpio.v/uart.v change; don't re-derive the verified list.

Verified OK (evidence: scratch tb_uart.v + tb_soc_periph.v, not in repo):
- Bus contract: side effects gated by sel&&ready; reads always ready; ready low only with own sel; soc_bus AND
  is sound. Through the real core: 16 back-to-back THR stores -> 16 frames/16 loads; MTIP pending during a held
  THR write is NOT injected (stall_other has wb_mem_stall), taken after, mepc = next insn, no duplicate frame;
  AMO to THR with phase-1 write held -> exactly 1 RBR pop + 1 THR load; req_hold_check silent.
- Linux 8250 (mainline, nbcon era): 8250_of sets UPF_FIXED_TYPE so autoconfig (IER=0x0F / SCR tests, which this
  UART would FAIL) never runs; IIR NO_INT gate, TXEN test (IER=THRI -> IIR 0x02, TEMT) -> no BUG_TXEN;
  THRE_test/backup timer skipped (irq=0); poll timer = uart_poll_timeout; LCR RMW (early init_port, shutdown)
  harmless; OE saved via lsr_saved_flags; wait_for_lsr timeout never loses chars because THR back-pressure.
- RX: +-4.5% baud tolerance at DIV 1/2/4/27 (fails at 5.5%); CTS-honouring PL011 model lossless, OE never; no-CTS
  flood keeps oldest byte, OE set, order preserved; glitch/FE/break handled. PL011 checks CTS per byte (TRM).
- KianV precedent: also back-pressures THR (tx_accept waits uart_tx_rdy) but has 16-deep RX FIFO, no RTS.

Findings:
- MAJOR gpio.v:67-69: back-pressure orders DATA->DATA only. `sw DATA; sw OUT` (D/C or CS#) lands mid-byte:
  reproduced from flash at DIV=2 and 3 -- command 0xA5 sampled with D/C=1, CS# rose after 6 bits (last byte
  lost). Linux path is slow enough to hide it by accident. Fix verified in scratch (+25 um2): stall OUT (when
  EN) / CTRL writes while busy AND hold busy one half-period after the last rising edge (tCSH 60, tAH 40 ns).
- MINOR gpio.v:89: OUT resets 0 -> CS# asserted + SCK pin low (not mode-3 idle); setting EN makes a rising SCK
  with CS# low (seen in sim). Reset 0x09 is area-neutral.
- MINOR SPI DIV=2 "up to 53 MHz" = 75.0 ns vs tCLKL/H 75 ns min: zero margin.
- MINOR soc_bus/uart: IO ready now in series dmem_req/we (sc_success 30-bit compare) -> decode -> ready ->
  stall fanout; run STA.
- NIT uart.v:169-177: async first THR write shortens the start bit by up to D-1 clocks (8120 vs 8640 ns @D=27).
- NIT: long THR stall blocks irqs (0.2 s/char at divisor 65535); mem_ctrl refetches pc continuously during stall.
- VERIF GAP: both tbs switch IO1 off -> no regression touches UART/GPIO; Spike's ns16550 stores LCR/SCR so
  lockstep can't check them -- self-checking tests needed.

Area (syn.sh, standalone): UART 3114 (0.276 tiles, 73 ff; flops ~50%), GPIO 1380 (0.122, 39 ff).
8-bit divisor -661 um2 (-0.058 t, >=12.2 kbaud @50 MHz); 12-bit -350; share RX sync w/ GPIO in[3] -45;
both -705 (-0.062 t). 1-stage GPIO IN -140 (not recommended); 1-bit SPI DIV -30. Peripherals can't fix the
13.56-vs-7 tile gap.

Related: [[finding-branch-review-2026-09-26-full]], [[reference-kianv-memory-map]].
