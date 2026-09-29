---
name: finding-pr5-mempath-review-2026-09-29
description: Adversarial review of PR #5 (head 4b4ed8b) memory path + fabric -- qspi_ctrl/mem_ctrl/soc_bus/alphaone_soc and the Pmod model/benches; no Critical/Major; dual-I/O CRM hand-over gap, model blind spots (tRST, mixed PSRAM modes, dev_oe under reset), what was proven
metadata:
  type: project
---

Reviewed 2026-09-29, scratch copy of 4b4ed8b (scratchpad pr5/, mut/, sweep/ -- not in repo).
Known minors m1-m4 (flash 77h wrap, PSRAM wrap-32 reset claim, pins released on reset edge, tCEM
min clock) were out of scope.

**Why:** coordinator asked for an adversarial pass on the SoC memory slice before PR #5 merges.
**How to apply:** don't re-derive the verified list; re-check the open items if qspi_ctrl init or
qspi_pmod_model change.

Verified (evidence in scratch):
- Every command vs datasheet: PSRAM QPI 0Bh 2+6+4 (APS6404L Table 8.5, Fig 13), 38h QPI (Fig 15),
  flash EBh 8+6+2(M=FF)+4 (JV-DTR Fig 24a), F5h/66h/99h/35h forms; tCHD/tCSP are CLK-rising
  referenced (Table 10) so CS# rising on an SCK falling edge is fine.
- make test-qspi 9/9 PASS. Delay sweep at 10 ns clk: rd_late=0 passes 0-19 ns, rd_late=1 10-29 ns
  (docs say 2-19 / 12-29: conservative, OK).
- Core never withdraws/changes imem/dmem requests (pc moves only on !stall, irq_inject gated by
  !stall_other); data req only after a fetch completes, pc outside exec windows, or AMO phase 2 ->
  engine is always idle then; latched grant + `second` make split fetches atomic.
- verilator -Wall on alphaone_soc: clean (only PINCONNECTEMPTY).
- Random mid-transaction resets (~100/run, rd_late 0/1, WRAP) recover via step-0 F5h: PASS once a
  model artifact is removed (below).
- Mutant CS# rising with the last write SCK edge: caught (iverilog orders cs_n first).
- run.sh soc 66/66 PASS (matches PR). flash_boot (full trace) and irq_stress (checksum) also PASS through the
  SoC with +PSRAM_QPI/+FLASH_QPI/+FLASH_CRM and with +RD_LATE +QSPI_DELAY=25 +PSRAM_WRAP (suite never does).

Open:
- MINOR start-up: flash in DUAL-I/O continuous read (BBh M5-4=10) needs 16 all-ones clocks in one CS
  window (JV-DTR s8.2.11 "FFFFh on IO0 (16 clocks)"); step 3 gives 8 -> first flash read garbage.
  Scratch model +FLASH_DCRM reproduces; a 16-clock step after step 3 (1 flop) passes all configs.
- MINOR/Q: flash BUSY (erase left running) / suspended at hand-over -> EBh ignored, bus floats.
- VERIF: model has no tRST (99h->next cmd 50 ns) check: 35h 2 clk after 99h PASSES all configs.
- VERIF: model false-fails a legal hand-over (PSRAM A in QPI, B in SPI) at the broadcast F5h; engine
  handles it (PASS with check relaxed).
- VERIF nit: model schedules dev_oe on with #delay but deselect does not cancel it -> false contention
  when CS# rises < delay_ns after the first data launch (only via mid-transaction reset).
- VERIF: SoC suite only ever runs delay 2 ns, rd_late=0, no hostile hand-over (unit benches cover).
- DOC nits: qspi-memories s4.4 "S_TAIL does exactly this" (tCHD > tACLK+tCLK) false -- S_TAIL gives
  1 tCLK; s6 "3T with S_TAIL" is 2T.

Related: [[finding-branch-review-2026-09-26-full]], [[reference-qspi-pmod-datasheets]].
