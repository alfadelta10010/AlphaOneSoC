---
name: finding-syscon-design-2026-10-23
description: syscon (0x1002_0000) design planned as WO-20 (RTL) / WO-21 (docs) -- reset architecture (rst vs rst_soc), 2-edge reboot hold, strap mux, full decode, Linux/QEMU driver facts, mailbox 12-bit-immediate catch, area 0.087 t
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
