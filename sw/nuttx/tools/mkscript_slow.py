#!/usr/bin/env python3
"""Like sw/tools/mkscript.py but types ONE character per script step, each step waiting for
the echo of the previous one.  The bench's UART receiver is one byte deep, has no flow control
and the bench sends frames back to back, while NuttX needs far more than one frame time to
take a character through the serial driver, nsh's readline and the echo.

  mkscript_slow.py script.txt out.hex      (script lines:  <wait text> TAB <command>)
"""
import sys
steps = []   # (wait bytes, send bytes)
for l in open(sys.argv[1]):
    l = l.rstrip("\n")
    if not l or l.startswith("#"):
        continue
    wait, _, cmd = l.partition("\t")
    prev = wait
    for ch in cmd:
        steps.append((prev, ch)); prev = ch
    steps.append((prev, "\r"))
data = []
for w, s in steps:
    w, s = w.encode(), s.encode()
    assert 0 < len(w) <= 32
    data += [len(w), *w, len(s), *s]
data.append(255)
open(sys.argv[2], "w").write("\n".join(f"{b:02x}" for b in data) + "\n")
