#!/usr/bin/env python3
"""Check the card image a fatfs run left behind (tb_sw +SD_DUMP), with mtools.

  fatfs_check.py dump.hex

The card must hold what fatfs_test.c did to it, and nothing else disturbed: RENAMED.BIN
(3000 bytes, byte i = (13i + 5) & 255) in place of OUT.BIN, APPEND.TXT with its second line,
NEW/LOG.TXT, no TRASH.TXT, the files it only read unchanged, and the two FAT copies equal.
"""
import re
import subprocess
import sys
import tempfile

dump = sys.argv[1]
img = bytearray(8192 * 512)
addr = 0
for tok in open(dump).read().split():
    if tok.startswith("@"):
        addr = int(tok[1:], 16)
    else:
        img[addr] = int(tok, 16)
        addr += 1

bad = []
with tempfile.NamedTemporaryFile(suffix=".img") as t:
    t.write(img)
    t.flush()

    def mtype(path):
        r = subprocess.run(["mtype", "-i", t.name, "::" + path], capture_output=True)
        return r.stdout if r.returncode == 0 else None

    def want(path, data):
        got = mtype(path)
        if got is None:
            bad.append(f"{path} is missing")
        elif got != data:
            bad.append(f"{path} differs: {len(got)} bytes, want {len(data)}")

    def gone(path):
        if mtype(path) is not None:
            bad.append(f"{path} is still there")

    want("RENAMED.BIN", bytes((13 * i + 5) & 255 for i in range(3000)))
    gone("OUT.BIN")
    gone("TRASH.TXT")
    want("APPEND.TXT", b"first line\nsecond line\n")
    want("NEW/LOG.TXT", b"boot 42, ok\n")
    want("HELLO.TXT", b"Hello from the SD card\n")
    want("DATA.BIN", bytes((7 * i + 3) & 255 for i in range(16384)))
    want("SUB/A long file name.txt", b"long names work\n")

# the two FAT copies
res = int.from_bytes(img[14:16], "little")
nfat = img[16]
spf = int.from_bytes(img[22:24], "little")
if nfat == 2:
    f1 = img[res * 512:(res + spf) * 512]
    f2 = img[(res + spf) * 512:(res + 2 * spf) * 512]
    if f1 != f2:
        bad.append("the two FAT copies differ")
for b in bad:
    print("DISK CHECK FAIL:", b)
if not bad:
    print("disk check: ok")
sys.exit(1 if bad else 0)
