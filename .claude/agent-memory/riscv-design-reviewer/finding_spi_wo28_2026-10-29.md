---
name: finding-spi-wo28-2026-10-29
description: WO-28 SPI controller design (tiny_spi map, F12 pin flops, MISO sample point and pad-timing verdict, area, decisions D1-D9) - worktree AlphaOneSoC-spi build/wo/
metadata:
  type: project
---

WO-28 design: `/home/alfadelta10010/projects/AlphaOneSoC-spi/build/wo/WO-28-spi-controller.md` (branch spi_alfadelta10010,
off 18940e4). RTL waits for the PR #12 merge.

**Upstream facts that hold (checked 2026-10-29):**
* Driver: drivers/spi/spi-oc-tiny.c (`opencores,tiny-spi-rtlsvn2`), polled when no irq.
* cs-gpios come through use_gpio_descriptors; the txt binding's `gpios` is stale.
* baud-width is effectively REQUIRED: if it is missing, BAUD is 0 for every device.
* The mode is shared across devices (last spi_setup wins), and CONTROL is written after CS# asserts.
* mmc_spi keeps MODE_3 if asked.
* tiny_spi RTL (freecores/tiny_spi): bb8 is both the TX hold and the RX-of-previous latch, so the roadmap's
  "cheaper variant" saves nothing.
* The RTL's TXE is high for 1 clk with a full buffer; our design gates TXE with !bba.

**Design choices:**
* GPIO window decoded on addr[5:2], SPI at 0x1001_0020.
* OUT bits 1/3 ARE the MOSI/SCK flops (F12): the mux is deleted.
* OUT resets 0x89 and the wrapper UO_RESET 0xB9 (SD CS# on uo_out[7] high).
* MISO is sampled by the existing in_m[1], one clk before the end of B.

**Verdict:** 15.6 MHz margin is only 2-12 ns for rt 20-30 ns. BAUD 2 gives 34-44 ns.
* The polled loop costs ~600 clk/byte, so SCK above ~2 MHz buys nothing.
* Recommended a DT cap at 12.5 MHz.

**Cost:** +24 flops, ~+1,150 um2 synth, ~+0.6 util pt. 3x4 lands at ~69.9% with fetch reuse, which is the proven ceiling.
* An early harden was proposed (D8). It deviates from the 2026-10-24 one-harden rule.

**Why:** next RTL block before the lock. **How to apply:** when reviewing the SPI RTL, check against the
WO's 2.2 clock table, the formal list in 5.3 and mutants SP01-SP20. SP01 (classic sample edge) is killed only by
a bench with rt=25 ns at BAUD 1.

**2026-10-30 implementation review, C1-C6 (b3de324..42e2fec): RTL APPROVE.**
* spi.v matches the 2.2 clock table line for line; flops 63 (+24 exact). bb next-state is 4-source (hold, wdata, sr, rx_in), not
  the 3:1 the WO costed; inherent (IDLE `bb <= sr` is the common slow-CPU path). Read mux 9-way. No new long path
  (dmem_addr is exwb_alu_result, a flop; addr[5:2] compare runs parallel to gpio_sel).
* Scratch probe (driver polled loop, 4 modes x BAUD 0-2, loopback delayed D clk+1 ns): rx==tx iff D <= 2*BAUD, i.e. MISO sampled
  at launch+(2B+1) clk, as 2.4 and WO-29 say; Q4 MOSI hold, never-X reads, 16(B+1) clk/byte all hold. Probe gotcha: EN 0->1
  moves SCK from OUT bit 3 to cpol, which is a real SCK edge (reset this from the device-side bit counter).
* Rulings: 0xCB in oled_spi is correct (WO-28 1.3's "value unchanged" was my slip: MOSI holds the last bit). irq_stall's
  OUT-behind-a-byte keeps the purpose (same `ready` wire). tb_gpio cut to a 105-line OUT/IN smoke test (WO allowed it):
  NO unit SPI checks, NO RX check, NO modes 0-2 anywhere until WO-29. mutate/run.py raises on GP01-GP04 (loud, not a kill).
* Stale comments: Makefile test-gpio, irq_stall header "(DIV 3)", clint_decode (+0xBFFC is now reserved slot 0x3C, not
  CTRL), tt_reboot.S l.11 "0x09", pins doc l.147 asks for an RP2350 pull-down on ui_in[1] (conflicts with the SD MISO rule).
