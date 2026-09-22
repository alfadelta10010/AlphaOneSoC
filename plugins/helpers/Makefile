# Build the river_core helper artifacts.
#
# Usage: make          (builds boot.bo and spike-fyracore.dtb)
#        make clean    (removes artifacts)

CROSS := riscv64-unknown-elf-

all: boot.bo spike-fyracore.dtb

boot.bo: boot.S
	$(CROSS)gcc -march=rv32imac_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
		-c boot.S -o boot.bo

# The device tree Spike is given with --dtb=. It is committed as a blob
# because that is what spike takes on the command line; regenerate it here
# whenever spike-fyracore.dts changes. Needs dtc (Debian: device-tree-compiler).
spike-fyracore.dtb: spike-fyracore.dts
	dtc -I dts -O dtb -o $@ $<

clean:
	rm -f boot.bo spike-fyracore.dtb

.PHONY: all clean
