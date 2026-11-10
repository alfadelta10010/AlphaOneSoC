#!/bin/sh
# Build the SD card image sw/fatfs mounts, as the byte-wide hex tb_sw loads (+SD_IMAGE=).
#
#   mkdisk.sh out.img out.hex
#
# A 4 MB FAT image with no partition table (FatFs mounts the volume at sector 0) made with
# mtools: HELLO.TXT, APPEND.TXT, TRASH.TXT, DATA.BIN (16384 bytes, byte i = (7i + 3) & 255)
# and SUB/A long file name.txt. sw/fatfs/fatfs_test.c and sw/tools/fatfs_check.py know them.
set -e
IMG=$1
HEX=$2
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=512 count=8192 status=none
mformat -i "$IMG" -T 8192 -h 4 -s 16 -v ALPHAONE ::
printf 'Hello from the SD card\n' > "$T/HELLO.TXT"
printf 'first line\n' > "$T/APPEND.TXT"
printf 'delete me\n' > "$T/TRASH.TXT"
printf 'long names work\n' > "$T/A long file name.txt"
python3 -I -c "import sys; sys.stdout.buffer.write(bytes((i * 7 + 3) & 255 for i in range(16384)))" > "$T/DATA.BIN"
mcopy -i "$IMG" "$T/HELLO.TXT" "$T/APPEND.TXT" "$T/TRASH.TXT" "$T/DATA.BIN" ::
mmd -i "$IMG" ::SUB
mcopy -i "$IMG" "$T/A long file name.txt" ::SUB/
python3 -I "$(dirname "$0")/img2hex.py" "$IMG" "$HEX"
