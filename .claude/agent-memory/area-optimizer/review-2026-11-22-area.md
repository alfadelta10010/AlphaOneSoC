---
name: review-2026-11-22-area
description: 2026-11-22 read-only area review of 4x4 HEAD 2a2978e: ranked cuts (cache 8x32B, PMP G=10, AMO on muldiv adder, muldiv no-m, mtval zero, signExt), per-hier inflation facts, flat cone attribution method
metadata:
  type: project
---

Report: localFiles/rtl-review-2026-11-22/C-area.md. No synthesis was run; everything is ESTIMATED except the cone numbers.

**Facts measured:**
- Per-hier (keep) numbers inflate. inc64 is 2,394 µm² per instance x3 (mcycle/minstret/mtime); its flat cone is only ~0.7-0.9k. Totals: 207.1k hier vs 168.9k flat.
- Flat attribution of the 3x4 netlist of 10-25 (localFiles/harden-2026-10-25/synth): flops are 22 % of the area; TT cells are `_2` (nand2 6.26, xor2 16.27, mux2 11.26, dfxtp_2 21.27).
- Costliest registers by cone: exwb_rs2_data 13.3k (CSR RMW + AMO), muldiv 14.5k, CSR regs 17.4k, CLINT 10.3k (mtip `>=` 1.7k), m reg 2.05k, exwb_trap_pc 1.5k, ifex_raw16 1.1k.
- Flop Q nets carry port names: csr_unit.csr_new = exwb_rs2_data, soc.bus.d_addr = exwb_alu_result, amo_old_val = exwb_trap_val, ex_pc_hi = pc.

**Ranked proposals:**
1. N1 cache as 8x32 B lines: -5.7..6.2k; it is in the hot GRT corner.
2. N2 PMP G=10 + pmpaddr[31:30] RO-0: -3.5..5k.
3. S2 AMO on muldiv adder: -1..2k, safe.
4. N4 muldiv without m (non-restoring): -1.6..2k.
5. N5 mtval=0 for non-memory faults: -1.5..1.8k.
6. N6 no exwb_trap_pc: -1.3k, high risk.
7. S1 signExt format mux: -0.8..1.3k, safe.

**Rejected:** mcycle aliased onto mtime (a write to one moves the other); merged ALU/branch add-sub (the XOR cost eats it); PWM cmpwidth 8 (Linux pwm-sifive assumes 16).

**How to apply:** start any 4x4 area work from this list. Measure S1/S2 and then N1 first on the sandbox, one change per run. See [[area-optimizations-measured]].
