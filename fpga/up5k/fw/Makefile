# Firmware for the UP5K twin. Sandbox only (GCC: ~/tools/rv64-gcc-elf, multilib not needed: no libgcc).
#   make -C fw F_CLK=20000000 CFG=1 OUT=../build/fw1
CROSS ?= $(HOME)/tools/rv64-gcc-elf/bin/riscv64-unknown-elf-
CC    := $(CROSS)gcc
F_CLK ?= 20000000
CFG   ?= 1
PIN_SHA ?= $(shell cat ../PIN)
OUT   ?= ../build/fw$(CFG)
CFLAGS := -march=rv32ic -mabi=ilp32 -Os -ffreestanding -fno-builtin -fno-pic -mno-relax -Wall -Wextra \
          -Wno-unused-parameter -DF_CLK=$(F_CLK) -DCFG=$(CFG) -DPIN_SHA='"$(PIN_SHA)"'
SRC := crt0.S fn.S main.c t_uart.c t_flash.c t_psram.c t_cache.c

all: $(OUT).hex

$(OUT).elf: $(SRC) hw.h link.ld $(OUT).pattern.S
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -nostdlib -nostartfiles -T link.ld -Wl,--no-warn-rwx-segments -o $@ $(SRC) $(OUT).pattern.S -Wl,-Map=$(OUT).map

$(OUT).pattern.S: gen_pattern.py
	@mkdir -p $(dir $@)
	python3 gen_pattern.py 512 > $@

$(OUT).bin: $(OUT).elf
	$(CROSS)objcopy -O binary $< $@
	$(CROSS)size $<

$(OUT).hex: $(OUT).bin bin2hex.py
	python3 bin2hex.py $< $@
	$(CROSS)objdump -d -M no-aliases $(OUT).elf > $(OUT).dis

.PHONY: all
