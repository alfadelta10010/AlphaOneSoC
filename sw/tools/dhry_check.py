#!/usr/bin/env python3
"""Dhrystone prints each final value followed by 'should be: <value>'. Compare
the numeric pairs (the pointer values and strings are implementation-
dependent or checked by eye). Arr_2_Glob[8][7] should be Number_Of_Runs + 10.

  dhry_check.py run.log [number_of_runs]
"""
import re
import sys

log = open(sys.argv[1], errors="replace").read().replace("\r", "").splitlines()
runs = int(sys.argv[2]) if len(sys.argv) > 2 else 500
bad = checked = 0
for i, line in enumerate(log[:-1]):
    m = re.match(r"\s*(\S+):\s+(-?\d+)\s*$", line)
    n = re.match(r"\s*should be:\s+(.*?)\s*$", log[i + 1])
    if not (m and n):
        continue
    name, got, want = m.group(1), int(m.group(2)), n.group(1)
    if "Ptr_Comp" in name:
        continue
    want = runs + 10 if want.startswith("Number_Of_Runs") else int(want) if re.fullmatch(r"-?\d+", want) else None
    if want is None:
        continue
    checked += 1
    if got != want:
        bad += 1
        print(f"DHRY FAIL: {name} = {got}, should be {want}")
print(f"dhrystone: {checked} values checked, {bad} wrong")
# The benchmark prints integers (Dhrystones per second at 1 MHz, truncated);
# the exact figure from the clocks per run it reports.
for line in log:
    m = re.match(r"Microseconds for one run through Dhrystone:\s+(\d+)", line)
    if m and int(m.group(1)):
        clocks = int(m.group(1))   # HZ = 10^6 and the timer is mcycle: clocks per run
        print(f"dhrystone: {clocks} clocks per run, {1e6 / clocks:.2f} Dhrystones/s per MHz, "
              f"{1e6 / clocks / 1757:.4f} DMIPS/MHz")
sys.exit(1 if bad or checked < 10 else 0)
