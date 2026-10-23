---
name: finding-syscon-design-2026-10-23
description: syscon (0x1002_0000) design planned as WO-20 (RTL) / WO-21 (docs) / WO-22 (DW watchdog) -- reset architecture (rst vs rst_soc), 2-edge reboot hold, strap mux, full decode, Linux/QEMU driver facts, mailbox 12-bit-immediate catch, area 0.087 t
metadata:
  type: project
---

Planned 2026-10-23 as the Opus planner (no RTL edits). WOs: build/wo/WO-20-syscon-rtl.md, WO-21-syscon-docs.md
(copies + validated acceptance benches in localFiles/verif-reports-2026-10-23/wo/, WO-20-acc/ with SHA256SUMS).

Design (as specified; check the RTL when reviewing WO-20):
- syscon.v ports: clk, rst (pin), rst_soc out, sel/we/be/addr[15:2]/wdata/rdata, strap_rd_late in, rd_late out.
  rst_soc = rst | rq | off; every block but syscon (cpu, memc, qspi, clint, uart, gpio) on rst_soc. Generator in
  the SoC, NOT the wrapper (alphaone_soc ports unchanged; wrapper untouched).
- Reboot hold = 2 edges (= shortest pin reset); rq one flop held both edges, rq2 times it. Scratch proof: mtime
  531/531 at both boots, ctl_oe low exactly 2 cycles. Writes gated by !rst_soc.
- Map: +0 FINISH (be[1:0]==11; 0x7777 reboot, 0x5555 off, 0x3333 fail=off; reads 0), +4 RESET_CAUSE W1C [0]PIN
  [1]SOFT reset 1, +8 BOOT_MODE[7:0], +C CHIP_ID 0x4131_5301 (proposed), +10 STRAPS[0], +14/+18 reserved RAZ/WI,
  decode addr[15:5]==0, rest of 64 KB RAZ/WI no alias.
- Strap: strap_q latched while rst; qspi rd_late = rst ? pin : strap_q -> qspi_ctrl.v unchanged, pin-reset timing
  identical. "Follow the pin" mutant hangs boot 2 in the scratch SoC smoke.
- No B9h at power-off (needs ABh + 3 us tRES1 in start-up; hidden state on shared Pmod). CLK_GATE/POWER reserved.
- Residual: uo_out[1]/[3] are muxes (gpio SPI EN) -> possible sub-ns hazard at the reset edge; ask the SPI WO to
  register those pins.
- Area: 979.7 um^2 = 0.087 t, 14 flops (synll.sh TT cell set). Reset root gains one OR (pd-expert: ss slack).

Facts verified at the source (2026-10-23): QEMU sifive_test valid access 2..4 bytes, reads 0, PASS also passes
code; Linux syscon-reboot/poweroff use regmap_update_bits (read first) with parent-regmap fallback;
syscon-reboot-mode needs a "syscon","simple-mfd" parent; reboot-mode.c never writes magic 0 (use mode-normal=1);
syscon.c max_register = size-4. KianV tt06: reboot only (0x7777 low half, 8-cycle rst_cnt), poweroff is a no-op.

Gotchas found: mailbox at +0xF00 is beyond a 12-bit store offset from s11=SYSCON (counter-proposed +0x7F0..+0x7FC);
periph_access.S "syscon reads 0" at +0x10 now reads STRAPS (0 only because tb_soc_periph ties the strap 0);
tests/directed/run.sh:96 lists SoC sources explicitly -> new src file needs a tests/ edit in the wiring commit.

**Why:** user asked 2026-10-23 for "syscon reboot/poweroff/all possible functionality". **How to apply:** when
reviewing the WO-20 diff, check every block's .rst, the 2-edge hold, writes gated in reset, lint 2/6/18, and run
the WO-20-acc smoke benches plus mutants (strap-follow, clint-on-rst, one-edge) as I did in scratch.
Related: [[finding-tt-wrapper-review-2026-10-10]], [[patterns-recurring]].

**User decisions (2026-10-23):** CHIP_ID 0x4131_5301, FAIL halts, no B9h, CLK_GATE/POWER RAZ/WI, RESET_CAUSE
PIN+SOFT all accepted. Mailbox moved to +0x7F0/+0x7F4/+0x7F8 (+0x7FC spare, periph_access reads it as 0).

**WO-22 watchdog (planned same day, build/wo/WO-22-syscon-watchdog.md, benches in WO-22-acc/):**
- Chose the Synopsys DW WDT layout at syscon +0x100 (upstream `dw_wdt`, `snps,dw-wdt`, needs only reg+clocks)
  over a custom keyed reg (+0x068 t, needs ~100-line out-of-tree driver). Same area either way.
- CR EN write-1-only (DW: driver's stop w/o reset ctrl = HW_RUNNING) = built-in lock; CRR kick 0x76 (8-bit key);
  TORR TOP[3:0] reset 15, reads {TOP,TOP}; COMP_PARAMS_1 +0xF4 = 0x40 (USE_FIX_TOP); CCVR etc RAZ.
- Tick = rising edge of mtime[14+TOP] (wdt_tap = mtime[29:14]); 2-bit count, fire on 3rd tick ->
  reset in (1, 1.5] x 2^(16+TOP); TORR write = kick + tprev forced 1 (else one-tick-early, proven 15 < 16).
- WDT flops on rst_soc (own reboot disables it; no fire in power-off); RESET_CAUSE[2] on rst, set wins vs W1C.
- Area: syscon 1625.3 um^2 = 0.144 t, 23 flops; watchdog +0.057 t, +9 flops (1-bit count: +0.049 t).
- Conflicts: WO-14 sweep writes +0x100 (arms it) and must drive wdt_tap (Z -> X on rst_soc); WO-15 alias list
  has +0x100/+0x104. Recommended landing WO-22 code right after WO-20, before WO-14.

**WO-20 review (8d54e14 + 8b29cf8, diff d42833a..8b29cf8): APPROVED, no blocking edits.**
syscon.v is the WO equations verbatim; all six blocks on rst_soc, syscon on rst, qspi rd_late from syscon, SB01-03
lines untouched, run.sh one-token exception. Re-ran on a git archive: lint 2/6/18 (0 in syscon.v), iverilog -Wall
clean, WO-20-acc unit 52 PASS + SoC smoke exact (2104/3801/531/531/2). Per-block reset mutants: core, qspi, uart,
gpio caught by the SoC smoke; **mem_ctrl on rst (AS06) PASSES it** -- no fetch in flight at that reboot; WO-18 lists
AS06, WO-15/16 must reboot with a fetch outstanding to kill it. Nit: alphaone_soc.v header omits the hold/off flops
from "rst resets only ...". WO-22 applied in scratch on 8b29cf8: all four acceptance benches pass exactly (76084).
Verif WO-14..19 were amended for WO-22 (WO-14 depends on WO-22 code; WO-15 probes +0x200/+0x204; WO-18 WD01-14, AS07).
