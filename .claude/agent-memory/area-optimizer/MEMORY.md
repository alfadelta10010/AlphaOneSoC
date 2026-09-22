# area-optimizer memory

Living logbook for area / PPA work on this RISC-V CPU + SoC. Keep it concise.
Update after meaningful work; consult before starting new work.

## Project target (confirmed)

- PDK: SkyWater **sky130**, standard-cell library `sky130_fd_sc_hd` (high density).
- Fabrication path: **TinyTapeout**. Tile ≈ 160 × 100 µm ≈ ~1000 logic gates. Metal5
  reserved for the TT power grid (off-limits for routing).
- Flow: OpenLane / LibreLane (yosys + OpenROAD). Area + instance counts come from the
  run's `metrics.json` and synthesis reports.
- On-chip RAM is area-prohibitive; flash + PSRAM live off-chip over QSPI.

## Governing constraint

The SoC is **memory-bound** (~30 MHz, QSPI-limited in the KianV reference; ~2 min Linux
boot). Trading core area for extra cycles is usually nearly free in real throughput.
Default to area-cheap iterative hardware; justify any larger/faster unit against the
memory bottleneck.

## Reference design (KianV uLinux SoC) — validated facts

- Boots **mainline NOMMU Linux** on sky130 silicon via TinyTapeout (TT05 + TT06,
  independently confirmed; Linux 6.8.0-rc1, riscv32). Featured at Linux Plumbers 2025
  noMMU BoF and FOSSI El Correo Libre #82.
- Multicycle (Harris-style) core, **no caches, no on-chip RAM**.
- ISA: TT chip is **RV32IMA** (FPGA repo) / earliest TT was **rv32ia** — note it dropped
  the **C** extension, and the earliest chip even dropped hardware **M**.
- Reference memory map: SPI flash @ 0x20000000 (16 MiB), PSRAM @ 0x80000000 (16 MiB,
  8 MiB/bank), UART/SPI/GPIO peripherals low. Reset PC = 0x20100000 (1 MiB into flash =
  bootloader, executed in place from QSPI). Kernel runs from PSRAM.
- Repos: github.com/splinedrive/kianRiscV (main),
  github.com/splinedrive/KianV-RV32IMA-RISC-V-uLinux-SoC (TT SoC RTL).
- Bring-up gotcha noted by the author: 22 pF cap on NOR flash clk line for signal
  integrity on TT05.

## This project's current decisions

<!-- Fill in as confirmed. Examples to capture:
- ISA actually implemented (e.g. rv32imac_zicsr_zifencei) and why.
- Hardware M present, or trap-emulated?
- Memory map / reset vector chosen.
- Pipeline vs multicycle.
- Verification flow (Spike lockstep, riscv-dv, RTL testbench location).
-->
- (none recorded yet — confirm and fill in)

## Area baseline

<!-- Record after first synthesis run: date, total cell area / instance count, and
     a per-block breakdown (mul/div, ALU+adder, shifter, regfile, decoder, CSRs, glue).
     Flops are usually the dominant sink — track flop count separately. -->
- (no baseline measured yet)

## Optimizations tried

<!-- One line each: what, measured area delta, cycle cost, kept/reverted, why. -->
- (none yet)

## Candidate optimizations (not yet tried)

- Iterative 1-bit/cycle shift-add multiplier (vs array/Wallace).
- Non-restoring iterative divider; combine MUL+DIV into one add/sub + shift datapath.
- Single muxed adder for arithmetic / address / branch-target / branch-compare / PC+.
- Compact register file structure (avoid flat 32×32 flop array). RV32E is off the table
  if Linux must boot.
- Trap-and-emulate misaligned accesses instead of a hardware aligner.
- Minimal M-mode CSR set; hardwire unused/WARL bits to zero.
- Drop C-extension decode path if image-size cost is acceptable.
- Area-oriented synth strategy; avoid async set/reset flops.
