---
name: project-fyracore-overview
description: FyraCore/AlphaOneSoC design intent — ISA string, privilege model, pipeline style, memory map, and TinyTapeout sky130 / NOMMU M-mode Linux target
metadata:
  type: project
---

FyraCore is a **3-stage in-order pipeline** (IF / EX / WB) implementing
**RV32IMACU_Zicsr_Zicntr_Zifencei**, in `/home/alfadelta10010/projects/AlphaOneSoC/src/`.

- Top: `src/fyracore.v` (~1250 lines at 39f6380). Submodules: `alu.v`, `branchCtrl.v`, `controller.v`,
  `decoder.v`, `signExt.v`, `regFile.v`, `csr.v`, `compressed_decoder.v`, `muldiv.v`, `pmp.v`, `clint.v`.
  `src/regs.v` and `src/memController.v` are **not instantiated** anywhere (dead).
- Privilege: **M + U** (no S, no MMU). `misa` reset `0x40101105`; only the **C** bit is writable (WARL).
- mstatus writable: MIE, MPIE, MPP(00/11), MPRV(17), TW(21) since 8485cf0/7cd1eb6.
- `mtvec` MODE hardwired to **direct** (WARL); `mepc[0]` forced 0, `mepc[1]` masked on read when misa.C=0.
- PMP: 4 entries, TOR/NA4/NAPOT, **two** checker instances (I-fetch + data), both fed from `csr.v`.
- Multicycle units: `muldiv` (33–34 cycles, shift-add multiply + restoring divide);
  AMO takes a 2-cycle WB via `wb_busy`.
- Sim memory (`tb/memory_model.v`): flat 32 MB byte array + CLINT at 0x0200_0000;
  `RESET_PC = 0x8000_0000` (aliases to mem[0] because the model masks addr[24:0]).
  It supports **unaligned 32-bit instruction fetch**, which real QSPI/PSRAM will not.
- Target: sky130 / TinyTapeout with **external QSPI flash + PSRAM**, eventual NOMMU M-mode Linux.
  Closest proven analogue: KianV uLinux SoC.

**Why:** the tapeout target has wait-stated external memory. Since 68d85b6 `tb/memory_model.v` has
+IMEM_WAIT/+DMEM_WAIT/*_RANDOM wait states, but it drives rdata = X while !ready, and iverilog
treats `if (X)` as false — that HIDES bugs where garbage pre-ready data feeds a control decision
(the 2026-09-24 spurious-trap-redirect CRITICAL). Also rerun with a bus returning 0/garbage.
**How to apply:** never conclude that stall/handshake logic is correct from a project-TB run;
re-check it against a wait-state model. Since 0d7f773 the model has +NOTREADY_DATA=1 (zeros) / 2 (LFSR
garbage) and a request/ready handshake checker ($fatal on a withdrawn/changed request) — use modes 1/2. See [[finding-wb-stall-drops-memory-op]].

Related: [[verification-flow-river-core-riscof]], [[finding-mret-multicommit-on-stall]],
[[finding-exception-priority-illegal-vs-misaligned]].
