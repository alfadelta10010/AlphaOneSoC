#!/bin/bash
# Resumable, unattended riscv-formal run for fyracore (WO-37). Run on the
# sandbox, in a shell with `source ~/tools/oss-cad-suite/environment`.
#
#   bash tb/rvfi/run.sh [--list] [ONLY="regex ..."] [FYRA_SRC=<dir>] [OUT=<dir>]
#                       [JOBS=4] [SOLVER=...] [TIMEOUT=7200] [RVFORMAL=<dir>]
#
# Each KEY=value may also come from the environment (ONLY="..." bash run.sh).
# A PASS is BMC: "BOUNDED (BMC depth N from reset)", never PROVED.
# $OUT/done/<check> = "PASS|FAIL|TIMEOUT|ERROR <seconds> <depth>". A check with a
# done file is skipped; one without has its sby dir deleted and is rerun.
# Exit 0 only if every selected check PASSes.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIN=c992aa61fdfe0846c5ed90324c596202a1c69b76
LIST=0; ONLY=${ONLY:-}; FYRA_SRC=${FYRA_SRC:-$HERE/../../src}; OUT=${OUT:-build/rvfi}; JOBS=${JOBS:-4}; SOLVER=${SOLVER:-}
TIMEOUT=${TIMEOUT:-7200}; IMEM_DEPTH=${IMEM_DEPTH:-16}; RVFORMAL=${RVFORMAL:-$HOME/regr/vc/rvfi-riscv-formal}
for a in "$@"; do
  case "$a" in
    --list) LIST=1 ;;
    ONLY=*) ONLY=${a#ONLY=} ;;
    FYRA_SRC=*) FYRA_SRC=${a#FYRA_SRC=} ;;
    OUT=*) OUT=${a#OUT=} ;;
    JOBS=*) JOBS=${a#JOBS=} ;;
    SOLVER=*) SOLVER=${a#SOLVER=} ;;
    TIMEOUT=*) TIMEOUT=${a#TIMEOUT=} ;;
    RVFORMAL=*) RVFORMAL=${a#RVFORMAL=} ;;
    *) echo "run.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd); FYRA_SRC=$(cd "$FYRA_SRC" && pwd)

if [ ! -d "$RVFORMAL/.git" ]; then
  git clone -q https://github.com/YosysHQ/riscv-formal.git "$RVFORMAL" || { echo "run.sh: clone failed" >&2; exit 2; }
  git -C "$RVFORMAL" checkout -q $PIN
fi
[ "$(git -C "$RVFORMAL" rev-parse HEAD)" = "$PIN" ] || { echo "run.sh: $RVFORMAL is not at $PIN" >&2; exit 2; }

CORES="fyracore alu branchCtrl compressed_decoder controller csr decoder muldiv pmp regFile signExt"
RF=$OUT/rf; CORE=$RF/cores/fyracore
mkdir -p "$CORE" "$OUT/done"
ln -sfn "$RVFORMAL/checks" "$RF/checks"; ln -sfn "$RVFORMAL/insns" "$RF/insns"
rm -f "$CORE"/*.v "$CORE"/*.sv
for m in $CORES; do cp "$FYRA_SRC/$m.v" "$CORE/$m.v"; done
cp "$HERE/wrapper.sv" "$HERE/rf_top_rvfi.v" "$HERE/imem_top.sv" "$CORE/"
cp "$HERE/checks.cfg" "$CORE/checks.cfg"
[ -n "$SOLVER" ] && sed -i "s/^solver .*/solver $SOLVER/" "$CORE/checks.cfg"
SOLV=$(awk '$1=="solver"{print $2}' "$CORE/checks.cfg")

( cd "$CORE" && md5sum *.v *.sv checks.cfg ; echo "riscv-formal $PIN"; echo "solver $SOLV";
  echo "defines: $(sed -n '/^\[defines/,/^\[verilog-files\]/p' checks.cfg | grep '^`define' | tr '\n' ';')";
  echo "jobs $JOBS timeout $TIMEOUT" ) > "$OUT/manifest.txt"

( cd "$CORE" && python3 "$RF/checks/genchecks.py" > "$OUT/genchecks.log" 2>&1 ) || { cat "$OUT/genchecks.log"; echo "run.sh: genchecks failed" >&2; exit 2; }
CH=$CORE/checks
# bmc3 has no cover mode: the cover check goes to yices
[ "$SOLV" = bmc3 ] && sed -i 's/^abc bmc3$/smtbmc yices/' "$CH/cover.sby"
# abc engines reject "skip" (only checked at step "depth" anyway by the check logic)
[ "$SOLV" = bmc3 ] && sed -i '/^skip /d' "$CH"/*.sby

# custom fetch-consistency check (D7). Always abc bmc3 with no skip (all steps <= IMEM_DEPTH):
# smtbmc/yices does not get past depth ~16 on it, bmc3 does depth 16 in ~45 s. Depth 16 covers
# the fetch-reuse pair (second compressed insn retires by about cycle 14 with waits).
ENG=$(awk '/^\[engines\]/{getline; print; exit}' "$CH/insn_add_ch0.sby")
{
  echo "[options]"; echo "mode bmc"; echo "expect pass,fail"; echo "depth $IMEM_DEPTH"; echo
  echo "[engines]"; echo "abc bmc3"; echo
  echo "[script]"
  echo "read -sv defines.sv imem_top.sv $(awk '/^\[verilog-files\]/{f=1;next} /^\[/{f=0} f&&NF{print}' "$CORE/checks.cfg" | sed "s#@basedir@#$RF#; s#@core@#fyracore#" | tr '\n' ' ')"
  echo "prep -flatten -nordff -top imem_top"; echo "chformal -early"; echo
  echo "[files]"; echo "$RF/checks/rvfi_macros.vh"; echo "$CORE/imem_top.sv"; echo
  echo "[file defines.sv]"
  echo '`define RISCV_FORMAL'; echo '`define RISCV_FORMAL_NRET 1'; echo '`define RISCV_FORMAL_XLEN 32'
  echo '`define RISCV_FORMAL_ILEN 32'; echo '`define FYRA_IMEM_CHECK'
  sed -n '/^\[defines\]/,/^\[/p' "$CORE/checks.cfg" | grep '^`define'
  echo '`include "rvfi_macros.vh"'
} > "$CH/fyra_imem.sby"

[ "$SOLV" = bmc3 ] && sed -i '/^skip /d' "$CH/fyra_imem.sby"
ALL=$( (ls "$CH"/*.sby | xargs -n1 basename | sed 's/\.sby$//') | sort)
if [ -n "$ONLY" ]; then
  SEL=""; for c in $ALL; do for p in $ONLY; do [[ $c =~ ^($p)$ ]] && { SEL="$SEL $c"; break; }; done; done
else SEL=$ALL; fi
if [ $LIST = 1 ]; then for c in $ALL; do echo "$c"; done; echo "$(echo $ALL | wc -w)"; exit 0; fi

one() {
  c=$1; d=$OUT/done/$c
  [ -e "$d" ] && return
  rm -rf "$CH/$c"
  dep=$(awk '/^depth/{print $2-1; exit}' "$CH/$c.sby"); t0=$(date +%s)
  ( cd "$CH" && nice -n 10 timeout "$TIMEOUT" sby -f "$c.sby" > "$CH/$c.log" 2>&1 ); rc=$?
  secs=$(( $(date +%s) - t0 ))
  st=ERROR
  if [ $rc = 124 ]; then st=TIMEOUT
  elif [ -f "$CH/$c/status" ]; then
    case "$(head -1 "$CH/$c/status")" in PASS*) st=PASS ;; FAIL*) st=FAIL ;; esac
  fi
  if [ $st = PASS ]; then
    mkdir -p "$OUT/keep/$c"; cp "$CH/$c/logfile.txt" "$CH/$c/status" "$OUT/keep/$c/" 2>/dev/null
    rm -rf "$CH/$c"
  elif [ $st = FAIL ]; then
    mkdir -p "$OUT/keep/$c"; cp -r "$CH/$c/logfile.txt" "$CH/$c/status" "$CH/$c/engine_0" "$OUT/keep/$c/" 2>/dev/null
    rm -rf "$CH/$c"
  fi
  [ $st = PASS ] && [[ $c == cover ]] && grep -q "Unreached cover" "$OUT/keep/$c/logfile.txt" && st=FAIL
  [ $st = FAIL ] && [[ $c == cover ]] && grep -h "Unreached cover" "$OUT/keep/$c/logfile.txt" >> "$OUT/keep/$c/unreached.txt"
  echo "$st $secs $dep" > "$d"
}
export -f one; export OUT CH TIMEOUT
printf '%s\n' $SEL | xargs -P "$JOBS" -I{} bash -c 'one {}'

n=0; p=0; f=0; t=0; e=0; : > "$OUT/summary.tsv"
for c in $SEL; do
  read -r st secs dep < "$OUT/done/$c" || { st=ERROR; secs=0; dep=0; }
  printf '%s\t%s\t%s\t%s\n' "$c" "$st" "$secs" "$dep" >> "$OUT/summary.tsv"
  n=$((n+1))
  case $st in PASS) p=$((p+1));; FAIL) f=$((f+1));; TIMEOUT) t=$((t+1));; *) e=$((e+1));; esac
done
cat "$OUT/summary.tsv"
msg="rvfi: $n checks, $p PASS, $f FAIL, $t TIMEOUT, $e ERROR"
echo "$msg" | tee -a "$OUT/summary.tsv"
[ $p = $n ]
