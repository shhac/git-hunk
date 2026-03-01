#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 200: add (stage) a hunk by SHA
# ============================================================================
new_repo
sed -i '' '1s/.*/Modified first line./' alpha.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" add "$SHA" > /dev/null
STAGED="$(git diff --cached alpha.txt | wc -l | tr -d ' ')"
[[ "$STAGED" -gt 0 ]] || fail "test 200: hunk was not staged"
pass "test 200: add stages hunk"

# ============================================================================
# Test 201: reset (unstage) a hunk by SHA
# ============================================================================
new_repo
sed -i '' '1s/.*/Modified first line./' alpha.txt

"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED_SHA="$("$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$STAGED_SHA" ]] || fail "test 201: no staged hunk found"
"$GIT_HUNK" reset "$STAGED_SHA" > /dev/null
REMAINING="$(git diff --cached | wc -l | tr -d ' ')"
[[ "$REMAINING" -eq 0 ]] || fail "test 201: hunk was not unstaged"
pass "test 201: reset unstages hunk"

# ============================================================================
# Test 202: --all stages all unstaged hunks
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

"$GIT_HUNK" add --all > /dev/null
UNSTAGED="$("$GIT_HUNK" count)"
[[ "$UNSTAGED" == "0" ]] || fail "test 202: expected 0 unstaged hunks after --all, got $UNSTAGED"
STAGED="$(git diff --cached | wc -l | tr -d ' ')"
[[ "$STAGED" -gt 0 ]] || fail "test 202: --all did not stage any hunks"
pass "test 202: --all stages all hunks"

# ============================================================================
# Test 203: add output shows staged HASH -> HASH  FILE format
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
ADD_OUT="$("$GIT_HUNK" add --no-color "$SHA")"
echo "$ADD_OUT" | grep -qE '^staged [a-f0-9]{7} → [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 203: output didn't match expected format, got: '$ADD_OUT'"
pass "test 203: add output format (staged X -> Y  file)"

# ============================================================================
# Test 204: reset output shows unstaged HASH -> HASH  FILE format
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED_SHA="$("$GIT_HUNK" list --staged --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
REM_OUT="$("$GIT_HUNK" reset --no-color "$STAGED_SHA")"
echo "$REM_OUT" | grep -qE '^unstaged [a-f0-9]{7} → [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 204: reset output didn't match expected format, got: '$REM_OUT'"
pass "test 204: reset output format (unstaged X -> Y  file)"

# ============================================================================
# Test 205: overlap/merge case shows consumed hash with + prefix
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
    || fail "test 205: merge output didn't show consumed hash, got: '$MERGE_OUT'"
pass "test 205: overlap/merge shows consumed hash"

# ============================================================================
# Test 206: porcelain format for add is tab-separated
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
PORC_OUT="$("$GIT_HUNK" add --porcelain "$SHA")"
PORC_VERB="$(echo "$PORC_OUT" | cut -f1)"
PORC_APPLIED="$(echo "$PORC_OUT" | cut -f2)"
PORC_RESULT="$(echo "$PORC_OUT" | cut -f3)"
PORC_FILE="$(echo "$PORC_OUT" | cut -f4)"
[[ "$PORC_VERB" == "staged" ]] || fail "test 206: porcelain verb not 'staged', got '$PORC_VERB'"
[[ ${#PORC_APPLIED} -eq 7 ]] || fail "test 206: porcelain applied hash not 7 chars, got '$PORC_APPLIED'"
[[ ${#PORC_RESULT} -eq 7 ]] || fail "test 206: porcelain result hash not 7 chars, got '$PORC_RESULT'"
[[ "$PORC_FILE" == "alpha.txt" ]] || fail "test 206: porcelain file not 'alpha.txt', got '$PORC_FILE'"
pass "test 206: porcelain format for add"

# ============================================================================
# Test 207: porcelain format for add with merge includes consumed field
# ============================================================================
new_repo
sed -i '' '1s/.*/Change A./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null

sed -i '' '1s/.*/Change B./' alpha.txt
SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
PORC_MERGE="$("$GIT_HUNK" add --porcelain "$SHA")"
FIELD_COUNT="$(echo "$PORC_MERGE" | awk -F'\t' '{print NF}')"
[[ "$FIELD_COUNT" -eq 5 ]] || fail "test 207: expected 5 tab fields for merge, got $FIELD_COUNT in: '$PORC_MERGE'"
CONSUMED_FIELD="$(echo "$PORC_MERGE" | cut -f5)"
[[ ${#CONSUMED_FIELD} -eq 7 ]] || fail "test 207: consumed hash not 7 chars, got '$CONSUMED_FIELD'"
pass "test 207: porcelain format includes consumed field on merge"

# ============================================================================
# Test 208: summary line shows merged count on stderr
# ============================================================================
new_repo
sed -i '' '1s/.*/Change A./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null

sed -i '' '1s/.*/Change B./' alpha.txt
SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
STDERR208="$("$GIT_HUNK" add --verbose --no-color "$SHA" 2>&1 >/dev/null)"
echo "$STDERR208" | grep -qE '\(.*merged\)' \
    || fail "test 208: summary stderr didn't show merged count, got: '$STDERR208'"
pass "test 208: summary line shows merged count"

# ============================================================================
# Test 209: batch add of multiple hunks in different files
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

SHAS209="$("$GIT_HUNK" list --porcelain --oneline)"
SHA209A="$(echo "$SHAS209" | grep "alpha.txt" | head -1 | cut -f1)"
SHA209B="$(echo "$SHAS209" | grep "beta.txt" | head -1 | cut -f1)"
[[ -n "$SHA209A" && -n "$SHA209B" ]] || fail "test 209: couldn't find both hunks"
BATCH_OUT="$("$GIT_HUNK" add --no-color "$SHA209A" "$SHA209B")"
LINE_COUNT="$(echo "$BATCH_OUT" | wc -l | tr -d ' ')"
[[ "$LINE_COUNT" -eq 2 ]] || fail "test 209: expected 2 output lines for batch, got $LINE_COUNT"
echo "$BATCH_OUT" | grep -qE 'staged .* alpha\.txt' || fail "test 209: missing alpha.txt in output"
echo "$BATCH_OUT" | grep -qE 'staged .* beta\.txt' || fail "test 209: missing beta.txt in output"
pass "test 209: batch add produces per-file output"

# ============================================================================
# Test 210: arrow is always present in add output (even simple case)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
ARROW_OUT="$("$GIT_HUNK" add --no-color "$SHA")"
echo "$ARROW_OUT" | grep -q '→' \
    || fail "test 210: arrow missing from output, got: '$ARROW_OUT'"
pass "test 210: arrow always present in add output"

# ============================================================================
# Test 211: bridge case — staging middle hunk consumes outer staged hunks
# ============================================================================
# Needs a file with specific line structure for predictable --unified 0 hunks.
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

BRIDGE_HUNKS="$("$GIT_HUNK" list --porcelain --oneline --unified 0 --file bridge.txt 2>/dev/null)"
BRIDGE_COUNT="$(echo "$BRIDGE_HUNKS" | wc -l | tr -d ' ')"
[[ "$BRIDGE_COUNT" -eq 2 ]] || fail "test 211: expected 2 hunks with --unified 0, got $BRIDGE_COUNT"

SHA211_A="$(echo "$BRIDGE_HUNKS" | sort -t$'\t' -k3 -n | head -1 | cut -f1)"
SHA211_B="$(echo "$BRIDGE_HUNKS" | sort -t$'\t' -k3 -n | tail -1 | cut -f1)"
"$GIT_HUNK" add --no-color --unified 0 "$SHA211_A" "$SHA211_B" > /dev/null 2>/dev/null

sed -i '' 's/line 5 gap/line 5 changed/' bridge.txt
SHA211_MID="$("$GIT_HUNK" list --porcelain --oneline --unified 0 --file bridge.txt 2>/dev/null | cut -f1)"
[[ -n "$SHA211_MID" ]] || fail "test 211: no gap hunk found after modifying line 5"

BRIDGE_OUT="$("$GIT_HUNK" add --no-color --unified 0 "$SHA211_MID" 2>/dev/null)"
CONSUMED_COUNT="$(echo "$BRIDGE_OUT" | grep -oE '\+[a-f0-9]{7}' | wc -l | tr -d ' ')"
[[ "$CONSUMED_COUNT" -eq 2 ]] \
    || fail "test 211: bridge expected 2 consumed hashes, got $CONSUMED_COUNT in: '$BRIDGE_OUT'"
echo "$BRIDGE_OUT" | grep -qE '→ [a-f0-9]{7}  bridge\.txt' \
    || fail "test 211: bridge output missing result hash, got: '$BRIDGE_OUT'"
pass "test 211: bridge case shows 2 consumed hashes"

# ============================================================================
# Test 212: batch add with pre-existing staged hunk causes merge
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
SHA212_PRE="$("$GIT_HUNK" list --porcelain --oneline --unified 0 --file batch.txt 2>/dev/null | cut -f1)"
[[ -n "$SHA212_PRE" ]] || fail "test 212: no hunk found for line 4"
"$GIT_HUNK" add --no-color --unified 0 "$SHA212_PRE" > /dev/null 2>/dev/null

sed -i '' 's/line 3 original/line 3 changed/' batch.txt
sed -i '' 's/line 5 original/line 5 changed/' batch.txt

BATCH_HUNKS="$("$GIT_HUNK" list --porcelain --oneline --unified 0 --file batch.txt 2>/dev/null)"
BATCH_COUNT="$(echo "$BATCH_HUNKS" | wc -l | tr -d ' ')"
[[ "$BATCH_COUNT" -eq 2 ]] || fail "test 212: expected 2 unstaged hunks, got $BATCH_COUNT"

SHA212_A="$(echo "$BATCH_HUNKS" | sort -t$'\t' -k3 -n | head -1 | cut -f1)"
SHA212_B="$(echo "$BATCH_HUNKS" | sort -t$'\t' -k3 -n | tail -1 | cut -f1)"

BATCH_OUT="$("$GIT_HUNK" add --no-color --unified 0 "$SHA212_A" "$SHA212_B" 2>/dev/null)"
BATCH_LINES="$(echo "$BATCH_OUT" | wc -l | tr -d ' ')"
[[ "$BATCH_LINES" -eq 1 ]] \
    || fail "test 212: expected 1 output line (merged), got $BATCH_LINES in: '$BATCH_OUT'"
echo "$BATCH_OUT" | grep -qE '\+[a-f0-9]{7}' \
    || fail "test 212: batch output missing consumed hash, got: '$BATCH_OUT'"
echo "$BATCH_OUT" | grep -q "$SHA212_A" \
    || fail "test 212: output missing first applied hash $SHA212_A, got: '$BATCH_OUT'"
echo "$BATCH_OUT" | grep -q "$SHA212_B" \
    || fail "test 212: output missing second applied hash $SHA212_B, got: '$BATCH_OUT'"
pass "test 212: batch add with merge — two applied + one consumed"

# ============================================================================
# Test 213: reset --porcelain uses tab-separated format
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED_SHA213="$("$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
OUT213="$("$GIT_HUNK" reset --porcelain "$STAGED_SHA213")"
VERB213="$(echo "$OUT213" | cut -f1)"
[[ "$VERB213" == "unstaged" ]] \
    || fail "test 213: expected 'unstaged' verb in reset porcelain, got: '$VERB213'"
pass "test 213: reset --porcelain uses tab-separated format"

# ============================================================================
# Test 214: --all stages both tracked changes and untracked files
# ============================================================================
new_repo
sed -i '' '1s/.*/Modified first line./' alpha.txt
echo "brand new untracked content" > untracked_all.txt

"$GIT_HUNK" add --all > /dev/null 2>/dev/null
REMAINING="$("$GIT_HUNK" count)"
[[ "$REMAINING" == "0" ]] || fail "test 214: expected 0 unstaged hunks after --all, got $REMAINING"
STAGED_FILES="$(git diff --cached --name-only)"
echo "$STAGED_FILES" | grep -q "alpha.txt" || fail "test 214: tracked change not staged"
echo "$STAGED_FILES" | grep -q "untracked_all.txt" || fail "test 214: untracked file not staged"
pass "test 214: --all stages tracked changes and untracked files"

# ============================================================================
# Test 215: add stages an untracked file by hash
# ============================================================================
new_repo
echo "new file content line 1" > untracked.txt

SHA215="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA215" ]] || fail "test 215: no untracked hunk found"
"$GIT_HUNK" add "$SHA215" > /dev/null
STAGED215="$(git diff --cached --name-only)"
echo "$STAGED215" | grep -q "untracked.txt" || fail "test 215: untracked file was not staged"
pass "test 215: add stages untracked file"

# ============================================================================
# Test 216: reset (unstage) untracked file returns it to untracked
# ============================================================================
new_repo
echo "new file content line 1" > untracked.txt

SHA216="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
"$GIT_HUNK" add "$SHA216" > /dev/null 2>/dev/null
STAGED_SHA216="$("$GIT_HUNK" list --staged --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$STAGED_SHA216" ]] || fail "test 216: no staged hunk found after add"
"$GIT_HUNK" reset "$STAGED_SHA216" > /dev/null
REMAINING216="$(git diff --cached --name-only | grep "untracked.txt" || true)"
[[ -z "$REMAINING216" ]] || fail "test 216: file still staged after reset"
[[ -f untracked.txt ]] || fail "test 216: file deleted after reset"
pass "test 216: reset returns untracked file to untracked"

# ============================================================================
# Test 217: add --tracked-only excludes untracked files
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

"$GIT_HUNK" add --all --tracked-only > /dev/null
STAGED217="$("$GIT_HUNK" list --staged --porcelain --oneline)"
echo "$STAGED217" | grep -q "alpha.txt" || fail "test 217: tracked file should be staged"
UNSTAGED217="$("$GIT_HUNK" list --porcelain --oneline)"
echo "$UNSTAGED217" | grep -q "untracked.txt" || fail "test 217: untracked file should remain unstaged"
pass "test 217: add --tracked-only excludes untracked files"

# ============================================================================
# Test 218: --tracked-only and --untracked-only conflict
# ============================================================================
new_repo
if "$GIT_HUNK" list --tracked-only --untracked-only 2>/dev/null; then
    fail "test 218: expected exit 1 for conflicting filter flags"
fi
pass "test 218: --tracked-only and --untracked-only conflict detected"

report_results
