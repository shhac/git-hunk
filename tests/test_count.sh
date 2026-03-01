#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 400: count outputs bare integer
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

COUNT400="$("$GIT_HUNK" count)"
[[ "$COUNT400" =~ ^[0-9]+$ ]] || fail "test 400: count output not a bare integer, got '$COUNT400'"
[[ "$COUNT400" -gt 0 ]] || fail "test 400: expected positive count, got '$COUNT400'"
pass "test 400: count outputs bare integer"

# ============================================================================
# Test 401: count --staged returns 0 when nothing staged
# ============================================================================
new_repo

STAGED_COUNT="$("$GIT_HUNK" count --staged)"
[[ "$STAGED_COUNT" == "0" ]] || fail "test 401: expected 0 staged hunks, got '$STAGED_COUNT'"
pass "test 401: count --staged returns 0"

# ============================================================================
# Test 402: count --file filters to one file
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

TOTAL="$("$GIT_HUNK" count)"
FILE_COUNT="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$FILE_COUNT" =~ ^[0-9]+$ ]] || fail "test 402: count --file output not integer, got '$FILE_COUNT'"
[[ "$FILE_COUNT" -gt 0 ]] || fail "test 402: expected positive count for alpha.txt, got '$FILE_COUNT'"
[[ "$FILE_COUNT" -le "$TOTAL" ]] || fail "test 402: file count $FILE_COUNT > total count $TOTAL"
pass "test 402: count --file filters to one file"

# ============================================================================
# Test 403: count returns 0 with exit 0 when no changes in file
# ============================================================================
new_repo

ZERO_COUNT="$("$GIT_HUNK" count --file alpha.txt)"
EXIT403=$?
[[ "$ZERO_COUNT" == "0" ]] || fail "test 403: expected 0 for clean file, got '$ZERO_COUNT'"
[[ "$EXIT403" -eq 0 ]] || fail "test 403: expected exit 0, got $EXIT403"
pass "test 403: count returns 0 with exit 0 when no changes"

# ============================================================================
# Test 404: count includes untracked files
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

COUNT404="$("$GIT_HUNK" count)"
[[ "$COUNT404" -ge 2 ]] || fail "test 404: expected count >= 2 (tracked + untracked), got '$COUNT404'"
pass "test 404: count includes untracked files"

# ============================================================================
# Test 405: count --staged does not include untracked files
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

COUNT405="$("$GIT_HUNK" count --staged)"
[[ "$COUNT405" == "0" ]] || fail "test 405: expected 0 staged count with only untracked, got '$COUNT405'"
pass "test 405: count --staged excludes untracked"

# ============================================================================
# Test 406: count --tracked-only + --untracked-only sum equals total
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked_count.txt

TOTAL406="$("$GIT_HUNK" count)"
TRACKED406="$("$GIT_HUNK" count --tracked-only)"
UNTRACKED406="$("$GIT_HUNK" count --untracked-only)"
SUM406=$((TRACKED406 + UNTRACKED406))
[[ "$SUM406" -eq "$TOTAL406" ]] \
    || fail "test 406: tracked ($TRACKED406) + untracked ($UNTRACKED406) = $SUM406, expected $TOTAL406"
pass "test 406: count --tracked-only + --untracked-only equals total"

# ============================================================================
# Test 407: count --untracked-only with no untracked files returns 0
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

COUNT407="$("$GIT_HUNK" count --untracked-only)"
[[ "$COUNT407" == "0" ]] || fail "test 407: expected 0 untracked count, got '$COUNT407'"
pass "test 407: count --untracked-only with no untracked files returns 0"

report_results
