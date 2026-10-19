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
| `uo_out[1]` | GPIO out 1, or SPI MOSI | out | OLED MOSI / keypad COL3 |
| `uo_out[2]` | GPIO out 2 | out | OLED D/C (moved there, see below) / keypad COL2 |
| `uo_out[3]` | GPIO out 3, or SPI SCK | out | OLED SCK / keypad COL1 |
| `uo_out[4]` | UART TX | out | RP2350 GPIO37 (UART1 RX) |
| `uo_out[5]` | UART RTS# | out | RP2350 GPIO38 (UART1 CTS) |
| `uo_out[6]` | GPIO out 6 | out | OLED RES# and VCCEN |
| `uo_out[7]` | GPIO out 7 | out | spare (7-segment DP) |
| `ui_in[0]` | `qspi_rd_late` strap during reset, then GPIO in 0 | in | RP2350 GPIO17, or DIP 1 |
| `ui_in[1]` | GPIO in 1 | in | DIP 2 |
| `ui_in[2]` | GPIO in 2 | in | DIP 3 |
| `ui_in[3]` | UART RX | in | RP2350 GPIO20 (UART1 TX) |
| `ui_in[4..7]` | GPIO in 4..7 | in | keypad ROW4..ROW1, or DIP 5–8 |

**Reset values.** GPIO OUT resets to `0x09`: `uo_out[6]` low holds the OLED
in reset with its panel supply off, while its CS# (`uo_out[0]`) is high,
deselected, and SCK (`uo_out[3]`) sits at SPI mode 3's idle-high level, so
enabling the transmitter makes no edge. On the keypad that leaves two columns
high and two low, which nothing reads until software scans.
UART TX resets to 1 (idle) and RTS# to 1 (not ready), so the RP2350 sees
neither a break nor a clear-to-send while the chip is in reset. While reset is
held the QSPI pins are released, as they are today.

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
  if they are used as inputs with their DIPs off.
* **RP2350 UART.**
  * UART1 on GPIO20 (TX) and GPIO37 (RX), with **CTS** flow control on
    GPIO38.
  * Do **not** enable its RTS: GPIO23 is `ui_in[6]`, a keypad row.
  * Leave GPIO21–24 as inputs.
* **7-segment display.** It is wired to every `uo_out` through solder
  jumpers JP1–8, so it flickers with the traffic. Cut the jumpers to stop
  that, or use `uo_out[7]` (segment DP) as a heartbeat LED.

## Peripheral RTL

| # | Block | Where | Status | Size (measured) | Linux |
|---|---|---|---|---|---|
| 1 | TinyTapeout wrapper | `src/tt_um_alfadelta10010_alphaone_soc.v` | built | 2 flops, about 10 gates | — |
| 2 | UART | `0x1000_0000`, `src/uart.v` | built | 0.29 tiles, 77 flops | `ns16550a` (8250 driver), polled |
| 3 | GPIO | `0x1001_0000`, `src/gpio.v` | built | 0.12 tiles, 39 flops, with 4 | generic gpio-mmio |
| 4 | SPI transmitter | `0x1001_0008`, inside the GPIO block | built | (in 3) | small SPI controller driver |
| 5 | Bus and top-level changes | `soc_bus.v`, `alphaone_soc.v` | built | a mux | — |

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
    project that has no section in its `config.ini`, stops the clock, pulses
    `rst_n` low for 2 ms and only then starts the clock
    (`tt-micropython-firmware`, `demoboard.py`: `clock_project_stop()`,
    `_first_encouter_reset()`, `clock_project_PWM()`). A reset that waited for
    a clock edge would never see that pulse.
  * Those two edges are what carries the reset into the SoC's flops, so any
    pulse on `rst_n` resets the chip, however short.
  * `ena` is unused.
* **While `rst` is high the pins depend on neither a clock nor on what the
  SoC's flops powered up with:**
  * `uio_oe` is 0. Every bit is ANDed with `!rst`: bits 0, 3, 6, 7 =
    `qspi_ctl_oe`, bits 1, 2, 4, 5 = `qspi_io_oe`. So whoever holds the chip
    in reset owns the QSPI bus without needing a clock, and the pins stay
    inputs after `rst_n` rises until the SoC has really been reset.
  * `uo_out` is `0x39`, the SoC's own reset values (TX and RTS# high, GPIO
    OUT `0x09`: the OLED held in reset with its panel supply off). Nothing
    moves when `rst` falls, because the SoC is driving the same values by
    then.
* `uio_out`: `[0]` cs_n[0], `[1]` io_out[0], `[2]` io_out[1], `[3]` sck,
  `[4]` io_out[2], `[5]` io_out[3], `[6]` cs_n[1], `[7]` cs_n[2].
* `qspi_io_in` = `{uio_in[5], uio_in[4], uio_in[2], uio_in[1]}`. The other
  four `uio_in` bits are unused; SCK's floats while the pins are released.
* `ui_in` as in the pinout table. `qspi_rd_late` = `ui_in[0]`, straight from
  the pin; the QSPI engine samples it on every clock edge while `rst` is
  high, the last of them the second edge after `rst_n` rises. **Hold
  `ui_in[0]` until then.** The whole `ui_in` byte also feeds GPIO IN.
* The demo board starts the clock by itself only if the project's `clock_hz`
  in `info.yaml` is not 0. With 0 the clock has to be started by hand, or
  from a `config.ini` section for the project.

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
* **The divisor resets to 27**, 115200 baud at a 50 MHz clock (+0.5%), so a
  program in flash can print before it sets the divisor
  (`alphaone_soc`'s `UART_DIV_RESET`). At 62.5 MHz, the clock the 3x4
  harden closes at, 27 gives 144,676 baud and 115200 needs 34 (-0.3%). A
  divisor of 0 behaves as 1.
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
1843200 / (16 × 115200) = 1, which on this chip is clk/16 (3.1 Mbaud at
50 MHz). With no baud, `8250_early.c` leaves the divisor alone and the
UART runs at whatever it holds -- 115200 at 50 MHz straight out of reset,
or whatever the boot loader set. A plain `earlycon` with `stdout-path` in
the device tree takes `clock-frequency` from the node and is also right.

### 3. GPIO at `0x1001_0000`

| Offset | Register |
|---|---|
| `0x00` | OUT (read/write). Bit *i* drives `uo_out[i]`. Bits 4 and 5 belong to the UART: they read 0 and ignore writes. Resets to `0x09`. |
| `0x04` | IN (read only). `ui_in[7:0]` through a two-flop synchroniser. |

Linux uses the generic gpio-mmio driver: one output-only chip and one
input-only chip. Pick the exact binding when writing the device tree.

Keypad scanning is software. Drive one column low and read the four rows,
four times over. Linux's `matrix_keypad` driver needs interrupt-capable row
GPIOs, which this chip does not have. The keypad is therefore a small polled
input driver, or a userspace program.

### 4. SPI transmitter (for the OLED) at `0x1001_0008`

**Why it is needed.** The OLED works without it: GPIO can bit-bang its SPI.
But through Linux's `spi-gpio` that costs very roughly 100 instructions per
bit at ~0.9 MIPS:

* about 0.1 s to draw one 8×6-pixel character;
* about 10 s for a full 96×64 frame.

The transmitter makes each byte a single store. That brings a character down
to a few milliseconds and a full frame to under a second (both estimates).
The transmitter lives in the GPIO block, which already owns the pins it
shares.

| Offset | Register |
|---|---|
| `0x08` | DATA (write). Shifts 8 bits out, MSB first. While a byte is shifting, **every** GPIO register write stalls until it is done, the same back-pressure as the UART; reads do not. |
| `0x0C` | CTRL (read/write). Bit 0 EN: 1 = the transmitter drives `uo_out[1]` (MOSI) and `uo_out[3]` (SCK); 0 = GPIO does. Bits 2:1 DIV: SCK = clk / 2^(DIV+1). Bit 8 BUSY (read only). |

* SPI mode 3: SCK idles high, data changes on the falling edge and is sampled
  on the rising edge.
* The SSD1331 needs an SCK period of at least 150 ns and each phase at
  least 75 ns. DIV=2 (clk/8) meets that exactly at 53 MHz, with no margin
  for pad duty-cycle distortion or edge rates, so use DIV=2 up to about
  48 MHz and DIV=3 (clk/16) above.
* CS# and D/C stay GPIO lines.
* With the keypad fitted, EN stays 0.
* As built (`src/gpio.v`): MOSI is its own flop and changes only on SCK's
  falling edge, so the device gets half an SCK period of setup and of hold
  even when the next byte is loaded the cycle after the last rising edge.
  The transmitter stays busy for one more half-period after that edge, and
  every register write waits for it, so `DATA; OUT` back to back is safe:
  the SSD1331 samples D/C on each byte's eighth rising edge and needs CS# and
  D/C held 60 / 40 ns after it, which the extra half-period gives. It also
  stops a CTRL write from changing DIV or EN mid-byte. Between two bytes SCK
  stays high for at least a period. DATA reads 0.

Linux needs a small SPI controller driver under fbtft's `fb_ssd1331`
(staging); its `transfer_one` is one register write per byte. Alternatively,
make the registers compatible with an existing mainline driver. Decide when
writing the driver.

### 5. Bus and top level

* `soc_bus.v`: `ready` comes from the IO targets, for the UART's and SPI's
  back-pressure. An IO target may hold `ready` low only on a cycle its own
  select is high, so the bus ANDs the readies.
* `alphaone_soc.v`: ports `uart_rx`, `uart_tx`, `uart_rts_n`, `gpio_in[7:0]`
  and `gpio_out[7:0]` (SPI muxed inside the GPIO block; `gpio_out[5:4]` are
  0, since those pins are the UART's). The wrapper maps them onto `ui_in`
  and `uo_out` as in the pinout table.
* `syscon` (`0x1002_0000`) stays reserved and unassigned.

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
