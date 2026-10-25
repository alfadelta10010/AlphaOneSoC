# AlphaOneSoC roadmap

Where the design goes after PR #11 (main `b8d8627`, 2026-10-23), and every
approach considered on the way, including the ones not chosen and why. Area is
in TinyTapeout tiles (1 tile = 11,300 µm² of cells at 60% density). Figures
marked *estimate* have not been synthesised; nothing here is measured unless
it cites a run.

## 0. Decisions and constraints

| Decision (2026-10-23, user) | Consequence |
|---|---|
| **Stay at 3x4 (12 tiles).** A 4x4 slot was considered and not taken. | Every addition below must fit the current die. |
| The SPI transmitter becomes a **general SPI controller**, with an **SD card and the OLED** on one bus. | Section 1.1. |
| **syscon** gets reboot, power-off and the rest of what a syscon block usually does. | Section 1.2. |
| Order: **lock the RTL**, then the **Verilator port and Linux bring-up**, then **FPGA ports** as a stretch goal. | Sections 1-2, then 3-4, then 5. |
| Explore **power domains and power optimisation**. | Section 6. |
| This branch targets the **sky26d** shuttle unless the user decides otherwise (2026-10-24). | Every area, timing and pin figure is for sky26d. |

The limits every item is judged against:

* **Area.** The 3x4 harden at 16 ns (`macro/rf_top/README.md`, b5077cd + hold
  guard) has 14.36 tiles of standard cells at **69.9% utilisation**, about
  15% of it repair and hold buffers. It routed clean. Nothing has been
  hardened above 70% at 3x4; the 6x2 attempt at 80% failed detailed placement
  (`docs/area-audit.md`). Treat about **0.5 tile of new RTL** (at synthesis)
  as the comfortable budget and anything above as needing a harden to prove it.
* **Memory is the speed limit.** About 48 clocks per instruction on compiled
  C, against 3.3 with zero-wait memory: over 90% of the time the core waits
  for QSPI. The QSPI clock is the core clock / 2 = 31.25 MHz, and TT's pads
  toggle at about 33 MHz, so a faster core clock does not make memory faster.
  Speed comes only from fewer or cheaper bus transactions.
* **Pins.** 24 in total. `uio[7:0]` belong to the QSPI Pmod. `uo_out[7]` is
  the only unused output. Inputs `ui_in[1,2,4..7]` are GPIO, DIP switches or
  keypad rows.

## 1. RTL work before the lock

### 1.1 General SPI controller (SD card + OLED)

**Today** (`src/gpio.v`): a transmit-only, mode-3, MSB-first byte shifter
inside the GPIO block. DATA (+0x08) starts a byte; CTRL (+0x0C) has EN (MOSI
and SCK take over OUT bits 1 and 3), a 2-bit DIV (SCK = clk / 2^(DIV+1), so
clk/2 to clk/16) and BUSY. Any register write waits while a byte shifts, which
is what keeps CS# and D/C (plain OUT bits) steady around a byte. At 62.5 MHz
the SSD1331's 150 ns minimum SCK period needs DIV = 3 (3.9 MHz).

**What it lacks for an SD card:**

| Need | Why | Change |
|---|---|---|
| Receive (MISO) | Every SD response and data block comes back on MISO | Synchronise MISO, shift it into the same shift register on the sampling edge, keep the received byte readable |
| 100-400 kHz during card initialisation | SD spec: identification mode runs at 400 kHz or less | 8-bit divisor: SCK = clk / (2 x (BAUD + 1)), 122 kHz to 31 MHz at 62.5 MHz. Data transfer at 15.6 MHz (BAUD = 1, under SD's 25 MHz) |
| Mode 0 | SD's SPI mode is mode 0 (most cards also work in mode 3); the OLED is mode 3 | CPOL and CPHA bits |
| A second chip select | SD and OLED share MOSI/SCK | SD CS# on `uo_out[7]` as an ordinary OUT bit |

**Register interface: copy OpenCores `tiny_spi`** so that Linux's upstream
driver `drivers/spi/spi-oc-tiny.c` (compatible `opencores,tiny-spi-rtlsvn2`,
checked in torvalds/master 2026-10-23) runs it unchanged:

| Offset | Register | Meaning (from the driver) |
|---|---|---|
| +0x00 | RXDATA | read: the byte received with the last byte sent |
| +0x04 | TXDATA | write: queue a byte. Read: the byte received with the byte before the one now shifting |
| +0x08 | STATUS | bit 0 TXE: shifter and holding register empty; bit 1 TXR: holding register empty |
| +0x0C | CONTROL | bits 1:0 = SPI mode (CPHA bit 0, CPOL bit 1) |
| +0x10 | BAUD | SCK = clk / (2 x (BAUD + 1)); width given by the `baud-width` DT property |

* The driver is polled when the node has no `interrupts` (IRQ optional), and
  takes chip selects from `cs-gpios`, i.e. the GPIO OUT bits through Linux's
  `gpio-mmio`. No SPI driver needs writing.
* **The driver needs real double buffering.** Its polled loop writes byte
  n+1, waits for TXR, then reads byte n's answer from TXDATA. A holding
  register (8 flops) gives exactly that. A cheaper variant (no holding
  register; back-pressure on TXDATA; TXR always 1; an RX latch captured when
  the next byte is accepted) also satisfies this loop, but it departs from
  tiny_spi's semantics. Prefer the exact semantics unless area forces it, and
  test either against a C model of the driver loop.
* **The driver keeps one mode for all devices.** `tiny_spi_setup()` stores the
  mode of the last device set up, and every transfer writes that mode. Run
  both devices in mode 3 (`spi-cpol; spi-cpha;` on the mmc-spi-slot node) or
  check at bring-up that the mode is rewritten per device.
* **Keep the back-pressure on OUT writes** while a byte shifts: it is how bare
  metal can write `DATA; OUT(D/C)` without polling, and it costs nothing.
* **Address.** Option A (preferred): inside the GPIO window, e.g. GPIO at
  +0x00/+0x04, SPI at +0x20..+0x30. `soc_bus` passes more address bits, and
  the core's PMA and its formal harness are untouched. Option B: its own
  64 KB window at 0x1003_0000 (bus index 3), which moves `PMA_IO1_TOP` and so
  touches the core and `core_req_props.sv`.
* **Pins.** `uo_out[7]` = SD CS# (today spare / 7-segment DP). MISO on
  `ui_in[1]` (DIP 2, must be off; RP2350 GPIO18 left as an input). The SD card
  tri-states MISO while deselected: put a 10-100 kΩ pull-up on the card side
  of the PCB. One board spanning the OUT and IN headers carries both devices.
* **More pins, if wanted later.** RES# can come from an RC power-on reset on
  the PCB (VCCEN still following it), which frees `uo_out[6]`; the OLED then
  cannot be reset by software. CS# can be tied low only when the OLED is alone
  on the bus. D/C stays unless a 3-wire (9-bit) SPI mode exists on the panel
  used (check the SSD1331 datasheet; the PmodOLEDrgb is wired 4-wire).
* **Linux stack:** `spi-oc-tiny` + `gpio-mmio` (CS#, D/C, RES#) +
  `mmc_spi` (SD) + staging `fbtft` `fb_ssd1331` (OLED; confirm it is still in
  the target kernel).
* **Cost:** about +0.1 to +0.15 tile over today's shifter (*estimate*: a
  holding register, an RX register, an 8-bit divisor and its counter, mode
  logic, a MISO synchroniser).
* **Verification:** spec-model unit bench (all four modes, every divisor edge
  case, back-to-back bytes, the driver's polled loop), an SD-card SPI model on
  the SoC bench (CMD0/CMD8/ACMD41/CMD17/CMD24), the existing SSD1331 model,
  mutation faults for the new block.

### 1.2 syscon (0x1002_0000)

**Status (2026-10-23): built** as `src/syscon.v` (`8d54e14`) and wired into
`alphaone_soc` (`8b29cf8`); the as-built map and reset architecture are in
`docs/soc-architecture.md`, section "syscon". It departs from the proposal
below in these ways:

* CLK_GATE (+0x14) and POWER (+0x18) are reserved: they read 0 and ignore
  writes (no clock gating exists yet; section 6).
* RESET_CAUSE has PIN and SOFT, plus WDT since the watchdog (below); there is
  no power-on bit. TinyTapeout has no power-on-reset cell, so power-on cannot
  be told from a pin reset. The bits accumulate: software that wants the last
  reset's cause alone reads it at boot and writes `0x7` to clear it.
* FAIL (`0x3333`) halts the chip like power-off.
* There is no flash deep power-down (`B9h`) at power-off.
* The reset generator is in `alphaone_soc`, not in the wrapper, so the
  wrapper and the SoC's ports are unchanged.
* The test mailbox landed at +0x7F0, +0x7F4, +0x7F8 (+0x7FC spare), as below.
* CHIP_ID is `0x4131_5301`.
* The optional watchdog is built (`a133652`) in the Synopsys DesignWare layout
  at +0x100, so Linux's `dw_wdt` runs it unchanged. RESET_CAUSE gained bit 2
  (WDT). syscon is 0.151 tile, 23 flops with it. See "Watchdog" in
  `docs/soc-architecture.md`.

Linux needs nothing more than a generic register block with the `syscon`
compatible; the functions come from small generic drivers that point into it.

| Function | Linux driver / binding | Hardware |
|---|---|---|
| Power-off | `syscon-poweroff` (regmap, offset, value, mask) | Write 0x5555 to FINISH. Halts the SoC (below) |
| Reboot | `syscon-reboot` | Write 0x7777 to FINISH. Whole-SoC reset, as from the pin |
| Simulation exit | QEMU `virt`'s `sifive,test0` convention: 0x5555 pass, `(code << 16) | 0x3333` fail, 0x7777 reset | The same register. Benches stop on it; software is identical to QEMU's |
| Reboot reason / boot mode | `syscon-reboot-mode` (`mode-normal`, `mode-bootloader`, ...) | BOOT_MODE: 8 bits that survive a soft reset |
| Reset cause | read by firmware or `devmem` | RESET_CAUSE: power-on / pin / software / watchdog, sticky |
| Chip identity | firmware, `/sys/bus/soc` | CHIP_ID / VERSION: constants, no flops |
| Straps | firmware | STRAPS: `rd_late` as latched at reset |
| Clock gates, sleep states | firmware first; a Linux clock/power driver later | Section 6 |
| Pin mux | `pinctrl-single` (`pinctrl-single,bits`) | Optional: move the SPI EN bit here |
| Watchdog | needs a driver or an existing register map | Optional, about 0.1 tile for a 32-bit counter (*estimate*). Area permitting only |

Proposed map (word registers):

| Offset | Name | Access | Reset by |
|---|---|---|---|
| 0x00 | FINISH | W: 0x5555 off, 0x7777 reboot, 0x3333 fail | - |
| 0x04 | RESET_CAUSE | R (W1C) | power-on / pin only |
| 0x08 | BOOT_MODE | R/W | power-on / pin only |
| 0x0C | CHIP_ID | R | constant |
| 0x10 | STRAPS | R | latched at reset |
| 0x14 | CLK_GATE | R/W | any reset |
| 0x18 | POWER | R/W: sleep mode select | any reset |

**Reset architecture.** Reboot cannot simply assert the wrapper's reset: the
syscon would reset itself mid-write and lose RESET_CAUSE and BOOT_MODE. The
write should raise a synchronous request into the reset generator in
`tt_um_*`, which holds the SoC reset for N clocks; RESET_CAUSE and BOOT_MODE
sit on the pin-only reset. While reset is high the QSPI pins are released, so
a reboot also hands the bus back briefly (harmless; the start-up sequence
already recovers any device state, REQ-QSPI-002). Open: whether the PSRAM
reset (`66h`/`99h`) in the start-up sequence keeps the array contents; if it
does, `ramoops`/pstore can carry a crash log across a reboot.

**Power-off on a chip that cannot cut its own supply** means: gate the core
and peripheral clocks (section 6), put the flash in deep power-down (`B9h`),
leave the PSRAM deselected (standby), keep only the reset logic alive. Only
`rst_n` brings it back.

**Test mailbox: done.** FINISH uses the QEMU sifive_test codes (WO-12,
d3cfd91, 28e95bf, 8e59169). EVENT, VALUE and VALUE2 are at +0x7F0, +0x7F4 and
+0x7F8 (+0x7FC spare), not +0xF00: a 12-bit store offset from SYSCON cannot
reach +0xF00. The syscon must leave those words RAZ/WI.

**Spike.** The window is outside Spike's memory, so a store there faults in
Spike. Lockstep tests must stop before it, or Spike gets a plugin device
(`--extlib`) for it.

**Cost:** about +0.1 to +0.2 tile (*estimate*: about 20-40 flops, a reset
request path).

### 1.3 Fetch word reuse

Every instruction is fetched on its own: the core asks for the 4 bytes at the
pc (`fyracore.v`, `imem_addr = pc`), and one QSPI read costs about 42 clocks.
A compressed (16-bit) instruction uses only the first 2 of those 4 bytes; the
other 2 are the start of the next instruction, and today they are thrown away.

```
address:   0x100   0x102   0x104   0x106
code:      c.addi  c.mv    c.lw    addi (32-bit, 0x106-0x109)

today:     fetch @0x100 -> bytes 100..103: run c.addi, discard 102..103
           fetch @0x102 -> bytes 102..105: run c.mv,   discard 104..105
           fetch @0x104 -> ...                         (4 fetches for 4 instructions)

reuse:     fetch @0x100 -> run c.addi, keep 102..103
           0x102 is in hand and is 16-bit -> run c.mv with no fetch
           fetch @0x104 -> run c.lw, keep 106..107
           0x106 starts a 32-bit instruction -> only half in hand -> fetch @0x106
```

Rule: after a fetch that returned a compressed instruction, keep its upper
halfword and a valid bit. If the next pc is sequential and that halfword is a
complete compressed instruction (bits 1:0 != 11), issue it without a fetch.
Clear the valid bit on every redirect (branch, jump, trap, interrupt, MRET),
on FENCE.I and on reset. A store to the kept halfword need not clear it:
Zifencei only promises that instruction fetch sees stores after a FENCE.I.

* Saves one fetch for each compressed instruction that follows a fetched
  compressed instruction, so at most half the fetches in runs of compressed
  code. On compiled C, with roughly half the instructions compressed, it
  might save 10-25% of fetches (*estimate*: measure it by counting C-after-C
  pairs in a Spike trace of compiled code before building it).
* Cost: about 17 flops and a 16-bit mux in IF, about 0.05-0.1 tile
  (*estimate*). No change to the memory controller or QSPI protocol.
* Risks: the instruction that runs from the buffer was never "fetched", so
  the trace, the fetch PMP check (it checks `ifex_pc`, not the fetch, so it
  still applies) and `tb_rivercore`'s transaction checker (every fetch matches
  a request) need to agree with it.
* Alternative in the memory controller: a last-word buffer in `mem_ctrl`
  (about 0.1 tile) also serves refetches after stalls, but still costs a
  request/ready round trip per instruction.

### 1.4 Area to win back

All small; together they could pay for most of 1.1-1.3.

| Candidate | Saving | Status |
|---|---|---|
| FC02: `csr_wb_hazard` is a dead stall term under the 3-cycle EX | small | proved equivalent (VPLAN 4.2) |
| FC49: the three `flush` gates on the M handshake are dead | small | proved equivalent (VPLAN 4.2); needs STA |
| UART 8-bit divisor | -0.06 tile | no rates below 12.2 kbaud at 50 MHz |
| UART fixed divisor | -0.09 tile | software cannot change the baud rate |

### 1.5 Open decisions that touch the lock

SA-006 is settled as a doc fix (1a845f5; wfi_umode pins the NOP, WO-10). The
CLINT window is settled in the testbench (WO-11: 0x0200_0000-0x0200_BFFF, MEIP
hook at 0x0200_8000); the RTL keeps its 64 KB window. TT01 is settled
(2026-10-24): the wrapper keeps releasing the pins on the second edge after
`rst_n` rises, one edge after the SoC's flops first take their reset values.
No RTL bench can tell that from the first edge, but the demo board resets
with the clock stopped and TinyTapeout confirms that a glitch at that edge
would reach the pins (`tb/VPLAN.md` 4.2, `docs/pins-and-peripherals.md` 1).

### 1.6 The lock gate

1. area-optimizer measures each block above in tiles.
2. pd-expert hardens 3x4 at 16 ns with all of them: routed, DRC/LVS clean, no
   hold violation, setup met at every corner, utilisation recorded.
3. Full verification: test-all, directed core and SoC, formal, seeds,
   mutation on the new blocks, the river_core regression (the fetch-reuse
   change touches the pipeline), gate-level on the TT flow.

## 2. Verification status and plan

### 2.1 Formal coverage at main `b8d8627`

`tb/formal/run.sh`, yosys's built-in SAT solver (no SMT solver is installed,
so no SymbiYosys):

| Harness | Mode | Proves |
|---|---|---|
| `csr` | k-induction, PROVED | P1-P8: mstatus.MPP in {U, M}; no stray mstatus/mie/mcounteren/mcountinhibit bits; mtvec direct; pmpcfg reserved bits 0 and no R=0/W=1; misa constant except C; mepc alignment |
| `core_hold` | k-induction (length 1), PROVED | Both memory ports hold the request (address, we, be, wdata) until ready; x0 is never written |
| `core_req` | bounded, 10 cycles from reset | Every request is legal: fetch halfword-aligned and in flash/PSRAM; data word-aligned, in a mapped window, legal byte lanes, store data replicated, no store to flash |

By the verification plan's own count, **4 of its 56 requirements** are proved
or bounded formally (REQ-CSR-003, REQ-RF-003, REQ-MEM-001, REQ-MEM-002 to 10
cycles), with slices of 2 more (misa in REQ-CSR-004, pmpcfg reserved bits in
REQ-CSR-005). Everything else (ISA results, traps, interrupts, PMP matching,
LR/SC, counters, every SoC block) is simulation only. In the mutation
campaign the formal harnesses killed 6 of 29 CSR faults and 9 of the 11 core
faults tried on them. Three survivors were shown equivalent by separate
k-induction proofs (MD07, FC02, FC49), which are not part of `run.sh`.

### 2.2 Next formal steps, by value

1. **Install a real solver stack** (SymbiYosys + Bitwuzla or Yices, e.g. the
   oss-cad-suite) on the sandbox: deeper BMC, cover statements, liveness.
2. **riscv-formal through an RVFI port** (simulation/formal-only `ifdef`,
   zero area): per-instruction checks for RV32IMC, register and pc
   consistency, causality, liveness. It covers the ISA rows that are
   simulation-only today. It does not check the A extension, and its CSR
   checks are limited; the directed suite keeps those.
3. **New blocks get formal from the start:** SPI (mode timing, no MOSI change
   near a sampling edge, one byte per write), syscon (reset request cannot
   glitch, sticky registers survive soft reset), fetch reuse (equivalence: the
   same instruction stream with and without the buffer).
4. **SoC properties:** the bus rule (an IO target drops ready only while
   selected), `mem_ctrl` (data-first, no starvation, bounded), QSPI engine
   (tCEM, never selects flash for a write).
5. Turn the MD07/FC02/FC49 equivalence proofs into `run.sh` harnesses.

### 2.3 Other verification still owed

River_core regression and gate-level runs on the PR #11 tree (not run on the
branch); the SoC mutation campaign's two survivors; an 8-seed run.

## 3. Verilator port

Needed because Icarus runs about 30k cycles/s and a Linux boot through QSPI
is billions of cycles.

* The QSPI Pmod model and other benches use `#` delays: build with
  `--timing` (Verilator 5) or rewrite the models as clocked logic. Porting
  effort unknown.
* Two targets: the core with fast memory (lockstep with Spike until the first
  timer interrupt, UART text after), and the full SoC through the pins with
  the Pmod model (pass = the shell answers).
* Keep Icarus as the reference simulator for the existing suites; Verilator
  must give byte-identical traces on them first.
* Reference: georgc4/rv32-linux-soc's Verilator Linux-acceptance CI
  (`localFiles/rv32-linux-soc`).

## 4. Linux bring-up

Plan in `localFiles/PROGRESS-2026-10-12.md` section 7. In short:

1. **Spike golden boot.** KianV's nommu buildroot recipe
   (`localFiles/kianRiscV`, Linux 6.8-rc1, HZ=30) rebuilt with C enabled,
   device tree for this map. Spike's default platform already has CLINT at
   0x0200_0000, an ns16550 at 0x1000_0000 and RAM at 0x8000_0000 (to confirm).
2. **Core level in Verilator**, then **SoC through the pins**.
3. Device tree: `riscv,clint0`; `ns16550a` with `reg-io-width = <1>`, no
   `interrupts` (expect the harmless `-ENXIO: IRQ index 0` line); 16 MB at
   0x8000_0000; `syscon` + `syscon-poweroff` + `syscon-reboot` +
   `syscon-reboot-mode`; `gpio-mmio`; `opencores,tiny-spi-rtlsvn2` with
   `cs-gpios`; `mmc-spi-slot`; `fbtft` SSD1331.
4. Kernel: NOMMU, `CONFIG_RISCV_M_MODE`, RVC, `SPI_OC_TINY`, `MMC_SPI`,
   `POWER_RESET_SYSCON(_POWEROFF)`, `SYSCON_REBOOT_MODE`,
   `GPIO_GENERIC_PLATFORM`, `FB_TFT_SSD1331`.
5. Root filesystem: initramfs first (fits the 16 MB flash), then SD.
6. A flash loader at 0x2000_0000 copies DTB and Image to PSRAM (KianV's
   layout: loader 1 MiB, DTB 1.5 MiB, Image 2 MiB).

## 5. FPGA ports (stretch)

Two kinds, both worth having:

* **Board twin:** the same SoC with the real QSPI Pmod, OLED and SD Pmod, at
  25-50 MHz. Proves the board path before silicon.
* **Fast variant:** the same core with on-board RAM (BRAM, SDRAM) behind the
  same request/ready port, for Linux development in minutes instead of days.

| Board | Why | Toolchain | Fit |
|---|---|---|---|
| Digilent Arty A7-35T/100T | Four Pmod ports: QSPI Pmod, PmodOLEDrgb and PmodMicroSD plug in as on the demo board; 256 MB DDR3 for the fast variant | Vivado (free) | Easy |
| Radiona ULX3S (ECP5) | 32 MB SDRAM, microSD slot, OLED header | yosys + nextpnr-ecp5 (open) | Easy |
| Sipeed Tang Nano 20K (Gowin) | Cheap, 8 MB SDRAM in package | yosys + apicula (open) | Likely |
| iCEBreaker (iCE40UP5K) | Pmods, open tools, 128 KB SPRAM | yosys + nextpnr-ice40 | Unknown: 5,280 LUTs; check with `synth_ice40` first |

* `rf_top` becomes any synchronous-read RAM: `regFile`'s bypass already
  supplies the written word on a read/write collision, so the RAM's own
  collision behaviour does not matter.
* Reuse the `tt_um` wrapper as the top, so the pin map is the chip's.

## 6. Power

### 6.1 What the platform allows

* **TinyTapeout already power-gates each project as a whole** (added in round
  6 for every design): unselected projects are off. Inside the project there
  is one 1.8 V supply (VPWR/VGND); only the analog template adds a 3.3 V rail.
* **The sky130 `hd` library has no power-switch (header/footer) cell.** It
  does have isolation cells (`lpflow_inputiso*`, `lpflow_isobufsrc*`),
  keep-alive clock buffers (`lpflow_clkbufkapwr*`), level shifters and a
  bleeder (`libs/sky130_fd_sc_hd__tt_025C_1v80.lib`), and clock-gate cells
  (`dlclkp`, `sdlclkp`).
* **No retention flops** in `hd`: a powered-down block loses its state.
* **The flow has no power intent** (no UPF in LibreLane, Icarus or yosys).

### 6.2 Levels, cheapest first

| Level | What | Gain | Cost / risk |
|---|---|---|---|
| L0 Measure | Gate-level VCD of real workloads (boot, OLED frame, idle WFI) into OpenSTA `report_power`, per block; on the sandbox, one job at a time | Tells where the power is; nothing else here is sized without it | Flow work only |
| L1 System | Fewer QSPI transactions (fetch reuse, later a stream or cache): every transaction toggles 3.3 V pads and off-chip lines, likely the largest single consumer. Flash deep power-down (`B9h`) when idle. OLED display off. Lower clock from the RP2350 | Large, mostly free | `B9h` needs a QSPI-engine command; a lower clock changes Linux's timebase |
| L2 Activity | Load enables instead of free-running flops (`alu_r`, `br_r` load every cycle today); operand isolation on the M unit and the 32-bit buses when idle | Moderate | Small area; must not touch the critical paths that set 62.5 MHz |
| L3 Clock gating ("logical power domains") | `dlclkp` gates on: the core during WFI (wake on any enabled pending interrupt), each peripheral (UART, SPI/GPIO), and everything but the reset logic on power-off. CLINT `mtime` stays on the ungated clock so the timer can wake the core | Large while idle: the clock tree is a big share of dynamic power | CTS and STA with gated clocks; our ICG register-file attempt (area-opt, patch 14) failed TT lint (MULTIDRIVEN) and grew hold-fix buffers. Start with one coarse gate (core in WFI) and harden it |
| L4 Power gating | Real switched domains: a custom header-switch macro, a split PDN, isolation cells on the domain's outputs, state saved to always-on flops or PSRAM first | Leakage only, which is small at the typical corner for this design size | No switch cell in `hd`, no UPF, no power-aware simulation; research tile on a future shuttle, not this SoC |

### 6.3 Sleep states (with syscon POWER and CLK_GATE)

| State | Clocks running | Wake |
|---|---|---|
| RUN | all | - |
| IDLE (WFI) | everything except the core | any enabled pending interrupt |
| DEEP | CLINT and the reset logic; flash in deep power-down | timer, external interrupt pin |
| OFF (power-off) | reset logic only | `rst_n` |

Wake logic must come from ungated state: `mip & mie` (mie is static while the
core's clock is off) and the CLINT compare.

## 7. Beyond the lock

Considered on 2026-10-22, kept for later:

* **Keep the fetch stream open:** leave CS# low and keep clocking while
  fetches are sequential. About 1.6x (review estimate), about 0.5-0.7 kGE;
  must close at each 1 KB PSRAM page and within tCEM; the heaviest to verify.
* **Instruction cache:** 256 B direct-mapped from two more RF macros plus
  tags, about 2.4 tiles (*estimate*). Needs the 4x4 slot that was not taken.
  Size it first with a cache simulator on a Spike Linux trace.
* **JTAG debug module** (halt, resume, abstract register access; the demo
  board's RP2350 as the probe): about 1.5-3 tiles (*estimate*), 3 inputs and
  1 output. A UART-based debug bridge costs no pins but is non-standard.
* **Code-size extensions** (Zcb; Zcmp push/pop): fewer bytes fetched. Zcmp
  needs a sequencer and kernel support checked.
* **UART interrupt with an RX FIFO**, a small interrupt controller, a
  timer/PWM block, a watchdog.
* **A standard peripheral bus** (Wishbone, OBI or APB) behind `soc_bus`, so
  existing open-source peripherals drop in.
* **Parameterise the core** (PMP entries, C, M unit kind, memory map) for
  smaller TT slots and FPGA builds.
* **S-mode + Sv32 MMU** for MMU Linux: about 2.5-3.5 tiles (*estimate*), and
  very slow at about 1 MIPS with page walks over QSPI.

Not worth doing while memory-bound: Zba/Zbb, a faster multiplier, forwarding,
vectored mtvec, a faster core clock (QSPI is pad-limited). Rejected earlier:
SCK = core clock (pads), flash continuous read or QPI (decided 2026-09-26),
a PLIC (all devices are polled).

## 8. Order

1. Settle 1.5's open decisions; move the test mailbox (1.2).
2. syscon (1.2), then the SPI controller (1.1), then fetch reuse (1.3), each
   through the tiered agent pipeline, with formal from the start (2.2 item 3).
3. Area pass (1.4), harden and the lock gate (1.6).
4. Solver stack and riscv-formal (2.2 items 1-2), in parallel with step 5.
5. Verilator port (3), Linux bring-up (4).
6. Power: L0 measurements anytime after the lock candidate exists; the WFI
   clock gate (L3) decided by those numbers before the lock; L4 as research.
7. FPGA ports (5).
