> **User rule 2026-10-25 (revised):** design size = whole TT tiles of the config
> hardened (3x4 -> 12 tiles) + the shape (AxB), routing density % (GRT usage) and area
> utilization % as two separate numbers, the headroom left, and flagged limits. Never
> fractional "t" (the old 11,300 µm²/tile @60 % factor is retired); harden only at
> TT-selectable sizes. Older "N.NN t" figures below = std-cell µm² / 11,300.

# pd-expert notes

## 2026-10-13: assessment of sandbox harden `rfm2-a3fo` (read-only)

### Flow / tools (verified from the run's files)
- LibreLane 3.0.14 (`runs/wokwi/pdk.json`), sky130A open_pdks 8afc8346, tt-support-tools 01d5d28, via `tt_tool.py --harden`.
- Sandbox: `ssh sandbox` (mempool.lan). Project `/home/mempool/tt/projects/rfm2-a3fo`, job dir `~/regr/rfm/harden/rfm2-a3fo`.
- Local `/usr/bin/sta` is OpenSTA 2.0.17 (old). On this netlist+SPEF it reproduces the flow's WS to
  0.003 ns (hold, ff), 0.06 ns (setup ff), 0.19 (setup tt) but is 0.77 ns MORE pessimistic at ss
  setup (-5.66 vs -4.89). Use it for deltas and hold; quote the flow for absolute ss numbers.
  Old syntax: no `report_check_types -violators`; redirect with `> file` on the command itself.
- Mid-PnR STA steps (31/36/38/43) only refresh nom_tt; the ss/ff keys in their state_out.json are
  stale copies of step 12 (pre-PnR). Do not read them as mid-flow ss results.
- Flow's STA never runs min-pulse-width / min-period checks (only max slew/cap/fanout).
- TT flow fails only on: tt setup (`TIMING_VIOLATION_CORNERS ["*tt*"]`), hold any corner, Magic DRC,
  LVS, PDN, lint errors. ss setup, slew, cap, fanout are warnings. KLayout DRC/XOR/EQY are off.
- TT precheck (sky130): Magic DRC, KLayout FEOL/BEOL/offgrid/pin-label/zero-area, pin, boundary,
  power pin, layer, cell name, urpm/nwell, analog pin, verilog syntax. No antenna, LVS, timing.

### rfm2-a3fo results (metrics.json)
- Setup ws: tt +7.24/+7.73/+6.80 (nom/min/max), ss -3.93/-2.88/-4.89, ff +10.07/+10.39/+9.78.
- Hold ws: tt 0.285, ss 0.786-0.791, ff 0.105; 0 violations at all 9 corners.
- Slew viol: 303 max_tt, 3338 max_ss, 75 max_ff. Cap: 26/45/25. Fanout: 1 everywhere.
- report_clock_min_period: max_ss 24.89 ns (40.2 MHz), max_tt 12.77 (78.3), max_ff 9.89.
- 624 hold buffers, all dlygate4sd3_1, all at step 37 (post-CTS). Post-GRT resizer steps are gated off,
  so GRT_RESIZER_HOLD_SLACK_MARGIN is a dead knob.
- Std cells 138,668 um2 = 12.27 t; util 60.6 % (58.1 % std-cell only); GRT overflow 1836, met2 90.6 %.

### Root causes found
- ss critical path starts at exwb_rd[]: the hold fixer put hold522-527 at the Q of exwb_rd[4:0] to
  meet the macro's placeholder w_addr hold (0.2 ns); that net also feeds the forwarding compare.
  254 of 259 max_ss violators pass through a hold buffer (1.2-2.6 ns each). RTL fix: a private copy
  of the write-address register for the macro.
- Macro w_data pins are driven by buf_1 over 0.5-0.9 mm wires: slew 2.98 ns (tt) / 4.74 ns (ss) at
  w_data[6]; lib's own max_transition 0.1 violated on 14-16 control pins. No post-route design repair.
- DRV on clock: only clkbuf_0_clk_regs/X max-cap (0.306 vs 0.2 pF), slew OK. DRV on the sync-reset
  tree: 5 cap, 1 fanout, 11 (tt) / 201 (ss) slew pins. The 2 "floating nets" are VPWR/VGND.

### Macro rf_top (placeholder liberty, same file every corner)
- Scalars: setup 2.0, hold 0.2, clk->q 4.0, slew 0.25, min period 10, MPW 5, min_clock_tree_path 0.2.
- Macro clock is a separate branch (3 delaybufs); arrives 0.03-0.28 (ff) / 0.05-0.41 (tt) /
  0.11-0.72 ns (ss) EARLIER than flops. No shared path with the flop tree, so no CRPR.
- Macro-launched hold is safe with clk->q = 0 (worst -0.000 min_ff, +0.016 max_ff, one endpoint).
- Macro-input hold is the open fatal-class unknown: ff slack +0.166, so a real hold above 0.37 ns
  at ff fails STA (0.62 ns with the 0.25 uncertainty spent).
- Macro-launched setup at ss is already -1.6 ns (local STA) at 4 ns clk->q; -1.05 ns per extra ns.
- Guard that stays inside TT tooling: per-corner copies of the liberty via `MACROS.rf_top.lib`
  wildcard keys in config.json. Not yet tried.

### GL sim, +QSPI_DELAY=19 (proven by probes in scratchpad pd-expert/gl)
- sky130 FUNCTIONAL models put `UNIT_DELAY` only on flop/latch UDPs (116 uses); combinational cells
  are zero delay. SCK leaves 1 ns late, so data lands in the same timestep as the sampling edge.
- Pure simulator race: a3/a3fo (3 cells on D, 4 clock buffers) sample X; a0/a3td (2 cells, 5 buffers)
  sample data. 1 ps of clock skew makes a3fo pass the whole run; 1 ps of data skew makes a0 fail.
- The "pins differ from clock 171" in every netlist is the bench: reset 2 is aimed off
  `posedge pmod_oe`, which moves across a clock edge, so the reset lands one clock later.
- Use +QSPI_DELAY=18 for gate level.

### I/O timing at the tile boundary (local STA; TT mux and Pmod NOT modelled, SDC is the generic 4 ns)
- SCK clk->port 1.2-1.5 (ff) / 1.8-2.3 (tt) / 3.6-4.2 ns (ss). SD sample aperture at the port:
  data may arrive up to 0.4-1.1 ns after the clk-port edge; must hold 0.55-1.8 ns.
- External round-trip budget at 20 ns: rd_late=0 up to ~36.7 ns, no lower bound;
  rd_late=1 between ~19.5 and ~56.7 ns.

### Open risks / unverified
- Precheck (KLayout FEOL/BEOL) has not been run on this GDS.
- The run is a dirty scratch tree (commit_id 03b1542 does not describe the sources; RTL is
  byte-identical to worktree HEAD 61686d1 src/). Submission repo is still 8x2, flop RF, default config.
- Gate-level coverage of the final netlist is one program (tt_pins.S); EQY off.
- Macro license unresolved (macro/rf_top/README.md).

## 2026-10-14: why the resizer never sees the ss failure (rfm2-a3fo; scripts in sandbox ~/regr/rfm/pd-expert/est.tcl, est2.tcl)
- Container has `openroad` (2026-02-17 build) next to `sta`: `docker run --rm -v /home/mempool:/home/mempool ghcr.io/librelane/librelane:3.0.14 openroad -no_splash -exit x.tcl`; runs on this netlist take <1 min.
- Flow estimator (rsz_timing_postcts.tcl): set_rc.tcl -> set_wire_rc with LAYERS_RC=None => tlef AVERAGE 4.4027e-4 kohm/um, 8.148e-5 pF/um (0.0815 fF/um) for signal AND clock, SAME for all 9 corners; then `estimate_parasitics -placement`.
- Extracted (max SPEF) is 0.21-0.23 fF/um on the 4 named nets (routed length from final DEF: 859/631/561/200 um; caps 0.194/0.141/0.128/0.042 pF) = 2.7x. Routed length also 1.0-2.3x the placement Steiner length (net _07827_ 275 -> 631 um; met3 341 of 631 um = congestion detour).
- Same final odb, max_ss, derate 5 %: estimator +2.24 ns (TNS 0) vs SPEF -4.89 (TNS -811.03). Flat cap sweep with estimator: 1.69e-4 -> -0.95; 2.2e-4 -> -2.98; 3.0e-4 -> -6.19 pF/um; match ~2.6e-4.
- SPEF totals: min 127.3 / nom 143.6 / max 159.6 pF (estimator has no per-corner RC).
- pdk_compat.py has a commented PDK LAYERS_RC table (tt: met1 1.72e-4, met2 1.36e-4, met3 2.15e-4, met4 1.54e-4 pF/um; res = tlef). LAYERS_RC is a config.json-settable PDK var: {"*":{"met1":{"res":..,"cap":..}}}. NOT yet tried in a flow run.
- Area classes in rfm2-a3fo: timing_repair_buffer 10,572 um2 (0.94 t, the 624 hold bufs), sequential 26,518, die 260,160 um2 (12 tiles), DRT needed 16 iterations (177 -> 0).
- repair_design (step 32) saw 430 slew/8 fanout/2 cap violations under the estimator; signoff ss has 3338.

## 2026-10-25: syscon branch harden `sc-3x4` (857883c src, sub-port config; evidence localFiles/harden-2026-10-25/)
- Project /home/mempool/tt/projects/sc-3x4 = sub-port minus runs/ + branch src/*.v (not regs.v) + syscon.v in
  info.yaml AND test/Makefile PROJECT_SOURCES (RTL cocotb needs it). config.json/macro byte-identical to sub-port.
  Sandbox driver ~/regr/sc/run.sh (resumable stages, markers in ~/regr/sc/out/stages), post.sh/rst.tcl/rsttree.py.
- Result: harden rc=0, 37 min (sub-port 28). All 9 corners met: ss setup +1.62/+1.26/+0.86 (min/nom/max), tt +6.65..
  +7.07, ff +8.71..+9.01; hold min_ff +0.189, max_ss +0.586. Std cells 164,259 um2 = 14.54 t (sub-port 14.36), util
  68.8 % (67.9). Flops 1307 (+23 = syscon). DRC/LVS/antenna 0, precheck PASS (same 12 checks as sub-port), cocotb
  RTL 3/3 + GL 3/3 (pnl md5 eb402847). Test program never touches syscon.
- ss +0.32 better than sub-port = placement noise: same critical families (d_addr/opcode/pmpcfg0 -> trap/pc/csr).
- METRIC TRAP: design__instance__count__hold_buffer = RSZ-0032 count of the LAST hold pass only. Real `hold*`
  cells: sub-port/st-hgc16 1,287, sc-3x4 1,404. CONTEXT.md's "92 hold buffers (calibrated)" is wrong.
- rst_soc (F5): one or3_2 (A = rst via hold1603 dlygate + buf_8, B rq, C off) -> 129 buffers, depth 14, 938 pins
  (baseline rst tree 198 buffers, depth 20, 906 pins). max_ss setup from rst +3.452 (baseline +3.589), from rq/off
  +5.33/+5.41; min_ff hold from rst +0.258 (baseline +0.215), thru OR +0.316. Root costs ~2.5 ns at ss (dlygate
  1.28 + or3 1.24). One tree net _06252_ (clkbuf_4) slew 0.869 ns at max_ss vs 0.75 SDC. No async pin on the tree;
  only async pins in design = wrapper's run/rst_sync[0]/rst on rst_n.
- Macro input hold min_ff +0.204 (w_data[24]) vs ff-guard 0.4 -> survives 0.85 ns real hold.
- Routability tighter: GRT usage 73.8 -> 77.9 %, overflow 703 -> 1037, DRT pass-1 violations 19.4k -> 23.3k, DRT
  15 -> 23.5 min, antenna diodes 28 -> 55. Converged clean.
- Slew: max_ss 99 SDC violators (worst 1.139 ns, net884/net889 buf_1 fanouts); sub-port had 2.154 ns on
  rf.byp[9] (beyond 1.5 ns table range). Cap: clknet_0_clk_regs 0.201 vs 0.2 (max corners).
- MPW (macro clk 7.88 vs 5) / min period (16 vs 10) / recovery +13.0 / removal +1.04 (max_ss) all MET; check_setup clean.
- TOOLING: `tt-test.sh . gates` fails on the sandbox (venv-test lacks PyYAML; val-sub-port hit it too). Use the
  gl-sub-port.sh recipe (copy pnl -> test/gate_level_netlist.v, GATES=yes make, iverilog13, venv-test).
- OpenSTA 2.7.0 in the container: report_check_types -net/-corner, report_slews, get_fanout -endpoints_only,
  pin props slew_max/slack_max/slack_min work; report_clock_skew/check_setup need sta::redirect_file_append_begin.
- Open: no gate-level test of reboot/watchdog/power-off; EQY off; IR drop not re-run (st-hgc16 1.06 %).

## 2026-10-25: EQY facts for WO-24 (sc-3x4; evidence localFiles/harden-2026-10-25/eqy-facts/, synth/)
- LVS (66-netgen-lvs/lvs_script.lvs) reads 52-openroad-fillinsertion/*.pnl.v (md5 eb402847 = final/pnl = tt_submission
  = test/gate_level_netlist.v). final/nl (md5 fbf13f22, = local copy) = 52's nl.v; nl == pnl minus VPWR/VGND
  (43,146 instances, identical types and signal pins). Nothing outside LibreLane writes netlists.
- $PDK_ROOT/sky130A -> 0536d02d (precheck PDK); harden used 8afc8346. tt lib md5 74170f90 identical in both.
  Synth reads full tt lib (428 cells), maps with trimmed runs/wokwi/tmp/e24a03....lib (192 cells; no_synth.cells +
  EXTRA_EXCLUDED_CELLS); PnR dont_use = drc_exclude.cells + EXTRA_EXCLUDED_CELLS. fill_1/fill_2/tapvpwrvgnd_1 are
  NOT in the liberty (need stubs); decap_3/diode_2 have no function.
- Container 3.0.14: yosys/eqy/sby 0.62 under /nix/store/vqq4mi8...-yosys-with-plugins-0.62-python3-3.13.9-env/bin;
  NO yices/boolector/bitwuzla/z3 (container or host) -> sby abc engines only. EQY has [recode <mod> <entity>]
  (eqy_recode.so) with "<gold> <gate>" value lines.
- Synthesis runs `fsm` unconditionally (pyosys/synthesize.py:186): exwb_memSize 2->3, muldiv_inst.st 3->6,
  qspi.state 3->7 one-hot; low gate bits keep the gold names (false name matches!).
- Flop accounting: gold 1,485 bits (proc/flatten/opt_clean) -> gate 1,307 = 1,286 direct + 5 renames (qspi_cs_n[2:0]
  -> uio_out[0,6,7]; pc[0] -> if_pc_next[0]; uart lsr[1] -> oe) + 16 FSM; 186 gone = 184 opt_dff constants (CSR WARL
  bits) + gpio out_r[5:4] unused. 0 flops merged. PnR: same Q-net set as 06, 85 flops resized.
- LibreLane Yosys.EQY sits AFTER Netgen.LVS in Classic (gate = final nl), RUN_EQY gate, PDK verilog via
  eqy.formal_pdk_proc, generic script has a bitwuzla strategy (missing in container).

## 2026-11-08: vetted variant B (SYNTH_EXCLUDED_CELL_FILE = PDK no_synth minus 89 _1 comb + plain flops), read-only
- LibreLane 3.0.14 source (container): synth excl = EXTRA_EXCLUDED_CELLS ∪ SYNTH_EXCLUDED_CELL_FILE ∪ PNR_EXCLUDED_CELL_FILE
  (pyosys.py:343-347, yosys.py:107-109). The config value REPLACES the PDK's file (single path var). OpenROAD dont_use =
  EXTRA ∪ PNR only (openroad.py:333-335 -> io.tcl set_dont_use_cells): synth list never reaches resizer/CTS/hold fix.
- PDK 8afc834 drc_exclude.cells (52 cells: _0 variants, fa_4, mux4_4, buf_16, xor3/xnor3, clkdlybuf4s15/18_1, lpflow, probe)
  has none of the 89. All 89 present in tt/ss_100C_1v60/ff_n40C_1v95 libs, LEF, CDL; no dont_use attrs.
- ss max_capacitance: mux2i_1 0.039 pF (weakest; watch), maj3_1 0.097, ha_1 0.101, fah_1 0.103, inv_1 0.115.
- ha/fah are multi-output: abc never maps them with SYNTH_ADDER_TYPE YOSYS, so freeing them is moot.
- gpl.tcl: pad per side = GPL_CELL_PADDING / 2 (integer) -> padding 2 = 1 site each side. Default density =
  util + 5*pad + 10 only when PL_TARGET_DENSITY_PCT unset (we set 65).
- 11-01 run: LAYERS_RC set (calibrated), RUN_POST_GRT_DESIGN_REPAIR/RESIZER_TIMING false, timing_repair_buffer 1650 cells
  18,559 um2; hold_buffer metric 525 = last pass only (count hold* instances).

## 2026-11-09: PD-REVIEW-55, qsd-af1c678 (qspi-stream + DDR, first negedge flops); review in localFiles/qspi-stream-ddr/PD-REVIEW-55.md
- Run ~/tt/projects/qsd-af1c678 (sub-repo b75d637 + branch src; qspi_ctrl.v md5 = af1c678), outputs ~/regr/qs/harden/out-af1c678.
  Probe ~/regr/qs/pd55/probe.tcl (9 corners, ~5 s each; sta::redirect_string_begin/end works in the 3.0.14 openroad).
- Fit: 12 tiles 3x4, std util 69.39 % (11-01 67.30), incl macro 71.28; GRT usage 72.21 % (11-01 75.79), overflow 176
  (met4 116; 11-01 104), GRT-0115 both runs; DRT 22 iters -> 0. hold* 665 instances. Slew 61 max_ss (116), cap 0 (5).
- Timing 16.0: all 9 met. Worst setup = nib_n -> uio_out[1] +0.507 max_ss = TT-SDC artefact (negedge launch vs 3.2 ns
  out-delay on clk rise). r2r max_ss +0.560 ifex_compressed -> csr_unit.raddr[0] (11-01 -0.303 d_addr->csr_new; 10-25 +0.86
  => ss r2r is noise-level). min period max_ss 15.44 ns. Hold min_ff +0.089. At tt/ff the r2r worst is cap_n->sr (half cycle).
- Negedge mapping: dfxtp_2 + private cloned inv_2 per flop (_25764__1103.._25771__1110) on normal leaves 38/40/45; fall
  edge reaches them +2.20 ns (max_ss, early) vs posedge sinks 1.97-2.83; tree passes fall ~0.5 ns faster than rise.
- DDR pins: SCK uio_out[3] (_28430_ -> buf_2) ss 3.29-4.07, tt 1.82-2.27, ff 1.23-1.54; a_dat from clk fall ss 2.96-4.04;
  |a_dat - a_sck| <= 0.92 ns (max_ss, mixed derate) -> contract 2 ns met at tile pins. SDR comb IO path 11.88 ns max_ss
  (doc EST 8.7 wrong). Macro: launched +3.67 / captured +1.05 max_ss; input hold min_ff +0.135 (ff guard lib).
- Sandbox: qsd-af1c678/core.156 = 1.6 GB openroad core from 2026-11-08 01:39 (predates this harden; step unknown).
- warnings.txt from run.sh is empty even when flow__warnings__count = 1 (extraction bug).
- Open: EQY on pnl ddb88503; GL with DDR enabled (TT cocotb tests are SDR); TT mux/pad sigma; macro real liberty.

## 2026-11-21: GO/NO-GO on macro-only hold band (rf_top guard lib 0.4 -> 0.5/0.55), q4x4-sb, read-only
- Verified 3.0.14 (venv-26d librelane): resolved PNR_CORNERS/RSZ_CORNERS None, but step 37 ResizerTimingPostCTS log
  loads all 9 corners; guard lib only at max/nom/min_ff, rf_top.lib at tt/ss. hold_args: -setup_margin 0.5 -hold_margin
  PL margin, no -allow_setup_violations. STA-1140 "library sky130_s47_lib already exists" (guard and base share the lib
  name) = cosmetic; corner map is by cell name.
- Guard lib diff vs rf_top.lib = 6 header lines + 10 values (hold_rising rise/fall on w_addr, ra_addr, rb_addr, w_data,
  w_ena). Header text says 0.4: a new file must update it (CERN-OHL-W notice).
- Post-route minus placement target at rf_top pins (vs 0.4 lib): base m0.1 -0.047, base m0.2 +0.040, bundle m0.1 -0.067.
- Verdict GO, step +0.15 (0.55): +0.1 leaves ~0.01 over the user's +0.12 bar at worst observed loss. Flow ff hold
  metrics then read vs the guard, not comparable across runs; judge with explicit 0.4 lib. Watch max_ss setup at
  rf_top pins (dlygate ~1.3 ns at ss; 3x4 captured +1.05) and GRT overflow ceiling 117. set_min_delay rejected.
- Follow-up 2026-11-21, q4x4-rcg (die 682.64 x 511.36; rf_top LEF 132.64 x 118.7; macros [3,60] E + [3,245] E):
  GRT 72.27 % / ovf 78 vs bar 71.83 / 117. 28-openroad-globalplacement: routability loop 7 iters, target density
  0.65 -> 1.033 > cap 0.99, reverted to min congestion 1.329, GPL-0089 "could not reach target" = whitespace-starved.
  Verdicts: (a) overflow threshold NO-GO (noise), (b) max_phi 1.04 GO (HPWL lever; usage is the miss), (c) vert halo 20
  NO-GO for GRT (~5k um2 rows, inter-macro gap 32 -> 12 um), (d) soft box over band NO-GO as sized. Hot band = channel
  between macro-2 top pin edge (y 378) and IO pins (y 511); suggested macro-2 location screen. Baseline must include
  the 0.55 lib (step-37 hold cells feed GRT).
- Follow-up 2026-11-21 (hd, max_ss 115 slew / 4 cap): RUN_POST_GRT_DESIGN_REPAIR = GO (experiment). Verified 3.0.14
  repair_design_postgrt.tcl: GRT -> estimate_parasitics -global_routing -> repair_design (-slew/-cap margin, max wire
  length 0 = no long-wire buffering) -> dpl -> GRT again (GRT_DESIGN_REPAIR_RUN_GRT default True). RSZ_DONT_TOUCH_RX
  `$^` = hold dlygates unprotected (resize to buf possible, unverified). Clock nets skipped -> 3 clock-root slews +
  clkbuf cap expected to remain. rf_top placeholder max_transition 0.1 (-10 % = 0.09 ns at ss) likely unreachable ->
  buffers pile at macro pin channel. MAX_FANOUT 12 rejected as the single knob (pre-route estimator, global).
- 2026-11-21 hd-r verdict (RESULTS.md "### hd-r vs hd"): GO as gate config as-is. Std-cell hold min_ff +0.034 (self-loop
  Q->inv->o22ai->D; repair unloaded the inv, no post-GRT hold repair) accepted: post-route SPEF, slack already nets out
  set_clock_uncertainty 0.25 (no -setup/-hold => applies to hold) + early derate 0.95 (seen in hold-guard-2026-10-15
  final sdc; assumed same TT template in hd-r), and self-loop => CPPR zero skew. 3x4 +0.091 was a sample, not a bar.
  RSZ_DONT_TOUCH_RX hold* NO (loop has no hold cell; blocks UART slew fixes). RUN_POST_GRT_RESIZER_TIMING not for gate
  (untested step; margin 0.1 would also hit macro pins < +0.25 vs 0.4 lib in the hot pin band); if ever, hold margin
  0.05, verify GRT_RESIZER_* keys in installed 3.0.14 first (NOT verified). Gate harden GO with RTL +400 um2 (util ~72.0 %,
  user owns > 71.6). Carried risk: cache w_data[16] 2.13 ns slew into placeholder macro (recoverable class).
- hd-r follow-up (coordinator facts): min_ff report confirms self-loops, CRPR -0.101, derate 5 %, hold unc 0.25 inside
  +0.034 => ~0.28 ns pre-uncertainty. Key names VERIFIED present in sandbox venv-26d librelane pyc (strings): GRT_RESIZER_
  {HOLD,SETUP}_SLACK_MARGIN, ALLOW_SETUP_VIOS, FIX_HOLD_FIRST, RUN_GRT, HOLD_MAX_BUFFER_PCT, HOLD_MAX_UTIL_PCT,
  HOLD_REPAIR_TNS_PCT, SETUP_BUFFERING, SETUP_GATE_CLONING, SETUP_MAX_UTIL_PCT, GATE_CLONING; RUN_POST_GRT_RESIZER_TIMING
  help text: "experimental and may result in hangs and/or extended run times". No skip-setup key seen. Defaults NOT read
  (pyc only; venv has no bin/python). Gate scope now WO-68 + WO-69 (~+25 flops, +1.5k um2) -> util 72.3-72.5 %; user:
  fine if IR drop + all past checks pass. My call: gate = hd-r config unchanged; optional parallel arm B (same RTL)
  RUN_POST_GRT_RESIZER_TIMING true + GRT_RESIZER_HOLD_SLACK_MARGIN 0.05, adopt only if overflow <= A and all checks >= A.

## 2026-11-22: Track B (3rd rf_top, 2nd I-cache way) placement desk review, hd-r DEF (scratchpad fp3/), read-only
- MEASURED (hd-r DEF): core x 2.76-679.88 (rows 1472 x 0.46); met4 straps full height 2.48-508.88, NOT cut over macros:
  VPWR x = 19.08 + 38.87k, VGND +3.3. Tracks: met2 X 0.23/0.46, met1 X 0.17/0.34. rf_top power pins = met3, vertical in N
  (N x 5-8, 14-22, 110-125) -> only E/W/FE/FW get via3 to met4 straps; N/S/FN/FS = unpowered macro.
- MEASURED: hold cells in direct series with macro inputs: core RF 22 (0.5/pin), data_mem 64 (1.3/pin); 1045 dlygate4sd3_1
  total (3.68x2.72 = 10.0 um2) are mostly NOT at macro pins (lower bound: upstream hold cells not traced).
- Pin phase: x - 3.00 = n*7.82 (lcm 0.46/0.34) keeps the proven pin-to-track geometry; 128.12 = 3 + 16*7.82.
- Advice: A = [128.12,245] E first, B = [128.12,60] E, D = [558.22,245] W control. Stub RTL with real 2nd tag bank +
  compare (not a tied dummy). PL_TARGET_DENSITY_PCT 65 likely below placeable density (~70 %) -> must change, same in all arms.
  LVS likely cannot catch a missing macro PDN connection (pnl from same odb): check via3 over new macro + PDN/PSM logs.
- Estimates (inferred, not measured): util ~78.3 %, GRT A 74-76 / B 75-77 / D 76-79 %, met1 83 -> 86-89 %.

## 2026-11-22: gA DRT failure (q4x4-gA runs/wokwi-run1-drtfail vs q4x4-hdr), screen GO, read-only
- MEASURED: DRT input = step-41 re-GRT (RUN_POST_GRT_DESIGN_REPAIR): gA 1391 -> 4135 ovf, 78.24 %, WL 1.49M, DPL max 209.6 um
  (hd-r 103 -> 123, 117 um). Step 39 (1418 vs 104) is NOT what DRT saw. Guides 200,986 vs 178,499.
- Cascade: GPL-1005 1.3577 vs 1.3209 (+3 %); legal HPWL delta grows 34: +2.7 %, 35: +3.4, 37: +5.6, 41: +8.4 %.
  Step-37 DPL total 44.0k/max 169 um vs 25.5k/108 (hold 975 vs 1083 bufs: fewer, but no local room).
- Inter-macro channel cell density (40 um bins, x0-120 y200-240, step 34): gA 55-65 % vs hd-r 33-45 %. Top-left y440 row
  after 41: 88-98 % vs 77-91 %. rf_top pins: N-left = inputs (48) -> E top edge; N-right = outputs (65) -> E bottom edge.
  So channel = RF inputs + data_mem outputs. LEF OBS li1-met3 only (met4 free over macro).
- GPL facts (3.0.14 / OR 2026-02-17): single-threaded (process_stats threads 1). Snapshot at ovf ~0.6, check 0.3 default
  (fires at 0.2981). Inflation budget = whitespace - movable area, independent of PL_TARGET_DENSITY_PCT (GPL-0079 math);
  cap ~1.0 (routability_max_density not exposed in gpl.tcl). Target < uniform -> "too low ... Automatically adjusting to
  uniform density" (binary string; uniform gA 0.6432). GRT-0022 global adjustment 30 % in effect.
- 4x4 history (~/regr/q4x4/reports/*/grt.txt): same netlist rcg 78 / rcgb (lib only) 255 / FW 198,189 / W 1342 / FE 3341 /
  rcgbA 143 vs AFW 2450; rcgbP (PL_MAX_PHI 1.04, my 11-21 GO) = 11,057 -> max_phi is NO. sbh (hold margin 0.2) 482 -> DRT
  plateau ~4200 killed. DRT iter3/iter4: hd 2807/536, hd-r 2465/381 OK; sbh 6554/4740 fail.
- Screen GO (ranked): 1 rf_macro [3,49.12]; 2 rf [3,49.12]+data_mem [3,234.12]; 3 PL_ROUTABILITY_OVERFLOW_THRESHOLD 0.2;
  4 data_mem [10.82,245]. NO: density 60/62/68, timing-driven, soft obs, GRT_LAYER_ADJUSTMENTS. Bars: step-39 ovf <=200,
  met1+met2 <=60, maxH/V <=6, step-37 DPL <=32k/130 um; FULL kill: step-41 ovf >300 or DPL max >150; DRT it3 >4000 / it4 >1000.
  Outcome: PENDING (not run by me).
- ROUND 1 RESULT (coordinator, ~/regr/q4x4/gas-summary-round1.txt): ALL 4 of my arms WORSE than gA (r49 6567, r49c234 5094,
  ot02 11235, c1082 6506; DPL37 64-97k). My channel-width mechanism was wrong. Lesson: on this knife edge my arm predictions
  had no skill; say so up front next time.
- Step 35->37 displacement map (scratchpad gA/disp.py): TL corner x0-80 y400-511 hd-r 1.8k, gA 9.3k, r49 27k um with the
  SAME ~80 new cells there -> corner full before hold fix. Macro-input hold chains: hd-r 36+72, gA 27+61 (not the cause).
  Coordinator: hot regions gain ordinary logic (TL +120 cells, channel +114 = more than the whole +160 delta).
- hd-r synth nl.v md5 5a15041d (gA 5bc49777); written netlist has 0 src/line refs. 8x2 template 1378.16 x 225.76, pins
  x 30.82-146.74 top edge (same as 4x4). PDN halos are PDN_*_HALO (10), separate from FP_MACRO_*_HALO (tapcell/cut_rows).
- Round 2 advice: RF W at [3,60] (inputs out of channel; history: data_mem inputs-to-channel W 1342/FE 3341 vs E 78-255),
  data_mem [128.12,245] E, RTL attribution gate-minus-WO-68 / gate-minus-WO-69. Told coordinator: no config lever I'd
  expect to reliably reach DRT 0 -> escalate to user in parallel. Fallback hd-r needs md5-identical synth netlist.

## 2026-11-22: gA round-3 screen arms (c128 floorplan), read-only; file scratchpad q4x4/gas-arms-r3.draft.txt
- Round 2 MEASURED (gas-summary-round2.txt): c128 1144 (best gA draw), rW 3677, no68 5200, no69 6552. gA family 0/9 draws <1000.
- VERIFIED 3.0.14 (venv-26d .py): AREA 3 abc script = strash;dch;map -B 0.9;topo;stime -c;buffer -c -N MAX_FANOUT;upsize -c;dnsize -c.
  SYNTH_ABC_USE_MFS3 / AREA_USE_NF / LEGACY_REFACTOR/REWRITE / ABC_BUFFERING / SIZING act ONLY in the generic branch
  (AREA 0/1/2, DELAY 0-3) -> no-ops with AREA 3 (a bit-identical wasted draw). MAX_FANOUT_CONSTRAINT feeds ABC buffer -N in AREA 3.
  SYNTH_AUTONAME runs after stat, before write_verilog -> same cells/area, new names (ODB child order is by name).
  Seeds: none exposed (GPL/DPL/GRT/ABC); DRT -or_seed 42 hard-coded in drt.tcl. PL_WIRE_LENGTH_COEF 0.25, PL_SKIP_INITIAL_PLACEMENT
  false, PL_ROUTABILITY_DRIVEN true, PL_ROUTABILITY_OVERFLOW_THRESHOLD Optional (unset). Step 09 checks assign statements.
- MEASURED step 37: setup repair is tiny (c128 66 endpts, init WNS -1.019 at uio_out[2], +0.1 % area; hd-r 4, -0.317 uio_out[4]);
  hold repair +4.2 % (c128) / +4.7 % (hd-r) area. Step-38 STA = nom_tt only (WS +2.26 / +2.15).
- INFERRED: AREA 0 vs AREA 3 = -0.8 t (-7 %) post-PnR std area on 4d21e43 (wo27acc2 rf_top/README.md table), ss WNS 1.7 ns worse then.
- Arms ranked: a2, a0 (area lever), wl20, sip (same synth netlist), f16, auto (autoname), a2m3, ot04. No skill claimed on seed arms.
- Gotcha: a literal backslash-u0020 typed into a Bash heredoc arrives as a space; write it with chr(92) in python.
- Follow-up (same day): relocation arms on the peer's "macro under the pin corner" idea; draft2 = a2, rmid, a0, dbot, dmid, wl20, sip, dright
  (f16/auto/a2m3/ot04 held for round 4). Coordinates: rmid RF [284.52,60] + DM c128; dbot DM [284.52,60]; dmid DM [284.52,245];
  dright DM [558.22,245]; all E, x-3 = n*7.82, each crosses 3 VPWR + 3 VGND met4 straps (verified by script).
- MEASURED rf_top LEF: signal pins met2 only on the two N vertical edges (inputs 49 incl clk; outputs 64 at N x=132.5, y 25.5-116.5);
  power met3 stripes full N height -> full E width. E: inputs top / outputs bottom (per 11-22 notes), pins span the full 118.7 edge.
- MEASURED hd-r signoff max_ss (56-openroad-stapostpnr/max_ss_100C_1v60/max.rpt): r2r worst +1.79 ns; uio_out[1] +0.237 (IO artefact);
  paths INTO data_mem worst +4.18, into RF +3.47; from-macro paths not in the 1003-path report at ss (tt: from DM +7.37, RF +7.58).
  => setup headroom at macro pins ~3.5 ns; a 150-450 um relocation (~0.3-1 ns) is affordable. Placeholder rf_top.lib caveat.
- Evidence note: c1082 (7.82 um nudge) 6506 vs c128 1144 => draw noise dominates; c128 is NOT evidence for "further is better";
  hd-r routed 104 with DM at [3,245], so the corner spot is not intrinsically unroutable.

## 2026-11-23: CLOCK_PERIOD as a routability lever (user may drop to 50-55 MHz), read-only; file scratchpad q4x4/gas-arms-clk.draft.txt
- VERIFIED 3.0.14: CLOCK_PERIOD used only in scripts/base.sdc (create_clock; IO in/out delay = period * IO_DELAY_CONSTRAINT/100, =20)
  and pyosys (abc -D <ps>). ABC runs "read_constr <driving cell/load sdc>; source AREA_3.abc" (06 log l.6495-6498); script has no {D},
  ABCScriptCreator.D is stored but unused -> period does not reach ABC. gpl.tcl not timing-driven (PL_TIMING_DRIVEN false);
  repair_design.tcl -buffer_gain only if DESIGN_REPAIR_BUFFER_GAIN set (unset); cts.tcl no period target. => steps 06-35 period-independent
  (inferred from code; pg20 control would prove it by md5). c128/hd-r resolved: PNR/SIGNOFF_SDC None, IO_DELAY 20, unc 0.25, trans 0.15, derate 5.
- MEASURED std-area build-up (state_out design__instance__area__stdcell), c128: synth 170,169 -> taps 175,631 (+5.5k) -> step 32
  repair_design 195,899 (+20.3k; 1452 bufs/740 resizes for 1298 slew, 289 cap, 16 fanout viol) -> CTS 205,120 (+9.2k) -> step 37
  214,906 (+9.8k: setup ~0.1 % = ~0.2k, rest hold). hd-r: 168,930 / 174,462 / 193,728 / 202,478 / 213,276. Setup repair < 0.5 % of PnR adds.
- Verdict: period is not a routability lever unless step-37 setup repair is heavy (A0-core or AREA 0/2 netlists). A 16-ns-closed netlist
  also closes at 18.18/20 (all SDC terms scale up; IO hold min delays grow). If an RTL recal (constants) lands, the netlist changes -> new draws.

## 2026-11-23: AREA 2 (gAsa2) timing + N-B-core floorplan, read-only
- MEASURED a2 (q4x4-gAsa2): step-37 setup repair @16 ns iter0 WNS -10.708 (805 eps) -> final -3.729 (647, RSZ-0062), +1.3 % area,
  678 upsized/143 bufs; stall endpoint _23741_ = br_r. Replay @20 (librelane --only, new run) iter0 -6.708 = exactly +4.000 ->
  steps 06-36 period-independent CONFIRMED. hold* cells at step 37: a2 1165, a0 1116, c128 968 (hold_buffer metric 21 = last pass).
- MEASURED pre-PnR (step 12) nom_ss WNS: a2 -13.70 (1427 viol), a0 -11.41, AREA 3 c128/rmid +3.20; nom_tt a2 -1.59. Worst a2 path =
  unbuffered inv_2 fanout 844 (12 ns) then or4b chains 1.4-1.5 ns/stage. Synth cells a2 12,984 (9 bufs, or4* 175) vs c128 19,149 (601 bufs, or4* 81).
- br_r path (probe, after repair): rf_top clk->q 4.2 (placeholder) + mux/and/a211o/xnor + 12 serial or4/or3/and4 (_4) ~10.7 ns; wires ~0.7.
  = cmp_lts/ltu carry (alu sub_res) -> ex_branch_valid. Logic depth from amap; resizer cannot restructure.
- VERIFIED 3.0.14 generate_abc_script bytecode (local dis of venv-26d pyc, python 3.12.4): generic = fx; mfs; strash; drf -l;
  [AREA 2: choice2 | else resyn2]; retime; scleanup; [AREA4/DELAY 2: choice | !=DELAY 0: choice2]; [AREA*/DELAY 3: amap | else
  map -p -B 0.2 -A 0.9 -M 0]; recovery AREA 1/2 choice2+amap, DELAY 1 choice2+map, DELAY 2 choice+map, DELAY 3 choice2+map_old_dly;
  retime; &get -n;&st;&dch;&nf;&put; fine_tune (only SYNTH_ABC_BUFFERING/SIZING). DELAY 4 = ORFS &syn2/&if -g x5 + buffer/upsize/dnsize.
- Advice: N-B-core nb1 DM [128.12,245] E + data_hi [261.06,245] E (33*7.82; gap 14.24 inside 10 um halos); nb2 data_hi [3,245] E.
  FULL rule: shortest period with no RSZ-0062 and probe max_ss >= +0.5; predicted 18.18 ~-1.1 NO, 20 ~+0.7. Q3 arms DELAY 1, DELAY 0
  (unmeasured). FP_MACRO/PDN halos 10/10, RUN_POST_GRT_RESIZER_TIMING false in a2.

## 2026-11-23 ~05:00: N-B-core (nb1/nb2) collapse root cause + per-module ABC question, read-only
- MEASURED (step logs): placement is NOT the problem. Step-34 legal HPWL nb2 690.8k / nb1 770.2k / a2 693.7k / hd-r 755.3k;
  step-37 pre-DPL 728.8k / 843.8k / 726.7k / 784.5k; step-37 DPL delta HPWL +33 % / +28 % / +4 % / +5 % (disp 149.8k/162k/19.2k/25.5k).
  GRT WL nb2 1.86M, nb1 1.67M vs a2 1.20M, hd-r 1.31M. => collapse = step-37 legalization of the adds, not wire demand.
- MEASURED util (state_out): step-35 std util nb2 64.2 %, a2 57.8 %, hd-r 65.1 %; step-37 add nb2 +18.5k um2, a2 +14.3k, hd-r +10.8k.
  "util 74.5 %" = step-37 total incl. 3 macros (47.2k um2 vs 31.5k for 2). GPL nb2 target raised 0.65 -> 0.6647 (GPL-0079).
- MEASURED nb setup @16: nb2 -11.03 -> -3.529 (1289 up/248 buf, RSZ-0062), nb1 -16.34 -> -4.981. a2 @20 replay: 468 up/109 buf,
  DPL 17.1k, +0.271 RSZ-0062. Hold worst endpoint = RESET_B (removal) in nb1/nb2/a2.
- tb3 (density 75) was prepared (~/regr/q4x4/tb3-mk.sh) but NEVER RUN: no data at 75. My 11-22 premise ("65 below placeable") does
  not hold for nb (GPL std util 0.53 at step 28).
- VERIFIED 3.0.14 synthesize.py: one `abc -script <SYNTH_STRATEGY> -D period` call for the whole design; SYNTH_KEEP_HIERARCHY_MODULES/
  INSTANCES/MIN_COST only keep module boundaries (same script per module). SYNTH_EXTRA_MAPPING_FILE runs after synth techmap
  ($alu already gates). Liberty cell instances are opaque to abc. GPL_CELL_PADDING = gpl -pad_left/right PAD/2 sites;
  DPL_CELL_PADDING separate (common/dpl_cell_pad.tcl).
- RTL fact (3f43aa4 src/branchCtrl.v): eq = (sub33[31:0]==0) -> BEQ/BNE also wait for the full ripple sum; lt = sub33[32].
- Advice: drop N-B-core now (no GO period >=50 MHz: setup like a2; routing collapse). Revisit only after a branch-compare RTL fix;
  then one arm nb2 + GPL_CELL_PADDING 2 (user parked padding 2 on 11-09 -> needs user OK). Density 70-78 = NO (wrong direction).
  Q2: best = RTL explicit prefix compare with (* keep *) on level wires + eq = (r1 == r2); 2nd = scripted pre-mapped netlist.

## 2026-11-23: DRAW FARM grid (A0-core, p67f on hd-r floorplan), read-only
- VERIFIED 3.0.14: PL_WIRE_LENGTH_COEF / PL_SKIP_INITIAL_PLACEMENT / PL_MIN_PHI_COEFFICIENT / PL_ROUTABILITY_OVERFLOW_THRESHOLD appear
  only in gpl.tcl (+ openroad.py defs) -> placement-only. PL_OPTIMIZE_MIRRORING only dpl.tcl (GPL shared with base -> weak draw, skipped).
  MAX_FANOUT_CONSTRAINT = ABC buffer -N AND base.sdc set_max_fanout (repair_design + sign-off fanout check): <=20 only (stricter).
  SYNTH_AUTONAME = names only, but names drive ODB order -> new GPL draw; long names flow to DEF/SPEF/LVS/EQY (untested here).
- MEASURED predictor: step-28 GPL-1012 inflation vs step-39 ovf (AREA 3, ~72-73 % util): hd-r 21.5 %->104, a2 19.5->1; c128 33.6->1144,
  gA 33.7->1418, cbase 34.6->1604, cw20 37.3->4667, p6base 43.5->4777, r49/no68/no69/c1082 42-46 -> 5-6.6k; a0 31.4->153 (util 66.5).
  Exceptions: dbot 0 % (no routability mode) 6388; nb2 17.2 % (util 74.5) 36078. Suggested early kill: >30 % or 0 % (inferred, n~22).
  Pending at 11-23 ~06: hsip 12.1 %, cauto 23.5, cf16 25.1 (predict pass-ish); hw20/hf16 33.0, csip 35.0, hauto 52.1, p67base 48.2,
  p67fbase 46.1 (predict thousands). Check these predictions when step 39 lands.
- Grid given (lines 1-4 = earlier GO): w20, sip, f16, auto, wl15, wl30, phi97 (min_phi 0.97), ot35, auto+sip, auto+wl20, f18, f16+auto.
- Trust: farm draw = same exhaustive sign-off; caveats = reproducibility from committed config (CI vs sandbox unverified, applies to A0 too),
  fragility to ANY input change incl. source ORDER, A0's path-specific acceptances (+0.034 self-loop hold, w_data slew) do not transfer.

## 2026-11-23: draw-farm EXTENSION (A0-core, FANOUT/AUTONAME axes), read-only
- MEASURED (sandbox resolved.json): q4x4-hdr MAX_FANOUT_CONSTRAINT 20, AUTONAME false, WL 0.25, PHI/OVF null -> FANOUT20 = base,
  FANOUT20+AUTONAME = ka04 (no-ops). PL_WIRE_LENGTH_COEF -> gpl -init_wirelength_coef; OVF/PHI flags only passed when set
  (ka07/ka08 logs). GPL snapshot iter 319 in both ka07/ka08 (snapshot overflow fixed, not the check threshold - recalled).
  OpenROAD default routability_check_overflow 0.3 = RECALLED, unverified.
- Results given (step-28 inflation): netlist re-rolls F16 25.1, AUTO 23.46, F18 24.07, F16+AUTO 37.8 (3/4 <30);
  placement-knob variants 0/8 <30 (base 34.58 cluster 32.9-37.3; AUTO+SKIP 47.2, AUTO+WL0.2 36.8 = worse than AUTO alone).
  Inflation <30 is not sufficient: F16 -> GRT 642. INFERRED: netlist/order is the dice; no skill on any axis.
- Extension GO list (ka13-ka22): F17, F19, F17+A, F18+A, F19+A, F15, F15+A (netlist re-rolls), then fillers F18+WL0.3, A+WL0.3,
  F18+SKIP. Dropped: F20, F20+A, AUTO+OVF (ot35 worst on base, default unverified), PHI. Duplicate guard: step-06 nl.v md5.

## 2026-11-23 ~09:00: corepb (A0-core + PBURST, b898869) floorplan arms, read-only; scripts scratchpad pbs/ (defan.py, an3-5.py)
- MEASURED (step-37 DEFs hd-r, ka11, cauto): the pin pocket (x<131, y 388-509; closed by die edge, data_mem below (OBS met1-3), pins
  above, open only east + met4) holds the I-cache TAG ARRAY in all 3 draws: 152/152 tag+valid flops there (med x 59-70, y 457-468),
  ~1600 icache cells. cauto pocket nets: 4280 conns internal vs ~200 external (self-contained). data_mem w_data driven by hold15*
  at x 89-171 y 299-392 (east of the pocket); ra/rb_data loads in the channel y 218-267. Pocket guides vs outside (20 um bins):
  met1 ~300 vs 240, met2 ~170 vs 125, met3 ~90 vs 35 (horizontal exit flow), met4 ~30 vs 8.
- MEASURED farm: GPL passers (<30 %) corepb 1010/1510/1551/2055/2174 vs A0-core 60/139/397/433/642 -> disjoint (p~0.004):
  corepb systematically harder on hd-r. corepb: usage +4 pts, WL +5.5 %, topleft guides 15.2-15.8k vs 12.0k, for +1.1 % synth area.
- CORRECTION of 11-22 note: FE keeps inputs on TOP (FE = MYR90 = E mirrored in x); only W/FW put inputs on the bottom.
  rf_top N pins: inputs left edge (rb/ra/w_addr y 1-21, w_ena 21, w_data 26-116), outputs + clk right edge (clk y 3.25).
  E: inputs top (addr x_rel 1-21, w_data 26-116), outputs bottom, clk bottom-left. History rcg: E 78/255, FW 198/189, W 1342, FE 3341.
- VERIFIED 3.0.14 (~/tt/r/venv-26d py3.13 = same tree as nix run): PL_SOFT_OBSTRUCTIONS / FP_OBSTRUCTIONS = list of [llx,lly,urx,ury] um
  (floorplan.tcl: dbBlockage_create, soft via setSoft, after initialize_floorplan); ROUTING_OBSTRUCTIONS/PDN_OBSTRUCTIONS in odb.py;
  no GRT blockage key; Instance = location+orientation only (no per-instance halo); MAGIC_DEF_NO_BLOCKAGES default true (-noblockage).
  UNVERIFIED: GPL honours soft blockage (doc says initial placer does), cut_rows ignoring blockages. gas-mk accepts new top-level keys.
- Arms given: 1 pc128 DM [128.12,245]; 2 pbot DM [3,60] + RF [167.22,60] (21*7.82, gap 45.5 um, 3+3 straps); 3 psoft
  PL_SOFT_OBSTRUCTIONS [[2.76,395,122,470]]. NO: FE, FW/W, swap, dright/dmid, FP_OBSTRUCTIONS, halo. Ovf skill: none claimed.
  Outcome: PENDING.

## 2026-11-24: region/group/fence feasibility for PBURST pocket (read-only, sandbox source of librelane 3.0.14)
- VERIFIED: no region/group/fence config var in librelane 3.0.14 (grep of steps/flows/scripts: only IO_EXCLUDE_PIN_REGION).
  Spatial placement vars = PL_SOFT_OBSTRUCTIONS (openroad.py:1133) only. meta.substituting_steps (config.py:173,
  __main__.py:98-106) maps step IDs to registered step IDs/None only -> custom step needs a plugin (TT = none).
- Only user-TCL hook before GPL: PDN_CFG (openroad.py:1466, GeneratePDN step 21, read_pdn_cfg in pdn.tcl:21, write_views
  persists ODB); GPL = steps 24/28. Abusing it for regions = hack, also replaces TT default PDN (would need to source default).
- MANUAL_GLOBAL_PLACEMENTS (odb.py:1001-1035, placers.py:127-160): per-instance exact name -> x,y,orient, PLACED, step 33
  (after GPL 28, before DPL). Moves named cells only, no re-GPL afterwards -> not a region; comb logic stays.
- VERIFIED in ghcr.io/librelane/librelane:3.0.14 (OpenROAD dcf36133): commands create_voltage_domain, create_power_domain,
  odb::dbRegion_create, odb::dbGroup_create exist. UNVERIFIED: GPL honouring plain dbGroups (from memory: gpl makes extra
  PlacerBase only for groups of power domains); DPL (opendp) fence-region support. ELF strings grep failed (binary not found).
- Opinion given: (2) relocates a self-contained cluster (4280 int vs ~200 ext conns) -> likely moves overflow like psoft.

## 2026-11-24: die-density analysis + 8x2 question (read-only; sandbox ~/regr/q4x4/density/, scripts dens.py, fp8x2.py; local copy scratchpad dens/)
- METHOD: step-37 DEF (== step-39 placement, checked per instance), after_grt.guide edge crossings per 20.7 um bin (=3 gcells of 6.9 um);
  guide demand sums to 100-102 % of the GRT log demand per layer (MEASURED validation). Capacity per bin = log resource spread over non-macro
  bins (met4 open) -> per-bin usage INFERRED. Module = net-name vote (an5.py method). Runtime ~1 min/design in a normal slot.
- MEASURED hd-r/ka11: util 71.4/73.3 %, GRT 69.9 % (met1 83 / met2 77.5). RF+DM+IO nets = 2.0 % of guide WL. Mid-die vertical cut x=331:
  H demand 1031/1075 of ~1156 tracks; macro column cut x=82: 695/556 (125 %). Pocket (x<160, y>377.6): dens 90.5/92.9 % (excl buf 75/78),
  icache 87-90 % of area, hold 9.8 % of rows (3.3x die), ~80 % of pocket hold cells end in icache comb logic, 33/23 at DM inputs.
  Channel met1 97/100 %. Overflow at macro east corners. Whitespace <40 %: 15/11 of 825 bins, core_left under RF buses, GRT use 0.83 vs 0.66.
  RF.w_data mean HPWL 228 (longest macro bus, rf.dIn up to 514 um). UART sits at the top-right corner.
- 8x2 (MEASURED from tools 01d5d28 + tts-main 0922544): 1378.16 x 225.76, core 302,420 vs 342,569 (-11.7 %), pins x 30.82-146.74 north,
  PDN met4 pitch 38.87 w 1.6 off 16.32, TOP/BOTTOM margin 1 row, L/R 6 sites. Verdict NO (util ~81-83 %, vertical cut 220 vs 506 um ->
  ~503 H tracks vs ~1000-1075 bisection demand, macro = 60 % of core height). Cost per shape: not in tools (unknown).
  One-arm screen s8a offered: tiles 8x2, DM [175.04,46.4] E, RF [448.74,46.4] E. Prediction: fail (no skill on the number).
- pbbase2 MEASURED (step 39 ovf 1551: m1 283/m2 498/m3 425/m4 345): pocket usage 98/100/99/87 % m1-4, dens 95 % (79 excl buf), hold 11.1 % rows,
  pocket guide WL 85.6k vs hd-r 58.6k; crossing nets 354 vs 225; icache->icache[core_left] bundle 82 nets/23.9k um vs 36/6.0k (PBURST nxt[*]).
  2nd hotspot = UART packed in the top-right die corner (excess ~70 edges/bin). Delivered README in ~/regr/q4x4/density/.
- 256B BUDGET (11-24 ~01:00, README "256B budget"): anchor hd-r std 213,276 / rows 302,282 = 70.6 % (routes); 72.7-73 % (ka11/cauto/pbbase2)
  all died (step 39 or 41). 3rd macro removes 19-21k um2 rows -> budget std(step39) <= ~199k = util <= ~72.0 % incl 3 macros (47,234).
  N-B AREA 2 (M) 207.9k -> -9k (synth <= ~144.7k); AREA 3 (I, x1.108 from gA a2->c128) ~230k -> -31k. User slim (PWM 5.2-5.5k,
  pinmux 0.6-0.8k total) ~ -1..-2.5k (I). Measured relocations out of the column: rmid 3091, dmid 3810, dbot 6388 vs c128 1144; dright never run.
  Pick nb3 (I): DM [3,245] E, data_hi [3,60] E, RF [558.22,190.56] E (3+3 straps). Static H-cut 102 % vs 113-128 % interior. Farming only
  when the family median is <= ~1000; AREA 3 not applicable to N-B unless ~-25k synth; AREA 2 needs <= ~50 MHz (nb @16 ns -3.5/-5.0).
- DRT convergence read (11-24): it3 -> it4 ratio is the discriminator. Pass: hd 2807->536 (0.19), hd-r 2465->381 (0.15) -> hd-r 216/33/6/6/0 (it9).
  Fail: sbh 6554->4740 (0.72), plateau ~4200. Fcauto2 it3 5689 (killed), mix = hd-r's (met1 short+spacing 75 %), 2.3x volume; Fka11b it3 7923.
  DRT log has no violation locations mid-run (markers only at the end; drt-run-0 empty). Kill rule given: it4 > ~2500 or ratio > 0.45 = kill;
  it4 <= ~1000 = likely converges; then require >= 2x drop per iteration, it6 <= ~150, it8 <= ~30.
- 11-24 Fcauto3 (A0-core+AUTONAME, routed DRT 0, exit 1 on ff hold) MEASURED: only hold viol = soc.bus.mem_rdata[29] -> hold2467 (dlygate, 0.393)
  -> hold1516 (clkbuf_1, 0.091) -> data_mem/w_data[29], -0.042 vs 055 guard. hold1516 was dlygate4sd3_1 at step 37, clkbuf_1 after step 41
  (RepairDesignPostGRT: 147 slew/28 cap, 37 resized, 101 bufs; hold* non-dlygate 18 -> 24). RUN_POST_GRT_RESIZER_TIMING False -> GRT_RESIZER_*
  are DEAD knobs (no step). RSZ_DONT_TOUCH_RX matches NETS only (resizer.tcl, unanchored Tcl regexp) -> cannot protect hold instances.
  Classic order: RepairAntennas -> ResizerTimingPostGRT -> STAMidPNR -> DRT. SPEF min_ff hold <0.05: 2, <0.10: 51. max_ss@16 worst r2r
  audio_inst.addr[2] -> icache.tags[56] -0.123, IO uio_out[2]. Advice: Fcauto4 = RUN_POST_GRT_RESIZER_TIMING true, margin 0.05 kept (GO conditional);
  alt RUN_POST_GRT_DESIGN_REPAIR false (step39 ovf 131 vs step41 348). 0.5 rule = max_ss r2r >= +0.5 at sign-off period -> 16.667 needed (I ~+0.54).
- 11-24 Fcauto4 (= Fcauto3 + RUN_POST_GRT_RESIZER_TIMING true) MEASURED max_ss slew: 92 pins/~42 nets (Fcauto3 55/~29, hd-r 64/~30);
  macro pins constant 34-36 (placeholder-lib class); delta = UART std pins (10 -> 31) on 2 buf_1-driven nets with antenna diodes:
  cti_cnt[7] D 2.31 ns, rx_mem[6][3] D 1.64 ns (> 1.5 table edge), setup +1.94 / +3.71 at max_ss, hold not in min_ff top-1003.
  data_mem/w_data[0] 1.72 (hd-r had w_data[16] 2.13). Cap: same 2 UART nets + 4 clkbuf_2_x roots 0.20-0.22 (hd-r class).
  buf_1 existed at step 41; step 44 removed 1 / inserted 7 bufs / upsized 39; DRT is a new draw. Verdict: not a blocker (recoverable,
  documented); r2r +0.511 @16 meets the 0.5 rule by 11 ps -> 62.5 MHz permissible, 60 MHz fallback; user decides.
- 11-25 256B slim screens (93a5e4c, peer est. -17k synth vs nb1 151.2k): advised AREA 2 arms at CLOCK_PERIOD 20.0 (a2b A0 probe -2.69@16
  +4.0 -0.46 RC ~ +0.85; 19.2 ~ +0.05 fails 0.5 rule); nb1 arm YES (measured better than nb2 on same netlist, 23.7k vs 36.1k; drop nb2 first);
  Fcauto4 config PDN_MACRO_CONNECTIONS lacks data_hi -> must append. Budget est (I): AREA 2 ~184.5k std (inside 199k), AREA 3 ~204.6k (over).
- 11-25 s2n3 (93a5e4c AREA 2 @20, nb3 floorplan; dens.py -> density/s2n3_*) MEASURED: GRT 577 (m4 284); met4 over RF only 10 % use;
  met4/met2 excess = zone west of RF (x 455-560, y 170-300) + band y~185 (x 120-560) + data_hi/DM channel (x 60-130, y 190-245, biggest).
  I-cache data macro nets 177, WL 45.3k (5.6 % vs 0.7 % hd-r); pocket now gpio/gamepad/pwm (62 %), icache moved to leftcol.
  Advice: re-rolls GO = AUTONAME false, PL_TARGET_DENSITY 63/67, WL coef 0.2/0.3, F16/F18 (weak: GPL step 28 precedes repair_design 32);
  NO = FANOUT 22/24 (loosens sign-off fanout check), CLOCK 20.2/20.5 (< user 50 MHz floor), padding/ot. No floorplan variant (W keeps
  pin edges N/S; N/S/FN/FS unpowered). Timing flag: step-37 +0.481 minus ~0.46 RC optimism ~ 0 at 20 ns -> 0.5 rule at risk. gplgate: stay ungated.

## 2026-11-25: adversarial slice F (ship state), report localFiles/wo-4x4/reviews/adv-tip-2026-11-25/F-pd-ship.md, read-only
- VERIFIED tt-gds-action@ttsky26d action.yml (gh api): tools-ref default `main` (moving), LibreLane 3.0.14 for sky130A, harden dockerized;
  custom_gds sub-action exists. tools compare 01d5d281...main: no sky130/harden-path change (ihp/gf/docs/precheck only).
- NEW precheck on tools main since 11-23: cf6f10e4 cell-name charset [A-Za-z0-9_$-], 7d2d2ef5 nwell_lvtn.drc (lvtn enclosed by nwell).
  rf_top.gds.gz: 16 lvtn shapes (rf_wldrv 15, rf_adec_dyn 1), 24 cell names all legal. Never run on Fcauto4 nor the 3x4 -> P0 check.
- Fcauto4 MEASURED: flow 16 ns max_ss setup ws +0.2321 / r2r +0.5108, hold min_ff +0.0752 (self-loop ex_pc_hi[18]), non-self +0.079,
  macro 0.4-lib +0.229; 16.129: r2r +0.640, uio_out[2] +0.271 (IO WNS), uio_out[1] +0.341 - both negedge half-cycle (dT/2-0.2dT).
  Runtime 3h01 (DRT 1h41, post-GRT RSZ 36 min, post-GRT repair 25 min), DRT peak 3.5 GB, 22 iters (stuck at 2 for it16-21). 3x4 CI gds 52 min.
- ~/regr/fin/sta-period.tcl loads rf_top.ff-hold-guard.lib (0.4) at ff, not 055; SUMMARY setup/hold = worst_slack_cmd (clips at 0, useless).
- Port tree config df5e1856 (commented) == Fcauto4 config 7c5a4194 semantically (36 keys, 0 diffs); job-port62 synth used df5e1856 -> f9a38b45.
- SELF-CORRECTION: my s2n3 "~0 at 20 ns" subtracted the probe37 offset from LibreLane's own step-37 WNS - wrong; area-agent ~+0.6/+0.9 [I].
- TT firmware clock_project_PWM chooses RP sys clock for integer divide (cap 133 MHz) and warns if inexact -> 62 MHz likely 124/2 [I, unmeasured].
- 11-25 Fs2n2 (256B AREA 2 @20, nb2; routed, rc=1 on min_ff hold into data_mem) MEASURED: step 44 @ GRT margin 0.05 saw 4 hold eps
  (worst -0.089 RF w_addr[0]), inserted 1 hold buf (hold3918 = buf_4, NEW at 44) -> GRT-est final +0.051; post-route SPEF ex_pc_hi[2] ->
  data_mem/ra_addr[0] -0.0325 through that very hold3918 => GRT-est optimism >= 0.083 ns (lower bound). Path 2 mem_rdata[23] -> hold2685
  dlygate -> max_cap2391 buf_8 -> w_data[23] -0.0096. SPEF min_ff <0: 2, <0.05: 13, <0.10: 99, <0.15: 587. Step-44 setup RSZ-0062 (311 eps,
  103 up, 28 removed, 33 inserted). No per-pin margin knob exists (guard lib = step 37 re-roll). Advice: GRT_RESIZER_HOLD_SLACK_MARGIN 0.15
  (not 0.10: optimism lower bound leaves ~+0.017), est. +10-40 hold cells; apply to queued Fp185n2, leave running Fp190n2.
- 11-25 Fp190n2i (256B @19.0, hold margin 0.15) PASSED rc 0; 1 antenna viol at step 48: soc.icache.data_hi_w_ena met3 PAR 406/400 (1.01),
  gates and2_2/A + hold2812/A. MEASURED cause: post-DRT antenna loop in drt.tcl (DRT_ANTENNA_REPAIR_ITERS 3, margin = GRT_ANTENNA_REPAIR_MARGIN 10)
  used all 3 iterations (90->131 diodes, 8->9, 3->3), each followed by a re-route; loop exits at i>3 WITHOUT a final check -> last re-route's
  leftovers survive. hd-r 36->1->0, Fcauto4 91->5->0 converged within 3. NOT caused by step 44 per se. Fix: DRT_ANTENNA_REPAIR_ITERS 5
  (loop exits on 0 -> runs that converge in <=3 are bit-identical; changes only step 46 after its 3rd re-route). Apply to all queued + port config.
