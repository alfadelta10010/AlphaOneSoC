#!/bin/bash
# Build and run Zephyr on the AlphaOneSoC Verilator bench; check the output.
#   run-zephyr.sh [hello|sync|tests|all] ...    (default: all = hello sync and the kernel tests)
# Needs ${ZEPHYR_WORK:-$HOME/zephyr-work}/{venv,ws,sw,build/sw/bench/sim} (see README-zephyr.txt for the one-time setup).
# Env: JOBS (parallel simulations, default 2), TESTS (list), MAXC (cycle cap per run).
set -u
W=${ZEPHYR_WORK:-$HOME/zephyr-work}; D=$W/deliver
. $D/env.sh
export PATH=$HOME/tools/rv64-gcc-elf/bin:$PATH
SIM=$W/build/sw/bench/sim
JOBS=${JOBS:-2}; MAXC=${MAXC:-1500000000}
TESTS=${TESTS:-"common mutex/mutex_api semaphore/semaphore fifo/fifo_api sleep timer/timer_api"}
LOGS=$D/logs; mkdir -p $LOGS $W/b
Z=$ZEPHYR_BASE
[ -x $SIM ] || make -C $W/sw -j2 bench
[ -f $W/build/sw/loader/loader.bin ] || make -C $W/sw -j2 hello >/dev/null

mkapp_sync() {  # the synchronization sample with a 50 ms sleep and a 600 ms main, so the run ends
  rm -rf $D/apps/sync; mkdir -p $D/apps; cp -r $Z/samples/synchronization $D/apps/sync
  sed -i 's/#define SLEEPTIME 500/#define SLEEPTIME 50/' $D/apps/sync/src/main.c
  python3 - <<P
p="$D/apps/sync/src/main.c"; s=open(p).read(); i=s.rindex("return 0;")
open(p,"w").write(s[:i]+"k_msleep(600); /* about 12 rounds, then the run ends */\n\t"+s[i:])
P
}

build() {  # build <name> <app dir> [cmake args]
  [ -n "${SKIPBUILD:-}" ] && [ -f $W/b/$1/flash.hex ] && return 0
  local n=$1 app=$2; shift 2
  (cd $Z && nice -n 19 west build -p always -b alphaone $app -d $W/b/$n -o=-j2 -- \
     -DZEPHYR_EXTRA_MODULES=$ZMOD "$@") > $LOGS/$n.build.log 2>&1 || { echo "BUILD FAIL $n"; return 1; }
  $D/mkflash.sh $W/b/$n >> $LOGS/$n.build.log 2>&1
}

sim() {  # sim <name> : run, cap MAXC cycles
  ( cd $W/b/$1 && nice -n 19 stdbuf -oL $SIM +FLASH_FILE=flash.hex +UART_DIV=34 +MAX_CYCLES=$MAXC > $LOGS/$1.run.log 2>&1 )
}

verdict() {  # verdict <name> <pattern that must appear> : prints a result line
  local n=$1 pat=$2 l=$LOGS/$1.run.log
  local res=$(grep -m1 "^SW-RESULT" $l | sed 's/SW-RESULT: //')
  if grep -q "$pat" $l && ! grep -q "FAIL" $l && [[ $res == PASS* ]]; then v=PASS; else v=FAIL; fi
  printf "%-28s %s   [%s]\n" "$n" "$v" "$res" | tee -a $LOGS/summary.txt
  [ $v = PASS ]
}

what=${*:-all}; rc=0
: > $LOGS/summary.txt
case " $what " in *" hello "*|*" all "*)
  build hello samples/hello_world && sim hello && verdict hello "Hello World! alphaone" || rc=1;; esac
case " $what " in *" sync "*|*" all "*)
  mkapp_sync; build sync $D/apps/sync && sim sync && verdict sync "thread_b: Hello World" || rc=1;; esac
case " $what " in *" tests "*|*" all "*)
  for t in $TESTS; do n=t_${t//\//_}; build $n tests/kernel/$t -DCONFIG_BOOT_DELAY=0 || rc=1; done
  running=0
  for t in $TESTS; do n=t_${t//\//_}; [ -f $W/b/$n/flash.hex ] || continue
    (sim $n; verdict $n "PROJECT EXECUTION SUCCESSFUL") &
    running=$((running+1)); [ $running -ge $JOBS ] && { wait -n; running=$((running-1)); }
  done; wait;; esac
(pgrep -x sim >/dev/null) || true
echo "---- summary"; cat $LOGS/summary.txt
exit $rc
