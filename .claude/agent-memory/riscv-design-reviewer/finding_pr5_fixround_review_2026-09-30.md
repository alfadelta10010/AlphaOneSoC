---
name: finding-pr5-fixround-review-2026-09-30
description: Adversarial review of the PR #5 fix round (c86a627..3f8a69f) -- qspi dual-CRM step, boot_addr[0], UART SBC/BI/RBR reset, model/tb upgrades; no Crit/Major; four PROVEN check-strength gaps (step order, QPI exit step, BI same-cycle, MTIP window upper bound)
metadata:
  type: project
---

Reviewed 2026-09-30 at HEAD 3f8a69f in scratch (git archive; scratchpad r/, rc/, mut/).
Reproduced: make test-qspi all PASS (tb_qspi x10, stress x4, resets 113/90), make test-uart
PASS 1,930,830 checks (42 s), new SoC MANIFEST lines 11/11 PASS (flash_boot hostile states,
straddle_flash_end, t_ctl_slow, irq_stress late, mtip_stale, cnt_instret, pma_flash).

**Why:** gate on the fix round before PR #5 merges; builds on [[finding-pr5-mempath-review-2026-09-29]],
[[finding-pr5-review-2026-09-29]], [[finding-pr5-core-review-2026-09-29]].
**How to apply:** don't re-derive; re-check the open gaps if qspi_pmod_model, tb_uart or mtip_stale change.

RTL verdicts: step 4 = 16 clocks 1111 under one CS (again flop, reset, continuous SCK) is correct
for SPI, quad CRM (exits at step 3), dual CRM (BBh s8.2.11 FFFFh), DTR BDh/EDh CRM (exit at step 3),
QPI, QPI+CRM. FFh has no SPI-mode meaning. tRST/tSHSL fine. boot_addr[0] mask trivial. UART BI/SBC
match 16550 + Linux 8250 (read_char BI path, break_ctl, TCSBRK waits TEMT; TEMT 1 tick early still
gives a full stop bit). 8250_of -> uart_read_and_validate_port_properties -> use_defaults=false ->
irq 0 (doc claim verified vs mainline serial_port.c).

PROVEN gaps (mutants in scratch mut/):
- M2 swap steps (16 then 8) passes every tb_qspi config incl +FLASH_CRM: quad-CRM model goes
  P_IGNORE after 8 clocks, never models dummy+data drive (real flash drives clocks 12-15).
- M4 drop step 5 (FFh QPI) passes everything: model exits QPI on step 3's 8-clock window.
- M1 no `again` IS caught by +FLASH_DCRM. M5 35h 2 clk after 99h caught by tRST.
- U6 BI clear-wins-over-set passes tb_uart (same-cycle section covers DR/OE only). U1-U5, U11-U14 caught.
- mtip_stale: 3-cycle MTIP lag passes all core lines; a third `csrr s8, mip` (x24) = 0 bounds it
  (0x80 on mutant, 0 on real, also +DMEM_WAIT=3 +DMEM_RANDOM=1).
- Probe: polling loops (lw/beqz, lr/beqz, c.lw/c.beqz) take timer irqs at SoC speed (no livelock).
REASONED nits: dual-CRM 16th falling edge = data-out edge coincides with CS rise (few-ns overlap);
UART no 16550 resync after framing error (mid-char break unreported) and no 1/2-bit marking;
t_ctl_slow x19=1 depends on pipeline timing (perf fixes may flip it); docs "two instructions" MTIP
(it is 2 clocks), BUSY "400 ms" (chip erase 200 s; s8.2.45 reset may be accepted while busy).
Not reviewed: docs/area-audit.md (tool denial).
