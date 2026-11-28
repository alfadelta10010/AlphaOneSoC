V13: NOMMU M-mode Linux 6.8-rc1 on the 4x4 RTL (a732aaa) in the Verilator bench.
kernel.config  full kernel config (drivers: 8250_of, SIFIVE_PLIC, DW_WATCHDOG, GPIO_GENERIC_PLATFORM,
               PINCTRL_SINGLE, PWM_SIFIVE, SPI_OC_TINY, MMC_SPI; no earlycon in the built-in cmdline)
recipe-changes.diff  the config change against the earlier recipe's kernel.config
bench-noearlycon.dts BENCH-ONLY overlay: docs/alphaone-4x4.dts with "earlycon=uart8250,mmio,0x10000000 " removed from bootargs, nothing else
script.txt     the typed session; boot-a.sh how boot (a) was run; pack-v13.sh how the payload was packed
Kernel source: the 6.8-rc1 snapshot with cnlohr buildroot 851edd24's patches 0001/0002 and the recipe's 0003 HZ_30, built with gcc 14.2; rootfs.cpio from the earlier recipe.
Loader: LOADER_DEFS=-DCACHE_CTL_VAL=5 (cache + PSRAM burst) or 0.
