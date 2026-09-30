---
name: reference-qspi-pmod-datasheets
description: Verified datasheet numbers for the TT QSPI Pmod parts (W25Q128JVSIM flash, APS6404L-3SQR PSRAM) plus how TinyQV and KianV drive the same Pmod — consult before any QSPI/mem_ctrl review
metadata:
  type: reference
---

Checked 2026-09-26. Local copies: ~/Downloads/W25Q128JVSIM.pdf (JV-DTR Rev C), ~/Downloads/priv-isa-asciidoc.pdf
(priv 20240411). APS6404L PDFs fetched to scratch (3SQR Rev 2.1 from github Edragon/Datasheet APM/APS6404L-3SQR-SN-2.pdf;
3SQN Rev 2.7 from apmemory.com). `pdftotext -layout` works.

**TT QSPI Pmod** (tinytapeout.com/guides/configure-flash-qspi-pmod): flash "25Q128JVSM", PSRAM "APS6404L-3SQR or
compatible". uio0 CS0 flash, 1 SD0, 2 SD1, 3 SCK, 4 SD2, 5 SD3, 6 CS1 RAM A, 7 CS2 RAM B. SD2/SD3 have pull-ups;
CS pull-ups UNVERIFIED. QE must be set by the guide's 35h/06h/31h sequence.

**W25Q128JVSIM = W25Q128JV-DTR**: QE=0 factory for IM/JM (1 for IQ/JQ). HAS QPI: Enter QPI = **38h** (same byte as
the PSRAM quad-write opcode!) when QE=1; Exit QPI = FFh. EBh SPI: 8 cmd + 6 addr + 2 mode (M7-0, note 14 "should be
Fxh"; M5-4=10 enters continuous read) + 4 dummy; "IO pins should be Hi-Z before the falling edge of the first data
out clock". FFh on IO0 x8 clocks resets continuous-read mode. tSHSL1 10 ns (read), tSHSL2 50 ns, tCLQV 6 ns,
tCLQX 1.5 ns, tSHQZ 7 ns, tDVCH 1 ns, tCHDX 2 ns, FR 133 MHz. Software reset 66h/99h clears M bits/wrap, tRST ~30 us.

JV-DTR CRM exit: "recommended to input FFh on IO0 for the next instruction (8 clocks)" (any 8 clocks with IO0=1
in the mode nibble works). Exit QPI (FFh, fig. 52) is drawn as 2 clocks then CS#; whether trailing clocks cancel it
is NOT specified. Flash 66h/99h clears QPI, CRM, wrap (77h), read params; tRST ~30 us.
APS6404L: s12 reset text does NOT say whether the array survives 66h/99h (matters for RP2040-preloaded PSRAM).
Read termination: "recommended tCHD > tACLK+tCLK" so the last nibble can be latched.

**APS6404L-3SQR** (R = RBX, row-boundary crossing): page 1 KB; default LINEAR burst crosses a page, max 84 MHz,
"can cross page boundary one time only in a burst" (s8.2). Non-R parts (3SQN, s9.2) WRAP within the 1 KB page by
default. C0h toggles wrap-32. SPI mode: EBh S/Q/6 wait, 38h S/Q/0 wait, 02h, 03h (33 MHz). QPI: 0Bh 4 wait
<=66 MHz, EBh 6 wait, enter 35h, exit F5h. tCPH 18 ns, tCEM 8 us std / 4 us ext (3SQR; 3SQN rev2.4 says 3 us @105C),
tCSP 2.5 ns, tCHD 3 ns, tACLK 2-5.5 ns, tKOH 1.5 ns, tHZ 5.5 ns, tRST 50 ns. s7: after tPU>=150 us a USER-ISSUED
RESET (66h+99h) is required. s8.6: CE# must rise right after each access or refresh is blocked.

**TinyQV** (github MichaelBell/tinyQV cpu/qspi_ctrl.v): same Pmod; "round trip latency of the TT mux is a little
over 20ns" -> read latency 1-3 half-SCK latched from SD pins during reset; 64 MHz clk, SCK=clk/2; PSRAM used in QPI
(0Bh 4 wait, 02h), flash in continuous-read (A0h) — BOTH set up by the RP2040 before start; executes only from
flash to avoid tCEM; blocks reselecting the same RAM for 2 cycles; drives OE=1111 during command.
**KianV TT** (splinedrive/KianV-RV32IMA-RISC-V-uLinux-SoC src/qqspi.v): SPI mode EBh read + 38h write to both
chips, releases ALL 6 wait clocks (flash mode bits float), word-aligned 32-bit reads, writes start at the first
enabled byte with byte count from wstrb, spi_buf + separate rdata reg, no device init in RTL.

Related: [[finding-soc-arch-review-2026-09-26]], [[reference-kianv-memory-map]].
