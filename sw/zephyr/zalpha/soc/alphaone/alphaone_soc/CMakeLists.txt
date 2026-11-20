set(SOC_LINKER_SCRIPT ${ZEPHYR_BASE}/include/zephyr/arch/riscv/common/linker.ld CACHE INTERNAL "")

zephyr_include_directories(.)
zephyr_sources(soc.c)
zephyr_sources(exit.c)
zephyr_ld_options(-Wl,--wrap=main)
