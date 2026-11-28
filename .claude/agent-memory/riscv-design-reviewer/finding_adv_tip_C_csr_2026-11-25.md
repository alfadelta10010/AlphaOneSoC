---
name: finding-adv-tip-C-csr-2026-11-25
description: Second adversarial look at the CSR-slim trims at tip f75a734; RTL unchanged and sound; fix gaps (Zephyr port grain, rand1 G=0 programs, no grain preflight, +CSR_X X-optimism)
metadata:
  type: project
---

Report: localFiles/wo-4x4/reviews/adv-tip-2026-11-25/C-csr.md (slice C of the six-slice tip review, 2026-11-25).

**RTL:** `git diff 93a5e4c^2 f75a734 -- src/csr.v src/pmp.v` is empty, and no src change after 93a5e4c. No RTL defect.
Re-derived against current main `src/priv/machine.adoc`. mcause is still "WLRL, only guaranteed to hold supported exception codes";
there is no 0-31 requirement, so do not re-raise that.

**Fixes verified:** `dtc` of spike-fyracore.dts is byte-identical to the blob, and the only diff from the old blob is pmpgranularity 4 -> 0x1000.
C16 covers the single source of mcause (exwb_trap_cause).

**Open findings (all MINOR or NIT):**
- C1: sw/zephyr/zalpha/.../Kconfig.defconfig lacks `PMP_GRANULARITY default 4096`. Zephyr's IRQ-stack guard is PMP_NONE|PMP_L
  (checked in Zephyr main pmp.c). A sub-4 KiB NAPOT becomes a locked region of at least 4 KiB over the live IRQ stack, which wedges
  (PLAUSIBLE). RESULTS.txt userspace PASS (11-22) predates G=10.
- C2: the rand1 rerun replays riscv-dv programs generated at pmp_granularity=0. pyflow bakes g into NA4 selection and the fault-handler
  NAPOT mask (riscv_pmp_cfg.py:159,408). Lockstep agrees, but the PMP tests may degenerate.
- C3: river-config.ini:128 uses an absolute local DTB path that sandbox trees hand-edit, and there is no grain preflight probe.
- C5: the tb_rivercore comment "+CSR_X catches read-before-write" is false for the TOR lower bound. In pmp.v `if (match1)` with X takes
  the else arm (Icarus X-optimism). Only GL or random init catches it.
- C6: no OS image has run with non-zero power-up CSRs (the Verilator runtime default is zero, the tb zero-inits, FPGA flops start at 0).

**Why:** the user asked for a hyper-critical review of the tip before the sky26d lock (closes 2026-11-30).

**How to apply:** before accepting river_core PMP evidence, check that the programs were generated at the RTL grain, as well as the DTB.
Treat Icarus `+CSR_X` as blind to implicit reads that go through `if` conditions. See [[finding-csrslim-adversarial-2026-11-24]] and
[[patterns-recurring]].
