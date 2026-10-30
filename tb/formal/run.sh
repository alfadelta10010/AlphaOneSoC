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
# core_fetch (fetch word reuse, core_fetch_props.sv) reads fyracore.v with
# observation ports added by sed, since the tools read no hierarchical names.
# Mode struct (soc_rst_sync) is not a SAT proof: the SoC is flattened and the
# fan-out cone of rst_soc is walked through buffers and logic but not through
# flops, $mem* cells or latches, which end the walk; it is FAILED if the cone
# reaches the reset, set or load port of an asynchronous flop or latch ($adff,
# $adffe, $aldff, $aldffe, $dffsr, $dffsre, $adlatch, $dlatchsr, $sr), PROVED
# (structural) otherwise. rst_soc is meant as a synchronous reset only.
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
SOC="alphaone_soc.v syscon.v alu.v branchCtrl.v clint.v compressed_decoder.v controller.v csr.v decoder.v fyracore.v gpio.v spi.v mem_ctrl.v muldiv.v pmp.v qspi_ctrl.v regFile.v regs.v signExt.v soc_bus.v uart.v"
CORE="alu.v branchCtrl.v compressed_decoder.v controller.v csr.v decoder.v fyracore.v muldiv.v pmp.v regFile.v signExt.v"
declare -A FILES=( [csr]="csr.v" [core_hold]="$CORE" [core_req]="$CORE" [core_fetch]="$CORE" [syscon_comb]="syscon.v" [syscon_gate]="syscon.v" [soc_rst_sync]="$SOC"
                   [spi_core]="spi.v" [spi_dc]="spi.v" )
declare -A EXTRA=( [core_hold]="rf_top_stub.v" [core_req]="rf_top_stub.v" [core_fetch]="rf_top_stub.v" [soc_rst_sync]="rf_top_stub.v" )   # read from $HERE
declare -A PASSES=( [core_hold]="memory_map; setundef -undriven -expose;" [core_req]="memory_map; setundef -undriven -expose;" [core_fetch]="memory_map; setundef -undriven -expose;" )
declare -A MODE=( [csr]=induct [core_hold]=induct [core_req]=bmc [core_fetch]=induct [syscon_comb]=bmc [syscon_gate]=induct [soc_rst_sync]=struct
                  [spi_core]=induct [spi_dc]=induct )
declare -A BDEPTH=( [syscon_comb]=24 )     # per-harness bmc depth; default $BMC_DEPTH
# spi_*: only induction length 1 counts as PROVED (WO-29 7.1); a harness that
# needs more reports FAILED and gets a strengthening invariant instead.
declare -A IDEPTH=( [spi_core]=1 [spi_dc]=1 )
# spi_*: white-box access with `expose` (a hierarchical reference such as
# dut.x would become an undriven wire, and `bind` does nothing: both are
# forbidden). PRE runs after the RTL is read and before the harness is.
SPI_EXPOSE="w:st w:sr w:bb w:bba w:cc w:bc w:cpol w:cpha w:baud"
declare -A PRE=( [spi_core]="hierarchy -top spi; proc; expose $SPI_EXPOSE" [spi_dc]="hierarchy -top spi; proc; expose $SPI_EXPOSE" )
names=("$@"); [ ${#names[@]} = 0 ] && names=(csr core_hold core_req core_fetch syscon_comb syscon_gate soc_rst_sync spi_core spi_dc)
bad=0
err=0
for n in "${names[@]}"; do
  srcs=""; for f in ${FILES[$n]}; do srcs="$srcs $SRC/$f"; done
  if [ "$n" = core_fetch ]; then
    # fyracore.v with the f_* observation ports (see core_fetch_props.sv)
    inst="$OUT/formal_core_fetch_fyracore.v"
    sed -e 's/^\( *\)output wire        dbg_trap$/\1output wire        dbg_trap,\n\1output wire [31:0] f_pc, f_fetched,\n\1output wire [15:0] f_kbuf,\n\1output wire        f_kv, f_exec, f_load/' \
        -e 's/^endmodule$/    assign f_pc = pc; assign f_fetched = if_fetched; assign f_kbuf = if_kbuf;\n    assign f_kv = if_kv; assign f_exec = if_exec;\n    assign f_load = !rst \&\& !stall \&\& !(flush || ex_nofetch);\nendmodule/' \
        "$SRC/fyracore.v" > "$inst"
    grep -q "f_load" "$inst" && grep -q "assign f_pc" "$inst" || { echo "ERROR $n: could not instrument fyracore.v"; err=1; continue; }
    srcs="${srcs/$SRC\/fyracore.v/$inst}"
  fi
  for f in ${EXTRA[$n]:-}; do srcs="$srcs $HERE/$f"; done
  log="$OUT/formal_${n}.log"
  if [ "${MODE[$n]}" = struct ]; then
    json="$OUT/formal_${n}.json"
    rm -f "$json"
    timeout 1800 yosys -p "read_verilog -sv $srcs; prep -top alphaone_soc; flatten; opt_clean; write_json $json" > "$log" 2>&1
    if [ ! -s "$json" ]; then echo "ERROR $n: yosys gave no netlist (log: $log)"; err=1; continue; fi
    out=$(python3 - "$json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
top = d["modules"]["alphaone_soc"]
seed = {b for b in top["netnames"]["rst_soc"]["bits"] if isinstance(b, int)}
ASYNC = {"$adff", "$adffe", "$aldff", "$aldffe", "$dffsr", "$dffsre", "$adlatch", "$dlatchsr", "$sr"}
RST_PORTS = {"ARST", "SET", "CLR", "ALOAD", "AD"}
SEQ = ("$dff", "$sdff", "$adff", "$aldff", "$dffsr", "$mem", "$ff", "$dlatch", "$adlatch", "$dlatchsr", "$sr")
seen, work, hits = set(seed), list(seed), []
while work:
    b = work.pop()
    for name, c in top["cells"].items():
        for port, bits in c["connections"].items():
            if b not in bits or c["port_directions"].get(port) != "input":
                continue
            if c["type"] in ASYNC and port in RST_PORTS:
                hits.append("%s (%s) port %s" % (name, c["type"], port))
            if c["type"].startswith(SEQ):
                continue                      # the cone stops at a flop
            for oport, obits in c["connections"].items():
                if c["port_directions"].get(oport) == "output":
                    for ob in obits:
                        if isinstance(ob, int) and ob not in seen:
                            seen.add(ob); work.append(ob)
if hits:
    print("HIT " + "; ".join(sorted(set(hits))))
else:
    print("CLEAN %d nets" % len(seen))
PYEOF
)
    case "$out" in
      CLEAN*) echo "PROVED $n (structural)";;
      HIT*)   echo "FAILED $n: ${out#HIT } (log: $log)"; bad=1;;
      *)      echo "ERROR $n: no verdict (log: $log)"; err=1;;
    esac
    continue
  fi
  bd="${BDEPTH[$n]:-$BMC_DEPTH}"
  if [ "${MODE[$n]}" = bmc ]; then
    sat="sat -prove-asserts -set-assumes -set-init-zero -set-def-inputs -seq $bd"
  else
    sat="sat -tempinduct -tempinduct-def -prove-asserts -set-assumes -set-init-zero -set-def-inputs -seq 1 -maxsteps ${IDEPTH[$n]:-$DEPTH}"
  fi
  if [ -n "${PRE[$n]:-}" ]; then rd="read_verilog -sv -formal $srcs; ${PRE[$n]}; read_verilog -sv -formal $HERE/${n}_props.sv"
  else rd="read_verilog -sv -formal $srcs $HERE/${n}_props.sv"; fi
  timeout 1800 yosys -p "$rd; prep -top ${n}_props; \
               chformal -lower; flatten; ${PASSES[$n]:-} opt -fast; $sat" > "$log" 2>&1
  case "$n" in spi_*)
    if grep -qE "is implicitly declared|is used but has no driver" "$log"; then
      echo "ERROR $n: an undriven or implicitly declared wire (hierarchical reference?) (log: $log)"; err=1; continue
    fi;;
  esac
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
    echo "FAILED $n: induction did not close by length ${IDEPTH[$n]:-$DEPTH} (log: $log)"
    grep -E "failed|Reached maximum" "$log" | tail -3; bad=1
  else
    echo "ERROR $n: no verdict (log: $log)"; err=1
  fi
done
[ $err = 1 ] && exit 2
exit $bad
