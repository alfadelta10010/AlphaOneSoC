# Coverage holes (known unreached bins, and why)

- No core-level reset-in-the-middle-of-a-program test (tb_rivercore cannot
  reset mid-run; Spike comparison would not apply). Covered only by tb_tt_um
  (resets mid-flash-read) and tb_qspi_stress +RESETS on the memory path.
- Formal: only yosys `sat` (tb/formal/run.sh, csr WARL invariants). No
  pipeline-level formal.
- UA07 (UART frame accepted after a framing error) survives tb_uart (WO-02 specs the sweep): needs
  RX to rise exactly on the mid-bit-9 sample of the counted low line.
- SoC-file "after" mutation campaign not run (only "before": test-qspi
  kills every MC/QS; soc-level benches are weak on the memory path).
