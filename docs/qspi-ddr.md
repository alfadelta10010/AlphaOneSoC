# DDR (DTR) flash reads: `EDh` on the TT QSPI Pmod

This document describes the switchable double-data-rate flash read in `src/qspi_ctrl.v`: the wire
protocol, the datasheet numbers it relies on, the timing budget at 60 MHz, how a nibble is captured,
what the clock duty cycle does to it, and what is still open. The flash is the Winbond W25Q128JV
(the `-IM` part has no DTR command; use the `-DTR` datasheet, see `docs/qspi-memories.md`).

DDR is **off at reset**. Software selects it by writing `QSPI_CFG` (syscon +0x1C): `DDR`, the
capture point `DDR_CAP[2:0]`, and `STREAM`. Every reset (pin, reboot, watchdog expiry) clears it to
SDR, `DDR_CAP = 2`. SDR reads, PSRAM accesses, writes and the start-up sequence are never DDR.

Sources named in the text:

- **[DS]** W25Q128JV-DTR datasheet, Rev C 2018-03-27 (section 8.2.14 and Figure 27a for `EDh`,
  section 6.1.5, section 9.6 for the AC table).
- **[STA]** the tile's static timing at the 3x4 harden (the TT mux and pads are not in it).
- **[TT]** silicon and community figures for the TT pad round trip (`docs/soc-architecture.md`,
  "Read latency"; `docs/qspi-memories.md`, section 10).
- **[EST]** an estimate. Each should be replaced by a measurement when one exists.
- **[SIM]** measured in simulation with the Pmod model (`tb/qspi_pmod_model.v`).

Clock: clk = 60 MHz, T = 16.667 ns, SCK = clk / 2 = 30 MHz. "Rise n / fall n" are the SCK edges of
SCK cycle n as numbered in Figure 27a (cycle 0 carries the first command bit). d is the clk duty
cycle (fraction high); TT gives no guarantee on it.

## 1. Wire protocol (SPI-mode `EDh`, 1-4-4 DTR, as the host drives it)

### 1.1 Per edge

| SCK edge at the flash pin | Host | Flash |
|---|---|---|
| CS0 falls (SCK low at least 3 ns before) | io_oe = 1, IO = {1,1,1,b7} | selected |
| rise 0 ... rise 7 | `EDh` MSB first on IO0, IO3:1 = 1 (as `EBh`) | samples IO0 on rising edges only [DS 6.1.5] |
| fall 0 ... fall 7 | | ignored. Fall 7 is **not** an address edge [DS Fig 27a: A23-16 starts in cycle 8] |
| rise 8 / fall 8 | A23-20 / A19-16 | samples on both edges from here |
| rise 9 / fall 9 | A15-12 / A11-8 | |
| rise 10 / fall 10 | A7-4 / A3-0, **A1:A0 = 00** (the open is word aligned) | |
| rise 11 / fall 11 | M7-4 = 1111 / M3-0 = 1111. **M = FFh**: M5-4 = 11 is not 10, so the flash never enters DTR continuous-read mode [DS 8.2.14] | |
| after fall 11, before fall 18 | io_oe = 0 | "IO pins should be high-impedance prior to the falling edge of the first data out clock" [DS 8.2.14] |
| rise 12 ... rise 18 | released | **7 dummy cycles**, 12 to 18 [DS Fig 27a] |
| **fall 18** | released | launches nibble 1: the high nibble of byte A |
| rise 19 | | byte A, low nibble |
| fall (17+k), rise (18+k) | | byte A+k-1, high then low nibble (k = 1..N) |
| fall (18+N) | SCK returns low | launches the high nibble of byte A+N: the first nibble of the next read (the held nibble, 1.2) |

- **Nibble and byte order** are those of `EBh`: IO3..IO0 carry bits 7..4 of a byte, then 3..0;
  bytes in ascending address order from A. The shift register and the byte swap in `rdata` are
  unchanged.
- **SCK count of an open:** 8 command + 3 address + 1 mode + 7 dummy + N data = 19 + N cycles:
  23 for 4 bytes, 25 for 6 bytes (the open at `addr[1] = 1`, 1.4).
- **SCK frequency:** the DTR limit is 66 MHz at 3.0 to 3.6 V [DS 9.6]. We run 30 MHz.
- **SCK high and low** must each be at least 45 % of the minimum period [DS 9.6 note 1]. Ours are
  16.67 ns each, at any clk duty (3.4).
- **Output toggle rate:** in DDR the address nibbles and the returned data change every T, the same
  rate as SCK (30 MHz): inside TT's roughly 33 MHz rating [TT], with no headroom.

### 1.2 Streaming (CS0 held, SCK paused low)

- Every read, open or continuation, ends with SCK low after its last fall. That fall has already
  launched the next byte's high nibble, the **held nibble**. The flash keeps it on the pins for the
  whole pause, however long (the device is static: minimum fC is DC [DS 9.6]). This is the same
  structure as SDR streaming, where nibble 8 is launched by the falling edge before the pause.
- During a pause: CS0 low, SCK low, io_oe = 0.
- A continuation of M bytes (4, or 2 for a top-up) is M SCK cycles. Its 2M nibbles are the held
  nibble plus 2M-1 launched by its own edges.
- **Capture of the held nibble.** Its capture time has passed during the pause. It stays valid until
  the continuation's first rise reaches the flash, plus tCLQX, plus the return path (at least
  T/2 + R_min + 1.5 ns after the clk edge that issues that rise [EST]). The host therefore takes it
  at the start of the continuation, on the clock that accepts it (`S_CHK` to `S_DATA`), no later than
  the edge that issues the first rise. It never enters `sr` earlier: `sr` holds the last 4 stream
  bytes for the top-up. This is safe because a pause is always longer than the capture delay: `done`
  comes after the last capture, and the earliest continuation is two clocks after `done`.
- `done` of any DDR read comes after its last nibble's capture, up to 4 clocks after the last SCK edge
  at `DDR_CAP = 7`. CS0 stays low at least until then.

### 1.3 Close and reset

- Close: CS0 rises with SCK low, after the last capture. The flash releases IO within tSHQZ 7 ns [DS];
  CS stays high at least 2 clocks (33 ns, against tSHSL1 10 ns).
- A reset mid-read or mid-stream releases the pins, and the Pmod's CS pull-up deselects. With M = FFh
  no mode is left behind.
- Hand-over (derived from the datasheet, not tested on silicon): a flash left in DTR continuous-read
  mode by another master takes the start-up sequence's first 8-clock window of ones as 3 address
  clocks plus mode FFh on clock 4, so it leaves the mode.

### 1.4 Datasheet ambiguities and the choices made

- **Dummy count.** The 8.2.14 text says "four Dummy clocks are required in SPI mode" (wording copied
  from `EBh`); Figure 27a draws **7** (cycles 12 to 18). We use 7. Another design read a real
  W25Q128JV-DTR correctly with 7 on an FPGA with the same Pmod.
- **First data edge.** Figure 27a puts it at fall 18. A device that launched at rise 19 (half an SCK
  later) would move the single-read passing points two half clocks later, which the sweep absorbs.
  In a stream it changes which read the held nibble belongs to: nothing would be held during a pause,
  and a continuation would take the previous read's last nibble again (silent corruption, one nibble
  off). The boot-time sweep reads with loads, and each load opens a new `EDh`, so the sweep alone
  never exercises a continuation. It therefore also runs a straight-line block from flash in DDR
  with the watchdog armed and BOOT_MODE recording the point under test; a framing error is caught
  there, and a crash later is recovered by the watchdog reboot and the "DDR tried" note in BOOT_MODE
  (section 6). The Pmod model supports both launches (`+DTR_LAUNCH=1`) and a streamed DDR test must
  fail on a rise-19 device at every capture point.
- **Alignment.** Note 6 of the AC table qualifies it with "4-bytes address alignment for QPI/Quad
  Read"; whether that covers `EDh` is not stated. Every DDR open starts at `A & ~3` and reads 6 bytes
  when `pc[1] = 1`, costing one more SCK (25 instead of 23); `sr` keeps the last 4 bytes, the same
  trick as SDR. A continuation is not a new start address, so the note does not apply to it. The
  model fails an unaligned `EDh` open by default.

## 2. Datasheet AC numbers that apply [DS 9.6]

| Symbol | Meaning | Value | Status |
|---|---|---|---|
| fC (DTR, 3.0-3.6 V) | SCK for DTR instructions | at most 66 MHz | 30 MHz meets it |
| tCLH, tCLL | SCK high / low | at least 45 % of Pc | 16.7 ns meets it |
| tSLCH / tCHSH | CS active setup to / hold after SCK rise | 3 / 3 ns | at least 1.5 T meets it |
| tCHSL / tSHCH | CS not-active hold / setup re SCK rise | 3 / 3 ns | met |
| tSHSL1 | CS high between reads | 10 ns | 2 clocks meets it |
| tDVCH / tCHDX | data-in setup / hold re SCK rise | 1 / 2 ns | assumed for both edges |
| tCLQV | SCK fall to output valid | at most 6 ns | assumed for both edges |
| tCLQX | output hold after SCK fall | at least 1.5 ns | assumed for both edges |
| tSHQZ | CS rise to output Hi-Z | at most 7 ns | close |

**Not in the datasheet:** there is no falling-edge input row (tDVCL / tCLDX), no rising-edge output
row (tCHQV / tCHQX), and no DTR timing diagram (sections 9.7 and 9.8 show SDR only). The only DTR
facts are the 66 MHz row, the 6.1.5 sentence "address input and data output will be latched on both
rising and falling edges", and Figure 27a. The assumption is that the rising-edge input numbers apply
to falling edges and tCLQV / tCLQX apply to rising-edge launches. The model's DTR checks use those
numbers and are listed in `tb/tb_pmod_dtr.v`.

## 3. Timing budget at 60 MHz

### 3.1 Inputs

| Quantity | ff | tt | ss | Source |
|---|---|---|---|---|
| a_dat: clk to an IO pin at the tile, combinational `io_out` | 3.47 (min) | 5.80 (max) | about 8.7 | [STA]; ss is 5.80 x 1.5 [EST] |
| a_sck: clk to the registered SCK pin at the tile | about 1.2 | about 1.8 | about 2.8 | [EST] |
| sigma: SCK-to-IO skew through the TT mux, pads and board | +/-1.0 | +/-1.0 | +/-1.0 | [EST] |
| R: round trip excluding the flash (SCK flop, mux, pad, board, flash pin, and back to the capture flop), reading A: TinyQV's "a little over 20 ns" includes the flash's clock-to-output | about 11 | about 15.5 | about 22.5 | [TT] with ff x 0.7, ss x 1.45 [EST] |
| R, reading B: the 20 ns is the pads only | about 14.5 | about 20.5 | about 30 | [TT] + [EST] |
| flash output delay | tCLQX 1.5 to tCLQV 6 | | | [DS] |
| Delta: spread inside one run (SCK pad rise vs fall, line to line, jitter, die warming) | 2 (1.5 to 3.5) | | | [EST] |

The swept R range (8 to 53 ns in the simulation, 3.3) covers both readings at every corner with
margin.

### 3.2 Host to device (address and mode nibbles, both edges)

The first data nibble needs a half-clock element somewhere. Placing the nibbles' changes on the
**falling clk edge** gives each SCK edge, rising or falling, T/2 of setup and hold from the nibble
change. Variants considered:

- **Negedge SCK flop** (SCK from a falling-edge flop, nibbles change at rising edges): setup is
  d.T + a_sck - a_dat - sigma. With the nibbles coming straight from combinational logic this fails
  at ss from about d = 0.45, and it puts a mux on the SCK pin.
- **Same-edge nibbles** (SCK from today's posedge flop, each nibble changing on the same rising edge
  as the SCK edge before it): zero designed hold (hold = a_dat,min - a_sck,max - sigma, about 1.3 ns
  at ff). Not workable.
- **As built:** SCK keeps today's posedge flop and pin path, so the silicon-proven SDR path is the
  fallback unchanged. The DDR address and mode nibbles are copied from four posedge flops (`nib_p`,
  loaded one clock earlier) into four **negedge** flops (`nib_n`) that drive IO[3:0] in a DDR
  transaction. Both paths are flop-to-flop half-cycle paths.

| Quantity (as built) | d = 0.50 | d = 0.45 | d = 0.40 |
|---|---|---|---|
| setup, need 1.0 ns | 6.83 | 6.00 | 5.17 |
| hold, need 2.0 ns (mirrored: d = 0.50 / 0.55 / 0.60) | 6.83 | 6.00 | 5.17 |

(setup = hold = d.T - 1.5 ns and (1-d).T - 1.5 ns, with 1.5 ns for the skew between the two flop
types [EST]).

The pin select (`t_ddr`) is constant through a transaction and changes only on the clock that takes
the bus. SCK has no mux, so it cannot glitch.

The command phase of an `EDh` (SDR on IO0) is driven as for `EBh`, from the posedge flops: setup
1.5 T, hold well above 2 ns.

### 3.3 Device to host capture window

A nibble launched at the SCK flop edge E is valid at the capture flop from E + R + tCLQV + Delta/2
until E + T + R + tCLQX - Delta/2 (the next launch is one T later). Its width is
**W = T - (tCLQV - tCLQX) - Delta = 12.17 - Delta ns** (10.2 at Delta = 2). SDR has 2T - 4.5 - Delta,
about 26.8 ns, for comparison. Capture points sit on a half-clock grid, X_c = c.T/2 after E
(8.33 ns steps). A whole-clock grid (16.67 ns) is wider than W at any Delta, so some R would have no
capture point at all: **half-clock capture is required.**

Derived table, d = 0.5, Delta = 2 (window [R+7, R+17.17)):

| R (ns) | passing c (margin ns) | best c |
|---|---|---|
| 8 | 2 (1.67), 3 (0.17) | 2 |
| 11 | 3 (3.17) | 3 |
| 14 | 3 (4.00) | 3 |
| 17 | 3 (1.00), 4 (0.83) | 3 (the straddling worst case) |
| 20 | 4 (3.83) | 4 |
| 23 | 4 (3.33) | 4 |
| 26 | 4 (0.33), 5 (1.50) | 5 |
| 29 | 5 (4.50) | 5 |
| 32 | 5 (2.67) | 5 |

The guaranteed margin at the worst R is (W - step) / 2 = (3.83 - Delta) / 2 per side at 50 % duty:
0.92 ns at Delta = 2, 0.42 at Delta = 3, none at 3.8 or more. The datasheet's spread tCLQV - tCLQX
(4.5 ns, across parts and conditions) is pessimistic; one part at one temperature spreads less, and
the sweep measures the real eye. DDR at 60 MHz on TT pads is marginal by construction, which is why
it is off at reset and software-switched.

**Measured in simulation [SIM]** (`make test-qspi-ddr-sweep`, `tb/qspi_ddr_sweep.sh`): the Pmod
model's flash output is valid from R + 7 ns after the SCK edge (`+QSPI_DELAY = R + 7`) until
R + 1 ns after the next launch (`+QSPI_HOLD = R + 1`), a window of [R+7, R+17.67) ns, for R = 8 to 53
in steps of 3 and every `DDR_CAP` 0 to 7. The passing set of c = DDR_CAP + 1 per R is compared with
the window rule and any difference fails the target:

| R (ns) | 8 | 11 | 14 | 17 | 20 | 23 | 26 | 29 | 32 | 35 | 38 | 41 | 44 | 47 | 50 | 53 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passing c | 2 3 | 3 | 3 | 3 4 | 4 | 4 | 4 5 | 5 | 5 | 6 | 6 | 6 7 | 7 | 7 | 7 8 | 8 |

The model window is 0.5 ns wider than the derived one at its late edge (R + 17.67 against R + 17.17,
because the model's spread is 1 ns where the derivation uses 2 ns). The two rules give different sets
only where a point sits within 0.5 ns of that edge (R = 41, c = 7, X = 58.33 ns); the table above is
the model's. With `+DTR_LAUNCH=1` (a device that launches the first nibble half an SCK late) the
streamed suite passes at no capture point, for every R.

### 3.4 What the missing duty-cycle guarantee does

- **SCK itself does not care.** Every SCK edge comes from a rising clk edge, so high = low = T at any
  duty.
- **Host to device:** setup scales with d.T and hold with (1-d).T. As built the margins stay at least
  4 ns down to d = 0.40 and up to 0.60.
- **Capture grid:** the points that capture on a falling clk edge move by (d - 0.5).T against the
  rising-edge ones, so the steps become alternately d.T and (1-d).T and the worst-case margin is
  (W - max(d, 1-d).T) / 2. At Delta = 2 that is 0.50 ns at d = 0.45, 0.08 ns at d = 0.40, and below
  d of about 0.39 some R has no point. DDR then simply does not come up: the sweep finds nothing and
  the SoC stays in SDR (the safe direction).
- The demo board's clock at 60 MHz: whether it is an integer divider of its PLL or a fractional one
  (alternating periods) and what duty it has is open (section 6). A fractional divider would hurt
  the core's own STA, not only DDR.

## 4. Capture points and the registers

`DDR_CAP[2:0]` selects the capture point: a nibble is captured **c = DDR_CAP + 1 half clocks** after
the clk edge that toggles the SCK flop (8.33 to 66.7 ns).

| DDR_CAP | c | Captured by | Time after the launching edge |
|---|---|---|---|
| 0 | 1 | negedge flops `cap_n`, taken at the next rising edge | 8.33 ns |
| 1 | 2 | the pins, at a rising clk edge | 16.67 ns |
| **2 (reset)** | **3** | **negedge flops `cap_n`** | **25.0 ns** |
| 3 | 4 | the pins, at a rising clk edge | 33.3 ns |
| 4 | 5 | negedge flops | 41.7 ns |
| 5 | 6 | the pins | 50.0 ns |
| 6 | 7 | negedge flops | 58.3 ns |
| 7 | 8 | the pins | 66.7 ns |

Odd c captures in four negedge flops on IO[3:0] (`cap_n`), which posedge logic takes half a clock
later; even c captures at a rising clk edge straight from the pins. **The default, `DDR_CAP = 2`, is a
negedge capture.** The launch marks travel down a 4-stage pipeline (`dq`); `sr` shifts when the mark
at stage m1 = (DDR_CAP + 2) / 2 (1 to 4) is set. The range the boot sweep uses is 1 to 6; 0 and 7
are spare but work in the model.

`QSPI_CFG` (syscon +0x1C): bit 0 STREAM, bit 1 DDR, bits 4:2 DDR_CAP. It resets with every reset
(`rst_soc`): SDR, `DDR_CAP = 2`, STREAM = the inverse of the no-stream strap on `ui_in[2]`, sampled
during the pin reset like `rd_late`. A read in flight finishes in the mode it started in; the next
request closes any open stream and reopens in the new mode. Software writes `DDR_CAP` in the same
store as `DDR` or before it.

Negedge flops: 8 in all (`nib_n` 4, `cap_n` 4). The DDR logic adds `t_ddr` (1), `t_cap` (3), `nib_p`
(4, posedge) and `dq` (4); `qspi_ctrl` went from 87 to 107 flops.

## 5. Static timing to check

- The clk-to-pin arrival of the SCK pin (rise and fall separately) and of the IO pins in DDR; the
  difference between the IO and SCK arrivals should stay within 2 ns at ss.
- The half-cycle paths: `nib_p` to `nib_n`, `nib_n` to the IO pins, the pins and `cap_n` to `sr`.
- Which clock leaf CTS gives the negedge flops.
- The default TT constraint file budgets 3.2 ns at the tile boundary, clock-relative; it does not
  constrain the source-synchronous SCK / IO relation, so that relation is the part to check by hand
  or in a gate-level run with SDF.

## 6. Boot use and the fallback

The boot starts in SDR with streaming on. The boot-time sweep (see `docs/ROADMAP.md`, 9.1):

1. If RESET_CAUSE shows a watchdog expiry and BOOT_MODE holds a "DDR tried" note (0xD8 + k), or
   BOOT_MODE is 0xDF, stay in SDR and consume the cause bit.
2. Otherwise run the sweep from PSRAM: for `DDR_CAP` 1 to 6, read a block of flash with loads in DDR
   several times and compare it with an SDR copy; a point passes with no mismatch.
3. Choose the middle of the longest run of passing points (the later of two, the later run on a tie);
   none passing means stay in SDR.
4. Execute test: write BOOT_MODE, arm the watchdog, switch DDR on at the chosen point and run a
   straight-line block from flash, which also exercises stream continuations. A trap restores SDR
   and writes BOOT_MODE 0xDF; a hang ends in the watchdog reboot and step 1.
5. Once enabled the watchdog must be serviced by the running program.

A single error rejects a point, since a point at the window edge fails intermittently. When two
adjacent points pass, the later one is taken: the die warms after boot, delays grow, and the window
moves later.

## 7. Open questions

| Question | Who can answer | Effect |
|---|---|---|
| Does TinyQV's "a little over 20 ns" include the flash's clock-to-output (reading A) or not (B)? | TinyQV's author, TT forum | `DDR_CAP` reset 2 (A) or 3 (B) |
| TT mux and pad delays per corner, rise and fall separately, for the SCK output and the IO pins. SCK comes back on `uio_in[3]` (loopback, `docs/qspi-memories.md` section 10), so it can be measured | TT, or measure | replaces every [EST] in 3.1 |
| The demo board's clock at 60 MHz: integer divider, duty, jitter | TT, board firmware | 3.4 |
| Does note 6 (alignment) cover `EDh`? | Winbond | moot while opens are aligned |
| No falling-edge setup/hold rows and no rising-edge output rows | Winbond | covered by the 6.8 ns margin of 3.2 and measured by the sweep |
