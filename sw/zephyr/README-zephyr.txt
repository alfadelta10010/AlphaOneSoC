Zephyr v4.5.0 on the AlphaOneSoC Verilator bench (rung 6)

Layout (all under ~/zephyr-work, nothing outside):
  sw/, build/sw/      copy of the ladder; build/sw/bench/sim is the bench, loader.bin the flash loader
  venv/, ws/zephyr    python venv with west; Zephyr v4.5.0 checked out by `west init` (no `west update`:
                      the kernel, minimal libc and ztest need no module)
  deliver/zalpha/     the Zephyr module: board alphaone, SoC alphaone_soc, dts (zephyr/module.yml adds
                      board/soc/dts roots; pass -DZEPHYR_EXTRA_MODULES=deliver/zalpha)
  deliver/env.sh      toolchain environment (cross-compile variant, ~/tools/rv64-gcc-elf, rv32imac/ilp32)
  deliver/mkflash.sh  zephyr.bin + the ladder's loader -> flash.hex (load 0x80000000, entry __start)
  deliver/run-zephyr.sh  build and run hello, sync, kernel tests; deliver/logs/ holds every log
One-time setup:
  python3 -m venv venv; . venv/bin/activate; pip install west
  mkdir ws; cd ws; west init -m https://github.com/zephyrproject-rtos/zephyr --mr v4.5.0 .
  pip install -r zephyr/scripts/requirements-base.txt
  make -C sw -j2 bench hello
Board facts: ns16550 at 0x10000000 (reg-shift 0, polled), sifive,clint0 + riscv,machine-timer, no PLIC,
  syscon FINISH 0x10020000 via the wrapped main (exit.c): main returning ends the run (0 = pass).
  RAM 0x80000000 + 0xff0000, tick 100 Hz, PMP off by default (-DCONFIG_RISCV_PMP=y + CONFIG_USERSPACE for userspace).
