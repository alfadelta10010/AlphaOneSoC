---
name: finding-qspi-stream-ddr-review53
description: 2026-11-08 REVIEW-53 of qspi-stream branch ae6742c (SDR streaming, EDh DTR variant P'', QSPI_CFG, FC02/FC49 removal) — 0 Crit, 2 Major (m1 3-bit overflow, io_out mixed-edge pin cone)
metadata:
  type: project
---

Review doc: localFiles/qspi-stream-ddr/REVIEW-53.md (committed tree ae6742c, read-only, no sims).

- **M-1 (open)** qspi_ctrl.v:345 `wire [2:0] m1 = (t_cap + 3'd2) >> 1` sizes in 3 bits -> DDR_CAP 6,7 give m1=0,
  dq[7] out of range (x in iverilog, proven by an 8-line eval): sr never shifts in RTL sim, gates may differ (x = don't-care).
  Fix `t_cap[2:1] + 1`. Hidden because test-qspi-ddr-sweep only prints (V-2) and R sweep stops at 32 ns.
- **M-2 (open)** io_out = t_ddr ? nib_n : io_sdr: DDR pin cone has posedge-launched io_sdr (hazard lands in tCHDX
  window), SDR cone now has negedge nib_n (nib_p loads every clock). Cheap SDR fix: nib_p <= t_ddr ? nib_next : F.
- V-1: syscon_gate P3 asserts DDR_CAP==0 but DDR_CAP_RESET=2 since 6dee0f1; verify-all.expected still PROVED.
- FC02/FC49 removal SOUND (inductive: EX/WB load edge => IF/EX ex_ph=0; OP/OP-IMM excluded from every flush term),
  but core_inv was deleted (ca6e008) and nothing now asserts the two invariants (V-3).
- Verified: EDh per-edge protocol (↑0 bit comes from the idle F, works only because EDh MSB=1 — m-1), capture
  accounting 0..5, held nibble at S_CHK->S_DATA, CS gaps, CS0 exclusive, p wrap, mode-change close, reset mid-stream.
- DDR path ignores nbytes_m1 (flash reads always 4 B via mem_ctrl; m-2).

**Why:** DDR is off at reset so boot is safe; DDR claims need M-1 + a failing-capable sweep + WO-55 GL/STA.
**How to apply:** on the next qspi_ctrl review check M-1/M-2/V-1..V-3 status first; watch for 3-bit arithmetic on
small config fields and print-only sweeps (see [[patterns-recurring]]).

## 2026-11-09 final pre-merge review @2a97dcd (vs main 3ad7991)

- 0 BLOCKER / 0 MAJOR. M-1 fix (m1 = t_cap[2:1]+1, 1..4) and M-2 fix (io_out = nib_n & (io_sdr | {4{t_ddr}}), nib_p held F
  in SDR) both correct; V-1 fixed (syscon_gate P3 uses DDR_CAP_RESET); V-2 fixed (qspi_ddr_sweep.sh has expected sets, exits 1);
  V-3 fixed (tb_rivercore FC02/FC49 every-clock checks + antecedent counts) -- sim-only, no formal since core_inv retired.
- Only RTL since ae6742c: the two fixes + UART DIV_RESET 34. Traced: sr/p invariant on every strm path, t_ddr/t_cap change
  only with CS high (S_IDLE !strm, S_GO), take_cont io_in is >= m1+2 clocks after the held nibble's launch for every cap.
- RAN (sandbox ~/regr/qs/rev-6a/rtl): tb_qspi_stress copy with random ddr 0/1 + cap 0/1 flips (~6.3k each, all with start
  high) x STREAM_TOGGLE/RESETS/seeds: PASS, 0 setup/hold violations. Idea for a permanent +DDR_TOGGLE run.
- MINOR docs: syscon.v:27-29 "stored only" stale (qspi_ctrl consumes DDR/DDR_CAP); uart.v:24-25 "(115200 +0.5% at the old
  50 MHz)" reads as if 34 gives that (34 @50 MHz = 91.9 kbaud).
- Board: Pmod has 10k CS pull-ups (docs/qspi-memories.md 8.3), so a pin release with a stream open deselects the flash.
