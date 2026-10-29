# Coverage holes (known unreached bins, and why)

- No core-level reset-in-the-middle-of-a-program test (tb_rivercore cannot
  reset mid-run; Spike comparison would not apply). Covered only by tb_tt_um
  (resets mid-flash-read) and tb_qspi_stress +RESETS on the memory path.
- Formal: only yosys `sat` (tb/formal/run.sh, csr WARL invariants). No
  pipeline-level formal.
- UA07: CLOSED by 7467761 (late-break sweep; review approved 2026-10-22). Was: needs
  RX to rise exactly on the mid-bit-9 sample of the counted low line.
- SoC-file "after" mutation campaign not run (only "before": test-qspi
  kills every MC/QS; soc-level benches are weak on the memory path).
- (2026-10-23) AS06-class holes: a reset that cuts a transaction is only as
  good as the state it lands on. mem_ctrl's `second` (split-fetch second
  half pending) is reachable at a reset only via an asynchronous-to-program
  source (watchdog, pin); WO-15 syscon_wdt_split covers it with floors on
  "split second half in flight" and "data in flight" at E1.
- (2026-10-24) tb_syscon (8eeba2e): fire-1 stores (SA-009) not aimed; sweep
  W1C-alias check vacuous; FINISH codes not swept at +0x04..+0x1C; CHIP_ID
  default not exercised (parameter overridden). Required edits in the
  WO-14 review; close when the fix commit lands.
  2026-10-24: all four go to WO-14a (after WO-23).

## Pins-only (WO-26 plan, 2026-10-29)
- Lost at the pins for all mailbox programs: req_hold_check on core/memc/qspi ports, ready-only-
  while-selected, no-irq-inject-while-dmem-waits, rst_soc cycle-exact. Covered only by EQY (WO-24).
- irq_stall is the weakest pins port: "pending during held store" and per-part hit floors are internal.
- GPIO OUT bits 5:4 have no pin (uo_out[4]/[5] = TX/RTS#): program readback only.
- Program facts: tests/soc assume UART_DIV_RESET=4 (tb override); the chip resets to 27
  (docs/pins-and-peripherals.md). periph_access.S:81 and syscon_reboot boot 2 hardcode 4;
  uart_echo.S:39 DELAY encodes DIV-4 char time.

## WO-26 review (2026-10-30, Opus) -- findings against 5ba6d0f..5b21b4a
- TB defect (BLOCK): tb_tt_um.v split proxy (a_start, :440/:656) is never cleared and ignores the cut
  class; GL wdt_split reported 6 "split" windows, only 1 and 9 genuine (2/6/10 stale a_start from an
  earlier boot, 5 = first half in flight); 3 and 7 (second half in flight, memc.second=1) missed.
- TB gap (BLOCK or relabel): syscon_poweroff "in flight at the hold start" printed, never enforced.
- No progress floor at the pins for clint_decode / syscon_regs (FINISH only; their rows are identical).
  Mitigation: GL cycles == RTL cycles (all 17 identical on partD-20261029); not enforced by run_gl.
- MB_UART periph_access waits TEMT before the DLL rewrite: "divisor write with a character on the line"
  is no longer exercised at div 27 / GL (uart.v reload = 16550 behaviour, < 1/16 bit shift).
- syscon_regs: 336 syscon loads statically; 335 compared exactly by the program, 1 unchecked (step 7 RMW lw).
- Payload strings cannot hold NUL: a spurious 0x00 byte is invisible to s_pay/mb_pay compares.
