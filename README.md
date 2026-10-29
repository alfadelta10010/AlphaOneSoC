# AlphaOneSoC

A small RISC-V system-on-chip for [TinyTapeout](https://tinytapeout.com) (SkyWater sky130),
built around **FyraCore**, a 3-stage RV32IMAC core. The long-term goal is to boot
**no-MMU, M-mode Linux** from external QSPI memory on a few TinyTapeout tiles. Area is the
first priority, speed the second.

By Abhiram Dasika ([alfadelta10010](https://github.com/alfadelta10010)) and Devesh Bhaskaran
([devesh-b](https://github.com/devesh-b)).

## What is in the SoC

| Block | File | Notes |
| :--- | :--- | :--- |
| **FyraCore** | `src/fyracore.v` (+ `alu`, `branchCtrl`, `controller`, `decoder`, `signExt`, `compressed_decoder`, `muldiv`, `csr`, `pmp`) | RV32IMAC + Zicsr + Zicntr + Zifencei. Pipeline IF / EX / WB. M and U modes, 4-entry PMP plus a fixed PMA map. Shared serial multiplier/divider/shifter. |
| Register file | `src/regFile.v`, `src/rf_top.v`, `macro/rf_top/` | Sylvain Munaut's 32x32 2R1W hard macro (synchronous read, write-first), with a bypass in the wrapper. Views, provenance and licences in `macro/rf_top/README.md`. |
| Bus | `src/soc_bus.v` | Stateless address decode on the core's own request/ready handshake (not APB). |
| Memory controller | `src/mem_ctrl.v`, `src/qspi_ctrl.v` | One QSPI port shared by fetch and data. Flash on CS0 (read and execute), two PSRAMs on CS1/CS2 (QPI mode). |
| CLINT | `src/clint.v` | `mtime`, `mtimecmp`, `msip`. No PLIC. |
| syscon | `src/syscon.v` | `FINISH` (reboot, power-off, fail), `RESET_CAUSE` (pin / soft / watchdog), `BOOT_MODE`, `CHIP_ID`, a DesignWare-style watchdog clocked from `mtime`, and the boot mailbox. Its reset request drives the whole SoC's reset. |
| UART | `src/uart.v` | 16550-compatible subset, byte registers, polled, RTS# flow control. |
| GPIO + OLED SPI | `src/gpio.v` | GPIO in/out and an SPI transmitter for an SSD1331 OLED. |
| Top level | `src/alphaone_soc.v`, `src/tt_um_alfadelta10010_alphaone_soc.v` | `alphaone_soc` is the SoC; the `tt_um_*` wrapper is the TinyTapeout 24-pin top (reset asserted asynchronously, released on the second clock edge). |

Memory map:

| Region | Base | Size |
| :--- | :--- | :--- |
| CLINT | `0x0200_0000` | 64 KB |
| UART | `0x1000_0000` | 64 KB |
| GPIO / OLED SPI | `0x1001_0000` | 64 KB |
| syscon (reboot, power-off, watchdog) | `0x1002_0000` | 64 KB |
| Flash (read, execute) | `0x2000_0000` | 16 MB |
| PSRAM (rwx, LR/SC, AMO) | `0x8000_0000` | 16 MB |

The SoC always boots from the first byte of flash (`0x2000_0000`); there is no boot ROM.
The QSPI pins are released while reset is high, so an external master can program the flash.

## Status

- **RTL:** complete for the blocks above; on `main`.
- **Verification:** unit benches for every block, a directed suite (about 140 tests, each
  compared instruction by instruction with Spike, also run through the whole SoC against a
  behavioural QSPI Pmod model), and a pins-only bench for the TinyTapeout wrapper. River Core
  regressions (riscv-arch-test via RISCOF, riscv-tests, riscv-dv, RRAG, torture) have found no
  open design defect; their known false-fail classes are labelled in `plugins/`. The
  `verif-upgrade` work adds a verification plan (`tb/VPLAN.md`), mutation testing and a formal
  proof of the CSR file's WARL rules. The syscon work adds unit, SoC and pins-level benches
  for reboot, power-off, the boot strap and the watchdog, with formal proofs of its reset gating.
- **Gate level:** the 3x4 hardened netlist is proven equivalent to the RTL with EQY (`tb/eqy/`,
  157 of 157 partitions) and runs the riscv-tests and the RISC-V arch tests through its pins,
  with signatures matching Spike (`scripts/gl/`).
- **Physical design:** hardens in a **3x4** TinyTapeout tile slot (12 tiles) with the
  register-file macro, at a 16 ns clock target (`clock_hz` 62.5 MHz in the submission).
  Hardening, precheck and gate-level tests are run from the separate TinyTapeout submission
  repository (`sky26d`), not from this repository.
- **Not done:** booting Linux. The ISA, privileged and boot-contract work is aimed at it,
  but no Linux image has run on the RTL.

## Requirements

- [Icarus Verilog](https://github.com/steveicarus/iverilog) (`iverilog`, `vvp`)
- A RISC-V GNU toolchain (`riscv64-unknown-elf-gcc`)
- [Spike](https://github.com/riscv-software-src/riscv-isa-sim) for the directed suite and the
  River Core regressions
- Python 3.10 (see `.python-version`, `requirements.txt`) for River Core and the mutation
  runner; `yosys` for the formal run

## Running the tests

```bash
make test-all            # every unit bench + the CPU compile check
make test-alu            # also: -csr -muldiv -compressed -controller -decoder -signext
                         #       -branchctrl -regfile -pmp -clint -qspi -uart -gpio
make test-soc-periph     # tests/soc/*.S through the SoC vs UART / OLED / keypad models
make test-wrapper        # the TinyTapeout top level, through its 24 pins only
make test-syscon         # syscon + watchdog unit bench; test-syscon-soc runs it through the SoC
make test-gl NETLIST=<nl.v> PDK_ROOT=<pdk>   # one pins run on a gate-level netlist (smoke)
make test-seeds SEEDS="1 2 3"   # the seeded unit benches once per seed
make asm FILE=tests/rv32i_basic.S

cd tests/directed && ./run.sh build && ./run.sh   # directed suite vs Spike
./run.sh soc                                      # the same suite through the whole SoC
python3 tb/mutate/run.py --check                  # mutation testing (see tb/VPLAN.md)
tb/formal/run.sh                                  # CSR WARL invariants by k-induction
```

`make clean` deletes `build/` entirely, including mutation results; use
`make BUILD_DIR=build/tb clean` to clear only the bench outputs.

Regressions through [River Core](https://github.com/incoresemi/river_core) use `plugins/`
(generator plugins for RISCOF, riscv-tests, riscv-dv, RRAG and torture; a Spike reference
plugin; the FyraCore iverilog plugin; `river-config.ini`). `scripts/patch-river-core.py`
applies the local fixes River Core needs, and `scripts/audit-regression.py` checks a finished
run for false passes (empty dumps, truncated programs).

## Repository layout

| Path | Contents |
| :--- | :--- |
| `src/` | All RTL (Verilog-2001, iverilog-compatible). |
| `tb/` | Unit and SoC benches, behavioural models (QSPI Pmod, UART host, OLED, keypad), `mutate/` mutation runner, `formal/` CSR and syscon proofs, `eqy/` RTL-against-netlist equivalence, `VPLAN.md` verification plan. |
| `tests/` | `*.S` smoke programs (`make asm`), `directed/` the Spike-compared suite (`MANIFEST`, `.S`, `.ref`), `soc/` programs for the peripherals and the wrapper. |
| `plugins/` | River Core and RISCOF integration, the RISC-V DV target and boot code. |
| `scripts/` | Assemble/run helpers, benchmark loop, regression audit and River Core patch; `gl/` the gate-level program runs. |
| `macro/rf_top/` | Register-file hard macro views (GDS, LEF, liberty, hold-guard liberty), model source and licences. |
| `libs/`, `gls_model/` | sky130 `tt` liberty and the cell models used for gate-level work. |
| `docs/` | Design documents (below) and the datasheets they cite. |
| `.claude/` | Agent definitions and their working notes. |

## Documentation

| Document | Topic |
| :--- | :--- |
| `docs/FyraCore_CPU_Reference.md` | The core: pipeline, memory interface, CSRs, traps, PMP, M unit. Start here. |
| `docs/soc-architecture.md` | Address map, boot, bus, memory controller, QSPI engine. |
| `docs/pins-and-peripherals.md` | The 24 TinyTapeout pins, the demo board, UART, GPIO, OLED, interrupts. |
| `docs/qspi-memories.md` | W25Q128JV flash and APS6404L PSRAM protocol notes. |
| `docs/area-audit.md` | Area breakdown and the cuts applied, in TinyTapeout tiles. |
| `docs/CLAUDE.md` | Build and test commands, architecture invariants, commit policy (agent-oriented but accurate for humans). |
| `tb/VPLAN.md` | Requirements, which bench checks each, the mutants that measure it, open items. |
| `macro/rf_top/README.md` | The register-file macro: provenance, licence, simulation model. |

## Licence

The register-file macro carries its own licences (GDS Apache-2.0 / CERN-OHL-W-2.0 dual;
LEF, liberty, model and sources CERN-OHL-W-2.0); see `macro/rf_top/`. The rest of the
repository has no licence file yet.
