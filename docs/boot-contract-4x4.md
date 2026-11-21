# AlphaOneSoC 4x4: boot contract

What the flash loader must do before it hands the hart to a NOMMU Linux kernel (or any OS that
reads a device tree), what it may choose, and which constants move together if the board runs a
lower clock than 62.5 MHz. No Linux driver does any of the items in section 1: they are loader
material. The device tree is `docs/alphaone-4x4.dts` (board) and `docs/devicetree-4x4.dtsi` (SoC).

## 1. The loader's duties, in order

The loader is ordinary code in flash (`docs/soc-architecture.md`, "Boot" and "Linux"). It runs
with the cache off and QSPI_CFG at its reset value (SDR, streaming per the strap).

1. **`mtvec`.** Set it to a handler in flash or PSRAM before anything can trap. It resets to 0,
   which is unmapped, and a trap there loops forever.
2. **UART divisor and early output** (section 4). The divisor resets to 34 (114,890 baud at
   62.5 MHz). Write it first if the clock is anything else.
3. **SD/OLED bus (when the board has them).** Clock at least 74 cycles (10 bytes of `0xFF`) with both
   CS# high, then CMD0 with SD CS# low, before any other SPI traffic, and after a reboot in the middle
   of a block clock `0xFF` with CS# low until the card returns `0xFF`
   (`docs/pins-and-peripherals.md`, section 3).
4. **`SPICTL.EN = 1`** (GPIO `+0x0C`, bit 0). `spi-oc-tiny` never writes it. With EN = 0 the engine
   runs but MOSI and SCK stay on OUT bits 1 and 3 (`src/spi.v`), so SD and OLED transfers fail
   silently. Set it only with every CS# high (the 0 to 1 edge can move SCK).
5. **Optional DDR bring-up** (section 3). Do it before the cache is turned on and before the kernel
   is copied, so the copy runs at the faster read speed.
6. **Copy the images into PSRAM:** the kernel image, the DTB and any initramfs, all inside the
   16 MB at `0x8000_0000`. A NOMMU RV32 kernel loads at a 4 MB boundary (`docs/soc-architecture.md`,
   "Linux"); put the DTB 8-byte aligned and clear of the kernel's `.bss` and the initramfs. Stores
   to PSRAM are QPI writes and complete before the next access.
7. **Cache (optional): `CACHE_CTL` at `0x1002_0024`.** Bit 0 EN, bit 1 reads 1 (a cache is built),
   bit 2 PBURST. Reset 0 on every reset, including a reboot.
   * EN may be written at any time, from flash or from PSRAM. Enabling starts cold; clearing returns
     to the pass-through. The cache is a read cache for instruction fetches: it snoops the core's own
     stores, AMOs and successful SCs, so no flush is needed for coherence.
   * **Still issue FENCE.I after loading code** (Zifencei requires it, and FENCE.I also flushes the
     cache). Do it after step 6 and before the jump.
   * **PBURST (bit 2): pending WO-68, TODO.** The RTL is not committed. When it lands: set PBURST only
     with `QSPI_CFG.STREAM = 1` (PBURST does nothing without it) and only if the core clock is at
     least **15 MHz**. A PSRAM line burst holds CE# low for about 97 clocks (1.55 µs at 62.5 MHz);
     the APS6404L allows 8 µs (tCEM, standard grade), which fixes the floor at 12.1 MHz, rounded up
     to 15 MHz. Below that leave PBURST at 0 (the reset value; the pins are then unchanged).
8. **Watchdog.** If the DDR sweep passed it left the watchdog armed with TOP 1 (about 2 to 3 ms) and
   it cannot be disabled. Before the jump write `WDT_TORR` with a long TOP (the write kicks): TOP 15
   is 34 s at 62.5 MHz, and Linux's `dw_wdt` then takes over (build with
   `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y`). A loader that never armed it can leave it off.
9. **Hand-over state:** `a0 = 0` (hartid), `a1` = the DTB's physical address, `mstatus.MIE = 0`,
   `mie = 0`, FENCE.I done, then `jr` to the kernel entry. The kernel sets up PMP, `mtvec` and the
   CLINT itself and reads `mhartid`. The PLIC needs nothing from the loader: every source is disabled
   and threshold 0 at reset, and the kernel's probe sets priorities and enables.

`QSPI_CFG` returns to SDR on any reboot or watchdog reset, so a loader that wants DDR repeats
section 3 on each boot (or reads BOOT_MODE first, as the reference routine does).

## 2. What the DT supplies and the loader must match

| DT item | Value | Must agree with |
|---|---|---|
| `memory@80000000` | 16 MB | the PSRAM window in the core's PMA; the loader's copy |
| `clk_core`, `uart0`, `spi0` `clock-frequency`; `timebase-frequency` | 62,500,000 | the real core clock (section 4) |
| `chosen` `stdout-path`, `bootargs` | `serial0:115200n8`, earlycon | the UART divisor (section 4) |
| CLINT `reg` | `0x0200_0000` + 64 KB | `fyracore` IO0 window |
| PLIC `riscv,ndev` | 9 | `src/plic.v` NSRC |

## 3. QSPI_CFG and the boot-time DDR sweep

`QSPI_CFG` (syscon `+0x1C`, lane 0): bit 0 STREAM (streaming flash reads), bit 1 DDR (`EDh` DTR
reads), bits 4:2 DDR_CAP (capture point). Reset: STREAM = the inverse of the no-stream strap
(`ui_in[2]`), DDR 0, DDR_CAP 0. The chip always boots in SDR; DDR is switched on by software after it
has proved on this board and temperature that it works. The reference routine is
`tests/soc/ddr_sweep.S` (`docs/soc-architecture.md`, "DDR bring-up"): reboot check, PSRAM copy of
the sweep, reference block, load sweep over DDR_CAP 1..6 (choose the middle of the longest passing
run, ties to the later one), a flash execute test under the watchdog, then pass or fall back to SDR.
BOOT_MODE `0xD0`..`0xDF` belong to it. At a lower core clock the margins grow, so the sweep still
works; if it finds nothing the board runs SDR. Fallbacks for the read path that need no software are
the `rd_late` strap (`ui_in[0]`) and the no-stream strap (`ui_in[2]`), both sampled at the pin reset.

## 4. Clock-dependent constants

Everything below is written for 62.5 MHz. If the board runs at *f* (the fallback for a thin setup
margin), change all of them together. The silicon constants cannot change; the DT and loader values
can.

| Constant | At 62.5 MHz | At lower *f* | Where |
|---|---|---|---|
| UART divisor (`UART_DIV_RESET`, a hardwired parameter) | 34 = 114,890 baud (-0.27 %) | The reset value stays 34, so the first characters come out at *f* / 544 baud until the loader writes DLL/DLM: divisor = round(*f* / (16 x baud)). 50 MHz: 27 (115,741, +0.47 %); 25 MHz: 14 (111,607, -3.1 %, use 13 or a lower baud); 15 MHz: 8 (117,188, +1.7 %); 10 MHz: 11 at 57,600 baud (56,818, -1.4 %) | `src/uart.v`, loader, `bootargs` |
| DT `clock-frequency` x3 (`clk_core`, `uart0`, `spi0`) | 62,500,000 | the real *f*. `clk_core` also feeds `pwm0` (period 2^(16+scale) clocks) and `dw_wdt` (timeouts) | `docs/devicetree-4x4.dtsi` |
| `timebase-frequency` | 62,500,000 | *f* (mtime counts the core clock) | `docs/alphaone-4x4.dts` |
| `earlycon` | no baud, clock from the node | with an explicit baud also give the clock in Hz (`earlycon=uart8250,mmio,0x10000000,115200,<f>`) | `bootargs` |
| SPI BAUD: SCK = *f* / (2 (BAUD + 1)) | SD at BAUD 2 = 10.4 MHz | The driver derives BAUD = ceil(*f* / (2 x `spi-max-frequency`)) - 1. BAUD 1 is lost to the pin flop, so keep `spi-max-frequency` **below *f* / 4**: 10,416,667 at 62.5 MHz gives BAUD 2, but at 25 MHz it would give BAUD 1, so use at most 6,250,000 there. SD init needs SCK <= 400 kHz (BAUD <= 255 up to 204 MHz, always met). The OLED needs 75 ns phases: BAUD >= ceil(*f* x 75 ns) - 1 (5 at 62.5 MHz; 1 at 25 MHz, but BAUD 1 is only unsafe for MISO, never use 0 to receive) | `spi0` node, loader |
| Watchdog: timeout = 2^(16+TOP) clocks | TOP 15 = 34.4 s; DDR test TOP 1 = 2.1 to 3.1 ms | scales as 1/*f*: at 15 MHz TOP 15 = 143 s, TOP 1 = 8.7 to 13 ms. The driver reads the rate from `clk_core`, so a correct DT needs nothing else | `docs/soc-architecture.md` (Watchdog), loader |
| PBURST minimum clock | 15 MHz (tCEM 8 µs, 97 clocks per line) | **below 15 MHz PBURST stays 0** (pending WO-68) | CACHE_CTL |
| Audio tone: *f* / 16 / 2^O / (2 (P + 1)) | 1,953,125 / (2^O (P + 1)) Hz | recompute the note table (`src/audio.v` header) | bare-metal software |
| UART RX slack without RTS# | 87 µs per character at 114,890 baud | set by the baud, not the clock: unchanged once the divisor is retuned | `docs/pins-and-peripherals.md` |

## 5. Checking the device tree

On the sandbox (never locally):

```
dtc -I dts -O dtb -@ -o alphaone-4x4.dtb alphaone-4x4.dts     # with devicetree-4x4.dtsi alongside
dt-validate -s <linux>/Documentation/devicetree/bindings alphaone-4x4.dtb
```

Expected remaining reports (2026-11-21, dtschema 2026.9 against torvalds/master): the PLIC's
out-of-tree `alfadelta10010,alphaone-plic` (the schema accepts `sifive,plic-1.0.0` only behind a
listed SoC name; the driver matches the fallback) and the legacy `baud-width` of `spi-oc-tiny`
(its binding is a text file, so there is no schema for the property). Nothing else.
