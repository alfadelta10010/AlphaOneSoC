#!/usr/bin/env python3
"""Turn a UART script into the hex file tb_sw reads (+UART_IN=).

  mkscript.py script.txt out.hex [--elf prog.elf]

A script line is  <wait text> TAB <keys>: the bench waits until the program's output
ends in the wait text (up to 32 characters), then types the keys and Enter. In the
keys, ^C is Ctrl-C (no Enter is added after a keys field that ends in ^C), and
PROMPT in the wait text is the monitor's prompt after a newline (a bare "> " also
matches the loader's "->"). {name} is the address of that symbol in --elf, in hex. # starts a comment line.
"""
import re
import subprocess
import sys

script, out = sys.argv[1], sys.argv[2]
syms = {}
if "--elf" in sys.argv:
    elf = sys.argv[sys.argv.index("--elf") + 1]
    for l in subprocess.run(["riscv64-unknown-elf-nm", elf], capture_output=True, text=True, check=True).stdout.splitlines():
        f = l.split()
        if len(f) == 3:
            syms[f[2]] = f[0]

data = []
for l in open(script):
    l = l.rstrip("\n")
    if not l or l.startswith("#"):
        continue
    wait, _, keys = l.partition("\t")
    keys = re.sub(r"\{(\w+)\}", lambda m: syms[m.group(1)], keys)
    send = keys.replace("^C", "\x03")
    if not keys.endswith("^C"):
        send += "\r"
    wait = wait.replace("PROMPT", "\\n> ")
    w, s = wait.replace("\\n", "\n").encode(), send.encode()
    assert 0 < len(w) <= 32 and len(s) < 255
    data += [len(w), *w, len(s), *s]
data.append(255)
open(out, "w").write("\n".join(f"{b:02x}" for b in data) + "\n")
