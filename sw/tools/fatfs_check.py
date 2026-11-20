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
fsck_only = "--fsck-only" in sys.argv         # the small-card run: files that must survive, FILL.BIN gone, FATs equal
img = bytearray(8192 * 512)
addr = 0
for line in open(dump):
    if line.lstrip().startswith("//"):          # Icarus's $writememh adds comment lines
        continue
    for tok in line.split():
        if tok.startswith("@"):
            addr = int(tok[1:], 16)
        else:
            img[addr] = int(tok, 16)
            addr += 1

# The volume is at sector 0 (a FAT boot sector starts with a jump) or in partition 1 of an MBR.
vol = 0
if img[0] not in (0xEB, 0xE9):
    vol = int.from_bytes(img[0x1BE + 8:0x1BE + 12], "little") * 512
bad = []
with tempfile.NamedTemporaryFile(suffix=".img") as t:
    t.write(img)
    t.flush()
    target = t.name + (f"@@{vol}" if vol else "")

    def mtype(path):
        r = subprocess.run(["mtype", "-i", target, "::" + path], capture_output=True)
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

    if fsck_only:
        gone("FILL.BIN")
        gone("MORE.BIN")
        want("HELLO.TXT", b"Hello from the SD card\n")
        want("DATA.BIN", bytes((7 * i + 3) & 255 for i in range(16384)))
    else:
        want("EMPTY.TXT", b"")
        gone("EDGE.BIN")
        gone("OUT.BIN")
        want("RENAMED.BIN", bytes((13 * i + 5) & 255 for i in range(3000)))
        gone("TRASH.TXT")
        want("APPEND.TXT", b"first line\nsecond line\n")
        want("NEW/LOG.TXT", b"boot 42, ok\n")
        want("HELLO.TXT", b"Hello from the SD card\n")
        want("DATA.BIN", bytes((7 * i + 3) & 255 for i in range(16384)))
        want("SUB/A long file name.txt", b"long names work\n")

# the two FAT copies
bpb = img[vol:vol + 512]
res = int.from_bytes(bpb[14:16], "little")
nfat = bpb[16]
spf = int.from_bytes(bpb[22:24], "little")
base = vol // 512
if nfat == 2:
    f1 = img[(base + res) * 512:(base + res + spf) * 512]
    f2 = img[(base + res + spf) * 512:(base + res + 2 * spf) * 512]
    if f1 != f2:
        bad.append("the two FAT copies differ")
for b in bad:
    print("DISK CHECK FAIL:", b)
if not bad:
    print("disk check: ok")
sys.exit(1 if bad else 0)
