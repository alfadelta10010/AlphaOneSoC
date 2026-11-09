# AlphaOneSoC — pins and peripherals

What each of the chip's 24 TinyTapeout I/O pins does, how the demo board and
the Pmods connect to them, and the peripheral RTL that has to be built behind
them.

**Status: the pinout is final. The UART (`src/uart.v`), the GPIO block with
the SPI transmitter (`src/gpio.v`) and the bus and top-level changes are
built and wired into `src/alphaone_soc.v`, and the TinyTapeout wrapper
(`src/tt_um_alfadelta10010_alphaone_soc.v`) puts that on the pins.** The
address map, boot flow and QSPI engine are in `docs/soc-architecture.md`.

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
| `uo_out[0]` | GPIO out 0 | out | OLED CS# / keypad COL4 |
| `uo_out[1]` | GPIO out 1, or SPI MOSI (a flop either way) | out | OLED SDIN and SD DI (MOSI) / keypad COL3 |
| `uo_out[2]` | GPIO out 2 | out | OLED D/C (moved there, see below) / keypad COL2 |
| `uo_out[3]` | GPIO out 3, or SPI SCK (a flop either way) | out | OLED SCK and SD SCK / keypad COL1 |
| `uo_out[4]` | UART TX | out | RP2350 GPIO37 (UART1 RX) |
| `uo_out[5]` | UART RTS# | out | RP2350 GPIO38 (UART1 CTS) |
| `uo_out[6]` | GPIO out 6 | out | OLED RES# and VCCEN |
| `uo_out[7]` | GPIO out 7: SD CS# (resets high) | out | SD CS# (DAT3), by a jumper wire; the 7-segment DP otherwise |
| `ui_in[0]` | `qspi_rd_late` strap during the pin reset (held through reboots), then GPIO in 0 | in | RP2350 GPIO17, or DIP 1 |
| `ui_in[1]` | GPIO in 1, and SPI MISO | in | SD DO (MISO); DIP 2 must be off with the SD fitted |
| `ui_in[2]` | the no-stream strap during the pin reset (held through reboots), then GPIO in 2. 1 = flash streaming off at reset | in | DIP 3 (off = RP2350 pull-down = streaming on) |
| `ui_in[3]` | UART RX | in | RP2350 GPIO20 (UART1 TX) |
| `ui_in[4..7]` | GPIO in 4..7 | in | keypad ROW4..ROW1, or DIP 5–8 |

**Reset values.** GPIO OUT resets to `0x89`: `uo_out[6]` low holds the OLED
in reset with its panel supply off, while its CS# (`uo_out[0]`) and the SD
card's (`uo_out[7]`) are high, deselected, and SCK (`uo_out[3]`) sits at SPI mode 3's idle-high level, so
enabling the transmitter makes no edge. On the keypad that leaves two columns
high and two low, which nothing reads until software scans.
UART TX resets to 1 (idle) and RTS# to 1 (not ready), so the RP2350 sees
neither a break nor a clear-to-send while the chip is in reset. While reset is
held the QSPI pins are released, as they are today. The same values hold at a
syscon reboot (for two clocks) and for as long as the chip is powered off, and
the QSPI pins are released then too.

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
  UART function. RTS# goes on `uo_out[5]` because that is GPIO38, the demo
  board's UART1 CTS pin.
* **Outputs are the scarce pins.** After TX and RTS#, six outputs remain. The
  OLED needs five of them once PMODEN and VCCEN are tied off (below), and the
  keypad needs four. Only one of the two is fitted at a time.
* The OLED's SPI lines keep their Pmod positions (CS# 0, MOSI 1, SCK 3), so
  the SPI transmitter can take over MOSI and SCK without moving anything.

## Board setups

One output Pmod at a time on the OUT header.

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

OUT pins 7, 8 and 10 (TX, RTS#, spare) then reach nothing on the Pmod side;
the RP2350 reads TX and RTS# through the board.

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

### Keypad (PmodKYPD): nice to have

The keypad connects through Digilent's 2×6-pin to dual 6-pin splitter cable,
or ten jumper wires. The Pmod itself is not modified.

* The top-row plug (COL4..COL1, GND, 3V3) goes into the OUT top row,
  `uo_out[0..3]`.
* The bottom-row plug (ROW4..ROW1, GND, 3V3) goes into the IN bottom row,
  `ui_in[4..7]`.

The columns have 470 Ω series resistors and the rows 10 kΩ pull-ups. A scan
drives one column low and the rest high, then reads the four rows. The series
resistors make two pressed keys in one row safe (about 3.5 mA between two
columns).

### Board rules

* **DIP switches 4–8 off.** DIP 4 sits on UART RX, and 5–8 on the keypad
  rows. A DIP that is on adds a 1 kΩ pull-up, which against the keypad's
  470 Ω leaves a pressed row at about 1.1 V.
* **An off DIP leaves its pin floating.** The switches pull up through 1 kΩ
  and nothing pulls down. The RP2350 drives `ui_in[0]` (the read-latency
  strap), since it chose the clock. It should also pull down `ui_in[1..2]`
  if they are used as inputs with their DIPs off, except `ui_in[1]` with the
  SD card fitted: the card drives MISO there, and the RP2350 pin must be an
  input with no pull-down (see the SD notes below). A floating `ui_in[2]`
  can only make flash reads slower (streaming off), never unbootable.
* **RP2350 UART.**
  * UART1 on GPIO20 (TX) and GPIO37 (RX), with **CTS** flow control on
    GPIO38.
  * Do **not** enable its RTS: GPIO23 is `ui_in[6]`, a keypad row.
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
  that. `uo_out[7]` (segment DP) is the SD card's CS#, so it is no
  heartbeat LED.

## Peripheral RTL

| # | Block | Where | Status | Size (measured) | Linux |
|---|---|---|---|---|---|
| 1 | TinyTapeout wrapper | `src/tt_um_alfadelta10010_alphaone_soc.v` | built | 2 flops, about 10 gates | — |
| 2 | UART | `0x1000_0000`, `src/uart.v` | built | 0.29 tiles, 77 flops | `ns16550a` (8250 driver), polled |
| 3 | GPIO | `0x1001_0000`, `src/gpio.v` | built | 0.12 tiles, 39 flops, with 4 | generic gpio-mmio |
| 4 | SPI transmitter | `0x1001_0008`, inside the GPIO block | built | (in 3) | small SPI controller driver |
| 5 | Bus and top-level changes | `soc_bus.v`, `alphaone_soc.v` | built | a mux | — |
| 6 | syscon | `0x1002_0000`, `src/syscon.v` | built | 0.151 tile, 23 flops (0.078 and 14 without the watchdog) | `syscon` + `syscon-poweroff`, `syscon-reboot`, `syscon-reboot-mode`, plus `snps,dw-wdt` for the watchdog at `0x1002_0100` |

Sizes: yosys + abc against `libs/sky130_fd_sc_hd__tt_025C_1v80.lib`, each
block synthesised on its own with the audit's recipe; 1 tile ≈ 11,300 µm² of
standard cells at TinyTapeout's 60% density (UART 3,321 µm², GPIO 1,380 µm²).
The recipe runs about 20-24% below LibreLane's synthesis (`docs/area-audit.md`).
In LibreLane the whole SoC is 12.52 tiles with the area cuts, about 1.8x the
seven-tile budget (see "Area" in `docs/soc-architecture.md`); these two add
about 0.4 tiles of that.

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
  * `uo_out` is `0xB9`, the SoC's own reset values (TX and RTS# high, GPIO
    OUT `0x89`: the OLED held in reset with its panel supply off). Nothing
    moves when `rst` falls, because the SoC is driving the same values by
    then.
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
  `uo_out` goes to `0xB9` on the same edge. Every `uo_out` bit is a flop except
  `uo_out[1]` and `uo_out[3]` while the SPI transmitter is on: those are a mux
  whose select and data both change on that edge, a possible sub-nanosecond
  hazard at the instant RES# falls and CS# rises. The OLED is being reset
  anyway. Gating `run` as well would not remove it, so the follow-up is for the
  SPI controller to drive MOSI and SCK from flops.
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
changed at the first moment it is allowed to. Because the bench refers to
nothing inside the design, it also runs on a gate-level netlist of the top
level.

### 2. UART at `0x1000_0000`

This is a 16550-compatible subset with **byte-wide registers**
(`reg-shift = 0`, `reg-io-width = 1`). That is the layout Spike
(`spike --dump-dts`) and QEMU's `virt` board use at the same address, so one
kernel and a near-identical device tree run on Spike and on the chip. The
frame is fixed at 8N1, and baud = clk / (16 × divisor).

| Offset | Read (DLAB=0) | Write (DLAB=0) | DLAB=1 |
|---|---|---|---|
| 0 | RBR (pops the received byte) | THR | DLL |
| 1 | IER: bit 0 ERBFI, bit 1 ETBEI | IER | DLM |
| 2 | IIR | FCR (ignored) | — |
| 3 | LCR (read/write; only DLAB, bit 7, and SBC, bit 6, are kept) | LCR | LCR |
| 4 | MCR (reads 0) | ignored | — |
| 5 | LSR: bit 0 DR, 1 OE, 4 BI, 5 THRE, 6 TEMT | — | — |
| 6 | MSR: `0xB0` (CTS, DSR, DCD asserted) | — | — |
| 7 | SCR (reads 0) | ignored | — |

RBR pops only on a load whose byte enable selects offset 0. The core drives
`dmem_be` on loads too.

The behaviour that matters to Linux (`drivers/tty/serial/8250`):

* **No interrupt line.** The device-tree node has no `interrupts`, so the
  8250 driver polls on a timer, once per tick. **IIR must be correct even
  so.** The poll calls the interrupt handler, which reads IIR first and
  returns at once if bit 0 is set. IIR reads:
  * `0x04` when ERBFI && DR;
  * otherwise `0x02` when ETBEI && THRE;
  * otherwise `0x01`.
* **Transmit back-pressure instead of a TX FIFO.** A write to THR while the
  transmitter still holds a byte does not complete: the UART holds `ready`
  low until the holding register is free. The device tree says `ns16550a`
  (16-byte FIFO), so on each poll the driver writes up to 16 bytes and the
  bus paces them.
  * Without this, a FIFO-less UART in polled mode sends **one character per
    timer tick**: 100 characters/s at HZ=100.
  * printk console output polls LSR per character and runs at line rate
    either way.
  * The divisor must reset to a non-zero value, so a THR write can never
    stall forever.
  * Check against `serial8250_tx_chars` when implementing.
* **Receive flow control instead of an RX FIFO.** RX has one holding
  register. RTS# (`uo_out[5]`) is asserted only while the receiver is idle
  and the holding register is empty. The RP2350, with CTS flow control on,
  checks CTS before each character, so it sends a character only when there
  is room for it.
  * Input is lossless at up to one character per poll. That is enough for
    typing and for multi-byte escape sequences; a paste is slow but not lost.
  * Without flow control, a burst arriving between two polls is lost. An
    arrow key alone is three bytes.
* **RX sampling:** two-flop synchroniser, 16x oversampling, start bit checked
  at mid-bit.

As built (`src/uart.v`):

* **No separate holding registers.** THR is the transmit shift register, so
  THRE and TEMT are the same bit and a write stalls until the previous
  frame's stop bit has gone. RBR is the receive shift register: a frame only
  starts while RBR is empty (RTS# sees to that), so nothing is overwritten.
  With the core's store loop between two bytes the line idles for a few
  instruction times per character, a few percent of the throughput.
* **A frame that starts while RBR is full** (a sender ignoring CTS) is not
  shifted in: RBR keeps the older byte, and the frame sets OE at its stop
  bit. **A frame whose stop bit reads 0 with any data bit 1** (a framing
  error) is dropped and sets nothing; there is no FE bit. **A frame whose
  every bit reads 0**, stop bit included, is a **break**: it sets BI and,
  as a 16550 loads one zero character, DR with RBR = 0 (or OE if RBR was
  full). Linux counts breaks and takes the magic SysRq key from BI. After
  a framing error the receiver looks for a start bit again as soon as the
  line is high; if the line instead stays low a whole frame more, counted
  from the bad stop bit, that is a break that began inside a character and
  is reported as one. After a break the line must be high for half a bit
  before a start bit counts, as on a 16550, so a short glitch inside a long
  break is not a second break.
* **Reading LSR clears OE and BI**, as on a 16550. RBR pops, and OE and BI
  clear, only on the cycle the load completes.
* **LCR stores only DLAB and SBC**; its other bits read 0. Linux keeps its
  own copy of LCR, and its read-modify-writes of LCR only clear bits.
  **SBC (bit 6) sends a break**: TX is held at 0 from the next 16x tick
  until SBC is cleared, as `serial8250_break_ctl` (tcsendbreak, TIOCSBRK)
  expects. The transmitter keeps shifting underneath.
* **RBR resets to 0.** Linux's startup reads it before any byte has
  arrived, and an X there would spread in an X-accurate simulation.
* **The divisor resets to 34**, 114,890 baud (-0.27% from 115200) at the
  documented 62.5 MHz clock, so a program in flash can print before it sets
  the divisor (`alphaone_soc`'s `UART_DIV_RESET`). At 60 MHz 34 gives
  110,294 baud (-4.3%, 33 would be -1.4%) and at 50 MHz 27 would be 115200 (+0.5%). A divisor of 0 behaves as 1.
* Every register write waits for `ready`, so a word store that writes THR
  and LCR together while the transmitter is busy writes LCR once, when THR
  is taken, and cannot flip DLAB under its own THR write.

Device tree: `compatible = "ns16550a"`, `reg-shift = <0>`,
`reg-io-width = <1>`, `clock-frequency` = the core clock, no `interrupts`.
With no `interrupts`, `__uart_read_properties()` calls `platform_get_irq()`
(not the `_optional` form), so every boot logs `error -ENXIO: IRQ index 0
not found` at error level before the driver falls back to polling with
irq 0, as intended. The line is expected, not a fault.

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
| `0x00` | OUT (read/write). Bit *i* drives `uo_out[i]`; reads return the pins. Bits 4 and 5 belong to the UART: they read 0 and ignore writes. Bit 7 is the SD card's CS#. Bits 1 and 3 are the MOSI and SCK pin flops: with EN = 1 the SPI engine drives them and OUT writes to them are ignored. Resets to `0x89`. |
| `0x04` | IN (read only). `ui_in[7:0]` through a two-flop synchroniser. |
| `0x08` | reserved |
| `0x0C` | SPICTL. Bit 0 EN (resets 0): 1 = the SPI engine owns `uo_out[1]` and `uo_out[3]`. Bit 8 BUSY (read only) = not TXE. |
| `0x10`-`0x1C` | reserved |
| `0x20`-`0x30` | the SPI controller, section 4 |
| `0x34`-`0x3C` | reserved |

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

Linux uses the generic gpio-mmio driver: one output-only chip and one
input-only chip. Pick the exact binding when writing the device tree.

Keypad scanning is software. Drive one column low and read the four rows,
four times over. Linux's `matrix_keypad` driver needs interrupt-capable row
GPIOs, which this chip does not have. The keypad is therefore a small polled
input driver, or a userspace program.

### 4. SPI controller (tiny_spi) at `0x1001_0020`

A general SPI master for the SD card and the OLED on one bus, inside the GPIO
block (`src/spi.v`). Its registers have the semantics of OpenCores
`tiny_spi`, so Linux's `drivers/spi/spi-oc-tiny.c` (compatible
`opencores,tiny-spi-rtlsvn2`) drives it unchanged, polled, with the chip
selects as `cs-gpios` on GPIO OUT (OLED CS# = bit 0, SD CS# = bit 7; D/C =
bit 2 and RES# = bit 6 are `dc-gpios` / `reset-gpios`).

| Offset | Register |
|---|---|
| `0x20` | RXDATA (read): the byte received with the last byte sent; valid once TXE = 1. |
| `0x24` | TXDATA. Write: queue a byte (waits while the holding register is full). Read: that register, i.e. the byte written but not yet loaded, or after a load the byte received with the byte before. |
| `0x28` | STATUS (read): bit 0 TXE = engine idle and holding register empty, bit 1 TXR = holding register empty. Writes are ignored. |
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
  capped at 12.5 MHz in the device tree (BAUD 2 = 10.4 MHz); BAUD 1 only
  after the round trip is measured on silicon (loopback `uo_out[1]` ->
  `ui_in[1]`). Never use BAUD 0 to receive.
* **Modes.** The driver writes CONTROL and BAUD before every transfer with
  the mode of the last device set up, so run both devices in mode 3.
* Device tree: `baud-width = <8>` and `clock-frequency` are both required.
* With the keypad fitted EN stays 0: COL3 and COL1 are MOSI and SCK.
* Departures from the tiny_spi RTL: a TXDATA write to a full holding register
  waits (tiny_spi overwrote it); TXE also needs the holding register empty;
  STATUS writes are ignored (no IRQ); CONTROL, BAUD and the data registers have
  reset values.
* A reset or reboot in the middle of A in mode 3 raises SCK on the same edge as
  SD CS#; the frame is abandoned either way.

#### Board setup: SD card + OLED

* PmodMicroSD J1: 1 CS, 2 MOSI, 3 MISO, 4 SCK, 5/11 GND, 6/12 3V3, 7 DAT1,
  8 DAT2, 9 CD (confirm against Digilent's reference manual).
* MOSI, SCK to both devices; MISO (`ui_in[1]`) from the card's DO; SD CS# from
  `uo_out[7]` by a jumper wire (the OLED adapter clips that pin). Keep the
  wires short, or fit 33 ohm series resistors, and scope SCK at the card.
* A 10-100 kohm pull-up on MISO on the card side (the card tri-states DO while
  deselected); check whether the Pmod has one. RP2350 GPIO18 must be an input
  with no pull-down.
* DIP 2 off with the SD fitted (its 1 kohm pull-up loads DO).

### 5. Bus and top level

* `soc_bus.v`: `ready` comes from the IO targets, for the UART's and SPI's
  back-pressure. An IO target may hold `ready` low only on a cycle its own
  select is high, so the bus ANDs the readies.
* `alphaone_soc.v`: ports `uart_rx`, `uart_tx`, `uart_rts_n`, `gpio_in[7:0]`
  and `gpio_out[7:0]` (SPI muxed inside the GPIO block; `gpio_out[5:4]` are
  0, since those pins are the UART's). The wrapper maps them onto `ui_in`
  and `uo_out` as in the pinout table.
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
  `rst_n` rises. `uo_out` is `0xB9` through it, then follows the GPIO block.
* **Power-off** (`0x5555`, or `0x3333`): the same values held until `rst_n`.
  The QSPI pins stay released, so the Pmod's pull-ups deselect the flash and
  both PSRAMs; `uo_out` stays `0xB9` (UART idle, RTS# not ready, the OLED in
  reset with its panel supply off). The clock keeps running. Only `rst_n`
  wakes the chip.
* **The strap** is read once, at the pin reset, and kept (see the wrapper
  section). The pin is GPIO afterwards.
* **The watchdog** (`0x1002_0100`, DesignWare layout) resets the SoC through
  the reboot path when it expires, so the pins behave as for a reboot. It is
  disabled again afterwards, since its flops are on `rst_soc`. It cannot fire
  while the chip is powered off.
* The RP2350 reads no syscon state from the pins; software reads
  RESET_CAUSE, BOOT_MODE and STRAPS over the bus.

## Not building

* **PLIC.** Every device here is polled, and interrupts would not make it
  faster on this core. Taking one interrupt through Linux costs very roughly
  1–2k instructions, 1–2 ms at ~0.9 MIPS. A character at 115200 baud lasts
  87 µs. An interrupt per character would be slower than back-pressure and
  flow control, and it would need a FIFO as well. The core's `external_irq`
  stays 0, and `0x0C00_0000` stays reserved.
* **UART FIFOs:** replaced by back-pressure (TX) and RTS# (RX).
* **Hardware keypad scanner:** software scans it.
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
2. **RP2350 terminal:** confirm that whatever runs it can enable CTS flow
   control on GPIO38 (MicroPython's `UART(..., flow=UART.CTS)` would).
3. **Linux drivers:** the SPI controller driver, and the gpio-mmio binding.
4. **Area:** measure every block once written.
5. ~~**Testbench models**~~ -- done: `tb/rp2350_uart_model.v`,
   `tb/ssd1331_model.v`, `tb/keypad_model.v`, driven by `make
   test-soc-periph` (`tests/soc/`) rather than `run.sh soc`, whose IO window
   is off to match Spike. Unit benches: `make test-uart`, `make test-gpio`.
   The top level's pins: `make test-wrapper`.
6. **Stall path timing:** the IO `ready` now sits in the core's global stall
   path (request decode → UART/GPIO ready → `wb_mem_stall`); check it in
   STA once the design is hardened.
7. **Keypad reads:** a column write reaches the pin on the edge the store
   completes, and IN is two synchroniser flops behind the pins, so only a
   load completing three or more clocks after the column store sees the new
   rows. With fast memory two back-to-back loads still read the old rows.
   Software discards two IN reads after each column write
   (`tests/soc/keypad.S`), or waits three clocks; a Linux driver must too,
   and must not rely on the QSPI memory making one discard enough.
