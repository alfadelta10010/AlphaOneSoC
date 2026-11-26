#!/usr/bin/env python3
"""Self-standing verdict for a gate-level software run (tb_sw -DTB_PINS -DTB_GATE).

  gl_verdict.py GL.log RTL.log [GL.lines RTL.lines]

A gate run sees syscon's `off` flop, not the FINISH code (0x5555 pass vs 0x3333 fail look the same), so its PASS is
only believed when the RTL-on-pins run of the same image, which logs `FINISH-PROBE: store <wdata>`, agrees:
  1. the RTL log's FINISH store is 00005555 and it ends in SW-RESULT: PASS;
  2. the gate log ends in SW-RESULT: PASS with the same cycle count;
  3. the console text is identical line for line (the bench's FINISH-PROBE line and the Verilator footer excluded);
  4. with LINE_LOG files, the clock count at the end of every UART line is identical.
Exit 0 only when all hold; every miss is printed (first differing line included).
"""
import re, sys

def load(p):
    return open(p, errors="replace").read().replace("\r", "").split("\n")

def body(lines):
    # only the informational lines are dropped; the Pmod model's ERROR lines (its violations $fatal, tb/qspi_pmod_model.v task fail)
    # and the SD model's error count stay in the compare
    info = ("qspi_pmod_model: setup/hold", "qspi_pmod_model: min margins", "qspi_pmod_model: flash reads")
    return [l for l in lines if not l.startswith(("FINISH-PROBE", "- ", "%", "RAND-PROBE") + info) and "walltime" not in l]

gl, rtl = load(sys.argv[1]), load(sys.argv[2])
bad = []
def res(lines):
    r = [l for l in lines if l.startswith("SW-RESULT:")]
    return r[-1] if r else None
rg, rr = res(gl), res(rtl)
probe = [l for l in rtl if l.startswith("FINISH-PROBE")]
if not probe or "store 00005555" not in probe[-1]:
    bad.append(f"RTL run's FINISH store is not 0x5555: {probe[-1:] or 'no FINISH-PROBE line'}")
if not rr or not rr.startswith("SW-RESULT: PASS"): bad.append(f"RTL result: {rr}")
if not rg or not rg.startswith("SW-RESULT: PASS"): bad.append(f"GL result: {rg}")
cyc = lambda r: re.search(r"cycles=(\d+)", r or "") and re.search(r"cycles=(\d+)", r).group(1)
if cyc(rg) != cyc(rr): bad.append(f"cycles differ: gl {cyc(rg)} rtl {cyc(rr)}")
bg, br = body(gl), body(rtl)
if bg != br:
    for i, (a, b) in enumerate(zip(bg, br)):
        if a != b:
            bad.append(f"console differs at line {i}: gl {a!r} rtl {b!r}"); break
    else:
        bad.append(f"console length differs: gl {len(bg)} rtl {len(br)}")
if len(sys.argv) >= 5:
    lg, lr = load(sys.argv[3]), load(sys.argv[4])
    if lg != lr:
        for i, (a, b) in enumerate(zip(lg, lr)):
            if a != b:
                bad.append(f"LINE_LOG differs at line {i}: gl {a} rtl {b}"); break
        else:
            bad.append(f"LINE_LOG length differs: gl {len(lg)} rtl {len(lr)}")
    else:
        print(f"LINE_LOG: {len([x for x in lg if x])} line ends, identical")
for b in bad: print("VERDICT FAIL:", b)
if not bad: print(f"VERDICT PASS: gl == rtl, cycles={cyc(rg)}, FINISH store 0x5555 seen on the RTL run")
sys.exit(1 if bad else 0)
