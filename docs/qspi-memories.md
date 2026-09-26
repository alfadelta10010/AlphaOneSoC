# QSPI memories — flash and PSRAM reference

Everything the SoC needs to know about the two memory ICs on the
TinyTapeout QSPI Pmod: the board, the packages, every command we use or
might use, the mode state machines, the timing parameters, and what each
of them means for `src/qspi_ctrl.v`. The last sections weigh **QPI mode
against the SPI framing we use today, counted in SCK cycles**, and list
the defects and open questions the datasheets and the prior art turned
up.

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
`src/ttcontrol/ttflash.py`); five TinyTapeout Discord threads saved as
`docs/*.txt` (§10); and the controllers other designs run on this board,
read from source (§11) — TinyQV, KianV, tinygpu_v2 and FazyRV-ExoTiny.

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
| Our read today | `EBh` 1-4-4, M = `FFh`, 4 dummy | `EBh` 1-4-4, 6 wait |
| Same framing? | **yes**: 8 + 6 + 6 clocks, first data on edge 20 | |
| QPI read | `0Bh`/`EBh`, 2/4/6/8 dummy by `C0h` | `0Bh` 4 wait (≤ 66 MHz) / `EBh` 6 wait |
| **Recommended read (§9)** | **QPI `EBh` in continuous read, P5-4 = 00: 6 address + 2 mode** | **QPI `0Bh`: 2 command + 6 address + 4 wait** |
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
| SCK ceiling, TT output pads | ~33 MHz toggle (community figure, §10) | clk/2 | ✓ | at the limit |
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

### 7.3 Start-up for the recommended operation (§9)

PSRAM in QPI; flash in QPI with continuous read. Eight steps — the
3-bit `step` counter already has room:

| Step | CS | Sent | Why |
|---|---|---|---|
| 0 | CS1+CS2 | `F5h` QPI form | PSRAM → SPI |
| 1 | CS1+CS2 | `66h` SPI (if `psram_reset`) | |
| 2 | CS1+CS2 | `99h` SPI (if `psram_reset`) | PSRAM → SPI, Linear Burst |
| 3 | CS0 | 8 clk `1111` | flash leaves CRM (SPI or QPI) |
| 4 | CS0 | `FFh` QPI form | flash leaves QPI |
| 5 | CS0 | `38h` SPI | flash → QPI (ignored if QE = 0) — skipped when `flash_spi` |
| 6 | CS0 | `C0h 00h` QPI form (4 clk) | flash: 2 dummy clocks (P5-4 = 00); mandatory after entering QPI — skipped when `flash_spi` |
| 7 | CS1+CS2 | `35h` SPI | PSRAM → QPI; steps 3–6 separate it from `99h`, so tRST = 50 ns holds |

`C0h` goes only to CS0: to the PSRAM it is Wrap Boundary Toggle.

The first flash read after reset carries the command — `EBh` in QPI form
(or SPI form with `flash_spi`) with mode byte `A0h` — which arms
continuous read; a flop in the engine then drops the command from every
later flash read. Reset clears the flop, and step 3 takes the flash out
of CRM, so the two can never disagree.

With the `flash_spi` fallback strap (§9) steps 5–6 are skipped and the
flash runs SPI-mode continuous read, TinyQV's proven scheme.

### 7.4 What we leave behind for the next user

The TinyTapeout flasher (`src/ttcontrol/ttflash.py`) speaks 1-bit SPI
only and sends nothing to recover the flash: it opens with `9Fh`. From
SPI-CRM it recovers by accident after one lost command (the flash takes
that `9Fh` as address and mode bits, its bits give M4 = 1, and it drops
out of CRM) — and TinyQV has left flashes in SPI-CRM on every demo
board it has run on, so this is the state community tools already live
with. **It cannot reach a flash left in QPI mode** until the Pmod is
power-cycled — and §9 leaves the flash in QPI. So before flashing, the
RP2040 must release it: CS0 low, IO0–IO3 driven high for 8 clocks (ends
CRM), CS0 high; then CS0 low, IO0–IO3 high for 2 clocks (`FFh`, Exit
QPI), CS0 high. After that the flash is in plain SPI mode and the
flasher works. We need an RP2040 script for this design anyway (straps,
loading PSRAM for `boot_sel` = 1), so this belongs in it; failing that,
unplug the Pmod before flashing.

---

## 8. Findings for the current RTL

### 8.1 Flash quad reads from a halfword address (harmless in SPI mode on silicon; a rule in QPI)

Both flash datasheets qualify their entire AC table with "4-bytes address
alignment for Quad Read" (-DTR: "QPI/Quad Read"), and the -DTR P-table
says QPI reads start at A1:A0 = 00. `mem_ctrl` fetches 4 bytes from the
**halfword** `pc`, so a flash fetch with `pc[1]` = 1 starts a Quad I/O
read at A1:A0 = 10 — formally outside the characterised conditions.

**In SPI mode this is proven harmless on this Pmod:** TinyQV starts every
flash read at `{instr_addr[23:1], 0}` (halfword) for fetches and at any
byte address for loads (`cpu/mem_ctrl.v`), with `EBh` in continuous read
and 4 dummy clocks at 32 MHz SCK, and has run from this flash on every
shuttle since TT06. **In QPI with reduced dummy clocks it is an explicit
rule** and nobody has tested breaking it.

With the flash in QPI (§9) the fix is **required**. It is cheap: for a flash fetch with
`pc[1]` = 1, read 6 bytes from `pc & ~3`. `qspi_ctrl`'s 32-bit read
register shifts in at the bottom and is never cleared, so after 6 bytes
it already holds exactly the last 4 — the ones the fetch wants. Cost: a
3-bit byte count and +4 SCK on those fetches only. Data loads are always
word-aligned already.

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

### 8.6 Hand-over from a flash in QPI **and** CRM — our own state after §9

Step 3 clocks 8 nibbles of `1111`. A flash in QPI-CRM with 2 dummy
clocks takes them as address + mode byte and starts driving data at the
SCK ↓ where the engine raises CS0 and drops its output enable. The
flash's output-disable (tSHQZ ≤ 7 ns) and the host's own drive can then
overlap for a few ns.

With §9 this is no longer somebody else's state: our design leaves the
flash in exactly this mode, so **every reset of our design after the
first** meets it (the Pmod is not power-cycled). The fix is the same
turnaround as a normal QPI read: **drive `1111` for the first 7 clocks of
step 3 and release the bus for the 8th.** In every state the flash can
be in, the 8th nibble is harmless undriven: in SPI- or QPI-CRM it is
M3-0, which is don't-care (M5-4 = `11` was already sent in the 7th); in
QPI without CRM the nibbles can only form `FFh`, Exit QPI, which step 4
repeats anyway; in
plain SPI mode it is the last bit of an 8-bit opcode `1111111x`, which
is no instruction (`FFh` for 8 clocks is Winbond's own recommended
reset of the mode bits). The model's `+FLASH_QPI` and `+FLASH_CRM` are
separate today; the combination needs a plusarg of its own.

---

## 9. The fastest mode for each chip

### 9.1 QSPI and QPI are one engine, not two protocols

Every transaction on this bus is the same four phases. What people call
"QSPI" (1-4-4) and "QPI" (4-4-4) differ **only in the command phase**;
address, wait and data always use all four lines.

| Phase | SPI-form command ("QSPI", 1-4-4) | QPI (4-4-4) | Continuous read (flash) |
|---|---|---|---|
| Command | 8 clocks, 1 bit/clock on IO0 | 2 clocks, 4 bits/clock | **none** |
| Address (24 bits) | 6 clocks × 4 | same | same |
| Mode / wait | per command | per command | per command |
| Data | 2 clocks per byte × 4 | same | same |

Today's engine already uses all four pins everywhere except the 8
command clocks — 8 of the 28 SCK of a read. QPI shrinks that phase to 2
clocks; continuous read (flash only) removes it.

The engine must speak **both** command widths whatever we choose,
because the devices do: they power up in SPI mode, the commands that
*enter* QPI (`35h`, `38h`) are accepted only in SPI form, and the
commands that *leave* it (`F5h`, `FFh`) only in QPI form. `qspi_ctrl`
already has both: the SPI-form shifter and the `qpi_form` path its
start-up uses. After start-up, normal traffic needs only the 4-bit
command (PSRAM) or no command (flash in continuous read). "Two
protocols" is one mux on the width of one phase.

### 9.2 SCK cycles per transaction

Core clocks per transaction ≈ 2 × SCK + 4 (start, `S_END`, deselect).

| Transaction | Today (SPI form) | PSRAM QPI | Flash SPI-CRM, M = `A0h` | Flash QPI P = 00 (2 dummy) | **Flash QPI-CRM, P = 00** |
|---|---|---|---|---|---|
| PSRAM read 4 B | 28 SCK / ~60 clk | **20 / ~44** | | | |
| PSRAM write 4 B | 22 / ~48 | **16 / ~36** | | | |
| PSRAM write 1 B | 16 / ~36 | **10 / ~24** | | | |
| Flash read 4 B, aligned | 28 / ~60 | | 20 / ~44 | 18 / ~40 | **16 / ~36** |
| Flash fetch, `pc[1]` = 1 | 28 | | 20 | 22 / ~48 (6-byte aligned read) | **20 / ~44** (6-byte aligned read) |
| First flash read after reset | 28 | | 28 | 18 | 18 |

**Floors.** Any SDR quad transfer of 4 bytes needs 6 address + 8 data =
14 SCK. The PSRAM adds 2 command + 4 wait, and it has neither continuous
read nor DTR, so **20 is its minimum**: QPI `0Bh` reaches it. The flash
in QPI continuous read adds only the 2 mode clocks: **16**, 2 above the
floor, and never slower than SPI continuous read (its worst case, an
unaligned fetch, ties at 20). DTR QPI `EDh` with continuous read would be
15 (3 address + 8 mode/dummy + 4 data) — one SCK for DDR pads and a
66 MHz cap: not worth it.

### 9.3 Verdict: QPI on both chips; continuous read on the flash too

1. **PSRAM: QPI, `0Bh` reads (4 wait), `02h` writes.** −29 % on every
   read, −27 % on a 4-byte write, −37 % on a byte store; all of Linux's
   traffic is PSRAM traffic, so this is the ~25 % CPI cut the review
   estimated. TinyQV, tinygpu_v2 and FazyRV-ExoTiny all run the PSRAM
   this way on silicon (§11). `0Bh`'s 66 MHz limit is twice our SCK.
2. **Flash: QPI with continuous read, 2 dummy clocks (`C0h 00h`).**
   16 SCK per aligned read, −43 % against today and −20 % against
   SPI-mode continuous read. Details:
   * 2 dummy clocks are rated to 50 MHz SCK at 3.0–3.6 V; we run ≤ 33.
   * In QPI the mode byte *is* the dummy phase. Drive M7-4 = `1010` in
     the first mode clock and release the bus for the second (M3-0 are
     don't-care), so there is a full SCK between the host letting go and
     the flash driving data.
   * QPI reads must start at A1:A0 = 00 (§8.1): a fetch with `pc[1]` = 1
     reads 6 bytes from `pc & ~3` (20 SCK). Loads are word-aligned.
   * The first read after reset is `EBh` in QPI form with `A0h` (18 SCK)
     and arms continuous read.
3. **Keep a `flash_spi` strap** that falls back to SPI-mode continuous
   read (skip start-up steps 5–6, first `EBh` in SPI form, 4 dummy clocks
   after the mode byte): 20 SCK and proven by TinyQV. Flash QPI has not
   been run on this board by anyone we know of, and a strap is how
   `rd_late` already covers the other silicon unknown. Read both straps
   from the QSPI data pins during reset (TinyQV's trick, §11) and they
   cost no pins.

Costs to accept:

* Start-up grows from 5 to 8 steps (§7.3).
* `mem_ctrl`: the 6-byte aligned flash fetch; `qspi_ctrl`: a 3-bit byte
  count, a continuous-read flop, and a preamble that depends on the chip
  (flash, once armed: 6 address + 2 mode = 8 SCK; PSRAM: 2 command +
  6 address + 4 wait = 12).
* We leave the flash in QPI, so the RP2040 must release it before the TT
  flasher can reach it (§7.4).
* QE = 1 on the flash — already required today, and set by TT's QA.
* The Pmod model needs QPI `0Bh`/`02h` and `35h` on the PSRAMs; `38h`,
  QPI `C0h`, QPI `EBh` with `A0h` and command-less reads on the flash; a
  check that QPI flash reads start 4-byte aligned; and it must stop
  rejecting `Ax` mode bytes.

---

## 10. Notes from the TinyTapeout Discord

From five threads saved beside this document (`docs/*.txt`: "Questions
on SPI-RAM-emulation (vs QSPI)", Nov 2024 – Mar 2025; "PSRAM and VGA
timing question", Jun 2026; "How to best implement a framebuffer",
Dec 2025 – Jul 2026; "RAM for ttsky25b tapeout", Oct 2025;
`some-old-pmod-info.txt`, Nov 2024 – Oct 2025). They are people's
experience, not specifications.

* **The Pmod BOM is settled:** a TT team member confirms TT-built Pmods
  carry the **W25Q128JVSIM**, and TinyQV's author that **TT's QA sets
  the QE bit before shipping**. (TinyQV's README still says -SIQ; it
  predates this.) A contributor who built his own Pmods with the -IM
  part found the online flasher could not read the flash ID until he set
  QE. The likely reason, inferred from the datasheet rather than stated
  there: with QE = 0, IO3 is `/HOLD`, the flasher leaves it undriven,
  and the Pmod has no pull-up on it, so the flash can sit in HOLD. A TT
  team member reports both -IM and -IQ parts ran DDR in his tests
  (datasheets say only -IM does).
* **tCEM on silicon, anecdotally:** tinygpu_v2 reads 12.8 µs PSRAM
  bursts (well past 8 µs) on its ttsky25b chip at room temperature with
  no corruption; TinyQV's author has had failures with long reads and
  finds the start of the array more robust than the middle; a TT team
  member saw an iCE40 framebuffer desynchronise (reads returning delayed
  data) when streaming past it. Writes should not run past 1 KB either
  (one page crossing per burst). Our transactions are ~1 µs; any future
  streaming fetch must close well inside 8 µs.
* **SCK without double-rate toggling:** a TT team member suggests using
  an external clock gated by CS, so no output toggles at twice the data
  rate — the sky130 pad limit is on toggle rate.
* **Controllers TinyQV's author points newcomers to:** FazyRV-ExoTiny's
  `wb_qspi_mem` (simple, initialises the PSRAM itself, but samples on the
  falling edge with no latency setting, so about 15 MHz SCK) and TinyQV's
  `qspi_ctrl` (configurable latency, about 33 MHz SCK, but needs the
  RP2040 to put the devices in the right modes first). Both in §11.
* **Other external-RAM routes, and why they are not ours:** the RP2040
  SPI-RAM emulator (`spi-ram-emu`) is 1-bit SPI, 64–128 KB, ≤ ~20 MHz;
  `pio-ram-emulator` reaches > 8 MB/s random reads over 4 pins with its
  own start-bit protocol. Neither gives Linux 16 MB.

* **TT outputs are rated at about a 33 MHz toggle rate** (a TT team
  member and TinyQV's author, separately). So SCK ≤ 33 MHz, which is
  clk/2 at up to 66 MHz — our design point. SCK = clk is only possible
  at clk ≤ 33 MHz.
* **Mux latency both ways is the real limit.** Sampling read data on the
  next SCK edge ("flip the clock, read when you next flip it") halves the
  usable SCK to about 12–15 MHz; accounting for the latency allows about
  33 MHz. TinyQV's controller has a configurable read latency for this —
  the same idea as our `rd_late`. Above 25 MHz SCK the turnaround
  propagation delay needs care.
* **TinyQV: 16 project clocks per 32-bit fetch** at SCK = clk/2 (8 for a
  compressed instruction). That is the *streaming* rate — 8 SCK per word
  with the flash kept selected on sequential fetches — not a per-access
  cost. Per access TinyQV pays 12 SCK of preamble on flash (SPI-CRM) and
  20 SCK for a 4-byte PSRAM read (QPI `0Bh`). After QPI, keeping the
  fetch stream open is the next big lever (soc-architecture.md,
  "Performance", option 2).
* **Continuous read mode byte: `1010xxxx` (`A0h`),** and `1111xxxx`
  followed by a normal command to leave it (TinyQV's author, who also
  noted it seemed undocumented — it is documented, but only in the
  W25Q128JV-DTR datasheet, §8.2.13).
* **Clock pin hygiene:** SCK should come straight from a flop with no
  logic between the flop and the pad, or a cell transient becomes a
  clock edge. `qspi_ctrl` registers `sck`, the chip selects and the
  output enables for this reason.
* **tCEM is real for streaming users:** 8 µs is shorter than a VGA line;
  the two PSRAMs cannot be interleaved to hide it because they share the
  bus (the second cannot be primed while the first streams), and the
  18 ns deselect is only one clock anyway. For us it bounds any future
  streaming fetch: close the stream well inside 8 µs.
* **Auto-calibration idea:** SCK driven out on `uio_out[3]` comes back
  on `uio_in[3]` one pad round trip later, so the chip can measure its
  own round trip and pick the read latency. Both TinyQV's author and a
  retro-console author prefer to keep a manual setting as the fallback;
  our `rd_late` strap is that setting.
* **The flash can do DTR** (8 bits per SCK on four lines); nobody on
  the board has used it (TinyQV considered it for TT10 and found the
  controller change hard). §9 explains why it buys us almost nothing.

## 11. Prior art: controllers for this Pmod

Read from source (links in the Discord threads; commits as cloned
2026-09-26).

| Design | Silicon | Clock / SCK | PSRAM | Flash | Read latency | Notes |
|---|---|---|---|---|---|---|
| **TinyQV** `cpu/qspi_ctrl.v` (MichaelBell/tinyQV `858986b`) | TT06 onwards | 64 MHz / clk/2 = 32 MHz | QPI: `0Bh` 2+6+4 wait, `02h` 2+6+data; RP2040 puts it in QPI | SPI `EBh` continuous read, no command: 6 addr + 2 mode (`1010 1010` driven) + 4 released; RP2040 sets CRM | 1–3 clocks after launch, strapped on SD2:SD0 **during reset**; plus an SCK-from-negedge option (half-clock steps). "2 or 3 likely required at 64 MHz" from tt3p5 measurements | Streams: sequential data continues with CS low; `stall_txn` stops SCK mid-transaction. Reads start at halfword/byte addresses (§8.1). 2-clock minimum between selects of the same PSRAM |
| TinyQV `cpu/qspi_flash.v` | TT09 (Atari 2600 project) | — / clk/2 | — | SPI `EBh`, command on IO0 only (IO1-3 released, needs QE = 1), mode `11h` | fixed, 2 clocks | "Should work up to about 60 MHz project clock on TT06+" |
| **KianV uLinux SoC** `src/qqspi.v` (splinedrive/KianV-RV32IMA-RISC-V-uLinux-SoC `e6f0d3f`) | TT06 | 30 MHz (max tested 34.5; 15 MHz failsafe) / clk/2 | **SPI mode**: `EBh` 8+6+6 wait, `38h` 8+6+data — our framing today | SPI `EBh`, **mode byte left floating** (bus released for all 6 wait clocks) | fixed, 1 clock (sampled at the next SCK rise) — why it tops out near 34 MHz | Word-aligned reads only. Same map as ours: flash `0x2000_0000`, PSRAM `0x8000_0000` 16 MB, UART `0x1000_0000`. **Boots uLinux**: reset PC `0x2010_0000`; flash holds bootloader at 1 MB, DTB at 1.5 MB, kernel+rootfs Image at 2 MB; the bootloader copies the Image to PSRAM (~20 s) and a shell appears after ~120 s |
| tinygpu_v2 `src/spi_flash_controller.v` (pongsagon, `09c0ede`) | ttsky25b, working | 25.175 MHz / **SCK = gated `!clk`** (= clk) | own `35h` at start, then QPI `0Bh` 4 wait, `02h`; long streams (§10) | SPI `EBh`, mode `00h`, 6 wait; drives `0000` through **all** wait clocks on both chips and releases the bus only as data starts | 3-bit strap on `ui_in`, half-clock steps (posedge/negedge buffers); the setting used on silicon is not stated | Uses only PSRAM A. Combinational gated clock output and a tight bus turnaround, both tolerated at 25 MHz on silicon, and both patterns our engine avoids |
| FazyRV-ExoTiny `rtl/wb_qspi_mem.sv` (meiniKi, `c433d40`) | — (not checked) | SCK = `~clk` | own `35h` at reset, then QPI `0Bh` 2+6+4, QPI `38h` | SPI `EBh` continuous read, mode `A5h`, 4 dummy; command dropped after first read | none; samples on the falling edge (~15 MHz SCK limit) | Word-address reads. The closest match to our `flash_spi` fallback |

Models for verification: TinyQV's `test/sim_qspi.v` (tt06-tinyQV
`981d027`) models exactly the recommended scheme — flash in CRM without
a command, PSRAM in QPI `0Bh`/`02h` — plus a clock-delay line for read
latency, but checks no timing or contention; nanoV's `sim_sram.v` is a
1-bit `03h`/`02h` SPI RAM. Our `tb/qspi_pmod_model.v` is stricter (bus
contention, tCEM, tCPH, hand-over states) and should stay the reference;
TinyQV's model is a useful cross-check once the engine speaks the same
protocol (Apache-2.0).

For FPGA bring-up with a real Pmod before tapeout: TinyQV documents
FPGA testing on pico-ice (RP2040 + iCE40, so the same RP2040-side
set-up as the demo board), and the Tang Nano 9k baseboard
(`gfcwfzkm/t9k-baseboard`, four Pmod headers) was suggested in the
threads as a cheap Pmod-compatible FPGA board. Neither was tried here.

Ideas worth borrowing:

* **Straps on the QSPI data pins during reset** (TinyQV). Our pins are
  already released in reset, so the RP2040 could drive `rd_late` (and
  `boot_sel`) on SD0–SD3 and free the dedicated input pins the TT wrapper
  would otherwise spend on them.
* **Half-clock latency steps** (TinyQV's negedge SCK option, tinygpu's
  negedge sample buffers). `rd_late` has whole-clock steps only; a
  half-clock option would widen the window of clock rates that work.
* **SCK stall for streaming** (TinyQV `stall_txn`): hold SCK low with CS
  still asserted while the core catches up. It is the mechanism a future
  streaming fetch needs.

## 12. Open questions (need a human, the TT Discord, or a board)

1. ~~Which parts do shipped Pmods carry?~~ **Answered (§10):**
   TT-built Pmods carry W25Q128JVSIM with QE set by TT QA. Self-built
   Pmods and clones may still differ (-IQ flash `EF 40 18`, non-RBX
   PSRAM); read the JEDEC ID at bring-up.
2. ~~Does TinyQV start flash reads off a 4-byte boundary?~~ **Answered
   (§8.1): yes**, at halfword and byte addresses, on silicon since TT06.
3. **Has anyone run the flash in QPI on this board?** Nobody in the
   threads or the designs surveyed has. §9 takes it anyway, with the
   `flash_spi` strap as the fallback; it is the first thing to try on a
   board (FPGA + real Pmod) before tapeout.
4. **Measured SCK-to-data round trip** on a recent shuttle. What is
   known: TinyQV needs 2–3 clocks of latency at 64 MHz (tt3p5 data);
   KianV, sampling after 1 clock, was tested to 34.5 MHz, so its round
   trip (device output time included) is under about 29 ns; TinyQV's
   author measured the TT mux round trip at a little over 20 ns;
   tinygpu_v2 works at 25 MHz. A
   measurement with and without the 22 pF SCK cap, and with the flash's
   DRV bits at 25 % vs 100 %, would still pin `rd_late` down.
5. **Does the demo board power-cycle the Pmod** when the RP2040 selects a
   different design or resets? (Everything in §7 assumes it does not.)
6. **Is there a -DTR datasheet newer than Rev C (2018-03-27)?** The
   distributor copies are Rev C; winbond.com did not resolve from this
   machine, so its documentation page was not checked.
