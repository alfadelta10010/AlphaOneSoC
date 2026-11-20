#!/usr/bin/env python3
"""Check a software run's output against its expect.txt.

  check_run.py run.log expect.txt

expect.txt has one rule per line:
  + text     the log must contain this text (fixed string)
  - text     the log must not contain it
  >=N text   the log must contain it at least N times
  =RESULT t  the run must end in 'SW-RESULT: t' (for example 'FAIL code=2') instead of PASS
  # ...      comment
and the run must have ended in 'SW-RESULT: PASS' (or the =RESULT line's text). Exit 1 listing every miss.
"""
import sys

log = open(sys.argv[1], errors="replace").read().replace("\r", "")
bad = []
rules = [l.rstrip("\n") for l in open(sys.argv[2])]
want = next((l[len("=RESULT "):] for l in rules if l.startswith("=RESULT ")), "PASS")
if f"SW-RESULT: {want}" not in log:
    bad.append(f"run did not end in SW-RESULT: {want}")
for line in rules:
    if not line or line.startswith("#") or line.startswith("=RESULT "):
        continue
    if line.startswith(">="):
        n, _, text = line[2:].partition(" ")
        if log.count(text) < int(n):
            bad.append(f"found {log.count(text)} of {n}: {text}")
        continue
    if len(line) < 3 or line[0] not in "+-" or line[1] != " ":
        bad.append(f"malformed rule: {line}")
        continue
    sign, text = line[0], line[2:]
    if sign == "+" and text not in log:
        bad.append(f"missing: {text}")
    elif sign == "-" and text in log:
        bad.append(f"present: {text}")
for b in bad:
    print("CHECK FAIL:", b)
sys.exit(1 if bad else 0)
