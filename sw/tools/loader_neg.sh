#!/bin/bash
# The loader's failure paths: every damaged header must stop with the right code and message, and the
# unknown flag bits must be ignored. Needs the hello payload and the bench built:
#   make -C sw hello bench && sw/tools/loader_neg.sh
cd "$(dirname "$0")/.." || exit 1
B=$(cd ../build/sw && pwd)
fail=0; n=0
for v in magic erased size_big load_low load_high load_unal size_unal size_zero entry_low entry_end sum_payload sum_header flags_unknown; do
  n=$((n+1))
  want=$(python3 tools/badimage.py "$B/hello/flash.bin" "$B/hello/bad-$v.hex" "$v")
  code=${want%% *}; msg=${want#* }
  (cd "$B/hello" && timeout 200 ${SIM:-$B/bench/sim} +FLASH_FILE="$B/hello/bad-$v.hex" +UART_DIV=34 +MAX_CYCLES=8000000 > "bad-$v.log" 2>&1)
  if [ "$code" = 0 ]; then
    ok=$(grep -q "SW-RESULT: PASS" "$B/hello/bad-$v.log" && grep -q "Hello, world" "$B/hello/bad-$v.log" && ! grep -q "flash in DDR\|flash stays SDR" "$B/hello/bad-$v.log" && echo y)
  else
    ok=$(grep -q "SW-RESULT: FAIL code=$code " "$B/hello/bad-$v.log" && grep -q "loader: $msg" "$B/hello/bad-$v.log" && ! grep -q "Hello, world\|sum ok" "$B/hello/bad-$v.log" && echo y)
  fi
  if [ "$ok" = y ]; then echo "ok    $v ($code ${msg:-boots})"; else echo "FAIL  $v: want code $code '$msg'"; grep -E "loader:|SW-RESULT" "$B/hello/bad-$v.log" | head -3; fail=$((fail+1)); fi
done
echo "loader negative images: $((n-fail)) of $n as expected"
[ "$fail" = 0 ]
