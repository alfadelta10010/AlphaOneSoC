# AlphaOneSoC — SoC architecture

The SoC around FyraCore: the address map, how it boots, the bus, the memory
controller and the QSPI engine. The overriding constraints are **area** (seven
TinyTapeout tiles, roughly 21 kGE of usable standard-cell area for everything)
and **booting NOMMU M-mode Linux from 16 MB of PSRAM**. Where the two pull
apart, this document says which one won and why.

## Address map

| Region | Base | Size | Attributes | Device |
|---|---|---|---|---|
| Flash | `0x2000_0000` | 16 MB | read, execute | W25Q128JV on QSPI CS0 |
| PSRAM | `0x8000_0000` | 16 MB | read, write, execute, LR/SC, AMO | 2x 8 MB PSRAM on QSPI CS1 (A) / CS2 (B), `addr[23]` picks the chip |
| CLINT | `0x0200_0000` | 64 KB | read, write, AMO | `src/clint.v` |
| PLIC | `0x0C00_0000` | — | reserved, not implemented (accesses fault) | — |
| UART | `0x1000_0000` | 64 KB | read, write, AMO | `src/uart.v`: 16550-compatible subset, byte registers, polled (`docs/pins-and-peripherals.md`) |
| GPIO | `0x1001_0000` | 64 KB | read, write, AMO | `src/gpio.v`: GPIO and the OLED's SPI transmitter (`docs/pins-and-peripherals.md`) |
| syscon | `0x1002_0000` | 64 KB | read, write, AMO | reserved (reads 0) |

Everything else is unmapped: an access raises an access fault (cause 1 / 5 /
7) from the core's PMA check, before anything reaches the bus. The windows are
`fyracore` parameters (`PMA_ROM_*`, `PMA_RAM_*`, `PMA_IO0_*`, `PMA_IO1_*`);
the defaults are this map.

* **Flash is read-only.** A store, AMO or SC to it is a store access fault
  (cause 7) and an LR is a load access fault (cause 5): flash has no write
  path in the QSPI engine and no reservation set.
* **LR/SC work only in PSRAM**, the one region with a reservation set.
* PSRAM is at `0x8000_0000` because that is where Linux (`PHYS_RAM_BASE`),
  Spike (`DRAM_BASE`) and KianV all put RAM.

## Boot

**The SoC boots from flash, always.** There is no boot ROM and no strap: the
reset PC (the core's `boot_addr` input, tied off in `alphaone_soc`) is
`0x2000_0000`, the first byte of flash. Whatever was last programmed there is
the first thing the core runs, so nothing about the boot path is fixed in
silicon, and a bare assembly program runs by flashing it. Anything that runs
from PSRAM is put there by code in flash.

**While reset is held, the QSPI pins are released** (every output enable is
0), so the demo board's RP2040 can program the flash over the same Pmod pins
before it releases reset. The Pmod's 10 kΩ pull-ups hold every chip select
high meanwhile (`docs/qspi-memories.md` §1.2).

A program links with `plugins/helpers/link_soc.ld` (code and read-only data
in flash, `.data`/`.bss`/stack in PSRAM) and starts with
`plugins/helpers/boot_flash.S`, which copies `.data` to PSRAM, clears
`.bss`, sets `sp` and jumps to `_start`. (`plugins/helpers/link.ld`, at
`0x8000_0000`, is for the verification flow, which starts the core straight
in PSRAM.)

`mtvec` resets to 0. The spec leaves it unspecified, boot code must set it
before it can take a trap, and 0 matches Spike, so lockstep traces agree from
reset. A trap taken before `mtvec` is written jumps to 0, which is unmapped,
and faults there over and over: a cause-1 loop at 0 that rewrites mepc,
mcause and mtval on every pass, so the first trap's cause is lost, and the
QSPI bus goes quiet, since 0 is outside every window. Erased flash
(`0xFFFFFFFF`, an illegal instruction) at the reset vector ends this way.
Kept at 0 by decision (2026-09-29); the first thing boot code does is set
`mtvec`.

## Bus fabric

**The core's own request/ready handshake, fanned out — not APB.**

APB needs a two-phase transfer (SETUP, then ACCESS with `PENABLE`) and a
bridge state machine to generate it, so every access costs at least two
cycles and a few registers. The core already has a request/ready port with a
held request (see `src/fyracore.v`), which is all a single-master bus needs.
`src/soc_bus.v` adds only:

* an address decode on a handful of bits — valid only because the PMA check
  has already refused anything outside the windows:
  `addr[31]` → PSRAM, `addr[29]` → flash, `addr[28]` → peripherals (then
  `addr[17:16]`), otherwise the CLINT;
* a read-data and ready mux.

It has no registers. Peripherals answer with combinational read data, and
in the cycle they are selected, so a peripheral access is one cycle -- except
for back-pressure: the UART holds a THR write, and the GPIO block a SPI DATA
write, until its transmitter is free. An IO target may hold `ready` low only
on a cycle its own select is high, so the bus simply ANDs the IO readies. A
peripheral with a side effect (a UART RX pop, a THR load) acts only on the
cycle its select and its `ready` are both high; the request strobe
guarantees that cycle is one real access.

The instruction port goes straight to the memory controller: fetch is only
ever from flash or PSRAM.

## Memory controller (`src/mem_ctrl.v`)

Joins the core's two ports onto the one QSPI engine.

* **Arbitration: data first.** When both ports are waiting, the data request
  goes first. The pipeline only issues a new data request on the cycle
  *after* a fetch completes, so a fetch is never starved. Serving data first
  also avoids reading the next instruction before a load and then losing it
  while the load stalls the pipeline; fetch-first would do that on every load.
* **Chip select** from the address: flash if `addr[31]` is 0, otherwise PSRAM
  A/B by `addr[23]`.
* **Reads are always a whole word** from the word address, whatever the byte
  enables say. Memory reads have no side effects, and a whole word needs no
  lane steering: byte *k* of the transfer is lane *k*.
* **Writes send only the enabled bytes**, starting at the first enabled lane.
  RISC-V stores are naturally aligned, so the enables are always contiguous.
* **Fetches are 4 bytes from the halfword `pc`**, not from a word boundary:
  a QSPI read streams from any byte address, so a straddling 32-bit
  instruction costs nothing extra. The exception is a PSRAM fetch that crosses
  a 1 KB page (`pc[9:1]` all ones). Parts with row-boundary crossing
  (APS6404L-3SQR) run on into the next page; "compatible" parts without it
  wrap to the start of the page, and the Pmod may carry either. So that fetch
  is split into two 2-byte reads, the second at the next page. The carry out
  of the page number into bit 23 is the step from PSRAM A to B, so the A/B
  boundary (`0x807F_FFFE`) is just one instance. The QSPI engine's read shift
  register carries over between the two reads, so the split needs no extra
  storage.
* **Requests are sampled only while the engine is idle**, and it is never
  idle on the cycle it reports done. On its ready cycle the core still shows
  the request being completed (a fetch's old pc), so starting a transaction
  from it would read a stale address.

## QSPI engine (`src/qspi_ctrl.v`)

One transaction at a time: chip select low, command, 24-bit address, then
data. The **PSRAMs run in QPI mode**: the command, too, goes out on all four
lines. The **flash is unchanged**: its quad I/O read sends the command on
IO0 and the address and data on all four lines (the chip's default "SPI
mode", as opposed to QPI mode). `docs/qspi-memories.md` §9 compares the
modes, including QPI for the flash.

| Access | Command | Wire timing (SCK cycles) | 4 bytes |
|---|---|---|---|
| PSRAM read | `0x0B` fast read, QPI | 2 cmd + 6 addr + 4 wait + 2 per byte | 20 |
| PSRAM write | `0x38` quad write, QPI | 2 cmd + 6 addr + 2 per byte | 16 |
| Flash read | `0xEB` quad I/O read | 8 cmd (IO0) + 6 addr + 6 dummy + 2 per byte | 28 |

The PSRAM's 4 wait cycles are all released, a full four for the bus to turn
around. The flash reads the first two of its 6 dummy cycles as its mode
byte: the engine drives `1111` there (mode byte `0xFF`, so the flash never
enters continuous-read mode) and releases the bus for the other four.

* **SCK = clk / 2.** Output data changes as SCK falls. Read data is sampled
  one full SCK period after the falling edge that launched it, on the clock
  edge that drives SCK low again. The data then has two core clocks to cross
  the pad and device delays rather than one, which is what keeps the design
  robust against TinyTapeout's slow I/O. The device's output hold plus the pad
  delays cover the other side of that edge.
* **CS is high for at least two clocks** between transactions: 30 ns at
  66 MHz, above the PSRAM's minimum deselect time.
* **The pins are registered** where a glitch could matter (SCK, the chip
  selects, the output enable). The data outputs are combinational: they settle
  a full clock before the SCK edge that samples them.
* **Pinout** follows the TinyTapeout QSPI Pmod on `uio`: 0 CS0 (flash),
  1 SD0, 2 SD1, 3 SCK, 4 SD2, 5 SD3, 6 CS1 (RAM A), 7 CS2 (RAM B). The
  rest of the chip's pins are in `docs/pins-and-peripherals.md`.

* **Read latency is a strap**, `qspi_rd_late` (on `ui_in[0]`). At 0 a nibble is sampled two
  clocks after its launching edge, which covers a clock-to-output time plus
  pad round trip up to about 2 clocks. At 1 it is sampled three clocks after,
  which covers about 1 to 3 clocks, and chip select stays low one clock
  longer for the last nibble. TinyQV measured the TinyTapeout pad round trip
  at a little over 20 ns; at 50 MHz use 0, and near 66 MHz use 1. It is a
  strap rather than a register because flash reads must work before any
  software runs, and it is sampled during reset and held, so a pin that
  changes later cannot move the sampling point mid-read. Measured in `tb_qspi` at a 10 ns clock: 0 passes 2–19 ns,
  1 passes 12–29 ns.
* **Writes never select the flash.** `0x38` is the PSRAM's quad write, but
  on the W25Q128JV-DTR it is Enter QPI. The PMA already faults stores to
  flash; this is the backstop.

A 4-byte PSRAM read is 20 SCK cycles, about 44 core clocks with the deselect
time (a flash read 28, about 60). That is the dominant cost of the whole
machine — see "Performance" below.

**Start-up sequence.** The Pmod is shared between designs on the demo board
and is not power cycled when the board switches to this one, so its devices
can be handed over in modes this engine does not speak. TinyQV, for example,
leaves the PSRAMs in QPI mode and the flash in continuous-read mode. The
PSRAM datasheet also asks for a reset after power-up. Before accepting its
first request the engine therefore sends the following, and leaves the
PSRAMs in QPI mode:

| Chips | Sent | Effect |
|---|---|---|
| CS1+CS2 | `F5h` in QPI form (2 clocks) | PSRAM exits QPI; a PSRAM in SPI mode sees an unfinished command |
| CS1+CS2 | `66h`, `99h` | PSRAM reset enable, reset (back to SPI mode, linear burst) |
| CS0 | 8 clocks of `1111` | flash leaves quad continuous-read mode |
| CS0 | 16 clocks of `1111` | flash leaves dual-I/O continuous-read mode (12 address + 4 mode clocks); must come after the 8-clock window, which a flash in quad continuous read needs first |
| CS0 | `FFh` in QPI form (2 clocks) | flash exits QPI (-DTR part); a flash in SPI mode sees an unfinished command |
| CS1+CS2 | `35h` | PSRAM enters QPI mode |

The flash steps separate the PSRAM reset from `35h` by far more than the
PSRAM's 50 ns tRST. The first step is also what takes a PSRAM we left in QPI
mode ourselves back to SPI at the next reset. The sequence starts 8 clocks
after reset is released, so a reset that lands just after the `99h` cannot
bring the restarted sequence's first command inside tRST. Each start-up
window ends with chip select rising while SCK is still high, SCK falling a
clock later: for a flash in continuous read the next falling edge would
start its data, and the two sides' pads would overlap for a moment. The
single two-clock `FFh` is the one Exit QPI that counts whether or not a
flash cancels Exit QPI on extra clocks (the datasheet does not say).

Not undone, and so the job of whatever programs the flash: a flash burst
wrap set with `77h`, deep power-down (`B9h`), and a cleared Quad Enable bit
(the "IM" part ships with QE = 0).

**Board prerequisites.** While reset is held the chip selects are released;
the Pmod's 10 kΩ pull-ups (R1–R3) keep every chip deselected. The data lines
have no pull-ups. The TinyTapeout wrapper, which does not exist yet, must
synchronise `rst_n` before it reaches this reset.

**Device prerequisites.**
* The flash's Quad Enable bit (SR2 bit 1) must be set once. It is
  non-volatile; TinyTapeout's QA sets it on the Pmods it ships, and the
  "Configure and flash the QSPI Pmod" guide sets it on others.
* The devices' power-up time (150 µs for the PSRAM) has passed before reset
  is released. On the demo board it long has.
* PSRAM maximum chip-select-low time (tCEM) is 8 µs for the standard grade
  the Pmod carries (APS6404L-3SQR-SN). The longest transaction is about 60
  clocks, so the core clock must be above about 8 MHz.
* The flash is idle when reset is released: no program, erase or status
  write still running, and no erase or program suspended. While BUSY the
  flash ignores everything but status reads and suspend (-DTR §7.1.1; a
  software reset would end the operation and corrupt it, §8.2.45), for up
  to 400 ms after a sector erase, 2 s after a 64 KB block erase and 200 s
  after a chip erase. The engine has no 1-bit read path to poll it, so a
  flash handed over mid-write would be fetched from as floating lines.

## Timer and interrupts

* **`mtime` counts core clocks.** There is no prescaler, because it would cost
  a counter and a register and buy nothing Linux needs. The device tree's
  `timebase-frequency` must equal the core clock.
* **MTIP is registered** in the CLINT. That takes the 64-bit
  `mtime >= mtimecmp` compare out of the path into the core's interrupt and
  next-PC logic, at the cost of one flop and one cycle of latency.
* `mtimecmp` resets to all-ones, so no timer interrupt is pending out of reset.
* No PLIC. With a polled UART, Linux needs no external interrupt; the `0x0C00_0000`
  window is reserved for one if that changes. `docs/pins-and-peripherals.md`
  explains why interrupts would not make the console faster on this core.
* Registered MTIP is legal: Priv §3.2.1 says MTIP reflects the comparison
  "eventually, but not necessarily immediately". Linux's CLINT driver sets
  MTIE before it writes `mtimecmp` (low word, then high), with MIE off, and
  the handler clears MTIE, so the extra cycle is invisible to it.

## Linux

* **The kernel runs from PSRAM, not in place from flash.** RISC-V's
  `XIP_KERNEL` is `depends on MMU` — in v6.1 exactly as in current kernels —
  so an older kernel does not change this. Boot code in flash copies the
  kernel image, its device tree and an initramfs into PSRAM and jumps to it.
* **The boot loader is ordinary code in flash.** It copies the images to
  PSRAM and enters the kernel with the hart ID in `a0` and the device tree's
  address in `a1` (or the kernel is built with `CONFIG_BUILTIN_DTB`). KianV
  does exactly this on the same map, and its SPI-framed copy of the image
  took about 20 s at 30 MHz; our PSRAM writes are QPI.
* A NOMMU M-mode kernel expects RAM at `0x8000_0000` (`PHYS_RAM_BASE`), loads
  at a 4 MB boundary on RV32, sets up PMP itself (`pmpaddr0 = -1`,
  `pmpcfg0 = 0x1F`), reads `mhartid` itself, and keeps time through CLINT
  MMIO. All of that holds on this map.
* **16 MB is the whole budget.** The kernel's text, data, initramfs and page
  cache all come out of the same 16 MB, so the kernel config has to be small.
  The flash holds the images compressed or not, whichever keeps the copy loop
  simple.

## Verification

* The core-level flow (river_core, `tests/directed`) runs the core on this
  map. The testbench models 16 MB of PSRAM at `0x8000_0000`, answers the flash
  window with zeros, and starts the core in PSRAM (`boot_addr =
  0x8000_0000`), where Spike starts.
* Spike is given `-m0x20000000:0x1000000,0x80000000:0x1000000`.
  **Spike has no read-only memory**, so a store to flash succeeds on Spike and
  faults on the core. That is a known, spec-legal divergence. No
  Spike-compared test stores to flash; `pma_flash` checks the flash faults
  DUT-only (LR cause 5; SC, AMO and stores of every width cause 7; mtval =
  the address).
* `tests/directed/run.sh soc` runs the same directed suite through the real
  memory path (bus fabric, memory controller, QSPI engine and a behavioural
  flash/PSRAM model, `tb/qspi_pmod_model.v`), compared against the same Spike
  references. The SoC boots from flash, so for a PSRAM-linked test the
  testbench loads the image into the model's PSRAM through the back door,
  forces the core's `boot_addr` to `0x8000_0000` and traces from there. The
  first fetch still goes through the fabric and the QSPI engine, and waits
  for the start-up sequence; every register is 0 on entry, as on Spike,
  which starts the hart at `--pc` with no boot ROM. MANIFEST mode `flash`
  tests are flash images, boot from the real `boot_addr` and are traced
  from reset (`flash_boot`: runs from flash, copies a routine to PSRAM,
  runs it there; `straddle_flash_end`: a 32-bit instruction at the last
  halfword of flash), so they exercise the order silicon uses. Tests that
  assume a fast memory -- timer periods of 37-100 clocks, reading `cycle`
  right after writing it -- are listed in `#soc-skip` lines; `t_irq_slow`,
  `irq_stress`, `t_ctl_slow` and `lrsc_trap_clear` (LR/SC under timer
  interrupts) cover interrupts at QSPI speed. MANIFEST `soc` lines run `flash_boot` and
  `irq_stress` again with the Pmod model's hostile hand-over states and with
  late sampling (`+RD_LATE`, a 25 ns round trip) on page-wrapping PSRAM.
* `make test-qspi` runs `tb_qspi` (every transfer shape, page and chip
  boundaries, arbitration) across device delays, the `rd_late` strap, a
  page-wrapping PSRAM and devices handed over in QPI / quad and dual
  continuous-read modes (one PSRAM in QPI and the other not, too), then
  `tb_qspi_stress` (core-shaped request streams, 400k clocks of random
  traffic against a shadow memory), twice more with resets dropped into
  the traffic and aimed at the start-up sequence (each run requires resets
  landing in it and in its 16-clock step). The Pmod model checks protocol, bus contention, tCEM, tCPH,
  tRST and SCK's period and duty per command as it goes, and closes the
  read data eye between its hold (`+QSPI_HOLD`) and delay.
* The peripherals are not reachable from the directed suite (its IO window
  is off, since Spike has no such devices), and Spike could not lockstep
  them anyway. They are checked self-checking instead:
  * `make test-uart`: `tb_uart` -- every offset, byte enable and DLAB
    state against a scoreboard, TX predicted on every clock from the 16x
    tick grid, RX from a reference transmitter across baud error, glitches,
    framing errors, breaks and overrun, RTS#, IIR, same-cycle priorities,
    divisor reload, constrained-random traffic.
  * `make test-gpio`: `tb_gpio` -- registers and pins every clock, the IN
    synchroniser's latency, a mode-3 SPI checker at every DIV, and the
    write back-pressure that keeps CS#/D/C still under a byte.
  * `make test-soc-periph`: `tb_soc_periph` runs flash-booted programs
    (`tests/soc/`) through the whole SoC against board models --
    `tb/rp2350_uart_model.v` (CTS-honouring terminal), `tb/ssd1331_model.v`
    (the OLED's serial timing, table 21) and `tb/keypad_model.v` -- with
    `req_hold_check` on both core ports: hello-world with and without
    polling, echo under flow control, a replay of the Linux 8250 driver's
    polled accesses, OLED bring-up, keypad scan, timer interrupts while a
    peripheral holds a store, every access width and AMO on the IO, and
    stores to every other target at the CLINT's offsets (`clint_decode`:
    only a CLINT store may write the CLINT).

## Area

Standard-cell area before placement, in tiles (1 tile ≈ 11,300 µm² at
TinyTapeout's 60% density). With the area cuts in `docs/area-audit.md`
applied, LibreLane's own synthesis (TT's flow, ttsky26c) puts the whole SoC at
**12.52 tiles, 2,238 flops** (16.58 tiles before the cuts), against about 7
tiles for a 4x2 slot. The yosys recipe the audit uses to rank cuts gives
10.07 tiles: it lets yosys use cells LibreLane excludes, so its figures run
about 20-24% low. The largest blocks, hierarchical with TT's cells: register
file 3.68, CSR 2.65, core glue 2.67, muldiv 0.93 tiles. The SoC blocks added
here cost about 0.7 tiles flat in the recipe (qspi_ctrl 0.24, mem_ctrl 0.07,
the UART 0.29 with 77 flops, GPIO with its SPI transmitter 0.12; soc_bus
mostly folds away). No harden of the SoC has completed yet (hold buffers on
the register file's enable loops stop detailed placement; see "TinyTapeout
flow check" in `docs/area-audit.md`); fit and timing are settled in the
TinyTapeout submission repository.

## Performance

Every fetch and every data access is a full QSPI transaction. With the
PSRAMs in QPI mode a 4-byte PSRAM read is 20 SCK cycles (about 44 core
clocks) and a flash read 28 (about 60). A taken branch also wastes the
fall-through fetch, because a redirect waits for the outstanding fetch to
complete.

Measured through the whole SoC (`tests/directed/run.sh soc`, clocks per
traced instruction, every test with at least 40 instructions): **77.3
before PSRAM QPI, 57.1 after, −26%**; the longest test, t_memstress (3,027
instructions of loads and stores), went from 77.0 to 55.8. flash_boot,
which runs from flash, moved only 5%. Re-measured by the 2026-09-29 area
review at `4b4ed8b`, the same suite gives 59.2 in aggregate (63.9 as a
mean of per-test figures, wfi_slow alone at 136), and a compiled-C
benchmark 56.1: about 0.89 MIPS at 50 MHz, a clock no timing analysis has
confirmed yet (0.53 MIPS at 30 MHz). Per instruction: ALU 42 clocks; `lw`,
a taken branch and every M op 84; `sw` 76; `sb` 64.

Options not yet taken, roughly in order of payoff per gate:

1. **Keep the fetch stream open.** Leave chip select low after a fetch and,
   if the next fetch is sequential, keep clocking. The review estimates about
   1.6x, because every load, store and taken branch closes the one shared
   bus, for about 0.5–0.7 kGE. It also ends the refetching during WFI and
   M-op stalls. It must close the stream at every 1 KB PSRAM page and within
   tCEM, and it is the heaviest to verify.
2. **Stop the two wasted fetches (prototyped, for a follow-up branch).**
   A taken branch pays for the fall-through fetch already in flight, and an
   M op starts only after a fetch completes and then discards it, so both
   cost one extra QSPI read (about 42 clocks). Holding `imem_req` low while
   a branch or jump is in EX, and letting `muldiv_start` ignore only a
   pending fetch, fix both at 0.00 tiles with no change to the
   request/ready contract: a taken branch drops from 84 to 43 clocks, an M
   op from 84 to 42, a not-taken branch rises from 42 to 43, and the
   compiled-C benchmark goes from 56.1 to 48.3 clocks per instruction
   (−14%). Prototypes in `localFiles/area-audit/pr5/`; kept off this branch
   by decision (2026-09-29).

3. **SCK = clk.** Anywhere between no gain and 2x, depending on whether the
   core or the pads limit the clock. With a round trip over 20 ns it needs
   multi-cycle sampling and a gated clock output, and the TinyTapeout pads
   toggle at about 33 MHz at most, so it only helps at a core clock of 33 MHz
   or less.

Declined: flash continuous read or QPI (`docs/qspi-memories.md` §9.4, 28 →
20 or 16 SCK per flash read). The decision (2026-09-26, §9.3 there) is PSRAM
QPI only; the flash keeps the quad I/O `0xEB` read with mode byte `0xFF`.
