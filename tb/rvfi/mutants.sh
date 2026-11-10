#!/bin/bash
# Fault runner for the riscv-formal checks (WO-38). On the sandbox, in a shell with
# `source ~/tools/oss-cad-suite/environment`.
#   bash tb/rvfi/mutants.sh <ID> <check>...        e.g.  mutants.sh ALU01 insn_add_ch0 insn_addi_ch0
# Env: MUTBASE (default build/rvfi-mut)  JOBS (default 1)  TIMEOUT (default 7200)
# <ID> is a tb/mutate/mutants.py id or a tb/rvfi/broken.py id (BC-*). Builds
# $MUTBASE/<ID>/{src,rvfi} = the tree's src/ and tb/rvfi/ plus ONE fault (find string must
# occur exactly once), runs that copy's run.sh with the solver of each check's family (as in the
# batch), prints "<ID> <check> FAIL|PASS|TIMEOUT|ERROR" and appends them to $MUTBASE/results.txt.
# PASS here means BOUNDED (BMC depth N from reset), never PROVED. Deletes src/rvfi/rf after.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ID=${1:?usage: mutants.sh <ID> <check>...}; shift
[ $# -ge 1 ] || { echo "mutants.sh: no checks" >&2; exit 2; }
MUTBASE=${MUTBASE:-build/rvfi-mut}; JOBS=${JOBS:-1}; TIMEOUT=${TIMEOUT:-7200}
mkdir -p "$MUTBASE"; MUTBASE=$(cd "$MUTBASE" && pwd)
D=$MUTBASE/$ID; rm -rf "$D"; mkdir -p "$D"
cp -r "$HERE/../../src" "$D/src"; mkdir -p "$D/rvfi"; cp "$HERE"/* "$D/rvfi/" 2>/dev/null
python3 - "$ID" "$D" "$HERE" <<'PY' || { echo "$ID - ERROR (fault not applied)"; exit 3; }
import sys, importlib.util
mid, d, here = sys.argv[1:4]
def load(p, n):
    s = importlib.util.spec_from_file_location(n, p); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
tab = {}
for p, a in ((here + "/../mutate/mutants.py", "M"), (here + "/broken.py", "B")):
    for t in getattr(load(p, "x" + a), a): tab[t[0]] = t
if mid not in tab: sys.exit("unknown fault id " + mid)
_, f, find, rep, why = tab[mid]
path = d + "/rvfi/" + f[5:] if f.startswith("rvfi/") else d + "/src/" + f
s = open(path).read()
if s.count(find) != 1: sys.exit("%s: find string occurs %d times in %s" % (mid, s.count(find), f))
open(path, "w").write(s.replace(find, rep, 1)); print("fault", mid, f, "-", why)
PY
solver_of() {
  case $1 in
    insn_sll*|insn_srl*|insn_sra*|insn_slli*|insn_srli*|insn_srai*|insn_c_slli*|insn_c_srli*|insn_c_srai*) echo boolector ;;
    insn_mul*|insn_div*|insn_rem*) echo boolector ;;
    reg_*|pc_fwd_*|pc_bwd_*|causal_*|unique_*|liveness*|fyra_imem|lat_*) echo bmc3 ;;
    *) echo yices ;;
  esac
}
for c in "$@"; do echo "$(solver_of "$c" | tail -1) $c"; done | sort > "$D/plan.txt"
for s in $(awk '{print $1}' "$D/plan.txt" | sort -u); do
  only=$(awk -v s=$s '$1==s{printf "%s ", $2}' "$D/plan.txt")
  ONLY="$only" bash "$D/rvfi/run.sh" FYRA_SRC="$D/src" OUT="$D/out" JOBS=$JOBS SOLVER=$s TIMEOUT=$TIMEOUT > "$D/run.$s.log" 2>&1
done
for c in "$@"; do
  if [ -s "$D/out/done/$c" ]; then read -r st _ < "$D/out/done/$c"; else st=ERROR; fi
  echo "$ID $c $st"
done | tee -a "$MUTBASE/results.txt"
mkdir -p "$MUTBASE/logs/$ID"; cp "$D/out/done"/* "$D"/run.*.log "$MUTBASE/logs/$ID/" 2>/dev/null
rm -rf "$D"
