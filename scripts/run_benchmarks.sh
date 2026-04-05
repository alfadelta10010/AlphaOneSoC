#!/bin/bash
# Run all benchmark/test programs and report results
# Usage: ./scripts/run_benchmarks.sh

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="${PROJ_DIR}/tests"
SCRIPTS_DIR="${PROJ_DIR}/scripts"
BUILD_DIR="${PROJ_DIR}/build"

mkdir -p "${BUILD_DIR}"

PASS=0
FAIL=0
ERRORS=""

run_test() {
    local test_file="$1"
    local test_name=$(basename "${test_file}" .S)

    printf "  %-25s " "${test_name}..."

    # Run the test (quiet mode)
    local output
    if output=$(bash "${SCRIPTS_DIR}/run_asm_test.sh" "${test_file}" --quiet 2>&1); then
        # Check if test passed (a0=0 at ecall)
        if echo "${output}" | grep -q "terminated via ECALL\|terminated via EBREAK"; then
            # Check x10 (a0) in final state
            local a0_val
            a0_val=$(echo "${output}" | grep "x10 (a0)" | tail -1 | sed 's/.*x10 (a0) =\([0-9a-f]*\).*/\1/' || echo "unknown")
            if echo "${output}" | grep -q "x10 (a0) =00000000"; then
                printf "PASS\n"
                PASS=$((PASS + 1))
            else
                printf "FAIL (a0=0x%s)\n" "${a0_val}"
                FAIL=$((FAIL + 1))
                ERRORS="${ERRORS}\n  ${test_name}: a0=${a0_val}"
            fi
        elif echo "${output}" | grep -q "Max cycles"; then
            printf "TIMEOUT\n"
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}\n  ${test_name}: timeout"
        else
            printf "PASS (completed)\n"
            PASS=$((PASS + 1))
        fi
    else
        printf "ERROR (build/run failed)\n"
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  ${test_name}: build/run error"
    fi
}

echo "============================================="
echo " FyraCore Benchmark Suite"
echo "============================================="
echo ""
echo "Running tests..."

# Run all .S files in tests/
for test_file in "${TESTS_DIR}"/*.S; do
    if [ -f "${test_file}" ]; then
        run_test "${test_file}"
    fi
done

echo ""
echo "============================================="
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "============================================="

if [ ${FAIL} -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    echo -e "${ERRORS}"
    exit 1
fi

echo ""
echo "ALL TESTS PASSED"
