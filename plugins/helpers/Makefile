# Build boot.bo from boot.S for river_core helper files
#
# Usage: make          (builds boot.bo)
#        make clean    (removes artifacts)

CROSS := riscv64-unknown-elf-

all: boot.bo

boot.bo: boot.S
	$(CROSS)gcc -march=rv32imac_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
		-c boot.S -o boot.bo

clean:
	rm -f boot.bo

.PHONY: all clean
