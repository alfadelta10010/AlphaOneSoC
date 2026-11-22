#!/usr/bin/env python3
"""Check the monitor's full CSR scan (make run-monitor-scan) against the CSRs src/csr.v implements.

  csr_scan_check.py run.log

`csr scan` tries all 4096 numbers and lists the ones that do not trap. The set the core must answer for
in M-mode is written out from csr.v's read mux and csr_read_zero: the machine information CSRs, status and
trap setup, mcountinhibit, the trap handling set, pmpcfg0-3 and pmpaddr0-15 (the unimplemented ones read
zero), mcycle/minstret and their high halves, the unprivileged counter aliases, mhpmcounter3-31 and their
high halves and mhpmevent3-31 (zero), and mstatush, menvcfg and menvcfgh. Anything else answering, or any of
these missing, fails.
"""
import re
import sys

want = set()
want |= {0xF11, 0xF12, 0xF13, 0xF14, 0xF15, 0x300, 0x301, 0x304, 0x305, 0x306, 0x320}
want |= set(range(0x340, 0x345))
want |= set(range(0x3A0, 0x3A4)) | set(range(0x3B0, 0x3C0))
want |= {0xB00, 0xB02, 0xB80, 0xB82, 0xC00, 0xC01, 0xC02, 0xC80, 0xC81, 0xC82}
want |= set(range(0xB03, 0xB20)) | set(range(0xB83, 0xBA0)) | set(range(0x323, 0x340))
want |= {0x310, 0x30A, 0x31A}

log = open(sys.argv[1], errors="replace").read()
a = log.index("> csr scan")
b = log.index("scan done", a)
got = {int(m.group(1), 16) for m in re.finditer(r"^([0-9a-f]{3}) ", log[a:b], re.M)}
extra, missing = sorted(got - want), sorted(want - got)
print(f"csr scan: {len(got)} CSRs answer, {len(want)} expected")
for n in extra:
    print(f"CSR SCAN FAIL: {n:03x} answers but csr.v does not implement it")
for n in missing:
    print(f"CSR SCAN FAIL: {n:03x} is implemented but did not answer")
sys.exit(1 if extra or missing else 0)
