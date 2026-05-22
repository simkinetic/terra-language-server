#!/bin/bash

# Configuration
EXECUTABLE="./build/src/terra-analyze"
TEST_DIR="./test/ast"
LOG_DIR="./test/logs"

# ANSI Colors for terminal output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Counters
PASSED=0
FAILED=0
TOTAL=0

echo "========================================"
echo "🧪 Running Terra AST Test Suite"
echo "========================================"

# Check if the test directory is empty
if [ -z "$(ls -A "$TEST_DIR"/*.t 2>/dev/null)" ]; then
    echo -e "${YELLOW}No tests found in $TEST_DIR${NC}"
    exit 0
fi

for test_file in "$TEST_DIR"/*.t; do
    TOTAL=$((TOTAL + 1))
    filename=$(basename "$test_file")
    log_file="$LOG_DIR/${filename}.log"

    # Run the analyzer and redirect both stdout and stderr to the log file
    "$EXECUTABLE" "$test_file" > "$log_file" 2>&1
    EXIT_CODE=$?

    # Check for soft errors that our fault-tolerant parser caught but didn't crash on
    SYNTAX_ERRORS=$(grep -m 1 "\[SYNTAX ERRORS" "$log_file")
    SEMANTIC_ERRORS=$(grep -m 1 "\[Semantic Error" "$log_file")

    if [ $EXIT_CODE -eq 0 ] && [ -z "$SYNTAX_ERRORS" ] && [ -z "$SEMANTIC_ERRORS" ]; then
        echo -e "[ ${GREEN}PASS${NC} ] $filename"
        PASSED=$((PASSED + 1))
    else
        echo -e "[ ${RED}FAIL${NC} ] $filename -> Check: $log_file"
        FAILED=$((FAILED + 1))
    fi
done

echo "========================================"
echo -e "Results: ${GREEN}${PASSED} Passed${NC} | ${RED}${FAILED} Failed${NC} | ${TOTAL} Total"
echo "========================================"

# Exit with a standard error code if any tests failed (useful for CI/CD)
if [ "$FAILED" -gt 0 ]; then
    exit 1
else
    exit 0
fi