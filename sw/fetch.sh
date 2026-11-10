#!/bin/sh
# Fetch the third-party benchmark sources at pinned commits into
# ../build/sw/third_party. They are not copied into this repository.
#
#   coremark     EEMBC CoreMark (Apache 2.0)
#   riscv-tests  only benchmarks/dhrystone is used (the Dhrystone sources)
#   fatfs        ChaN's FatFs R0.16 (BSD-1-clause), the release zip, checked against its SHA-256
#   embench-iot  Embench-IoT 1.0 (GPL-3.0-or-later; linked into the benchmark binaries only, never committed here)
set -e
TP="$(cd "$(dirname "$0")/.." && pwd)/build/sw/third_party"
mkdir -p "$TP"

get() { # get <name> <url> <commit>
    if [ "$(git -C "$TP/$1" rev-parse HEAD 2>/dev/null)" = "$3" ]; then return; fi
    rm -rf "$TP/$1"
    git init -q "$TP/$1"
    git -C "$TP/$1" fetch -q --depth 1 "$2" "$3"
    git -C "$TP/$1" checkout -q FETCH_HEAD
    echo "fetched $1 $3"
}

get coremark    https://github.com/eembc/coremark.git                    1f483d5b8316753a742cbf5590caf5bd0a4e4777
get riscv-tests https://github.com/riscv-software-src/riscv-tests.git    3df703cd52d5f0d8224e3c50bf03c6cb70efff98
get embench-iot https://github.com/embench/embench-iot.git                 09c2ed8c3b7008c95d08b038de4a3f6dc103ed70

# FatFs is published as a zip, not in a repository.
FF_SHA=99f7dc1f7e095356e4a9e3dbe29959090d8b948afe2bbc5441e52fdf4b85449e
if [ ! -f "$TP/fatfs/source/ff.c" ] || [ "$(cat "$TP/fatfs/.sha256" 2>/dev/null)" != "$FF_SHA" ]; then
    rm -rf "$TP/fatfs"
    mkdir -p "$TP/fatfs"
    curl -sSL -o "$TP/fatfs/ff16.zip" https://elm-chan.org/fsw/ff/arc/ff16.zip
    echo "$FF_SHA  $TP/fatfs/ff16.zip" | sha256sum -c - >/dev/null
    python3 -I -m zipfile -e "$TP/fatfs/ff16.zip" "$TP/fatfs"
    echo "$FF_SHA" > "$TP/fatfs/.sha256"
    echo "fetched fatfs R0.16"
fi
