# Ported unchanged from localFiles/setup-timing-2026-10-14/tools/gls-sdf/prep.py (the 2026-10-18 SDF recipe;
# sandbox ~/regr/rfm/gls-sdf/prep.py) for WO-34 (tb/gls_sdf/run_glitch.sh).
# prep.py <pnl.v> <sdf> <out pnl> <out sdf> : make a LibreLane netlist + SDF simulate in Icarus.
#  - The macro instance \soc.cpu.rf.rf_macro becomes rf_macro_i (Icarus's SDF reader cannot
#    resolve the escaped dots), and the macro's own CELL block is dropped (its bit-indexed
#    IOPATHs do not parse; rf_top_timing.v carries the same 4.0 ns).
#  - Icarus ignores SDF INTERCONNECT, so every wire delay is put into the netlist instead: the
#    load pin is reconnected to a wire of its own, driven by `assign #(rise, fall)` from the net,
#    and the INTERCONNECT entries are removed from the SDF so nothing counts twice.
import re, sys
nl, sdf, onl, osdf = sys.argv[1:]
t = open(nl).read()
assert t.count('\\soc.cpu.rf.rf_macro ') == 1
t = t.replace('\\soc.cpu.rf.rf_macro ', 'rf_macro_i ')
s = open(sdf).read()
blk = re.search(r' \(CELL\n  \(CELLTYPE "rf_top"\)\n.*?\n \)\n', s, re.S)
s = s[:blk.start()] + s[blk.end():]
s = s.replace('soc\\.cpu\\.rf\\.rf_macro', 'rf_macro_i')
assert '\\' not in s

ic = {}
pat = re.compile(r'^\s*\(INTERCONNECT (\S+) (\S+) \(([\d.]+):([\d.]+):([\d.]+)\)(?: \(([\d.]+):([\d.]+):([\d.]+)\))?\)\s*\n', re.M)
for m in pat.finditer(s):
    r = float(m.group(4)); f = float(m.group(7)) if m.group(7) else r
    ic[m.group(2)] = (m.group(1), r * float(__import__('os').environ.get('SDF_SCALE', '1')), f * float(__import__('os').environ.get('SDF_SCALE', '1')))
s = pat.sub('', s)
assert 'INTERCONNECT' not in s
import os
K = float(os.environ.get('SDF_SCALE', '1'))
if K != 1:   # every cell and wire delay times K (a sensitivity check, not a corner)
    s = re.sub(r'\(([\d.]+):([\d.]+):([\d.]+)\)', lambda m: '(' + ':'.join(f'{float(x)*K:.4f}' for x in m.groups()) + ')', s)
s, k = re.subn(r' \(CELL\n  \(CELLTYPE "[^"]*"\)\n  \(INSTANCE\)\n  \(DELAY\n   \(ABSOLUTE\n   \)\n  \)\n \)\n', '', s)
assert k == 1, k      # the top cell held only the INTERCONNECTs
open(osdf, 'w').write(s)

# instances: "<cell> <name> (<conns>);" -- find each one's connection list
inst_re = re.compile(r'^ (sky130_\w+|rf_top) (\S+)\s*\((.*?)\);\n', re.M | re.S)
insts = {m.group(2): m for m in inst_re.finditer(t)}
edits = {}       # instance name -> new connection text
decls = []
def conns(body):
    # yields (pin, start, end) of each ".PIN(expr)" expr span
    i = 0
    while True:
        j = body.find('.', i)
        if j < 0: return
        k = body.index('(', j)
        pin = body[j + 1:k].strip()
        d, e = 1, k + 1
        while d:
            c = body[e]
            if c == '\\':                      # escaped identifier: up to the next space
                e = body.index(' ', e)
            elif c == '(': d += 1
            elif c == ')': d -= 1
            e += 1
        yield pin, k + 1, e - 1
        i = e
n_pin = n_port = 0
seq = iter(range(10**7))
ports_out = {}
for dst, (src, r, f) in ic.items():
    if r == 0 and f == 0: continue
    w = f'ic_{next(seq)}'
    if '.' not in dst:                         # a top-level output port: delay after its driver
        ports_out[dst] = (src, w, r, f); continue
    inst, pin = dst.rsplit('.', 1)
    idx = None
    mm = re.match(r'(\w+)\[(\d+)\]$', pin)
    if mm: pin, idx = mm.group(1), int(mm.group(2))
    body = edits.get(inst, insts[inst].group(3))
    for p, a, b in conns(body):
        if p != pin: continue
        expr = body[a:b]
        if idx is None:
            net = expr.strip(); body = body[:a] + w + body[b:]
        else:
            items = [x.strip() for x in expr.strip()[1:-1].split(',')]
            k = len(items) - 1 - idx
            net = items[k]; items[k] = w
            body = body[:a] + '{' + ' ,\n    '.join(items) + ' }' + body[b:]
        break
    else:
        raise SystemExit(f'pin {dst} not found')
    edits[inst] = body
    decls.append(f' wire {w};\n assign #({r}, {f}) {w} = {net}{" " if net.startswith(chr(92)) else ""};\n')
    n_pin += 1
for port, (src, w, r, f) in ports_out.items():
    inst, pin = src.rsplit('.', 1)
    body = edits.get(inst, insts[inst].group(3))
    for p, a, b in conns(body):
        if p == pin:
            assert body[a:b].strip() == port, (src, body[a:b]); body = body[:a] + w + body[b:]; break
    edits[inst] = body
    decls.append(f' wire {w};\n assign #({r}, {f}) {port} = {w};\n'); n_port += 1
out, last = [], 0
for name, m in sorted(((n, insts[n]) for n in edits), key=lambda x: x[1].start(3)):
    out.append(t[last:m.start(3)]); out.append(edits[name]); last = m.end(3)
out.append(t[last:])
t = ''.join(out)
i = inst_re.search(t).start()   # declared before the first instance, ahead of every use
t = '`timescale 1ns / 1ps\n' + t[:i] + ''.join(decls) + t[i:]
open(onl, 'w').write(t)
print(f'{len(ic)} INTERCONNECTs: {n_pin} load pins and {n_port} output ports delayed, {len(ic) - n_pin - n_port} zero')
