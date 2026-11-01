# AlphaOneSoC roadmap

Where the design goes, and every approach considered on the way, including
the ones not chosen and why. Written after PR #11 (main `b8d8627`,
2026-10-23); brought up to date after PR #14 (main `a2f7285`, 2026-10-31), by
which time syscon (1.2), fetch word reuse (1.3) and the SPI controller (1.1)
were merged. The design's size is in whole TinyTapeout tiles with the shape
hardened (3x4 = 12 tiles), with area utilisation and routing density as two
separate percentages. A block's cost is in flops and µm² of standard cells at
synthesis; estimates first written as fractions of a tile are converted at
the old 11,300 µm² per tile. Figures marked *estimate* have not been
synthesised; nothing here is measured unless it cites a run.

## 0. Decisions and constraints

| Decision (user, 2026-10-23 unless dated) | Consequence |
|---|---|
| **Stay at 3x4 (12 tiles).** A 4x4 slot was considered and not taken. | Every addition below must fit the current die. |
| The SPI transmitter becomes a **general SPI controller**, with an **SD card and the OLED** on one bus. | Section 1.1. Merged (PR #14). |
| **syscon** gets reboot, power-off and the rest of what a syscon block usually does. | Section 1.2. Merged (PR #12). |
| Order: **lock the RTL**, then the **Verilator port and Linux bring-up**, then **FPGA ports** as a stretch goal. | Sections 1-2, then 3-4, then 5. |
| (2026-10-31) **The RTL freezes once basic functionality works**, not at the shuttle's close. Software climbs from easy goals up: **FreeRTOS first, then Linux** in the next few PRs. Most of this roadmap stays in scope. | Section 9, the software ladder. |
| Explore **power domains and power optimisation**. | Section 6. |
| This branch targets the **sky26d** shuttle unless the user decides otherwise (2026-10-24). SKY26d closes 2026-11-30 20:00 UTC. | Area figures are sky130 cell-library figures; the harden, timing sign-off and pinout are for sky26d. |
| (2026-11-01) **3x4 is fixed; the clock gives way** when the two conflict. The tree with all three blocks misses 16 ns by 0.303 ns at the slowest corner, so the clock is documented as **60 MHz** (16.67 ns, met at every corner). | `CLOCK_PERIOD` stays 16 ns, so the submission CI rebuilds the layout that was checked. Figures below that depend on the clock are at 60 MHz; 1.7 is the way back to 62.5 MHz. |

The limits every item is judged against:

* **Area.** The last harden (2026-11-01, main `a2f7285` with syscon, fetch
  reuse and SPI; `localFiles/harden-2026-11-01`) is 12 tiles as 3x4, with
  **67.3% area utilisation** (160,752 µm² of standard cells) and **75.8%
  routing density**, DRC, LVS and antenna clean (1.6 item 2). Against the
  PR #12 tree's harden (2026-10-25, `localFiles/harden-2026-10-25`: 68.8% and
  77.9%), fetch reuse and SPI added 42 flops and about 4,000 µm² of flops and
  gates once placed, and timing-repair buffers came to about 8,300 µm² less
  with the hold margin cut from 0.2 to 0.1 ns. **Headroom:** about a third of
  the placement area is free, but routing is the limit. At the 0.2 ns margin
  the PR #12 tree routed with, this tree did not: global routing at 84.6%,
  11.7k detailed-routing violations left after 15 iterations. The 6x2 attempt
  at 80% failed detailed placement (`docs/area-audit.md`). Anything added
  needs a harden to prove it fits, and 1.4 is where room can come from.
* **Memory is the speed limit.** About 43 clocks per instruction on compiled
  C with fetch reuse (53 without; WO-27 A9, `bench.c` at -O2), against 3.3
  with zero-wait memory: over 90% of the time the core waits for QSPI. At
  60 MHz that is about 1.4 million instructions per second. The QSPI clock
  is the core clock / 2 = 30 MHz, and TT's pads toggle at about 33 MHz, so
  a faster core clock does not make memory faster. Speed comes only from
  fewer or cheaper bus transactions.
* **Pins.** 24 in total. `uio[7:0]` belong to the QSPI Pmod. `uo_out[7]` is
  now the SD card's CS# (PR #14), so no output is spare. `ui_in[1]` is MISO
  when the SD card is fitted; `ui_in[2,4..7]` are GPIO, DIP switches or
  keypad rows.

## 1. RTL work before the lock

### 1.1 General SPI controller (SD card + OLED)

**Status: merged** in PR #14 (`a2f7285`, 2026-10-31; design WO-28,
verification WO-29): `src/spi.v` at `0x1001_0020` with the tiny_spi
registers at +0x20..+0x30, SD CS# on OUT bit 7, MOSI and SCK from flops. The
as-built description, the SD-first boot rule and the board setup are in
`docs/pins-and-peripherals.md` sections 3 and 4. Not yet hardened or
measured on silicon. The rest of this section is the design record from
before it was built.

**Before PR #14** (`src/gpio.v`): a transmit-only, mode-3, MSB-first byte shifter
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
* **Address.** Option A (chosen, WO-28 D3): inside the GPIO window, e.g. GPIO at
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
* **Cost:** about +1,100 to +1,700 µm² over the old shifter (*estimate*: a
  holding register, an RX register, an 8-bit divisor and its counter, mode
  logic, a MISO synchroniser). WO-28's estimate for the design as built:
  +24 flops, about +1,150 µm².
* **Verification:** spec-model unit bench (all four modes, every divisor edge
  case, back-to-back bytes, the driver's polled loop), an SD-card SPI model on
  the SoC bench (CMD0/CMD8/ACMD41/CMD17/CMD24), the existing SSD1331 model,
  mutation faults for the new block.

### 1.2 syscon (0x1002_0000)

**Status: merged** in PR #12 (`4c9946a`, 2026-10-30) and hardened at 3x4
(section 0). Built as `src/syscon.v` (`8d54e14`) and wired into
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
  (WDT). syscon is 1,708 µm² and 23 flops with it. See "Watchdog" in
  `docs/soc-architecture.md`.

Linux needs nothing more than a generic register block with the `syscon`
compatible; the functions come from small generic drivers that point into it.

| Function | Linux driver / binding | Hardware |
|---|---|---|
| Power-off | `syscon-poweroff` (regmap, offset, value, mask) | Write 0x5555 to FINISH. Halts the SoC (below) |
| Reboot | `syscon-reboot` | Write 0x7777 to FINISH. Whole-SoC reset, as from the pin |
| Simulation exit | QEMU `virt`'s `sifive,test0` convention: 0x5555 pass, `(code << 16) | 0x3333` fail, 0x7777 reset | The same register. Benches stop on it; software is identical to QEMU's |
| Reboot reason / boot mode | `syscon-reboot-mode` (`mode-normal`, `mode-bootloader`, ...) | BOOT_MODE: 8 bits that survive a soft reset |
| Reset cause | read by firmware or `devmem` | RESET_CAUSE: pin / software / watchdog, sticky (no power-on bit, above) |
| Chip identity | firmware, `/sys/bus/soc` | CHIP_ID / VERSION: constants, no flops |
| Straps | firmware | STRAPS: `rd_late` as latched at reset |
| Clock gates, sleep states | firmware first; a Linux clock/power driver later | Section 6 |
| Pin mux | `pinctrl-single` (`pinctrl-single,bits`) | Optional: move the SPI EN bit here |
| Watchdog | `snps,dw-wdt` (`dw_wdt`) | Built: the DesignWare register layout at +0x100, timed from `mtime` |

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

**Cost:** about +1,100 to +2,300 µm² (*estimate*: about 20-40 flops, a reset
request path). Built: 1,708 µm² and 23 flops with the watchdog, 882 µm² and
14 flops without (`docs/soc-architecture.md`).

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

**Status: merged** in PR #13 (`2937cd5`, 2026-10-30), always on (WO-27).
`if_kbuf` 16 flops + `if_kv`, a 16-bit mux in front of the window mask.
Spike-trace model on compiled C: 24.6% (-Os) to 26.1% (-O2) of fetches
removed. Measured through the SoC bench on compiled C (WO-27 A9, `bench.c` at
-O2, `localFiles/fr-a9-2026-10-30.md`): 26.12% of instruction loads served
from the buffer, 40 clocks saved per hit, **53.15 to 42.70 clocks per
instruction (-19.7%)**, the commit log byte-identical to the run without it.
In the directed benches (mostly `.option norvc`, so the hit rate is low):
`t_memstress` 65 hits in 3027 loads, `fr_pairs` 22 of 78. Checked by the
`fr_*` directed tests (4 of them, `fr_reset`, `fr_irq_sw`, `fr_irq_tmr` and
`fr_smc`, check the DUT against expected values, not against Spike), the
`tb_rivercore` shadow/hit checks, `tb/formal/run.sh core_fetch` and mutants
FR01-FR14. Not yet hardened; the harden, IF-path STA, EQY, gate-level and
full river_core runs come once, on the tree with SPI as well (1.6).

* Saves one fetch for each compressed instruction that follows a fetched
  compressed instruction, so at most half the fetches in runs of compressed
  code. On compiled C, with roughly half the instructions compressed, it
  might save 10-25% of fetches (*estimate*: measure it by counting C-after-C
  pairs in a Spike trace of compiled code before building it). Measured:
  26.1% (above).
* Cost: about 17 flops and a 16-bit mux in IF, about 550-1,100 µm²
  (*estimate*). WO-27's estimate for the design as built: about 750 µm² at
  synthesis, about 1,200 µm² once placed, +0.5 points of utilisation. No change to the memory controller or QSPI protocol.
* Risks: the instruction that runs from the buffer was never "fetched", so
  the trace, the fetch PMP check (it checks `ifex_pc`, not the fetch, so it
  still applies) and `tb_rivercore`'s transaction checker (every fetch matches
  a request) need to agree with it.
* Alternative in the memory controller: a last-word buffer in `mem_ctrl`
  (about 1,100 µm²) also serves refetches after stalls, but still costs a
  request/ready round trip per instruction.

### 1.4 Area to win back

All small; together they could pay for most of 1.1-1.3.

| Candidate | Saving | Status |
|---|---|---|
| FC02: `csr_wb_hazard` is a dead stall term under the 3-cycle EX | small | proved equivalent (VPLAN 4.2) |
| FC49: the three `flush` gates on the M handshake are dead | small | proved equivalent (VPLAN 4.2); needs STA |
| UART 8-bit divisor | -16 flops, about -680 µm² | no rates below 12.2 kbaud at 50 MHz |
| UART fixed divisor | -24 flops, about -1,000 µm² | software cannot change the baud rate |

### 1.5 Open decisions that touch the lock

SA-006 is settled as a doc fix (1a845f5; wfi_umode pins the NOP, WO-10). The
CLINT window is settled in the testbench (WO-11: 0x0200_0000-0x0200_BFFF, MEIP
hook at 0x0200_8000); the RTL keeps its 64 KB window. TT01 is settled
(2026-10-24): the wrapper keeps releasing the pins on the second edge after
`rst_n` rises, one edge after the SoC's flops first take their reset values.
No RTL bench can tell that from the first edge, but the demo board resets
with the clock stopped and TinyTapeout confirms that a glitch at that edge
would reach the pins (`tb/VPLAN.md` 4.2, `docs/pins-and-peripherals.md` 1).

Open (2026-10-31):

* **What "basic functionality" means for the freeze** (section 0). The
  user's call; section 9's lower rungs are candidate checkpoints.
* **The UART's reset divisor.** `UART_DIV_RESET` is 27: 115,200 baud at
  50 MHz, but 138,889 baud at the 60 MHz clock the chip is documented for.
  The divisor is a software register, so this matters only for output sent
  before software writes it; the boot contract (9.1) writes 33 (113,636
  baud) first. Changing the parameter to 33 would make the reset rate right
  too; the benches and gate-level programs that assume 27 (WO-26) would
  follow.

### 1.6 The lock gate

1. area-optimizer measures each block above in flops and µm² at synthesis.
2. ~~pd-expert hardens 3x4 at 16 ns with all of them: routed, DRC/LVS clean,
   no hold violation, setup met at every corner, utilisation recorded.~~
   **Done 2026-11-01** on main `a2f7285` (LibreLane 3.0.14 on the sandbox,
   `localFiles/harden-2026-11-01`): 0 route DRC, Magic DRC, LVS and antenna
   errors; TT precheck passed; the TT cocotb tests pass 3/3 at gate level. No
   hold violation at any corner (worst +0.092 ns, fast corner), and the
   register file's inputs keep +0.128 ns against the ff hold guard band.
   Setup is met at every corner at 16.67 ns (60 MHz) but not at 16 ns: one
   path, from bus address bit 17 (syscon's select) to the CSR write value,
   misses by 0.303 ns at the slowest corner only (max ss; nominal ss is
   +0.315 ns). Utilisation and density are in section 0. Two changes made it
   route:
   * `PL_RESIZER_HOLD_SLACK_MARGIN` 0.2 to 0.1 ns; at 0.2 it did not route
     (section 0).
   * `rf_top` moved from [3, 189] to [3, 60], orientation E. [3, 3], the
     placement with the least global-routing overflow, ended detailed routing
     with 1,075 violations on the macro's nets: rotated to E, one pin row
     faces the die's bottom edge 3 µm away and has no room to escape. Global
     routing does not model pin access, so placements were then screened
     through detailed routing: [3, 189], [3, 30] and [3, 60] all routed
     clean, and [3, 60] had the least overflow (104) and converged fastest.

   Left as found: max-slew violations, 116 at the slowest corner (99 on
   2026-10-25), and max-cap, 5 (1); the flow does not block on them. Power is
   9.37 mW (typical corner, default activity). Worst IR drop is 5.5 mV (0.28%)
   at the fast corner with 20% switching and the stripes fed from their top
   ends only; the flow's own estimate is 0.1 mV. `rf_top`'s liberty reports no
   power, so the register file is missing from both figures.
3. Full verification: test-all, directed core and SoC, formal, seeds,
   mutation on the new blocks, the river_core regression (the fetch-reuse
   change touches the pipeline: rrag and riscv-dv with C, not only the
   compliance suite), gate-level on the TT flow (`scripts/gl`, parts A-D),
   and EQY of the RTL against the new netlist (`tb/eqy`; its FSM cut points,
   tie lists and no-match list were fitted to the 2026-10-25 netlist and
   need fitting again).
4. Port the locked RTL to the submission repo (`localFiles/alphaOneSoC-sky26d`,
   which still has the design from before syscon) and pass its CI.

### 1.7 Back to 62.5 MHz

One path keeps the clock at 60 MHz (1.6 item 2): from `soc.bus.d_addr[17]`,
the address bit that selects syscon, to `soc.cpu.csr_unit.csr_new[22]`,
-0.303 ns at 16 ns at the slowest corner (max ss). The PR #12 tree had
+0.861 ns at that corner (2026-10-25); what moved this path since has not
been analysed. The STA of the routed layout at other periods
(`localFiles/harden-2026-11-01/sta-sweep.sh`) puts the limit at about
61 MHz: +0.090 ns at 16.39 ns. Getting 62.5 MHz back needs a change on main
that takes logic off this path, then another harden and port. The extra 4%
does not make memory faster (section 0).

## 2. Verification status and plan

### 2.1 Formal coverage

`tb/formal/run.sh`, yosys's built-in SAT solver (no SMT solver is installed,
so no SymbiYosys). At main `b8d8627` (PR #11):

| Harness | Mode | Proves |
|---|---|---|
| `csr` | k-induction, PROVED | P1-P8: mstatus.MPP in {U, M}; no stray mstatus/mie/mcounteren/mcountinhibit bits; mtvec direct; pmpcfg reserved bits 0 and no R=0/W=1; misa constant except C; mepc alignment |
| `core_hold` | k-induction (length 1), PROVED | Both memory ports hold the request (address, we, be, wdata) until ready; x0 is never written |
| `core_req` | bounded, 10 cycles from reset | Every request is legal: fetch halfword-aligned and in flash/PSRAM; data word-aligned, in a mapped window, legal byte lanes, store data replicated, no store to flash |

Added by PRs #12-#14 (main `a2f7285`); the property lists are in each
`tb/formal/*_props.sv`:

| Harness | Mode | Covers |
|---|---|---|
| `core_fetch` | k-induction, PROVED | Fetch word reuse against a symbolic 16-halfword code memory: what issues is what memory holds at the pc |
| `syscon_comb` | bounded, 24 cycles | No combinational path from the bus to `rst_soc` |
| `syscon_gate` | k-induction, PROVED | No watchdog fire while the SoC is held in reset |
| `soc_rst_sync` | structural | `rst_soc` reaches no asynchronous reset, set or load |
| `spi_core`, `spi_dc`, `spi_bus` | k-induction at length 1, PROVED | The SPI engine's invariants, its don't-care state, and the bus rules gpio and spi rely on from each other |
| `spi_bb`, `spi_bb1` | bounded, 24 cycles | A black-box reference model of the controller at gpio's ports (SCK, MOSI, MISO sampling, RXDATA), written from the spec, sharing no names with the RTL |
| `spi_cover` | cover | Guards `spi_bb`'s assumptions against vacuity |
| `spi_f12` | structural | GPIO's pin outputs (MOSI, SCK, the chip selects) come straight from flops (finding F12) |

At PR #11, by the verification plan's own count, **4 of its 56 requirements**
were proved or bounded formally (REQ-CSR-003, REQ-RF-003, REQ-MEM-001,
REQ-MEM-002 to 10 cycles), with slices of 2 more (misa in REQ-CSR-004,
pmpcfg reserved bits in REQ-CSR-005). ISA results, traps, interrupts, PMP
matching, LR/SC and counters are still simulation only. In the mutation
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
3. ~~**New blocks get formal from the start**~~: done for syscon, fetch reuse
   and SPI (2.1). Fetch reuse is checked against a symbolic code memory
   rather than by equivalence with and without the buffer.
4. **SoC properties:** the bus rule (an IO target drops ready only while
   selected), `mem_ctrl` (data-first, no starvation, bounded), QSPI engine
   (tCEM, never selects flash for a write).
5. Turn the MD07/FC02/FC49 equivalence proofs into `run.sh` harnesses.

### 2.3 Other verification still owed

Done on the PR #12 tree (2026-10-25 to 10-30): river_core compliance plus
one random round (0 DUT defects), the gate-level programs at the pins (183
programs and 17 SoC programs, RTL = GL), EQY 157/157. Every mutation survivor
has a verdict (`tb/VPLAN.md` 4.2). Since then fetch reuse has run the
compliance suite only (175/176, the known `ma_data`), and SPI its own
benches, formal and mutation. Owed on the combined tree: everything in 1.6
item 3. Still open from PR #11: an 8-seed run.

## 3. Verilator port

Needed because Icarus runs about 30k cycles/s and a Linux boot through QSPI
is billions of cycles. At about 43 clocks per instruction that is about 700
instructions per second on the SoC bench: enough for the bare-metal rungs of
the software ladder (section 9), not for Zephyr's test suite, NuttX or Linux.

* **Status (2026-11-01): the port exists and matches Icarus.** The
  testbenches build unchanged with Verilator 5.031 `--binary --timing`: the
  `#` delays and the QSPI Pmod model stay as written, so the model is
  cycle- and timing-accurate with no rewrite to clocked logic. (SDF
  gate-level timing is not something Verilator does; that stays on Icarus,
  `scripts/gl`.)
  * `plugins/fyracore_verilator_plugin` is the river_core DUT plugin
    (`target = fyracore_verilator`, section `[fyracore_verilator]` in
    `plugins/river-config.ini`). It runs `verilator` against `src/` in
    `init`, so every river_core run is built from the current RTL: cold
    build about 17 s.
  * `make verilator-build` / `make verilator-test HEX=...` do the same for a
    single hex; `SIMULATOR=verilator tests/directed/run.sh [soc]` runs the
    directed suite on it.
  * Byte-identical dumps against Icarus on the core bench (rv32i_basic,
    csr_test, trap_test, rv32m_test). The SoC directed suite, through the
    QSPI Pmod model, passes 113/113 against the Spike references.
  * Full river_core regression on the sandbox, code d00eb8a, 2026-11-01
    12:30 to 16:51, peak 73 C: conf (riscv_tests + riscof) 175/176, the one
    failure the known `rv32ui-ma_data`; three random rounds (rrag +
    riscv_dv) **1076/1076 each**. 0 false passes in the audit, 0 DUT
    defects. Compile and compare takes about 90 s a round against about 66
    min on Icarus; generation (about 85 min a round) is now the whole
    wall clock. The earlier Icarus rounds had 1 to 2 Spike-side failures
    each (interleave SC yield, one unlinkable rrag program); none occurred
    in these seeds, so that is not a Verilator difference. Logs stay on the
    sandbox in `~/regr/multi`.
  * Needs Verilator 5.x on the box; the sandbox copy is the local
    `/tools/verilator-euvm` build under `~/tools/verilator` (the apt
    package there is 5.032 if a rebuild is wanted).
* **Speed, measured:** the SoC bench runs at about 245k clocks/s
  (`irq_stress`: 208k clocks in 0.85 s, local machine under load), roughly
  8x Icarus. At about 43 clocks per instruction that is about 5.7k
  instructions/s: enough for the bare-metal rungs, and about a day per 100
  million instructions, so Linux (hundreds of millions) is a long run on
  this bench. The build is deliberately left untuned (decision 2026-11-02):
  Verilator flags, a clock driven from C++ or a fast-memory bench would make
  the simulation quicker without making the core quicker, and the bench
  should show the core's real clocks per instruction. Measured for the
  record: `-O3` with `--x-assign fast` gave 340k clocks/s (1.28x); the
  profile puts about a third of the time in Verilator's `--timing`
  scheduler. Real speed comes from RTL (fetch reuse is merged), then FPGA
  and silicon (section 5).
* Two targets: the core with fast memory (lockstep with Spike until the first
  timer interrupt, UART text after), and the full SoC through the pins with
  the Pmod model (pass = the shell answers). The river_core plugin and the
  directed suite cover the testbench builds; a UART-only SoC build for long
  runs is still to do.
* Keep Icarus as the reference simulator for the existing suites; the
  byte-identical comparison above is how Verilator earns trust, and any
  new suite should be run on both before relying on Verilator alone.
* Reference: georgc4/rv32-linux-soc's Verilator Linux-acceptance CI
  (`localFiles/rv32-linux-soc`).

## 4. Linux bring-up

The top rung of the software ladder (section 9), after FreeRTOS. Plan in
`localFiles/PROGRESS-2026-10-12.md` section 7. In short:

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
   layout: loader 1 MiB, DTB 1.5 MiB, Image 2 MiB). It is the same loader as
   the ladder's first rung and keeps the boot contract (9.1).

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
| L2 Activity | Load enables instead of free-running flops (`alu_r`, `br_r` load every cycle today); operand isolation on the M unit and the 32-bit buses when idle | Moderate | Small area; must not touch the critical paths that set the clock (1.7) |
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
  tags, about 27,000 µm² (*estimate*), far beyond what 3x4 has left. Needs
  the 4x4 slot that was not taken.
  Size it first with a cache simulator on a Spike Linux trace.
* **JTAG debug module** (halt, resume, abstract register access; the demo
  board's RP2350 as the probe): about 17,000-34,000 µm² (*estimate*, a
  larger slot than 3x4), 3 inputs and 1 output. A UART-based debug bridge
  costs no pins but is non-standard.
* **Code-size extensions** (Zcb; Zcmp push/pop): fewer bytes fetched. Zcmp
  needs a sequencer and kernel support checked.
* **UART interrupt with an RX FIFO**, a small interrupt controller, a
  timer/PWM block. (The watchdog is built, in syscon.)
* **A standard peripheral bus** (Wishbone, OBI or APB) behind `soc_bus`, so
  existing open-source peripherals drop in.
* **Parameterise the core** (PMP entries, C, M unit kind, memory map) for
  smaller TT slots and FPGA builds.
* **S-mode + Sv32 MMU** for MMU Linux: about 28,000-40,000 µm² (*estimate*, a
  larger slot than 3x4), and very slow at about 1 MIPS with page walks over
  QSPI.

Not worth doing while memory-bound: Zba/Zbb, a faster multiplier, forwarding,
vectored mtvec, a faster core clock (QSPI is pad-limited). Rejected earlier:
SCK = core clock (pads), flash continuous read or QPI (decided 2026-09-26),
a PLIC (all devices are polled).

## 8. Order

1. ~~Settle 1.5's open decisions; move the test mailbox (1.2).~~ Done.
2. ~~syscon (1.2), then the SPI controller (1.1), then fetch reuse (1.3), each
   through the tiered agent pipeline, with formal from the start (2.2 item
   3).~~ Done: PR #12 (syscon), PR #13 (fetch reuse), PR #14 (SPI).
3. Area pass (1.4), ~~harden~~ and the lock gate (1.6), on the tree with all
   three. The harden is done (2026-11-01, 1.6 item 2).
4. The software ladder's bare-metal rungs and FreeRTOS (9.2, rungs 1-5), on
   the current benches; they can start before the lock and become its
   checkpoints.
5. Solver stack and riscv-formal (2.2 items 1-2), in parallel with step 6.
6. Verilator port (3), then the upper rungs: Zephyr or NuttX, and Linux
   bring-up (4).
7. Power: L0 measurements anytime after the lock candidate exists; the WFI
   clock gate (L3) decided by those numbers before the lock; L4 as research.
8. FPGA ports (5).

## 9. Software ladder

The user's order (2026-10-31): easier goals first, then FreeRTOS, then Linux.
Each rung proves something the rungs below it do not, and each stays on as a
regression test for later RTL changes. Collected on 2026-10-31; none of it
has been run yet.

What software gets: RV32IMAC with Zicsr, Zicntr and Zifencei; M and U modes;
4 PMP entries; no S-mode and no MMU. The CLINT's timer and software
interrupts are the only interrupts: there is no PLIC, and every device is
polled. 16 MB of flash at `0x2000_0000` (execute in place; the reset pc) and
16 MB of PSRAM at `0x8000_0000`. An ns16550 subset UART, GPIO, the tiny_spi
controller with an SD card and the OLED, and syscon (reboot, power-off,
reset cause, boot mode, watchdog). About 1.4 million instructions per second
at 60 MHz.

### 9.1 Boot contract

Rules that whatever runs first from flash keeps. Each is documented with the
block it comes from; the loader (rung 1) is where they all meet, and Linux
(section 4) relies on them.

1. **Set `mtvec` before anything can trap.** It resets to 0, which is
   outside flash and PSRAM, so a trap before it is set faults again at 0.
2. **Set the UART divisor before the first character:** set LCR.DLAB, write
   DLL = 33 and DLM = 0, clear DLAB. That is 113,636 baud at 60 MHz
   (115,200 - 1.4%); at 62.5 MHz it would be 34 (114,890 baud, -0.27%). The
   reset divisor, 27, gives 138,889 baud at 60 MHz (1.5).
3. **Read RESET_CAUSE and BOOT_MODE, then write `0x7` to RESET_CAUSE** so that
   the next boot sees only its own cause (`docs/soc-architecture.md`,
   syscon).
4. **SPI EN on an SD/OLED board:** set it with every CS# high (setting it can
   make an SCK edge; OUT resets with both CS# high), and leave it set for the
   kernel. Linux never writes it. With the keypad fitted, EN stays 0.
5. **SD first, on every boot, before any other SPI traffic:** with both CS#
   high clock at least 74 cycles (10 bytes of `0xFF`; BAUD resets to `0xFF`,
   117 kHz at 60 MHz), then send CMD0 with SD CS# low. After a reboot in the middle of a
   block, first clock `0xFF` with SD CS# low until the card returns `0xFF`
   (`docs/pins-and-peripherals.md` section 3).
6. **The watchdog is off at reset, and once enabled only a reset turns it
   off** (the DesignWare behaviour). Enable it only in code that services it.
7. **Timebase:** `mtime` counts every core clock, 60 MHz as documented
   (section 0).
   FreeRTOS's RISC-V port computes its tick from `configCPU_CLOCK_HZ`, and
   Linux reads `timebase-frequency`: both take that value.

### 9.2 Rungs

| # | Software | What it proves that the rungs below do not | Fit and effort |
|---|---|---|---|
| 0 | Directed tests, riscv-tests, river_core (exist) | ISA and privileged behaviour, instruction by instruction | Done; everything below stands on it |
| 1 | **Flash loader + hello world** (bare metal) | Boot from flash, the boot contract (9.1), copying an image to PSRAM and jumping to it, UART output at the right rate | Small. Every rung above starts from it |
| 2 | **CoreMark, Dhrystone, Embench-IoT** | A performance number for each RTL change (fetch reuse, compiler flags, -Os against -O2), timed with `mtime` | Hours. A valid CoreMark run lasts 10 s, about 14 million instructions here: short runs on the benches, full runs on Verilator or silicon |
| 3 | **Forth monitor** (mecrisp-quintus, an RV32IM Forth) | An interactive prompt over UART that reads and writes registers: the first thing to run on returned silicon | Small; needs only polled UART routines |
| 4 | **FatFs on the SD card** (bare metal) | The SPI controller and the SD protocol (CMD0, CMD8, ACMD41, CMD17, CMD24) driven by real software, before Linux's `mmc_spi` depends on them | Small; polled. The SoC bench's SD-card model runs it |
| 5 | **FreeRTOS** (upstream RISC-V port, M-mode) | The CLINT tick, context switches, trap entry and exit, interrupt latency under load | Small. The polled UART is enough. U-mode tasks under PMP are not part of the upstream port (to check) |
| 6 | **Zephyr** | Atomics, U-mode with PMP (userspace), its ns16550 and CLINT drivers, and its kernel test suite (twister) | Medium. KianV's Zephyr port (`localFiles/kianRiscV`) is a starting point. Check that 4 PMP entries are enough for userspace. The test suite needs Verilator |
| 7 | **NuttX** | POSIX, the `nsh` shell, FAT on SD over SPI, ELF programs loaded without an MMU: the closest rung to Linux | Medium. Its 16550 serial driver expects an interrupt line; check for a polled console |
| 8 | **Linux, NOMMU, M-mode** | Section 4 | Large |

Optional, anywhere after rung 1:

* **Rust:** `riscv32imac-unknown-none-elf` is this exact ISA, and embassy
  needs only an `mtime` time driver.
* **MicroPython or Lua:** a REPL on the board that drives the OLED and GPIO.
  Plenty of RAM; slow but usable at about 1.4 MIPS.
* **Tock:** U-mode applications isolated by PMP, which is what M + U + PMP
  is for. 4 PMP entries are tight for a kernel and its applications (to
  check).
* **OLED and keypad demos**, e.g. small games.

Not on the ladder:

* xv6, and anything else that needs an MMU (section 7 has the S-mode + Sv32
  estimate).
* OpenSBI: there is no S-mode, and M-mode Linux does not use it.
* U-Boot: possible later as the Linux loader, but heavy; the rung-1 loader
  comes first.
* Doom-class programs: far too slow at about 1.4 MIPS.

### 9.3 Where each rung runs

| Where | Speed | Good for |
|---|---|---|
| SoC bench, Icarus (today) | about 30k clocks/s, about 700 instructions/s | Rungs 1, 3, 4 and 5 as smoke tests (boot, a few task switches, mounting the card), up to a few hundred thousand instructions: minutes each |
| Core bench with fast memory, Icarus (today) | 3.3 clocks per instruction, 13x fewer than the SoC bench | Short benchmark runs; no QSPI and no SoC peripherals |
| Verilator (section 3) | about 245k clocks/s on the SoC bench, untuned (about 8x Icarus) | Full benchmark runs and the river_core regressions today; Zephyr's test suite, NuttX and Linux need more speed (tuning, a UART-only SoC build) |
| FPGA (section 5) and silicon | real time | The interactive rungs (Forth, MicroPython, demos), full CoreMark |
