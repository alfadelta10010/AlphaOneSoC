---
name: soc-performance-measured
description: Measured clocks per instruction class through the whole SoC (PSRAM QPI, 4b4ed8b) and two ~zero-area fetch fixes worth ~14% (M op refetch, speculative fall-through fetch on branches)
metadata:
  type: project
---

Measured 2026-09-29 at 4b4ed8b, SoC sim (-DSOC_TB, qspi_pmod_model, rd_late 0), code in PSRAM.
Microbenchmarks = 256 copies of one 32-bit instruction (`.option norvc`), delta vs 1 copy:
- ALU / csrr: **42.0 clk** (= one 4-byte PSRAM QPI read, the fetch floor)
- lw 84.2 · sw 76.1 · sb 64.1 · taken branch / jal **84.2** · not-taken branch 42.0
- mul / mulhu / div: **84.2** — the extra is exactly one refetch (muldiv_start waits for
  !stall_other, which includes if_mem_stall; muldiv_stall then drops the completed fetch).
- Compiled C (crc32 + insertion sort + list walk + div, -O2, ~10.4k instr): 56.1 clk/instr,
  so the PR's 57.1 is representative. 0.89 MIPS at an (unverified) 50 MHz.

Two fixes, both ~0 area (4-order SoC mean 13.60 t vs 13.61 t), prototypes in
`localFiles/area-audit/pr5/{mdfix,brhold,both}/fyracore.v`:
1. mdfix: muldiv_start ignores if_mem_stall only (keeps load-use, wb_busy, wb_mem_stall, wfi,
   ifetch_hi, flush). M op 84.2 -> 42.0. C bench -3%.
2. brhold: imem_req low while a branch/jump is in EX (ex_cti); not-taken -> bubble + pc
   stays. Taken CTI 84.2 -> 43.0, not-taken 42.0 -> 43.0. C bench -11%.
Both: C bench 56.1 -> 48.3 clk/instr (-14%); SoC-suite aggregate 59.2 -> 53.0. Verified
locally: core suite 106/106 and `run.sh soc` 66/66 for mdfix alone and for mdfix+brhold.
- The PR's "57.1 clk/instr (tests >= 40 instr)" does not reproduce at 4b4ed8b: same definition
  gives 63.9 mean-of-CPI over 17 tests (wfi_slow 136 inflates it), 59.2 aggregate.

10a37c3 + series (2026-09-30, `localFiles/area-opt-2026-09-30/res/bench_*`): base 56.10,
perf-only 48.30, final area stack 48.42 clk/instr. Shared muldiv (34/36 clk) and serial shifts
(2+shamt, 33 max) stay hidden behind the 42-clk fetch with mdfix; 1-read-port adds +1 clk per
branch with rs2 != x0 (43 -> 44). A 16-bit compressed-pair fetch buffer would skip 16.9% of
fetches on the C bench (~-15% clocks, ~+0.05 t est., not built).

**Why:** memory-bound core; a fetch is 42 clk, so wasted fetches dominate CPI.
**How to apply:** quote these instead of the old "t_mul 84 vs 73" (stale framing). The
"+0.1 t mem_ctrl fetch buffer" is not needed for the M-op case.
