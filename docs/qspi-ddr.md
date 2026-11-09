# DDR (DTR) flash reads: `EDh` on the TT QSPI Pmod

This document describes the switchable double-data-rate flash read in `src/qspi_ctrl.v`: the wire
protocol, the datasheet numbers it relies on, the timing budget at 62.5 MHz, how a nibble is captured,
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
- **[AUDIT]** `localFiles/qspi-stream-ddr/FLASH-DATASHEET-AUDIT.md` (2026-11-09; row ids such as D13).

Evidence rule for every claim here: silicon proven (tier 1: TinyQV, same Pmod and flash) > FPGA proven
with the real part (tier 2: LISA rev 3 on an Arty A7, 2026-10-25, `RESPIN.md:1407-1412`) > datasheet
(tier 3). A claim says its tier; none of the DDR numbers below is tier 1, because no silicon has run
`EDh` yet.

Clock: clk = 62.5 MHz, T = 16.0 ns, SCK = clk / 2 = 31.25 MHz. "Rise n / fall n" are the SCK edges of
SCK cycle n as numbered in Figure 27a (cycle 0 carries the first command bit). d is the clk duty
cycle (fraction high); TT gives no guarantee on it.

**Also valid at 60 MHz** (the earlier build clock, T = 16.667 ns, SCK 30 MHz): window W = 12.17 - Delta =
10.17 ns at Delta 2, grid step 8.33 ns, guaranteed margin 0.92 ns per side at 50 % duty (0.42 at Delta 3),
duty cutoff about d = 0.39, host-to-device 6.83 / 6.00 / 5.17 ns at d = 0.50 / 0.45 / 0.40 before the
0.8 ns ss correction of section 3.1. Every 60 MHz figure that this document used is one of these.

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
- **SCK frequency:** the DTR limit is 66 MHz at 3.0 to 3.6 V [DS 9.6] and applies to the whole
  instruction, command clocks included (the Pmod model checks it from rise 0, `tb_pmod_dtr` F12). We run
  31.25 MHz (tier 3; LISA ran 25 MHz, tier 2).
- **SCK high and low** must each be at least 45 % of the minimum period [DS 9.6 note 1]. Ours are
  16.0 ns each, at any clk duty (3.4).
- **Output toggle rate:** in DDR the address nibbles and the returned data change every T, the same
  rate as SCK (31.25 MHz): about 5 % under TT's roughly 33 MHz rating [TT] [AUDIT 3.3].

### 1.2 Streaming (CS0 held, SCK paused low)

- Every read, open or continuation, ends with SCK low after its last fall. That fall has already
  launched the next byte's high nibble, the **held nibble**. The flash keeps it on the pins for the
  whole pause, however long (the device is static: minimum fC is DC [DS 9.6]). This is the same
  structure as SDR streaming, where nibble 8 is launched by the falling edge before the pause.
- **What this relies on (tier 3 only).** The continuation samples the nibble the flash launched at the
  last falling edge before the pause, possibly long after it was launched. Nothing but the datasheet's
  static clock rating (fC min D.C., 9.6) says the flash holds it that long. Pause and resume themselves
  are tier 1 (TinyQV stalls with CS held and SCK forced low, `cpu/qspi_ctrl.v:153-164, 172-174`) and tier 2
  (LISA stops SCK with CS low, `lisa_qqspi.v:209, 520-531`); but TinyQV buffers the held nibble at its
  normal latency, early in the stall (`qspi_ctrl.v:243`), and LISA captures DDR nibbles at their normal
  capture point while SCK is paused, so neither captures a nibble after a long hold [AUDIT T1, D14, 2.6].
  Our boot sweep's execute test (section 6, step 4) runs a straight-line block from flash in DDR, which
  continues streams across pauses, so it covers this on our own silicon. This flash has no auto-sleep
  while CS is low, so the risk is low; the cheapest hedge (a 4-flop buffer at the normal capture point) is
  not built.
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

- **Dummy count (SA-DDR-1, closed).** The 8.2.14 text (p.48) says "four Dummy clocks are required in
  SPI mode" (wording copied from `EBh`: the same paragraph says it "does not require the EBh instruction
  code"). Against it: instruction Table 4 (p.28) gives "Number of Clock(1-4-4)" 8 for the `EDh` M7-M0/dummy
  field, which is the mode byte (1 DTR clock for 2 nibbles) plus **7 dummy** (M + 7 = 8); and Figures
  27a/b/c all say "7 Dummy Clocks" (cycles 12 to 18). We use 7. **Tier 2:** LISA uses 7
  (`lisa_qqspi.v:70, 507`; `docs/info.md:291`) and read the real W25Q128JV-DTR on the same Pmod correctly
  in DDR on the Arty (capture points 2 and 3 matched SDR, the REV3 suite 27/27, NuttX boots,
  `RESPIN.md:1407-1412`); a count of 4 would shift every word by 3 SCK. The sentence in 8.2.14 is an
  erratum [AUDIT D5, 2.3].
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
| fC (DTR, 3.0-3.6 V) | SCK for DTR instructions | at most 66 MHz | 31.25 MHz meets it |
| tCLH, tCLL | SCK high / low | at least 45 % of Pc | 16.0 ns meets it |
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

## 3. Timing budget at 62.5 MHz

### 3.1 Inputs

| Quantity | ff | tt | ss | Source |
|---|---|---|---|---|
| a_sck: clk rise to the registered SCK pin (`uio_out[3]`) at the tile, early / late, `qsd-af1c678` 3x4 harden | 1.23 to 1.54 | 1.82 to 2.27 | 3.29 (min_ss, SCK fall early) to 4.07 (max_ss, SCK rise late) | [STA] |
| a_dat: clk fall to the DDR IO pins (`uio_out[1,2,4,5]`, from the `nib_n` flops), early / late | 1.09 / 1.46 (min_ff / max_ff) | 1.62 to 2.21 | 2.96 to 4.04 | [STA] |
| a_dat - a_sck, worst over a pin pair, early/late derate mixed (pessimistic): setup side (+) and hold side (-) | +0.13 / -0.33 (min_ff) to +0.13 / -0.37 (max_ff) | +0.24 / -0.47 to +0.25 / -0.54 | +0.48 / -0.92 (max_ss); +0.52 / -0.80 (min_ss) | [STA]; with one derate on both sides -0.59 to +0.11 at ss |
| SDR IO pin path (posedge, combinational `io_out`); masked in DDR, where `t_ddr` = 1 makes `io_out` = `nib_n` | 1.51 (min_ff, min) | 5.51 to 6.30 | 10.34 to 11.88 | [STA] |
| sigma: SCK-to-IO skew through the TT mux, pads and board | +/-1.0 | +/-1.0 | +/-1.0 | [EST] |
| R: round trip excluding the flash (SCK flop, mux, pad, board, flash pin, and back to the capture flop), reading A: TinyQV's "a little over 20 ns" includes the flash's clock-to-output | about 11 | about 15.5 | about 22.5 | [TT] with ff x 0.7, ss x 1.45 [EST] |
| R, reading B: the 20 ns is the pads only | about 14.5 | about 20.5 | about 30 | [TT] + [EST] |
| flash output delay | tCLQX 1.5 to tCLQV 6 | | | [DS] |
| Delta: spread inside one run (SCK pad rise vs fall, line to line, jitter, die warming) | 2 (1.5 to 3.5) | | | [EST] |

The swept R range (8 to 53 ns in the simulation, 3.3) covers both readings at every corner with
margin.

Measured on the `qsd-af1c678` 3x4 harden (post-route SPEF, all nine corners, T = 16.0 ns; `pnl` md5
ddb88503; PD review 55). The a_sck / a_dat rows above are those values at the tile pins; "early" is
the min analysis with derate 0.95, "late" the max analysis with 1.05. The contract |a_dat - a_sck| <=
2 ns holds with margin (worst 0.92 ns, max_ss). More from the same run:

- **Half-cycle paths** (setup / hold slack at T = 16.0, ns, ss to ff over min/nom/max): `nib_p` to
  `nib_n` setup >= +6.42 (ss) and >= +7.30 (ff), hold >= +8.03; `cap_n` to `sr` setup >= +6.02,
  hold >= +8.01; pin to `cap_n` (TT's 3.2 ns input delay) setup >= +5.01, hold >= +9.10. The 60 MHz table's
  6.83 ns (d = 0.5) was 0.8 ns too high for setup at ss; no half-cycle path is a limit.
- **Negedge mapping:** all eight negedge flops (`nib_n[3:0]`, `cap_n[3:0]`) are posedge cells
  (`dfxtp_2`) behind a private `inv_2` on the clock (cloned from one inverter, hung off the ordinary
  clock leaves). At max_ss they see the falling edge 2.201 to 2.218 ns after the clk-port fall (17 ps
  spread, inverter 0.060 to 0.069 ns); the tree passes the fall about 0.5 ns faster than the rise at
  ss, so posedge-to-negedge is T/2 - 0.59 and negedge-to-posedge T/2 + 0.59 there. STA includes it.
- **What the TT SDC does not time:** SCK is not a clock, so the SCK-IO skew (the numbers above are
  from a hand probe), the flash-side hold and the return path into `cap_n` / `sr` (only the DDR_CAP
  sweep covers that) have no check; input and output delays are clk-rise-relative with one value
  for min and max, so a falling-edge launch to a pin gets half the budget (the reported worst setup
  path, `nib_n` to `uio_out[1]`, +0.507 at max_ss, is that artefact); the clock duty cycle at the
  pin; and the TT mux, pads and board (sigma).

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
| setup, need 1.0 ns | 6.50 | 5.70 | 4.90 |
| hold, need 2.0 ns (mirrored: d = 0.50 / 0.55 / 0.60) | 6.50 | 5.70 | 4.90 |

(setup = hold = d.T - 1.5 ns and (1-d).T - 1.5 ns at T = 16.0 ns, with 1.5 ns for the skew between the
two flop types [EST]). With the 3x4 STA numbers of 3.1 (T/2 - 0.59, |a_dat - a_sck| <= 0.92, sigma 1.0)
the setup is about 5.5 ns and the hold about 6.1 ns; both margins are at least 4 ns [AUDIT 3.2]. The
60 MHz figures were 6.83 / 6.00 / 5.17.

The pin select (`t_ddr`) is constant through a transaction and changes only on the clock that takes
the bus. SCK has no mux, so it cannot glitch.

The command phase of an `EDh` (SDR on IO0) is **also driven from `nib_n`**, not from the posedge
flops (`src/qspi_ctrl.v:306`, `io_out = nib_n & (io_sdr | {4{t_ddr}})`: in DDR the SDR term is forced to
1111, so the pins carry `nib_n`; its next value is `nib_next` for `S_CMD`, 281-301, loaded at 329). Each
command bit changes on a falling clk edge, T/2 before the SCK rise that samples it, and holds until T/2
before the next sampled rise, two SCK edges later: **setup T/2 (8 ns), hold 1.5 T (24 ns)**, against
1 / 2 ns. The earlier text here said "from the posedge flops: setup 1.5 T", which is backwards (the audit's
D13 "doc error"). Tier 2: LISA's `EDh` command on IO0 at 25 MHz read the real part [AUDIT D1, D13].

### 3.3 Device to host capture window

A nibble launched at the SCK flop edge E is valid at the capture flop from E + R + tCLQV + Delta/2
until E + T + R + tCLQX - Delta/2 (the next launch is one T later). Its width is
**W = T - (tCLQV - tCLQX) - Delta = 11.5 - Delta ns** at T = 16.0 (9.5 at Delta = 2; 10.17 at 60 MHz),
over [R+7, R+16.5). SDR has 2T - 4.5 - Delta, about 27.5 ns, for comparison. Capture points sit on a
half-clock grid, X_c = c.T/2 = 8c ns after E (8.0 ns steps). A whole-clock grid (16 ns) is wider than W at
any Delta, so some R would have no capture point at all: **half-clock capture is required.**

Derived table, d = 0.5, Delta = 2, T = 16.0 [AUDIT 3.2] (c = DDR_CAP + 1, X_c = 8c ns):

| R (ns) | 8 | 11 | 14 | 17 | 20 | 23 | 26 | 29 | 32 |
|---|---|---|---|---|---|---|---|---|---|
| passing c (margin ns) | 2 (1.0), 3 (0.5) | 3 (3.5) | 3 (3.0) | 3 (0.0), **4 (1.5)** | 4 (4.5) | 4 (2.0) | 5 (2.5) | 5 (4.0) | 5 (1.0), 6 (0.5) |

The guaranteed margin at the worst R is (W - step) / 2 = (3.5 - Delta) / 2 per side at 50 % duty:
**+0.75 ns at Delta = 2** (0.92 at 60 MHz), +0.25 at Delta = 3, none at Delta 3.5 or more. The worst R is
about 16.25 ns, where c = 3 and c = 4 both have 0.75 ns. This is positive but thinner than at 60 MHz. The datasheet's spread tCLQV - tCLQX
(4.5 ns, across parts and conditions) is pessimistic; one part at one temperature spreads less, and
the sweep measures the real eye. DDR at 62.5 MHz on TT pads is marginal by construction, which is why
it is off at reset and software-switched.

**Measured in simulation [SIM]** (`make test-qspi-ddr-sweep`, `tb/qspi_ddr_sweep.sh`, at the 62.5 MHz
clock, T = 16 ns, `+CLK_HALF_PS=8000`): the Pmod model's flash output is valid from R + 7 ns after the
SCK edge (`+QSPI_DELAY = R + 7`) until R + 1 ns after the next launch (`+QSPI_HOLD = R + 1`), a window of
[R+7, R+17) ns, for R = 8 to 53 in steps of 3 and every `DDR_CAP` 0 to 7. Capture point c = DDR_CAP + 1
sits at X_c = 8c ns. The passing set per R is compared with the window rule (R+7 <= X_c < R+17) and any
difference fails the target:

| R (ns) | 8 | 11 | 14 | 17 | 20 | 23 | 26 | 29 | 32 | 35 | 38 | 41 | 44 | 47 | 50 | 53 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passing c | 2 3 | 3 | 3 | 3 4 | 4 | 4 | 5 | 5 | 5 6 | 6 | 6 | 6 7 | 7 | 7 | 8 | 8 |

The simulated table equals the audit's expectation for T = 16 [AUDIT 3.2]; four points sit exactly on a
window edge (R = 17 / c = 3, 23 / 5, 41 / 6, 47 / 8) and are simulation ties, not margin. With `+DTR_LAUNCH=1` (a device that launches the first
nibble half an SCK late) the streamed suite passes at no capture point, for every R. The SoC runs
(`ddr_sweep` in `SYSCON_SOC_RUNS`) pick DDR_CAP 2, 3, 3, 4 at R = 11, 17, 23, 29 at both 62.5 and 60 MHz.

### 3.4 What the missing duty-cycle guarantee does

- **SCK itself does not care.** Every SCK edge comes from a rising clk edge, so high = low = T at any
  duty.
- **Host to device:** setup scales with d.T and hold with (1-d).T. As built the margins stay at least
  4 ns (4.90 ns) down to d = 0.40 and up to 0.60.
- **Capture grid:** the points that capture on a falling clk edge move by (d - 0.5).T against the
  rising-edge ones, so the steps become alternately d.T and (1-d).T and the worst-case margin is
  (W - max(d, 1-d).T) / 2. At Delta = 2 and T = 16.0 that is **+0.35 ns at d = 0.45, -0.05 ns at
  d = 0.40**, and below d of about **0.406** (0.39 at 60 MHz) some R has no point. DDR then simply does not come up: the sweep finds nothing and
  the SoC stays in SDR (the safe direction).
- The demo board's clock at 62.5 MHz: whether it is an integer divider of its PLL or a fractional one
  (alternating periods) and what duty it has is open (section 6). A fractional divider would hurt
  the core's own STA, not only DDR.

## 4. Capture points and the registers

`DDR_CAP[2:0]` selects the capture point: a nibble is captured **c = DDR_CAP + 1 half clocks** after
the clk edge that toggles the SCK flop (8 to 64 ns at T = 16.0).

| DDR_CAP | c | Captured by | Time after the launching edge (c * 8 ns) |
|---|---|---|---|
| 0 | 1 | negedge flops `cap_n`, taken at the next rising edge | 8 ns |
| 1 | 2 | the pins, at a rising clk edge | 16 ns |
| **2 (reset)** | **3** | **negedge flops `cap_n`** | **24 ns** |
| 3 | 4 | the pins, at a rising clk edge | 32 ns |
| 4 | 5 | negedge flops | 40 ns |
| 5 | 6 | the pins | 48 ns |
| 6 | 7 | negedge flops | 56 ns |
| 7 | 8 | the pins | 64 ns |

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
| The demo board's clock at 62.5 MHz: integer divider, duty, jitter | TT, board firmware | 3.4 |
| Does note 6 (alignment) cover `EDh`? | Winbond | moot while opens are aligned |
| Does the held nibble survive a long pause (section 1.2)? | the boot sweep's execute test on silicon, or an FPGA stream with delays between fetches | tier 3 only today |
| No falling-edge setup/hold rows and no rising-edge output rows | Winbond | covered by the 6.8 ns margin of 3.2 and measured by the sweep |
