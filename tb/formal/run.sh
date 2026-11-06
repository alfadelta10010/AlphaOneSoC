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
#
# Sidecars: every tb/formal/*.conf (sorted) is sourced after the tables below.
# A sidecar adds harnesses without editing this file: for its own name n it
# sets FILES[n] and MODE[n] (induct, bmc, cover, pdr or struct), optionally
# EXTRA PASSES PRE BDEPTH IDEPTH PROPN DEFS PDR_TIMEOUT GEN [n], and appends
# n to ALL. <PROPN or n>_props.sv must exist in tb/formal. GEN[n] names a bash
# function, called as `fn "$SRC" "$OUT"` before the sources are read; it may
# write generated sources under $OUT only and prints their paths. A sidecar
# that redefines a built-in harness, or names a harness with no props file,
# gives ERROR (exit 2).
# Environment: FORMAL_BIN is prepended to PATH inside this script only (the
# sandbox: $HOME/tools/oss-cad-suite/bin), so a campaign's simulators stay the
# system ones. Every harness's yosys log is checked for an implicitly declared
# or undriven wire (a hierarchical reference); a hit is ERROR, never a verdict.
set -u
[ -n "${FORMAL_BIN:-}" ] && export PATH="$FORMAL_BIN:$PATH"
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
                   [spi_core]="spi.v" [spi_dc]="spi.v" [spi_f12]="$SOC tt_um_alfadelta10010_alphaone_soc.v" [spi_bus]="gpio.v spi.v" [spi_bb]="gpio.v spi.v" [spi_bb1]="gpio.v spi.v" [spi_cover]="gpio.v spi.v" )
declare -A EXTRA=( [core_hold]="rf_top_stub.v" [core_req]="rf_top_stub.v" [core_fetch]="rf_top_stub.v" [soc_rst_sync]="rf_top_stub.v" [spi_f12]="rf_top_stub.v" )   # read from $HERE
declare -A PASSES=( [core_hold]="memory_map; setundef -undriven -expose;" [core_req]="memory_map; setundef -undriven -expose;" [core_fetch]="memory_map; setundef -undriven -expose;" )
declare -A MODE=( [csr]=induct [core_hold]=induct [core_req]=bmc [core_fetch]=induct [syscon_comb]=bmc [syscon_gate]=induct [soc_rst_sync]=struct
                  [spi_core]=induct [spi_dc]=induct [spi_bus]=induct [spi_bb]=bmc [spi_bb1]=bmc [spi_cover]=cover [spi_f12]=struct )
declare -A BDEPTH=( [syscon_comb]=24 [spi_bb]=24 [spi_bb1]=${BB1_DEPTH:-24} [spi_cover]=48 )     # per-harness bmc depth; default $BMC_DEPTH
# spi_*: only induction length 1 counts as PROVED (WO-29 7.1); a harness that
# needs more reports FAILED and gets a strengthening invariant instead.
declare -A IDEPTH=( [spi_core]=1 [spi_dc]=1 [spi_bus]=1 )
# spi_*: white-box access with `expose` (a hierarchical reference such as
# dut.x would become an undriven wire, and `bind` does nothing: both are
# forbidden). PRE runs after the RTL is read and before the harness is.
SPI_EXPOSE="w:st w:sr w:bb w:bba w:cc w:bc w:cpol w:cpha w:baud"
# gpio is flattened and the wires of its spi instance renamed s_<port>, then
# exposed (the names of spi.v's ports and of the flops listed in WO-28 2.1).
GPIO_PRE="hierarchy -top gpio; proc; flatten; cd gpio;"
for x in wr_tx wr_ctl wr_baud wr_en wr_out miso st bba bb sr baud cpol cpha cc bc; do GPIO_PRE="$GPIO_PRE rename spi_inst.$x x_$x;"; done
GPIO_PRE="$GPIO_PRE expose w:x_wr_tx w:x_wr_ctl w:x_wr_baud w:x_wr_en w:x_wr_out w:x_miso w:x_st w:x_bba w:x_bb w:x_sr w:x_baud w:x_cpol w:x_cpha w:x_cc w:x_bc w:spi_en w:in_m w:in_s w:out_r; cd .."
declare -A PRE=( [spi_core]="hierarchy -top spi; proc; expose $SPI_EXPOSE" [spi_dc]="hierarchy -top spi; proc; expose $SPI_EXPOSE"
                 [spi_bus]="$GPIO_PRE" [spi_bb]="" [spi_bb1]="" [spi_cover]="$GPIO_PRE" )
# spi_bb1 is spi_bb_props.sv built with -DBB_BAUD1 (BAUD 1 and narrowed inputs)
declare -A PROPN=( [spi_bb1]=spi_bb ); declare -A DEFS=( [spi_bb1]="-DBB_BAUD1" )
BUILTIN=(csr core_hold core_req core_fetch syscon_comb syscon_gate soc_rst_sync spi_core spi_dc spi_bus spi_bb spi_bb1 spi_cover spi_f12)
declare -A PDR_TIMEOUT=() GEN=()
bad=0
err=0
ARRS=(FILES EXTRA PASSES MODE BDEPTH IDEPTH PRE PROPN DEFS PDR_TIMEOUT GEN)
sig() { local a n; for a in "${ARRS[@]}"; do for n in "${BUILTIN[@]}"; do eval "printf '%s\n' \"$a[$n]=\${$a[$n]-UNSET}\""; done; done; }
SIDE=(); declare -A BROKEN=()
for conf in $(ls "$HERE"/*.conf 2>/dev/null | sort); do
  ALL=(); before=$(sig)
  # shellcheck disable=SC1090
  . "$conf"
  after=$(sig)
  if [ "$before" != "$after" ]; then
    for n in "${BUILTIN[@]}"; do
      if [ "$(diff <(echo "$before") <(echo "$after") | grep -c "\[$n\]")" != 0 ]; then
        echo "ERROR $n: sidecar $(basename "$conf") redefines a built-in harness"; BROKEN[$n]=1; err=1
      fi
    done
    continue
  fi
  for n in "${ALL[@]}"; do
    case " ${BUILTIN[*]} " in *" $n "*) echo "ERROR $n: sidecar $(basename "$conf") redefines a built-in harness"; BROKEN[$n]=1; err=1; continue;; esac
    if [ ! -f "$HERE/${PROPN[$n]:-$n}_props.sv" ] && [ "${MODE[$n]:-}" != struct ]; then
      echo "ERROR $n: sidecar $(basename "$conf"): ${PROPN[$n]:-$n}_props.sv is missing"; err=1; continue
    fi
    if [ -z "${FILES[$n]:-}" ] || [ -z "${MODE[$n]:-}" ]; then
      echo "ERROR $n: sidecar $(basename "$conf") sets no FILES or MODE"; err=1; continue
    fi
    SIDE+=("$n")
  done
done
while [ $# -gt 0 ]; do
  case "$1" in
    *) break;;
  esac
done
names=("$@"); [ ${#names[@]} = 0 ] && names=("${BUILTIN[@]}" "${SIDE[@]}")

# guard_hit LOG: the log shows a hierarchical reference (an implicit, undriven wire)
# The one allowed exception: rf_top_stub.v's wires free_a, free_b, ra_data and
# rb_data are undriven on purpose (free register-file read data, turned into
# inputs by `setundef -undriven -expose` in the core_* PASSES).
guard_hit() { grep -E "is implicitly declared|is used but has no driver" "$1" | grep -vE 'Wire rf_top\.\\(free_a|free_b|ra_data|rb_data) ' | grep -q .; }

for n in "${names[@]}"; do
  if [ -n "${BROKEN[$n]:-}" ]; then continue; fi
  if [ -z "${FILES[$n]:-}" ] || [ -z "${MODE[$n]:-}" ]; then echo "ERROR $n: no such harness"; err=1; continue; fi
  srcs=""; for f in ${FILES[$n]}; do srcs="$srcs $SRC/$f"; done
  if [ -n "${GEN[$n]:-}" ]; then
    gen=$(${GEN[$n]} "$SRC" "$OUT") || { echo "ERROR $n: generator ${GEN[$n]} failed"; err=1; continue; }
    srcs="$srcs $gen"
  fi
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
    stop=alphaone_soc; [ "$n" = spi_f12 ] && stop=tt_um_alfadelta10010_alphaone_soc
    timeout 1800 yosys -p "read_verilog -sv $srcs; prep -top $stop; flatten; opt_clean; write_json $json" > "$log" 2>&1
    if [ ! -s "$json" ]; then echo "ERROR $n: yosys gave no netlist (log: $log)"; err=1; continue; fi
    if guard_hit "$log"; then echo "ERROR $n: an undriven or implicitly declared wire (hierarchical reference?) (log: $log)"; err=1; continue; fi
    if [ "$n" = spi_f12 ]; then
    out=$(python3 - "$json" <<'PYEOF'
# F12 (SPI-014): MOSI, SCK and the chip selects leave from flops.
#   F1  gpio's out[0,1,2,3,6,7]: the driver, through wires and $pos only, is the
#       Q of a sequential cell.
#   F2  the wrapper's uo_out[0,1,2,3,6,7]: the cone back to sequential Q outputs
#       holds exactly one gate (a 2-input logic cell, or a mux with a constant
#       leg) that has `run` in its cone, plus at most one inverter; its leaves
#       are the gpio pin flop and the flop `run`.
import json, sys
d = json.load(open(sys.argv[1]))
top = d["modules"]["tt_um_alfadelta10010_alphaone_soc"]
SEQ = ("$dff", "$sdff", "$adff", "$aldff", "$dffsr", "$ff", "$dlatch", "$adlatch", "$dlatchsr", "$sr", "$mem")
drv = {}
for name, c in top["cells"].items():
    for port, bits in c["connections"].items():
        if c["port_directions"].get(port) == "output":
            for i, b in enumerate(bits):
                if isinstance(b, int):
                    drv[b] = (name, c, port, i)
def bits_of(n):
    return [b for b in top["netnames"][n]["bits"]]
bad = []
def seqcell(c):
    return c["type"].startswith(SEQ)
# F1
gout = [n for n in top["netnames"] if n.endswith("gpio_inst.out")]
if len(gout) != 1:
    print("ERROR no gpio_inst.out net"); sys.exit()
gb = bits_of(gout[0])
for i in (0, 1, 2, 3, 6, 7):
    b = gb[i]
    seen = 0
    while isinstance(b, int) and b in drv and drv[b][1]["type"] == "$pos" and seen < 20:
        b = drv[b][1]["connections"]["A"][drv[b][3]]; seen += 1
    if not (isinstance(b, int) and b in drv and seqcell(drv[b][1])):
        t = drv[b][1]["type"] if isinstance(b, int) and b in drv else "undriven"
        bad.append("F1 out[%d] driven by %s" % (i, t))
# F2
run_bits = bits_of("run")
runq = set(run_bits)
ub = bits_of("uo_out")
for i in (0, 1, 2, 3, 6, 7):
    gates, leaves, work, seen = [], set(), [ub[i]], set()
    while work:
        b = work.pop()
        if not isinstance(b, int) or b in seen:
            continue
        seen.add(b)
        if b not in drv:
            leaves.add(("const_or_input", b)); continue
        name, c, port, k = drv[b]
        if seqcell(c):
            leaves.add(("seq", b)); continue
        if c["type"] != "$pos":
            gates.append(c)
        ycells = c["connections"].get("Y", [])
        for p, bs in c["connections"].items():
            if c["port_directions"].get(p) != "input":
                continue
            if len(bs) == len(ycells) and len(bs) > 1:
                work.append(bs[k])          # a bitwise cell: only this bit's input
            else:
                work.extend(bs)             # a 1-bit select or operand
    logic = [c for c in gates if c["type"] not in ("$not", "$logic_not")]
    inv   = [c for c in gates if c["type"] in ("$not", "$logic_not")]
    seqleaves = {b for kind, b in leaves if kind == "seq"}
    ok = len(logic) == 1 and len(inv) <= 1 and run_bits[0] in seqleaves and len(seqleaves) == 2
    if ok:
        c = logic[0]
        wide = [p for p, bs in c["connections"].items() if c["port_directions"].get(p) == "input" and len(bs) > 1]
        ok = c["type"] in ("$and", "$or", "$xor", "$nand", "$nor", "$xnor", "$logic_and", "$logic_or", "$mux")
    if not ok:
        bad.append("F2 uo_out[%d]: %d logic cells, %d inverters, flop leaves %d, run leaf %s"
                   % (i, len(logic), len(inv), len(seqleaves), run_bits[0] in seqleaves))
print("HIT " + "; ".join(bad) if bad else "CLEAN f12")
PYEOF
)
    else
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
    fi
    case "$out" in
      CLEAN*) echo "PROVED $n (structural)";;
      HIT*)   echo "FAILED $n: ${out#HIT } (log: $log)"; bad=1;;
      *)      echo "ERROR $n: no verdict (log: $log)"; err=1;;
    esac
    continue
  fi
  bd="${BDEPTH[$n]:-$BMC_DEPTH}"
  if [ "${MODE[$n]}" = cover ]; then
    # one run per point (-D COVER_i); the point is assert(!cond), so "model found" = COVERED
    ncov=0; ntot=6; unr=""; ecov=0
    for i in 1 2 3 4 5 6; do
      clog="$OUT/formal_${n}_$i.log"
      timeout 1800 yosys -p "read_verilog -sv -formal $srcs; ${PRE[$n]:-}; read_verilog -sv -formal -DCOVER_$i ${EXTRA_DEFS:-} $HERE/${n}_props.sv; \
          prep -top ${n}_props; chformal -lower; flatten; opt -fast; \
          sat -prove-asserts -set-assumes -set-init-zero -set-def-inputs -seq $bd" > "$clog" 2>&1
      if guard_hit "$clog"; then ecov=1
      elif grep -q "SAT proof finished - model found: FAIL" "$clog"; then ncov=$((ncov+1))
      elif grep -q "SAT proof finished - no model found: SUCCESS" "$clog"; then unr="$unr $i"
      else ecov=1; fi
    done
    if [ $ecov = 1 ]; then echo "ERROR $n: a cover run gave no verdict (logs: $OUT/formal_${n}_*.log)"; err=1
    elif [ $ncov = $ntot ]; then echo "COVERED $n ($ncov/$ntot)"
    else echo "FAILED $n: $ncov/$ntot covered, unreachable within $bd steps:$unr"; bad=1; fi
    continue
  fi
  if [ "${MODE[$n]}" = bmc ]; then
    sat="sat -prove-asserts -set-assumes -set-init-zero -set-def-inputs -seq $bd"
  else
    sat="sat -tempinduct -tempinduct-def -prove-asserts -set-assumes -set-init-zero -set-def-inputs -seq 1 -maxsteps ${IDEPTH[$n]:-$DEPTH}"
  fi
  if [ -n "${PRE[$n]:-}" ]; then rd="read_verilog -sv -formal $srcs; ${PRE[$n]}; read_verilog -sv -formal ${DEFS[$n]:-} ${EXTRA_DEFS:-} $HERE/${n}_props.sv"
  else rd="read_verilog -sv -formal $srcs; read_verilog -sv -formal ${DEFS[$n]:-} ${EXTRA_DEFS:-} $HERE/${PROPN[$n]:-$n}_props.sv"; fi
  timeout 1800 yosys -p "$rd; prep -top ${PROPN[$n]:-$n}_props; \
               chformal -lower; flatten; ${PASSES[$n]:-} opt -fast; $sat" > "$log" 2>&1
  if guard_hit "$log"; then
    echo "ERROR $n: an undriven or implicitly declared wire (hierarchical reference?) (log: $log)"; err=1; continue
  fi
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
