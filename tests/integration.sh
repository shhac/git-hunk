#!/usr/bin/env bash
# Integration tests for git-hunk. Run via: zig build test-integration
# Requires the binary to already be built (zig build installs it first).
set -euo pipefail

GIT_HUNK="${1:-./zig-out/bin/git-hunk}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

pass() {
    echo "PASS: $1"
}

# Create a temporary git repo for all tests.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"

git init -q
git config user.email "test@git-hunk.test"
git config user.name "git-hunk test"

# ============================================================================
# Test 1: porcelain list shows expected fields
# ============================================================================
echo "hello world" > file.txt
git add file.txt
git commit -m "init" -q
echo "hello changed" > file.txt

LINE="$("$GIT_HUNK" list --porcelain)"
[[ -n "$LINE" ]] || fail "test 1: expected output from list --porcelain"

SHA="$(echo "$LINE" | cut -f1)"
FILE="$(echo "$LINE" | cut -f2)"
START="$(echo "$LINE" | cut -f3)"
[[ ${#SHA} -eq 7 ]] || fail "test 1: expected 7-char SHA, got '${SHA}'"
[[ "$FILE" == "file.txt" ]] || fail "test 1: expected file.txt, got '${FILE}'"
[[ "$START" -gt 0 ]] || fail "test 1: expected positive start line, got '${START}'"
pass "test 1: porcelain output format"

# ============================================================================
# Test 2: add (stage) a hunk by SHA
# ============================================================================
"$GIT_HUNK" add "$SHA" > /dev/null
STAGED_LINES="$(git diff --cached file.txt | wc -l | tr -d ' ')"
[[ "$STAGED_LINES" -gt 0 ]] || fail "test 2: hunk was not staged"
pass "test 2: add stages hunk"

# ============================================================================
# Test 3: remove (unstage) a hunk by SHA
# ============================================================================
STAGED_SHA="$("$GIT_HUNK" list --staged --porcelain | cut -f1)"
[[ -n "$STAGED_SHA" ]] || fail "test 3: no staged hunk found"
"$GIT_HUNK" remove "$STAGED_SHA" > /dev/null
STILL_STAGED="$(git diff --cached file.txt | wc -l | tr -d ' ')"
[[ "$STILL_STAGED" -eq 0 ]] || fail "test 3: hunk was not unstaged"
pass "test 3: remove unstages hunk"

# ============================================================================
# Test 4: new file with intent-to-add appears in list
# ============================================================================
echo "brand new content" > new_file.txt
git add -N new_file.txt   # intent-to-add: shows in git diff
LINE4="$("$GIT_HUNK" list --porcelain | grep "new_file.txt" || true)"
[[ -n "$LINE4" ]] || fail "test 4: new file hunk not listed (try git add -N)"
SHA4="$(echo "$LINE4" | cut -f1)"
[[ ${#SHA4} -eq 7 ]] || fail "test 4: new file SHA not 7 chars"
pass "test 4: new file with intent-to-add listed"

# ============================================================================
# Test 5: deleted file appears in staged list
# ============================================================================
git add file.txt
git commit -m "stage modified" -q
git rm file.txt -q
DEL_LINE="$("$GIT_HUNK" list --staged --porcelain | grep "file.txt" || true)"
[[ -n "$DEL_LINE" ]] || fail "test 5: deleted file not in staged list"
pass "test 5: deleted file in staged list"

# ============================================================================
# Test 6: --file filter restricts output to matching file
# ============================================================================
git reset HEAD file.txt -q 2>/dev/null || git checkout HEAD -- file.txt 2>/dev/null || true
git add new_file.txt
git commit -m "clean up" -q
echo "change a" > alpha.txt
echo "change b" > beta.txt
git add alpha.txt beta.txt
git commit -m "add alpha beta" -q
echo "alpha changed" > alpha.txt
echo "beta changed" > beta.txt

ALL_OUTPUT="$("$GIT_HUNK" list --porcelain)"
FILTERED="$("$GIT_HUNK" list --porcelain --file alpha.txt)"
[[ -n "$FILTERED" ]] || fail "test 6: no output with --file alpha.txt"
# All filtered lines must reference alpha.txt
while IFS= read -r line; do
    FILE_COL="$(echo "$line" | cut -f2)"
    [[ "$FILE_COL" == "alpha.txt" ]] || fail "test 6: --file filter returned non-matching file '$FILE_COL'"
done <<< "$FILTERED"
# Filtered output should not include beta.txt
echo "$FILTERED" | grep "beta.txt" && fail "test 6: --file filter leaked beta.txt" || true
pass "test 6: --file filter restricts output"

# ============================================================================
# Test 7: --all stages all unstaged hunks
# ============================================================================
BEFORE_STAGED="$(git diff --cached | wc -l | tr -d ' ')"
"$GIT_HUNK" add --all > /dev/null
AFTER_STAGED="$(git diff --cached | wc -l | tr -d ' ')"
[[ "$AFTER_STAGED" -gt "$BEFORE_STAGED" ]] || fail "test 7: --all did not stage any hunks"
pass "test 7: --all stages all hunks"

# ============================================================================
# Test 8: human output contains 7-char SHA and file name
# ============================================================================
git reset HEAD -q 2>/dev/null || true
echo "yet another change" >> alpha.txt
HUMAN="$("$GIT_HUNK" list 2>/dev/null | head -1)"
[[ -n "$HUMAN" ]] || fail "test 8: empty human output"
FIRST_TOKEN="$(echo "$HUMAN" | awk '{print $1}')"
[[ ${#FIRST_TOKEN} -eq 7 ]] || fail "test 8: first token not 7 chars: '${FIRST_TOKEN}'"
pass "test 8: human output format"

echo ""
echo "ALL INTEGRATION TESTS PASSED (9 tests)"
