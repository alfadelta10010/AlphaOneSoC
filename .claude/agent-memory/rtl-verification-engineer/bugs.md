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
- TB-005 tests/directed first drafts: .skip regions jumped into (label in
  front of the padding); .text.init over 4 KB moves tohost.
