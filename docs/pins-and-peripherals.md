# AlphaOneSoC — pins and peripherals

What each of the chip's 24 TinyTapeout I/O pins does, how the demo board and
the Pmods connect to them, and the peripheral RTL that has to be built behind
them.

**Status (2026-11-21, 4x4 branch).** The 3x4 submission has the UART
(`src/uart.v`, polled subset), the GPIO block with the SPI controller
(`src/gpio.v`, `src/spi.v`), syscon and the TinyTapeout wrapper. The 4x4
branch (decision of 2026-11-20, `docs/ROADMAP.md` section 0) adds, all on the
bus and the pins in the committed RTL: a PLIC, a 16550A UART (8-entry RX
FIFO, one TX holding register) with an interrupt, a one-pad gamepad receiver, a
timer/PWM with two comparators, one square-wave audio voice, an output pinmux,
the watchdog interrupt, an instruction cache (K4, `CACHE_CTL`) and the
registered IO read path; and it moves the default pin map. PSRAM line bursts
(`CACHE_CTL.PBURST`, WO-68) are **pending**: TODO, the RTL is not committed.
Block-by-block sizes come from the gate harden. The address map, boot flow
and QSPI engine are in `docs/soc-architecture.md`; what the loader must do
before an OS runs is in `docs/boot-contract-4x4.md`, the device tree in
`docs/devicetree-4x4.dtsi` and `docs/alphaone-4x4.dts`.

The board is the TinyTapeout ETR demo board v3.2
([tt-demo-pcb](https://github.com/TinyTapeout/tt-demo-pcb)), with the
TinyTapeout QSPI Pmod on the bidirectional header. Its RP2350 is wired to
every project pin: `ui_in[0..7]` = GPIO17–24, `uio[0..7]` = GPIO25–32,
`uo_out[0..7]` = GPIO33–40.

## Chip pinout

| Pin | Function | Direction | Connected to |
|---|---|---|---|
| `uio[0]` | QSPI CS0 (flash) | out | QSPI Pmod |
| `uio[1]` | QSPI SD0 | bidir | QSPI Pmod |
| `uio[2]` | QSPI SD1 | bidir | QSPI Pmod |
| `uio[3]` | QSPI SCK | out | QSPI Pmod |
| `uio[4]` | QSPI SD2 | bidir | QSPI Pmod |
| `uio[5]` | QSPI SD3 | bidir | QSPI Pmod |
| `uio[6]` | QSPI CS1 (PSRAM A) | out | QSPI Pmod |
| `uio[7]` | QSPI CS2 (PSRAM B) | out | QSPI Pmod |
| `uo_out[0]` | OLED CS# = GPIO out 0 (pinmux default) | out | OLED CS# |
| `uo_out[1]` | OLED MOSI = GPIO out 1, or SPI MOSI (a pin flop either way) | out | OLED SDIN and SD DI (MOSI) |
| `uo_out[2]` | OLED D/C = GPIO out 2 | out | OLED D/C (moved there, see below) |
| `uo_out[3]` | OLED SCK = GPIO out 3, or SPI SCK (a pin flop either way) | out | OLED SCK and SD SCK |
| `uo_out[4]` | UART TX | out | RP2350 GPIO37 (UART1 RX) |
| `uo_out[5]` | SD CS# = GPIO out 5 (resets high) | out | SD CS# (DAT3), by a jumper wire; the RP2350's GPIO38 (UART1 CTS) is on this pin |
| `uo_out[6]` | OLED RES# and VCCEN = GPIO out 6 | out | OLED RES# and VCCEN |
| `uo_out[7]` | AUDIO (the audio block's PWM DAC) | out | TT Audio Pmod, or the 7-segment DP |
| `ui_in[0]` | `qspi_rd_late` strap during the pin reset (held through reboots), then GPIO in 0 | in | RP2350 GPIO17, or DIP 1 |
| `ui_in[1]` | GPIO in 1, and SPI MISO | in | SD DO (MISO); DIP 2 must be off with the SD fitted |
| `ui_in[2]` | the no-stream strap during the pin reset (held through reboots), then GPIO in 2. 1 = flash streaming off at reset | in | DIP 3 (off = RP2350 pull-down = streaming on) |
| `ui_in[3]` | UART RX | in | RP2350 GPIO20 (UART1 TX) |
| `ui_in[4]` | gamepad LATCH, and GPIO in 4 | in | gamepad Pmod; DIP 5 off |
| `ui_in[5]` | gamepad CLOCK, and GPIO in 5 | in | gamepad Pmod; DIP 6 off |
| `ui_in[6]` | gamepad DATA, and GPIO in 6 | in | gamepad Pmod; DIP 7 off |
| `ui_in[7]` | GPIO in 7 | in | DIP 8 |

**Pinmux.** Each `uo_out` pin has a default function (the table above) and
may take another one by a 3-bit code in the PINMUX register (section 11):
GPIO OUT bit *i*, UART RTS#, AUDIO, or PWM0-3. RTS# exists only as such a
feature now: the default map gives `uo_out[5]` to SD CS#, so flow control
means RTS# on pin 5 and no SD card.

**Reset values.** Every `uo_out` pin is a flop after the pinmux, and all eight
reset to `0x39`: `uo_out[0]` (OLED CS#), `[3]` (SCK, SPI mode 3's idle-high
level, so enabling the transmitter makes no edge), `[4]` (UART TX idle) and
`[5]` (SD CS#) high, `[6]` low (OLED held in reset, panel supply off), `[7]`
(audio) low. GPIO OUT resets to `0xB9`, which is the same on the pins that
default to GPIO plus bit 7 and bit 4 high, so a pin switched to GPIO starts at
its idle level. UART TX, RTS# (when mapped) and the PWM and audio sources
reset to the pin's idle level as well, so the pin flops load `0x39` again on the
first running edge and nothing moves (the TT01 case, `tb/VPLAN.md` 4.2). While
reset is held the QSPI pins are released, as they are today. The same values
hold at a syscon reboot (for two clocks) and for as long as the chip is
powered off, and the QSPI pins are released then too. (The 3x4 submission
drives `0xB9` and RTS# on pin 5.)

## Why this layout

* **`uio` belongs to the QSPI Pmod.** The Pmod's own wiring puts CS0, SCK,
  CS1 and CS2 on `uio[0,3,6,7]`, so four output-only lines occupy
  bidirectional pins. That is unavoidable without rewiring the Pmod, and CS0
  and SCK have to stay there anyway. TinyTapeout programs the flash from the
  RP2350 through the BIDIR header, with the chip-ROM project selected. The chip
  always drives its `uo_out` pads, so a line the RP2350 also has to drive
  cannot be on `uo_out`. Moving only CS1/CS2 would trade two outputs for two
  bidirectionals, and outputs are the scarce pins.
* **The console goes through the RP2350's UART terminal.** TX and RX
  therefore take the first of TinyTapeout's listed UART pairs
  (<https://tinytapeout.com/specs/pinouts/>): `ui_in[3]` RX, `uo_out[4]` TX.
  On the RP2350 these are plain UART1 function pins (GPIO20 TX, GPIO37 RX).
  The other listed pair (`ui_in[1]`, `uo_out[0]`) needs GPIO18's auxiliary
  UART function. GPIO38, the demo board's UART1 CTS pin, is `uo_out[5]`: RTS#
  can be mapped there as a pinmux feature, but the default gives the pin to
  SD CS# (below), so the RP2350's UART1 runs without CTS.
* **Outputs are the scarce pins.** After TX, seven outputs remain. The OLED
  needs five of them once PMODEN and VCCEN are tied off (below), the SD card's
  CS# one more (the rest of the SD card shares the OLED's SPI lines), and the
  audio PWM one. That is the default map; the pinmux moves any of them.
* The OLED's SPI lines keep their Pmod positions (CS# 0, MOSI 1, SCK 3), so
  the SPI transmitter can take over MOSI and SCK without moving anything.
* **The TT Audio Pmod sits on the OUT header and passes `out[0-6]` through**,
  so the OLED adapter stacks on it and the audio PWM on `uo_out[7]` reaches the
  Pmod's filter and jack. The gamepad Pmod takes `ui_in[4..6]`, which replaces
  the keypad rows (the keypad is no longer a board setup).

## Board setups

The TT Audio Pmod sits on the OUT header (it passes `out[0-6]` through) and
the OLED connects by jumper wires: either stacked through the PmodTPH2
adapter below, or wired directly to the same `uo_out` pins. The gamepad Pmod
goes on the IN header.

### OLED (PmodOLEDrgb): the primary display

The OLED goes through a PmodTPH2 used as a fixed adapter. The TPH2 is a
straight 12-line pass-through with a test pin on top of each line. Three of
its lines are cut off from the demo board and rejoined with jumpers:

1. Isolate TPH2 pins 7, 8 and 10 from the OUT header: clip them, or sleeve
   their tips (heat-shrink or Kapton) so they do not contact the socket.
2. Fit female–female jumpers between TPH2 test pins:
   * **7 → 3**: D/C moves onto `uo_out[2]`, the slot of the OLED's
     unconnected pin 3.
   * **8 → 9**: RES# joins VCCEN on `uo_out[6]`.
   * **10 → 12**: PMODEN goes to 3V3.
3. Plug the OLED into the TPH2, and the TPH2 into OUT.

| OLED signal | OLED pin | Goes to |
|---|---|---|
| CS# | 1 | `uo_out[0]` |
| MOSI | 2 | `uo_out[1]` |
| SCK | 4 | `uo_out[3]` |
| D/C | 7 | `uo_out[2]` |
| RES# and VCCEN | 8, 9 | `uo_out[6]` |
| PMODEN | 10 | 3V3 (always on) |

OUT pins 7, 8 and 10 (TX, SD CS#, AUDIO) then reach nothing on the OLED side;
the RP2350 reads TX through the board, the SD CS# goes by a jumper from OUT
header pin 8 (not pin 10) to the card, and the audio output is on the Audio
Pmod's pin.

What the two ties do:

* **PMODEN** switches the ground of the OLED's logic supply. Tied high, the
  controller is powered whenever the board is. All that is lost is the
  ~200 nA power-down mode.
* **VCCEN** enables the panel's 14 V boost converter. Tied to RES#, the panel
  supply rises when the controller leaves reset and falls when it enters
  reset. This follows the SSD1331 power-on order: VDD, a reset pulse, then
  VCC, with display-on after VCC settles. *Confirm against the SSD1331
  datasheet.*
  * Driver sequence: reset low for ≥3 µs, reset high, initialisation
    commands, wait ≥100 ms, display on (`AFh`).
  * To power down: display off (`AEh`), then reset low.
  * Chip reset drives `uo_out[6]` low: controller in reset, panel off.

### Gamepad (SNES Pmod): ui_in[4..6]

The TT gamepad Pmod goes on the IN header's bottom row: LATCH on `ui_in[4]`,
CLOCK on `ui_in[5]`, DATA on `ui_in[6]`. DIP 5-7 must be off. The receiver
(section 10) is `src/gamepad.v`. The PmodKYPD is no longer supported by the
default map: its rows were `ui_in[4..7]` and its columns `uo_out[0..3]`.

### Board rules

* **DIP switches 4–7 off.** DIP 4 sits on UART RX, and 5–7 on the gamepad
  Pmod's lines (a DIP that is on adds a 1 kΩ pull-up to a line the Pmod
  drives). DIP 8 is GPIO in 7.
* **An off DIP leaves its pin floating.** The switches pull up through 1 kΩ
  and nothing pulls down. The RP2350 drives `ui_in[0]` (the read-latency
  strap), since it chose the clock. It should also pull down `ui_in[1..2]`
  if they are used as inputs with their DIPs off, except `ui_in[1]` with the
  SD card fitted: the card drives MISO there, and the RP2350 pin must be an
  input with no pull-down (see the SD notes below). A floating `ui_in[2]`
  can only make flash reads slower (streaming off), never unbootable.
* **RP2350 UART.**
  * UART1 on GPIO20 (TX) and GPIO37 (RX), **without CTS** by default: GPIO38
    is `uo_out[5]`, the SD card's CS#, so it must be an input with no UART
    function. Flow control needs RTS# mapped to pin 5 (PINMUX code 2), which
    gives up the SD card; then CTS on GPIO38 works as before. Without it,
    the 8-deep RX FIFO is the only margin (section 2).
  * Do **not** enable its RTS: GPIO23 is `ui_in[6]`, the gamepad DATA line.
  * Leave GPIO21–24 as inputs.
* **Flash hand-over.** A master that hands the QSPI Pmod to this design must leave the flash
  **idle** (no program, erase or status write running, nothing suspended), **not in deep power-down**
  (`B9h`), **without a `77h` burst wrap** (W4 = 1, the power-up default) and with **QE = 1**. Our
  start-up sequence undoes continuous-read mode (quad, dual and DTR) and QPI, and nothing else. A
  flash in any of the other states gives a boot failure with no diagnosis, and a wrap gives silent
  wrong fetches. TinyQV makes the same assumption (tier 1, silicon). Details and sources:
  `docs/qspi-memories.md` section 7.3a.
* **7-segment display.** It is wired to every `uo_out` through solder
  jumpers JP1–8, so it flickers with the traffic. Cut the jumpers to stop
  that. `uo_out[7]` (segment DP) is the audio PWM, `uo_out[5]` the SD card's
  CS#; neither is a heartbeat LED.

## Peripheral RTL

| # | Block | Where | Status | Size | Linux |
|---|---|---|---|---|---|
| 1 | TinyTapeout wrapper | `src/tt_um_alfadelta10010_alphaone_soc.v` | built; `uo_out` from the pin flops, `0x39` in reset | 2 flops, about 10 gates | — |
| 2 | UART | `0x1000_0000`, `src/uart.v` | built: 16550A, RX 8 / THR 1, trigger 1/2/4/7, interrupt 1 | gate harden | `ns16550a` (8250 driver), interrupt 1 |
| 3 | GPIO | `0x1001_0000`, `src/gpio.v` | built; OUT bits 4-5 real, reset `0xB9`, reads return the GPIO outputs | 0.12 tiles, 39 flops, with 4 | `wd,mbl-gpio` (gpio-mmio) |
| 4 | SPI transmitter | `0x1001_0020`, inside the GPIO block | built; tiny_spi IRQ enables (PLIC 2, not in the DT) | (in 3) | `spi-oc-tiny` |
| 5 | Gamepad | `0x1001_0010`, `src/gamepad.v`, carved out of the GPIO window by `soc_bus` | built; one pad (pad 0) | gate harden | none (bare metal) |
| 6 | PLIC | `0x0C00_0000`, `src/plic.v` | built; 9 sources, 1 context | gate harden | `sifive,plic-1.0.0` |
| 7 | PWM | `0x1003_0000`, `src/pwm.v` | built; 2 of 4 comparators (cmp2/3 read `0xFFFF`) | gate harden | `pwm-sifive` |
| 8 | Audio | `0x1003_0100`, `src/audio.v` | built; one square voice | gate harden | none (bare metal) |
| 9 | Pinmux | `0x1002_0020`, `src/pinmux.v`, carved out of the syscon window | built | 2,560 µm² synth, 32 flops | `pinctrl-single` |
| 10 | Instruction cache | `src/cache.v`, `CACHE_CTL` at `0x1002_0024` | built (K4); PBURST pending WO-68 | one `rf_top` macro + flops | none (loader) |
| 11 | Bus and top-level changes | `soc_bus.v`, `alphaone_soc.v` | built; registered IO read path | one state flop and a 32-bit register, 632 µm² (measured) | — |
| 12 | syscon | `0x1002_0000`, `src/syscon.v` | built | 0.151 tile, 23 flops (0.078 and 14 without the watchdog) | `syscon` + `syscon-poweroff`, `syscon-reboot`, `syscon-reboot-mode`, plus `snps,dw-wdt` for the watchdog at `0x1002_0100` |

Sizes: yosys + abc against `libs/sky130_fd_sc_hd__tt_025C_1v80.lib`, each
block synthesised on its own with the audit's recipe; 1 tile ≈ 11,300 µm² of
standard cells at TinyTapeout's 60% density (UART 3,321 µm², GPIO 1,380 µm²).
The recipe runs about 20-24% below LibreLane's synthesis (`docs/area-audit.md`).
The per-block figures that remain are LibreLane synthesis of the committed
RTL (area-agent, 2026-11-20); the figures after the trims (UART, PWM, audio,
gamepad, cache) are the gate harden's (`localFiles/wo-4x4/INDEX-4x4.md`
section 4 has the planning budget). The bundle routes under the 3x4 ceiling
only with the registered IO read path (measured: combinational read data GRT
78.26 % / overflow 4,290, registered 66.04 % / 16).

### 1. TinyTapeout wrapper

`src/tt_um_alfadelta10010_alphaone_soc.v`, module
`tt_um_alfadelta10010_alphaone_soc`.

* **Reset is asserted asynchronously and released synchronously.** `rst`, the
  SoC's active-high reset, is set by `rst_n` itself, with or without a clock,
  and cleared by the second clock edge after `rst_n` rises.
  * It has to be set without a clock. The demo board's firmware, loading a
    project for the first time since it booted and finding no section for it
    in its `config.ini`, stops the clock, pulses `rst_n` low for 2 ms and
    only then starts the clock (`tt-micropython-firmware`, `demoboard.py`:
    `clock_project_stop()`, `_first_encouter_reset()`,
    `clock_project_PWM()`). A reset that waited for a clock edge would never
    see that pulse. The other ways the board resets a project, and the ways
    it does not, are listed below.
  * Those two edges are what carries the reset into the SoC's flops, so any
    pulse on `rst_n` resets the chip, however short.
  * The pins leave reset on the second edge as well, one edge after the SoC's
    flops first take their reset values. They are gated by `run`, a flop of
    their own that rises on the edge `rst` falls. After a reset with the clock
    running this changes nothing: the flops took their reset values long
    before. After one with the clock stopped, edge 1 is where they take them,
    and pins opened on that edge would race them for about a nanosecond.
    TinyTapeout confirmed (Discord, 2026-10-23) that the clock is not
    guaranteed to run during reset and that such a glitch reaches the pin; a
    few ns of contention on `uio` with the RP2350 is harmless. `run` also
    loads 0 on the edge where `rst_n` is released, so that release cannot
    make it metastable. No RTL bench can tell the second edge from the first
    (mutant TT01, `tb/VPLAN.md` 4.2): keep it.
  * `ena` is unused.
* **While `rst` is high the pins depend on neither a clock nor on what the
  SoC's flops powered up with:**
  * `uio_oe` is 0. Every bit is ANDed with `!rst`: bits 0, 3, 6, 7 =
    `qspi_ctl_oe`, bits 1, 2, 4, 5 = `qspi_io_oe`. So whoever holds the chip
    in reset owns the QSPI bus without needing a clock, and the pins stay
    inputs after `rst_n` rises until the SoC has really been reset.
  * `uo_out` is `0x39`, the pin flops' own reset values (OLED CS#, SCK, UART
    TX and SD CS# high; RES#/VCCEN and AUDIO low: the OLED held in reset with
    its panel supply off). Nothing moves when `rst` falls, because the SoC is
    driving the same values by then. (The 3x4 submission drives `0xB9`,
    with RTS# on bit 5.)
* `uio_out`: `[0]` cs_n[0], `[1]` io_out[0], `[2]` io_out[1], `[3]` sck,
  `[4]` io_out[2], `[5]` io_out[3], `[6]` cs_n[1], `[7]` cs_n[2].
* `qspi_io_in` = `{uio_in[5], uio_in[4], uio_in[2], uio_in[1]}`. The other
  four `uio_in` bits are unused; SCK's floats while the pins are released.
* `ui_in` as in the pinout table. `qspi_rd_late` = `ui_in[0]`, straight from
  the pin; the QSPI engine samples it on every clock edge while `rst` is
  high, the last of them the second edge after `rst_n` rises. **Hold
  `ui_in[0]` until then.** `ui_in[2]` is the no-stream strap, read the same
  way (`qspi_no_stream`): 1 resets syscon's QSPI_CFG.STREAM to 0, 0 to 1. The
  whole `ui_in` byte also feeds GPIO IN.
  syscon latches the strap while `rst` is high (the same window: every edge up
  to the second after `rst_n` rises) and the QSPI engine uses that copy
  afterwards, so a reboot does not re-read the pin. The no-stream strap is
  latched in the same window, and every reboot or watchdog reset restores
  QSPI_CFG from that copy.
* **A reboot or power-off is generated inside the SoC**, so the wrapper's
  `run` gating applies to `rst_n` only. The pins still go to their reset
  values: the QSPI pins are released by the engine's own registered output
  enables (each `uio_oe` bit is that flop ANDed with `run`, which stays 1), and
  `uo_out` goes to `0x39` on the same edge. With the pinmux every `uo_out` bit is
  one flop through the `run` gate (the structural `spi_f12` harness covers all
  eight pins), which removes the sub-nanosecond hazard
  the 3x4 design has on `uo_out[1]` and `uo_out[3]` while the SPI transmitter
  is on (a mux whose select and data change on that edge).
* The demo board starts the clock by itself only if the project's `clock_hz`
  in `info.yaml` is not 0. With 0 the clock has to be started by hand, or
  from a `config.ini` section for the project.

**Selecting the project does not reset it. Reset it after every selection**
(Reset in the TinyTapeout commander). An unselected project has `clk`,
`rst_n`, `ui_in` and `uio_in` tied to 0 and its power switched off, both by
the same enable (`tt-multiplexer`, `rtl/tt_mux.v`), so at selection it powers
up with `rst_n` already high and starts from whatever its flops powered up
with. Until the first reset the SoC may drive the QSPI pins and `uo_out` from
that state; the RP2350's `uio` pins are inputs by then (below). What each
board action does, from the sources as of 2026-10-24:

| Action | Clock while `rst_n` is low | Reset? |
|---|---|---|
| Firmware loads the project for the first time since boot, no `config.ini` section | none: stopped, 2 ms pulse, then started if `clock_hz` is set | yes (the case the second edge is for) |
| Firmware loads it with a `config.ini` section (also written by the commander's "Make default") | running: `clock_frequency` starts it before the pulse | yes, unless `start_in_reset` holds it |
| Firmware selects it again in the same session | - | **no** (`_first_encouter_reset` runs once per project per boot) |
| Commander selects it (`ttcontrol.py` `select_design`) | - | **no** (it turns the firmware's config handling off) |
| Commander Reset (`ttcontrol.py` `reset_project`) | 10 clocks, released with the clock stopped, then restarted | yes |
| `tt.reset_project(True)` / `(False)` from the REPL | whatever the clock is doing; only the pin moves | yes |
| The demo board's reset button | whatever the clock is doing; the contacts bounce | yes |

Every selection, by the firmware or the commander, first sets all the
RP2350's `uio` pins to inputs (`project_mux.py`, `safe_bidir()`), so after
programming the flash with the chip-ROM project selected the RP2350 has let
go of the bus before this project is selected.

`make test-wrapper` (`tb/tb_tt_um.v`, `tests/soc/tt_pins.S`) checks all of
this through the pins alone, with the board wired from the pinout table
above: the Pmod model on `uio` with pulled-up chip selects and floating SCK
and data, and the RP2350's UART. The program is reset three times and has to
start again each time: the firmware's way (clock stopped, pulse, clock
started), in the middle of a flash read with the clock running, and by a
pulse shorter than a clock. The pins are checked in reset and on each of the
three clock edges that follow it. Then every GPIO pin in both directions,
which chip select each PSRAM answers on, and the strap in both positions,
changed at the first moment it is allowed to (pin expectations are `0x39`,
no RTS# on `uo_out[5]`). Because the bench refers to
nothing inside the design, it also runs on a gate-level netlist of the top
level.

### 2. UART at `0x1000_0000`

A 16550A subset (`src/uart.v`), trimmed to fit the 4x4 area: an 8-entry RX FIFO, a
single TX holding register (THR) in front of the shifter, RX trigger codes 1/2/4/7
bytes. The registers are
**byte-wide** (`reg-shift = 0`, `reg-io-width = 1`), the layout Spike
(`spike --dump-dts`) and QEMU's `virt` board use at the same address, so one
kernel and a near-identical device tree run on Spike and on the chip. The
frame is fixed at 8N1, and baud = clk / (16 × divisor). (The 3x4 submission
has the earlier polled subset.)

| Offset | Read (DLAB=0) | Write (DLAB=0) | DLAB=1 |
|---|---|---|---|
| 0 | RBR (head of the RX FIFO, 0 when empty; pops) | THR (the TX holding register) | DLL |
| 1 | IER: bit 0 ERBFI, 1 ETBEI, 2 ELSI, 3 EDSSI | IER | DLM |
| 2 | IIR: `{FEN, FEN, 2'b00, IID[3:0]}` | FCR: bit 0 FEN, 1 clear RX, 2 clear THR, bits 7:6 RX trigger code | — |
| 3 | LCR (only DLAB, bit 7, and SBC, bit 6, are kept) | LCR | LCR |
| 4 | MCR: LOOP, OUT2, OUT1, RTS, DTR; **resets to `0x02`** | MCR | — |
| 5 | LSR: bit 0 DR, 1 OE, 3 FE, 4 BI, 5 THRE, 6 TEMT, 7 FIFOERR | — | — |
| 6 | MSR: `0xB0` (CTS, DSR, DCD asserted); in loopback, the MCR outputs | — | — |
| 7 | SCR (8-bit scratch, resets 0) | SCR | — |

RBR pops only on a load whose byte enable selects offset 0. The core drives
`dmem_be` on loads too.

* **FIFOs.** RX 8 entries of 9 bits (8 data bits and an error flag: a break
  is the flag with data 0, a framing error the flag with data != 0); TX is
  one holding register, THR (IIR[7:6] still reads 11 so autoconfig sees
  FIFOs). FCR[7:6] pick the RX trigger **1, 2, 4 or 7** bytes for codes 0-3
  (with FEN clear, 1; the FIFO buffers either way). Linux's FCR `0x81`
  (code 2) therefore means 4 bytes here, not the 16550A's 8. A write that
  changes FEN clears the RX FIFO and THR; FCR bits 1 and 2 clear one each (a
  frame already in the shifter finishes).
* **Interrupt, IRQ 1.** `irq` is IIR[0] == 0, a level, from flops. IID
  priority: `0x6` receiver line status (ELSI and OE or an error at the head),
  `0x4` received data (ERBFI and the trigger level reached), `0xC` character
  timeout (ERBFI, the FIFO not empty and nothing pushed or popped for four
  character times), `0x2` THR empty (ETBEI and the TX FIFO empty), else
  `0x1`. THRE is a level: reading IIR does not clear it. OUT2 does not gate
  the interrupt (neither Spike nor QEMU gates it).
* **Loopback** (MCR bit 4): TX is held high, the transmit shifter feeds the
  receiver, and MSR shows the MCR outputs.
* **Transmit back-pressure.** A write to THR while THR is full does not
  complete: the UART holds `ready` low (only while selected) until the
  shifter takes the character, and the write lands one clock after the take,
  so the bus paces the driver at line rate (the CPU waits up to one frame,
  about 87 µs at 115,200 baud). With the interrupt, the DT's `fifo-size = <8>`
  and `tx-threshold = <7>` make the 8250 driver's `tx_loadsz` = 1, so it
  writes one byte per THRE interrupt and never waits on a full THR. The
  divisor must reset to a non-zero value, so a THR write can never stall
  forever.
* **RX sampling:** two-flop synchroniser, 16x oversampling, start bit checked
  at mid-bit, as today. The receiver does not wait for an empty RBR.

**Departures from a PC16550D.**
* MCR resets to `0x02` (RTS = 1), not `0x00`; it only matters when RTS# is
  mapped to a pin.
* THRE is level and not cleared by an IIR read; Linux's `__stop_tx` clears
  ETBEI when it has nothing to send, and its THRE test needs the interrupt on
  both IIR reads.
* BI and FE belong to the head entry: an LSR read acknowledges them (and the
  receiver-line-status interrupt, as a 16550 does: BI/FE then read 0 and the
  FIFOERR count drops that entry), but the entry itself stays until the RBR pop.
  OE is sticky until an LSR read.
* MSR has no delta bits, so the modem-status interrupt never fires.
* A frame with a bad stop bit and any data bit 1 is a framing error, queued
  with the error flag (the polled subset dropped it). A frame whose every bit
  reads 0, stop bit included, is a break: it queues `{1, 0x00}`, so DR is
  set with RBR = 0, as a 16550 loads one zero character. Linux counts breaks
  and takes the magic SysRq key from BI. After a break the line must be high
  for half a bit before a start bit counts, so a short glitch inside a long
  break is not a second break.
* FIFO mode off still buffers (a 16450 would overrun at the second character).
* RX trigger codes 1/2/4/7 (not 1/4/8/14) and one THR instead of a TX FIFO,
  so `rx_trig_bytes` in sysfs reads back the 16550A table, not ours.
* The character-timeout interrupt (`0xC`) fires after 4 character times with
  data in the FIFO and nothing pushed or popped.
* LCR stores only DLAB and SBC; its other bits read 0. SBC (bit 6) sends a
  break: TX is held at 0 from the next 16x tick until SBC is cleared
  (`serial8250_break_ctl`). RBR resets to 0 so Linux's start-up read cannot
  see an X. The divisor resets to 34, 114,890 baud (-0.27% from 115200) at
  62.5 MHz, so a program in flash can print before it sets the divisor
  (`alphaone_soc`'s `UART_DIV_RESET`); a divisor of 0 behaves as 1. Every
  register write waits for `ready`, so a word store that writes THR and LCR
  together while the FIFO is full writes LCR once, when THR is taken.

**RX without RTS# (the default map).** At 114,890 baud a character is 87 µs.
The 8-deep FIFO leaves, after the trigger (4 bytes for Linux's code 2), room
for 4 more characters plus the one being shifted in: **5 character times,
about 435 µs, before an overrun**. Linux reaches the 8250 handler in roughly
0.3-0.7 ms at 1.5 MIPS, so typing is fine and bursts are lossless only while
the interrupt is served within that slack (a polled printk of 9 or more
characters masks interrupts for 87 µs each). **A sustained 115,200 stream
into Linux is not carried without flow control**: n_tty costs about
0.15-0.3 ms per character against 0.087 ms of arrival. Bare metal or FreeRTOS
draining in the ISR (about 30 µs a character) carries it continuously. For
sustained input, map RTS# to `uo_out[5]` (no SD card; RTS# is asserted while 2 or
more entries are free and deasserts when 1 is left) or lower the baud rate; otherwise set the trigger to 1 byte
(the sysfs `rx_trig_bytes` file only offers the 16550A table's 1/4/8/14, so
the init script writes `1`: sysfs values 1-3 select FCR code 0, which is 1 byte
here; 4-7 select code 1, 2 bytes; the file reads back 8 while the hardware
uses 4).

Device tree (`docs/devicetree-4x4.dtsi`, included by the board file
`docs/alphaone-4x4.dts`): `compatible = "ns16550a"`, `reg-shift = <0>`,
`reg-io-width = <1>`, `clock-frequency` = the core clock, `fifo-size = <8>`,
`tx-threshold = <7>`, `interrupts = <1>` on the PLIC. `8250_of.c` sets
`UPF_FIXED_TYPE`, so autoconfig never overwrites `fifosize` and `tx_loadsz`
with the 16550A table's 16/16. (The 3x4 polled UART had no `interrupts`;
`platform_get_irq()` then logged `error -ENXIO: IRQ index 0 not found` at
every boot, expected and harmless.)

Early console: `earlycon=uart8250,mmio,0x10000000,115200,<core clock in Hz>`,
or `earlycon=uart8250,mmio,0x10000000` with no baud at all. The clock
matters: given a baud and no clock, `drivers/tty/serial/earlycon.c` assumes
`BASE_BAUD * 16` = 1.8432 MHz and `8250_early.c` programs divisor
1843200 / (16 × 115200) = 1, which on this chip is clk/16 (3.906 Mbaud at
62.5 MHz). With no baud, `8250_early.c` leaves the divisor alone and the
UART runs at whatever it holds -- 114,890 baud at 62.5 MHz straight out of reset,
or whatever the boot loader set. A plain `earlycon` with `stdout-path` in
the device tree takes `clock-frequency` from the node and is also right.

### 3. GPIO at `0x1001_0000`

The window is decoded on `addr[5:2]`: 16 word slots that alias every 64 bytes
through the 64 KB. Writes take byte lane 0 only. Reserved slots read 0 and
ignore writes.

| Offset | Register |
|---|---|
| `0x00` | OUT (read/write). Bit *i* is the GPIO output *i*: it reaches `uo_out[i]` while the pinmux selects GPIO for that pin (the default for bits 0-3 and 6, and the SD CS# on bit 5; bit 4 is the UART's pin and bit 7 the audio's by default, so those two bits are only the GPIO source of the pinmux). **Reads return the GPIO outputs, not the pads**, since the pad is a pinmux flop after a mux. Bits 1 and 3 are the SPI engine's MOSI and SCK flops: with EN = 1 the SPI engine drives them and OUT writes to them are ignored. **Resets to `0xB9`.** (Bits 4 and 5 are real; the 3x4 design reads them as 0 and resets to `0x89`.) |
| `0x04` | IN (read only). `ui_in[7:0]` through a two-flop synchroniser. |
| `0x08` | reserved |
| `0x0C` | SPICTL. Bit 0 EN (resets 0): 1 = the SPI engine owns `uo_out[1]` and `uo_out[3]`. Bit 8 BUSY (read only) = not TXE. |
| `0x10` | GAMEPAD (read only), section 10; decoded in `soc_bus`, `gpio.v` never sees it |
| `0x14` | GPSTAT, section 10; same carve |
| `0x18` | IN_IE (read/write, `[7:0]`, resets 0): per-bit enable of the input-change interrupt (PLIC source 4). |
| `0x1C` | IN_IP: read `[7:0]` = pending edges. Bit *i* sets on **either** edge of the synchronised `ui_in[i]`, whatever IN_IE says; a write with lane 0 clears every bit written as 1 (W1C); an edge in the same clock as the clear of its bit wins. Resets to 0 (reset and syscon reboot leave no phantom edge with a pin held high). `in_irq = |(IN_IP & IN_IE)`, a level. Neither slot ever stalls. |
| `0x20`-`0x30` | the SPI controller, section 4 |
| `0x34`-`0x3C` | reserved |

Input-change interrupt (PLIC source 4, bare-metal and FreeRTOS): clear IN_IP, then set IN_IE; an edge seen
while disabled stays pending and fires when its enable is set. With the gamepad Pmod fitted, `ui_in[4..6]`
toggle every frame: leave IE[6:4] at 0 and use GPSTAT's interrupt (source 3). IE[1] is the SD card's MISO
and toggles with every byte while the SD is in use: leave it 0 then. IE[3] is the UART RX pin: a start bit
is a falling edge, so it wakes a `wfi` on the first character's start bit (the byte arrives later: read it
after the UART's own interrupt). Linux's gpio-mmio driver has no interrupt support, so Linux does not use it.

Setting EN (0 to 1) moves SCK from OUT bit 3 to CPOL on that edge, so it can
create an SCK edge: set EN only with every CS# high. Clearing EN leaves the
pins as they are.

The flash loader sets EN before it enters the kernel on an SD/OLED board;
Linux never writes it. A reboot in the middle of an SD block leaves the card
mid-transfer: boot code must clock `0xFF` with CS# low until the card returns
`0xFF`, then send CMD0 (Linux's `mmc_spi` does the clocking).

SD first: after power-up the card is in SD (native) mode, where it reads
MOSI as its CMD line whatever its CS# says. OLED bytes can then form a valid
command frame (start bit, CRC7, end bit), and the card answers on that same
wire against the chip's MOSI driver. So the flash loader, on every boot and
before any other SPI traffic, clocks at least 74 cycles (10 bytes of `0xFF`)
with both CS# high, then sends CMD0 with SD CS# low, which puts the card in
SPI mode. Linux's probe order cannot guarantee this, so it belongs to the
loader.

Linux uses the generic gpio-mmio driver: one output-only chip (`gpo`, OUT) and
one input-only chip (`gpi`, IN), bit *i* = OUT or IN bit *i*
(`docs/devicetree-4x4.dtsi`). The SPI chip selects are `cs-gpios = <&gpo 0 1>,
<&gpo 5 1>` (OLED, SD, both active low).

### 4. SPI controller (tiny_spi) at `0x1001_0020`

A general SPI master for the SD card and the OLED on one bus, inside the GPIO
block (`src/spi.v`). Its registers have the semantics of OpenCores
`tiny_spi`, so Linux's `drivers/spi/spi-oc-tiny.c` (compatible
`opencores,tiny-spi-rtlsvn2`) drives it unchanged, polled, with the chip
selects as `cs-gpios` on GPIO OUT (OLED CS# = bit 0, SD CS# = bit 5; D/C =
bit 2 and RES# = bit 6 are `dc-gpios` / `reset-gpios`).

| Offset | Register |
|---|---|
| `0x20` | RXDATA (read): the byte received with the last byte sent; valid once TXE = 1. |
| `0x24` | TXDATA. Write: queue a byte (waits while the holding register is full). Read: that register, i.e. the byte written but not yet loaded, or after a load the byte received with the byte before. |
| `0x28` | STATUS. Read: bit 0 TXE = engine idle and holding register empty, bit 1 TXR = holding register empty. Write: `{txren, txeen} <= wdata[1:0]`, the interrupt enables; **a STATUS write never waits**. |
| `0x2C` | CONTROL: bit 0 CPHA, bit 1 CPOL. All four modes; resets to 3 (mode 3). |
| `0x30` | BAUD, 8 bits, resets to `0xFF`. SCK = clk / (2 x (BAUD + 1)): 122 kHz to 31.25 MHz at 62.5 MHz. |

* Polled loop, as the driver runs it: write TXDATA(b0); for each further
  byte write TXDATA, wait TXR, read TXDATA; at the end wait TXE and read
  RXDATA.
* **Back-pressure.** A TXDATA write waits only while the holding register is
  full. Every other write (OUT, SPICTL, CONTROL, BAUD, STATUS, reserved slots)
  waits for TXE, so `TXDATA; OUT` back to back is safe: the OUT store lands at
  least one SCK half-period after the last sampling edge (the SSD1331's tCSH
  60 ns and tAH 40 ns), and a change of mode, BAUD or EN cannot cut a phase
  short. Reads never wait.
* **Timing.** A byte takes exactly 16 x (BAUD + 1) clocks and bytes run back
  to back. MOSI changes only at a launch edge, from a flop, so the device gets
  BAUD + 1 clocks of setup and hold. MISO is sampled one core clock before
  the edge that ends each bit, from GPIO IN 1's first synchroniser flop.
  The SSD1331 needs 75 ns phases: BAUD >= 5 at 62.5 MHz. The SD card is
  capped at 10.4 MHz in the device tree (BAUD 2). **BAUD 1 is lost
  to the pin flop**: MOSI and SCK both move one clock
  later, so device timing is unchanged, but the MISO sample point is
  internal and the round trip loses one clock (16 ns). At BAUD 2 the card
  keeps 28 / 23 / 18 ns of margin for round trips of 20 / 25 / 30 ns; at
  BAUD 1 it goes negative. Never use BAUD 0 to receive.
* **Modes.** The driver writes CONTROL and BAUD before every transfer with
  the mode of the last device set up, so run both devices in mode 3.
* Device tree: `baud-width = <8>` and `clock-frequency` are both required.
* **Interrupt.** As tiny_spi: `irq = (TXR & txren) |
  (TXE & txeen)`, PLIC source 2. **The device tree leaves `interrupts` out**:
  `spi-oc-tiny` then takes one interrupt per byte, about 1 ms each against a
  48-clock byte at BAUD 2, and polling is faster.
* Departures from the tiny_spi RTL: a TXDATA write to a full holding register
  waits (tiny_spi overwrote it); TXE also needs the holding register empty;
  STATUS writes never wait; CONTROL, BAUD and the data registers have
  reset values.
* A reset or reboot in the middle of A in mode 3 raises SCK on the same edge as
  SD CS#; the frame is abandoned either way.

#### Board setup: SD card + OLED

* PmodMicroSD J1: 1 CS, 2 MOSI, 3 MISO, 4 SCK, 5/11 GND, 6/12 3V3, 7 DAT1,
  8 DAT2, 9 CD (confirm against Digilent's reference manual).
* MOSI, SCK to both devices; MISO (`ui_in[1]`) from the card's DO; SD CS# from
  `uo_out[5]` by a jumper wire from OUT header pin 8 (the OLED adapter clips
  that pin; the old pin 10 is now audio). Keep the wires short, or fit 33 ohm series resistors, and scope SCK at the card.
* A 10-100 kohm pull-up on MISO on the card side (the card tri-states DO while
  deselected); check whether the Pmod has one. RP2350 GPIO18 must be an input
  with no pull-down.
* DIP 2 off with the SD fitted (its 1 kohm pull-up loads DO).

### 5. Bus and top level

* `soc_bus.v`: **every IO target's read data reaches the core through a
  register** (decision D14, `localFiles/wo-4x4/INDEX-4x4.md`).
  One state flop `ph` and a 32-bit `io_q`: the selects are high only in phase
  1, the target acts and `io_q` captures on the edge where `sel && ready`, and
  `d_ready = ph` one clock later with `io_q`; the selects are low in phase 2,
  so an RBR pop, a PLIC claim, a W1C or a write acts exactly once. The
  memory path is unchanged. The cost is one clock per IO access (polled loops
  2-5 % slower, benchmarks unaffected); the gain is routing (above) and the
  IO `ready` into the core's stall path becomes a flop. `ready` still comes
  from the UART and GPIO/SPI back-pressure, and an IO target may hold it
  low only on a cycle its own select is high, so the bus ANDs the readies.
  The new targets (PLIC, PWM, audio, gamepad, pinmux) never hold `ready` low.
* `alphaone_soc.v`: ports `uart_rx`, `gpio_in[7:0]`, `uo[7:0]` (the pin flops)
  and the old `uart_tx`, `uart_rts_n`, `gpio_out[7:0]` as pre-mux taps for the
  benches. The wrapper maps `uo` onto `uo_out` and the
  input byte onto `ui_in` as in the pinout table.
* `syscon` (`0x1002_0000`, `src/syscon.v`) decodes its own offsets in full
  and never holds `ready` low. `alphaone_soc` resets every other block from
  `rst_soc` (the chip reset, or a syscon reboot for two clock edges, or
  power-off until the chip reset); the chip reset `rst` resets only syscon's
  RESET_CAUSE, BOOT_MODE, strap and reboot flops.

### 6. syscon at `0x1002_0000`

The register map, the reset architecture, the reboot timeline and the device
tree are in `docs/soc-architecture.md`, section "syscon". What faces the pins:

* **Reboot** (a FINISH write of `0x7777`): the SoC is in reset for two clock
  edges. The QSPI pins are released for those two clocks, the control pins
  (SCK and the chip selects) come back driven idle on the first running edge,
  and the start-up sequence runs again, so the board sees what it sees after
  `rst_n` rises. `uo_out` is `0x39` through it (the 3x4 design: `0xB9`), then follows the pin flops.
* **Power-off** (`0x5555`, or `0x3333`): the same values held until `rst_n`.
  The QSPI pins stay released, so the Pmod's pull-ups deselect the flash and
  both PSRAMs; `uo_out` stays `0x39` (UART idle, SD CS# high, the OLED in
  reset with its panel supply off, audio low). The clock keeps running. Only `rst_n`
  wakes the chip.
* **The strap** is read once, at the pin reset, and kept (see the wrapper
  section). The pin is GPIO afterwards.
* **The watchdog** (`0x1002_0100`, DesignWare layout) resets the SoC through
  the reboot path when it expires, so the pins behave as for a reboot. It is
  disabled again afterwards, since its flops are on `rst_soc`. It cannot fire
  while the chip is powered off.
* The RP2350 reads no syscon state from the pins; software reads
  RESET_CAUSE, BOOT_MODE and STRAPS over the bus.
* **The syscon window also holds the PINMUX word** at `0x1002_0020` (section
  11), carved out by `soc_bus`; `syscon.v` is not edited and still reads 0
  there. CACHE_CTL takes `0x1002_0024` the same way (section 12).

### 7. PLIC at `0x0C00_0000`

A subset of the
RISC-V PLIC specification 1.0.0 as `drivers/irqchip/irq-sifive-plic.c` drives
it (`sifive,plic-1.0.0`): one context (hart 0, M-mode), 9 level-triggered
sources, 1-bit priorities and a 1-bit threshold. It lives in its own 4 MB PMA
window, the core's third IO window `PMA_IO2` (`0x0C00_0000`-`0x0C3F_FFFF`,
core commit c60b579), decoded in `soc_bus` by `addr[27]`.

| Offset | Register |
|---|---|
| `0x000004 + 4(i-1)` | priority of source *i*: reads 0 or 1, any non-zero write stores 1 (0 masks) |
| `0x001000` | pending word (read only) |
| `0x002000` | context 0 enable word (bit 0 hard 0) |
| `0x200000` | context 0 threshold (0 or 1) |
| `0x200004` | claim (read) / complete (write the id) |

Every other word reads 0 and ignores writes; there are no aliases. Only a
full-word write (`be == 4'b1111`) takes effect, and **reads must be word
reads**: a read claims whatever its byte enables, so an `lb`/`lh` of
`0x0C20_0004..7` claims and can return 0 for the id, leaving the source in
service until a complete it never receives (Linux uses `readl`). The claim id is the lowest
eligible source (pending, enabled, priority 1, threshold 0); a claim read
clears its pending bit and marks it in service, and a complete write clears
that mark only if the source's enable bit is set (a completion of a disabled
source is ignored, as the specification says; the driver enables around it).
The gateway forwards a source once and holds it until it is completed. The
output `meip` is registered, like MTIP (one clock of latency; it drops two
clocks after a claim), and drives the core's `external_irq`.

| Source | Device |
|---|---|
| 1 | UART |
| 2 | SPI (tiny_spi interrupt; the DT does not use it) |
| 3 | gamepad change |
| 4 | GPIO input change (IN_IP & IN_IE, a level; bare-metal/FreeRTOS: gpio-mmio has no irqchip) |
| 5-6 | PWM comparators 0-1 |
| 7-8 | PWM comparators 2-3 (not built, tied 0) |
| 9 | watchdog: a ONE-clock pulse at the first expiry (not the STAT level); the PLIC pend is sticky, so it is lost only while source 9 is in service (WDT_STAT stays pollable) |

The audio block has no interrupt. The claim ignores the threshold (as the
specification says) and `meip` is gated by it. Device tree: `riscv,ndev = <9>`,
`interrupts-extended = <&cpu0_intc 11>`.

### 8. PWM at `0x1003_0000`

`src/pwm.v`. The register layout of SiFive's pwm0 (FE310-G002 chapter 20),
**two** built 16-bit comparators (0 and 1) on a scaled counter, so `pwm-sifive`
drives it; `compatible = "sifive,fu540-c000-pwm", "sifive,pwm0"` with four
`interrupts` (PLIC sources 5-8) and `clocks`. `pwmcmp2/3` read `0xFFFF` and
ignore writes (no pin, no interrupt): `pwm-sifive`'s `get_state` computes duty =
`0xFFFF - cmp`, so they read as off and the clock-enable count stays balanced.

| Offset | Register |
|---|---|
| `0x00` | PWMCFG: `scale[3:0]` (0-15), sticky, zerocmp, enoneshot, enalways, and `ip[3:0]` in bits 31:28 (a write of the top byte sets or clears `ip`); gang, center and deglitch are not built and read 0 |
| `0x08` | PWMCOUNT: reads 0 (departure); any write restarts the prescaler and the count |
| `0x10` | PWMS: the scaled counter, read only |
| `0x20`, `0x24` | PWMCMP0-1, 16 bits |
| `0x28`, `0x2C` | PWMCMP2-3: read `0xFFFF`, writes ignored |

The period is 2^(16 + scale) clocks. The pin is `ip`, high while the scaled
counter is at or above the comparator (the arithmetic of `pwm-sifive.c`,
`cmp = 0xFFFF - duty`, requires this polarity, so 0 % is not available and
100 % is `cmp = 0`). `zerocmp` resets the count one cycle after a match on
comparator 0, and `enoneshot` stops it at that reset or the counter wrap. A
PWM pin reaches a `uo_out` pin only through the pinmux (codes 4-7). Writes
never stall.

### 9. Audio at `0x1003_0100`

`src/audio.v`. Original design, no interrupt, no driver: bare-metal software
drives it. **One square-wave voice** and nothing else (no volume, noise or PCM),
on `uo_out[7]`.

| Offset | Register |
|---|---|
| `0x00` | TONE0: `{O[2:0], P[11:0]}`; f = clk / 16 / 2^O / (2 (P + 1)) = 1,953,125 / (2^O (P + 1)) Hz at 62.5 MHz |
| `0x10` | CTRL: bit 0 EN |

Every other offset reads 0 and ignores writes. EN = 0 holds the counters and the
pin at their reset values. A new period takes effect at the next reload. Range at
62.5 MHz: O = 0 gives 477 Hz (P = 4095) to 976 kHz. **The Tetris formula**
(Korobeiniki, smallest O, equal-tempered A4 = 440; table in the `src/audio.v`
header, `tests/soc/tune.S`): `P = round(1,953,125 / (2^O f)) - 1`, for example
A4 = 440 Hz: O = 1, P = 2218 gives 440.09 Hz; E5: O = 0, P = 2962 gives
659.17 Hz. (WO-67 would remove the block and play the tune on PWM channel 1;
it is not applied.)

### 10. Gamepad at GPIO `+0x10`

`src/gamepad.v`. The receiver for the TT SNES gamepad Pmod, an independent
implementation of the protocol of TinyTapeout's `gamepad_pmod.v`, **one pad**.
LATCH, CLOCK and DATA are `ui_in[4..6]` (the GPIO block's synchronised inputs).
The Pmod shifts 12 bits per pad (B Y SELECT START UP DOWN LEFT RIGHT A X L R, MSB
first, 1 = pressed) on rising CLOCK and pulses LATCH after the last bit. Pad 0
is the last 12 bits before LATCH, so a 12-bit and a 24-bit report both load it;
pad 1 is not kept. A missing pad reads all ones, which is the presence test.
Any other bit count is ignored.

| Offset | Register |
|---|---|
| `+0x10` GAMEPAD | read only: `{16'b0, pr0, 3'b0, pad0[11:0]}`; an absent pad reads 0 with its present bit clear; the pad-1 fields read 0 |
| `+0x14` GPSTAT | read `{30'b0, ie, chg}`; write bit 1 sets `ie`, write 1 to bit 0 clears `chg` (a new value in the same cycle wins). Never stalls |

The interrupt is `chg & ie` (PLIC source 3). It is carved out of the GPIO
window by `soc_bus`, so `gpio.v` does not change for it.

### 11. Pinmux at `0x1002_0020`

`src/pinmux.v`. One word in the
syscon window, carved out by `soc_bus`: pin *i*'s code in bits `[4i+2:4i]`,
bit `4i+3` reads 0 (so it can be `pinctrl-single` with 4-bit fields).

| Code | Pin *i* takes |
|---|---|
| 0 | the default of the map above |
| 1 | GPIO OUT bit *i* |
| 2 | UART RTS# |
| 3 | AUDIO |
| 4-7 | PWM0-3 |

The result goes through **one flop per pin**, which resets to `0x39`, the
wrapper's in-reset value (so F12, the rule that every pin is a flop, holds,
and the TT01 second-edge release makes no edge). Every source therefore
reaches its pin one clock later than before. Codes reset to 0, so no write
is needed out of reset. A write takes effect on the next clock.

### 12. Instruction cache and `CACHE_CTL` at `0x1002_0024`

`src/cache.v` (variant K4): 128 B, direct-mapped, 16 B lines, fetch path only,
data in one `rf_top` macro, tags in flops. It sits between the core's fetch port
and `mem_ctrl`; the data path is only watched. `CACHE_CTL` is one word carved
out of the syscon window like PINMUX:

| Bit | Meaning |
|---|---|
| 0 EN | read/write, reset 0 (every reset, including a reboot). 0 = the fetch path passes straight through; 0 to 1 starts cold |
| 1 | reads 1: a cache is built |
| 2 PBURST | **pending WO-68 (TODO: the RTL is not committed).** Reset 0; PSRAM line fills in one CE# period. Needs EN and `QSPI_CFG.STREAM`; only at a core clock of at least 15 MHz (tCEM 8 µs, about 97 clocks per line) |

A hit takes 2 clocks (3 for a straddling fetch); a miss fills four aligned words in
line order, restarting early. Stores, AMOs and successful SCs that complete on the
data port invalidate their line, so a fetch that starts after the store completes sees
the new bytes. Instructions already fetched are not re-fetched: the rest of a line whose
fill is under way when the store issues (up to three words, early restart) can execute the
old bytes, a few instructions after the store (WO-70/71, legal under Zifencei). So issue
FENCE.I after writing code, as Zifencei requires; it also flushes the cache. With the cache on, the
worst fetch wait on a miss is 476 clocks PSRAM-only to 581 with flash code (4 data
transactions, 3 old and 4 own fill words, plus 3 clocks); the 449/482-clock bound
of `mem_ctrl` is the EN = 0 statement. The software rule and the loader's
duties are in `docs/boot-contract-4x4.md`. No pin changes.

## Not building

* **UART flow control as a default.** RTS# is a pinmux feature on
  `uo_out[5]` only; the default map gives that pin to SD CS#, and RX relies
  on the 8-entry FIFO.
* **Keypad:** the gamepad Pmod replaced it on `ui_in[4..6]`; no hardware scanner.
* **The other Pmods:**

  | Pmod | Why not |
  |---|---|
  | PmodTMP3 | I²C needs a bidirectional pin for SDA, and QSPI holds all eight. |
  | PmodCLP | 11 signals across two connectors. |
  | PmodHB5, PmodSTEP | Motors not needed. |
  | PmodSWT | Duplicates the demo board's DIP switches. |
  | PmodDA2 | Not planned. It would fit the OUT top row as plain GPIO if ever wanted. |

## Open items

1. **VCCEN tied to RES#:** confirm against the SSD1331 datasheet's power
   sequence.
2. **RP2350 terminal:** UART1 without CTS is the default (GPIO38 carries SD
   CS#); confirm the firmware that runs it does not enable CTS. Flow control
   is for the RTS# mapping only.
3. **Linux drivers:** no Linux boot has run; every driver contract is argued
   from source and checked as a device tree (`docs/alphaone-4x4.dts`, dtc and
   dt-validate clean but for the out-of-tree PLIC name).
4. **Area:** the gate harden gives the final figures.
5. ~~**Testbench models**~~ -- done: `tb/rp2350_uart_model.v`,
   `tb/ssd1331_model.v`, driven by `make test-soc-periph` (`tests/soc/`)
   rather than `run.sh soc`, whose IO window is off to match Spike. Unit
   benches: `make test-uart`, `make test-gpio`, and for the 4x4 blocks
   `test-gamepad`, `test-pwm`, `test-audio`, `test-pinmux` and `test-plic`. The top level's pins: `make test-wrapper`.
6. ~~**Stall path timing**~~ -- the registered IO read path makes the IO
   `ready` into the core's stall path a flop.
