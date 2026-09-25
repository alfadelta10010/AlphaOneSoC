---
name: finding-branch-review-2026-09-25
description: Adversarial verification of the ~35 fix commits 7f7e6f9..39f6380 (RTL unchanged at 832e068) — all 2026-09-24 C/M/m findings verified fixed; no new CRITICAL; new MINOR pmpcfg R=0/W=1 WARL bug, UNOPTFLAT false loop from 6dbf31d, two SoC-contract risks (no load byte lanes, imem_req always 1)
metadata:
  type: project
---

Reviewed 2026-09-25 (src/tb identical at 39f6380 and 832e068). Method: scratch copy of src/tb,
iverilog tb_rivercore + Spike full-trace first-divergence diff, one run at a time; verilator
--lint-only -Wall and yosys `check` (flattened, pre/post techmap) for loops.

## Verified FIXED (do not re-raise)
- 2026-09-24 C1 (517f04e muldiv_have), C2 (5b48522 !ex_trap in muldiv_want), C3 (1dcf1de trap
  redirect gated on !stall). M: SC withdrawal (00c6b74 WB-commit clear), MRET+irq (e99b231),
  mie forward (b5b6107), request strobes (c579eeb). m: mip (bc0f6d0), mstatush/mhpm*/menvcfg
  (cf1ce18), SRET/reserved enc (a1366f5 — 21-encoding probe matches Spike), counter alias fwd
  (e02f385), PMP 34-bit + NAPOT mask (9c3237b/fccc91a), reservation word (84782b2), misa.C
  lag (6dbf31d), straddle PMA+PMP (96ee78a), MPP WARL/reset (f298958/c519c63), PMP-write
  refetch (2d02808, new sibling nobody had raised).
- Reasoned + measured: every EX-stage side effect now gated by !stall (next_pc all arms,
  ex_mret_commit, wfi_active, EX/WB record, wb_busy set); pc changes only when imem_ready;
  muldiv flush cannot fire with an M-op in EX; trap in WB always has a bubble in EX.
- Straddle: hi-phase interacts correctly with load-use, wb_mem_stall, muldiv, irq (interrupt
  on a straddling insn in hi phase -> mepc = start, matches Spike), MRET into a straddle,
  locked-PMP M-mode both directions (mtval = hi half only when only hi faults).
- Measured matches: muldiv chain x8 timings; U-mode all-straddle x4; interrupt differential
  (U-mode loop, straddles+M-ops+AMO+LR/SC, P=41..131, 15 runs, checksum identical to the
  no-irq Spike-checked run); FENCE.I self-modifying code x3 timings; PMP-write refetch with
  load-use on the csrw and random waits + garbage.

## NEW findings
- MINOR (spec): pmpcfg stores reserved R=0,W=1 (csr.v wval 0x3A0) and pmp.v honours it.
  `pmpcfg0=0x1a` reads 0x1a (Spike 0x18); U-mode store to that region succeeds (Spike cause 7).
  Priv 3.7.1 "collective WARL field ... R=0 and W=1 are reserved". Fix: W &= R per byte.
- MINOR (lint/timing): Verilator UNOPTFLAT csr_rdata -> csr_new -> misa_after_we -> misa_c
  -> mepc_eff -> rdata, introduced by 6dbf31d (0 at e02f385). yosys: 0 problems (no bit-level
  loop). Root: csr_new falls back to rdata when op!=01 although fyracore only ever drives 01
  with we. False STA path raddr->CSR read mux->misa_c/mstatus_mie/mie_out->ex_trap/irq->next_pc.
  Fix: csr_new = wdata.
- MAJOR (SoC contract, not an ISA bug): loads carry no byte-lane/size info (dmem_addr word
  aligned, wmask=0) -> an 8250 UART at reg-shift 0 cannot tell lbu IER (off 1) from RBR (off
  0): serial8250_console_write reads IER every printk -> RX FIFO pops / IIR clears. Sibling
  of c579eeb's UART rationale. Fix: export a lane mask for loads too, or mandate reg-shift=2.
- MAJOR (SoC contract): imem_req hard-wired 1 -> (a) an instruction-fetch-priority arbiter on
  a shared QSPI bus starves dmem forever (WB load never served, stall never clears); (b) fetch
  of an unmapped pc must still be answered or the core hangs before raising cause 1; (c) IO
  fetch side effects; (d) every stall cycle refetches. Document in the port contract or gate.
- NIT: fencei_flush = ex_is_fencei && !stall also fires for an interrupted / fetch-faulting
  FENCE.I (harmless extra invalidate).

## Patterns confirmed
- Word-level structural loops appear when a module both exports a post-write value AND reads
  it back through its own read mux; check with verilator -Wall per commit (yosys alone won't).
- The other session adds tests/MANIFEST while a review runs; RTL can be stable while HEAD moves
  — diff src/tb against the scratch copy before concluding.

Related: [[finding-branch-review-2026-09-24]], [[finding-lrsc-policy-2026-09-22]],
[[reference-kianv-memory-map]], [[verification-flow-river-core-riscof]].
