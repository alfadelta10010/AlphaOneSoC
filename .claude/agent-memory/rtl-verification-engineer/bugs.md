# Bugs found

(none yet in this pass -- 2026-10-18)

## TB bugs found and fixed
- TB-001 Makefile run_tb piped vvp into tee (exit status lost) and grepped
  only ^FAIL/^TIMEOUT: a $fatal, an ERROR line, or a bench that ends early
  without a summary passed.
- TB-002 tb_compressed_decoder: C.ADD field check used && (failed only if
  rd AND rs1 were both wrong); most cases checked opcode/funct3 only, with
  zero immediates.
- TB-003 tb_qspi_stress: no progress floor or wait bound -- a deadlock
  part-way through the 400k random clocks still printed PASS (b22129a).
- TB-004 my own new benches (caught before commit): $random(seed) moves
  seed, so PASS lines printed the end state, not the reproducing seed;
  tb_csr's sweep/post-reset reads advanced time with the clock running
  (counters ran ahead of the model); the muldiv model divided unsigned
  inside ?: with unsigned arms; memory_model's first fill-free read
  helper read mem[] inside a function (continuous assign not sensitive).
- TB-006 (2026-10-23, found planning WO-10) tests/directed/wfi_umode: the
  handler's mret back to M-mode kept MIE=1 (MPIE=1 from the previous mret),
  so a core whose U-mode WFI waited re-took the still-pending timer at cont_b
  forever (FC86 copy: 13617 traps, DUT-ABORT). The "waits" alternative the
  MANIFEST accepted could never pass. Fix in WO-10 (clear MPIE).
- TB-005 tests/directed first drafts: .skip regions jumped into (label in
  front of the padding); .text.init over 4 KB moves tohost.

2026-10-22: candidate review (FC02 FC49 FC27 MD07 RG01 RG04, CLINT window): no DUT bug; see vplan.md "Candidate verdicts".

## 2026-10-24 candidate (pending SA-009 decision)
- BUG-001? [Low] syscon watchdog fires on E1 of a FINISH reboot / power-off
  hold (en still 1 for one clock). Reproducer build/wo14rev/probe_e1.v:
  `cd build/wo14rev && iverilog -o probe_e1 ../../src/syscon.v probe_e1.v
  && vvp -n probe_e1` -> RESET_CAUSE 0x7 after reboot, 0x5 in power-off.
  -> 2026-10-24: user decision = RTL fix (WO-23, fire gated by rst_soc).
     Close BUG-001 when WO-23 lands and WO-14a's k=16..18 pass (WD16 FAILs).
