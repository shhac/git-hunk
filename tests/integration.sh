#!/usr/bin/env bash
# Integration tests for git-hunk. Run via: zig build test-integration
# Requires the binary to already be built (zig build installs it first).
#
# Each test gets its own fresh fixture repo (3 files × 30 lines, 2 commits).
# Tests are fully independent — no shared state.
set -euo pipefail

GIT_HUNK="${1:-./zig-out/bin/git-hunk}"
GIT_HUNK="$(cd "$(dirname "$GIT_HUNK")" && pwd)/$(basename "$GIT_HUNK")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP="$SCRIPT_DIR/setup-repo.sh"
MANPAGE="$SCRIPT_DIR/../doc/git-hunk.1"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# Track current repo for cleanup on failure.
CURRENT_REPO=""
cleanup_repo() {
    if [[ -n "$CURRENT_REPO" && -d "$CURRENT_REPO" ]]; then
        cd /
        rm -rf "$CURRENT_REPO"
    fi
    CURRENT_REPO=""
}
trap cleanup_repo EXIT

# Create a fresh fixture repo and cd into it. Cleans up the previous one.
new_repo() {
    cleanup_repo
    CURRENT_REPO="$(bash "$SETUP")"
    cd "$CURRENT_REPO"
}

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
# Test 2: add (stage) a hunk by SHA
# ============================================================================
new_repo
sed -i '' '1s/.*/Modified first line./' alpha.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" add "$SHA" > /dev/null
STAGED="$(git diff --cached alpha.txt | wc -l | tr -d ' ')"
[[ "$STAGED" -gt 0 ]] || fail "test 2: hunk was not staged"
pass "test 2: add stages hunk"

# ============================================================================
# Test 3: remove (unstage) a hunk by SHA
# ============================================================================
new_repo
sed -i '' '1s/.*/Modified first line./' alpha.txt

"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED_SHA="$("$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$STAGED_SHA" ]] || fail "test 3: no staged hunk found"
"$GIT_HUNK" remove "$STAGED_SHA" > /dev/null
REMAINING="$(git diff --cached | wc -l | tr -d ' ')"
[[ "$REMAINING" -eq 0 ]] || fail "test 3: hunk was not unstaged"
pass "test 3: remove unstages hunk"

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
# Test 7: --all stages all unstaged hunks
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

"$GIT_HUNK" add --all > /dev/null
UNSTAGED="$("$GIT_HUNK" count)"
[[ "$UNSTAGED" == "0" ]] || fail "test 7: expected 0 unstaged hunks after --all, got $UNSTAGED"
STAGED="$(git diff --cached | wc -l | tr -d ' ')"
[[ "$STAGED" -gt 0 ]] || fail "test 7: --all did not stage any hunks"
pass "test 7: --all stages all hunks"

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
# Test 9: add output shows staged HASH -> HASH  FILE format
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
ADD_OUT="$("$GIT_HUNK" add --no-color "$SHA")"
echo "$ADD_OUT" | grep -qE '^staged [a-f0-9]{7} → [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 9: output didn't match expected format, got: '$ADD_OUT'"
pass "test 9: add output format (staged X -> Y  file)"

# ============================================================================
# Test 10: remove output shows unstaged HASH -> HASH  FILE format
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED_SHA="$("$GIT_HUNK" list --staged --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
REM_OUT="$("$GIT_HUNK" remove --no-color "$STAGED_SHA")"
echo "$REM_OUT" | grep -qE '^unstaged [a-f0-9]{7} → [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 10: remove output didn't match expected format, got: '$REM_OUT'"
pass "test 10: remove output format (unstaged X -> Y  file)"

# ============================================================================
# Test 11: overlap/merge case shows consumed hash with + prefix
# ============================================================================
new_repo
sed -i '' '1s/.*/Change A./' alpha.txt
SHA_A="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" add --no-color "$SHA_A" > /dev/null

# Modify same area again to create overlap
sed -i '' '1s/.*/Change B./' alpha.txt
SHA_B="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
MERGE_OUT="$("$GIT_HUNK" add --no-color "$SHA_B")"
echo "$MERGE_OUT" | grep -qE '^staged [a-f0-9]{7} \+[a-f0-9]{7} → [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 11: merge output didn't show consumed hash, got: '$MERGE_OUT'"
pass "test 11: overlap/merge shows consumed hash"

# ============================================================================
# Test 12: porcelain format for add is tab-separated
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
PORC_OUT="$("$GIT_HUNK" add --porcelain "$SHA")"
PORC_VERB="$(echo "$PORC_OUT" | cut -f1)"
PORC_APPLIED="$(echo "$PORC_OUT" | cut -f2)"
PORC_RESULT="$(echo "$PORC_OUT" | cut -f3)"
PORC_FILE="$(echo "$PORC_OUT" | cut -f4)"
[[ "$PORC_VERB" == "staged" ]] || fail "test 12: porcelain verb not 'staged', got '$PORC_VERB'"
[[ ${#PORC_APPLIED} -eq 7 ]] || fail "test 12: porcelain applied hash not 7 chars, got '$PORC_APPLIED'"
[[ ${#PORC_RESULT} -eq 7 ]] || fail "test 12: porcelain result hash not 7 chars, got '$PORC_RESULT'"
[[ "$PORC_FILE" == "alpha.txt" ]] || fail "test 12: porcelain file not 'alpha.txt', got '$PORC_FILE'"
pass "test 12: porcelain format for add"

# ============================================================================
# Test 13: porcelain format for add with merge includes consumed field
# ============================================================================
new_repo
sed -i '' '1s/.*/Change A./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null

sed -i '' '1s/.*/Change B./' alpha.txt
SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
PORC_MERGE="$("$GIT_HUNK" add --porcelain "$SHA")"
FIELD_COUNT="$(echo "$PORC_MERGE" | awk -F'\t' '{print NF}')"
[[ "$FIELD_COUNT" -eq 5 ]] || fail "test 13: expected 5 tab fields for merge, got $FIELD_COUNT in: '$PORC_MERGE'"
CONSUMED_FIELD="$(echo "$PORC_MERGE" | cut -f5)"
[[ ${#CONSUMED_FIELD} -eq 7 ]] || fail "test 13: consumed hash not 7 chars, got '$CONSUMED_FIELD'"
pass "test 13: porcelain format includes consumed field on merge"

# ============================================================================
# Test 14: summary line shows merged count on stderr
# ============================================================================
new_repo
sed -i '' '1s/.*/Change A./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null

sed -i '' '1s/.*/Change B./' alpha.txt
SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
STDERR14="$("$GIT_HUNK" add --no-color "$SHA" 2>&1 >/dev/null)"
echo "$STDERR14" | grep -qE '\(.*merged\)' \
    || fail "test 14: summary stderr didn't show merged count, got: '$STDERR14'"
pass "test 14: summary line shows merged count"

# ============================================================================
# Test 15: batch add of multiple hunks in different files
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

SHAS15="$("$GIT_HUNK" list --porcelain --oneline)"
SHA15A="$(echo "$SHAS15" | grep "alpha.txt" | head -1 | cut -f1)"
SHA15B="$(echo "$SHAS15" | grep "beta.txt" | head -1 | cut -f1)"
[[ -n "$SHA15A" && -n "$SHA15B" ]] || fail "test 15: couldn't find both hunks"
BATCH_OUT="$("$GIT_HUNK" add --no-color "$SHA15A" "$SHA15B")"
LINE_COUNT="$(echo "$BATCH_OUT" | wc -l | tr -d ' ')"
[[ "$LINE_COUNT" -eq 2 ]] || fail "test 15: expected 2 output lines for batch, got $LINE_COUNT"
echo "$BATCH_OUT" | grep -qE 'staged .* alpha\.txt' || fail "test 15: missing alpha.txt in output"
echo "$BATCH_OUT" | grep -qE 'staged .* beta\.txt' || fail "test 15: missing beta.txt in output"
pass "test 15: batch add produces per-file output"

# ============================================================================
# Test 16: arrow is always present in add output (even simple case)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
ARROW_OUT="$("$GIT_HUNK" add --no-color "$SHA")"
echo "$ARROW_OUT" | grep -q '→' \
    || fail "test 16: arrow missing from output, got: '$ARROW_OUT'"
pass "test 16: arrow always present in add output"

# ============================================================================
# Test 17: bridge case — staging middle hunk consumes outer staged hunks
# ============================================================================
# Needs a file with specific line structure for predictable --context 0 hunks.
new_repo
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
git add bridge.txt && git commit -m "bridge setup" -q

sed -i '' 's/line 4 original/line 4 changed/' bridge.txt
sed -i '' 's/line 6 original/line 6 changed/' bridge.txt

BRIDGE_HUNKS="$("$GIT_HUNK" list --porcelain --oneline --context 0 --file bridge.txt 2>/dev/null)"
BRIDGE_COUNT="$(echo "$BRIDGE_HUNKS" | wc -l | tr -d ' ')"
[[ "$BRIDGE_COUNT" -eq 2 ]] || fail "test 17: expected 2 hunks with --context 0, got $BRIDGE_COUNT"

SHA17_A="$(echo "$BRIDGE_HUNKS" | sort -t$'\t' -k3 -n | head -1 | cut -f1)"
SHA17_B="$(echo "$BRIDGE_HUNKS" | sort -t$'\t' -k3 -n | tail -1 | cut -f1)"
"$GIT_HUNK" add --no-color --context 0 "$SHA17_A" "$SHA17_B" > /dev/null 2>/dev/null

sed -i '' 's/line 5 gap/line 5 changed/' bridge.txt
SHA17_MID="$("$GIT_HUNK" list --porcelain --oneline --context 0 --file bridge.txt 2>/dev/null | cut -f1)"
[[ -n "$SHA17_MID" ]] || fail "test 17: no gap hunk found after modifying line 5"

BRIDGE_OUT="$("$GIT_HUNK" add --no-color --context 0 "$SHA17_MID" 2>/dev/null)"
CONSUMED_COUNT="$(echo "$BRIDGE_OUT" | grep -oE '\+[a-f0-9]{7}' | wc -l | tr -d ' ')"
[[ "$CONSUMED_COUNT" -eq 2 ]] \
    || fail "test 17: bridge expected 2 consumed hashes, got $CONSUMED_COUNT in: '$BRIDGE_OUT'"
echo "$BRIDGE_OUT" | grep -qE '→ [a-f0-9]{7}  bridge\.txt' \
    || fail "test 17: bridge output missing result hash, got: '$BRIDGE_OUT'"
pass "test 17: bridge case shows 2 consumed hashes"

# ============================================================================
# Test 18: batch add with pre-existing staged hunk causes merge
# ============================================================================
new_repo
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
git add batch.txt && git commit -m "batch setup" -q

sed -i '' 's/line 4 gap/line 4 changed/' batch.txt
SHA18_PRE="$("$GIT_HUNK" list --porcelain --oneline --context 0 --file batch.txt 2>/dev/null | cut -f1)"
[[ -n "$SHA18_PRE" ]] || fail "test 18: no hunk found for line 4"
"$GIT_HUNK" add --no-color --context 0 "$SHA18_PRE" > /dev/null 2>/dev/null

sed -i '' 's/line 3 original/line 3 changed/' batch.txt
sed -i '' 's/line 5 original/line 5 changed/' batch.txt

BATCH_HUNKS="$("$GIT_HUNK" list --porcelain --oneline --context 0 --file batch.txt 2>/dev/null)"
BATCH_COUNT="$(echo "$BATCH_HUNKS" | wc -l | tr -d ' ')"
[[ "$BATCH_COUNT" -eq 2 ]] || fail "test 18: expected 2 unstaged hunks, got $BATCH_COUNT"

SHA18_A="$(echo "$BATCH_HUNKS" | sort -t$'\t' -k3 -n | head -1 | cut -f1)"
SHA18_B="$(echo "$BATCH_HUNKS" | sort -t$'\t' -k3 -n | tail -1 | cut -f1)"

BATCH_OUT="$("$GIT_HUNK" add --no-color --context 0 "$SHA18_A" "$SHA18_B" 2>/dev/null)"
BATCH_LINES="$(echo "$BATCH_OUT" | wc -l | tr -d ' ')"
[[ "$BATCH_LINES" -eq 1 ]] \
    || fail "test 18: expected 1 output line (merged), got $BATCH_LINES in: '$BATCH_OUT'"
echo "$BATCH_OUT" | grep -qE '\+[a-f0-9]{7}' \
    || fail "test 18: batch output missing consumed hash, got: '$BATCH_OUT'"
echo "$BATCH_OUT" | grep -q "$SHA18_A" \
    || fail "test 18: output missing first applied hash $SHA18_A, got: '$BATCH_OUT'"
echo "$BATCH_OUT" | grep -q "$SHA18_B" \
    || fail "test 18: output missing second applied hash $SHA18_B, got: '$BATCH_OUT'"
pass "test 18: batch add with merge — two applied + one consumed"

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
# Test 23: check with valid hashes exits 0 (silent success)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

SHAS23="$("$GIT_HUNK" list --porcelain --oneline)"
SHA23A="$(echo "$SHAS23" | grep "alpha.txt" | head -1 | cut -f1)"
SHA23B="$(echo "$SHAS23" | grep "beta.txt" | head -1 | cut -f1)"
[[ -n "$SHA23A" && -n "$SHA23B" ]] || fail "test 23: couldn't find both hunks"
OUT23="$("$GIT_HUNK" check "$SHA23A" "$SHA23B" 2>/dev/null)"
[[ -z "$OUT23" ]] || fail "test 23: expected no stdout on success, got '$OUT23'"
pass "test 23: check with valid hashes exits 0"

# ============================================================================
# Test 24: check with stale hash exits 1
# ============================================================================
new_repo
if OUT24="$("$GIT_HUNK" check --no-color "deadbeef" 2>/dev/null)"; then
    fail "test 24: expected exit 1, got 0"
fi
echo "$OUT24" | grep -q "stale" || fail "test 24: expected 'stale' in output, got '$OUT24'"
pass "test 24: check with stale hash exits 1"

# ============================================================================
# Test 25: check --exclusive with exact set exits 0
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

ALL_ALPHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | cut -f1)"
[[ -n "$ALL_ALPHA" ]] || fail "test 25: no alpha.txt hunks found"
# shellcheck disable=SC2086
"$GIT_HUNK" check --exclusive --file alpha.txt $ALL_ALPHA > /dev/null 2>/dev/null
pass "test 25: check --exclusive with exact set exits 0"

# ============================================================================
# Test 26: check --exclusive with extra hunks exits 1
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

SHA26="$("$GIT_HUNK" list --porcelain --oneline | grep "alpha.txt" | head -1 | cut -f1)"
if OUT26="$("$GIT_HUNK" check --no-color --exclusive "$SHA26" 2>/dev/null)"; then
    fail "test 26: expected exit 1 for exclusive with extras"
fi
echo "$OUT26" | grep -q "unexpected" || fail "test 26: expected 'unexpected' in output, got '$OUT26'"
pass "test 26: check --exclusive with extra hunks exits 1"

# ============================================================================
# Test 27: check --porcelain reports both ok and stale entries
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA27="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
if PORC27="$("$GIT_HUNK" check --porcelain "$SHA27" "deadbeef" 2>/dev/null)"; then
    fail "test 27: expected exit 1"
fi
echo "$PORC27" | grep -qE '^ok	' || fail "test 27: expected 'ok' line in porcelain, got '$PORC27'"
echo "$PORC27" | grep -qE '^stale	' || fail "test 27: expected 'stale' line in porcelain, got '$PORC27'"
pass "test 27: check --porcelain reports all entries"

# ============================================================================
# Test 28: check rejects line specs
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA28="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
if "$GIT_HUNK" check "${SHA28}:1-3" > /dev/null 2>/dev/null; then
    fail "test 28: expected exit 1 for line spec"
fi
pass "test 28: check rejects line specs"

# ============================================================================
# Test 29: discard reverts a single unstaged hunk
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA29="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA29" ]] || fail "test 29: no unstaged hunk found"
"$GIT_HUNK" discard --no-color "$SHA29" > /dev/null
REMAINING29="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING29" == "0" ]] || fail "test 29: expected 0 unstaged hunks after discard, got '$REMAINING29'"
pass "test 29: discard reverts single hunk"

# ============================================================================
# Test 30: discard --all reverts all unstaged hunks
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

COUNT30_BEFORE="$("$GIT_HUNK" count)"
[[ "$COUNT30_BEFORE" -gt 0 ]] || fail "test 30: expected unstaged hunks before discard --all"
"$GIT_HUNK" discard --all > /dev/null
COUNT30_AFTER="$("$GIT_HUNK" count)"
[[ "$COUNT30_AFTER" == "0" ]] || fail "test 30: expected 0 unstaged hunks after discard --all, got '$COUNT30_AFTER'"
pass "test 30: discard --all reverts all hunks"

# ============================================================================
# Test 31: discard --dry-run does NOT modify worktree
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA31="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA31" ]] || fail "test 31: no unstaged hunk found"
DRY_OUT="$("$GIT_HUNK" discard --no-color --dry-run "$SHA31")"
echo "$DRY_OUT" | grep -q "would discard" || fail "test 31: expected 'would discard' in output, got '$DRY_OUT'"
REMAINING31="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING31" -gt 0 ]] || fail "test 31: dry-run should not have modified worktree"
pass "test 31: discard --dry-run does not modify worktree"

# ============================================================================
# Test 32: discard output format (human mode)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA32="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
DISCARD_OUT="$("$GIT_HUNK" discard --no-color "$SHA32")"
echo "$DISCARD_OUT" | grep -qE '^discarded [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 32: discard output format wrong, got: '$DISCARD_OUT'"
pass "test 32: discard output format"

# ============================================================================
# Test 33: discard --porcelain output is tab-separated
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA33="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
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
new_repo
sed -i '' '1s/.*/Staged content./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED34_BEFORE="$("$GIT_HUNK" count --staged)"

sed -i '' '1s/.*/Additional unstaged change./' alpha.txt
"$GIT_HUNK" discard --all > /dev/null
STAGED34_AFTER="$("$GIT_HUNK" count --staged)"
[[ "$STAGED34_BEFORE" == "$STAGED34_AFTER" ]] \
    || fail "test 34: discard should not affect staged changes (before=$STAGED34_BEFORE, after=$STAGED34_AFTER)"
pass "test 34: discard preserves staged changes"

# ============================================================================
# Test 35: discard --file only discards hunks in specified file
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

"$GIT_HUNK" discard --file alpha.txt > /dev/null
ALPHA35="$("$GIT_HUNK" count --file alpha.txt)"
BETA35="$("$GIT_HUNK" count --file beta.txt)"
[[ "$ALPHA35" == "0" ]] || fail "test 35: alpha.txt should have 0 hunks after discard --file, got '$ALPHA35'"
[[ "$BETA35" -gt 0 ]] || fail "test 35: beta.txt should still have hunks, got '$BETA35'"
pass "test 35: discard --file only discards hunks in specified file"

# ============================================================================
# Test 36: check --staged validates staged hashes
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA36="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
"$GIT_HUNK" add "$SHA36" > /dev/null 2>/dev/null
STAGED_SHA36="$("$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
"$GIT_HUNK" check --staged "$STAGED_SHA36"
[[ $? -eq 0 ]] || fail "test 36: check --staged should exit 0 for valid staged hash"
pass "test 36: check --staged validates staged hashes"

# ============================================================================
# Test 37: check --exclusive --porcelain shows unexpected entries
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

ALL_SHAS37="$("$GIT_HUNK" list --porcelain --oneline | cut -f1)"
FIRST_SHA37="$(echo "$ALL_SHAS37" | head -1)"
TOTAL37="$(echo "$ALL_SHAS37" | wc -l | tr -d ' ')"
if [[ "$TOTAL37" -gt 1 ]]; then
    OUT37="$("$GIT_HUNK" check --porcelain --exclusive "$FIRST_SHA37" 2>/dev/null || true)"
    echo "$OUT37" | grep -q "^unexpected" \
        || fail "test 37: expected 'unexpected' in porcelain exclusive output, got: '$OUT37'"
    pass "test 37: check --exclusive --porcelain shows unexpected entries"
else
    "$GIT_HUNK" check --porcelain --exclusive "$FIRST_SHA37" > /dev/null 2>/dev/null
    pass "test 37: check --exclusive --porcelain (single hunk, trivial pass)"
fi

# ============================================================================
# Test 38: discard with stale hash exits 1
# ============================================================================
new_repo
if "$GIT_HUNK" discard deadbeef > /dev/null 2>/dev/null; then
    fail "test 38: expected exit 1 for stale hash"
fi
pass "test 38: discard with stale hash exits 1"

# ============================================================================
# Test 39: discard --dry-run --porcelain uses would-discard verb
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA39="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
OUT39="$("$GIT_HUNK" discard --dry-run --porcelain "$SHA39")"
echo "$OUT39" | grep -q "^would-discard" \
    || fail "test 39: expected 'would-discard' verb in porcelain output, got: '$OUT39'"
pass "test 39: discard --dry-run --porcelain uses would-discard verb"

# ============================================================================
# Test 40: remove --porcelain uses tab-separated format
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED_SHA40="$("$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
OUT40="$("$GIT_HUNK" remove --porcelain "$STAGED_SHA40")"
VERB40="$(echo "$OUT40" | cut -f1)"
[[ "$VERB40" == "unstaged" ]] \
    || fail "test 40: expected 'unstaged' verb in remove porcelain, got: '$VERB40'"
pass "test 40: remove --porcelain uses tab-separated format"

# ============================================================================
# Test 41: basic stash push by SHA
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

SHA41="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" stash "$SHA41" > /dev/null
STASH_LIST41="$(git stash list)"
[[ -n "$STASH_LIST41" ]] || fail "test 41: expected non-empty stash list"
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 41: expected alpha.txt reverted to committed content"
[[ "$(head -1 beta.txt)" == "Changed beta." ]] \
    || fail "test 41: beta.txt should be unchanged"
pass "test 41: basic stash push by SHA"

# ============================================================================
# Test 42: stash pop roundtrip
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

SHA42="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" stash "$SHA42" > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] || fail "test 42: not reverted after stash"

"$GIT_HUNK" stash --pop > /dev/null 2>/dev/null
[[ "$(head -1 alpha.txt)" == "Changed alpha." ]] \
    || fail "test 42: expected alpha.txt restored after pop"
STASH_LIST42="$(git stash list)"
[[ -z "$STASH_LIST42" ]] || fail "test 42: expected empty stash list after pop"
pass "test 42: stash pop roundtrip"

# ============================================================================
# Test 43: stash --all
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"
ORIG_BETA="$(git show HEAD:beta.txt | head -1)"

"$GIT_HUNK" stash --all > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 43: expected alpha.txt reverted"
[[ "$(head -1 beta.txt)" == "$ORIG_BETA" ]] \
    || fail "test 43: expected beta.txt reverted"
git stash show > /dev/null 2>/dev/null \
    || fail "test 43: git stash show should succeed"
pass "test 43: stash --all"

# ============================================================================
# Test 44: stash -m custom message
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

"$GIT_HUNK" stash --all -m "custom stash msg" > /dev/null
STASH_LIST44="$(git stash list)"
echo "$STASH_LIST44" | grep -q "custom stash msg" \
    || fail "test 44: expected 'custom stash msg' in stash list, got '$STASH_LIST44'"
pass "test 44: stash -m custom message"

# ============================================================================
# Test 45: stash --file filter
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

"$GIT_HUNK" stash --file alpha.txt > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 45: expected alpha.txt reverted"
[[ "$(head -1 beta.txt)" == "Changed beta." ]] \
    || fail "test 45: beta.txt should be unchanged"
pass "test 45: stash --file filter"

# ============================================================================
# Test 46: stash preserves staged changes
# ============================================================================
new_repo
sed -i '' '1s/.*/Staged beta./' beta.txt
git add beta.txt
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA46="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" stash "$SHA46" > /dev/null
STAGED46="$(git diff --cached --name-only)"
echo "$STAGED46" | grep -q "beta.txt" \
    || fail "test 46: expected beta.txt still staged, got '$STAGED46'"
pass "test 46: stash preserves staged changes"

# ============================================================================
# Test 47: stale SHA error (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash deadbeef > /dev/null 2>/dev/null; then
    fail "test 47: expected exit 1 for stale SHA"
fi
pass "test 47: stale SHA error"

# ============================================================================
# Test 48: no-changes error (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash --all > /dev/null 2>/dev/null; then
    fail "test 48: expected exit 1 for no unstaged changes"
fi
pass "test 48: no-changes error"

# ============================================================================
# Test 49: pop with no stash entries (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash --pop > /dev/null 2>/dev/null; then
    fail "test 49: expected exit 1 for pop with no stash"
fi
pass "test 49: pop with no stash entries"

# ============================================================================
# Test 50: --pop rejects conflicting flags (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash --pop --all > /dev/null 2>/dev/null; then
    fail "test 50: expected exit 1 for --pop --all"
fi
pass "test 50: --pop rejects conflicting flags"

# ============================================================================
# Test 51: line spec rejection (exit 1)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA51="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
if "$GIT_HUNK" stash "${SHA51}:1-3" > /dev/null 2>/dev/null; then
    fail "test 51: expected exit 1 for line spec"
fi
pass "test 51: line spec rejection"

# ============================================================================
# Test 52: global --help exits 0 and shows commands
# ============================================================================
OUT52="$("$GIT_HUNK" --help)"
echo "$OUT52" | grep -q "commands:" \
    || fail "test 52: --help should contain 'commands:'"
echo "$OUT52" | grep -q "git-hunk <command> --help" \
    || fail "test 52: --help should mention per-command help"
pass "test 52: global --help exits 0 and shows commands"

# ============================================================================
# Test 53: subcommand --help shows per-command help and exits 0
# ============================================================================
OUT53="$("$GIT_HUNK" list --help)"
echo "$OUT53" | grep -q "USAGE" \
    || fail "test 53: list --help should contain 'USAGE'"
echo "$OUT53" | grep -q "\-\-staged" \
    || fail "test 53: list --help should describe --staged"
echo "$OUT53" | grep -q "EXAMPLES" \
    || fail "test 53: list --help should contain 'EXAMPLES'"
pass "test 53: list --help shows per-command help"

# ============================================================================
# Test 54: help <command> shows same per-command help
# ============================================================================
OUT54="$("$GIT_HUNK" help stash)"
echo "$OUT54" | grep -q "USAGE" \
    || fail "test 54: help stash should contain 'USAGE'"
echo "$OUT54" | grep -q "\-\-pop" \
    || fail "test 54: help stash should describe --pop"
pass "test 54: help <command> shows per-command help"

# ============================================================================
# Test 55: help <unknown> exits 1
# ============================================================================
if "$GIT_HUNK" help badcmd > /dev/null 2>/dev/null; then
    fail "test 55: expected exit 1 for help badcmd"
fi
pass "test 55: help <unknown> exits 1"

# ============================================================================
# Test 56: all commands support --help
# ============================================================================
for CMD in list show add remove discard count check stash; do
    OUT56="$("$GIT_HUNK" "$CMD" --help)"
    echo "$OUT56" | grep -q "USAGE" \
        || fail "test 56: $CMD --help should contain 'USAGE'"
    echo "$OUT56" | grep -q "git-hunk $CMD" \
        || fail "test 56: $CMD --help should mention 'git-hunk $CMD'"
done
pass "test 56: all commands support --help"

# ============================================================================
# Test 57: man page lists all commands from --help
# ============================================================================
if [[ -f "$MANPAGE" ]]; then
    HELP_CMDS="$("$GIT_HUNK" --help | sed -n '/^commands:/,/^$/p' | grep '^ ' | awk '{print $1}')"
    for CMD in $HELP_CMDS; do
        grep -q "^\.B $CMD" "$MANPAGE" \
            || fail "test 57: man page missing command '$CMD'"
    done
    pass "test 57: man page lists all commands from --help"
else
    echo "SKIP: test 57: man page not found at $MANPAGE"
fi

echo ""
echo "ALL INTEGRATION TESTS PASSED (57 tests)"
