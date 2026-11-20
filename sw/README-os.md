# Operating systems on the SoC bench (ladder rungs 5 to 8)

Each directory is the recipe for one OS: patches, board and config files and run scripts, never the OS's own
source (that is fetched by the script). All of them build on the sandbox and run on the software bench
(`tb/tb_sw.v`, Verilator), through the same flash loader as the rest of the ladder (`sw/loader`, boot contract
in docs/ROADMAP.md 9.1). Set `ZEPHYR_WORK`, `NUTTX_WORK` or `LINUX_WORK` to move a work directory
(default `~/<name>-work`). The scripts expect a copy of this repository's `sw/` and `tb/` and the bench build
(`make -C sw bench`) there; see each README or NOTES.

| Directory | OS | Status (2026-11-21) | Licence of what is here |
|---|---|---|---|
| `zephyr/` | Zephyr 4.5.0, board `alphaone` (out-of-tree module) | hello_world and samples/synchronization pass; hello_world_user passes with 4 PMP slots; the ztest default memory domain does not fit 4 slots; kernel tests not finished | Apache-2.0 (Zephyr's own) |
| `nuttx/` | NuttX 12.11.0, rv-virt 32-bit flat/NOMMU patched for this SoC (polled UART, no PLIC) | `nsh` boots, a scripted session and poweroff pass; ELF and SD not done | Apache-2.0 (NuttX's own) |
| `linux/` | Linux 6.8-rc1 NOMMU M-mode, buildroot (KianV's recipe, C extension on) | boots to a shell on Spike; bench boot reached userspace | Linux patches and configs are GPL-2.0; the stub and scripts here are this repository's |

Measured numbers and what is not done are in docs/ROADMAP.md 9.4. None of these runs has been repeated on
Icarus, and the NuttX and Linux scripts have not been run end to end from a clean directory by anyone but their author.
