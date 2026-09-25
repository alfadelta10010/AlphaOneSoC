---
name: finding-soc-rtl-review-2026-09-26
description: Post-RTL review of soc-fabric_alfadelta10010 (qspi_ctrl, mem_ctrl, soc_bus, alphaone_soc, clint, PMA split) at 71a8514 — no Critical/Major; all four pre-RTL Majors verified fixed; open Minors are flash QPI hand-over framing, unlatched rd_late strap, CS-on-first-OE-cycle
metadata:
  type: project
---

Reviewed 2026-09-26 at 71a8514 (base main 1535042). Pre-RTL Majors A1 (1 KB page split), A2 (start-up
sequence + CS0 write gate), A3 (engine never idle on its done cycle), A4 (rd_late strap) all VERIFIED FIXED.

**Why:** RTL for the SoC fabric landed after the 09-26 architecture review; user wanted protocol/arbitration/PMA
checks before tapeout.
**How to apply:** don't re-raise the verified items; re-check the open ones when qspi_ctrl init or the TT
wrapper changes.

Measured (scratch review2/, not in repo):
- tb_qspi_rev.v: core-like continuous i_req, next pc applied after the ready edge, random data ops the cycle
  after a fetch, corners 0x80FFFFFE/0x807FFFFE/pc%1K=0x3FE/flash, d_req injected mid-first-half of a split.
  7 configs (delay 2/10/12/15/19/25, rd_late, PSRAM_WRAP, PSRAM_QPI+FLASH_CRM, FLASH_QPI) all PASS
  (~4.3k fetches + 2.1k data ops each). Mutations `pick_d = d_req` and split-only-at-A/B both caught.
- SoC-mode asm (pma_rom.S): LR flash cause 5, SC/AMO/SW flash cause 7, mtval=addr; LR/SC PSRAM ok;
  32-bit insn at 0x80FFFFFE -> cause 1 mtval 0x81000000 mepc 0x80FFFFFE. All correct.
- SoC-mode timer test (period 3000 clk): 3 MTIP interrupts, cause 0x80000007. Works. (Suite soc-skips
  t_irq/t_irq2/t_mulirq/t_ctl, so this was otherwise untested at SoC speed.)
- Area (sky130 hd, yosys+abc): qspi_ctrl 2381 um2, mem_ctrl 747, soc_bus 1536 standalone (read mux),
  clint 7619 (byte lanes ~205, mtimecmp reset ~225 — not worth it). in_win constant compares fold to
  equality (no cost). Full flat SoC 148,728 um2 = ~39.7 kGE vs docs' ~21 kGE budget (core is the overrun).

Open (Minor unless noted):
- Flash hand-over: step 3 is 8 clocks of 1111. Ends CRM (datasheet: "input FFh on IO0 ... 8 clocks").
  Exit QPI (FFh) followed by 24 more clocks is NOT datasheet-backed; model accepts it. QPI+CRM not
  handled: `vvp tb_qspi +FLASH_QPI +FLASH_CRM` -> first flash load returns X. Fix: add a 2-clock QPI-framed
  FFh step after the 8-clock one. Flash wrap (77h) / power-down (B9h) not covered either (document as
  RP2040 contract; flash 66h/99h needs tRST 30 us).
- rd_late used combinationally every cycle (qspi_ctrl.v:147, :209): async pin into flop enable/next state;
  TinyQV latches during reset. Latch it (1 flop).
- First CS# fall happens on the same edge ctl_oe first rises (qspi_ctrl.v:166,173): no SCK-low/CS-high
  driven cycle before the QPI-form F5h. Gate S_IDLE->S_CMD on ctl_oe.
- docs/soc-architecture.md:91-92 still says data req arises "on a cycle a fetch completes" (it's the
  cycle after; mem_ctrl.v header was corrected). qspi_ctrl.v:70 "idle is high only on cycles start is
  taken" is wrong wording.
- Question: APS6404L datasheet does not state that 66h/99h preserves array contents; boot_sel=1 (RP2040
  preloads PSRAM, then engine resets PSRAM) depends on it. Verify on hardware.
- Question: CS# pull-ups on the Pmod (pins float while rst/ctl_oe=0); TT wrapper needs rst_n synchroniser.
- Perf idea not in doc: abort the in-flight fall-through fetch on a taken redirect (needs an abort in the
  req/ready contract); ~58 clk per taken branch/jump.

Related: [[finding-soc-arch-review-2026-09-26]], [[reference-qspi-pmod-datasheets]], [[rtl-area-hotspots-fyracore]].
