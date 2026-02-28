#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

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
# Test 56: --all stages both tracked changes and untracked files
# ============================================================================
new_repo
sed -i '' '1s/.*/Modified first line./' alpha.txt
echo "brand new untracked content" > untracked_all.txt

"$GIT_HUNK" add --all > /dev/null 2>/dev/null
REMAINING="$("$GIT_HUNK" count)"
[[ "$REMAINING" == "0" ]] || fail "test 56: expected 0 unstaged hunks after --all, got $REMAINING"
STAGED_FILES="$(git diff --cached --name-only)"
echo "$STAGED_FILES" | grep -q "alpha.txt" || fail "test 56: tracked change not staged"
echo "$STAGED_FILES" | grep -q "untracked_all.txt" || fail "test 56: untracked file not staged"
pass "test 56: --all stages tracked changes and untracked files"

# ============================================================================
# Test 54: add stages an untracked file by hash
# ============================================================================
new_repo
echo "new file content line 1" > untracked.txt

SHA54="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA54" ]] || fail "test 54: no untracked hunk found"
"$GIT_HUNK" add "$SHA54" > /dev/null
STAGED54="$(git diff --cached --name-only)"
echo "$STAGED54" | grep -q "untracked.txt" || fail "test 54: untracked file was not staged"
pass "test 54: add stages untracked file"

# ============================================================================
# Test 55: remove (unstage) untracked file returns it to untracked
# ============================================================================
new_repo
echo "new file content line 1" > untracked.txt

SHA55="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
"$GIT_HUNK" add "$SHA55" > /dev/null 2>/dev/null
STAGED_SHA55="$("$GIT_HUNK" list --staged --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$STAGED_SHA55" ]] || fail "test 55: no staged hunk found after add"
"$GIT_HUNK" remove "$STAGED_SHA55" > /dev/null
REMAINING55="$(git diff --cached --name-only | grep "untracked.txt" || true)"
[[ -z "$REMAINING55" ]] || fail "test 55: file still staged after remove"
[[ -f untracked.txt ]] || fail "test 55: file deleted after remove"
pass "test 55: remove returns untracked file to untracked"

report_results
