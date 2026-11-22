#!/usr/bin/env python3
"""img2hex.py in.img out.hex: one byte per line, what $readmemh of a byte array reads."""
import sys

data = open(sys.argv[1], "rb").read()
with open(sys.argv[2], "w") as f:
    f.write("\n".join(f"{b:02x}" for b in data) + "\n")
