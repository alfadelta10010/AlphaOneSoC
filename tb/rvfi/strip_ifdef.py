#!/usr/bin/env python3
"""Print a Verilog file with every `ifdef RISCV_FORMAL / RISCV_FORMAL_ALTOPS
region removed (the `else arm's lines are kept). Other conditionals are left
alone; nested ifdef/ifndef inside a region are skipped with it.
Exit 2 on unbalanced directives."""
import re, sys

RF = re.compile(r'^\s*`ifdef\s+RISCV_FORMAL(_ALTOPS)?\b')
OPEN = re.compile(r'^\s*`if(n?def)\b')
ELSE = re.compile(r'^\s*`else\b')
ELSIF = re.compile(r'^\s*`elsif\b')
END = re.compile(r'^\s*`endif\b')

def main(path):
    out = []
    # stack entries: 'rf' (ours) or 'other'; state: skipping (True while the
    # active arm of an 'rf' region is the ifdef arm)
    stack = []      # list of [kind, skipping]
    skip_depth = 0  # >0 while any enclosing rf region is in its ifdef arm
    for n, line in enumerate(open(path).read().split('\n')):
        # the file's final element after the last \n is '' and is re-joined
        if RF.match(line) and not skip_depth:
            stack.append(['rf', True]); skip_depth += 1; continue
        if OPEN.match(line):
            stack.append(['other', False])
            if skip_depth: continue
            out.append(line); continue
        if ELSIF.match(line):
            if not stack: _die("unbalanced `elsif at line %d" % (n + 1))
            if stack[-1][0] == 'rf': _die("`elsif in an RISCV_FORMAL region, line %d" % (n + 1))
            if skip_depth: continue
            out.append(line); continue
        if ELSE.match(line):
            if not stack: _die("unbalanced `else at line %d" % (n + 1))
            if stack[-1][0] == 'rf':
                if stack[-1][1]:
                    stack[-1][1] = False; skip_depth -= 1
                continue
            if skip_depth: continue
            out.append(line); continue
        if END.match(line):
            if not stack: _die("unbalanced `endif at line %d" % (n + 1))
            kind, skipping = stack.pop()
            if kind == 'rf':
                if skipping: skip_depth -= 1
                continue
            if skip_depth: continue
            out.append(line); continue
        if skip_depth: continue
        out.append(line)
    if stack: _die("unbalanced: %d unterminated `ifdef at EOF" % len(stack))
    sys.stdout.write('\n'.join(out))

def _die(msg):
    sys.stderr.write("strip_ifdef: " + msg + "\n"); sys.exit(2)

if __name__ == '__main__':
    if len(sys.argv) != 2: _die("usage: strip_ifdef.py <file>")
    main(sys.argv[1])
