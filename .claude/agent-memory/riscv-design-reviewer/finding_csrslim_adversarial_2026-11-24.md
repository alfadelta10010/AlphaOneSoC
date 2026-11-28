---
name: finding-csrslim-adversarial-2026-11-24
description: Adversarial review of CSR trims A (no reset on mtvec/mscratch/mepc/mtval/pmpaddr), B (4-bit mcause), D (PMP G=10) at 93a5e4c; river_core Spike DTB overrides --pmpgranularity
metadata:
  type: project
---

Report: localFiles/wo-4x4/reviews/csrslim-adversarial-2026-11-24.md (branch 4x4-alfadelta10010, merge 93a5e4c of rtl/csr-slim).

Verdicts: A sound, B sound, D RTL sound. No BLOCKER and no RTL defect.

**MAJOR-1 (open):** river_core passes `--dtb=plugins/helpers/spike-fyracore.dtb`, whose CPU node still says
`riscv,pmpgranularity = <4>`. Spike's DTB value overrides the `--pmpgranularity=4096` CLI flag (probe: with the DTB,
pmpaddr0 reads 0xffffffff; without it, 0xfffffc00). As a result:
- rv32mi-pmpaddr's "expected divergence" (ref 90 lines, DUT 136) comes from the misconfigured reference, not from PA[33:32].
- With a correct G=10 Spike, the only difference is pmpaddr[31:30].
- rand1 is untrusted until the DTS is fixed to 4096 and rebuilt.
- RISCOF spike_simple runs Spike at the default grain too.
- The directed run.sh and gl/spike_sig.sh do not pass a DTB, so they are correct.

**Minors:**
- NA4 maps to NAPOT, which amplifies a 4-byte lock (demo: NA4 L=1 at 0x80FFFFFC becomes a 32 MiB lock over PSRAM, and M-mode wedges on both Spike and the core).
- The docs must say Zephyr needs `CONFIG_PMP_GRANULARITY=4096` for any `CONFIG_RISCV_PMP` build (z_riscv_pmp_init locks ROM, null-pointer and stack-guard entries), not only for userspace.
- The doc line "unwritten pmpaddr matches nothing" is wrong for a TOR lower bound.
- Nothing guards against a trap_cause with bits [30:4] set.
- EQY accounting EXPECT needs a refit (by my count gold -74, gate -71, cand -3).

**Evidence that holds:**
- Standalone GL csr+pmp netlist with X in the unreset flops: pmp_allow has no X.
- Arch-test 3.9.1 misalign-jal-01 passes with +CSR_X, both at core level and in SoC flash-boot mode.
- FC32-FC37 kill sets are identical on 3bff64f and 93a5e4c (FR14 is equivalent).
- The OpenSBI granularity probe reads back 4096.

**Why:** the user requested an adversarial review of the trims before the sky26d lock.

**How to apply:** before accepting any river_core PMP result, check that the reference DTB grain matches the RTL. See [[patterns-recurring]].
