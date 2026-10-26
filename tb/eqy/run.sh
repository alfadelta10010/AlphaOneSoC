#!/bin/bash
# Equivalence of the branch RTL (gold) and the hardened post-PnR netlist
# (gate): every flop's next-state function and every output, by EQY (WO-24).
# Runs on the sandbox, inside the librelane container (eqy/sby/yosys 0.62).
#
#   tb/eqy/run.sh NETLIST=<nl.v> [PDK_ROOT=<dir>] [JOBS=4] [STAGE=read|lemma|prove|mutants]
#
# Stages, in order; STAGE= runs one, otherwise all. Each writes
# build/eqy/<stage>/ and, once it has succeeded, the stamp build/eqy/<stage>.done
# (a stage with a stamp is skipped, so a run can be relaunched after a reboot;
# delete the stamp, or build/eqy, to redo one). build/eqy/STATUS has a
# timestamped line per stage.
#
#   read     md5 of the netlist and the Liberty file; gold and gate read; the
#            flop accounting (accounting.py) against the work order's table
#   lemma    on the RTL: the 184 removed CSR bits are constant after reset and
#            the recoded FSMs never hold an unlisted code (lemma_props.sv,
#            yosys sat -tempinduct); writes consts.txt, the ties of the gold
#   prove    EQY on gold (ties applied) against gate: strategy sat for every
#            partition, then sby abc pdr for those sat leaves open
#   mutants  three runs that must FAIL: two mutated netlists (mutate_netlist.py,
#            a gate changed in the D cone of one flop; core and syscon) and the
#            gold with one constant left untied. Setup is redone for each, but
#            only the partitions that hold the changed flop are run.
#
# The last line is `EQY PASS`, `EQY FAIL <partitions>` or `EQY UNPROVEN
# <partitions>` (the prove stage); `EQY VACUOUS <mutants>` instead when a
# mutant was not caught. STAGE=read|lemma ends with `EQY STAGE <name> OK`.
# Exit status: 0 pass, 1 fail, 2 unproven or error, 3 vacuous.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NETLIST=""; PDK_ROOT="${PDK_ROOT:-/home/mempool/tt/pdk}"; JOBS=4; STAGE=""
for a in "$@"; do
  case "$a" in
    NETLIST=*) NETLIST="${a#NETLIST=}";;
    PDK_ROOT=*) PDK_ROOT="${a#PDK_ROOT=}";;
    JOBS=*) JOBS="${a#JOBS=}";;
    STAGE=*) STAGE="${a#STAGE=}";;
    *) echo "unknown argument $a" >&2; exit 2;;
  esac
done
[ -n "$NETLIST" ] || { echo "NETLIST=<path> is required" >&2; exit 2; }
NL_MD5=fbf13f2241e6945e98f00b43705f7c8b
# The version of the PDK the harden used (not what $PDK_ROOT/sky130A points to).
LIB="$PDK_ROOT/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
TOP=tt_um_alfadelta10010_alphaone_soc
# The harden's sources, in resolved.json's order.
SRCS="tt_um_alfadelta10010_alphaone_soc.v alphaone_soc.v fyracore.v alu.v branchCtrl.v clint.v compressed_decoder.v controller.v csr.v decoder.v muldiv.v pmp.v regFile.v rf_top.v signExt.v qspi_ctrl.v mem_ctrl.v soc_bus.v uart.v gpio.v syscon.v"
# FSM registers that synthesis recoded one-hot (kept as buses in gold and gate).
FSMS="soc.cpu.exwb_memSize soc.cpu.muldiv_inst.st soc.qspi.state"
B="$ROOT/build/eqy"
# The tools run in the container, in the caller's directory. NATIVE=1 runs
# them from PATH instead (inside a container already).
dk() {
  if [ "${NATIVE:-0}" = 1 ]; then "$@"; return; fi
  # The container has no make, which eqy needs: the host's GNU make runs
  # through the host's own libc (mounted read-only), via the wrapper below.
  docker run --rm -u "$(id -u):$(id -g)" -v /home/mempool:/home/mempool \
    -v /usr/bin/make:/opt/hostmake/make:ro -v /lib/x86_64-linux-gnu:/opt/hostmake/lib:ro \
    -w "$PWD" ghcr.io/librelane/librelane:3.0.14 \
    bash -c 'export PATH="'"$B"'/bin:$PATH"; exec "$@"' _ "$@"
}
mkdir -p "$B/bin"
cat > "$B/bin/make" <<'EOF'
#!/usr/bin/env bash
exec /opt/hostmake/lib/ld-linux-x86-64.so.2 --library-path /opt/hostmake/lib /opt/hostmake/make "$@"
EOF
chmod +x "$B/bin/make"
cat > "$B/bin/awk" <<'EOF'
#!/usr/bin/env bash
# awk shim for EQY's sby wrapper: only awk '{print $1}' FILE
f="${@: -1}"; read -r a _ < "$f"; echo "$a"
EOF
chmod +x "$B/bin/awk"
STATUS="$B/STATUS"
say() { echo "$(date -Is) $*" | tee -a "$STATUS"; }
die() { say "ERROR $*"; echo "EQY ERROR $*"; exit 2; }
yos() { local log="$1"; shift; ( cd "$B" && dk yosys -ql "$log" "$@" ) > /dev/null 2>&1; }

gold_common() {            # RTL read to the pre-tie gold, as RTLIL
  for f in $SRCS; do echo "read_verilog -sv $ROOT/src/$f"; done
  cat <<EOF
hierarchy -top $TOP
proc -norom
flatten
delete t:\$scopeinfo
opt_clean
setundef -undriven -zero
setattr -unset init
opt_clean
write_rtlil $B/read/gold_pre.il
EOF
}

# ---------------------------------------------------------------- read ------
stage_read() {
  mkdir -p "$B/read"; local R="$B/read"
  local md5; md5=$(md5sum "$NETLIST" | cut -d' ' -f1)
  [ "$md5" = "$NL_MD5" ] || die "netlist md5 $md5, expected $NL_MD5"
  [ -f "$LIB" ] || die "no Liberty file at $LIB"
  { echo "netlist  $NETLIST  $md5"
    echo "liberty  $LIB  $(md5sum "$LIB" | cut -d' ' -f1)"
    echo "src      $(cd "$ROOT/src" && md5sum $SRCS | md5sum | cut -d' ' -f1)  (md5 of the 21 per-file md5 lines)"
    ( cd "$B" && dk yosys -V; dk eqy --version; dk sby --version ) 2>&1
    echo "git      $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "${GITREV:-unknown (not a git tree)}")"; } > "$R/inputs.txt"
  if [ -d /home/mempool/tt/projects/sc-3x4/src ]; then      # the harden's own copy: log only
    for f in $SRCS; do
      a=$(md5sum < "$ROOT/src/$f"); b=$(md5sum < "/home/mempool/tt/projects/sc-3x4/src/$f" 2>/dev/null)
      [ "$a" = "$b" ] || echo "NOTE: src/$f differs from the harden's copy" >> "$R/inputs.txt"
    done
  fi
  gold_common > "$R/gold_pre.ys"
  yos read/gold_pre.log read/gold_pre.ys || die "gold read failed (see $R/gold_pre.log)"
  grep -iE "^(warning|error)" "$R/gold_pre.log" | sort | uniq -c > "$R/gold_pre.warnings"
  cat > "$R/gold_json.ys" <<EOF
read_rtlil $R/gold_pre.il
splitnets -format []
write_json $R/gold.json
EOF
  yos read/gold_json.log read/gold_json.ys || die "gold json failed"
  gate_script > "$R/gate_pre.ys"
  cat >> "$R/gate_pre.ys" <<EOF
write_json $R/gate.json
EOF
  yos read/gate_pre.log read/gate_pre.ys || die "gate read failed (see $R/gate_pre.log)"
  grep -iE "^(warning|error)" "$R/gate_pre.log" | sort | uniq -c > "$R/gate_pre.warnings"
  python3 "$HERE/accounting.py" "$R/gold.json" "$R/gate.json" "$R" > "$R/match.txt"
  local rc=$?
  cat "$R/match.txt"
  cp "$R/consts.cand" "$B/consts.cand"
  [ $rc = 0 ] || say "read: accounting differs from the work order's table (see read/match.txt)"
  return 0
}

gate_script() {            # netlist to flat gate; FSM registers as buses for [recode]
  cat <<EOF
read_liberty -ignore_miss_func $LIB
read_verilog $HERE/stubs.v
read_verilog -DSYNTHESIS $ROOT/src/rf_top.v
read_verilog $NETLIST
hierarchy -top $TOP
# private cell names, so flatten's pin wires (inst.PIN) are private too and opt_clean
# keeps the netlist's own net names for the nets they alias
rename -hide t:sky130_fd_sc_hd__*
flatten
delete =sky130_fd_sc_hd__fill_1 =sky130_fd_sc_hd__fill_2 =sky130_fd_sc_hd__tapvpwrvgnd_1
delete t:\$scopeinfo
hierarchy -top $TOP
opt_clean
splitnets -ports -format []
EOF
  gate_fsm_buses
}

gate_fsm_buses() {         # \name[0..n-1] scalar flop nets joined into a bus \name
  local name width i list
  while read -r name width; do
    list=""
    for ((i = width - 1; i >= 0; i--)); do list="$list,\\$name[$i]"; done
    echo "add -wire $name $width"
    echo "connect -set \\$name ${list#,}"
  done <<EOF
soc.cpu.exwb_memSize 3
soc.cpu.muldiv_inst.st 6
soc.qspi.state 7
EOF
}

# --------------------------------------------------------------- lemma ------
stage_lemma() {
  mkdir -p "$B/lemma"; local L="$B/lemma"
  [ -f "$B/consts.cand" ] || die "no consts.cand: run the read stage first"
  [ "$(wc -l < "$B/consts.cand")" = 184 ] || die "consts.cand has $(wc -l < "$B/consts.cand") entries, not 184"
  # the design, flat, with the wires the lemma reads brought out as ports
  local regs; regs=$(sed 's/\[[0-9]*\]$//' "$B/consts.cand" | sort -u)
  {
    for f in $SRCS; do
      [ "$f" = rf_top.v ] && echo "read_verilog -sv $HERE/rf_top_free.v" || echo "read_verilog -sv $ROOT/src/$f"
    done
    cat <<EOF
hierarchy -top $TOP
proc -norom
flatten
opt_clean
setundef -undriven -zero
setattr -unset init
opt_clean
expose$(for r in $regs $FSMS soc.rst_soc soc.cpu.imem_addr soc.cpu.ifex_pc; do echo -n " w:$r"; done)
write_rtlil $L/exposed.il
EOF
  } > "$L/expose.ys"
  yos lemma/expose.log lemma/expose.ys || die "lemma: expose failed (see $L/expose.log)"
  # reset values: a one-edge reset from the all-zero state, read off a solver trace
  {
    cat <<EOF
read_rtlil $L/exposed.il
hierarchy -top $TOP
async2sync
opt_clean
sat -seq 3 -set-init-zero -set-at 1 rst_n 0 -set-def-inputs$(for r in $regs; do echo -n " -show $r"; done)
EOF
  } > "$L/reset.ys"
  yos lemma/reset.log lemma/reset.ys || die "lemma: reset trace failed (see $L/reset.log)"
  python3 "$HERE/lemma_gen.py" "$B/consts.cand" "$L/reset.log" "$L" > "$L/gen.txt" || die "lemma_gen.py failed: $(cat "$L/gen.txt")"
  cat "$L/gen.txt"
  # the proof
  cat > "$L/prove.ys" <<EOF
read_rtlil $L/exposed.il
read_verilog -sv -formal -I$L $HERE/lemma_props.sv
hierarchy -top lemma_props
proc
async2sync
flatten
opt -fast
chformal -lower
opt -fast
sat -tempinduct -tempinduct-def -prove-asserts -set-assumes -set-init-zero -set-def-inputs -seq 1 -maxsteps ${LEMMA_STEPS:-12} -show-public
EOF
  local t0=$SECONDS
  yos lemma/prove.log lemma/prove.ys
  local dt=$((SECONDS - t0))
  local len; len=$(grep -oE "Trying induction with length [0-9]+" "$L/prove.log" | tail -1 | grep -oE "[0-9]+$")
  if grep -q "Induction step proven: SUCCESS" "$L/prove.log"; then
    cp "$L/consts.txt" "$B/consts.txt"
    {
      echo "PROVED k-induction length ${len:-?}, ${dt}s: all 184 constant bits equal their reset value once reset (L1)"
      echo "PROVED the same run: exwb_memSize != 3, muldiv st not 6 or 7, qspi state != 7 once reset (L2)"
      echo
      echo "bit  value  (consts.txt)"
      sed 's/^/PROVED /' "$L/consts.txt"
    } > "$L/lemma.txt"
    say "lemma: PROVED 184 constant bits and the 3 FSM invariants (k=${len:-?}, ${dt}s)"
    return 0
  fi
  local why="no verdict"
  grep -q "model found for base case" "$L/prove.log" && why="counterexample from reset"
  grep -q "Reached maximum" "$L/prove.log" && why="induction did not close by length ${LEMMA_STEPS:-12}"
  echo "FAILED ($why); see $L/prove.log" > "$L/lemma.txt"
  grep -E "failed|Reached maximum|ERROR" "$L/prove.log" | head -20 >> "$L/lemma.txt"
  say "lemma: FAILED ($why)"
  echo "EQY LEMMA FAILED ($why)"
  return 1
}

# --------------------------------------------------------------- prove ------
# gold_final.ys: the pre-tie gold, the proved constants tied, nets split.
write_gold_final() {       # $1 = dir, $2 = consts file
  local D="$1" C="$2"
  {
    echo "read_rtlil $B/read/gold_pre.il"
    echo -n "select -set notfsm *"; for f in $FSMS; do echo -n " w:$f"; done; echo " %u %u %d"   # 3 FSM wires: 2 unions, then subtract
    echo "splitnets -ports -format [] @notfsm"
    # The constant bits are cut from their flops (the flop keeps no fan-out)
    # and driven by the proved constant; bit-level wires exist after splitnets.
    awk '{ b=$1; gsub(/\[/,"\\[",b); gsub(/\]/,"\\]",b); if ($2=="0") z=z " w:" b; else o=o " w:" b; all=all " w:" b }
         END { print "cutpoint -undef -noscopeinfo" all;
               if (z != "") { print "select -set tie0" z; print "setundef -zero @tie0" }
               if (o != "") { print "select -set tie1" o; print "setundef -one @tie1" } }' "$C"
    echo "opt_clean"
  } > "$D/gold_final.ys"
}

fsm_init() {               # the FSM flops start in the reset state (gold 0; gate: one-hot of state 0)
  if [ "$1" = gold ]; then
    echo "setattr -set init 2'b00 w:soc.cpu.exwb_memSize"
    echo "setattr -set init 3'b000 w:soc.cpu.muldiv_inst.st"
    echo "setattr -set init 3'b000 w:soc.qspi.state"
  else
    echo "setattr -set init 3'b001 w:soc.cpu.exwb_memSize"
    echo "setattr -set init 6'b000001 w:soc.cpu.muldiv_inst.st"
    echo "setattr -set init 7'b0000001 w:soc.qspi.state"
  fi
}

write_eqy() {              # $1 = dir, $2 = gold script, $3 = gate script, $4 = match rules
  sed -e "s|@GOLD@|$2|" -e "s|@GATE@|$3|" -e "/@MATCHRULES@/{r $4" -e "d}" "$HERE/soc.eqy.in" > "$1/soc.eqy"
}

gate_final() {             # gate script for EQY: as gate_pre, no json
  gate_script
}

run_eqy() {                # $1 = dir: setup, match report, then all partitions
  local D="$1"
  if [ ! -d "$D/eqy" ]; then
    ( cd "$D" && dk eqy -f -m -d eqy soc.eqy ) > "$D/setup.log" 2>&1
    echo $? > "$D/setup.rc"
  fi
  python3 "$HERE/matchreport.py" "$B/read/gold.json" "$B/read/gate.json" "$D/eqy" "$B/consts.txt" "$D/match.txt" > /dev/null
  say "prove: $(tail -1 "$D/match.txt") ($(grep -c . "$D/eqy/partition.list" 2>/dev/null) partitions)"
  ( cd "$D" && dk eqy -k -c -j "$JOBS" -d eqy soc.eqy ) > "$D/eqy.log" 2>&1
  echo $? > "$D/eqy.rc"
}

eqy_verdict() {            # $1 = dir: prints the last line from the strategies' status files
  local D="$1"
  python3 "$HERE/verdict.py" "$D/eqy" "$D/verdict.txt"
}

stage_prove() {
  [ -f "$B/consts.txt" ] || die "no consts.txt: the lemma stage has not PROVED"
  mkdir -p "$B/prove"; local P="$B/prove"
  write_gold_final "$P" "$B/consts.txt"
  gate_final > "$P/gate_final.ys"
  local side
  for side in gold gate; do
    { cat "$P/${side}_final.ys"; echo "write_json $P/${side}_final.json"; } > "$P/${side}_json.ys"
    yos prove/${side}_json.log prove/${side}_json.ys || die "prove: ${side} json failed"
  done
  python3 "$HERE/matchrules.py" "$P/gold_final.json" "$P/gate_final.json" "$P/match.rules" "$P/match.rules.report" || die "matchrules.py failed"
  # one public name per matched net (matchrules.py), then what EQY reads
  { cat "$P/gold_final.ys"; cat "$P/match.rules.gold_hide"; echo "opt_clean"; fsm_init gold; } > "$P/gold_eqy.ys"
  { cat "$P/gate_final.ys"; cat "$P/match.rules.gate_hide"; echo "opt_clean"; fsm_init gate; } > "$P/gate_eqy.ys"
  write_eqy "$P" "$P/gold_eqy.ys" "$P/gate_eqy.ys" "$P/match.rules"
  local t0=$SECONDS
  run_eqy "$P"
  say "prove: eqy finished in $((SECONDS - t0))s"
  eqy_verdict "$P"
  local rc=$?
  cat "$P/verdict.txt"
  return $rc
}

# ------------------------------------------------------------- mutants ------
# $1 name, $2 = gate script path, $3 = consts file, $4 = flop whose partition
# must FAIL. Setup is redone; only the partitions holding $4 are run.
mutant_run() {
  local name="$1" gate="$2" consts="$3" flop="$4"
  local M="$B/mutants/$name"; rm -rf "$M"; mkdir -p "$M"
  write_gold_final "$M" "$consts"
  write_eqy "$M" "$M/gold_final.ys" "$gate" "$B/prove/match.rules"
  ( cd "$M" && dk eqy -f -m -d eqy soc.eqy ) > "$M/setup.log" 2>&1
  python3 "$HERE/verdict.py" --partitions-of "$flop" "$M/eqy" > "$M/partitions.txt"
  local parts; parts=$(cat "$M/partitions.txt")
  [ -n "$parts" ] || { echo "no partition holds $flop" > "$M/result.txt"; return 2; }
  local p targets=""
  for p in $parts; do targets="$targets strategies/$p/pdr/status"; done
  ( cd "$M/eqy" && dk make -k -f strategies.mk $targets ) > "$M/run.log" 2>&1
  python3 "$HERE/verdict.py" --only "$parts" "$M/eqy" "$M/result.txt"
}

stage_mutants() {
  [ -f "$B/consts.txt" ] || die "no consts.txt: the lemma stage has not PROVED"
  mkdir -p "$B/mutants"; local X="$B/mutants"; local bad=""
  local k flop
  for k in core syscon; do
    python3 "$HERE/mutate_netlist.py" "$NETLIST" "$X/$k.nl.v" --kind $k --lib "$LIB" > "$X/$k.mutation.txt" || die "mutate_netlist.py $k failed"
    cat "$X/$k.mutation.txt"
    flop=$(sed -n 's/^flop \(.*\)$/\1/p' "$X/$k.mutation.txt")
    # gate script on the mutated netlist
    NETLIST="$X/$k.nl.v" gate_final > "$X/$k.gate.ys"
    mutant_run "$k" "$X/$k.gate.ys" "$B/consts.txt" "$flop"
    say "mutants: $k mutant: $(tail -1 "$X/$k/result.txt")"
    grep -q "^EQY FAIL" "$X/$k/result.txt" || bad="$bad $k"
  done
  # untie one constant: the first bit of misa_reg that is 1 (the A extension)
  local ut; ut=$(awk '$1 ~ /^soc.cpu.csr_unit.misa_reg\[/ && $2 == 1 { print $1; exit }' "$B/consts.txt")
  grep -v -F -x -e "$ut 1" "$B/consts.txt" > "$X/consts_untied.txt"
  echo "untied $ut (from $(wc -l < "$B/consts.txt") to $(wc -l < "$X/consts_untied.txt") ties)" | tee "$X/untie.txt"
  gate_final > "$X/untie.gate.ys"
  mutant_run untie "$X/untie.gate.ys" "$X/consts_untied.txt" "$ut"
  say "mutants: untied-constant mutant: $(tail -1 "$X/untie/result.txt")"
  grep -q "^EQY FAIL" "$X/untie/result.txt" || bad="$bad untie"
  if [ -n "$bad" ]; then echo "EQY VACUOUS$bad" > "$X/summary.txt"; return 3; fi
  echo "mutants: all three FAIL as required" > "$X/summary.txt"
  return 0
}

# ---------------------------------------------------------------- main ------
run_stage() {              # name; skips if stamped; stops the run on failure
  local s="$1"
  if [ -f "$B/$s.done" ]; then say "$s: skipped (stamp present)"; return 0; fi
  say "$s: start"
  local t0=$SECONDS
  "stage_$s"; local rc=$?
  if [ $rc = 0 ]; then
    touch "$B/$s.done"; say "$s: done in $((SECONDS - t0))s"
  else
    say "$s: FAILED rc=$rc after $((SECONDS - t0))s"
  fi
  return $rc
}

stages="read lemma prove mutants"; [ -n "$STAGE" ] && stages="$STAGE"
final=""
for s in $stages; do
  case "$s" in read|lemma|prove|mutants) ;; *) die "unknown stage $s";; esac
  run_stage "$s"; rc=$?
  if [ "$s" = prove ]; then
    final=$(tail -1 "$B/prove/verdict.txt" 2>/dev/null)
    # a FAIL or UNPROVEN prove still lets the mutants (which need no pass) run
    [ $rc = 0 ] || { touch "$B/prove.done"; prove_rc=$rc; }
    rc=0
  fi
  if [ $rc != 0 ]; then
    [ "$s" = mutants ] && { tail -1 "$B/mutants/summary.txt"; exit 3; }
    exit $rc
  fi
done
if [ "$STAGE" = "" ] || [ "$STAGE" = prove ]; then
  echo "$final"
  case "$final" in "EQY PASS") exit 0;; "EQY FAIL"*) exit 1;; *) exit 2;; esac
fi
echo "EQY STAGE $STAGE OK"
