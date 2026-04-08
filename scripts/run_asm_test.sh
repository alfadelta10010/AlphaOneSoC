#!/bin/bash
# Run a RISC-V assembly file through the FyraCore CPU testbench
# Usage: ./scripts/run_asm_test.sh <input.S> [--quiet] [--max-cycles N] [--vcd]
#
# This script:
#   1. Assembles the .S file to a hex file
#   2. Compiles the CPU testbench with iverilog
#   3. Runs the simulation
#   4. Reports results (per-instruction register dump by default)

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${PROJ_DIR}/src"
TB_DIR="${PROJ_DIR}/tb"
BUILD_DIR="${PROJ_DIR}/build"
SCRIPTS_DIR="${PROJ_DIR}/scripts"

QUIET=0
MAX_CYCLES=100000
DUMP_VCD=0

# Parse args
if [ $# -lt 1 ]; then
    echo "Usage: $0 <input.S> [--quiet] [--max-cycles N] [--vcd]"
    exit 1
fi

INPUT="$1"
shift

while [ $# -gt 0 ]; do
    case "$1" in
        --quiet)   QUIET=1; shift ;;
        --max-cycles) MAX_CYCLES="$2"; shift 2 ;;
        --vcd)     DUMP_VCD=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

BASENAME=$(basename "${INPUT}" .S)
mkdir -p "${BUILD_DIR}"

# Step 1: Assemble
echo "=== Assembling ${INPUT} ==="
LINKER_SCRIPT="${PROJ_DIR}/tests/linker.ld" \
    bash "${SCRIPTS_DIR}/asm2hex.sh" "${INPUT}" "${BUILD_DIR}/${BASENAME}.hex"

# Step 2: Compile testbench
echo ""
echo "=== Compiling testbench ==="
SRC_FILES=$(ls ${SRC_DIR}/adder.v ${SRC_DIR}/alu.v ${SRC_DIR}/and2.v \
    ${SRC_DIR}/branchCtrl.v ${SRC_DIR}/compressed_decoder.v \
    ${SRC_DIR}/controller.v ${SRC_DIR}/csr.v ${SRC_DIR}/decoder.v \
    ${SRC_DIR}/muldiv.v \
    ${SRC_DIR}/mux21.v ${SRC_DIR}/mux31.v ${SRC_DIR}/or2.v \
    ${SRC_DIR}/regFile.v ${SRC_DIR}/regs.v ${SRC_DIR}/signExt.v \
    ${SRC_DIR}/fyracore.v)

iverilog -Wall \
    -DINIT_FILE=\"${BUILD_DIR}/${BASENAME}.hex\" \
    -DMAX_CYCLES=${MAX_CYCLES} \
    -o "${BUILD_DIR}/${BASENAME}_tb" \
    ${SRC_FILES} \
    ${TB_DIR}/memory_model.v \
    ${TB_DIR}/tb_cpu.v

# Step 3: Run simulation
echo ""
echo "=== Running simulation ==="
cd "${BUILD_DIR}"

if [ ${DUMP_VCD} -eq 1 ]; then
    vvp "${BASENAME}_tb" +vcd 2>&1
    echo ""
    echo "VCD file: ${BUILD_DIR}/cpu_trace.vcd"
else
    if [ ${QUIET} -eq 1 ]; then
        # Only show final state
        vvp "${BASENAME}_tb" 2>&1 | grep -E "(===|FINAL|Cycles|IPC|terminated|FAIL|TRAP|---.*Register)"
    else
        vvp "${BASENAME}_tb" 2>&1
    fi
fi

echo ""
echo "=== Done ==="
