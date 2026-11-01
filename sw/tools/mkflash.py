#!/usr/bin/env python3
"""Build the flash image the loader boots, as the byte-wide hex the QSPI Pmod
model reads ($readmemh, +FLASH_FILE=) and as a raw .bin for programming.

  mkflash.py --loader loader.bin --image payload.bin --load 0x80000000 \
             --entry 0x80000000 --out flash.hex [--bin flash.bin]

Layout (sw/common/soc.h): the loader at flash offset 0, an image header at
IMAGE_FLASH_OFF = 0x10000 and the payload 20 bytes behind it. The header is
magic, load address, size, entry and the 32-bit sum of the payload words.
"""
import argparse
import struct
import sys

IMAGE_FLASH_OFF = 0x10000
IMAGE_MAGIC = 0x4D493141


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--loader", required=True)
    ap.add_argument("--image", required=True)
    ap.add_argument("--load", type=lambda s: int(s, 0), default=0x80000000)
    ap.add_argument("--entry", type=lambda s: int(s, 0), default=None)
    ap.add_argument("--out", required=True)
    ap.add_argument("--bin")
    a = ap.parse_args()

    loader = open(a.loader, "rb").read()
    image = open(a.image, "rb").read()
    image += b"\0" * (-len(image) % 4)
    entry = a.load if a.entry is None else a.entry
    if len(loader) > IMAGE_FLASH_OFF:
        sys.exit(f"loader is {len(loader)} bytes, over the {IMAGE_FLASH_OFF}-byte slot")
    s = sum(struct.unpack(f"<{len(image) // 4}I", image)) & 0xFFFFFFFF
    hdr = struct.pack("<5I", IMAGE_MAGIC, a.load, len(image), entry, s)

    flash = bytearray(loader)
    flash += b"\xff" * (IMAGE_FLASH_OFF - len(flash))
    flash += hdr + image

    with open(a.out, "w") as f:
        f.write("@00000000\n")
        for i in range(0, len(flash), 16):
            f.write(" ".join(f"{b:02x}" for b in flash[i:i + 16]) + "\n")
    if a.bin:
        open(a.bin, "wb").write(flash)
    print(f"loader {len(loader)} B, image {len(image)} B at {a.load:#x}, "
          f"entry {entry:#x}, sum {s:#010x}, flash {len(flash)} B", file=sys.stderr)


main()
