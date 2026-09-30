---
name: finding-soc-arch-review-2026-09-26
description: Pre-RTL review of the SoC architecture doc (native req/ready fabric, mem_ctrl, qspi_ctrl, boot_addr strap, registered MTIP) — no Critical; page-wrap straddle, device-state init, ready-cycle arbitration invariant and read-timing margin are the open Majors
metadata:
  type: project
---

Reviewed 2026-09-26: scratchpad soc-architecture.md (to become docs/soc-architecture.md) at HEAD 682908f. Core
already has boot_addr input (caa2d10), PMA split ROM/RAM/IO0/IO1 (e98761e); clint.v registered MTIP was
uncommitted in the working tree. Fabric/mem_ctrl/qspi_ctrl RTL did not exist yet.

**Why:** user adopted the 09-25b map and asked for the smallest fabric + memory/QSPI controller.
**How to apply:** check these when the RTL lands; statuses below are as of 2026-09-26.

Verified OK (do not re-raise): EBh 8+6+2(FF)+4 correct for flash and = 6 wait for PSRAM; 38h framing; 2-clk deselect
>= tCPH 18 ns / tSHSL1 10 ns; late sampling has no hold hole (change needs a full out-and-back); PMA cause 5/7, SC to
non-reservable faults in EX before sc_success (Spike check_load_reservation agrees); data-first arbitration is
deadlock-free and REQUIRED (fetch-first livelocks: fetch completes during wb_mem_stall, discarded, refetched);
registered MTIP legal (priv 3.2.1 "eventually") and invisible to Linux (clint_clock_next_event sets MTIE before
writeq lo/hi with global MIE off; ISR clears MTIE); mtvec=0 legal (priv 3.4).

Open:
- MAJOR A1: halfword-pc 4-byte fetch crossing a 1 KB PSRAM page relies on RBX (-3SQR) linear burst; non-R /
  "compatible" parts wrap in-page -> silent wrong upper halfword at pc%1K==0x3FE. Fix: split at every 1 KB
  boundary (subsumes the A/B split at 0x807FFFFE) or pin BOM + never send C0h.
- MAJOR A2: device state assumed not established: PSRAM needs 66h/99h after power-up (ds s7); TinyQV's setup leaves
  PSRAM in QPI + flash in continuous read; flash (JV-DTR) treats 38h as Enter-QPI. Want small reset-time init or a
  written RP2040 contract, and CS0 hard-gated by !we.
- MAJOR A3: doc says data req arises "on a cycle a fetch completes" — it is the cycle AFTER; in the imem_ready
  cycle imem_req is still high with the old pc. Engine must never sample *_req in its own ready cycle.
- MAJOR A4: fixed sample point = TinyQV latency 2; at 66 MHz ~3 ns margin vs >20 ns TT round trip + tACLK.
  Recommend a reset-strap for +1 clk latency.
- MINOR: doc PMA table denies AMO on UART/GPIO/syscon but e98761e allows AMO on all IO; tCEM makes clk < ~7 MHz
  (std) / ~14 MHz (ext) unsafe for PSRAM; boot_sel=1 straight into Linux leaves a1 unset (stub or BUILTIN_DTB).
- Perf: baseline ~88 clk/insn (fetch 60 + data + wasted fall-through fetch per taken branch), not 60. Ranking per
  gate: QPI PSRAM > streaming (~1.6x, not 3x) > SCK=clk (only if core fmax < 2*SCK_max).

Related: [[reference-qspi-pmod-datasheets]], [[finding-branch-review-2026-09-25b-memmap]], [[reference-kianv-memory-map]].
