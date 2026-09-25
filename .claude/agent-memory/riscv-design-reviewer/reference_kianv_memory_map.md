---
name: reference-kianv-memory-map
description: KianV uLinux SoC's proven NOMMU M-mode Linux memory map and device tree (sky130/TinyTapeout silicon) — the benchmark for AlphaOneSoC's map
metadata:
  type: reference
---

From `asic/os/ulinux_asic_kianv_soc/bldroot/board/kianv/rv32ima/kianv.dts` in
https://github.com/splinedrive/kianRiscV — the DT that actually boots NOMMU M-mode Linux
on sky130 TinyTapeout silicon with 16 MB QSPI flash + 16 MB PSRAM.

- `compatible = "riscv-minimal-nommu"`, `mmu-type = "riscv,none"`, `riscv,isa = "rv32ima"`.
- **memory@80000000** — PSRAM at `0x8000_0000`. Same base as Spike's DRAM_BASE and QEMU
  virt, so no harness translation is needed.
- **clint@11000000**, size 0x10000, `compatible = "sifive,clint0"`. Address is arbitrary
  (it is in the DT) — but Spike hardcodes CLINT at `0x0200_0000`, so keeping 0x02000000
  is free lockstep agreement.
- **uart@10000000**, size 0x100, `compatible = "ns16850"`,
  `bootargs = "earlycon=uart8250,mmio,0x10000000,3000000 console=ttyS0"`. Same base Spike
  uses for its ns16550.
- **NO PLIC** in the ASIC NOMMU DTS (and harris_mcycle_edition). `interrupts-extended = <intc 3>, <intc 7>`
  — MSI and MTI only; the 8250 console runs polled (serial8250_timeout, port->irq=0). KianV's MMU
  SoC (`linux_socs/kianv_mc_rv32ima_sv32/engineering/plic.v`, 31 src x 2 ctx) DOES have a PLIC:
  yosys generic synth ~1037 cells / 129 FF (2026-09-24). A 1-context 4-source 1-bit-priority
  Linux-compatible PLIC is ~165 cells / 17 FF. MEIP straight into riscv-intc is NOT usable by a
  normal driver: intc hwirqs are percpu_devid and request_irq() returns -EINVAL for them.
- **syscon@11100000** + `syscon-poweroff` (0x5555) / `syscon-reboot` (0x7777) — needed for
  a clean `poweroff`/`reboot`, costs one 16-bit compare.
- spi@10500000 for the SD/SPI-NOR path.
- **timebase-frequency = 0x2710 = 10 kHz**, clock-frequency = 70 MHz. mtime is heavily
  prescaled, so the 64-bit incrementer and the 64-bit `mtime >= mtimecmp` comparator do
  not sit on the CPU-clock critical path. AlphaOneSoC's clint.v ticks mtime **every clock**
  and compares combinationally — an area/timing risk on sky130.
- Flash does not appear in the DT at all: reset vector is in flash (KianV boots at
  0x20100000 = flash + 1 MB), a bootloader copies the kernel into PSRAM, and Linux only
  ever sees PSRAM. DTB at flash+1.5 MB, bootloader at +1 MB, Image at +2 MB.

**How to apply:** when reviewing AlphaOneSoC's map, benchmark against this. The two
highest-leverage divergences to question are (a) RAM not at 0x8000_0000 and (b) mtime
ticking at the core clock.

Related: [[project-fyracore-overview]], [[finding-branch-review-2026-09-22]].
