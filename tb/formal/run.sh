#!/bin/bash
# Prove the invariants in tb/formal/*_props.sv with yosys's built-in SAT
# solver (no sby or external SMT solver needed): k-induction. The base case
# starts from all-zero state; every assert is gated on the harness's `armed`
# flag, which only a reset sets, so the start state is irrelevant to it. The
# induction step starts from any state.
#   tb/formal/run.sh            every harness
#   tb/formal/run.sh csr        one (csr_props.sv)
# Modes: induct (k-induction, PROVED) or bmc (bounded from reset, BOUNDED;
# core_req is not inductive without internal invariants). The core harnesses
# read tb/formal/rf_top_stub.v instead of src/rf_top.v (free read data).
# Prints PROVED, BOUNDED or FAILED per harness; exits 1 if any failed. FAILED
# means yosys finished with a counterexample (or, for induct, hit the depth
# limit); a yosys error or timeout gives no verdict and prints ERROR instead:
# exit 2, which tb/mutate/run.py scores as ERROR, never as a kill.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
SRC="${FYRA_SRC:-$ROOT/src}"
DEPTH="${DEPTH:-12}"
OUT="${OUT_DIR:-$ROOT/build}"
mkdir -p "$OUT"
BMC_DEPTH="${BMC_DEPTH:-10}"
CORE="alu.v branchCtrl.v compressed_decoder.v controller.v csr.v decoder.v fyracore.v muldiv.v pmp.v regFile.v signExt.v"
declare -A FILES=( [csr]="csr.v" [core_hold]="$CORE" [core_req]="$CORE" [syscon_comb]="syscon.v" )
declare -A EXTRA=( [core_hold]="rf_top_stub.v" [core_req]="rf_top_stub.v" )   # read from $HERE
declare -A PASSES=( [core_hold]="memory_map; setundef -undriven -expose;" [core_req]="memory_map; setundef -undriven -expose;" )
declare -A MODE=( [csr]=induct [core_hold]=induct [core_req]=bmc [syscon_comb]=bmc )
declare -A BDEPTH=( [syscon_comb]=24 )     # per-harness bmc depth; default $BMC_DEPTH
names=("$@"); [ ${#names[@]} = 0 ] && names=(csr core_hold core_req syscon_comb)
bad=0
err=0
for n in "${names[@]}"; do
  srcs=""; for f in ${FILES[$n]}; do srcs="$srcs $SRC/$f"; done
  for f in ${EXTRA[$n]:-}; do srcs="$srcs $HERE/$f"; done
  log="$OUT/formal_${n}.log"
  bd="${BDEPTH[$n]:-$BMC_DEPTH}"
  if [ "${MODE[$n]}" = bmc ]; then
    sat="sat -prove-asserts -set-assumes -set-init-zero -set-def-inputs -seq $bd"
  else
    sat="sat -tempinduct -tempinduct-def -prove-asserts -set-assumes -set-init-zero -set-def-inputs -seq 1 -maxsteps $DEPTH"
  fi
  timeout 1800 yosys -p "read_verilog -sv -formal $srcs $HERE/${n}_props.sv; prep -top ${n}_props; \
               chformal -lower; flatten; ${PASSES[$n]:-} opt -fast; $sat" > "$log" 2>&1
  if [ "${MODE[$n]}" = bmc ]; then
    if grep -q "SAT proof finished - no model found: SUCCESS" "$log"; then
      echo "BOUNDED $n (no counterexample within $bd steps of reset)"
    elif grep -q "SAT proof finished - model found: FAIL" "$log"; then
      echo "FAILED $n: counterexample within $bd steps (log: $log)"
      grep -E "failed|ERROR" "$log" | tail -3; bad=1
    else
      echo "ERROR $n: no verdict (log: $log)"; err=1
    fi
    continue
  fi
  len=$(grep -oE "Trying induction with length [0-9]+" "$log" | tail -1 | grep -oE "[0-9]+$")
  if grep -q "Induction step proven: SUCCESS" "$log"; then
    echo "PROVED $n (k-induction, length ${len:-?})"
  elif grep -q "model found for base case" "$log"; then
    echo "FAILED $n: a counterexample from reset (log: $log)"
    grep -E "failed|ERROR" "$log" | tail -3; bad=1
  elif grep -q "Reached maximum" "$log"; then
    echo "FAILED $n: induction did not close by length $DEPTH (log: $log)"
    grep -E "failed|Reached maximum" "$log" | tail -3; bad=1
  else
    echo "ERROR $n: no verdict (log: $log)"; err=1
  fi
done
[ $err = 1 ] && exit 2
exit $bad
