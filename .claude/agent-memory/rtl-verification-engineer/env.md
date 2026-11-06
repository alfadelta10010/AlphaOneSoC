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
- Spike 5a760667 CLINT (probe 2026-10-23, build/wo/probes/clint-offsets.S):
  offsets 0x0000-0xBFFF answer (hart-0 msip/mtimecmp/mtime; every other
  offset reads 0, sw/sh/sb dropped, mtime_hi writable); 0xC000 and up fault
  (load 5, store 7, mtval = address). Same with or without
  plugins/helpers/spike-fyracore.dtb: Spike ignores the clint reg size. The
  committed dtb is byte-identical to `dtc` of the .dts. Spike has
  `--wfi-as-nop` (all modes; not usable suite-wide: FyraCore's M-mode WFI waits).
- tb_soc_periph's req_hold_check instances are reset by the bench's rst only:
  any SoC-internal reset (syscon reboot/power-off) cuts an outstanding fetch
  and they $fatal. WO-12 resets them with `rst || done`; tb_syscon_soc
  (WO-15) with `rst || soc.rst_soc`.
- Review lesson (2026-10-24): aim directed boundary cases at fire-1 and
  fire+1, not only at the predicted cycle; a model rule never exercised at
  its edge ("frozen while held") hid a DUT/spec split. Re-read my own WO's
  exclusions (sweep data sets) as test targets.
- GL facts (2026-10-25): TT's GL test Makefile (sc-3x4/test) defines
  GL_TEST FUNCTIONAL USE_POWER_PINS SIM UNIT_DELAY=#1 and reads the pnl
  netlist as test/gate_level_netlist.v; rf_top.v's power ports are under
  GL_TEST. GL sim ~8 us simulated per wall second (~500 clocks/s). Sandbox
  read-only ssh works: `timeout 20 ssh -o BatchMode=yes sandbox '...'`.
- EQY 0.62 in librelane:3.0.14 (2026-10-26, tested in sandbox
  ~/regr/eqy/plan-exp): [recode] does NOT cut the gate-side recoded
  register (gate one-hot $dff stays inside every downstream partition) ->
  unusable for FSM recodes; use nomatch + reset `init` attrs on both sides
  + sby abc pdr (honours init; sat cannot find the onehot=E(bin)
  invariant). The container lacks make (coder mounts host make via a
  shim) AND awk (EQY's sby run.sh uses awk '{print $1}' -> every sby
  verdict reads ERROR); strategies.mk caches a sat FAIL as pdr FAIL. Run
  docker as ~/regr/eqy/plan-exp/dkp.sh (shims in plan-exp/bin).
- Yosys setundef with a wire selection does NOT scope the x's that `cutpoint -undef`
  leaves on module connects: `cutpoint -undef A B; setundef -zero @A; setundef -one @B`
  zeroes both. Tie per value instead (cutpoint one set, unscoped setundef, then the next set).
  Guard it: gold_pre.il must hold no other x constant (WO-24 q1 tied misa 1-bits to 0).
- EQY FSM cut point (2026-10-28, sandbox ~/regr/eqy/plan-exp3): yosys has no
  "add cell" command, so the cut is an RTLIL text patch (fsmcut.py) +
  instance of a Verilog module + flatten; `rename -hide w:fsmcutI_*` after
  flatten or the instance port names become public aliases of the cut. In the
  gate RTLIL most FSM bit names are ALIASES (`connect \soc.qspi.state[0]
  \net2205`): the flop's Q is on the netNNN name, so follow module-level
  connects. RTLIL needs wires declared before use (insert after `module`).
  EQY sat strategy runs `formalff -ff2anyinit` on the gate and
  `sat -set-init-undef`: init attrs do not reach sat, only sby/pdr.
  `partition.list` lines are "module partition : nets" (take field 2).
  gate sat invariant: `sat -tempinduct` honours init attrs ("Import
  set-constraint from init attribute"). EQY setup for this design: 30 s.
- yosys 0.66 formal white-box (probe 2026-10-30, toy in scratchpad): a
  hierarchical ref `dut.x` in a harness becomes an implicit UNDRIVEN wire
  (warning "is implicitly declared" only) -> proof about a free signal;
  `bind` parses but its asserts never reach sat (broken toy still "Induction
  step proven: SUCCESS"). Both forbidden. Working recipe: `read_verilog rtl.v;
  expose mod/wire ...; read_verilog -sv -formal harness.sv; prep -top h`
  (harness instantiates mod with the exposed wires as ports; mutant toy killed).
  Coordinator rule: a sat PROVED counts only at induction length 1.
