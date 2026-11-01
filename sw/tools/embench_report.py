#!/usr/bin/env python3
"""Embench-IoT speed score from the runs under build/sw/embench-*/run.log.

  embench_report.py baseline-data/speed.json <gsf> <build/sw>

Each log has a line 'EMBENCH <name> clocks=<n> correct=<0|1>' (the time
between start_trigger and stop_trigger, in core clocks: mtime counts them).
Embench's rule (doc/README.md, "Speed benchmarks"): relative speed =
reference_ms / ms * gsf, then divided by the CPU's MHz; the score is the
geometric mean. The clocks are exact, so ms = clocks / (60 MHz * 1000), and
the score is reference_ms / ms * gsf / 60.
"""
import glob
import json
import math
import re
import sys

ref = json.load(open(sys.argv[1]))
gsf = float(sys.argv[2])
build = sys.argv[3]
MHZ = 60.0

rows = []
for log in sorted(glob.glob(f"{build}/embench-*/run.log")):
    text = open(log, errors="replace").read()
    m = re.search(r"EMBENCH (\S+) clocks=(\d+) correct=(\d)", text)
    if not m or "SW-RESULT: PASS" not in text:
        print(f"{log}: no complete result")
        continue
    name, clocks, ok = m.group(1), int(m.group(2)), m.group(3) == "1"
    ms = clocks / (MHZ * 1000.0)
    score = ref[name] / ms * gsf / MHZ
    rows.append((name, clocks, ms, score, ok))

if not rows:
    sys.exit("no Embench runs found")
print(f"{'benchmark':16} {'clocks':>12} {'ms@60MHz':>10} {'score/MHz':>10}")
for n, c, ms, s, ok in rows:
    print(f"{n:16} {c:12d} {ms:10.1f} {s:10.4f}{'' if ok else '  WRONG RESULT'}")
good = [s for _, _, _, s, ok in rows if ok]
gm = math.exp(sum(math.log(s) for s in good) / len(good))
print(f"geometric mean over {len(good)} of {len(ref)} benchmarks: {gm:.4f} Embench speed per MHz "
      f"(1.0 = the Cortex-M4 reference)")
