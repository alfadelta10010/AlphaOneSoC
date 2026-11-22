#!/bin/bash
# Build NuttX 12.11.0 (rv-virt, 32-bit flat, patched for AlphaOneSoC), boot it on the SoC bench through the
# loader, play deliver/sessions/nsh.txt into the UART one character per echo, check the output.
#   run-nuttx.sh [max_cycles]       (default 3000000000; on a loaded sandbox the session takes about an hour)
# Sandbox only.  Needs: this repo copy at $W (sw/, src/, tb/), rv64 gcc, verilator, git, curl, python3, flex, bison, gperf.
set -e
W=$(cd "$(dirname "$0")/.." && pwd); D=$W/deliver; NX=$W/nx; B=$W/build/nuttx; CYC=${1:-3000000000}
export PATH=$NX/kv/bin:$HOME/tools/rv64-gcc-elf/bin:$HOME/tools/verilator/bin:$PATH; unset VERILATOR_ROOT
mkdir -p $NX $B
# host tools: kconfiglib (+ the kconfig-tweak shim) and genromfs
if [ ! -x $NX/kv/bin/olddefconfig ]; then python3 -m venv $NX/kv && $NX/kv/bin/pip -q install kconfiglib; fi
cp $D/tools/kconfig-tweak $NX/kv/bin/
if [ ! -x $NX/kv/bin/genromfs ]; then git clone -q --depth 1 https://github.com/chexum/genromfs.git $NX/genromfs && make -C $NX/genromfs -s && cp $NX/genromfs/genromfs $NX/kv/bin/; fi
# sources at the pinned tag
[ -d $NX/nuttx ] || git clone -q --depth 1 --branch nuttx-12.11.0 https://github.com/apache/nuttx.git $NX/nuttx
[ -d $NX/apps ]  || git clone -q --depth 1 --branch nuttx-12.11.0 https://github.com/apache/nuttx-apps.git $NX/apps
cd $NX/nuttx
cp -a $D/overlay/. .
python3 $D/patch.py .
./tools/configure.sh -l rv-virt:alphaone >/dev/null
make olddefconfig >/dev/null 2>&1
nice -n 19 make -j2 >$B/build.log 2>&1 || { tail -20 $B/build.log; exit 1; }
# the SoC bench and the loader
make -C $W/sw -j2 bench hello >$B/bench-build.log 2>&1
python3 $D/tools/mkscript_slow.py $D/sessions/nsh.txt $B/nsh.hex
NUTTX_WORK=$W $D/runsim.sh nsh $CYC $B/nsh.hex
mkdir -p $D/logs && cp $B/nsh.log $D/logs/nsh-session.log
$D/check-nuttx.sh $B/nsh.log
