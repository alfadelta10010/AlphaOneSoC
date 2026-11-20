cd ${ZEPHYR_WORK:-$HOME/zephyr-work}
. venv/bin/activate
export PATH=$HOME/tools/rv64-gcc-elf/bin:$HOME/tools/verilator/bin:$HOME/tools/rv32-isa-sim/bin:$PATH; unset VERILATOR_ROOT
export ZEPHYR_BASE=${ZEPHYR_WORK:-$HOME/zephyr-work}/ws/zephyr
export ZEPHYR_TOOLCHAIN_VARIANT=cross-compile
export CROSS_COMPILE=$HOME/tools/rv64-gcc-elf/bin/riscv64-unknown-elf-
export ZMOD=${ZEPHYR_WORK:-$HOME/zephyr-work}/deliver/zalpha
