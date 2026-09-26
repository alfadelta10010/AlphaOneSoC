# QSPI memories — flash and PSRAM reference

Everything the SoC needs to know about the two memory ICs on the
TinyTapeout QSPI Pmod: the board, the packages, every command we use or
might use, the mode state machines, the timing parameters, and what each
of them means for `src/qspi_ctrl.v`. The last sections weigh **QPI mode
against the SPI framing we use today, counted in SCK cycles**, and list
the defects and open questions the datasheets turned up.

| Role | Part on the board | Datasheet that describes it |
|---|---|---|
| Flash, CS0 | Winbond **W25Q128JVSIM** (marked `25Q128JVSM`) | **`docs/W25Q128JV_DTR.pdf`** — W25Q128JV-DTR, Rev C, 2018-03-02 |
| PSRAM A, CS1 | AP Memory **APS6404L-3SQR-SN** | `docs/APS6404L_3SQR.pdf` — Rev 2.3, 2020-04-30 |
| PSRAM B, CS2 | AP Memory **APS6404L-3SQR-SN** | same |

> **The flash datasheet in `docs/W25Q128JV_QSPI.pdf` is not the one for
> this part.** That document (Rev F, 2018-03-27) covers the **-IQ/-JQ**
> parts (QE fixed at 1, JEDEC ID `EF 40 18`) and says, in its ID table and
> ordering notes, *"For DTR, QPI supporting, please refer to W25Q128JV DTR
> datasheet"*. The Pmod carries the **-IM** part (QE programmable, factory
> 0, JEDEC ID `EF 70 18`), whose datasheet is the -DTR one. It adds QPI
> mode (38h/FFh), Set Read Parameters (C0h), Burst Read with Wrap (0Ch),
> the DTR reads (0Dh/BDh/EDh/0Eh), the Continuous Read Mode description
> and the HOLD/RST bit. Everything common to both documents agrees
> (command codes, SR layout apart from HOLD/RST, the AC table apart from
> the rows the -DTR adds for DTR clocks and `/HOLD`). The -DTR
> datasheet was fetched from <https://www.pjrc.com/teensy/W25Q128JV.pdf>
> (also mirrored by SparkFun) and saved beside the others.

Sources: the three PDFs above; the Pmod design files,
<https://github.com/mole99/qspi-pmod> at `250aee2` (QSPI-Pmod v2.2,
KiCad 9); the TinyTapeout guide "Configuring and flashing the QSPI Pmod"
(<https://tinytapeout.com/guides/configure-flash-qspi-pmod/>); the
TinyTapeout flasher (<https://github.com/TinyTapeout/tinytapeout-flasher>,
`src/ttcontrol/ttflash.py`); the TinyQV README
(<https://github.com/MichaelBell/tinyQV>), the one silicon-proven design
on this exact board.

Conventions. "SCK cycles" counts rising edges of the serial clock. Our
engine runs SCK = clk/2, so one SCK cycle is two core clocks. Nibble
order on the quad bus is always IO3 = bit 3 of the nibble … IO0 = bit 0,
high nibble of a byte first. `x-y-z` is the number of IO lines used for
command, address and data (1-4-4 = command on IO0, address and data on
all four).

---

## 1. The board: QSPI-Pmod v2.2

One flash and two PSRAMs share **one** SCK and **one** 4-bit data bus;
only the chip selects are separate. 2-layer FR4, 1.6 mm, 3.3 V from the
Pmod connector (no regulator, no level shifting).

### 1.1 Pinout

| Header pin (net) | TT pin | Signal | Flash U1 pin | PSRAM A U2 pin | PSRAM B U3 pin |
|---|---|---|---|---|---|
| 1 (PMOD1) | `uio[0]` | CS0 | 1 `/CS` | — | — |
| 2 (PMOD2) | `uio[1]` | SD0 | 5 `DI (IO0)` | 5 `SI/SIO0` | 5 `SI/SIO0` |
| 3 (PMOD3) | `uio[2]` | SD1 | 2 `DO (IO1)` | 2 `SO/SIO1` | 2 `SO/SIO1` |
| 4 (PMOD4) | `uio[3]` | SCK | 6 `CLK` | 6 `SCLK` | 6 `SCLK` |
| 7 (PMOD5) | `uio[4]` | SD2 | 3 `/WP (IO2)` | 3 `SIO2` | 3 `SIO2` |
| 8 (PMOD6) | `uio[5]` | SD3 | 7 `/HOLD or /RESET (IO3)` | 7 `SIO3` | 7 `SIO3` |
| 9 (PMOD7) | `uio[6]` | CS1 | — | 1 `CE#` | — |
| 10 (PMOD8) | `uio[7]` | CS2 | — | — | 1 `CE#` |
| 5, 11 | — | GND | 4 | 4 | 4 |
| 6, 12 | — | +3.3 V | 8 | 8 | 8 |

(The header is a 2×6 Pmod: pins 1–4 and 7–10 carry the nets the README
calls PMOD1–PMOD8. Our `qspi_ctrl` pin assignment, `uio` 0/1/2/3/4/5/6/7 = CS0/SD0/SD1/SCK/SD2/SD3/CS1/CS2,
matches this table.)

### 1.2 Everything else on the board (from the KiCad netlist)

| Ref | Value | Where | Note |
|---|---|---|---|
| R1, R2, R3 | 10 kΩ 0402 | CS2, CS1, CS0 → +3.3 V | **Chip-select pull-ups.** They sit on the *device* side of the J2 cut traces, so each chip is held deselected whenever nobody drives its CS — including while our core is in reset and the pads are released. |
| J2 | 2×4 header, "CONFIG" | 1-2 CS0, 3-4 CS1, 5-6 CS2, 7-8 SCK↔C7 | Pads 1-2, 3-4, 5-6 are bridged by bottom-side traces; **cutting one disables that chip** (its pull-up keeps it deselected) and frees the Pmod pin. Pads 7-8 are **open**: shorting them hangs C7 on SCK. |
| C7 | 22 pF | SCK → GND via J2 7-8 | Optional **SCK delay**. Slows SCK at the devices so their output timing moves later relative to the controller. Fitted, but connected only when J2 7-8 is shorted. |
| C1/C2, C5/C6, C3/C4 | 100 nF + 1 µF per chip | at each VDD pin | Matches the PSRAM datasheet's decoupling requirement (1 µF low-ESR, optional 100 nF). |

**No pull-ups or pull-downs on SD0–SD3 or SCK.** Whenever no master
drives them, the data lines float. That matters twice: (a) the flash's
`/WP` and `/HOLD` are IO2/IO3 while QE = 0, so they must be *driven high*
during any SPI-mode command until QE is set; (b) the PSRAM datasheet asks
for SIO low and CLK low during its power ramp, which the board does not
enforce (it is the demo board's power sequencing, outside our control).

### 1.3 Electrical load on the shared bus

Each data line is loaded by three device pins (6 pF in / 8 pF out each,
both datasheets), the TinyTapeout pad, the Pmod connector and the traces.
A rough estimate is 25–30 pF. The PSRAM's AC timing (`tACLK`) is
specified for a **system load of at most 15 pF**; the flash's for 30 pF.
The PSRAM therefore drives a heavier load than it is specified for, and
its clock-to-output time on the board will be longer than 5.5 ns. That is
one more reason the engine samples late (see §6). This is an estimate,
not a measurement.

---

## 2. Packages

### 2.1 Flash — W25Q128JVSIM, 8-pin SOIC 208-mil (package code S)

KiCad footprint `Package_SO:SOIC-8_5.23x5.23mm_P1.27mm`.
Top marking `25Q128JVSM` (Winbond marks 10 of the 12 ordering digits).

| Dim | Min | Nom | Max (mm) |
|---|---|---|---|
| A (height) | 1.75 | 1.95 | 2.16 |
| A1 (standoff) | 0.05 | 0.15 | 0.25 |
| A2 | 1.70 | 1.80 | 1.91 |
| b (lead width) | 0.35 | 0.42 | 0.48 |
| c (lead thickness) | 0.19 | 0.20 | 0.25 |
| D (body length) | 5.18 | 5.28 | 5.38 |
| E1 (body width) | 5.13 | 5.23 | 5.33 |
| e (pitch) | | 1.27 BSC | |
| H (tip to tip) | 7.70 | 7.90 | 8.10 |
| L (foot) | 0.50 | 0.65 | 0.80 |
| y (coplanarity) | | | 0.10 |
| θ | 0° | | 8° |

Pins: 1 `/CS`, 2 `DO (IO1)`, 3 `/WP (IO2)`, 4 GND, 5 `DI (IO0)`, 6 `CLK`,
7 `/HOLD or /RESET (IO3)`, 8 VCC. No hardware reset pin on this package
(pin 7 becomes `/RESET` only if SR3 `HOLD/RST` = 1 *and* QE = 0).

Ordering code decode, `W25Q128JV S I M`: 25Q = SpiFlash with 4 KB
sectors, 128J = 128 Mbit JV generation, V = 2.7–3.6 V, **S = SOIC-8
208 mil**, **I = industrial −40…+85 °C** (J = −40…+105 °C), **M = QE
programmable, factory 0, new device ID** (Q = QE fixed at 1).

### 2.2 PSRAM — APS6404L-3SQR-SN, SOP-8 150-mil (package code SN)

KiCad footprint `Package_SO:SOP-8_3.9x4.9mm_P1.27mm`. JEDEC MS-012 AA
(the ordinary SOIC-8 narrow body).

| Dim | Min | Nom | Max (mm) |
|---|---|---|---|
| A (height) | 1.35 | 1.60 | 1.75 |
| A1 (standoff) | 0.10 | 0.15 | 0.25 |
| A2 | 1.35 | 1.45 | 1.55 |
| b (lead width) | 0.31 | — | 0.51 |
| c (lead thickness) | 0.17 | — | 0.25 |
| D (body length) | 4.80 | 4.90 | 5.00 |
| E (tip to tip) | | 6.00 BSC | |
| E1 (body width) | 3.80 | 3.90 | 4.00 |
| e (pitch) | | 1.27 BSC | |
| L (foot) | 0.40 | 0.66 | 1.27 |
| L1 | | 1.05 REF | |
| h (chamfer) | 0.25 | 0.38 | 0.50 |
| Y (coplanarity) | | | 0.10 |
| θ | 0° | | 8° |

Pins: 1 `CE#`, 2 `SO/SIO[1]`, 3 `SIO[2]`, 4 VSS, 5 `SI/SIO[0]`, 6 `SCLK`,
7 `SIO[3]`, 8 VDD. Same pin functions as the flash: the two are
pin-compatible, which is what lets them share the bus.

Ordering code decode, `APS 64 04 L - 3 SQ R - SN`: 64 Mbit, x1/x4 I/O,
die generation L, **3 = 3 V**, SQ = serial x1/x4 SDR, **R = RBX (row
boundary crossing)** (N = non-RBX), **SN = SOP-8, standard temperature
−40…+85 °C** (`-3SQRX-SN` would be extended, −40…+105 °C; `-ZR` is the
USON-8 2×3 mm, −25…+85 °C).

---

## 3. Flash: W25Q128JV (-IM, "-DTR" datasheet)

### 3.1 Organisation and identity

* 16 MB, 24-bit address, byte-addressable reads; 65,536 program pages of
  256 B; erase in 4 KB sectors (4,096), 32 KB or 64 KB blocks (256), or
  whole chip.
* Reads run on across **any** boundary to the end of the array (no page
  wrap on reads unless a wrap is configured, §3.6).
* IDs: manufacturer `EFh`; `9Fh` returns **`EF 70 18`** on -IM/-JM
  (**`EF 40 18`** on -IQ/-JQ); `ABh`/`90h`/`92h`/`94h` device ID `17h`.
  The TT guide expects `ef7018` after QE is set.
* Plus: 64-bit unique ID (`4Bh`), 256-byte SFDP (`5Ah`), three 256-byte
  OTP security registers (`42h`/`44h`/`48h`).

### 3.2 Status registers

| Reg (read / write) | Bit 7 | 6 | 5 | 4 | 3 | 2 | 1 | 0 |
|---|---|---|---|---|---|---|---|---|
| SR1 (`05h` / `01h`) | SRP | SEC | TB | BP2 | BP1 | BP0 | WEL | BUSY |
| SR2 (`35h` / `31h`) | SUS | CMP | LB3 | LB2 | LB1 | (R) | **QE** | SRL |
| SR3 (`15h` / `11h`) | HOLD/RST | DRV1 | DRV0 | (R) | (R) | WPS | (R) | (R) |

* **QE** (SR2[1]): non-volatile. **0 from the factory on the -IM part.**
  QE = 0: IO2 is `/WP`, IO3 is `/HOLD` (or `/RESET`); every quad command
  (6Bh, EBh, 32h, 94h) and `38h` Enter QPI is **ignored**. QE must be 1 for
  anything we do. The TT guide sets it once with `06h` then `31h 02h`
  (non-volatile; `50h` + `31h` would set it volatile, lost at power-off).
  In QPI mode a Write Status Register cannot clear QE.
* **DRV1:0** (SR3[6:5]): output driver strength for reads. **Factory
  default 11 = 25 %**; 10 = 50 %, 01 = 75 %, 00 = 100 %. With the bus load
  of §1.3, a stronger driver shortens the flash's effective clock-to-output
  time; it is a knob for `rd_late` and fmax (volatile via `50h` + `11h`, or
  non-volatile via `06h` + `11h`).
* **HOLD/RST** (SR3[7]): 0 (default) pin 7 is `/HOLD`, 1 it is `/RESET` —
  only while QE = 0. With QE = 1 it is IO3 and neither function exists.
* WEL is set by `06h` and cleared after every program/erase/write-status;
  BUSY is 1 during program/erase/write-status (read SR1 to poll).
* Protection: BP2:0/TB/SEC/CMP (WPS = 0, default) or per-block locks
  (WPS = 1, all locked at power-up). SRP/SRL/`/WP` gate status writes.
  Factory state protects nothing.

### 3.3 Modes and what survives what

```
                power-up / 66h+99h (either form)
                            |
                            v
   +------------------ SPI mode ------------------+   38h (SPI form, needs QE=1)
   |  1-1-1, 1-1-2, 1-2-2, 1-1-4, 1-4-4 commands  | ---------------------------+
   |   EBh with M5-4 = 10  ->  SPI-CRM             |                            v
   +-----------------------------------------------+                 +--- QPI mode ---+
                            ^                                        |  4-4-4 only    |
                            +--------------- FFh (QPI form) ---------|  EBh M5-4=10   |
                                                                     |   -> QPI-CRM   |
   B9h: power-down (only ABh wakes it, tRES1 = 3 us)                  +----------------+
```

* **Continuous Read Mode (CRM)** is a property of the *next* `EBh`: if
  the mode byte M7-0 of an `EBh` has M5-4 = `10` (e.g. `A0h`, `Ax`), the
  next transaction after CS rises and falls has **no command byte** — it
  starts directly with the address. Any M5-4 ≠ `10` returns to normal.
  The recommended exit is 8 clocks with IO0 = 1 (in quad form the
  address nibbles are then all ones and M = `FFh`). M3-0 are don't-care.
* **Volatile, reset by power cycle or `66h`+`99h`:** QPI mode, CRM, the
  read parameters P7-0 (dummy count and QPI wrap length), the SPI wrap
  bits W6-4, WEL, suspend state, volatile SR copies, individual block
  locks (back to all-locked).
* **Non-volatile:** QE, DRV, HOLD/RST, protection bits, WPS, SRL (unless
  set volatile), OTP lock bits.
* **Software reset** `66h` then `99h` (consecutive; anything else between
  cancels it) works in SPI and in QPI form; the device then needs
  **tRST = 30 µs** before it accepts a command. That is ~1,500 clocks at
  50 MHz, which is why our start-up sequence does *not* reset the flash
  and instead walks it out of CRM and QPI explicitly (§7).
* A reset leaves QE (non-volatile) alone and is ignored in power-down
  (only `ABh` is heard there). It does clear a `77h` wrap — but our
  sequence does not reset the flash, so a `77h` wrap survives it.

### 3.4 Read commands, counted

SCK cycles for the command, the address, the mode/dummy clocks, and a
4-byte transfer, with the datasheet's maximum clock (3.0–3.6 V; the Pmod
runs at 3.3 V).

| Cmd | Name | Mode | Cmd | Addr | Mode+dummy | 4 B data | **Total** | Max SCK |
|---|---|---|---|---|---|---|---|---|
| `03h` | Read Data | 1-1-1 | 8 | 24 | 0 | 32 | 64 | 50 MHz |
| `0Bh` | Fast Read | 1-1-1 | 8 | 24 | 8 | 32 | 72 | 133 MHz |
| `3Bh` | Fast Read Dual Out | 1-1-2 | 8 | 24 | 8 | 16 | 56 | 133 |
| `6Bh` | Fast Read Quad Out | 1-1-4 | 8 | 24 | 8 | 8 | 48 | 133 |
| `BBh` | Fast Read Dual I/O | 1-2-2 | 8 | 12 | 4 (M) | 16 | 40 | 133 |
| **`EBh`** | **Fast Read Quad I/O** (ours today) | 1-4-4 | 8 | 6 | 2 (M) + 4 | 8 | **28** | 133 |
| `EBh` | … in SPI-CRM (no cmd) | x-4-4 | 0 | 6 | 2 (M) + 4 | 8 | **20** | 133 |
| `0Bh` | Fast Read, QPI | 4-4-4 | 2 | 6 | P: 2/4/6/8 | 8 | **18**/20/22/24 | 50/80/104/133 |
| `EBh` | Fast Read Quad I/O, QPI | 4-4-4 | 2 | 6 | P: 2/4/6/8 (M is the first 2) | 8 | **18**/20/22/24 | 50/80/104/133 |
| `EBh` | … in QPI-CRM | x-4-4 | 0 | 6 | P (M is the first 2) | 8 | **16**/18/20/22 | as above |
| `0Ch` | Burst Read with Wrap, QPI | 4-4-4 | 2 | 6 | P | 8 | as `0Bh` QPI | as above |
| `EDh` | DTR Fast Read Quad I/O | 1-4-4 DDR | 8 | 3 | 8 (M + 7) | 4 | 23 | 66 |
| `EDh` | DTR, QPI | 4-4-4 DDR | 2 | 3 | 8 | 4 | 17 | 66 |

* **Dummy clocks in QPI come from Set Read Parameters `C0h`** (QPI form,
  4 clocks: `C0h` then P7-0). Default after power-up/reset is **2**.
  "Whenever the device is switched from SPI mode to QPI mode, the number
  of dummy clocks should be set again." `C0h` is not accepted in SPI mode.

  | P5-4 | Dummy | Max SCK 2.7–3.0 V | Max SCK 3.0–3.6 V | P1-0 | QPI wrap (0Ch) |
  |---|---|---|---|---|---|
  | 00 | 2 | 33 MHz | 50 MHz | 00 | 8 B |
  | 01 | 4 | 50 | 80 | 01 | 16 B |
  | 10 | 6 | 80 | 104 | 10 | 32 B |
  | 11 | 8 | 104 | 133 | 11 | 64 B |

* In QPI `EBh` the mode byte **is** the first two dummy clocks: with
  P5-4 = 00 data follows M7-0 immediately (Figure 24c: command 0–1,
  address 2–7, M 8–9, first data nibble sampled on edge 10).
* The whole AC table carries note 6, **"4-bytes address alignment for
  QPI/Quad Read"**, and the P-table adds **"4-bytes address alignment for
  QPI Read: read address start from A1,A0 = 0,0"**. See §8.1: our fetch
  path starts flash reads at halfword addresses.
* The SPI-mode `EBh` mode byte **must be `Fxh`** unless CRM is wanted
  ("the first dummy is M7-M0 should be set to Fxh"). Anything with
  M5-4 = `10` enters CRM.
* Read data leaves the device on the **falling** SCK edge: valid
  `tCLQV` ≤ 6 ns after it, held `tCLQX` ≥ 1.5 ns after the next one.
* Wrap: in SPI mode `77h` (24 dummy bits + W7-0; W4 = 0 enables, W6-5 =
  8/16/32/64 B, default W4 = 1 = off) makes every *later* `EBh` wrap
  inside an aligned 8/16/32/64-byte group. In QPI, `EBh` never wraps;
  `0Ch` wraps by P1-0. We use none of this.

### 3.5 Program, erase, and the rest (for flashers and boot tools)

Never issued by our SoC (the PMA and the engine both refuse writes to
flash), but a flash tool on the same bus must get them right.

| Cmd | Operation | Notes |
|---|---|---|
| `06h` / `04h` | Write Enable / Disable | WEL must be 1 before every program, erase, NV status write |
| `50h` | Volatile SR Write Enable | then `01h/31h/11h` write the volatile copy; WEL stays 0 |
| `02h` | Page Program 1-1-1 (4-4-4 in QPI) | 1–256 B; wraps within the 256 B page; CS must rise on a byte boundary |
| `32h` | Quad Input Page Program 1-1-4 | SPI mode only (in QPI use `02h`) |
| `20h` / `52h` / `D8h` / `C7h`,`60h` | Erase 4 KB / 32 KB / 64 KB / chip | |
| `75h` / `7Ah` | Suspend / Resume | tSUS ≤ 20 µs |
| `B9h` / `ABh` | Power-down / release | tDP 3 µs; tRES1 3 µs (tRES2 1.8 µs with ID) |
| `66h`,`99h` | Reset | tRST 30 µs |

Times: tW (status write) 10 / 15 ms typ/max; tPP 0.4 / 3 ms; tSE
45 / 400 ms; tBE1 (32 KB) 120 / 1,600 ms; tBE2 (64 KB) 150 / 2,000 ms;
tCE 40 / 200 s. Endurance 100 k cycles/sector, retention > 20 years.
CS high between an erase/program/write command and the next: tSHSL2 ≥
50 ns.

### 3.6 Flash AC timing (-DTR datasheet §9.6; identical in the Rev F doc)

| Symbol | Parameter | Min | Max |
|---|---|---|---|
| FR | SCK, all but `03h` and DTR (3.0–3.6 V) | | 133 MHz |
| fR | SCK, `03h` | | 50 MHz |
| — | SCK, DTR commands (3.0–3.6 V) | | 66 MHz |
| tCLH, tCLL | SCK high / low | 45 % of 1/fC(max) | |
| tSLCH | CS active setup to SCK ↑ | 3 ns | |
| tCHSL | CS not-active hold after SCK ↑ | 3 ns | |
| tDVCH | data-in setup | 1 ns | |
| tCHDX | data-in hold | 2 ns | |
| tCHSH | CS active hold after SCK ↑ | 3 ns | |
| tSHCH | CS not-active setup to SCK ↑ | 3 ns | |
| tSHSL1 | CS high between reads | 10 ns | |
| tSHSL2 | CS high after erase/program/write | 50 ns | |
| tSHQZ | CS ↑ to output high-Z | | 7 ns |
| tCLQV | SCK ↓ to output valid | | 6 ns |
| tCLQX | output hold after SCK ↓ | 1.5 ns | |
| tHLCH, tCHHH, tHHCH, tCHHL | `/HOLD` setup/hold | 5 ns | |
| AC load | | | 30 pF, 5 ns input edges |

Power-up: `/CS` must track VCC; tVSL ≥ 20 µs from VCC(min) to the
first CS low; program/erase ignored for tPUW (≥ 5 ms). SPI modes 0 and 3
are both supported (we use mode 0: SCK idles low).

DC: VIH ≥ 0.7 VCC, VIL ≤ 0.3 VCC, VOH ≥ VCC − 0.2 V at −100 µA, VOL ≤
0.2 V at 100 µA. Standby 10 / 60 µA, power-down 1 / 20 µA, quad read
8 / 15 mA at 50 MHz.

---

## 4. PSRAM: APS6404L-3SQR

### 4.1 Organisation

* 64 Mbit = 8 M × 8, address A[22:0] (the 24-bit address field carries a
  don't-care A23). **Two chips** give the SoC 16 MB; `addr[23]` picks
  CS1 or CS2.
* **Page = 1 KB (CA[9:0]).** Default burst is **Linear Burst**, which on
  this **RBX** part runs across a page boundary transparently — but *"it
  can cross page boundary one time only in a burst"* and crossing bursts
  are limited to **84 MHz**. A non-RBX part (`-3SQN`, and several
  "compatible" PSRAMs) wraps within the 1 KB page instead.
* `C0h` **Wrap Boundary Toggle** flips between Linear Burst and Wrap-32
  (32-byte aligned wrap, CA[4:0], up to 133 MHz at 3.0 V / 109 MHz at
  3.3 V). It is a *toggle*: its effect depends on the current state, so
  never send it without knowing that state (a reset returns to Linear).
* Refresh is internal and **needs CE# high**: every read or write must be
  ended by CE# high "immediately afterwards", and CE# may stay low at
  most **tCEM = 8 µs** (standard grade, our `-SN`) or 4 µs (extended
  grade).
* Drive strength fixed at 50 Ω (no command to change it in this
  datasheet).

### 4.2 Modes

```
 power-up / 66h+99h ---> SPI mode ---35h (SPI form)---> QPI mode
                            ^                              |
                            +-------F5h (QPI form)---------+
                            (66h+99h also works in QPI form)
```

* Powers up in **SPI mode** with CE# high. The command table's "QE = 0"
  and "QE = 1" labels only name SPI and QPI mode: the PSRAM has no QE
  register bit.
* `35h` Enter Quad Mode: SPI form only. `F5h` Exit Quad Mode: QPI form
  only.
* Reset: `66h` then `99h`, consecutive, SPI or QPI form. Back to SPI mode
  and Linear Burst. **tRST = 50 ns** from the end of `99h` to the next
  command. The datasheet does **not** say whether the array contents
  survive; we assume they may not.
* Power-up: after VDD is stable, **150 µs, then a user-issued reset**
  complete self-initialisation. During the ramp CLK low, CE# high
  (tracking VDD within 200 mV), SIO low.

### 4.3 Commands, counted

| Cmd | Name | SPI form | Wait | Max | QPI form | Wait | Max |
|---|---|---|---|---|---|---|---|
| `03h` | Read | 1-1-1 | 0 | **33 MHz** | — | | |
| `0Bh` | Fast Read | 1-1-1 | 8 | 133/84 | **4-4-4** | **4** | **66 MHz** |
| `EBh` | Fast Quad Read | **1-4-4** | 6 | 133/84 | 4-4-4 | 6 | 133/84 |
| `02h` | Write | 1-1-1 | 0 | 133/84 | 4-4-4 | 0 | 133/84 |
| `38h` | Quad Write | **1-4-4** | 0 | 133/84 | 4-4-4 (= `02h`) | 0 | 133/84 |
| `35h` | Enter Quad Mode | 1 | | 133 | — | | |
| `F5h` | Exit Quad Mode | — | | | 4 | | 133 |
| `66h`/`99h` | Reset Enable / Reset | 1 | | 133 | 4 | | 133 |
| `C0h` | Wrap Boundary Toggle | 1 | | 133 | 4 | | 133 |
| `9Fh` | Read ID | 1-1-1 | 0 | 33 | — | | |

"133/84": 133 MHz (3.0 V ±10 %) or 109 MHz (3.3 V ±10 %) in Wrap-32,
84 MHz in Linear Burst.

SCK cycles for our transfer sizes:

| Transaction | SPI form (ours today) | QPI form |
|---|---|---|
| Read 4 B | `EBh` 8 + 6 + 6 + 8 = **28** | `0Bh` 2 + 6 + 4 + 8 = **20** (`EBh`: 22) |
| Read 2 B (page-split fetch half) | 24 | 16 |
| Write 4 B | `38h` 8 + 6 + 8 = **22** | `02h`/`38h` 2 + 6 + 8 = **16** |
| Write 2 B | 18 | 12 |
| Write 1 B | 16 | 10 |

Waveforms (cycle numbers are SCK rising edges; data leaves the PSRAM
`tACLK` after a falling edge and is shown in the cycle it is sampled):

```
SPI EBh (Fig. 8):  0..7 cmd on SIO0 | 8..13 addr A23..A0 quad | 14..19 wait (hi-Z) | 20,21 = byte0 hi,lo ...
QPI 0Bh (Fig. 13): 0,1 cmd 0,B      | 2..7 addr quad          | 8..11 wait (hi-Z)  | 12,13 = byte0 hi,lo ...
QPI EBh (Fig. 14): 0,1 cmd E,B      | 2..7 addr quad          | 8..13 wait (hi-Z)  | 14,15 = byte0 hi,lo ...
SPI 38h (Fig. 10): 0..7 cmd on SIO0 | 8..13 addr quad         | 14,15 = byte0 hi,lo in ...
QPI 38h/02h (Fig. 15): 0,1 cmd      | 2..7 addr quad          | 8,9 = byte0 hi,lo in ...
```

Read ID (`9Fh`, SPI only, ≤ 33 MHz): 8 command clocks, 24 address clocks
(don't care), then MF ID `0Dh`, KGD (`5Dh` = pass, `55h` = fail), then
EID[47:0] with the density in EID[47:45].

### 4.4 PSRAM AC timing (datasheet §14.6)

| Symbol | Parameter | Min | Max |
|---|---|---|---|
| tCLK | SPI Read `03h` | 30.3 ns (33 MHz) | |
| tCLK | QPI Fast Read `0Bh` | 15.1 ns (66 MHz) | |
| tCLK | all others, Wrap-32, 3.0 V / 3.3 V | 7.5 / 9.17 ns | |
| tCLK | all others, Linear Burst | 11.9 ns (84 MHz) | |
| tCH / tCL | SCK high / low | 0.45 tCLK | 0.55 tCLK |
| tKHKL | SCK rise/fall (20–80 %) | | 1.5 ns |
| tCPH | CE# high between bursts | **18 ns** | |
| tCEM | CE# low | | **8 µs** std / 4 µs ext |
| tCSP | CE# setup to SCK ↑ | 2.5 ns | |
| tCHD | CE# hold after SCK ↑ | 3.0 ns | |
| tSP | input setup | 2 ns | |
| tHD | input hold | 2 ns | |
| tHZ | CE# ↑ to output high-Z | | 5.5 ns |
| tACLK | SCK ↓ to output valid | 2 ns | 5.5 ns |
| tKOH | output hold after SCK ↓ | 1.5 ns | |
| tRST | end of `99h` to next command | 50 ns | |
| CL | system load | | **15 pF** |

* For reads the datasheet *recommends* tCHD > tACLK + tCLK, so the last
  nibble is still there when the controller latches it (Figure 3) — our
  `rd_late` `S_TAIL` state does exactly this.
* Above 84 MHz it recommends sampling read data on the falling edge or
  training the sampling point. Irrelevant at our SCK.

DC (VDD 2.7–3.6 V): **VIH ≥ VDD − 0.4 V** (2.9 V at 3.3 V), **VIL ≤
0.4 V**, VOH ≥ 0.8 VDD, VOL ≤ 0.2 VDD at 0.2 mA. These are tight CMOS
levels, tighter than the flash's 0.7/0.3 VCC: the TinyTapeout pads must
swing rail to rail at 3.3 V into this load. ICC 7 mA active,
standby 250 µA (85 °C) / 140 µA (25 °C).

---

## 5. Side by side

| | W25Q128JVSIM (flash) | APS6404L-3SQR (PSRAM) |
|---|---|---|
| Size / address | 16 MB, A[23:0] | 8 MB each, A[22:0] |
| Power-up mode | SPI (QE = 0 from factory) | SPI |
| Quad needs | QE = 1 (non-volatile, set once) | nothing |
| Enter / exit QPI | `38h` SPI form / `FFh` QPI form | `35h` SPI form / `F5h` QPI form |
| Reset | `66h`+`99h`, **30 µs** | `66h`+`99h`, **50 ns** |
| Our read | `EBh` 1-4-4, M = `FFh`, 4 dummy | `EBh` 1-4-4, 6 wait |
| Same framing? | **yes**: 8 + 6 + 6 clocks, first data on edge 20 | |
| QPI read | `0Bh`/`EBh`, 2/4/6/8 dummy by `C0h` | `0Bh` 4 wait (≤ 66 MHz) / `EBh` 6 wait |
| **Common QPI read** | **`0Bh` with P5-4 = 01: 2 + 6 + 4** | **`0Bh`: 2 + 6 + 4** |
| Address alignment | QPI/Quad reads: **A1:A0 = 00** | none |
| Page | 256 B program page; reads run on | 1 KB; RBX runs on once per burst |
| Max CS low | none | 8 µs |
| Min CS high | 10 ns (read), 50 ns (write) | 18 ns |
| Output valid after SCK ↓ | ≤ 6 ns (30 pF, 25 % drive) | 2–5.5 ns (15 pF) |
| Output hold after SCK ↓ | ≥ 1.5 ns | ≥ 1.5 ns |
| Input setup / hold | 1 / 2 ns | 2 / 2 ns |
| CS setup / hold | 3 / 3 ns | 2.5 / 3 ns |
| Commands that clash | `38h` = Enter QPI (SPI mode) | `38h` = Quad Write |
| | `C0h` = Set Read Params (QPI) | `C0h` = Wrap Toggle |
| | `FFh` = Exit QPI / CRM reset | `F5h` = Exit QPI |

Two command clashes matter: a PSRAM write (`38h`) sent to an SPI-mode
flash puts the flash into QPI (the engine never selects the flash for a
write), and `C0h` means something different to each chip (never
broadcast it).

---

## 6. Our engine against the datasheets (`src/qspi_ctrl.v`, SCK = clk/2)

Host outputs change on the core clock edge that drives SCK low; the
device samples them one core clock (T) later on SCK ↑; read data is
sampled 2T (`rd_late` = 0) or 3T (`rd_late` = 1) after the SCK ↓ that
launched it. T = 20 ns at 50 MHz, 15 ns at 66 MHz.

| Requirement | Datasheet | Engine gives | 50 MHz | 66 MHz |
|---|---|---|---|---|
| Data setup before SCK ↑ | 2 ns (PSRAM), 1 ns (flash) | ≈ T − pad skew | 20 ns ✓ | 15 ns ✓ |
| Data hold after SCK ↑ | 2 ns | ≈ T | ✓ | ✓ |
| CS setup before first SCK ↑ | 2.5 / 3 ns | T | ✓ | ✓ |
| CS hold after last SCK ↑ | 3 ns | ≥ T (3T with `S_TAIL`) | ✓ | ✓ |
| SCK duty | 45–55 % | 50 % (registered toggle) | ✓ | ✓ |
| CS high between transactions | 18 ns (PSRAM), 10 ns (flash read) | ≥ 2T | 40 ns ✓ | 30 ns ✓ |
| SCK ceiling, current commands | PSRAM `EBh` 84 MHz (linear), flash `EBh` 133 | clk/2 | 25 MHz | 33 MHz |
| CS low, one 4 B read | ≤ 8 µs | ≈ 56T | 1.1 µs | 0.85 µs |
| Minimum clock for tCEM (4 B read, ≈ 60 clocks) | | | ≥ 7.5 MHz (std), 15 MHz (ext) | |
| Read data: launch → sample | tACLK/tCLQV + 2 pad delays | 2T or 3T | see `rd_late` | |

The frequency ceilings that would bite if SCK ever ran at clk: PSRAM
`03h` 33 MHz (we never use it), PSRAM QPI `0Bh` **66 MHz**, flash QPI
with 2 dummy clocks **50 MHz**, with 4 dummy 80 MHz.

---

## 7. Start-up and hand-over

### 7.1 States another design (or the RP2040) can leave behind

| Device | Possible state at our reset release | Left by | Way out |
|---|---|---|---|
| PSRAM | QPI mode | TinyQV (expects PSRAM in QPI), any QPI user | `F5h` in QPI form |
| PSRAM | Wrap-32 | anyone who toggled `C0h` | reset (`66h`+`99h`) |
| Flash | SPI-CRM | TinyQV (runs flash in CRM, M = `A0h`) | 8 clocks of `1111` |
| Flash | QPI (± CRM, any P) | a QPI user | CRM exit, then `FFh` in QPI form |
| Flash | `77h` wrap on | a cache-line user | `77h` with W4 = 1, or reset (30 µs) |
| Flash | power-down (`B9h`) | a low-power user | `ABh`, then 3 µs |
| Flash | QE = 0 | a fresh -IM part | `06h`, `31h 02h` — a programming job, not ours |

### 7.2 Today's sequence (SPI framing)

| Step | CS | Sent | Effect |
|---|---|---|---|
| 0 | CS1+CS2 | `F5h` QPI form (2 clk) | PSRAM leaves QPI; SPI-mode PSRAM sees 2 bits of nothing |
| 1–2 | CS1+CS2 | `66h`, `99h` SPI | PSRAM reset — only when booting from flash |
| 3 | CS0 | 8 clk of `1111` | flash leaves CRM (SPI or QPI) |
| 4 | CS0 | `FFh` QPI form (2 clk) | flash leaves QPI; SPI-mode flash sees 2 bits of nothing |

The flash steps sit between the PSRAM reset and the first request, well
over tRST = 50 ns.

### 7.3 Sequence for QPI operation (proposed, §9)

Eight steps — the 3-bit `step` counter already has room:

| Step | CS | Sent | Why |
|---|---|---|---|
| 0 | CS1+CS2 | `F5h` QPI form | PSRAM → SPI |
| 1 | CS1+CS2 | `66h` SPI (if `psram_reset`) | |
| 2 | CS1+CS2 | `99h` SPI (if `psram_reset`) | PSRAM → SPI, Linear Burst |
| 3 | CS0 | 8 clk `1111` | flash leaves CRM |
| 4 | CS0 | `FFh` QPI form | flash → SPI |
| 5 | CS0 | `38h` SPI | flash → QPI (ignored if QE = 0: then every flash read fails, as today) |
| 6 | CS0 | `C0h`, P QPI form (4 clk) | flash dummy count; mandatory after entering QPI |
| 7 | CS1+CS2 | `35h` SPI | PSRAM → QPI; four transactions after `99h`, so tRST holds |

`C0h` goes only to CS0: to the PSRAM it is Wrap Boundary Toggle.

### 7.4 What we leave behind for the next user

The TinyTapeout flasher (`src/ttcontrol/ttflash.py`) speaks 1-bit SPI
only and sends nothing to recover the flash: it opens with `9Fh`. From
SPI-CRM it recovers by accident after one lost command (the flash takes
that `9Fh` as address and mode bits, its bits give M4 = 1, and it drops
out of CRM), but **it cannot
reach a flash left in QPI mode** until the Pmod is power-cycled. If we
adopt flash QPI, either document "power-cycle the Pmod before flashing"
or ask for the flasher to send `FFh` and `66h`/`99h` in QPI form (all four
IOs) before `9Fh`.

---

## 8. Findings for the current RTL

### 8.1 Flash quad reads from a halfword address (datasheet rule, not yet observed)

Both flash datasheets qualify their entire AC table with "4-bytes address
alignment for Quad Read" (-DTR: "QPI/Quad Read"), and the -DTR P-table
says QPI reads start at A1:A0 = 00. `mem_ctrl` fetches 4 bytes from the
**halfword** `pc`, so a flash fetch with `pc[1]` = 1 starts a Quad I/O
read at A1:A0 = 10 — formally outside the characterised conditions.
In SPI mode with 4 dummy clocks at ≤ 33 MHz this is very probably
harmless (generic `spi-nor` drivers issue unaligned `EBh` reads all the
time), but nothing in hand proves it. In **QPI with 2 dummy clocks it is
an explicit rule.**

The cheap fix, if needed: for a flash fetch with `pc[1]` = 1, read 6
bytes from `pc & ~3`. `qspi_ctrl`'s 32-bit read register shifts in at the
bottom and is never cleared, so after 6 bytes it already holds exactly
the last 4 — the ones the fetch wants. Cost: a 3-bit byte count and
+4 SCK on those fetches only. Data loads are always word-aligned already.

### 8.2 The flash datasheet in the repo describes a different part

See the note at the top. Anything about QPI, `C0h`, CRM or the
HOLD/RST bit has to come from `docs/W25Q128JV_DTR.pdf`.

### 8.3 Open board question answered: chip-select pull-ups exist

`docs/soc-architecture.md` lists "while reset is held the chip selects
are released; unless the Pmod or the RP2040 pulls them high, they float"
as open. The Pmod has 10 kΩ pull-ups on CS0/CS1/CS2 (R3/R2/R1). The data
lines have none (§1.2).

### 8.4 PSRAM grade is standard: tCEM = 8 µs

The Pmod BOM is `APS6404L-3SQR-SN` (standard, −40…+85 °C), so the
engine's 8 µs model default is right; 4 µs applies only to a `-3SQRX`.

### 8.5 The 1 KB page split is insurance, not a requirement, on this BOM

The BOM part is RBX, which reads across a page. The split in `mem_ctrl`
covers non-RBX clones on other boards; it costs little and stays.

### 8.6 Hand-over from a flash in QPI **and** CRM (minor)

Step 3 clocks 8 nibbles of `1111`. A flash in QPI-CRM with 2 dummy
clocks takes them as address + mode byte and starts driving data at the
SCK ↓ where the engine raises CS0. Output-disable (tSHQZ ≤ 7 ns) and the
host's own drive then overlap for a few ns. No design we know of leaves
the flash in that state (TinyQV uses SPI-CRM); the model does not
exercise it (`+FLASH_QPI` and `+FLASH_CRM` are separate).

---

## 9. Should we go QPI? SCK cycles per transaction

Core clocks per transaction ≈ 2 × SCK + 4 (start, `S_END`, deselect).

| Transaction | Today (SPI form) | PSRAM QPI | Flash QPI P = 01 (4 dummy) | Flash QPI P = 00 (2 dummy) | Flash QPI-CRM P = 00 |
|---|---|---|---|---|---|
| PSRAM read 4 B | 28 SCK / ~60 clk | **20 / ~44** | | | |
| PSRAM write 4 B | 22 / ~48 | **16 / ~36** | | | |
| PSRAM write 1 B | 16 / ~36 | **10 / ~24** | | | |
| Flash read 4 B | 28 / ~60 | | **20 / ~44** | 18 / ~40 | 16 / ~36 |
| + `pc[1]` = 1 flash fetch, aligned (§8.1) | (28) | | 24 / ~52 | 22 / ~48 | 20 / ~44 |

For comparison, flash SPI-CRM (TinyQV's choice) is 20 SCK — the same as
flash QPI with 4 dummy clocks — and DTR QPI `EDh` would be 17 (15 with
CRM) at the price of DDR pads and a 66 MHz cap; the PSRAM has no DTR.
DTR buys at most 1 SCK over SDR QPI here and is not worth it.

**Verdict: yes, go QPI on both chips, with one read shape for both.**

1. **PSRAM: QPI, `0Bh` reads (4 wait), `02h` writes.** −29 % on every
   read, −27 % on a 4-byte write, −37 % on a byte store; all of Linux's
   traffic is PSRAM traffic, so this is the ~25 % CPI cut the review
   estimated. TinyQV runs exactly this (20-cycle reads, 16-cycle writes)
   on this board in silicon. `0Bh`'s 66 MHz limit is twice our SCK.
2. **Flash: QPI, `0Bh` with P5-4 = 01 (4 dummy clocks).** That makes
   every read on the bus the *same* transaction — 2 command clocks,
   6 address, 4 released, data — so the engine loses its SPI-form
   command path for normal traffic and the mode-byte drive entirely
   (`0Bh` has no mode byte, and the bus can be released for all four
   wait clocks). Commands become `0Bh`/`02h`, whose high nibble is `0`
   for both: the command phase is a constant nibble then `we ? 2 : B`.
   The SPI-form shifter stays only for the start-up commands.
3. **Honour the alignment rule on flash** (§8.1, 6-byte aligned fetch
   when `pc[1]` = 1) once flash is QPI.
4. **Leave 2-dummy and CRM for later.** They shave 2 and 4 more SCK off
   flash reads only, and flash is read only while booting (Linux runs from
   PSRAM). 2 dummy clocks also cap SCK at 50 MHz and need a per-chip
   dummy count; CRM needs a state flop and an `EBh`-with-`A0h` first read.

Costs to accept:

* Flash QPI needs QE = 1 — already a prerequisite for today's `EBh`.
* The start-up sequence grows from 5 to 8 steps (§7.3), ~30 SCK once.
* We leave the flash in QPI: the TT flasher cannot reprogram it without
  a Pmod power cycle (§7.4).
* The Pmod model needs QPI `0Bh`/`02h` support in both devices, QPI
  `C0h` for the flash, `35h` for the PSRAMs, and a check that flash QPI
  read addresses are 4-byte aligned.

---

## 10. Open questions (need a human, the TT Discord, or a board)

1. **Which parts do shipped QSPI Pmods actually carry?** The KiCad BOM
   says W25Q128JVSIM + APS6404L-3SQR-SN; earlier revisions or clones may
   differ (non-RBX PSRAM, -IQ flash with `EF 40 18`, which has no QPI).
2. **Does TinyQV ever start a flash read off a 4-byte boundary?** If it
   does, that is silicon evidence that unaligned SPI-mode `EBh` works on
   this flash at 32 MHz.
3. **Has anyone run the flash in QPI on this board**, and does the
   community flasher or `tt-micropython` recover a flash left in QPI?
4. **Measured SCK-to-data round trip** on a TT06+ chip with this Pmod,
   with and without the 22 pF SCK cap, and with the flash's DRV bits at
   25 % vs 100 %. That decides `rd_late` and whether SCK = clk is viable.
5. **Does the demo board power-cycle the Pmod** when the RP2040 selects a
   different design or resets? (Everything in §7 assumes it does not.)
