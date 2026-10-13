---
name: finding-tt-wrapper-review-2026-10-10
description: TinyTapeout wrapper (tt_um_alfadelta10010_alphaone_soc) + pins-only bench review — reset needs clocks the stock TT firmware does not give, proven bench gaps, pin map verified
metadata:
  type: project
---

Reviewed uncommitted working tree on main (after 4b7472d), 2026-10-10: `src/tt_um_alfadelta10010_alphaone_soc.v`,
`tb/tb_tt_um.v`, `tests/soc/tt_pins.S`, `make test-wrapper` (3 runs PASS, reproduced; also PASS with +RF_X).

**Wrapper as reviewed ("A"):** plain 2-flop synchroniser (no reset) -> SoC sync `rst`; `uio_oe = soc_oe && rst_n` (raw);
`qspi_rd_late = ui_in[0]` direct; uo_out ungated. 2 dfxtp + 2 and2 + 1 inv = 56 um^2 (0.005 tile).

## Findings (status: open, reported to parent)

- **MAJOR — reset needs clock edges while rst_n is low; stock TT firmware gives none.** tt-micropython-firmware
  `src/ttboard/demoboard.py` `apply_user_config`, no-config path (lines ~531-541): `clock_project_stop()`, then
  `_first_encouter_reset` (rst_n low, 2 ms, release), THEN `clock_project_PWM(design.clock_hz)`. Config path starts the
  clock first. With A the pulse never reaches the SoC and uio_oe goes live from un-reset flops.
  Proven with scratch probe: clock stopped mid flash read + rst_n pulse -> no SoC reset, CS0 falls again in S_DATA,
  Pmod model fatal. Fix proven in scratch ("B'"): async-assert / sync-release pair
  (`always @(posedge clk or negedge rst_n) if (!rst_n) rst_sync <= 2'b11; else rst_sync <= {rst_sync[0],1'b0};`),
  `uio_oe = soc_oe && rst_n && !rst`. Passes the unmodified bench x3 (same cycle counts) and resets cleanly on
  stopped-clock / runt / one-edge / full pulses. +9 um^2 (0.001 tile). Without the raw `rst_n` term the bench's
  "before the first clock" check fails in RTL sim only (rst_n starts 0, no negedge event; silicon is level-sensitive).
- **Minor — rd_late strap is sampled until the 2nd clock edge AFTER rst_n rises** (qspi_ctrl.v `late <= rd_late` while
  the synchronised rst is high). Proven: dropped 19 ns after release -> late=0; 21 ns -> late=1 (10 ns clock).
  Docs say "read only while reset is held". No metastability exposure (first use is after the start-up sequence).
- **Minor — uo_out ungated**: random until a clocked reset; uo_out[6] is OLED RES#+VCCEN, uo_out[4] UART TX.
- **Minor — submission info.yaml `clock_hz: 0`**: firmware only auto-starts the clock `if design.clock_hz`.
- Pin map: all uo_out/uio_out/uio_oe/qspi_io_in/gpio_in/uart_rx bits match the pinout table and the fabbed
  TinyQV (ttsky25a) and KianV (ttsky25b) tops on the same Pmod. No discrepancy.
- Raw-rst_n AND itself: hazard-free (flop Q & pad), in-to-out path gets (1 - 2*IO_DELAY_CONSTRAINT) * period under
  LibreLane base.sdc (no false path, reset not excluded); async release mid-read with the flash driving is clean
  (probe at init=0, S_DATA, pmod_oe=1: no model error).

## Bench gaps (all PROVEN unless marked)

- Second reset does NOT land in a flash read: `@(negedge cs0); repeat(40)` from the FIRST CS0 fall lands in
  start-up step 4 (init=1, step=4, S_CMD, host driving, flash silent). Same loop is in the submission's test.py.
  Fix: aim after the 3 start-up CS0 falls and require the model's dev_oe at the reset instant.
- `rst = !rst_n` (no synchroniser) and `rst = rst_sync[0]` both PASS (cycle count shifts by 4 / 2, unchecked).
  Fix: check the exact release latency at the pins (uio_oe[3] rises on the 3rd edge after rst_n rises).
- No reset with the clock stopped or shorter than one sampled edge; strap hold window never exercised.
- REASONED: bench cannot run on TT's powered GL netlist as written (no VPWR/VGND under GL_TEST; `#0.001` check vs
  unit-delay cells). Model's CS pull-up is instantaneous (real 10k: ~100s of ns).

**Why:** tapeout-facing; ttsky26d shuttle. **How to apply:** on the next wrapper review check first whether the reset
was made clock-independent, and re-run the scratch probe idea (stop clock, pulse rst_n, expect a full restart).
Pattern: a "wait N clocks after an event" aim in a bench must be checked against internal state once
(see [[patterns-recurring]]).

**Status, same day (applied after this review; the branch `tt-wrapper_alfadelta10010` holds the result):**
- M1 fixed: reset asserted asynchronously by `rst_n`, released on the second clock edge
  (`always @(posedge clk or negedge rst_n)`, 2 dfstp). `uio_oe` is gated by that latched `rst` alone (the raw
  `rst_n` term is redundant once `rst` is set asynchronously).
- m2 taken: `uo_out = rst ? 8'h39 : ...`. m1: docs and the wrapper header now say the strap is held until the second
  edge after `rst_n` rises. m3 (`clock_hz`) is the submission repo's and still open with the user.
- Bench gaps closed: three resets (clock-stopped pulse, mid flash read aimed with `pmod_oe`, runt pulse), the pins
  checked on each of the three edges after release (one-flop, no-flop and three-flop releases all fail), the strap
  flipped 1 ns after the second edge, `USE_POWER_PINS` ports, the check moved to 2 ns after `rst_n` falls, and a
  wall-clock TIMEOUT. 34 wrapper mutants, 0 survivors; the plain synchroniser is one of them.

