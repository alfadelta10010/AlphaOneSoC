---
name: verification-flow-river-core-riscof
description: How FyraCore is verified (river_core + RISCOF + Spike trace diff), how to reproduce one test standalone, and how to tell a real RTL failure from an infrastructure failure
metadata:
  type: reference
---

Flow: **river_core** drives a **RISCOF / riscv-arch-test 3.9.1** generator and diffs the DUT's
per-instruction dump against a **Spike** `--log-commits` trace. It is a *trace* comparison, not a
signature comparison (`river_core/utils.py::compare_dumps` → `diff -iw dut.dump ref.dump`).

Key facts for reading results:
- `logcomparison()` in `river_core/rivercore.py` calls `compare_dumps(dut.dump, ref.dump)`, so in
  the recorded `log:` diffs **`<` is the DUT and `>` is Spike**.
- A log beginning `0a1,N` means **dut.dump was empty** → infrastructure failure, not an RTL bug.
- `report.html` can show "DUT Unavailable" for *every* test when river_core cannot find the DUT
  json; that is a global override, not per-test. `failed_list.yaml` (written before the override)
  holds the real per-test comparison results.
- Trap-entry CSR writes (mepc/mcause/mtval/mstatus) are **not** in Spike's commit log. They are
  compared only indirectly, via the arch-test trap handler's `csrr` + `SREG` of the trap signature
  (which appears as `mem <addr> <value>` lines).
- `arch_test.h` `SET_REL_TVAL_MSK` includes CAUSE_BREAKPOINT but **not** CAUSE_ILLEGAL_INSTRUCTION,
  so mtval is compared for EBREAK but stored as 0 (uncompared) for illegal instruction.
- `hw_data_misaligned_support` defaults to **false** in riscv-config, so misalign-l*/s* select the
  trapping test-case variant.
- Spike sets **mtval = PC of the EBREAK** for cause 3 and **mtval = instruction bits** for cause 2.

Reproduce one test standalone (touches no project files):
1. `iverilog -g2012 -o sim -s tb_rivercore src/{alu,branchCtrl,clint,compressed_decoder,controller,csr,decoder,fyracore,muldiv,pmp,regFile,regs,signExt}.v tb/memory_model.v tb/tb_rivercore.v`
2. `riscv64-unknown-elf-gcc -static -std=gnu99 -O2 -mcmodel=medany -nostdlib -nostartfiles -march=rv32imac_zicsr_zifencei -mabi=ilp32 -T plugins/riscof_plugins/fyracore/env/link.ld <test>.S -I <arch-test>/riscv-test-suite/env -I plugins/riscof_plugins/fyracore/env -D<macros> -DXLEN=32`
3. `objcopy -O verilog --change-addresses=-0x80000000`; run
   `vvp sim +INIT_FILE=... +DUMP_FILE=dut.dump +TOHOST_ADDR=$(readelf -s ... tohost) +MAX_CYCLES=1000000`
4. Post-process DUT: `sed -E '/\(0x00000063\)$/d;/\(0x0000006f\)$/d'`
5. `spike --hartids=0 --log ref.dump --log-commits --priv=mu --pc=0x80000000 --isa=rv32imac_zicntr --pmpregions=8 --pmpgranularity=4 <test>.elf`
   then `sed '1,5d'`, strip `c[0-9]+_(mstatush|tcontrol|mtinst|mtval2|mscratchcsw|mscratchcswl|mtinstcsw)`,
   and delete `(0x00000063)` / `(0x0000006f)` lines.
6. `diff -iw ref.dump dut.dump`

**Why:** the headline "158/176" mixed 3 genuine ISA bugs with 15 runs where the DUT dump was never
written, so the pass count under-reports correctness and hides the real bugs.
**How to apply:** classify every failure by its first diff hunk before assuming an RTL defect.

Notes now live at the absolute path `.claude/agent-memory/riscv-design-reviewer/` in the repo
root (relocated after an earlier loss under build/). When reproducing trap-taking tests with
Spike, omit `--instructions` — see [[reference-spike-probed-behaviours]].

Related: [[project-fyracore-overview]].
