#!/bin/bash
# Equivalence of the branch RTL (gold) and the hardened post-PnR netlist
# (gate): every flop's next-state function and every output, by EQY (WO-24).
# Runs on the sandbox, inside the librelane container (eqy/sby/yosys 0.62).
#
#   tb/eqy/run.sh NETLIST=<nl.v> [PDK_ROOT=<dir>] [JOBS=4] [STAGE="read lemma fsminv prove mutants"]
#
# Stages, in order; STAGE= runs one, otherwise all. Each writes
# build/eqy/<stage>/ and, once it has succeeded, the stamp build/eqy/<stage>.done
# (a stage with a stamp is skipped, so a run can be relaunched after a reboot;
# delete the stamp, or build/eqy, to redo one). build/eqy/STATUS has a
# timestamped line per stage.
#
#   read     md5 of the netlist and the Liberty file; gold and gate read; the
#            flop accounting (accounting.py) against the work order's table
#   lemma    on the RTL: the 186 removed bits (184 CSR + gpio out_r[1], [3]) are constant after reset and
#            the recoded FSMs never hold an unlisted code (lemma_props.sv,
#            yosys sat -tempinduct); writes consts.txt, the ties of the gold
#   fsminv   on the netlist: the four one-hot FSMs always hold exactly one set bit
#            (fsm_inv_props.sv, sat -tempinduct), with a negative control (NEG must FAIL)
#   prove    EQY on gold (ties applied) against gate: strategy sat for every
#            partition, then sby abc pdr for those sat leaves open
#   mutants  seven runs that must FAIL: four mutated netlists (mutate_netlist.py,
#            a gate changed in the D cone of one flop; core, syscon, spi, kbuf), the five
#            tie1 bits tied to 1'0 (fliptie), and two wrong FSM tables (fsmtable: qspi,
#            fsmtable_spi). Setup is redone for each, but only the partitions that hold the
#            changed flop are run. Caught = a real counterexample: a sat FAIL, or a pdr FAIL
#            (from init) on a partition sat left open; a "vacuous base" sat pass is rerun
#            with sat noapplied and pdr 600 s, and a pdr that does not FAIL is NOT caught.
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
NL_MD5=71d75961e9e64b995d551afdec157aff
# The version of the PDK the harden used (not what $PDK_ROOT/sky130A points to).
LIB="$PDK_ROOT/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
TOP=tt_um_alfadelta10010_alphaone_soc
# The harden's sources, in resolved.json's order.
SRCS="tt_um_alfadelta10010_alphaone_soc.v alphaone_soc.v fyracore.v alu.v branchCtrl.v clint.v compressed_decoder.v controller.v csr.v decoder.v muldiv.v pmp.v regFile.v rf_top.v signExt.v qspi_ctrl.v mem_ctrl.v soc_bus.v uart.v gpio.v spi.v syscon.v"
# FSM registers that synthesis recoded one-hot (kept as buses in gold and gate).
FSMS="soc.cpu.exwb_memSize soc.cpu.muldiv_inst.st soc.qspi.state soc.gpio_inst.spi_inst.st"
B="$ROOT/build/eqy"
# The tools run in the container, in the caller's directory. NATIVE=1 runs
# them from PATH instead (inside a container already; that container needs sed,
# which the librelane image lacks). DK_OPTS adds docker run options to every
# container, e.g. DK_OPTS=--cpus=1.5 to cap the CPU.
dk() {
  if [ "${NATIVE:-0}" = 1 ]; then "$@"; return; fi
  # The container has no make, which eqy needs: the host's GNU make runs
  # through the host's own libc (mounted read-only), via the wrapper below.
  docker run --rm ${DK_OPTS:-} -u "$(id -u):$(id -g)" -v /home/mempool:/home/mempool \
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
  local HC=/home/mempool/tt/projects/fin-3x4
  if [ -d $HC/src ]; then      # the harden's own copy: compared without comments; a functional difference dies
    local a b
    for f in $SRCS; do
      a=$(strip_comments "$ROOT/src/$f" | md5sum); b=$(strip_comments "$HC/src/$f" | md5sum)
      if [ "$(md5sum < "$ROOT/src/$f")" = "$(md5sum < "$HC/src/$f" 2>/dev/null)" ]; then :
      elif [ "$a" = "$b" ]; then echo "NOTE: src/$f differs from the harden's copy in comments only" >> "$R/inputs.txt"
      else echo "FUNCTIONAL: src/$f differs from the harden's copy" >> "$R/inputs.txt"; die "src/$f differs functionally from the harden's copy"; fi
    done
  fi
  if [ -f $HC/runs/wokwi/resolved.json ]; then    # SRCS = the harden's VERILOG_FILES, in order
    local rj; rj=$(python3 -c 'import json,sys,os;d=json.load(open(sys.argv[1]));print(" ".join(os.path.basename(x) for x in d["VERILOG_FILES"]))' $HC/runs/wokwi/resolved.json)
    if [ "$rj" = "$SRCS" ]; then echo "srcs     = resolved.json VERILOG_FILES (same set and order)" >> "$R/inputs.txt"
    else echo "srcs     DIFFER from resolved.json: $rj" >> "$R/inputs.txt"; die "SRCS differ from resolved.json"; fi
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
  gate_script buses > "$R/gate_pre.ys"
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

strip_comments() {        # Verilog without // and /* */ comments and blank space, for the compare with the harden's copy
  python3 -c 'import re,sys;s=open(sys.argv[1]).read();s=re.sub(r"/\*.*?\*/","",s,flags=re.S);s=re.sub(r"//[^\n]*","",s);print(" ".join(s.split()))' "$1"
}

gate_script() {            # netlist to flat gate; $1 = buses: FSM registers as buses (read and fsminv stages only)
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
  [ "${1:-}" = buses ] && gate_fsm_buses
  return 0
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
soc.qspi.state 10
soc.gpio_inst.spi_inst.st 3
EOF
}

# --------------------------------------------------------------- lemma ------
stage_lemma() {
  mkdir -p "$B/lemma"; local L="$B/lemma"
  [ -f "$B/consts.cand" ] || die "no consts.cand: run the read stage first"
  [ "$(wc -l < "$B/consts.cand")" = 186 ] || die "consts.cand has $(wc -l < "$B/consts.cand") entries, not 186"
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
      echo "PROVED k-induction length ${len:-?}, ${dt}s: all 186 constant bits (184 CSR + gpio out_r[1], [3]) equal their reset value once reset (L1)"
      [ "${len:-1}" -gt 1 ] && echo "NOTE: induction length ${len} > 1: the step is from any state; the base case covers only the zero power-up of the no-reset flops (if_kbuf, spi cc/bc), which EQY starts free on both sides"
      echo "PROVED the same run: exwb_memSize != 3, muldiv st not 6 or 7, qspi state > 9, spi st != 3 once reset (L2, 4 FSMs)"
      echo
      echo "bit  value  (consts.txt)"
      sed 's/^/PROVED /' "$L/consts.txt"
    } > "$L/lemma.txt"
    say "lemma: PROVED 186 constant bits and the 4 FSM invariants (k=${len:-?}, ${dt}s)"
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
    echo -n "select -set notfsm *"; for f in $FSMS; do echo -n " w:$f"; done; echo " %u %u %u %d"   # 4 FSM wires: 3 unions, then subtract
    echo "splitnets -ports -format [] @notfsm"
    # The constant bits are cut from their flops (the flop keeps no fan-out)
    # and driven by the proved constant; bit-level wires exist after splitnets.
    # tie1 first: one cutpoint over all bits let the first setundef zero them all (q1).
    awk '{ b=$1; gsub(/\[/,"\\[",b); gsub(/\]/,"\\]",b); if ($2=="0") z=z " w:" b; else o=o " w:" b }
         END { if (o != "") { print "select -set tie1" o; print "cutpoint -undef -noscopeinfo @tie1"; print "setundef -one" }
               if (z != "") { print "select -set tie0" z; print "cutpoint -undef -noscopeinfo @tie0"; print "setundef -zero" } }' "$C"
    echo "opt_clean"
  } > "$D/gold_final.ys"
}

fsm_init_gate() {          # the netlist's FSM buses start at the one-hot image of state 0 (fsminv base case)
  echo "setattr -set init 3'b001 w:soc.cpu.exwb_memSize"
  echo "setattr -set init 6'b000001 w:soc.cpu.muldiv_inst.st"
  echo "setattr -set init 10'b0000000001 w:soc.qspi.state"
  echo "setattr -set init 3'b001 w:soc.gpio_inst.spi_inst.st"
}

# ---- FSM cut point (fsmcut.py, fsmcut.v): see WO-24's 2026-10-28 amendment ----
# cut_design SIDE IN.ys DIR VFILE: run IN.ys, write_rtlil, patch the RTLIL (fsmcut.py; dies if an
# assert fails), and write DIR/SIDE_cut.ys, the script that reads the patched design.
cut_design() {
  local side="$1" in="$2" D="$3" vf="$4" nq npin wq
  { cat "$in"; echo "write_rtlil $D/${side}_pre.il"; } > "$D/${side}_pre.ys"
  yos "$D/${side}_pre.log" "$D/${side}_pre.ys" || die "cut: $side read failed (see $D/${side}_pre.log)"
  python3 "$HERE/fsmcut.py" "$side" "$D/${side}_pre.il" "$D/${side}_cut.il" > "$D/$side.patch.txt" 2>&1 \
    || die "fsmcut.py $side asserted: $(tail -3 "$D/$side.patch.txt" | tr '\n' ' ')"
  nq=$(grep -c "^$side: connect .Q " "$D/$side.patch.txt"); npin=$(grep -c "^$side: rf_macro w_ena" "$D/$side.patch.txt")
  wq=4; [ "$side" = gate ] && wq=22
  [ "$nq" = "$wq" ] && [ "$npin" = 1 ] || die "cut: $side patch has $nq Q edits (want $wq) and $npin pin edits (want 1)"
  cat > "$D/${side}_cut.ys" <<EOF
read_rtlil $D/${side}_cut.il
read_verilog -sv $vf
hierarchy -top $TOP
flatten
hierarchy -top $TOP
rename -hide w:fsmcutI_* c:fsmcutI_*
opt_clean
EOF
}

cut_scripts() {            # $1 = dir, $2 = match rules prefix: SIDE_eqy.ys = cut + hides + asserts
  local D="$1" R="$2"
  { cat "$D/gold_cut.ys"; cat "$R.gold_hide"; echo "opt_clean"
    echo "select -assert-count 4 w:soc.cpu.fsmcut_exwb_memSize w:soc.cpu.muldiv_inst.fsmcut_st w:soc.qspi.fsmcut_state w:soc.gpio_inst.spi_inst.fsmcut_st %u %u %u"; } > "$D/gold_eqy.ys"
  { cat "$D/gate_cut.ys"; cat "$R.gate_hide"; echo "opt_clean"
    echo "select -assert-count 8 w:soc.cpu.exwb_memSize__oh w:soc.cpu.muldiv_inst.st__oh w:soc.qspi.state__oh w:soc.gpio_inst.spi_inst.st__oh w:soc.cpu.fsmcut_exwb_memSize w:soc.cpu.muldiv_inst.fsmcut_st w:soc.qspi.fsmcut_state w:soc.gpio_inst.spi_inst.fsmcut_st %u %u %u %u %u %u %u"; } > "$D/gate_eqy.ys"
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
  [ "$D" = "$B/prove" ] && check_ties "$D/eqy"
  python3 "$HERE/matchreport.py" "$B/read/gold.json" "$B/read/gate.json" "$D/eqy" "$B/consts.txt" "$D/match.txt" > /dev/null
  say "prove: $(tail -1 "$D/match.txt") ($(grep -c . "$D/eqy/partition.list" 2>/dev/null) partitions)"
  # no sat timeout exists in EQY 0.62: a hard partition would hang; after 3 h the rest is UNKNOWN
  ( cd "$D" && dk timeout -k 120 3h eqy -k -c -j "$JOBS" -d eqy soc.eqy ) > "$D/eqy.log" 2>&1
  echo $? > "$D/eqy.rc"
}

no_x_consts() {            # the unscoped setundefs of the ties are safe only if gold_pre has no x constant
  local n; n=$(grep -v '^ *#' "$B/read/gold_pre.il" | grep -cE "[0-9]+'[01xzm-]*x")
  say "prove: x constants in read/gold_pre.il: $n"
  [ "$n" = 0 ] || die "read/gold_pre.il holds $n x constants; the unscoped setundef ties are unsafe"
}

check_ties() {             # $1 = eqy dir: gold.il ties the 181 tie0 bits to 1'0 and the 5 tie1 bits to 1'1
  local G="$1/gold.il" bad=0 n0=0 n1=0 name v
  [ -f "$G" ] || die "no $G to check the ties"
  while read -r name v; do
    if grep -qxF "  connect \\$name 1'$v" "$G"; then
      if [ "$v" = 0 ]; then n0=$((n0 + 1)); else n1=$((n1 + 1)); fi
    else bad=$((bad + 1)); echo "tie check: $name not tied to 1'$v" >> "$STATUS"; fi
  done < "$B/consts.txt"
  say "prove: tie check: $n0 tie0 bits at 1'0, $n1 tie1 bits at 1'1, $bad wrong"
  [ "$bad" = 0 ] && [ "$n0" = 181 ] && [ "$n1" = 5 ] || die "tie check failed ($n0/181 tie0, $n1/5 tie1, $bad wrong)"
}

eqy_verdict() {            # $1 = dir: prints the last line from the strategies' status files
  local D="$1"
  local cl=(); [ -f "$HERE/classes.txt" ] && cl=(--classes "$HERE/classes.txt")
  python3 "$HERE/verdict.py" "${cl[@]}" "$D/eqy" "$D/verdict.txt"
}

stage_fsminv() {
  mkdir -p "$B/fsminv"; local F="$B/fsminv"
  { gate_script buses; fsm_init_gate; echo "delete t:rf_top"
    echo "expose w:soc.cpu.exwb_memSize w:soc.cpu.muldiv_inst.st w:soc.qspi.state w:soc.gpio_inst.spi_inst.st"
    echo "write_rtlil $F/gate_exposed.il"; } > "$F/expose.ys"
  yos fsminv/expose.log fsminv/expose.ys || die "fsminv: expose failed (see $F/expose.log)"
  cat > "$F/inv.ys" <<EOF
read_rtlil $F/gate_exposed.il
read_verilog -sv -formal $HERE/fsm_inv_props.sv
hierarchy -top fsm_inv_props
proc
async2sync
flatten
opt -fast
chformal -lower
opt -fast
sat -tempinduct -prove-asserts -set-assumes -maxsteps 4
EOF
  sed -e "s|read_verilog -sv -formal|read_verilog -sv -formal -DNEG|" -e "s|^sat .*|sat -seq 8 -prove-asserts -set-assumes -show-ports|" "$F/inv.ys" > "$F/neg.ys"
  local t0=$SECONDS
  ( cd "$B" && dk timeout 900 yosys -ql fsminv/inv.log fsminv/inv.ys ) > /dev/null 2>&1
  ( cd "$B" && dk timeout 600 yosys -ql fsminv/neg.log fsminv/neg.ys ) > /dev/null 2>&1
  local len; len=$(grep -oE "Trying induction with length [0-9]+" "$F/inv.log" | tail -1 | grep -oE "[0-9]+$")
  if grep -q "Induction step proven: SUCCESS" "$F/inv.log" && grep -q "model found: FAIL" "$F/neg.log"; then
    echo "PROVED induction length ${len:-?}, $((SECONDS - t0))s: each of the 4 FSMs soc.cpu.exwb_memSize (3), muldiv_inst.st (6), qspi.state (10), spi_inst.st (3) of the netlist is one-hot in every state reachable from its one-hot reset code (I_gate); NEG control (the FSMs stay in reset) FAILs as required" > "$F/fsminv.txt"
    say "fsminv: PROVED (k=${len:-?}), NEG FAIL"; return 0
  fi
  echo "FAILED: see $F/inv.log and $F/neg.log" > "$F/fsminv.txt"
  say "fsminv: FAILED (inv: $(grep -cE 'Induction step proven: SUCCESS' "$F/inv.log"), neg: $(grep -cE 'model found: FAIL' "$F/neg.log"))"
  echo "EQY FSMINV FAILED"; return 1
}

stage_prove() {
  [ -f "$B/consts.txt" ] || die "no consts.txt: the lemma stage has not PROVED"
  { [ -f "$B/fsminv/fsminv.txt" ] && grep -q '^PROVED' "$B/fsminv/fsminv.txt"; } || die "no fsminv/fsminv.txt: the fsminv stage has not PROVED"
  mkdir -p "$B/prove"; local P="$B/prove"
  no_x_consts
  write_gold_final "$P" "$B/consts.txt"
  gate_final > "$P/gate_final.ys"
  local side
  cut_design gold "$P/gold_final.ys" "$P" "$HERE/fsmcut.v"
  cut_design gate "$P/gate_final.ys" "$P" "$HERE/fsmcut.v"
  for side in gold gate; do
    { cat "$P/${side}_cut.ys"; echo "write_json $P/${side}_final.json"; } > "$P/${side}_json.ys"
    yos prove/${side}_json.log prove/${side}_json.ys || die "prove: ${side} json failed"
  done
  python3 "$HERE/matchrules.py" "$P/gold_final.json" "$P/gate_final.json" "$P/match.rules" "$P/match.rules.report" || die "matchrules.py failed"
  # one public name per matched net (matchrules.py), then what EQY reads
  cut_scripts "$P" "$P/match.rules"
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
  # the same scripts as the prove stage (cut point, names made private), on the mutated gate
  local vf="${MUT_VFILE:-$HERE/fsmcut.v}"
  cut_design gold "$M/gold_final.ys" "$M" "$vf"
  cut_design gate "$gate" "$M" "$vf"
  cut_scripts "$M" "$B/prove/match.rules"
  write_eqy "$M" "$M/gold_eqy.ys" "$M/gate_eqy.ys" "$B/prove/match.rules"
  ( cd "$M" && dk eqy -f -m -d eqy soc.eqy ) > "$M/setup.log" 2>&1
  : > "$M/partitions.all"                  # $flop may list several flops: the partitions holding any
  local fl; for fl in $flop; do python3 "$HERE/verdict.py" --partitions-of "$fl" "$M/eqy" >> "$M/partitions.all"; done
  tr ' ' '\n' < "$M/partitions.all" | grep . | sort -u > "$M/partitions.txt"
  # a flipped tie leaves no net of that name (the bit is a constant), so the partitions are named
  if [ -n "${PARTS_OVERRIDE:-}" ]; then
    for fl in $PARTS_OVERRIDE; do echo "$TOP.$fl"; done > "$M/partitions.txt"
    for fl in $(cat "$M/partitions.txt"); do grep -qxF "$fl" "$M/eqy/partition.list" || echo "$fl" >> "$M/override_missing.txt"; done   # a name not in the setup is skipped below
  fi
  # only partitions the prove stage PROVED can carry the check (an open one proves nothing);
  # the flop's own partition when it is one of them, else the proved ones holding it
  local parts p2 own pre="$TOP." keep=""
  own="$pre$(echo "$flop" | sed 's/\[\([0-9]*\)\]$/.\1/')"
  for p2 in $(cat "$M/partitions.txt"); do
    grep -q -F -e "$p2:" "$B/prove/verdict.txt" 2>/dev/null && continue    # TIMEOUT/UNKNOWN/FAIL in the prove stage
    keep="$keep $p2"
  done
  parts=$(echo "$keep" | tr ' ' '\n' | grep -x -F -e "$own" || echo "$keep" | tr ' ' '\n' | head -40)
  echo $parts | tr ' ' '\n' > "$M/partitions.txt"
  [ -n "$parts" ] || { echo "no partition holds $flop" > "$M/result.txt"; return 2; }
  local p targets=""
  for p in $parts; do targets="$targets strategies/$p/pdr/status"; done
  ( cd "$M/eqy" && dk make -j2 -k -f strategies.mk $targets ) > "$M/run.log" 2>&1
  # verdict.py's exit status is the verdict (1 FAIL, 2 unproven), not an error of the run
  python3 "$HERE/verdict.py" --only "$parts" "$M/eqy" "$M/result.txt" || true
  [ -s "$M/result.txt" ]
}

# Caught = a real counterexample (coordinator rule 2026-11-07): the mutant's result has a FAIL partition
# (a sat FAIL, or a pdr FAIL on a partition sat left open). A sat pass at induction length > 1 ("vacuous base")
# is not a proof and not a catch: pdr_confirm reruns those partitions with sat noapplied and pdr (600 s).
# A pdr that returns PASS, TIMEOUT or UNKNOWN is NOT caught. mutants/table.txt records each case.
pdr_confirm() {            # $1 = mutant dir: pdr (from init) on the partitions sat left as "vacuous base"
  local M="$1" p vp=""
  for p in $(sed -n 's/^OPEN \([^:]*\): sat induction.*(vacuous base)$/\1/p' "$M/result.txt"); do vp="$vp $p"; done
  [ -n "$vp" ] || return 0
  grep -q '^FAIL ' "$M/result.txt" && return 0       # already caught by a real counterexample
  rm -rf "$M/eqy_pdr"
  awk -v list="$vp" 'BEGIN { n = split(list, a, " ") } { print } /^\[strategy sat\]/ { for (i = 1; i <= n; i++) print "noapply " a[i] }' "$M/soc.eqy" > "$M/soc_pdr.eqy"
  [ -z "${PDR_TIMEOUT:-}" ] || sed -i "s/^timeout 600\$/timeout $PDR_TIMEOUT/" "$M/soc_pdr.eqy"   # the one longer retry
  ( cd "$M" && dk eqy -f -m -d eqy_pdr soc_pdr.eqy ) > "$M/setup_pdr.log" 2>&1
  local targets=""; for p in $vp; do targets="$targets strategies/$p/pdr/status"; done
  ( cd "$M/eqy_pdr" && dk make -j2 -k -f strategies.mk $targets ) > "$M/run_pdr.log" 2>&1
  python3 "$HERE/verdict.py" --only "$vp" "$M/eqy_pdr" "$M/result_pdr.txt" || true
}

mutant_table() {           # $1 = name, $2 = mutant dir: appends partition, strategy, raw result, trace path to mutants/table.txt
  python3 "$HERE/verdict.py" --mutant-table "$1" "$2" >> "$B/mutants/table.txt"
}

# caught: the table has a FAIL row for the mutant
mutant_caught() { grep -q -e "^$1	.*	FAIL	" "$B/mutants/table.txt"; }

mutant_finish() {          # $1 = name; confirm, record, and say whether it was caught
  local k="$1" X="$B/mutants"
  pdr_confirm "$X/$k"
  mutant_table "$k" "$X/$k"
  if mutant_caught "$k"; then say "mutants: $k CAUGHT"; else say "mutants: $k NOT CAUGHT"; notcaught="$notcaught $k"; fi
}

mutant_error() {           # $1 = name, $2 = reason: recorded; the stage goes on with the next mutant
  say "mutants: $1 ERROR $2"; echo "$1 $2" >> "$B/mutants/errors.txt"
}

want() { [ -z "${MUT_ONLY:-}" ] && return 0; case " $MUT_ONLY " in *" $1 "*) return 0;; esac; return 1; }

mutate_flop() {            # $1 name, $2 kind, $3.. candidate flops (the first with a swappable cell in its cone is used)
  local k="$1" kind="$2" X="$B/mutants" fl; shift 2
  for fl in "$@"; do
    if python3 "$HERE/mutate_netlist.py" "$NETLIST" "$X/$k.nl.v" --kind "$kind" --lib "$LIB" $([ -n "$fl" ] && echo --flop "$fl") > "$X/$k.mutation.txt" 2> "$X/$k.mutation.err"; then
      echo "candidate used: ${fl:-default}" >> "$X/$k.mutation.txt"; return 0
    fi
    echo "no swappable cell for ${fl:-default}: $(cat "$X/$k.mutation.err")" >> "$X/$k.skipped.txt"
  done
  return 1
}

stage_mutants() {
  [ -f "$B/consts.txt" ] || die "no consts.txt: the lemma stage has not PROVED"
  mkdir -p "$B/mutants"; local X="$B/mutants"; local notcaught=""
  # MUT_ONLY="a b" runs just those mutants and keeps the table rows of the others
  if [ -z "${MUT_ONLY:-}" ] || [ ! -f "$X/table.txt" ]; then
    : > "$X/table.txt"; : > "$X/errors.txt"
    printf 'mutant\tpartition\tstrategy\traw result\ttrace\n' >> "$X/table.txt"
  fi
  touch "$X/errors.txt"
  local k flop
  for k in core syscon spi kbuf; do
    want $k || continue
    sed -i "/^$k /d" "$X/errors.txt"; sed -i "/^$k	/d" "$X/table.txt"
    # MUT_RESCORE=1: the mutant's EQY run exists; only the pdr confirm and the table are redone
    if [ "${MUT_RESCORE:-}" = 1 ] && [ -s "$X/$k/result.txt" ]; then mutant_finish "$k"; continue; fi
    case $k in
      core)   mutate_flop core core "${MUT_CORE_FLOP:-}" ;;
      syscon) mutate_flop syscon syscon "" ;;
      spi)    mutate_flop spi core 'soc.gpio_inst.spi_inst.cc[5]' 'soc.gpio_inst.spi_inst.bba' 'soc.gpio_inst.spi_inst.cc[0]' 'soc.gpio_inst.spi_inst.bc[0]' 'soc.gpio_inst.spi_inst.sr[3]' ;;
      kbuf)   mutate_flop kbuf core 'soc.cpu.if_kbuf[5]' 'soc.cpu.if_kbuf[6]' 'soc.cpu.if_kbuf[4]' 'soc.cpu.if_kbuf[7]' 'soc.cpu.if_kbuf[3]' ;;
    esac || { mutant_error "$k" "mutate_netlist.py failed for every candidate (see $X/$k.skipped.txt)"; continue; }
    cat "$X/$k.mutation.txt"
    flop=$(sed -n 's/^flop \(.*\)$/\1/p' "$X/$k.mutation.txt")
    NETLIST="$X/$k.nl.v" gate_final > "$X/$k.gate.ys"
    mutant_run "$k" "$X/$k.gate.ys" "$B/consts.txt" "$flop" || { mutant_error "$k" "$(cat "$X/$k/result.txt" 2>/dev/null)"; continue; }
    say "mutants: $k mutant: $(tail -1 "$X/$k/result.txt")"
    mutant_finish "$k"
  done
  if want fliptie; then
    sed -i "/^fliptie	/d" "$X/table.txt"; sed -i "/^fliptie /d" "$X/errors.txt"
    if [ "${MUT_RESCORE:-}" = 1 ] && [ -s "$X/fliptie/result.txt" ]; then mutant_finish fliptie
    else
    # the 5 tie1 bits tied to 1'0 on the gold side (the q1 bug): a wrong tie value must FAIL
    local fb; fb=$(awk '$2 == 1 { printf "%s ", $1 }' "$B/consts.txt")
    awk '$2 == 1 { print $1, 0; next } { print }' "$B/consts.txt" > "$X/consts_flip.txt"
    echo "flipped to 1'0: $fb(consts_flip.txt: $(awk '$2 == 1' "$X/consts_flip.txt" | wc -l) tie1 left)" | tee "$X/fliptie.txt"
    gate_final > "$X/fliptie.gate.ys"
    # the partitions must exist in this setup (a name missing from partition.list would be silently skipped)
    if PARTS_OVERRIDE="soc.bus.d_addr.2 soc.cpu.csr_unit.csr_new.2 soc.cpu.csr_misa_c" mutant_run fliptie "$X/fliptie.gate.ys" "$X/consts_flip.txt" "$fb"; then
      say "mutants: flipped-tie mutant: $(tail -1 "$X/fliptie/result.txt")"
      mutant_finish fliptie
    else mutant_error fliptie "$(cat "$X/fliptie/result.txt" 2>/dev/null)"; fi
    fi
  fi
  local tag vfile
  for tag in qspi spi; do
    k=fsmtable; [ $tag = qspi ] || k=fsmtable_$tag
    want $k || continue
    sed -i "/^$k	/d" "$X/table.txt"; sed -i "/^$k /d" "$X/errors.txt"
    if [ "${MUT_RESCORE:-}" = 1 ] && [ -s "$X/$k/result.txt" ]; then mutant_finish $k; continue; fi
    # a wrong enc/dec table in fsmcut_gate_<tag> (two codes swapped): the cut partition must FAIL
    vfile=fsmcut_neg.v; [ $tag = qspi ] || vfile=fsmcut_neg_$tag.v
    python3 "$HERE/mk_wrong_table.py" "$HERE/fsmcut.v" "$X/fsmcut_wrong_$tag.v" $tag || { mutant_error $k "could not build the wrong table"; continue; }
    [ "$(diff "$HERE/fsmcut.v" "$X/fsmcut_wrong_$tag.v" | grep -c '^[<>]')" = 4 ] || { mutant_error $k "the wrong table differs in other than 2 lines"; continue; }
    cmp -s "$X/fsmcut_wrong_$tag.v" "$HERE/$vfile" || { mutant_error $k "the wrong table is not $vfile"; continue; }
    echo "wrong table: $tag codes swapped (enc and dec), exactly 2 lines changed, = $vfile" | tee "$X/$k.txt"
    gate_final > "$X/$k.gate.ys"
    local cut=soc.qspi.fsmcut_state; [ $tag = qspi ] || cut=soc.gpio_inst.spi_inst.fsmcut_st
    MUT_VFILE="$X/fsmcut_wrong_$tag.v" PARTS_OVERRIDE="$cut" mutant_run $k "$X/$k.gate.ys" "$B/consts.txt" "$cut" || { mutant_error $k "$(cat "$X/$k/result.txt" 2>/dev/null)"; continue; }
    say "mutants: wrong-table mutant $tag: $(tail -1 "$X/$k/result.txt")"
    mutant_finish $k
  done
  # the verdict covers all 7 mutants, from the table (rows of earlier partial runs are kept)
  local nc="" er="" m
  for m in core syscon spi kbuf fliptie fsmtable fsmtable_spi; do
    if grep -q "^$m " "$X/errors.txt" 2>/dev/null; then er="$er $m"
    elif mutant_caught $m; then :
    else nc="$nc $m"; fi          # no FAIL row, or never run
  done
  : > "$X/summary.txt"
  for m in $er; do echo "ERROR $m: $(grep "^$m " "$X/errors.txt" | head -1 | cut -d' ' -f2-)" >> "$X/summary.txt"; done
  if [ -n "$nc" ]; then echo "EQY VACUOUS$nc" >> "$X/summary.txt"; return 3; fi
  if [ -n "$er" ]; then echo "EQY ERROR$er" >> "$X/summary.txt"; return 2; fi
  echo "mutants: core, syscon, spi, kbuf, fliptie, fsmtable and fsmtable_spi all caught by a real counterexample (see table.txt)" >> "$X/summary.txt"
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

stages="read lemma fsminv prove mutants"; [ -n "$STAGE" ] && stages="$STAGE"
final=""
for s in $stages; do
  case "$s" in read|lemma|fsminv|prove|mutants) ;; *) die "unknown stage $s";; esac
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
