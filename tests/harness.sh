#!/usr/bin/env bash
# Shared test utilities sourced by each test_*.sh script.
# Usage: source "$(dirname "$0")/harness.sh" "$1"
set -euo pipefail

GIT_HUNK="${1:?Usage: $0 <git-hunk-binary>}"
GIT_HUNK="$(cd "$(dirname "$GIT_HUNK")" && pwd)/$(basename "$GIT_HUNK")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
SETUP="$SCRIPT_DIR/setup-repo.sh"
MANPAGE="$SCRIPT_DIR/../doc/git-hunk.1"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_REPO=""

fail() { echo "FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup_repo() {
    if [[ -n "$CURRENT_REPO" && -d "$CURRENT_REPO" ]]; then
        cd /
        rm -rf "$CURRENT_REPO"
    fi
    CURRENT_REPO=""
}
trap cleanup_repo EXIT

new_repo() {
    cleanup_repo
    CURRENT_REPO="$(bash "$SETUP")"
    cd "$CURRENT_REPO"
}

# Call at end of each test script:
report_results() {
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        echo "FAILED: $FAIL_COUNT failures, $PASS_COUNT passed" >&2
        exit 1
    fi
    echo "OK: $PASS_COUNT passed"
    exit 0
}
