#!/usr/bin/env bash
#
# Assemble every program riscv-dv generated, and report per stream.
#
# Generation exiting 0 is not evidence that a test is usable. pyflow decides
# which access widths are legal from its own model of the address it is about
# to emit, and picks base registers without applying the constraint that says
# which registers it may touch -- both of which have produced programs that
# generate cleanly and then fail to assemble:
#
#     Error: illegal operands `c.swsp t2,23(sp)'
#     Error: illegal operands `la zero,region_1+3609'
#
# Those are silent until the compile stage, where they look like a toolchain
# problem rather than a generator one. Run this straight after `river_core
# generate` to attribute them correctly.
#
# Usage: scripts/check-riscv-dv-asm.sh [asm-root] [riscv-dv-dir]
set -uo pipefail

ROOT="${1:-build/mywork/riscv_dv}"
DV_DIR="${2:-build/riscv-dv}"
MARCH="rv32imac_zicsr_zifencei"
MABI="ilp32"

CC=""
for cand in riscv32-unknown-elf-gcc riscv64-unknown-elf-gcc; do
    if command -v "$cand" >/dev/null 2>&1; then CC="$cand"; break; fi
done
if [ -z "$CC" ]; then
    echo "no riscv*-unknown-elf-gcc on PATH" >&2
    exit 2
fi

if [ ! -d "$ROOT" ]; then
    echo "no generated tests under $ROOT" >&2
    exit 2
fi

total=0
bad=0
printf '%-36s %6s %6s\n' "STREAM" "PROGS" "ERRORS"
for dir in "$ROOT"/*/; do
    stream=$(basename "$dir")
    n=0
    e=0
    for asm in "$dir"asm_test/*.S; do
        [ -e "$asm" ] || continue
        n=$((n + 1))
        total=$((total + 1))
        if ! out=$("$CC" -c -march="$MARCH" -mabi="$MABI" \
                        -I "$DV_DIR/user_extension" \
                        -x assembler "$asm" -o /dev/null 2>&1); then
            e=$((e + 1))
            bad=$((bad + 1))
            echo "--- $asm" >&2
            echo "$out" | head -5 >&2
        elif [ -n "$out" ]; then
            # gas warns without failing for some malformed operands
            e=$((e + 1))
            bad=$((bad + 1))
            echo "--- $asm (warnings)" >&2
            echo "$out" | head -5 >&2
        fi
    done
    printf '%-36s %6d %6d\n' "$stream" "$n" "$e"
done

echo
echo "total programs: $total, failing: $bad"
[ "$bad" -eq 0 ]
