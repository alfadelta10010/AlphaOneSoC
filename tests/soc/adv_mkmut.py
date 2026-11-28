#!/usr/bin/env python3
"""Make a throwaway broken copy of a tree for adv_trackb.sh non-vacuity runs.
usage: adv_mkmut.py <tree> <dst> <ID>   ID = a tb/mutate/mutants.py id, or a hand mutant below.
Copies <tree>/{src,tb,tests} to <dst> and applies the fault (the find text must occur exactly once)."""
import os, shutil, subprocess, sys

HAND = {
    # snoop index drops index[3]: a store to a line of data_hi clears lines 0-7's valid bit instead
    "HM2": ("cache.v", "wire [3:0]  kidx  = snoop ? d_addr[7:4] :", "wire [3:0]  kidx  = snoop ? {1'b0, d_addr[6:4]} :"),
    # a store that hits the line being filled marks the fill dead only in data_mem (index[3] = 0)
    "HM5": ("cache.v", "if (fill_active && fill_idx == kidx)", "if (fill_active && fill_idx == kidx && !kidx[3])"),
}
tree, dst, mid = sys.argv[1:4]
if os.path.exists(dst):
    shutil.rmtree(dst)
for d in ("src", "tb", "tests"):
    shutil.copytree(os.path.join(tree, d), os.path.join(dst, d), symlinks=True)
if mid == "HM1":   # the gate-a-4x4 128 B cache (a correct cache that is silently half the size)
    alt = os.path.join(tree, "hm1_cache.v")
    if os.path.exists(alt):
        text = open(alt).read()
    else:
        src = subprocess.run(["git", "-C", tree, "show", "gate-a-4x4:src/cache.v"], capture_output=True, text=True)
        if src.returncode != 0:
            sys.exit("HM1 needs <tree> to be a git clone with tag gate-a-4x4 (or the file at <tree>/hm1_cache.v)")
        text = src.stdout
    open(os.path.join(dst, "src", "cache.v"), "w").write(text)
    sys.exit(0)
if mid in HAND:
    f, find, rep = HAND[mid]
else:
    sys.path.insert(0, os.path.join(tree, "tb", "mutate"))
    import mutants
    hit = [x for x in mutants.M if x[0] == mid]
    if len(hit) != 1:
        sys.exit("unknown mutant " + mid)
    _, f, find, rep, _ = hit[0]
p = os.path.join(dst, "src", f)
s = open(p).read()
if s.count(find) != 1:
    sys.exit("%s: find text occurs %d times in %s" % (mid, s.count(find), f))
open(p, "w").write(s.replace(find, rep))
