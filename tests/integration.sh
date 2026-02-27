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

LINE="$("$GIT_HUNK" list --porcelain --oneline | head -1)"
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
STAGED_SHA="$("$GIT_HUNK" list --staged --porcelain --oneline | cut -f1)"
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
LINE4="$("$GIT_HUNK" list --porcelain --oneline | grep "new_file.txt" || true)"
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
DEL_LINE="$("$GIT_HUNK" list --staged --porcelain --oneline | grep "file.txt" || true)"
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

ALL_OUTPUT="$("$GIT_HUNK" list --porcelain --oneline)"
FILTERED="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt)"
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

# ============================================================================
# Test 9: add output shows staged HASH → HASH  FILE format
# ============================================================================
git reset HEAD -q 2>/dev/null || true
echo "simple staging test" > simple.txt
git add simple.txt
git commit -m "add simple.txt" -q
echo "simple staging changed" > simple.txt

SHA9="$("$GIT_HUNK" list --porcelain --oneline | grep "simple.txt" | cut -f1)"
[[ -n "$SHA9" ]] || fail "test 9: no unstaged hunk found"
ADD_OUT="$("$GIT_HUNK" add --no-color "$SHA9")"
# Should match: staged <7char> → <7char>  simple.txt
echo "$ADD_OUT" | grep -qE '^staged [a-f0-9]{7} → [a-f0-9]{7}  simple\.txt$' \
    || fail "test 9: output didn't match expected format, got: '$ADD_OUT'"
pass "test 9: add output format (simple 1→1)"

# ============================================================================
# Test 10: remove output shows unstaged HASH → HASH  FILE format
# ============================================================================
STAGED_SHA10="$("$GIT_HUNK" list --staged --porcelain --oneline | grep "simple.txt" | cut -f1)"
[[ -n "$STAGED_SHA10" ]] || fail "test 10: no staged hunk found"
REM_OUT="$("$GIT_HUNK" remove --no-color "$STAGED_SHA10")"
echo "$REM_OUT" | grep -qE '^unstaged [a-f0-9]{7} → [a-f0-9]{7}  simple\.txt$' \
    || fail "test 10: remove output didn't match expected format, got: '$REM_OUT'"
pass "test 10: remove output format (simple 1→1)"

# ============================================================================
# Test 11: overlap/merge case shows consumed hash with + prefix
# ============================================================================
# Stage first hunk, then modify same area to create overlap
echo "simple staging changed" > simple.txt
SHA11A="$("$GIT_HUNK" list --porcelain --oneline | grep "simple.txt" | cut -f1)"
[[ -n "$SHA11A" ]] || fail "test 11: no unstaged hunk A found"
"$GIT_HUNK" add --no-color "$SHA11A" > /dev/null

# Modify file within same area to create a new unstaged hunk that overlaps
echo "simple staging changed again" > simple.txt
SHA11B="$("$GIT_HUNK" list --porcelain --oneline | grep "simple.txt" | cut -f1)"
[[ -n "$SHA11B" ]] || fail "test 11: no unstaged hunk B found"
MERGE_OUT="$("$GIT_HUNK" add --no-color "$SHA11B")"
# Should show consumed hash with + prefix: staged <hash_B> +<hash_A> → <result>  simple.txt
echo "$MERGE_OUT" | grep -qE '^staged [a-f0-9]{7} \+[a-f0-9]{7} → [a-f0-9]{7}  simple\.txt$' \
    || fail "test 11: merge output didn't show consumed hash, got: '$MERGE_OUT'"
pass "test 11: overlap/merge shows consumed hash"

# ============================================================================
# Test 12: porcelain format for add is tab-separated
# ============================================================================
git reset HEAD -q 2>/dev/null || true
echo "porcelain test line" > simple.txt
SHA12="$("$GIT_HUNK" list --porcelain --oneline | grep "simple.txt" | cut -f1)"
[[ -n "$SHA12" ]] || fail "test 12: no unstaged hunk found"
PORC_OUT="$("$GIT_HUNK" add --porcelain "$SHA12")"
# Porcelain: staged\t{applied}\t{result}\t{file}
PORC_VERB="$(echo "$PORC_OUT" | cut -f1)"
PORC_APPLIED="$(echo "$PORC_OUT" | cut -f2)"
PORC_RESULT="$(echo "$PORC_OUT" | cut -f3)"
PORC_FILE="$(echo "$PORC_OUT" | cut -f4)"
[[ "$PORC_VERB" == "staged" ]] || fail "test 12: porcelain verb not 'staged', got '$PORC_VERB'"
[[ ${#PORC_APPLIED} -eq 7 ]] || fail "test 12: porcelain applied hash not 7 chars, got '$PORC_APPLIED'"
[[ ${#PORC_RESULT} -eq 7 ]] || fail "test 12: porcelain result hash not 7 chars, got '$PORC_RESULT'"
[[ "$PORC_FILE" == "simple.txt" ]] || fail "test 12: porcelain file not 'simple.txt', got '$PORC_FILE'"
pass "test 12: porcelain format for add"

# ============================================================================
# Test 13: porcelain format for add with merge includes consumed field
# ============================================================================
# File is staged from test 12. Modify again to create overlap.
echo "porcelain merge test line" > simple.txt
SHA13="$("$GIT_HUNK" list --porcelain --oneline | grep "simple.txt" | cut -f1)"
[[ -n "$SHA13" ]] || fail "test 13: no unstaged hunk found"
PORC_MERGE="$("$GIT_HUNK" add --porcelain "$SHA13")"
# Should have 5 tab-separated fields when consumed hash exists
FIELD_COUNT="$(echo "$PORC_MERGE" | awk -F'\t' '{print NF}')"
[[ "$FIELD_COUNT" -eq 5 ]] || fail "test 13: expected 5 tab fields for merge, got $FIELD_COUNT in: '$PORC_MERGE'"
CONSUMED_FIELD="$(echo "$PORC_MERGE" | cut -f5)"
[[ ${#CONSUMED_FIELD} -eq 7 ]] || fail "test 13: consumed hash not 7 chars, got '$CONSUMED_FIELD'"
pass "test 13: porcelain format includes consumed field on merge"

# ============================================================================
# Test 14: summary line shows merged count on stderr
# ============================================================================
git reset HEAD -q 2>/dev/null || true
echo "summary merge A" > simple.txt
SHA14A="$("$GIT_HUNK" list --porcelain --oneline | grep "simple.txt" | cut -f1)"
"$GIT_HUNK" add --no-color "$SHA14A" > /dev/null 2>/dev/null
echo "summary merge B" > simple.txt
SHA14B="$("$GIT_HUNK" list --porcelain --oneline | grep "simple.txt" | cut -f1)"
# Capture stderr to check summary
STDERR14="$("$GIT_HUNK" add --no-color "$SHA14B" 2>&1 >/dev/null)"
echo "$STDERR14" | grep -qE '\(.*merged\)' \
    || fail "test 14: summary stderr didn't show merged count, got: '$STDERR14'"
pass "test 14: summary line shows merged count"

# ============================================================================
# Test 15: batch add of multiple hunks in different files
# ============================================================================
git reset HEAD -q 2>/dev/null || true
echo "batch alpha" > alpha.txt
echo "batch beta" > beta.txt
SHAS15="$("$GIT_HUNK" list --porcelain --oneline)"
SHA15A="$(echo "$SHAS15" | grep "alpha.txt" | cut -f1)"
SHA15B="$(echo "$SHAS15" | grep "beta.txt" | cut -f1)"
[[ -n "$SHA15A" && -n "$SHA15B" ]] || fail "test 15: couldn't find both hunks"
BATCH_OUT="$("$GIT_HUNK" add --no-color "$SHA15A" "$SHA15B")"
# Should produce two lines, one per file
LINE_COUNT="$(echo "$BATCH_OUT" | wc -l | tr -d ' ')"
[[ "$LINE_COUNT" -eq 2 ]] || fail "test 15: expected 2 output lines for batch, got $LINE_COUNT"
echo "$BATCH_OUT" | grep -qE 'staged .* alpha\.txt' || fail "test 15: missing alpha.txt in output"
echo "$BATCH_OUT" | grep -qE 'staged .* beta\.txt' || fail "test 15: missing beta.txt in output"
pass "test 15: batch add produces per-file output"

# ============================================================================
# Test 16: arrow is always present in add output (even simple case)
# ============================================================================
git reset HEAD -q 2>/dev/null || true
echo "arrow always present" > simple.txt
SHA16="$("$GIT_HUNK" list --porcelain --oneline | grep "simple.txt" | cut -f1)"
[[ -n "$SHA16" ]] || fail "test 16: no unstaged hunk found"
ARROW_OUT="$("$GIT_HUNK" add --no-color "$SHA16")"
echo "$ARROW_OUT" | grep -q '→' \
    || fail "test 16: arrow missing from output, got: '$ARROW_OUT'"
pass "test 16: arrow always present in add output"

# ============================================================================
# Test 17: bridge case — staging middle hunk consumes outer staged hunks
# ============================================================================
# Strategy: changes at lines 4 and 6 with a gap at line 5. With --context 0,
# these are 2 separate hunks. Stage both, then modify and stage line 5. The
# three adjacent changes merge into one hunk, consuming the two original ones.
git reset HEAD -q 2>/dev/null || true
cat > bridge.txt <<'BRIDGE_EOF'
line 1
line 2
line 3
line 4 original
line 5 gap
line 6 original
line 7
line 8
line 9
line 10
BRIDGE_EOF
git add bridge.txt
git commit -m "add bridge.txt" -q

# Change lines 4 and 6 (with line 5 unchanged between them)
sed -i '' 's/line 4 original/line 4 changed/' bridge.txt
sed -i '' 's/line 6 original/line 6 changed/' bridge.txt

# With --context 0 these should be 2 separate hunks
BRIDGE_HUNKS="$("$GIT_HUNK" list --porcelain --oneline --context 0 2>/dev/null | grep "bridge.txt")"
BRIDGE_COUNT="$(echo "$BRIDGE_HUNKS" | wc -l | tr -d ' ')"
[[ "$BRIDGE_COUNT" -eq 2 ]] || fail "test 17: expected 2 hunks with --context 0, got $BRIDGE_COUNT"

SHA17_A="$(echo "$BRIDGE_HUNKS" | sort -t$'\t' -k3 -n | head -1 | cut -f1)"
SHA17_B="$(echo "$BRIDGE_HUNKS" | sort -t$'\t' -k3 -n | tail -1 | cut -f1)"

# Stage both outer hunks
"$GIT_HUNK" add --no-color --context 0 "$SHA17_A" "$SHA17_B" > /dev/null 2>/dev/null

# Now modify line 5 (the gap) — creates a new unstaged hunk that bridges the two
sed -i '' 's/line 5 gap/line 5 changed/' bridge.txt
SHA17_MID="$("$GIT_HUNK" list --porcelain --oneline --context 0 2>/dev/null | grep "bridge.txt" | cut -f1)"
[[ -n "$SHA17_MID" ]] || fail "test 17: no gap hunk found after modifying line 5"

# Stage the bridge — should consume the two outer staged hunks
BRIDGE_OUT="$("$GIT_HUNK" add --no-color --context 0 "$SHA17_MID" 2>/dev/null)"
# Should show consumed hashes: staged <middle> +<outer1> +<outer2> → <result>  bridge.txt
CONSUMED_COUNT="$(echo "$BRIDGE_OUT" | grep -oE '\+[a-f0-9]{7}' | wc -l | tr -d ' ')"
[[ "$CONSUMED_COUNT" -eq 2 ]] \
    || fail "test 17: bridge expected 2 consumed hashes, got $CONSUMED_COUNT in: '$BRIDGE_OUT'"
echo "$BRIDGE_OUT" | grep -qE '→ [a-f0-9]{7}  bridge\.txt' \
    || fail "test 17: bridge output missing result hash, got: '$BRIDGE_OUT'"
pass "test 17: bridge case shows 2 consumed hashes"

# ============================================================================
# Test 18: batch add with pre-existing staged hunk causes merge
# ============================================================================
# Strategy: stage a hunk, then batch-add two more adjacent hunks that bridge
# across it, causing all three to merge. This tests multiple applied + consumed.
git reset HEAD -q 2>/dev/null || true
cat > batch.txt <<'BATCH_EOF'
line 1
line 2
line 3 original
line 4 gap
line 5 original
line 6
line 7
line 8
BATCH_EOF
git add batch.txt
git commit -m "add batch.txt" -q

# Change line 4 (the middle) and stage it first
sed -i '' 's/line 4 gap/line 4 changed/' batch.txt
SHA18_PRE="$("$GIT_HUNK" list --porcelain --oneline --context 0 2>/dev/null | grep "batch.txt" | cut -f1)"
[[ -n "$SHA18_PRE" ]] || fail "test 18: no hunk found for line 4"
"$GIT_HUNK" add --no-color --context 0 "$SHA18_PRE" > /dev/null 2>/dev/null

# Now change lines 3 and 5 (flanking the staged change)
sed -i '' 's/line 3 original/line 3 changed/' batch.txt
sed -i '' 's/line 5 original/line 5 changed/' batch.txt

BATCH_HUNKS="$("$GIT_HUNK" list --porcelain --oneline --context 0 2>/dev/null | grep "batch.txt")"
BATCH_COUNT="$(echo "$BATCH_HUNKS" | wc -l | tr -d ' ')"
[[ "$BATCH_COUNT" -eq 2 ]] || fail "test 18: expected 2 unstaged hunks, got $BATCH_COUNT"

SHA18_A="$(echo "$BATCH_HUNKS" | sort -t$'\t' -k3 -n | head -1 | cut -f1)"
SHA18_B="$(echo "$BATCH_HUNKS" | sort -t$'\t' -k3 -n | tail -1 | cut -f1)"

# Batch-add both flanking hunks — they should merge with the pre-existing staged hunk
BATCH_OUT="$("$GIT_HUNK" add --no-color --context 0 "$SHA18_A" "$SHA18_B" 2>/dev/null)"
# Should show: staged <sha_A> <sha_B> +<pre_staged> → <result>  batch.txt
# (one line with 2 applied hashes, 1 consumed hash, 1 result)
BATCH_LINES="$(echo "$BATCH_OUT" | wc -l | tr -d ' ')"
[[ "$BATCH_LINES" -eq 1 ]] \
    || fail "test 18: expected 1 output line (merged), got $BATCH_LINES in: '$BATCH_OUT'"
echo "$BATCH_OUT" | grep -qE '\+[a-f0-9]{7}' \
    || fail "test 18: batch output missing consumed hash, got: '$BATCH_OUT'"
# Verify both applied SHAs appear in the output
echo "$BATCH_OUT" | grep -q "$SHA18_A" \
    || fail "test 18: output missing first applied hash $SHA18_A, got: '$BATCH_OUT'"
echo "$BATCH_OUT" | grep -q "$SHA18_B" \
    || fail "test 18: output missing second applied hash $SHA18_B, got: '$BATCH_OUT'"
pass "test 18: batch add with merge — two applied + one consumed"

# ============================================================================
# Test 19: count outputs bare integer
# ============================================================================
git reset HEAD -q 2>/dev/null || true
echo "count test alpha" > alpha.txt
echo "count test beta" > beta.txt
COUNT19="$("$GIT_HUNK" count)"
# Must be a bare integer (no labels, no padding)
[[ "$COUNT19" =~ ^[0-9]+$ ]] || fail "test 19: count output not a bare integer, got '$COUNT19'"
[[ "$COUNT19" -gt 0 ]] || fail "test 19: expected positive count, got '$COUNT19'"
pass "test 19: count outputs bare integer"

# ============================================================================
# Test 20: count --staged returns 0 when nothing staged
# ============================================================================
STAGED_COUNT="$("$GIT_HUNK" count --staged)"
[[ "$STAGED_COUNT" == "0" ]] || fail "test 20: expected 0 staged hunks, got '$STAGED_COUNT'"
pass "test 20: count --staged returns 0"

# ============================================================================
# Test 21: count --file filters to one file
# ============================================================================
FILE_COUNT="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$FILE_COUNT" =~ ^[0-9]+$ ]] || fail "test 21: count --file output not integer, got '$FILE_COUNT'"
[[ "$FILE_COUNT" -gt 0 ]] || fail "test 21: expected positive count for alpha.txt, got '$FILE_COUNT'"
# File-filtered count should be less than or equal to total
[[ "$FILE_COUNT" -le "$COUNT19" ]] || fail "test 21: file count $FILE_COUNT > total count $COUNT19"
pass "test 21: count --file filters to one file"

# ============================================================================
# Test 22: count returns 0 with exit 0 when no changes in file
# ============================================================================
git add alpha.txt beta.txt
git commit -m "commit for count test" -q
ZERO_COUNT="$("$GIT_HUNK" count --file alpha.txt)"
EXIT22=$?
[[ "$ZERO_COUNT" == "0" ]] || fail "test 22: expected 0 for committed file, got '$ZERO_COUNT'"
[[ "$EXIT22" -eq 0 ]] || fail "test 22: expected exit 0, got $EXIT22"
pass "test 22: count returns 0 with exit 0 when no changes"

# ============================================================================
# Test 23: check with valid hashes exits 0 (silent success)
# ============================================================================
echo "check test alpha" > alpha.txt
echo "check test beta" > beta.txt
SHAS23="$("$GIT_HUNK" list --porcelain --oneline)"
SHA23A="$(echo "$SHAS23" | grep "alpha.txt" | cut -f1)"
SHA23B="$(echo "$SHAS23" | grep "beta.txt" | cut -f1)"
[[ -n "$SHA23A" && -n "$SHA23B" ]] || fail "test 23: couldn't find both hunks"
OUT23="$("$GIT_HUNK" check "$SHA23A" "$SHA23B" 2>/dev/null)"
[[ -z "$OUT23" ]] || fail "test 23: expected no stdout on success, got '$OUT23'"
pass "test 23: check with valid hashes exits 0"

# ============================================================================
# Test 24: check with stale hash exits 1
# ============================================================================
if OUT24="$("$GIT_HUNK" check --no-color "deadbeef" 2>/dev/null)"; then
    fail "test 24: expected exit 1, got 0"
fi
echo "$OUT24" | grep -q "stale" || fail "test 24: expected 'stale' in output, got '$OUT24'"
pass "test 24: check with stale hash exits 1"

# ============================================================================
# Test 25: check --exclusive with exact set exits 0
# ============================================================================
ALL_ALPHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | cut -f1)"
[[ -n "$ALL_ALPHA" ]] || fail "test 25: no alpha.txt hunks found"
# shellcheck disable=SC2086
"$GIT_HUNK" check --exclusive --file alpha.txt $ALL_ALPHA > /dev/null 2>/dev/null
pass "test 25: check --exclusive with exact set exits 0"

# ============================================================================
# Test 26: check --exclusive with extra hunks exits 1
# ============================================================================
# Only pass alpha hash but check exclusive globally — beta hunks are unexpected
if OUT26="$("$GIT_HUNK" check --no-color --exclusive "$SHA23A" 2>/dev/null)"; then
    fail "test 26: expected exit 1 for exclusive with extras"
fi
echo "$OUT26" | grep -q "unexpected" || fail "test 26: expected 'unexpected' in output, got '$OUT26'"
pass "test 26: check --exclusive with extra hunks exits 1"

# ============================================================================
# Test 27: check --porcelain reports both ok and stale entries
# ============================================================================
if PORC27="$("$GIT_HUNK" check --porcelain "$SHA23A" "deadbeef" 2>/dev/null)"; then
    fail "test 27: expected exit 1"
fi
echo "$PORC27" | grep -qE '^ok	' || fail "test 27: expected 'ok' line in porcelain, got '$PORC27'"
echo "$PORC27" | grep -qE '^stale	' || fail "test 27: expected 'stale' line in porcelain, got '$PORC27'"
pass "test 27: check --porcelain reports all entries"

# ============================================================================
# Test 28: check rejects line specs
# ============================================================================
if "$GIT_HUNK" check "${SHA23A}:1-3" > /dev/null 2>/dev/null; then
    fail "test 28: expected exit 1 for line spec"
fi
pass "test 28: check rejects line specs"

# ============================================================================
# Test 29: discard reverts a single unstaged hunk
# ============================================================================
git reset HEAD -q 2>/dev/null || true
git add alpha.txt beta.txt 2>/dev/null || true
git commit -m "commit for discard tests" -q 2>/dev/null || true
echo "discard test alpha" > alpha.txt
SHA29="$("$GIT_HUNK" list --porcelain --oneline | grep "alpha.txt" | cut -f1)"
[[ -n "$SHA29" ]] || fail "test 29: no unstaged hunk found"
"$GIT_HUNK" discard --no-color "$SHA29" > /dev/null
# After discard, file should match committed version (no unstaged changes)
REMAINING29="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING29" == "0" ]] || fail "test 29: expected 0 unstaged hunks after discard, got '$REMAINING29'"
pass "test 29: discard reverts single hunk"

# ============================================================================
# Test 30: discard --all reverts all unstaged hunks
# ============================================================================
echo "discard all alpha" > alpha.txt
echo "discard all beta" > beta.txt
COUNT30_BEFORE="$("$GIT_HUNK" count)"
[[ "$COUNT30_BEFORE" -gt 0 ]] || fail "test 30: expected unstaged hunks before discard --all"
"$GIT_HUNK" discard --all > /dev/null
COUNT30_AFTER="$("$GIT_HUNK" count)"
[[ "$COUNT30_AFTER" == "0" ]] || fail "test 30: expected 0 unstaged hunks after discard --all, got '$COUNT30_AFTER'"
pass "test 30: discard --all reverts all hunks"

# ============================================================================
# Test 31: discard --dry-run does NOT modify worktree
# ============================================================================
echo "dry run test" > alpha.txt
SHA31="$("$GIT_HUNK" list --porcelain --oneline | grep "alpha.txt" | cut -f1)"
[[ -n "$SHA31" ]] || fail "test 31: no unstaged hunk found"
DRY_OUT="$("$GIT_HUNK" discard --no-color --dry-run "$SHA31")"
echo "$DRY_OUT" | grep -q "would discard" || fail "test 31: expected 'would discard' in output, got '$DRY_OUT'"
# File should still have changes (dry-run doesn't modify)
REMAINING31="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING31" -gt 0 ]] || fail "test 31: dry-run should not have modified worktree"
pass "test 31: discard --dry-run does not modify worktree"

# ============================================================================
# Test 32: discard output format (human mode)
# ============================================================================
DISCARD_OUT="$("$GIT_HUNK" discard --no-color "$SHA31")"
echo "$DISCARD_OUT" | grep -qE '^discarded [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 32: discard output format wrong, got: '$DISCARD_OUT'"
pass "test 32: discard output format"

# ============================================================================
# Test 33: discard --porcelain output is tab-separated
# ============================================================================
echo "porcelain discard" > alpha.txt
SHA33="$("$GIT_HUNK" list --porcelain --oneline | grep "alpha.txt" | cut -f1)"
[[ -n "$SHA33" ]] || fail "test 33: no unstaged hunk found"
PORC33="$("$GIT_HUNK" discard --porcelain "$SHA33")"
PORC33_VERB="$(echo "$PORC33" | cut -f1)"
PORC33_SHA="$(echo "$PORC33" | cut -f2)"
PORC33_FILE="$(echo "$PORC33" | cut -f3)"
[[ "$PORC33_VERB" == "discarded" ]] || fail "test 33: porcelain verb not 'discarded', got '$PORC33_VERB'"
[[ ${#PORC33_SHA} -eq 7 ]] || fail "test 33: porcelain sha not 7 chars, got '$PORC33_SHA'"
[[ "$PORC33_FILE" == "alpha.txt" ]] || fail "test 33: porcelain file not 'alpha.txt', got '$PORC33_FILE'"
pass "test 33: discard --porcelain output format"

# ============================================================================
# Test 34: discard preserves staged changes
# ============================================================================
echo "staged content" > alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED34_BEFORE="$("$GIT_HUNK" count --staged)"
echo "additional unstaged change" > alpha.txt
"$GIT_HUNK" discard --all > /dev/null
STAGED34_AFTER="$("$GIT_HUNK" count --staged)"
[[ "$STAGED34_BEFORE" == "$STAGED34_AFTER" ]] \
    || fail "test 34: discard should not affect staged changes (before=$STAGED34_BEFORE, after=$STAGED34_AFTER)"
pass "test 34: discard preserves staged changes"

# ============================================================================
# Test 35: discard --file only discards hunks in specified file
# ============================================================================
git reset HEAD -q 2>/dev/null || true
git add alpha.txt 2>/dev/null || true
git commit -m "commit for discard file test" -q 2>/dev/null || true
echo "discard file alpha" > alpha.txt
echo "discard file beta" > beta.txt
"$GIT_HUNK" discard --file alpha.txt > /dev/null
ALPHA35="$("$GIT_HUNK" count --file alpha.txt)"
BETA35="$("$GIT_HUNK" count --file beta.txt)"
[[ "$ALPHA35" == "0" ]] || fail "test 35: alpha.txt should have 0 hunks after discard --file, got '$ALPHA35'"
[[ "$BETA35" -gt 0 ]] || fail "test 35: beta.txt should still have hunks, got '$BETA35'"
pass "test 35: discard --file only discards hunks in specified file"

# ============================================================================
# Test 36: check --staged validates staged hashes (M3)
# ============================================================================
git reset HEAD -q 2>/dev/null || true
git checkout -- . 2>/dev/null || true
echo "check staged content" > alpha.txt
git add alpha.txt && git commit -m "base for check staged" -q
echo "check staged change" > alpha.txt
SHA36="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
"$GIT_HUNK" add "$SHA36" > /dev/null 2>/dev/null
STAGED_SHA36="$("$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
"$GIT_HUNK" check --staged "$STAGED_SHA36"
[[ $? -eq 0 ]] || fail "test 36: check --staged should exit 0 for valid staged hash"
pass "test 36: check --staged validates staged hashes"

# ============================================================================
# Test 37: check --exclusive --porcelain shows unexpected entries (L5)
# ============================================================================
echo "extra change for exclusive" >> beta.txt
# Get only one of multiple hunks
ALL_SHAS37="$("$GIT_HUNK" list --porcelain --oneline | cut -f1)"
FIRST_SHA37="$(echo "$ALL_SHAS37" | head -1)"
TOTAL37="$(echo "$ALL_SHAS37" | wc -l | tr -d ' ')"
if [[ "$TOTAL37" -gt 1 ]]; then
    OUT37="$("$GIT_HUNK" check --porcelain --exclusive "$FIRST_SHA37" 2>/dev/null || true)"
    echo "$OUT37" | grep -q "^unexpected" \
        || fail "test 37: expected 'unexpected' in porcelain exclusive output, got: '$OUT37'"
    pass "test 37: check --exclusive --porcelain shows unexpected entries"
else
    # Only one hunk — exclusive should pass
    "$GIT_HUNK" check --porcelain --exclusive "$FIRST_SHA37" > /dev/null 2>/dev/null
    pass "test 37: check --exclusive --porcelain (single hunk, trivial pass)"
fi

# ============================================================================
# Test 38: discard with stale hash exits 1 (L5)
# ============================================================================
! "$GIT_HUNK" discard deadbeef 2>/dev/null
[[ $? -eq 0 ]] || fail "test 38: discard with stale hash should exit 1"
pass "test 38: discard with stale hash exits 1"

# ============================================================================
# Test 39: discard --dry-run --porcelain uses would-discard verb (L5)
# ============================================================================
git checkout -- . 2>/dev/null || true
echo "dry run porcelain test" > alpha.txt
SHA39="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
OUT39="$("$GIT_HUNK" discard --dry-run --porcelain "$SHA39")"
echo "$OUT39" | grep -q "^would-discard" \
    || fail "test 39: expected 'would-discard' verb in porcelain output, got: '$OUT39'"
pass "test 39: discard --dry-run --porcelain uses would-discard verb"

# ============================================================================
# Test 40: remove --porcelain uses tab-separated format (L5)
# ============================================================================
"$GIT_HUNK" add "$SHA39" > /dev/null 2>/dev/null
STAGED_SHA40="$("$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
OUT40="$("$GIT_HUNK" remove --porcelain "$STAGED_SHA40")"
VERB40="$(echo "$OUT40" | cut -f1)"
[[ "$VERB40" == "unstaged" ]] \
    || fail "test 40: expected 'unstaged' verb in remove porcelain, got: '$VERB40'"
pass "test 40: remove --porcelain uses tab-separated format"

echo ""
echo "ALL INTEGRATION TESTS PASSED (40 tests)"
