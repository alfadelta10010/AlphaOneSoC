#!/usr/bin/env python3
"""bin -> one byte per line hex for the Pmod model's +FLASH_FILE ($readmemh into a byte array)."""
import sys
d = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'w').write(''.join('%02x\n' % b for b in d))
