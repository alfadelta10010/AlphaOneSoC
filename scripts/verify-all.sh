#!/bin/bash
# verify-all.sh: the whole verification closure behind one resumable command.
# Run it ON THE SANDBOX from a frozen tree (git archive of the commit under test),
# detached, under the thermal watchdog:
#
#   nice -n 10 setsid nohup bash scripts/verify-all.sh OUT=~/regr/vc/run1 TREE=<commit> [STAGES="..."] [FORCE=1] \
#        [BASE=<git rev>] [CHANGED="csr.v syscon.v"] [LAST=<results.tsv>] \
#        [NETLIST=<nl.v>] [PNL=<pnl.v>] [SUITES=<river_core conf dir>] [SDFDIR=<work dir>] \
#        [JOBS=4] > /dev/null 2>&1 &
#   M=~/regr/vc/run1 setsid nohup bash ~/regr/thermal-watch.sh > /dev/null 2>&1 &
#
# Stages (default: unit directed formal rvfi mutation, plus eqy gl sdf for each of
# NETLIST / PNL / SDFDIR that is given):
#   unit      make test-all, then test-seeds with seeds 1..8, then test-wrapper-soc (the mailbox
#             programs through the pins at 10 and 20 ns, RTL)
#   directed  tests/directed/run.sh plain, with +RF_X +RF_COLLIDE_X, and soc
#   formal    tb/formal/run.sh default list on both engines (full verdict lines compared with
#             scripts/verify-all.expected, depth/timeout env overrides unset), then --nonvac on every harness that has a .nonvac
#   rvfi      tb/rvfi/run.sh, one run per solver family, then the fault matrix (mutants.sh)
#   mutation  tb/mutate/run.py on the src files changed since BASE (default main); the
#             kills are compared with LAST (an earlier results.tsv); without LAST the verdict is
#             NO-BASELINE (not PASS); an ERROR/TIMEOUT row or a partial run is FAIL
#   eqy       tb/eqy/run.sh NETLIST=<nl.v>, all stages including the mutants
#   gl        scripts/gl build_isa.sh + night.sh on PNL, parts A B C D (SUITES for A-C)
#   sdf       tb/gls_sdf/run_glitch.sh WORK=SDFDIR, all variants and corners
# river_core is not run here (see docs/verification-runbook.md).
#
# TREE=<commit> (required) is the commit this frozen tree was archived from (git archive has no
# .git). It is written to $OUT/TREE and printed in SUMMARY; relaunching with another TREE refuses
# to reuse the done.<stage> markers (exit 2) unless FORCE=1 (then the markers are deleted).
#
# Every stage writes $OUT/<stage>.verdict (one line: PASS | FAIL | BOUNDED-OK | ERROR, then counts),
# $OUT/<stage>.log and, unless ERROR, the marker $OUT/done.<stage>; relaunching with the same OUT
# skips a stage with a marker (delete the marker to rerun it; ERROR leaves none).
# $OUT/driver.sid holds the session id for the watchdog. $OUT/SUMMARY is written last.
# Exit status: 0 if every stage ran and is PASS or BOUNDED-OK, else 1.
set -u
for a in "$@"; do case $a in *=*) export "${a%%=*}=${a#*=}";; *) echo "verify-all.sh: unknown argument $a" >&2; exit 2;; esac; done
: "${OUT:?OUT=<dir> is required}"
: "${TREE:?TREE=<commit> is required (the commit this tree was archived from)}"
R=$(cd "$(dirname "$0")/.." && pwd)
JOBS=${JOBS:-4}; BASE=${BASE:-main}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
if [ -s "$OUT/TREE" ] && [ "$(cat "$OUT/TREE")" != "$TREE" ]; then
  if [ "${FORCE:-}" = 1 ]; then rm -f "$OUT"/done.*
  elif ls "$OUT"/done.* > /dev/null 2>&1; then
    echo "verify-all.sh: $OUT holds stages of tree $(cat "$OUT/TREE"), not $TREE; use a new OUT or FORCE=1 to rerun them" >&2; exit 2; fi
fi
echo "$TREE" > "$OUT/TREE"
if [ -z "${STAGES:-}" ]; then
  STAGES="unit directed formal rvfi mutation"
  [ -n "${NETLIST:-}" ] && STAGES="$STAGES eqy"
  [ -n "${PNL:-}" ] && STAGES="$STAGES gl"
  [ -n "${SDFDIR:-}" ] && STAGES="$STAGES sdf"
fi
export PATH=/home/mempool/tools/rv64-gcc-elf/bin:/home/mempool/tools/rv32-isa-sim/bin:$PATH
OSS=${OSS:-$HOME/tools/oss-cad-suite/environment}
ps -o sid= -p $$ | tr -d ' ' > "$OUT/driver.sid"; echo $$ > "$OUT/driver.pid"
T0=$SECONDS
cd "$R" || exit 2

oss() { [ -f "$OSS" ] && . "$OSS" > /dev/null 2>&1; command -v sby > /dev/null 2>&1; }   # formal tools, in the calling subshell only
# verdict word + detail -> $OUT/<stage>.verdict
vd() { echo "$2${3:+ $3}" > "$OUT/$1.verdict"; }

# ---- unit
st_unit() {
  local B=build/va-unit   # relative: the Makefile prefixes $(CURDIR) to BUILD_DIR (test-soc-periph's FLASH_FILE)
  make BUILD_DIR="$B" test-all > "$OUT/unit.make.log" 2>&1; local rc1=$?
  make BUILD_DIR="$B" test-seeds SEEDS="1 2 3 4 5 6 7 8" > "$OUT/unit.seeds.log" 2>&1; local rc2=$?
  # its summary prints "FAIL 0" lines, so its log stays out of the unit.*.log scan; the target
  # itself fails on any FAIL or TIMEOUT count above 0
  make BUILD_DIR="$B" test-wrapper-soc > "$OUT/wsoc.log" 2>&1; local rc3=$?
  local np nf; np=$(cat "$B"/*.log 2>/dev/null | grep -c '^PASS'); nf=$(cat "$OUT"/unit.*.log | grep -cE '^FAIL|\*\*\* Error|Error [0-9]')
  if [ $rc1 = 0 ] && [ $rc2 = 0 ] && [ $rc3 = 0 ] && [ "$nf" = 0 ]; then vd unit PASS "test-all rc=0 seeds 1-8 rc=0 wrapper-soc rc=0 PASS-lines=$np"
  else vd unit FAIL "test-all rc=$rc1 test-seeds rc=$rc2 wrapper-soc rc=$rc3 fail-lines=$nf (see unit.make.log, unit.seeds.log, wsoc.log)"; fi
}

# ---- directed
st_directed() {
  local v rc bad=0 txt="" line
  for v in plain rfx soc; do
    local args="" pa=""
    [ $v = rfx ] && pa="+RF_X +RF_COLLIDE_X"; [ $v = soc ] && args=soc
    OUT_DIR="$OUT/directed/$v" RUN_PLUSARGS="$pa" bash tests/directed/run.sh $args > "$OUT/directed.$v.log" 2>&1; rc=$?
    line=$(grep -E '^REGRESS ' "$OUT/directed.$v.log" | tail -1)
    [ $rc = 0 ] && [ -n "$line" ] || bad=1
    txt="$txt $v:rc=$rc[${line:-no REGRESS line}]"
  done
  [ $bad = 0 ] && vd directed PASS "$txt" || vd directed FAIL "$txt"
}

# ---- formal
st_formal() {
  if ! oss; then vd formal ERROR "no sby on PATH after sourcing $OSS"; return; fi
  local eng bad=0 txt="" n nexp v
  # depth/timeout overrides would change what a verdict line means: run the pinned defaults
  for v in $(env | sed -n 's/^\([A-Za-z0-9_]*_\(DEPTH\|TIMEOUT\)\)=.*/\1/p') DEPTH BMC_DEPTH NVDEPTH; do unset "$v"; done
  # the full verdict line minus any "(trace: ...; log: ...)" path. The sat leg proves the
  # induction harnesses with yosys sat ("k-induction"), the sby leg with sby ("sby k-induction"):
  # one expected file serves both legs, so the engine word is dropped; the length is kept
  norm() { sed -E 's/ \((trace|log): [^)]*\)//g; s/\(sby k-induction,/(k-induction,/; s/ +$//' | sort; }
  norm < scripts/verify-all.expected > "$OUT/formal.expected"; nexp=$(grep -c . "$OUT/formal.expected")
  for eng in sat sby; do
    FORMAL_ENGINE=$eng OUT_DIR="$OUT/formal_$eng" bash tb/formal/run.sh > "$OUT/formal.$eng.log" 2>&1
    grep -E '^(PROVED|BOUNDED|COVERED|FAILED|ERROR) ' "$OUT/formal.$eng.log" | norm > "$OUT/formal.$eng.got"
    if diff "$OUT/formal.expected" "$OUT/formal.$eng.got" > "$OUT/formal.$eng.diff"; then txt="$txt $eng:$nexp/$nexp-match"
    else bad=1; txt="$txt $eng:$(grep -c '^[<>]' "$OUT/formal.$eng.diff")-verdict-lines-differ(see formal.$eng.diff)"; fi
  done
  # only harnesses of the default list (the names in verify-all.expected); opt-in ones (mem_li, ...) are residuals
  local names=""; for f in tb/formal/*.nonvac; do n=$(basename "$f" .nonvac)
    awk -v n="$n" '$2==n{f=1} END{exit !f}' scripts/verify-all.expected && names="$names $n"; done
  bash tb/formal/run.sh --nonvac $names > "$OUT/formal.nonvac.log" 2>&1
  local ok miss er; ok=$(grep -c '^NONVAC-OK' "$OUT/formal.nonvac.log"); miss=$(grep -c '^NONVAC-MISS' "$OUT/formal.nonvac.log"); er=$(grep -c '^NONVAC-ERROR' "$OUT/formal.nonvac.log")
  txt="$txt nonvac:ok=$ok,miss=$miss,error=$er"
  [ "$miss" = 0 ] && [ "$er" = 0 ] && [ "$ok" -gt 0 ] || bad=1
  grep -qE '^(ERROR|NONVAC-ERROR)' "$OUT"/formal.*.log && { vd formal ERROR "$txt"; return; }
  [ $bad = 0 ] && vd formal PASS "$txt" || vd formal FAIL "$txt"
}

# ---- rvfi
RVFI_MATRIX='ALU01 insn_add_ch0 insn_addi_ch0 insn_c_add_ch0
ALU06 insn_slt_ch0 insn_slti_ch0
BR02 insn_bge_ch0
BR05 insn_bltu_ch0
SE01 insn_jal_ch0
SE03 insn_sb_ch0 insn_sw_ch0
CT01 insn_lbu_ch0
FC22 insn_lb_ch0 insn_sb_ch0
FC24 insn_sb_ch0
FC43 insn_jalr_ch0
FC72 insn_c_jal_ch0 insn_c_jalr_ch0
CD01 insn_c_addi4spn_ch0
CD07 insn_c_srai_ch0
CD16 insn_c_jalr_ch0
RFF02 insn_c_beqz_ch0
RF02 insn_c_lw_ch0
BC-ILL ill_ch0
FC51 insn_lw_ch0
BC-COV cover
FR06 fyra_imem
FR01 fyra_imem
FR02 fyra_imem
FR05 fyra_imem
FC52 fyra_imem
MD05 insn_srl_ch0 insn_srli_ch0
MD06 insn_sll_ch0
CT16 insn_div_ch0 insn_divu_ch0
BC-ALTMUL insn_mul_ch0
BC-ALTDIV insn_div_ch0
MD01 insn_mulhsu_ch0
MD03 insn_div_ch0
MD10 insn_mulhsu_ch0
RG05 reg_ch0
FC01 reg_ch0
FC56 reg_ch0
BC-PC1 pc_fwd_ch0 pc_bwd_ch0
BC-ORD-DOWN causal_ch0
BC-ORD-TRAP unique_ch0
MD08 liveness_ch0
FC44 liveness_ch0'
RVFI_SURVIVORS="FC51 MD01 MD03 MD10 RG05"   # the faults the port cannot see (tb/rvfi/RESULTS.md)
st_rvfi() {
  if ! oss; then vd rvfi ERROR "no sby on PATH after sourcing $OSS"; return; fi
  local RO=$OUT/rvfi MB=$OUT/rvfi-mut SH MM ALL fam
  mkdir -p "$RO"
  ALL=$(bash tb/rvfi/run.sh --list OUT="$RO/listtmp" 2>/dev/null | grep -v '^[0-9]*$')
  SH='insn_(sll|srl|sra|slli|srli|srai|c_slli|c_srli|c_srai)_ch0'; MM='insn_(mul|mulh|mulhsu|mulhu|div|divu|rem|remu)_ch0'
  # run.sh regenerates the shared rf/ tree per SOLVER, so the families run one after the other
  fam() { [ -e "$RO/fam.$1.done" ] && return; bash tb/rvfi/run.sh OUT="$RO" JOBS="$JOBS" TIMEOUT=7200 SOLVER=$2 ONLY="$3" > "$OUT/rvfi.fam.$1.log" 2>&1; touch "$RO/fam.$1.done"; }
  fam plain yices "$(echo "$ALL" | grep -E '^(insn_.*_ch0|ill_ch0)$' | grep -vE "^($SH|$MM)\$" | tr '\n' ' ')"
  fam consist bmc3 "reg_ch0 pc_fwd_ch0 pc_bwd_ch0 causal_ch0 unique_ch0 liveness_ch0"
  fam shiftM boolector "$(echo "$ALL" | grep -E "^($SH|$MM)\$" | tr '\n' ' ')"
  fam cover yices "cover"
  fam imem bmc3 "fyra_imem lat_mul lat_div lat_sll31"
  local c n=0 p=0 st s d other=""
  for c in $ALL; do read -r st s d < "$RO/done/$c" 2>/dev/null || st=MISSING
    n=$((n + 1)); case $st in PASS|REACHED) p=$((p + 1));; *) other="$other $c:$st";; esac; done
  # fault matrix: a row is killed when some check FAILs; the survivors are the known blind spots
  mkdir -p "$MB"
  echo "$RVFI_MATRIX" | while read -r id checks; do
    [ -e "$MB/ok.$id" ] && continue
    MUTBASE=$MB JOBS=1 TIMEOUT=7200 bash tb/rvfi/mutants.sh $id $checks >> "$OUT/rvfi.mut.log" 2>&1 && touch "$MB/ok.$id"
  done
  local rows=0 killed=0 badm="" id
  for id in $(echo "$RVFI_MATRIX" | awk '{print $1}'); do
    rows=$((rows + 1))
    if grep -qE "^$id .* (TIMEOUT|ERROR)$" "$MB/results.txt" 2>/dev/null || ! grep -q "^$id " "$MB/results.txt" 2>/dev/null; then badm="$badm $id:no-verdict"; continue; fi
    if grep -qE "^$id .* FAIL$" "$MB/results.txt"; then
      killed=$((killed + 1)); case " $RVFI_SURVIVORS " in *" $id "*) [ $id = RG05 ] || badm="$badm $id:expected-survivor-killed";; esac
    else case " $RVFI_SURVIVORS " in *" $id "*) ;; *) badm="$badm $id:survived";; esac; fi
  done
  local txt="checks=$n pass/reached=$p other=[${other# }] faults=$rows killed=$killed unexpected=[${badm# }] (BMC from reset, never PROVED)"
  if [ "$p" = "$n" ] && [ "$n" -gt 0 ] && [ -z "$badm" ]; then vd rvfi BOUNDED-OK "$txt"; else vd rvfi FAIL "$txt"; fi
}

# ---- mutation
st_mutation() {
  local files res=$OUT/mutation/results.tsv
  mkdir -p "$OUT/mutation"
  if [ -n "${CHANGED:-}" ]; then files=$CHANGED
  elif [ -e "$R/.git" ]; then files=$(git diff --name-only "$BASE" -- src | sed 's#^src/##' | grep '\.v$')
  else vd mutation ERROR "no git tree and no CHANGED=\"a.v b.v\""; return; fi
  if [ -z "$files" ]; then vd mutation PASS "no src file changed since $BASE"; return; fi
  oss > /dev/null 2>&1
  local f
  rm -f "$OUT/mutation.rc"
  for f in $files; do
    python3 tb/mutate/run.py -j "$JOBS" --file "$f" --benches unit,dir,soc,dir-soc,formal --results "$res" >> "$OUT/mutation.log" 2>&1 \
      || echo "$f:$?" >> "$OUT/mutation.rc"
  done
  python3 - "$res" "${LAST:-}" "$files" > "$OUT/mutation.report" <<'PY'
import sys, collections
def load(p):
    d = {}
    try:
        for l in open(p):
            c = l.rstrip("\n").split("\t")
            if len(c) >= 4: d[(c[0], c[2])] = c[3]
    except OSError: pass
    return d
new = load(sys.argv[1]); old = load(sys.argv[2]) if sys.argv[2] else {}
cnt = collections.Counter(new.values())
lost = sorted(k for k, v in old.items() if v.startswith("KILLED") and k in new and not new[k].startswith("KILLED"))
print("files: " + sys.argv[3]); print("rows: " + " ".join("%s=%d" % kv for kv in sorted(cnt.items())))
print("lost kills vs LAST: %s" % (" ".join("%s/%s:%s" % (m, b, new[(m, b)]) for m, b in lost) or ("none" if old else "n/a (no LAST)")))
print("LOST %d" % len(lost))
print("BAD %d" % sum(1 for v in new.values() if v in ("ERROR", "TIMEOUT")))
PY
  local lost err miss="" sum; lost=$(sed -n 's/^LOST //p' "$OUT/mutation.report"); err=$(sed -n 's/^BAD //p' "$OUT/mutation.report")
  sum=$(sed -n 2p "$OUT/mutation.report")
  # a partial run: a listed file with no rows in results.tsv, or a run.py that did not exit 0
  for f in $files; do grep -q "^[^	]*	$f	" "$res" 2>/dev/null || miss="$miss $f"; done
  [ -s "$OUT/mutation.rc" ] && miss="$miss run.py-rc=$(tr '\n' ',' < "$OUT/mutation.rc")"
  if [ ! -s "$res" ] || [ -n "$miss" ]; then vd mutation FAIL "partial run: no rows / non-zero run.py for:${miss:- all} $sum"
  elif [ "${err:-?}" != 0 ]; then vd mutation FAIL "$sum error-or-timeout-rows=${err:-?} lost-kills=${lost:-?}"
  elif [ -z "${LAST:-}" ]; then vd mutation NO-BASELINE "$sum (no LAST=<results.tsv>: lost kills cannot be checked)"
  elif [ "${lost:-?}" = 0 ]; then vd mutation PASS "$sum lost-kills=0"
  else vd mutation FAIL "$sum lost-kills=${lost:-?}"; fi
}

# ---- eqy / gl / sdf
st_eqy() {
  bash tb/eqy/run.sh NETLIST="$NETLIST" JOBS="$JOBS" > "$OUT/eqy.log" 2>&1; local rc=$?
  local last; last=$(tail -1 "$OUT/eqy.log")
  case $rc in 0) vd eqy PASS "$last";; 1) vd eqy FAIL "$last";; *) vd eqy ERROR "rc=$rc $last";; esac
}
st_gl() {
  local G=$OUT/gl parts=${GLPARTS:-A B C D}; mkdir -p "$G"
  bash scripts/gl/build_isa.sh ${SUITES:+SUITES="$SUITES"} PARTS="$parts" OUT="$G/build" > "$OUT/gl.build.log" 2>&1
  bash scripts/gl/night.sh D="$G/run" NETLIST="$PNL" BUILD="$G/build" JOBS=auto PARTS="$parts" > "$OUT/gl.log" 2>&1
  [ -e "$G/run/RUN_DONE" ] || { vd gl ERROR "night did not finish (see $G/run/STATUS)"; return; }
  local d bad=0 nf=0 np=0 nk=0 mutmiss=0 v
  for d in "$G"/run/gl-*; do for v in "$d"/*.verdict; do [ -e "$v" ] || continue
    case "$(cut -d' ' -f1 "$v")" in PASS) np=$((np + 1));; *) if grep -q 'known:' "$v"; then nk=$((nk + 1)); else nf=$((nf + 1)); fi;; esac; done; done
  for d in "$G"/run/mut-*; do [ -d "$d" ] || continue; for v in "$d"/*.verdict; do [ -e "$v" ] || continue
    [ "$(cut -d' ' -f1 "$v")" = PASS ] && mutmiss=$((mutmiss + 1)); done; done
  [ $nf = 0 ] && [ $mutmiss = 0 ] && [ $np -gt 0 ] && vd gl PASS "pass=$np known=$nk fail=$nf mutants-not-caught=$mutmiss" || vd gl FAIL "pass=$np known=$nk fail=$nf mutants-not-caught=$mutmiss"
}
st_sdf() {
  bash tb/gls_sdf/run_glitch.sh WORK="$SDFDIR" > "$OUT/sdf.log" 2>&1
  local last; last=$(tail -1 "$OUT/sdf.log")
  case "$last" in *"PASS") vd sdf PASS "$last";; *"FAIL"*) vd sdf FAIL "$last";; *) vd sdf ERROR "$last";; esac
}

# ---- main
ALLOK=1
for s in $STAGES; do
  case $s in unit|directed|formal|rvfi|mutation|eqy|gl|sdf) ;; *) echo "verify-all.sh: unknown stage $s" >&2; exit 2;; esac
  case $s in eqy) [ -n "${NETLIST:-}" ] || { vd eqy ERROR "NETLIST= is required"; continue; };;
             gl) [ -n "${PNL:-}" ] || { vd gl ERROR "PNL= is required"; continue; };;
             sdf) [ -n "${SDFDIR:-}" ] || { vd sdf ERROR "SDFDIR= is required"; continue; };; esac
  [ -e "$OUT/done.$s" ] && continue
  t=$SECONDS
  ( "st_$s" ) > "$OUT/$s.log" 2>&1
  echo $((SECONDS - t)) > "$OUT/$s.secs"
  [ -s "$OUT/$s.verdict" ] || vd $s ERROR "stage produced no verdict (see $s.log)"
  case "$(cut -d' ' -f1 "$OUT/$s.verdict")" in ERROR) ;; *) touch "$OUT/done.$s";; esac
done
{
  for s in $STAGES; do
    printf '%-9s %s  [%ss]\n' "$s" "$(cat "$OUT/$s.verdict" 2>/dev/null || echo 'ERROR not run')" "$(cat "$OUT/$s.secs" 2>/dev/null || echo 0)"
    case "$(cut -d' ' -f1 "$OUT/$s.verdict" 2>/dev/null)" in PASS|BOUNDED-OK) ;; *) ALLOK=0;; esac
  done
  echo "total wall (this launch) $((SECONDS - T0)) s; tree $TREE"
} > "$OUT/SUMMARY.tmp"
mv "$OUT/SUMMARY.tmp" "$OUT/SUMMARY"
cat "$OUT/SUMMARY"
[ $ALLOK = 1 ]
