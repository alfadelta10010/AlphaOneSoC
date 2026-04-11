#!/bin/bash
# Convert a RISC-V assembly file to a hex file for simulation
# Usage: ./scripts/asm2hex.sh <input.S> [output.hex]
#
# The hex file is byte-addressable (one byte per line) suitable for
# $readmemh() in Verilog with a byte-addressable memory array.

set -euo pipefail

TOOLCHAIN_PREFIX="${RISCV_PREFIX:-riscv64-unknown-elf-}"
MARCH="${RISCV_MARCH:-rv32imac_zicsr_zifencei}"
MABI="${RISCV_MABI:-ilp32}"
LINKER_SCRIPT="${LINKER_SCRIPT:-$(dirname "$0")/../tests/linker.ld}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <input.S> [output.hex]"
    exit 1
fi

INPUT="$1"
BASENAME=$(basename "${INPUT}" .S)
OUTDIR=$(dirname "${INPUT}")
OUTPUT="${2:-${OUTDIR}/${BASENAME}.hex}"
ELF="${OUTDIR}/${BASENAME}.elf"
BIN="${OUTDIR}/${BASENAME}.bin"

echo "Assembling ${INPUT} → ${OUTPUT}"
echo "  MARCH=${MARCH} MABI=${MABI}"

# Compile
${TOOLCHAIN_PREFIX}gcc \
    -march=${MARCH} -mabi=${MABI} \
    -nostdlib -nostartfiles \
    -T "${LINKER_SCRIPT}" \
    -o "${ELF}" \
    "${INPUT}"

# Disassemble for debug
${TOOLCHAIN_PREFIX}objdump -d "${ELF}" > "${OUTDIR}/${BASENAME}.dis"
echo "  Disassembly: ${OUTDIR}/${BASENAME}.dis"

# Convert to binary
${TOOLCHAIN_PREFIX}objcopy -O binary "${ELF}" "${BIN}"

# Convert binary to hex (one byte per line, for $readmemh with byte array)
xxd -p -c 1 "${BIN}" > "${OUTPUT}"

echo "  ELF:  ${ELF}"
echo "  Hex:  ${OUTPUT} ($(wc -l < "${OUTPUT}") bytes)"
echo "Done."
