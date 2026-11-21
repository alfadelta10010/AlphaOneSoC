# UP5K peripheral twin (WO-F1)

The tapeout SoC on a TinyTapeout FPGA kit (iCE40UP5K-SG48 breakout on the TT demo board), with **only
the CPU swapped**: `fyracore` -> picorv32. Everything else is the tapeout RTL, byte for byte, from commit
`PIN` (file `PIN`, currently `1f2a473`): `tt_um_alfadelta10010_alphaone_soc`, `alphaone_soc`, `soc_bus`,
`mem_ctrl`, `qspi_ctrl`, `cache`, `syscon`, `uart`, `plic`, `clint`, `gpio`, `spi`, `pwm`, `audio`,
`gamepad`, `pinmux`. Purpose: check on hardware that the peripherals and the QSPI path behave as in
simulation before the sky26d lock. The core itself is validated 1-to-1 elsewhere (Arty A7-35T, later).

## What is where

| path | what |
|---|---|
| `PIN`, `srclist.txt`, `pin_extra.txt`, `pin.sums` | the pin, the exact SoC files used, their sha256 (derived from `git show PIN:path`) |
| `rtl/fyracore_picorv32.v` | module `fyracore`, same parameters and ports as `src/fyracore.v` at the pin, picorv32 inside |
| `rtl/rf_top_fpga.v` | `rf_top` (sky130 macro) replaced by sync-read RAM; also used by the cache |
| `rtl/fpga_top.v` | the tapeout wrapper instance, `ena=1`, `uio` through `SB_IO` tristates, optional `-DINTCLK` |
| `third_party/picorv32/` | picorv32 `ef203c2`, unmodified, ISC licence |
| `up5k.pcf` | pins, `tt_fpga_fabricfoxv2.pcf` from tt-support-tools (source and commit in its header) |
| `fw/` | test firmware (T1 uart, T2 flash, T3 psram, T4 cache), `-march=rv32ic -mabi=ilp32` |
| `sim/` | golden-reference bench (Icarus) on the pin's QSPI Pmod and RP2350 UART models |
| `scripts/`, `Makefile`, `build.sh` | everything runs on the sandbox; `scripts/sync.sh` copies the pin (git archive, never the working tree) and this directory there |

## Build and golden run (sandbox)

```
fpga/up5k/scripts/sync.sh                        # local: pin + fpga/up5k -> ~/regr/fpga-up5k/wo-f1
cd ~/regr/fpga-up5k/wo-f1/up5k
M=$HOME/regr/fpga-up5k/wo-f1/mb scripts/launch.sh ./build.sh F_MHZ=18    # manifest, port check, yosys, nextpnr, icepack
for c in 0 1 2 3; do scripts/run_vl.sh $c; done          # Verilator: build/vl/cfg$c/golden.txt, 35-40 M cycles each, ~15 min on the loaded sandbox
# scripts/run_sim.sh $c is the same bench under Icarus 12: identical transcript, but ~8k cycles/s, a full run is
# hours; use it for the first lines (the UART test matches), run_vl.sh for the whole thing. Use scripts/launch.sh
# (thermal watchdog) for both.
```

Measured at the committed `F_MHZ=18`, seed 1 (`build/pnr.log`): **5050 / 5280 LCs (95 %)**, 6 / 30 EBR (picorv32
register file 4, the cache's data RAM 2), nextpnr post-route fmax **22.28 MHz** (18 MHz = 0.81 x fmax).
LC 95 % does not meet the WO's 85 % limit: see the report; picorv32 without the C extension is 88 %
(4673 LCs), without C / catch traps / two-stage shifter 86 % (4562), the rest of the SoC is about 3,100 LUT4.
`build.sh` writes `build/MANIFEST` (PIN, sha256 of every file used) and fails if a pin file differs.
`scripts/port_check.sh` (A2) diffs the `fyracore` parameter and port list against the pin's.
`cfg` is the QSPI_CFG the firmware sets at boot: bit 0 STREAM, bit 1 DDR (cfg 1 = streaming, SDR is
the hardware default image; cfg 2 and 3 need the -IM part). T2 additionally loops all four settings itself.

## Running it on the board

1. **Flash the firmware image to the Pmod first**, before the FPGA is configured, so `uio` is hi-Z and
   the RP2350 can drive the flash pins: `build/sim/cfg1/fw.bin` (flat, flash offset 0, entry 0x2000_0000)
   with the demo board's flash-programming path for the QSPI Pmod (tt-micropython-firmware; the exact command
   was not checked in this WO, it needs a first run on the board).
2. Load the bitstream: copy `build/up5k.bin` to `/bitstreams` on the demo board and enable it from the REPL, or
   `tt_fpga.py configure --upload` (FPGA awaits configuration at reset; the RP2350 loads it over SPI).
3. Set the RP2350 project clock to **18 MHz** (same value as `F_MHZ`; the UART divisor in the image
   is built for it: `F_CLK`). Setting the clock after the load is what starts the design; keep `rst_n`
   low until the clock runs, as the board's firmware does.
4. Capture the UART with the RP2350: chip TX is `uo_out[4]` (FPGA pin 45), chip RX `ui_in[3]` (pin 21).
   The pinmux reset value 0x39 routes TX to `uo_out[4]`. Baud = F_CLK / (16 x div): at 18 MHz and
   div 10 that is **112500 baud** (not 115200 exactly): set the RP2350 UART to it. 8N1, no flow control.
5. Diff the captured transcript against `build/sim/cfg1/golden.txt` (committed copies of the golden
   transcripts are in `golden/`). Hardware passes when every line is identical except lines that start
   with `INFO` (banner, cycle and time numbers). `ALL PASS` ends a good run.
   Straps: `ui_in[0]`/`ui_in[2]` should be low (the firmware writes QSPI_CFG itself and prints the straps
   in the `INFO` banner, so a different strap setting does not fail the run).

## NOT 1-to-1 with the tapeout

* **The CPU.** picorv32 (rv32ic, no M/A/Zicsr, no CSRs, no traps handled, no interrupts, no PMP, no
  `fence.i`). Its memory port is word-aligned and fetches whole words; fyracore fetches from a halfword
  pc and keeps half-words (so the cache and `mem_ctrl` see different request streams and timing).
  picorv32 does not touch `fencei_flush`, `timer_irq`, `external_irq`, `sw_irq`; the interrupt wires
  (UART IRQ -> PLIC pending bit) are only **polled**. Trap/CSR/privilege, AMO/LR/SC, PMP, the watchdog reboot
  loop and CLINT interrupts are not exercised by this image (the watchdog, reboot, CLINT compare and the
  GPIO/SPI/PWM/gamepad/pinmux pins are the later WO-F2).
* **`rf_top`** (also inside the cache) is a block-RAM model, not the sky130 macro: same sync-read behaviour,
  none of the macro's timing, write-through or hold behaviour.
* **Pads and clock speed.** FPGA IO cells instead of sky130 pads, a clock of 18 MHz instead of 62.5 MHz,
  so every setup/hold/IO-timing margin is different. The RP2350's clock is jittery; the on-board 24 MHz
  oscillator (pad 35) is a build option (`make INTCLK=1`) and cleaner.
* **DDR capture timing.** The `EDh` DTR read's launch/capture margin depends on pad and board delays (and
  `QSPI_CFG.DDR_CAP`); at the FPGA's slow clock the eye is wide open, which says nothing about the ASIC at 62.5 MHz.
* The bitstream has no reset synchroniser beyond the wrapper's own two flops, no added logic, but
  the FPGA's own configuration/GSR behaviour replaces power-on reset.

## Golden transcripts (`golden/cfg0..3.txt`)

Verilator run of the bench at `F_MHZ=18`, pin `1f2a473`: all four images `ALL PASS`, 34-40 M cycles, the
Pmod model's setup/hold checks and the `fyracore` contract assertions silent, no UART frame errors. The
non-`INFO` lines are identical for the four images; the `INFO` lines carry the chosen `DDR_CAP`
(0 and 1 pass at 18 MHz, 1 is picked) and the cache loop ticks (about 1.3 M off, 0.11 M on). On hardware the
passing `DDR_CAP` set and the tick counts will differ and are not compared.
