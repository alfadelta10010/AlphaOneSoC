---
name: spec-legality-notes
description: Which area trades are RISC-V spec-legal / Linux-safe for this NOMMU M-mode target (counters, PMP, mtval, mcause, LR/SC set, M/A emulation)
metadata:
  type: project
---

- mcycle, minstret: mandatory, 64-bit on RV32 (Priv "Hardware Performance Monitor").
  Only mhpmcounter3-31/mhpmevent3-31 may be read-only 0. mtime/mtimecmp also 64-bit.
  mcountinhibit is WARL (may be RO zero). Reset value of counters is arbitrary.
- PMP: 0 entries is legal; with none implemented, U-mode accesses succeed. Linux M-mode
  head.S writes pmpaddr0/pmpcfg0 under a temporary trap vector, so absent/RO-zero is fine.
- mtval on illegal instruction may be 0 (encoding is optional). mcause code is WLRL.
- LR reservation set may be larger than the word ("subsumes"). Spike is word-exact, so
  lockstep diverges.
- M and A cannot be trap-emulated for stock M-mode Linux: kernel is built rv32ima and
  owns mtvec itself; there is no firmware underneath to emulate.
- Drop C costs no runtime here: every fetch is a full 4-byte QSPI read (~60 clk) anyway.
- U-mode must stay: M-mode Linux decides user-vs-kernel return from MPP.

- Priv (current, local docs/RISCV-spec.html): PMP "Implementations may implement zero, 16, or 64
  PMP entries ... All PMP CSR fields are WARL and may be read-only zero" (so 4 usable = 16 with
  12 RO-0); mcountinhibit may be absent (acts as 0); mcounteren must exist with U-mode but all
  fields may be RO-0; mtvec may be read-only; mcause Exception Code is WLRL; reset: only
  MIE/MPRV, mcause, PMP A/L specified, "All other hart state is UNSPECIFIED".
- Linux of_serial "ns16550a" sets UPF_FIXED_TYPE, so autoconfig (SCR/IER/loopback tests) never runs.

**How to apply:** label any trade touching these as spec-legal-but-diverges-from-Spike
where relevant; see [[area-optimizations-measured]].
