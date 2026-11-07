#!/bin/bash
# eqy-refit.sh: the one manual step after every harden, as far as it can be automated.
# Run ON THE SANDBOX (tb/eqy/run.sh needs docker and the PDK there), in a frozen tree:
#
#   bash scripts/eqy-refit.sh NETLIST=<nl.v> [WORK=<dir>] [JOBS=4] [APPLY=1]
#   e.g. NETLIST=/home/mempool/tt/projects/fin-3x4/runs/wokwi/final/nl/tt_um_alfadelta10010_alphaone_soc.nl.v
#
# tb/eqy/run.sh dies on a netlist whose md5 is not its NL_MD5, so the refit works on a copy of
# src/ and tb/eqy/ under WORK (default build/eqy-refit) in which NL_MD5 is the new md5, and
# which stops after the EQY setup. It
#   1. prints the netlist md5;
#   2. runs the read, lemma and fsminv stages (flop accounting by tb/eqy/accounting.py,
#      the 186 constant bits, the one-hot invariant of the four recoded FSMs);
#   3. runs the setup of the prove stage and prints the partition count;
#   4. writes WORK/refit.patch: NL_MD5 in run.sh, the EXPECT tables of accounting.py and
#      matchreport.py, and the partition count of verdict.py.
# Nothing in the repository is changed unless APPLY=1, and APPLY=1 is refused (exit 3) when the
# accounting shows a flop that nothing explains, an unmatched flop, a changed constant set or a
# changed recoded FSM (new FSMs need an enc/dec table in fsmcut.v and tie lists by a person).
# Exit status: 0 patch written (and applied if asked), 3 a person must look, 2 a stage failed.
set -u
for a in "$@"; do case $a in *=*) export "${a%%=*}=${a#*=}";; *) echo "eqy-refit.sh: unknown argument $a" >&2; exit 2;; esac; done
: "${NETLIST:?NETLIST=<nl.v> is required}"
R=$(cd "$(dirname "$0")/.." && pwd); JOBS=${JOBS:-4}; WORK=${WORK:-$R/build/eqy-refit}
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd); NETLIST=$(realpath "$NETLIST")
T=$WORK/tree
md5=$(md5sum "$NETLIST" | cut -d' ' -f1)
echo "netlist  $NETLIST"; echo "md5      $md5"
rm -rf "$T"; mkdir -p "$T/tb"; cp -r "$R/src" "$T/src"; cp -r "$R/tb/eqy" "$T/tb/eqy"; rm -rf "$T/tb/eqy/__pycache__"
RUN=$T/tb/eqy/run.sh
n=$(grep -c '^NL_MD5=[0-9a-f]*$' "$RUN"); [ "$n" = 1 ] || { echo "eqy-refit.sh: NL_MD5 line not found once in run.sh" >&2; exit 2; }
sed -i "s/^NL_MD5=[0-9a-f]*\$/NL_MD5=$md5/" "$RUN"
# stop after the setup of the prove stage (the partition list, the match report), before any proof
n=$(grep -c '^  say "prove: \$(tail -1' "$RUN"); [ "$n" = 1 ] || { echo "eqy-refit.sh: run.sh changed: the 'say \"prove:' line is not unique; update this script" >&2; exit 2; }
sed -i '/^  say "prove: \$(tail -1/a\  [ -n "${SETUP_ONLY:-}" ] \&\& { echo "EQY STAGE setup OK"; exit 0; }' "$RUN"
export GITREV="refit"
for s in read lemma fsminv prove; do
  echo "--- stage $s"
  SETUP_ONLY=1 bash "$RUN" NETLIST="$NETLIST" JOBS="$JOBS" STAGE=$s > "$WORK/stage.$s.log" 2>&1; rc=$?
  tail -3 "$WORK/stage.$s.log"
  [ "$s" = read ] && [ -f "$T/build/eqy/read/accounting.txt" ] && { echo "--- flop accounting"; cat "$T/build/eqy/read/accounting.txt"; }
  if [ $rc != 0 ]; then
    if [ "$s" = lemma ] || [ "$s" = fsminv ]; then echo "eqy-refit.sh: stage $s failed (rc=$rc): the constant set or the FSM invariant changed; a person must look (see $WORK/stage.$s.log)"; exit 3; fi
    echo "eqy-refit.sh: stage $s failed (rc=$rc), see $WORK/stage.$s.log"; exit 2
  fi
done
B=$T/build/eqy
PC=$(grep -c . "$B/prove/eqy/partition.list"); echo "--- partitions $PC"
echo "--- match report"; cat "$B/prove/match.txt"
python3 - "$R" "$B" "$WORK" "$md5" "$PC" <<'PY'
import re, sys, os, difflib
R, B, W, md5, pc = sys.argv[1:5] + [int(sys.argv[5])]
acc = open(B + "/read/accounting.txt").read(); mt = open(B + "/prove/match.txt").read()
def num(pat, s):
    m = re.search(pat, s, re.M); return int(m.group(1)) if m else None
got = dict(gold=num(r"gold flop bits\s+(\d+)", acc), gate=num(r"gate flops\s+(\d+)", acc), direct=num(r"direct name match\s+(\d+)", acc),
           rename=num(r"same flop, other name\s+(\d+)", acc), recode_gold=num(r"recoded FSM bits, gold\s+(\d+)", acc),
           recode_gate=num(r"recoded FSM bits, gate\s+(\d+)", acc), removed=num(r"removed by synthesis\s+(\d+)", acc),
           cand=num(r"constant bits \(CSR.*?\)\s+(\d+)", acc), unused=num(r"unused gpio bits\s+(\d+)", acc),
           stray=num(r"no gold bit explains: (\d+)", acc), unmatched=num(r"^\s*UNMATCHED\s+(\d+)", mt))
print("--- derived:", got)
why = []
if None in got.values(): why.append("a count could not be read (%s)" % [k for k, v in got.items() if v is None])
else:
    if got["stray"]: why.append("%d gate flops that no gold bit explains (new flops)" % got["stray"])
    if got["unmatched"]: why.append("%d flop bits EQY did not match" % got["unmatched"])
    if got["cand"] != 186 or got["unused"] != 2: why.append("the constant set changed (cand %s, unused %s)" % (got["cand"], got["unused"]))
    if (got["recode_gold"], got["recode_gate"]) != (10, 19): why.append("the recoded FSM bits changed (gold %s, gate %s): a new or changed FSM" % (got["recode_gold"], got["recode_gate"]))
    if got["rename"] != 7: why.append("the rename count changed to %s (check EXPLICIT_RENAME and renames.txt)" % got["rename"])
def edit(path, fn):
    s = open(R + "/" + path).read(); t = fn(s); return s, t
edits = {}
edits["tb/eqy/run.sh"] = edit("tb/eqy/run.sh", lambda s: re.sub(r"^NL_MD5=[0-9a-f]+$", "NL_MD5=" + md5, s, count=1, flags=re.M))
if not why:
    def acc_fn(s):
        m = re.search(r"EXPECT = dict\(.*?\)", s, re.S); b = m.group(0)
        for k in ("direct", "removed", "gold", "gate"):
            b = re.sub(r"(?<![a-z_])%s=\d+" % k, "%s=%d" % (k, got[k]), b)
        return s.replace(m.group(0), b, 1)
    edits["tb/eqy/accounting.py"] = edit("tb/eqy/accounting.py", acc_fn)
    edits["tb/eqy/matchreport.py"] = edit("tb/eqy/matchreport.py", lambda s: re.sub(r"(EXPECT = dict\(direct=)\d+", r"\g<1>%d" % got["direct"], s, count=1))
    edits["tb/eqy/verdict.py"] = edit("tb/eqy/verdict.py", lambda s: s.replace("!= 165", "!= %d" % pc).replace("expected 165", "expected %d" % pc))
out = []
for p, (a, b) in edits.items():
    out += list(difflib.unified_diff(a.splitlines(True), b.splitlines(True), "a/" + p, "b/" + p))
open(W + "/refit.patch", "w").write("".join(out))
print("--- patch: %s/refit.patch (%d lines)" % (W, len(out)))
print("".join(out))
if why:
    print("MANUAL: " + "; ".join(why)); print("Only NL_MD5 is in the patch; the tables need a person (docs/verification-runbook.md, 'EQY refit').")
    sys.exit(3)
print("Not covered by this script: tb/VPLAN.md 4.4 and docs/CLAUDE.md quote the md5 and the partition count; the GL refs and SDF run use the new pnl.")
PY
rc=$?
if [ $rc = 0 ] && [ "${APPLY:-0}" = 1 ]; then ( cd "$R" && patch -p1 < "$WORK/refit.patch" ) && echo "applied"; fi
if [ $rc = 3 ] && [ "${APPLY:-0}" = 1 ]; then echo "APPLY=1 refused: a person must look"; fi
exit $rc
