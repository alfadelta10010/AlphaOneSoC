#!/usr/bin/env python3
"""Make a damaged flash image from a good one, for the loader's failure paths.

  badimage.py flash.bin out.hex <variant>

The loader (loader/loader.c) checks the header at flash offset 0x10000: magic, load address, size,
entry, sum, flags. Variants (each damages one thing):
  magic erased size_big load_low load_high load_unal size_unal size_zero entry_low entry_end sum_payload
  sum_header flags_unknown
Prints the exit code and message the loader must give ("1 no image (bad magic)") or "0" for a variant that
must still boot.
"""
import struct
import sys

OFF = 0x10000
LOAD_LIMIT = 0x80FF0000

src, out, variant = sys.argv[1:4]
img = bytearray(open(src, "rb").read())
magic, load, size, entry, total, flags = struct.unpack_from("<6I", img, OFF)
want = ("0", "")


def put(**kw):
    vals = dict(magic=magic, load=load, size=size, entry=entry, total=total, flags=flags)
    vals.update(kw)
    struct.pack_into("<6I", img, OFF, *(vals[k] & 0xFFFFFFFF for k in ("magic", "load", "size", "entry", "total", "flags")))


if variant == "magic":
    put(magic=magic ^ 0x100); want = ("1", "no image (bad magic)")
elif variant == "erased":
    img[OFF:OFF + 24] = b"\xff" * 24; want = ("1", "no image (bad magic)")
elif variant == "size_big":
    put(size=0x01000000); want = ("2", "image does not fit PSRAM")
elif variant == "load_low":
    put(load=0x7FFFFFFC); want = ("2", "image does not fit PSRAM")
elif variant == "load_high":                 # unmapped: the case a wrapped subtraction let through
    put(load=0x90000000); want = ("2", "image does not fit PSRAM")
elif variant == "load_unal":
    put(load=load + 2); want = ("2", "image does not fit PSRAM")
elif variant == "size_unal":
    put(size=size + 2); want = ("2", "image does not fit PSRAM")
elif variant == "size_zero":
    put(size=0); want = ("3", "entry outside the image")
elif variant == "entry_low":
    put(entry=load - 4); want = ("3", "entry outside the image")
elif variant == "entry_end":
    put(entry=load + size); want = ("3", "entry outside the image")
elif variant == "sum_payload":
    img[OFF + 24 + 10] ^= 0x01; want = ("4", "sum mismatch after the copy")
elif variant == "sum_header":
    put(total=total + 1); want = ("4", "sum mismatch after the copy")
elif variant == "flags_unknown":             # bits the loader does not know are ignored
    put(flags=0x80000000)
else:
    sys.exit(f"badimage.py: unknown variant {variant}")

with open(out, "w") as f:
    f.write("@00000000\n")
    for i in range(0, len(img), 16):
        f.write(" ".join(f"{b:02x}" for b in img[i:i + 16]) + "\n")
print(*want)
