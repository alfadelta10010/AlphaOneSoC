#!/bin/sh
# Build the SD card image sw/fatfs mounts, as the byte-wide hex tb_sw loads (+SD_IMAGE=).
#
#   mkdisk.sh out.img out.hex [fat12|fat16|mbr]
#
# A 4 MB FAT image made with mtools. fat12 (the default) has no partition table (FatFs mounts
# the volume at sector 0); fat16 is the same with one sector per cluster, which makes it FAT16;
# mbr is a FAT16 volume in partition 1 of an MBR (starting at sector 2048, as a real card's is).
# It holds: HELLO.TXT, APPEND.TXT, TRASH.TXT, DATA.BIN (16384 bytes, byte i = (7i + 3) & 255)
# and SUB/A long file name.txt. sw/fatfs/fatfs_test.c and sw/tools/fatfs_check.py know them.
set -e
IMG=$1
HEX=$2
KIND=${3:-fat12}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=512 count=8192 status=none   # (tiny: 256 sectors formatted in it)
case "$KIND" in
tiny)  VOL=$IMG; mformat -i "$VOL" -T 256 -h 4 -s 16 -c 1 -v ALPHAONE :: ;;      # 128 KB, for the full-card test
fat12) VOL=$IMG; mformat -i "$VOL" -T 8192 -h 4 -s 16 -v ALPHAONE :: ;;
fat16) VOL=$IMG; mformat -i "$VOL" -T 8192 -h 4 -s 16 -c 1 -v ALPHAONE :: ;;
mbr)   python3 -I - "$IMG" <<'PY'
import struct, sys
img = bytearray(open(sys.argv[1], "rb").read())
# partition 1: active, type 0x06 (FAT16), CHS 'beyond 8 GB' (254/255/1023), start 2048, 6144 sectors
img[0x1BE:0x1CE] = struct.pack("<B3sB3sII", 0x80, b"\xfe\xff\xff", 0x06, b"\xfe\xff\xff", 2048, 6144)
img[0x1FE:0x200] = b"\x55\xaa"
open(sys.argv[1], "wb").write(img)
PY
       VOL="$IMG@@1048576"; mformat -i "$VOL" -T 6144 -h 4 -s 16 -c 1 -H 2048 -v ALPHAONE :: ;;
*)     echo "mkdisk.sh: unknown kind $KIND" >&2; exit 2 ;;
esac
printf 'Hello from the SD card\n' > "$T/HELLO.TXT"
printf 'first line\n' > "$T/APPEND.TXT"
printf 'delete me\n' > "$T/TRASH.TXT"
printf 'long names work\n' > "$T/A long file name.txt"
python3 -I -c "import sys; sys.stdout.buffer.write(bytes((i * 7 + 3) & 255 for i in range(16384)))" > "$T/DATA.BIN"
mcopy -i "$VOL" "$T/HELLO.TXT" "$T/APPEND.TXT" "$T/TRASH.TXT" "$T/DATA.BIN" ::
mmd -i "$VOL" ::SUB
mcopy -i "$VOL" "$T/A long file name.txt" ::SUB/
python3 -I "$(dirname "$0")/img2hex.py" "$IMG" "$HEX"
