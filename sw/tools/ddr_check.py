#!/usr/bin/env python3
"""Check one run of the ddr payload against the loader's own rule (loader/ddr.S, docs/qspi-ddr.md 6).

  ddr_check.py run.log

The loader prints either "flash in DDR, DDR_CAP 0xk (passing points 0xMASK)" or "flash stays SDR: <why>
(passing points 0xMASK)". The rule: the capture point is the middle of the longest run of passing points
1 to 6, start + length / 2, the later run on a tie; no passing point means SDR. The run must have ended in
PASS with the flash read-back right ("0 differ") in the mode the loader chose. Prints one summary line;
exit 1 on any disagreement.
"""
import re
import sys

log = open(sys.argv[1], errors="replace").read()
m = re.search(r"flash in DDR, DDR_CAP 0x([0-9a-f]) \(passing points 0x([0-9a-f]{2})\)", log)
n = re.search(r"flash stays SDR: ([^(\n]*)\(passing points 0x([0-9a-f]{2})\)", log)
bad = []
if "SW-RESULT: PASS" not in log:
    bad.append("run did not pass")
if m:
    k, mask = int(m.group(1), 16), int(m.group(2), 16)
    chosen = f"DDR cap {k}"
elif n:
    k, mask = None, int(n.group(2), 16)
    chosen = "SDR"
else:
    print("no loader decision found")
    sys.exit(1)

best_len = best_start = 0
cur_len = cur_start = 0
for c in range(1, 7):
    if mask >> c & 1:
        if cur_len == 0:
            cur_start = c
        cur_len += 1
        if cur_len >= best_len:
            best_len, best_start = cur_len, cur_start
    else:
        cur_len = 0
want = best_start + best_len // 2 if best_len else None
if want != k:
    bad.append(f"the rule gives {want} for mask {mask:#04x}, the loader chose {k}")
if mask & ~0x7E:
    bad.append(f"mask {mask:#04x} has bits outside points 1-6")
mode = "DDR" if k is not None else "SDR"
if f"read back from flash in {mode}, 0 differ" not in log:
    bad.append(f"the flash read-back in {mode} is not clean")
print(f"{chosen:10} mask {mask:#04x} {'OK' if not bad else 'FAIL: ' + '; '.join(bad)}")
sys.exit(1 if bad else 0)
