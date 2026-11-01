#!/usr/bin/env python3
"""Check a software run's output against its expect.txt.

  check_run.py run.log expect.txt

expect.txt has one rule per line:
  + text     the log must contain this text (fixed string)
  - text     the log must not contain it
  # ...      comment
and the run must have ended in 'SW-RESULT: PASS'. Exit 1 listing every miss.
"""
import sys

log = open(sys.argv[1], errors="replace").read().replace("\r", "")
bad = []
if "SW-RESULT: PASS" not in log:
    bad.append("run did not end in SW-RESULT: PASS")
for line in open(sys.argv[2]):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    sign, text = line[0], line[2:]
    if sign == "+" and text not in log:
        bad.append(f"missing: {text}")
    elif sign == "-" and text in log:
        bad.append(f"present: {text}")
for b in bad:
    print("CHECK FAIL:", b)
sys.exit(1 if bad else 0)
