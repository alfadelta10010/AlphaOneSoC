---
name: finding-final-prelock-2026-11-21
description: Final whole-SoC adversarial pre-lock review of the 4x4 tree at 1f2a473 + WO-68 PSRAM-burst diff -- verdict, DT driver-probe bugs, boot contract gaps, WO-68 equivalence/tCEM facts, silicon-risk fallback table
metadata:
  type: project
---

Report: localFiles/wo-4x4/reviews/FINAL-prelock-review.md (2026-11-21). Verdict: 1f2a473 READY WITH SHOULD-FIXES
(0 RTL blockers, no RTL change needed); WO-68 RTL sound but NOT READY to commit until qspi_burst_eq /
mem_tcem_burst / qspi_pins close.

**Should-fix (all non-RTL):** SF1 DT `compatible="gpio-mmio"` matches nothing in gpio-mmio.c OF table (brcm,bcm6345,
wd,mbl-gpio, ni,169445-nand, intel,ixp4xx..., opencores,gpio) -> cs-gpios unresolved -> spi0 defers forever; fix
wd,mbl-gpio + no-output on gpi. SF2 pinctrl-single: `,bits` parsed only with `,bit-per-mux`, args>=3 so
#pinctrl-cells 2, fmask 0xf (bits_per_pin = fls(fmask)). SF3 no board DTS anywhere; loader must set SPICTL.EN=1
(no Linux driver does), a0/a1, copy kernel; clock-dependent constants list. SF4 no reboot test with dirty
PLIC/UART/pinmux/PWM/audio/gamepad/cache. SF5 lint V1 + Verilator V10 not run (PLIC multi-driver escaped sim).
SF6 Linux never booted (V13).

**Cross-block facts verified (reuse):** every instance rst=rst_soc except syscon; CACHE_CTL flop on rst_soc;
AMO to IO = two separate two-phase accesses (amo_phase flips on the phase-2 edge, ph clears same edge);
dmem_req gated by !exwb_trap; fencei_flush in EX (fyracore.v:1273) after older store d_ready; irq priority
MEI>MSI>MTI; WFI wake ignores MIE (correct). Registered IO path removes the stale-MTIP window.
PLIC byte read of claim word claims (be ignored on reads) -- nit.

**WO-68 facts:** PBURST=0 => pstrm never set (needs t_bst<-burst) => every edited qspi_ctrl expression reduces to
1f2a473 text. Measured worst CE#-low 1552 ns @16 ns = ~97 clk -> tCEM 8 us needs >=12.1 MHz (vs 7.5 MHz single
read); comment "< 0.5 us" wrong. PBURST also needs QSPI_CFG.STREAM (stream_en in pstreamable). SCK-pause-in-PSRAM
read has TinyQV silicon precedent (ttsky25a mem_ctrl.v continue_txn/data_stall) -> tier 1 by analogy, not tier 3.

**Silicon fallbacks:** setup/slew -> lower clock; hold -> none; cache macro -> EN=0; core RF macro -> none;
burst/DDR/stream -> CSR/strap off. See [[finding-wo62-icache-k4-2026-11-21]], [[finding-wo58-wo61-wo63-2026-11-21]].
