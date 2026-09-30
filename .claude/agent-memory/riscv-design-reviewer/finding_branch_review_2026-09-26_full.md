---
name: finding-branch-review-2026-09-26-full
description: Whole-branch review of soc-fabric_alfadelta10010 at bc0baec (+2 doc commits to 605b9d0) — no Critical/Major; PSRAM QPI framing, flash-only boot, start-up sequence verified; open items are model blind spots (M5-4, PSRAM reset, CS-before-OE), flash 77h wrap / PSRAM wrap-32 residual state, SoC tb lacks handshake checker
metadata:
  type: project
---

Reviewed 2026-09-26, 42 commits main(1535042)..bc0baec; 605b9d0/d8194db (docs) landed during the review:
user DECIDED PSRAM QPI only, flash keeps quad I/O EBh (cmd on IO0, M=FFh), no CRM/QPI — do not recommend
flash QPI/CRM again, and don't call the flash "SPI mode".

**Why:** full-branch pass before merge; prior passes were pre-RTL and at 71a8514.
**How to apply:** don't re-raise the verified list; re-check the open list when qspi_ctrl init or the Pmod
model changes.

Verified at HEAD (evidence in scratch review3/, not in repo):
- 84e643d/98410e7/659ed6f/4d0adf3->81afe82/97010f4/6a0fdda/468c14a/7f51964 all correct. QPI 0Bh 2+6+4 and
  38h 2+6 match APS6404L Table 8.5 + Fig 13/15; 35h SPI-form, F5h QPI-form; reset->35h gap >> tRST.
- make test-qspi 8 configs PASS; tb_qspi_stress 3 configs PASS; SoC directed 64/64 (flash_boot needs a
  short path, see below); core-level directed 101/101 PASS; verilator -Wall clean (unused bits only).
- New SoC probes: WFI wake at QSPI speed (mepc=WFI+4, MIE=0 wake) OK; irq_stress (57 timer irqs over
  M-ops, AMO, PSRAM A/B, page-split + A->B straddling fetches) checksum == irq-off pass == Spike.
- Area: qspi_ctrl 2381 -> 2646 um2 (+206 from QPI), SoC 148,963 (was 148,728). yosys flow maps ~2.3k um2
  of lpflow_* cells OpenLane won't use.

Mutations on qspi_ctrl vs tb_qspi: wait 3/5 caught; no-35h caught; no-F5h caught (+PSRAM_QPI); no-step3
caught; no-step4 caught only by +FLASH_QPI +FLASH_CRM. NOT caught: mode byte 0x20 (model checks
mode[7:4]==A, datasheet CRM condition is M5-4=10); dropping 66h/99h entirely; CS falling on first OE cycle
(tb gates cs_n with ctl_oe).

Open (all Minor/Question):
- Model: M5-4 check too narrow; no "reset required after power-up" / 66h-then-99h state; no CRM data drive.
- Flash 77h wrap (volatile, W4=1 default) not undone: silent wrong upper half on straddling flash fetches.
  Cheap fix: init step 77h + 6 addr clk + FFh mode clk (engine already frames this). PSRAM wrap-32 (C0h
  toggle): datasheet s12 does NOT say reset restores Linear, docs claim it does.
- SoC tb has no req/ready handshake checker (lives only in memory_model.v).
- qspi_pmod_model FLASH_FILE buffer is reg[1023:0] = 128 chars; long work dirs fail flash tests loudly.
- Pins released on the same edge rst asserts (CS pulled up by 10k, SCK floats) — nit.
- Readiness: no TT wrapper, no UART (no Linux console), no AlphaOneSoC Linux DTS/boot loader yet.

Related: [[finding-soc-rtl-review-2026-09-26]], [[finding-soc-arch-review-2026-09-26]], [[reference-qspi-pmod-datasheets]].
