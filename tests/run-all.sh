#!/usr/bin/env bash
set -euo pipefail

BINARY="${1:?Usage: $0 <git-hunk-binary>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Find all test_*.sh files
TEST_FILES=("$SCRIPT_DIR"/test_*.sh)

echo "Running ${#TEST_FILES[@]} test suites..."

# Run in parallel, collect exit codes
PIDS=()
RESULTS=()
for f in "${TEST_FILES[@]}"; do
    SUITE="$(basename "$f" .sh)"
    bash "$f" "$BINARY" > "/tmp/git-hunk-test-${SUITE}.out" 2>&1 &
    PIDS+=($!)
    RESULTS+=("$SUITE")
done

# Wait and report
EXIT=0
for i in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$i]}"; then
        EXIT=1
        echo "FAIL: ${RESULTS[$i]}" >&2
        cat "/tmp/git-hunk-test-${RESULTS[$i]}.out" >&2
    else
        # Show pass summary from last line
        tail -1 "/tmp/git-hunk-test-${RESULTS[$i]}.out"
    fi
    rm -f "/tmp/git-hunk-test-${RESULTS[$i]}.out"
done

if [[ "$EXIT" -eq 0 ]]; then
    echo ""
    echo "ALL TEST SUITES PASSED (${#TEST_FILES[@]} suites)"
else
    echo ""
    echo "SOME TEST SUITES FAILED" >&2
fi
exit "$EXIT"
