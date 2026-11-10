#!/usr/bin/env python3
# edit_netlist.py <in pnl.v> <out pnl.v> [--tt01] [--pin-delay NS] : the two netlist edits of WO-34.
# Applied to prep.py's output (INTERCONNECTs already moved into the netlist as `assign #(r,f)`), so the
# SDF stays valid: no cell is added or removed that the SDF names.
#
#   --tt01          the TT01 mutant at gate level. The one sky130_fd_sc_hd__dfrtp that drives net `run`
#                   (directly, or through at most two buf cells) gets .D(1'b1): the pin gates open on the
#                   FIRST clock edge after rst_n rises, not the second. Exactly one replacement is asserted.
#   --pin-delay NS  the late-SoC-input control. Every "pin gate" (a cell with an input on `run` or on a buffered
#                   copy of it) gets its other input(s) reconnected through `assign #(NS) <wire> = <net>;`.
#                   Each of the 16 ports uo_out[7:0], uio_oe[7:0] must have exactly one pin gate in its fan-in
#                   (the uio_oe bits may share one); anything else is an error.
#
# Prints the edited instance and the gate list, so the run log shows what was edited.
import re, sys

args = sys.argv[1:]
if len(args) < 2:
    sys.exit(__doc__)
inp, outp = args[0], args[1]
tt01 = '--tt01' in args
delay = None
if '--pin-delay' in args:
    delay = float(args[args.index('--pin-delay') + 1])
t = open(inp).read()

OUTPINS = {'X', 'Y', 'Q', 'Q_N', 'COUT', 'SUM', 'HI', 'LO', 'GCLK', 'Z'}
POWER = {'VGND', 'VNB', 'VPB', 'VPWR', 'VDPWR'}
inst_re = re.compile(r'^ (sky130_\w+|rf_top|rf_macro\w*) (\S+)\s*\((.*?)\);\n', re.M | re.S)

def conns(body):
    """(pin, start, end) of each .PIN(expr) expr span (same scanner as prep.py)."""
    i = 0
    while True:
        j = body.find('.', i)
        if j < 0:
            return
        k = body.index('(', j)
        pin = body[j + 1:k].strip()
        d, e = 1, k + 1
        while d:
            c = body[e]
            if c == '\\':
                e = body.index(' ', e)
            elif c == '(':
                d += 1
            elif c == ')':
                d -= 1
            e += 1
        yield pin, k + 1, e - 1
        i = e

insts = {}                     # name -> (cell, match)
for m in inst_re.finditer(t):
    insts[m.group(2)] = (m.group(1), m)
assert insts, 'no instances parsed'

assign_re = re.compile(r'^\s*assign\s+(?:#\([^)]*\)\s+)?(\S+)\s*=\s*(\S+?)\s*;\s*$', re.M)
alias = {}                     # net -> the net it is assigned from
for m in assign_re.finditer(t):
    alias[m.group(1)] = m.group(2)

def pins_of(name):
    cell, m = insts[name]
    body = m.group(3)
    return [(p, body[a:b].strip()) for p, a, b in conns(body) if p not in POWER]

def is_seq(cell):
    return not cell.startswith('sky130_') or re.match(r'sky130_fd_sc_hd__(s?e?df|dl)', cell) is not None

driver = {}                    # net -> instance driving it (output pin)
loads = {}                     # net -> [(instance, pin)] reading it
for n, (cell, m) in insts.items():
    for p, e in pins_of(n):
        if cell.startswith('sky130_') and p in OUTPINS:
            driver[e] = n
        else:
            loads.setdefault(e, []).append((n, p))

def resolve(net):
    """follow assigns back to the net that a cell (or the port) really drives"""
    seen = 0
    while net in alias and net not in driver:
        net = alias[net]
        seen += 1
        assert seen < 50
    return net

# nets that carry `run`: the net, its assign aliases, and up to two buf cells of copies
def alias_closure(nets):
    nets = set(nets)
    changed = True
    while changed:
        changed = False
        for dst, src in alias.items():
            if src in nets and dst not in nets:
                nets.add(dst)
                changed = True
    return nets

R = alias_closure({'run'})
bufs = []
frontier = set(R)
for depth in range(2):
    new = set()
    for n, (cell, m) in insts.items():
        if re.match(r'sky130_fd_sc_hd__(buf|clkbuf)_', cell) and n not in bufs:
            ps = dict(pins_of(n))
            if ps.get('A') in frontier:
                bufs.append(n)
                new.add(ps['X'])
    new = alias_closure(new) - R
    R |= new
    frontier = new
print(f'run nets: {len(R)} (run + aliases{" + " + str(len(bufs)) + " buffered copies" if bufs else ""})')

gates = []                     # (instance, [pins on run], [other input pins])
for n, (cell, m) in insts.items():
    if n in bufs or not cell.startswith('sky130_'):
        continue
    ins = [(p, e) for p, e in pins_of(n) if p not in OUTPINS]
    on_run = [p for p, e in ins if e in R]
    if on_run:
        gates.append((n, cell, on_run, [(p, e) for p, e in ins if e not in R]))

edits = {}                     # instance -> new body
decls = []

if tt01:
    # the flop that drives `run`
    net, hops, cur = 'run', 0, None
    while True:
        cur = driver.get(resolve(net))
        assert cur is not None, 'nothing drives run'
        cell = insts[cur][0]
        if re.match(r'sky130_fd_sc_hd__buf_|sky130_fd_sc_hd__clkbuf_', cell) and hops < 2:
            net = dict(pins_of(cur))['A']
            hops += 1
            continue
        break
    cell = insts[cur][0]
    assert re.match(r'sky130_fd_sc_hd__dfrtp_\d+$', cell), f'run is driven by {cell} {cur}, not a dfrtp'
    flops = [n for n, (c, m) in insts.items() if re.match(r'sky130_fd_sc_hd__dfrtp_', c)
             and dict(pins_of(n)).get('Q') in R and n == cur]
    assert flops == [cur], flops
    body = insts[cur][1].group(3)
    old = None
    n_rep = 0
    for p, a, b in conns(body):
        if p == 'D':
            old = body[a:b].strip()
            body = body[:a] + "1'b1" + body[b:]
            n_rep += 1
            break
    assert n_rep == 1 and old is not None, n_rep
    edits[cur] = body
    print(f"--tt01: {cur} ({cell}) behind {hops} buf(s): .D({old}) -> .D(1'b1); 1 replacement")

if delay is not None:
    # fan-in check: each port sees exactly one pin gate
    gate_names = {g[0] for g in gates}
    cover = {}
    for i in range(8):
        for port in (f'uo_out[{i}]', f'uio_oe[{i}]'):
            seen, stack, found = set(), [port], set()
            while stack:
                nt = stack.pop()
                if nt in seen:
                    continue
                seen.add(nt)
                if nt in alias and nt not in driver:
                    stack.append(alias[nt])
                    continue
                d = driver.get(nt)
                if d is None:
                    continue
                cell = insts[d][0]
                if d in gate_names:
                    found.add(d)
                if is_seq(cell):
                    continue
                for p, e in pins_of(d):
                    if p not in OUTPINS:
                        stack.append(e)
            cover[port] = found
    for port, found in cover.items():
        assert len(found) == 1, f'{port}: {len(found)} pin gates in its fan-in: {sorted(found)}'
    used = set().union(*cover.values())
    assert used == {g[0] for g in gates}, f'gates on run that no port sees: {sorted({g[0] for g in gates} - used)}'
    n_edit = 0
    for n, cell, on_run, others in gates:
        body = edits.get(n, insts[n][1].group(3))
        for p, e in others:
            for q, a, b in conns(body):
                if q == p:
                    w = 'gd_' + re.sub(r'\W', '_', n) + '_' + p
                    decls.append(f' wire {w};\n assign #({delay}) {w} = {e}{" " if e.startswith(chr(92)) else ""};\n')
                    body = body[:a] + w + body[b:]
                    n_edit += 1
                    break
        edits[n] = body
    print(f'--pin-delay {delay} ns: {len(gates)} pin gates, {n_edit} SoC-side inputs delayed')
    for n, cell, on_run, others in gates:
        ports = ','.join(p for p, f in cover.items() if n in f)
        print(f'  {n} {cell} run on {on_run} other {[p for p, e in others]} ports {ports}')
    print(f'  ports covered: {len(cover)} of 16')

out, last = [], 0
for name, m in sorted(((n, insts[n][1]) for n in edits), key=lambda x: x[1].start(3)):
    out.append(t[last:m.start(3)])
    out.append(edits[name])
    last = m.end(3)
out.append(t[last:])
t = ''.join(out)
if decls:
    i = inst_re.search(t).start()
    t = t[:i] + ''.join(decls) + t[i:]
open(outp, 'w').write(t)
