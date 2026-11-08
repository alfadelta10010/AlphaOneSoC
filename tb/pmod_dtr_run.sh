#!/usr/bin/env bash
# Builds tb/tb_pmod_dtr.v against the Pmod model and runs the DTR case list: pass cases,
# expected-fail cases (the model's ERROR text must match) and limit-raise cases (each limit
# raised past the margin P1 measured must fail with that check's message). Prints one verdict
# per case and "pmod_dtr: <k>/<n> as expected"; exits non-zero on any unexpected verdict.
#
#   BUILD_DIR=<dir>   build and log directory (default build/pmod_dtr)
#   MODEL=<file>      the model to use (default tb/qspi_pmod_model.v), for broken copies
set -u
cd "$(dirname "$0")/.."
B=${BUILD_DIR:-build/pmod_dtr}
MODEL=${MODEL:-tb/qspi_pmod_model.v}
IV=${IVERILOG:-/usr/bin/iverilog}
mkdir -p "$B"
TOP=tb_pmod_dtr
K=0; N=0

compile() {   # compile <out> [iverilog -P args...]
  local out=$1; shift
  $IV -g2012 "$@" -o "$out" -s $TOP "$MODEL" tb/tb_pmod_dtr.v > "$out.log" 2>&1 || { echo "pmod_dtr: compile failed ($out)"; cat "$out.log"; exit 2; }
}
simulate() {  # simulate <vvp> <log> plusargs...
  local vvp=$1 log=$2; shift 2
  timeout 300 vvp -n "$vvp" "$@" > "$log" 2>&1
  echo $? >> "$log.rc"
}
verdict() {   # verdict <id> <ok:0|1> <text>
  N=$((N+1)); [ "$2" = 1 ] && K=$((K+1))
  printf '%-5s %-8s %s\n' "$1" "$([ "$2" = 1 ] && echo as-exp || echo UNEXPECTED)" "$3"
}
dtr_line() { grep -h "qspi_pmod_model: DTR min margins" "$1" | sed 's/.*ns: //'; }
num() { sed -n "s/.*$2 \([-0-9.]*\).*/\1/p" <<<"$1" | head -1; }   # num "<line>" "rise setup"
flash_m() { grep -h "min margins ns (flash/PSRAM)" "$1" | sed -n "s/.*$2 \([-0-9.]*\)\/.*/\1/p"; }
close() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=0.0011)}'; }

DEF=$B/default.vvp
compile "$DEF"
rm -f "$B"/*.rc

# pass <id> <what> <extra check cmd or ""> plusargs...  (extra check: a shell function name)
pass_case() {
  local id=$1 chk=$2; shift 2
  local log=$B/$id.log
  rm -f "$log.rc"; simulate "$DEF" "$log" "$@"
  local ok=1 note=""
  grep -q "tb_pmod_dtr: PASS" "$log" || { ok=0; note="no PASS"; }
  grep -q "ERROR" "$log" && { ok=0; note="ERROR in log"; }
  if [ $ok = 1 ] && [ -n "$chk" ]; then note=$($chk "$log") || ok=0; fi
  verdict "$id" $ok "$note"
}
margins_is() { # margins_is <log> rs rh fs fh
  local l; l=$(dtr_line "$1")
  close "$(num "$l" 'rise setup')" "$2" && close "$(num "$l" 'rise hold')" "$3" &&
  close "$(num "$l" 'fall setup')" "$4" && close "$(num "$l" 'fall hold')" "$5" || { echo "margins: $l"; return 1; }
  echo "DTR margins $l"
}
c_p1()  { margins_is "$1" 9 8 9 8 || return 1; grep -q "SCK cycles 23" "$1" && grep -q "flash reads: EBh 0, EDh 1, resumes 0, bytes 4" "$1" || { echo "counters/cycles"; return 1; }; echo "margins 9/8/9/8, 23 SCK, EDh 1"; }
c_p2()  { margins_is "$1" 6 11 6 11; }
c_p3()  { margins_is "$1" 12 5 12 5; }
c_p4()  { grep -q "SCK cycles 25" "$1" && grep -q "13 nibbles captured, 0 wrong" "$1" && echo "12 nibbles + the held one, 25 SCK"; }
c_p5()  { grep -q "EDh 1, resumes 3, bytes 18" "$1" && echo "$(grep -h 'nibbles captured' "$1" | sed 's/tb_pmod_dtr: //')"; }
c_p12() { grep -q "EBh 1, EDh 1, resumes 2, bytes" "$1" && echo "$(grep -h 'flash reads' "$1" | sed 's/qspi_pmod_model: //')"; }
c_p13() { grep -q "17 nibbles captured, 0 wrong" "$1" && echo "17 nibbles across the wrap"; }
c_p14() { echo "$(dtr_line "$1")"; }

pass_case P1 c_p1
pass_case P2 c_p2 +QSPI_IO_DLY_PS=3000
pass_case P3 c_p3 +QSPI_SCK_DLY_PS=3000
pass_case P4 c_p4 +OPEN_A=000200 +OPEN_N=6
pass_case P5 c_p5 +SEQ=stream
pass_case P6 c_p5 +SEQ=stream +DTR_LAUNCH=1 +HOST_LAUNCH=1
pass_case P12 c_p12 +SEQ=p12
pass_case P13 c_p13 +OPEN_A=FFFFFC +OPEN_N=8
pass_case P14 c_p14 +SCK_PS=33334 +QSPI_DELAY=22 +QSPI_HOLD=17 +CAP_PS=25000

# P11: same data, same margins as without delay (SCK 20 ns).
rm -f $B/P11base.log.rc; simulate "$DEF" $B/P11base.log +SCK_PS=20000
pass_case P11 "" +SCK_PS=20000 +QSPI_SCK_DLY_PS=25000 +QSPI_IO_DLY_PS=25000 +QSPI_CS_DLY_PS=25000 +CAP_PS=30000 +QSPI_DELAY=2
if [ "$(dtr_line $B/P11.log)" = "$(dtr_line $B/P11base.log)" ] && [ -n "$(dtr_line $B/P11.log)" ] &&
   grep -q "tb_pmod_dtr: PASS" $B/P11base.log; then verdict P11b 1 "same margins as with 0 delay: $(dtr_line $B/P11.log)"
else verdict P11b 0 "margins differ: [$(dtr_line $B/P11.log)] vs [$(dtr_line $B/P11base.log)]"; fi

# Sweeps: the passing capture offsets (ps) must be exactly lo..hi step 500.
sweep_case() { # sweep_case <id> <lo> <hi> [ignore ps...] -- plusargs
  local id=$1 lo=$2 hi=$3; shift 3
  local ign=(); while [ "$1" != "--" ]; do ign+=("$1"); shift; done; shift
  local log=$B/$id.log; rm -f "$log.rc"; simulate "$DEF" "$log" +SWEEP "$@"
  local got want t
  got=$(sed -n 's/^tb_pmod_dtr: sweep pass ps://p' "$log")
  for t in "${ign[@]:-}"; do [ -n "$t" ] && got=$(tr ' ' '\n' <<<"$got" | grep -vx "$t" | tr '\n' ' '); done
  got=$(tr -s ' ' '\n' <<<"$got" | sed '/^$/d' | tr '\n' ' ')
  want=$( [ "$lo" = none ] && echo "" || seq "$lo" 500 "$hi" | tr '\n' ' ')
  local raw=$(sed -n 's/^tb_pmod_dtr: sweep pass ps://p' "$log")
  local edge="12.0:$(grep -qw 12000 <<<"$raw" && echo pass || echo fail) 23.0:$(grep -qw 23000 <<<"$raw" && echo pass || echo fail)"
  if [ "$got" = "$want" ] && ! grep -q ERROR "$log"; then
    verdict "$id" 1 "passing CAP ns: $( [ "$lo" = none ] && echo none || echo "$(awk -v x=$lo "BEGIN{print x/1000}") ... $(awk -v x=$hi "BEGIN{print x/1000}")") (same-step points, not judged: $edge)"
  else verdict "$id" 0 "passing ps [$got] want [$want]"; fi
}
sweep_case P7 12500 22500 12000 23000 -- +QSPI_DELAY=12 +QSPI_HOLD=3
sweep_case P8 32500 42500 32000 43000 -- +QSPI_DELAY=12 +QSPI_HOLD=3 +DTR_LAUNCH=1
sweep_case P9 25500 27500 25000 28000 -- +SCK_PS=20000 +QSPI_DELAY=25 +QSPI_HOLD=18
sweep_case P10 none none -- +SCK_PS=20000 +QSPI_DELAY=25 +QSPI_HOLD=14

# Expected-fail cases: one run each, the ERROR text must match.
fail_case() { # fail_case <id> <regex> plusargs...
  local id=$1 re=$2; shift 2
  local log=$B/$id.log; rm -f "$log.rc"; simulate "$DEF" "$log" "$@"
  if grep "ERROR: qspi_pmod_model:" "$log" | grep -Eq "$re"; then
    verdict "$id" 1 "$(grep -h 'ERROR: qspi_pmod_model:' "$log" | head -1 | sed 's/ERROR: qspi_pmod_model: //; s/ (cs_n.*//')"
  else verdict "$id" 0 "wanted /$re/, got: $(grep -h 'ERROR\|tb_pmod_dtr: PASS' "$log" | head -1)"; fi
}
fail_case F1 "DTR_AD: data-in setup violated.*before SCK rise" +SU_R_PS=900
fail_case F2 "DTR_AD: data-in hold violated.*after SCK rise" +SU_F_PS=18100
fail_case F3 "DTR_AD: data-in setup violated.*before SCK fall" +SU_F_PS=900
fail_case F4 "DTR_AD: data-in hold violated.*after SCK fall" +SU_R_PS=18100
fail_case F5 "M5-4 = 10 would enter DTR continuous-read mode" +MODE_HEX=A0
fail_case F6 "SCK period below the minimum" +SCK_PS=15000
fail_case F7 "host and device both driving IO" +NO_REL
fail_case F8 "something other than its Exit QPI" +FLASH_QPI
fail_case F9 "A1:A0 != 00" +OPEN_A=000102
fail_case F10 "IO release hold violated" +REL_PS=1500

# Limit-raise cases: limit + measured margin + 0.1 ns must fail with that check's message.
fl=$B/P1.log
RS=$(num "$(dtr_line $fl)" 'rise setup'); RH=$(num "$(dtr_line $fl)" 'rise hold')
FS=$(num "$(dtr_line $fl)" 'fall setup'); FH=$(num "$(dtr_line $fl)" 'fall hold')
CSS=$(flash_m $fl 'CS setup'); CSH=$(flash_m $fl 'CS hold')
rm -f $B/P1rel.log.rc; simulate "$DEF" $B/P1rel.log +REL_PS=2500
REL=$(flash_m $B/P1rel.log 'IO release hold')
raise() { awk -v l="$1" -v m="$2" 'BEGIN{printf "%.3f", l+m+0.1}'; }
limit_case() { # limit_case <id> <param> <value> <regex> plusargs...
  local id=$1 par=$2 val=$3 re=$4; shift 4
  compile "$B/$id.vvp" "-P$TOP.$par=$val"
  local log=$B/$id.log; rm -f "$log.rc"; simulate "$B/$id.vvp" "$log" "$@"
  if grep "ERROR: qspi_pmod_model:" "$log" | grep -Eq "$re"; then
    verdict "$id" 1 "$par=$val: $(grep -h 'ERROR: qspi_pmod_model:' "$log" | head -1 | sed 's/ERROR: qspi_pmod_model: //; s/ (cs_n.*//')"
  else verdict "$id" 0 "$par=$val wanted /$re/, got: $(grep -h 'ERROR\|tb_pmod_dtr: PASS' "$log" | head -1)"; fi
  rm -f "$B/$id.vvp"
}
limit_case L1 TDVCH_NS    "$(raise 1.0 "$RS")"  "DTR_AD: data-in setup violated.*before SCK rise"
limit_case L2 TCHDX_NS    "$(raise 2.0 "$RH")"  "DTR_AD: data-in hold violated.*after SCK rise"
limit_case L3 TDVCL_NS    "$(raise 1.0 "$FS")"  "DTR_AD: data-in setup violated.*before SCK fall"
limit_case L4 TCLDX_NS    "$(raise 2.0 "$FH")"  "DTR_AD: data-in hold violated.*after SCK fall"
limit_case L5 TCLDX_NS    "$(raise 2.0 "$REL")" "IO release hold violated" +REL_PS=2500
limit_case L6 TSLCH_NS    "$(raise 3.0 "$CSS")" "chip select setup violated"
limit_case L7 TCHSH_NS    "$(raise 3.0 "$CSH")" "chip select hold violated"
limit_case L8 TCLK_DTR_NS 40.1                  "SCK period below the minimum"

echo "pmod_dtr: $K/$N as expected"
[ "$K" = "$N" ]
