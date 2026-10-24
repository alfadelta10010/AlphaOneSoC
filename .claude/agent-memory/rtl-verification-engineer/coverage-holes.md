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
