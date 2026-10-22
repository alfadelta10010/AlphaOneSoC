# Environment (verified 2026-10-18)

- Machine: 8 cores, 15 GB RAM, /tmp is RAM tmpfs (do not put sims/logs there).
  Max 2 simulations in parallel, everything under `timeout`. /home fills up:
  check `df -h /home` before campaigns, keep the footprint < 3 GB.
- Put scratch artifacts under `build/` (gitignored). `make clean` wipes
  build/ entirely, so run make with `BUILD_DIR=build/tb` when logs live in
  build/logs or build/mut.
- Tools: iverilog/vvp 13.0, Verilator 5.031 (/tools/verilator-euvm/bin),
  yosys 0.66 + yosys-smtbmc (no sby, no SMT solver binary found: z3/yices/
  boolector absent, so no sby/smtbmc flow; yosys's built-in `sat -prove` /
  `sat -tempinduct` needs no external solver and works on small blocks), Spike (/tools/rv32-isa-sim/bin,
  upstream 5a760667 since 2026-10-18; refs byte-identical to 7ab2efd6 for
  spike-compared tests), riscv64-unknown-elf-gcc 14.2 (/tools/rv64-gcc-elf).
- iverilog quirks:
  * `$fatal` exits 1, `$error` exits 0; `vvp x | tee` hides the exit status.
  * Verilog-2001 functions need >= 1 input port (unit benches are compiled
    without -g2012).
  * `?:` with unsigned arms makes `$signed(a)/$signed(b)` divide unsigned:
    compute signed results in signed variables first.
  * `bit` arrays need -g2012; scripts/run_asm_test.sh compiles without it.
  * A function call cannot be bit-selected (`f(x)[3:0]` is a syntax error).
- Baseline timings (484ec59, this machine): `make test-all` 469 s; directed
  core suite 138 runs 1208 s (each run ~10 s, 9.9 s of it memory_model's
  16M-byte zero-fill until the 2026-10-18 change; ~0.1 s after).
- Commands:
  * unit: `make BUILD_DIR=build/tb test-<x>`; seeds: `make test-seeds SEEDS="1 2 3"`
  * directed: `cd tests/directed && ./run.sh` (build+suite), `./run.sh soc`,
    `RUN_PLUSARGS="+RF_X +RF_COLLIDE_X" ./run.sh`; knobs FYRA_SRC, OUT_DIR, FAILFAST
  * mutation: `python3 tb/mutate/run.py --check`, `-j 2 [--tree build/before]
    [--results build/mut/before.tsv] [--benches unit,dir,soc]`, `--report`
- Do not edit tests/directed/run.sh while a run.sh is executing (bash reads
  scripts incrementally). Freeze a tree with `git archive HEAD src tb tests`.
- Whole-core formal with yosys sat (2026-10-21): rf_top.v cannot be read
  ($test$plusargs; its SYNTHESIS form is an empty blackbox sat rejects), use a
  stub with undriven read data; passes `prep; chformal -lower; flatten;
  memory_map; setundef -undriven -expose; opt -fast` then
  `sat -tempinduct -tempinduct-def -prove-asserts -set-init-zero
  -set-def-inputs -seq 1 -maxsteps N`. Induction runs take 7-80 s.
- GL assets (2026-10-21): newest hardened netlist = sandbox
  /home/mempool/tt/projects/sub-port/runs/wokwi/final/pnl/*.pnl.v (2026-10-19,
  62.5 MHz); its src/ equals this branch's src modulo comments. tb_tt_um
  takes power pins as nets under USE_POWER_PINS (gl.sh's sed patch is
  obsolete). Defines: GL_TEST FUNCTIONAL USE_POWER_PINS SIM UNIT_DELAY=#1;
  files gls_model/{primitives,sky130_fd_sc_hd}.v + pnl + src/rf_top.v + the
  two models + tb_tt_um.v; earlier GL runs: PASS, GL = RTL + 1 cycle.
  netlists/ in the repo is 2024-era and unrelated.
