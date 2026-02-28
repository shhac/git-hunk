#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 1: porcelain list shows expected fields
# ============================================================================
new_repo
sed -i '' '1s/.*/Modified first line of alpha./' alpha.txt

LINE="$("$GIT_HUNK" list --porcelain --oneline | head -1)"
[[ -n "$LINE" ]] || fail "test 1: expected output from list --porcelain"
SHA="$(echo "$LINE" | cut -f1)"
FILE="$(echo "$LINE" | cut -f2)"
START="$(echo "$LINE" | cut -f3)"
[[ ${#SHA} -eq 7 ]] || fail "test 1: expected 7-char SHA, got '${SHA}'"
[[ "$FILE" == "alpha.txt" ]] || fail "test 1: expected alpha.txt, got '${FILE}'"
[[ "$START" -gt 0 ]] || fail "test 1: expected positive start line, got '${START}'"
pass "test 1: porcelain output format"

# ============================================================================
# Test 4: new file with intent-to-add appears in list
# ============================================================================
new_repo
echo "brand new content" > new_file.txt
git add -N new_file.txt

LINE="$("$GIT_HUNK" list --porcelain --oneline | grep "new_file.txt" || true)"
[[ -n "$LINE" ]] || fail "test 4: new file hunk not listed (try git add -N)"
SHA="$(echo "$LINE" | cut -f1)"
[[ ${#SHA} -eq 7 ]] || fail "test 4: new file SHA not 7 chars"
pass "test 4: new file with intent-to-add listed"

# ============================================================================
# Test 5: deleted file appears in staged list
# ============================================================================
new_repo
git rm alpha.txt -q

DEL_LINE="$("$GIT_HUNK" list --staged --porcelain --oneline | grep "alpha.txt" || true)"
[[ -n "$DEL_LINE" ]] || fail "test 5: deleted file not in staged list"
pass "test 5: deleted file in staged list"

# ============================================================================
# Test 6: --file filter restricts output to matching file
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

FILTERED="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt)"
[[ -n "$FILTERED" ]] || fail "test 6: no output with --file alpha.txt"
while IFS= read -r line; do
    FILE_COL="$(echo "$line" | cut -f2)"
    [[ "$FILE_COL" == "alpha.txt" ]] || fail "test 6: --file filter returned non-matching file '$FILE_COL'"
done <<< "$FILTERED"
echo "$FILTERED" | grep "beta.txt" && fail "test 6: --file filter leaked beta.txt" || true
pass "test 6: --file filter restricts output"

# ============================================================================
# Test 8: human output contains 7-char SHA and file name
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

HUMAN="$("$GIT_HUNK" list 2>/dev/null | head -1)"
[[ -n "$HUMAN" ]] || fail "test 8: empty human output"
FIRST_TOKEN="$(echo "$HUMAN" | awk '{print $1}')"
[[ ${#FIRST_TOKEN} -eq 7 ]] || fail "test 8: first token not 7 chars: '${FIRST_TOKEN}'"
pass "test 8: human output format"

# ============================================================================
# Test 50: untracked file appears in list output
# ============================================================================
new_repo
echo "brand new untracked content" > untracked.txt

LINE50="$("$GIT_HUNK" list --porcelain --oneline | grep "untracked.txt" || true)"
[[ -n "$LINE50" ]] || fail "test 50: untracked file not shown in list"
SHA50="$(echo "$LINE50" | cut -f1)"
[[ ${#SHA50} -eq 7 ]] || fail "test 50: untracked SHA not 7 chars"
pass "test 50: untracked file appears in list"

# ============================================================================
# Test 51: untracked file does NOT appear in list --staged
# ============================================================================
new_repo
echo "brand new untracked content" > untracked.txt

STAGED51="$("$GIT_HUNK" list --staged --porcelain --oneline 2>/dev/null | grep "untracked.txt" || true)"
[[ -z "$STAGED51" ]] || fail "test 51: untracked file should not appear in --staged list"
pass "test 51: untracked file not in staged list"

# ============================================================================
# Test 52: untracked file hint no longer shown
# ============================================================================
new_repo
echo "some content" > untracked.txt

STDERR52="$("$GIT_HUNK" list --no-color 2>&1 >/dev/null || true)"
echo "$STDERR52" | grep -q "untracked file(s) not shown" && fail "test 52: old untracked hint still showing" || true
pass "test 52: old untracked hint removed"

# ============================================================================
# Test 53: --file filter works with untracked files
# ============================================================================
new_repo
echo "untracked alpha" > untracked_a.txt
echo "untracked beta" > untracked_b.txt

FILTERED53="$("$GIT_HUNK" list --porcelain --oneline --file untracked_a.txt)"
[[ -n "$FILTERED53" ]] || fail "test 53: no output with --file untracked_a.txt"
echo "$FILTERED53" | grep "untracked_b.txt" && fail "test 53: --file leaked untracked_b.txt" || true
pass "test 53: --file filter works with untracked files"

new_repo
echo "unique_marker_for_show_test" > untracked_show.txt

SHA57="$("$GIT_HUNK" list --porcelain --oneline --file untracked_show.txt | head -1 | cut -f1)"
[[ -n "$SHA57" ]] || fail "test 57: no untracked hunk found"
SHOW_OUT="$("$GIT_HUNK" show --no-color "$SHA57")"
echo "$SHOW_OUT" | grep -q "unique_marker_for_show_test" \
    || fail "test 57: show output missing file content, got: '$SHOW_OUT'"
echo "$SHOW_OUT" | grep -qE '(new file|@@)' \
    || fail "test 57: show output missing new file or @@ header, got: '$SHOW_OUT'"
pass "test 57: show displays untracked file content"

report_results
