#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 19: count outputs bare integer
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

COUNT19="$("$GIT_HUNK" count)"
[[ "$COUNT19" =~ ^[0-9]+$ ]] || fail "test 19: count output not a bare integer, got '$COUNT19'"
[[ "$COUNT19" -gt 0 ]] || fail "test 19: expected positive count, got '$COUNT19'"
pass "test 19: count outputs bare integer"

# ============================================================================
# Test 20: count --staged returns 0 when nothing staged
# ============================================================================
new_repo

STAGED_COUNT="$("$GIT_HUNK" count --staged)"
[[ "$STAGED_COUNT" == "0" ]] || fail "test 20: expected 0 staged hunks, got '$STAGED_COUNT'"
pass "test 20: count --staged returns 0"

# ============================================================================
# Test 21: count --file filters to one file
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

TOTAL="$("$GIT_HUNK" count)"
FILE_COUNT="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$FILE_COUNT" =~ ^[0-9]+$ ]] || fail "test 21: count --file output not integer, got '$FILE_COUNT'"
[[ "$FILE_COUNT" -gt 0 ]] || fail "test 21: expected positive count for alpha.txt, got '$FILE_COUNT'"
[[ "$FILE_COUNT" -le "$TOTAL" ]] || fail "test 21: file count $FILE_COUNT > total count $TOTAL"
pass "test 21: count --file filters to one file"

# ============================================================================
# Test 22: count returns 0 with exit 0 when no changes in file
# ============================================================================
new_repo

ZERO_COUNT="$("$GIT_HUNK" count --file alpha.txt)"
EXIT22=$?
[[ "$ZERO_COUNT" == "0" ]] || fail "test 22: expected 0 for clean file, got '$ZERO_COUNT'"
[[ "$EXIT22" -eq 0 ]] || fail "test 22: expected exit 0, got $EXIT22"
pass "test 22: count returns 0 with exit 0 when no changes"

# ============================================================================
# Test 60: count includes untracked files
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

COUNT60="$("$GIT_HUNK" count)"
[[ "$COUNT60" -ge 2 ]] || fail "test 60: expected count >= 2 (tracked + untracked), got '$COUNT60'"
pass "test 60: count includes untracked files"

# ============================================================================
# Test 61: count --staged does not include untracked files
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

COUNT61="$("$GIT_HUNK" count --staged)"
[[ "$COUNT61" == "0" ]] || fail "test 61: expected 0 staged count with only untracked, got '$COUNT61'"
pass "test 61: count --staged excludes untracked"

report_results
