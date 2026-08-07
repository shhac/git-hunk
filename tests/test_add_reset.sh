#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 200: add (stage) a hunk by SHA
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line./' alpha.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" add "$SHA" > /dev/null
STAGED="$(git diff --cached alpha.txt | wc -l | tr -d ' ')"
[[ "$STAGED" -gt 0 ]] || fail "test 200: hunk was not staged"
pass "test 200: add stages hunk"

# ============================================================================
# Test 201: reset (unstage) a hunk by SHA
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line./' alpha.txt

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
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt

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
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
ADD_OUT="$("$GIT_HUNK" add --no-color "$SHA")"
echo "$ADD_OUT" | grep -qE '^staged [a-f0-9]{7} → [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 203: output didn't match expected format, got: '$ADD_OUT'"
pass "test 203: add output format (staged X -> Y  file)"

# ============================================================================
# Test 204: reset output shows unstaged HASH -> HASH  FILE format
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

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
sed -i.bak '1s/.*/Change A./' alpha.txt
SHA_A="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" add --no-color "$SHA_A" > /dev/null

# Modify same area again to create overlap
sed -i.bak '1s/.*/Change B./' alpha.txt
SHA_B="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
MERGE_OUT="$("$GIT_HUNK" add --no-color "$SHA_B")"
echo "$MERGE_OUT" | grep -qE '^staged [a-f0-9]{7} \+[a-f0-9]{7} → [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 205: merge output didn't show consumed hash, got: '$MERGE_OUT'"
pass "test 205: overlap/merge shows consumed hash"

# ============================================================================
# Test 206: porcelain format for add is tab-separated
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

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
sed -i.bak '1s/.*/Change A./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null

sed -i.bak '1s/.*/Change B./' alpha.txt
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
sed -i.bak '1s/.*/Change A./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null

sed -i.bak '1s/.*/Change B./' alpha.txt
SHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
STDERR208="$("$GIT_HUNK" add --verbose --no-color "$SHA" 2>&1 >/dev/null)"
echo "$STDERR208" | grep -qE '\(.*merged\)' \
    || fail "test 208: summary stderr didn't show merged count, got: '$STDERR208'"
pass "test 208: summary line shows merged count"

# ============================================================================
# Test 209: batch add of multiple hunks in different files
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt

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
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

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

sed -i.bak 's/line 4 original/line 4 changed/' bridge.txt
sed -i.bak 's/line 6 original/line 6 changed/' bridge.txt

BRIDGE_HUNKS="$("$GIT_HUNK" list --porcelain --oneline --unified 0 --file bridge.txt 2>/dev/null)"
BRIDGE_COUNT="$(echo "$BRIDGE_HUNKS" | wc -l | tr -d ' ')"
[[ "$BRIDGE_COUNT" -eq 2 ]] || fail "test 211: expected 2 hunks with --unified 0, got $BRIDGE_COUNT"

SHA211_A="$(echo "$BRIDGE_HUNKS" | sort -t$'\t' -k3 -n | head -1 | cut -f1)"
SHA211_B="$(echo "$BRIDGE_HUNKS" | sort -t$'\t' -k3 -n | tail -1 | cut -f1)"
"$GIT_HUNK" add --no-color --unified 0 "$SHA211_A" "$SHA211_B" > /dev/null 2>/dev/null

sed -i.bak 's/line 5 gap/line 5 changed/' bridge.txt
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

sed -i.bak 's/line 4 gap/line 4 changed/' batch.txt
SHA212_PRE="$("$GIT_HUNK" list --porcelain --oneline --unified 0 --file batch.txt 2>/dev/null | cut -f1)"
[[ -n "$SHA212_PRE" ]] || fail "test 212: no hunk found for line 4"
"$GIT_HUNK" add --no-color --unified 0 "$SHA212_PRE" > /dev/null 2>/dev/null

sed -i.bak 's/line 3 original/line 3 changed/' batch.txt
sed -i.bak 's/line 5 original/line 5 changed/' batch.txt

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
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

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
sed -i.bak '1s/.*/Modified first line./' alpha.txt
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
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
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

# ============================================================================
# Test 219: add sha:N-M stages only a single changed line from a multi-change hunk
# ============================================================================
new_repo
cat > linespec.txt <<'LINESPEC_EOF'
line 1
line 2
line 3 original
line 4
line 5 original
line 6
line 7
line 8 original
line 9
line 10
LINESPEC_EOF
git add linespec.txt && git commit -m "linespec setup" -q
sed -i.bak 's/line 3 original/line 3 changed/' linespec.txt
sed -i.bak 's/line 5 original/line 5 changed/' linespec.txt
sed -i.bak 's/line 8 original/line 8 changed/' linespec.txt

SHA219="$("$GIT_HUNK" list --porcelain --oneline --file linespec.txt | head -1 | cut -f1)"
[[ -n "$SHA219" ]] || fail "test 219: no hunk found"
"$GIT_HUNK" add --no-color "${SHA219}:3-4" > /dev/null

STAGED219="$(git diff --cached linespec.txt)"
echo "$STAGED219" | grep -q "line 3 changed" \
    || fail "test 219: line 3 change should be staged"
if echo "$STAGED219" | grep -q "line 5 changed"; then
    fail "test 219: line 5 change should not be staged"
fi
if echo "$STAGED219" | grep -q "line 8 changed"; then
    fail "test 219: line 8 change should not be staged"
fi
UNSTAGED219="$(git diff linespec.txt)"
echo "$UNSTAGED219" | grep -q "line 5 changed" \
    || fail "test 219: line 5 change should remain unstaged"
pass "test 219: add sha:N-M stages only selected lines from a multi-change hunk"

# ============================================================================
# Test 220: add sha:N-M stages a range covering multiple changed lines
# ============================================================================
new_repo
cat > linespec.txt <<'LINESPEC_EOF'
line 1
line 2
line 3 original
line 4
line 5 original
line 6
line 7
line 8 original
line 9
line 10
LINESPEC_EOF
git add linespec.txt && git commit -m "linespec setup" -q
sed -i.bak 's/line 3 original/line 3 changed/' linespec.txt
sed -i.bak 's/line 5 original/line 5 changed/' linespec.txt
sed -i.bak 's/line 8 original/line 8 changed/' linespec.txt

SHA220="$("$GIT_HUNK" list --porcelain --oneline --file linespec.txt | head -1 | cut -f1)"
[[ -n "$SHA220" ]] || fail "test 220: no hunk found"
"$GIT_HUNK" add --no-color "${SHA220}:3-7" > /dev/null

STAGED220="$(git diff --cached linespec.txt)"
echo "$STAGED220" | grep -q "line 3 changed" \
    || fail "test 220: line 3 change should be staged"
echo "$STAGED220" | grep -q "line 5 changed" \
    || fail "test 220: line 5 change should be staged"
if echo "$STAGED220" | grep -q "line 8 changed"; then
    fail "test 220: line 8 change should not be staged"
fi
UNSTAGED220="$(git diff linespec.txt)"
echo "$UNSTAGED220" | grep -q "line 8 changed" \
    || fail "test 220: line 8 change should remain unstaged"
if echo "$UNSTAGED220" | grep -q "line 3 changed"; then
    fail "test 220: line 3 change should not be in unstaged diff"
fi
pass "test 220: add sha:N-M stages a range covering multiple changes"

# ============================================================================
# Test 221: reset sha:N-M unstages a subset of a staged hunk (with --unified 0)
# Using pure insertions so context lines match the index after staging.
# ============================================================================
new_repo
cat > linespec.txt <<'LINESPEC_EOF'
line 1
line 2
line 3
line 4
line 5
LINESPEC_EOF
git add linespec.txt && git commit -m "linespec setup" -q
cat > linespec.txt <<'LINESPEC_EOF'
line 1
line 2
new line A
new line B
new line C
line 3
line 4
line 5
LINESPEC_EOF

"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED_SHA221="$("$GIT_HUNK" list --staged --unified 0 --porcelain --oneline --file linespec.txt | head -1 | cut -f1)"
[[ -n "$STAGED_SHA221" ]] || fail "test 221: no staged hunk found"

"$GIT_HUNK" reset --no-color --unified 0 "${STAGED_SHA221}:1-2" > /dev/null

STAGED221="$(git diff --cached linespec.txt)"
echo "$STAGED221" | grep -q "new line C" \
    || fail "test 221: new line C should remain staged"
if echo "$STAGED221" | grep -q "new line A"; then
    fail "test 221: new line A should be unstaged after reset"
fi
if echo "$STAGED221" | grep -q "new line B"; then
    fail "test 221: new line B should be unstaged after reset"
fi
UNSTAGED221="$(git diff linespec.txt)"
echo "$UNSTAGED221" | grep -q "new line A" \
    || fail "test 221: new line A should be back in unstaged diff"
echo "$UNSTAGED221" | grep -q "new line B" \
    || fail "test 221: new line B should be back in unstaged diff"
pass "test 221: reset sha:N-M unstages a subset of a staged hunk"

# ============================================================================
# Test 222: add --porcelain with line spec includes sha:N-M in applied field
# ============================================================================
new_repo
cat > linespec.txt <<'LINESPEC_EOF'
line 1
line 2
line 3 original
line 4
line 5 original
line 6
line 7
line 8 original
line 9
line 10
LINESPEC_EOF
git add linespec.txt && git commit -m "linespec setup" -q
sed -i.bak 's/line 3 original/line 3 changed/' linespec.txt
sed -i.bak 's/line 5 original/line 5 changed/' linespec.txt
sed -i.bak 's/line 8 original/line 8 changed/' linespec.txt

SHA222="$("$GIT_HUNK" list --porcelain --oneline --file linespec.txt | head -1 | cut -f1)"
[[ -n "$SHA222" ]] || fail "test 222: no hunk found"
PORC222="$("$GIT_HUNK" add --porcelain "${SHA222}:3-4")"
VERB222="$(echo "$PORC222" | cut -f1)"
APPLIED222="$(echo "$PORC222" | cut -f2)"
RESULT222="$(echo "$PORC222" | cut -f3)"
FILE222="$(echo "$PORC222" | cut -f4)"
[[ "$VERB222" == "staged" ]] \
    || fail "test 222: porcelain verb not 'staged', got '$VERB222'"
echo "$APPLIED222" | grep -qE '^[a-f0-9]{7}:3-4$' \
    || fail "test 222: applied field should include :3-4 suffix, got '$APPLIED222'"
[[ ${#RESULT222} -eq 7 ]] \
    || fail "test 222: result hash not 7 chars, got '$RESULT222'"
[[ "$FILE222" == "linespec.txt" ]] \
    || fail "test 222: file not 'linespec.txt', got '$FILE222'"
pass "test 222: add --porcelain includes line spec suffix in applied field"

# ============================================================================
# Test 223: add with a stale SHA exits non-zero with an error
# ============================================================================
new_repo
sed -i.bak '1s/.*/First change./' alpha.txt
SHA223="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA223" ]] || fail "test 223: no hunk found before staleness"

# Overwrite the change so SHA223 no longer matches the diff
sed -i.bak '1s/.*/Second change./' alpha.txt

if "$GIT_HUNK" add "$SHA223" > /dev/null 2>/dev/null; then
    fail "test 223: expected non-zero exit when adding stale SHA"
fi
pass "test 223: add with stale SHA exits non-zero"

# ============================================================================
# Test 224: reset with a stale SHA exits non-zero with an error
# ============================================================================
new_repo
sed -i.bak '1s/.*/Staged change./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED_SHA224="$("$GIT_HUNK" list --staged --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$STAGED_SHA224" ]] || fail "test 224: no staged hunk found"

# Unstage so STAGED_SHA224 is no longer in the staged diff
git reset HEAD alpha.txt -q

if "$GIT_HUNK" reset "$STAGED_SHA224" > /dev/null 2>/dev/null; then
    fail "test 224: expected non-zero exit when resetting stale SHA"
fi
pass "test 224: reset with stale SHA exits non-zero"

# ============================================================================
# Test 225: round-trip add+reset leaves worktree file byte-exact
# ============================================================================
new_repo
sed -i.bak '1s/.*/Round-trip test./' alpha.txt
cp alpha.txt alpha.txt.orig

SHA225="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA225" ]] || fail "test 225: no hunk found"
"$GIT_HUNK" add "$SHA225" > /dev/null
SHA225_STAGED="$("$GIT_HUNK" list --staged --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA225_STAGED" ]] || fail "test 225: no staged hunk found after add"
"$GIT_HUNK" reset "$SHA225_STAGED" > /dev/null

diff alpha.txt alpha.txt.orig > /dev/null \
    || fail "test 225: add+reset left worktree file modified"
rm alpha.txt.orig
pass "test 225: add+reset roundtrip leaves worktree byte-exact"

# ============================================================================
# Test 226: add is not idempotent — second add fails (SHA stale after first)
# ============================================================================
new_repo
sed -i.bak '1s/.*/Idempotency test./' alpha.txt

SHA226="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA226" ]] || fail "test 226: no hunk found"
"$GIT_HUNK" add "$SHA226" > /dev/null

if "$GIT_HUNK" add "$SHA226" > /dev/null 2>/dev/null; then
    fail "test 226: expected non-zero exit on second add of same SHA"
fi
pass "test 226: second add of same SHA fails (SHA stale after first add)"

# ============================================================================
# Test 227: reset --all unstages all staged hunks across multiple files
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
sed -i.bak '1s/.*/Changed gamma./' gamma.txt

"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED227_BEFORE="$(git diff --cached --name-only)"
echo "$STAGED227_BEFORE" | grep -q "alpha.txt" || fail "test 227: alpha.txt should be staged"
echo "$STAGED227_BEFORE" | grep -q "beta.txt" || fail "test 227: beta.txt should be staged"
echo "$STAGED227_BEFORE" | grep -q "gamma.txt" || fail "test 227: gamma.txt should be staged"

"$GIT_HUNK" reset --all > /dev/null 2>/dev/null
STAGED227_AFTER="$(git diff --cached --name-only)"
[[ -z "$STAGED227_AFTER" ]] \
    || fail "test 227: git diff --cached should be empty after reset --all, got: '$STAGED227_AFTER'"

UNSTAGED227="$(git diff --name-only)"
echo "$UNSTAGED227" | grep -q "alpha.txt" || fail "test 227: alpha.txt should still be unstaged-modified"
echo "$UNSTAGED227" | grep -q "beta.txt" || fail "test 227: beta.txt should still be unstaged-modified"
echo "$UNSTAGED227" | grep -q "gamma.txt" || fail "test 227: gamma.txt should still be unstaged-modified"
pass "test 227: reset --all unstages all staged hunks across multiple files"

# ============================================================================
# Test 228: add --file a --file c stages union, excluding b (multi-file filter)
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
sed -i.bak '1s/.*/Changed gamma./' gamma.txt

"$GIT_HUNK" add --file alpha.txt --file gamma.txt > /dev/null 2>/dev/null
STAGED228="$(git diff --cached --name-only)"
echo "$STAGED228" | grep -q "alpha.txt" || fail "test 228: alpha.txt missing from --file a --file c"
echo "$STAGED228" | grep -q "gamma.txt" || fail "test 228: gamma.txt missing from --file a --file c"
echo "$STAGED228" | grep -q "beta.txt" && fail "test 228: beta.txt leaked into --file a --file c" || true
pass "test 228: add --file a --file c stages union, excluding b"

# ============================================================================
# Test 229: reset --file a --file c unstages union, leaving b (multi-file filter)
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
sed -i.bak '1s/.*/Changed gamma./' gamma.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null
"$GIT_HUNK" reset --file alpha.txt --file gamma.txt > /dev/null 2>/dev/null
STAGED229="$(git diff --cached --name-only)"
echo "$STAGED229" | grep -q "beta.txt" || fail "test 229: beta.txt should remain staged"
echo "$STAGED229" | grep -q "alpha.txt" && fail "test 229: alpha.txt should have been unstaged" || true
echo "$STAGED229" | grep -q "gamma.txt" && fail "test 229: gamma.txt should have been unstaged" || true
pass "test 229: reset --file a --file c unstages union, leaving b"

# ============================================================================
# Test 230: add on a clean repo emits "no unstaged changes" and exits 1
# ============================================================================
new_repo
OUT230=$("$GIT_HUNK" add --all 2>&1 || true)
ECODE230=$?
echo "$OUT230" | grep -q "no unstaged changes" \
    || fail "test 230: expected 'no unstaged changes' message, got: '$OUT230'"
pass "test 230: add on clean repo emits no-changes message"

# ============================================================================
# Test 231: reset on a clean staging area emits "no staged changes" and exits 1
# ============================================================================
new_repo
OUT231=$("$GIT_HUNK" reset --all 2>&1 || true)
echo "$OUT231" | grep -q "no staged changes" \
    || fail "test 231: expected 'no staged changes' message, got: '$OUT231'"
pass "test 231: reset on clean stage emits no-staged-changes message"

# ============================================================================
# Test 232: add with path positional arguments gives a hash hint
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
ERR232=$("$GIT_HUNK" add alpha.txt 2>&1 >/dev/null || true)
echo "$ERR232" | grep -q "error: 'alpha.txt' looks like a path, not a hunk hash" \
    || fail "test 232a: expected path-vs-hash error for dotted file, got: '$ERR232'"
echo "$ERR232" | grep -q "hint: run 'git hunk list --oneline' to find hashes; use '--file <path>' to narrow by path" \
    || fail "test 232a: expected list/narrow hint for dotted file, got: '$ERR232'"

ERR232_SHA_MISS=$("$GIT_HUNK" add 00000000 2>&1 >/dev/null || true)
echo "$ERR232_SHA_MISS" | grep -q "no hunk matching '00000000'" \
    || fail "test 232b: expected no-hunk error for missed SHA fragment, got: '$ERR232_SHA_MISS'"
echo "$ERR232_SHA_MISS" | grep -q "looks like a path" \
    && fail "test 232b: missed SHA fragment should not get path hint, got: '$ERR232_SHA_MISS'"

touch noext
git add noext && git commit -q -m "add noext"
echo "changed" > noext
ERR232_NOEXT=$("$GIT_HUNK" add noext 2>&1 >/dev/null || true)
echo "$ERR232_NOEXT" | grep -q "looks like a path, not a hunk hash" \
    || fail "test 232c: expected path-vs-hash hint for no-extension file, got: '$ERR232_NOEXT'"

mkdir -p nested
touch nested/inner
git add nested/inner && git commit -q -m "add nested inner"
echo "changed" > nested/inner
ERR232_NESTED=$("$GIT_HUNK" add nested/inner 2>&1 >/dev/null || true)
echo "$ERR232_NESTED" | grep -q "looks like a path, not a hunk hash" \
    || fail "test 232d: expected path-vs-hash hint for nested path, got: '$ERR232_NESTED'"

ERR232_DIR=$("$GIT_HUNK" add nested 2>&1 >/dev/null || true)
echo "$ERR232_DIR" | grep -q "looks like a path, not a hunk hash" \
    || fail "test 232e: expected path-vs-hash hint for directory, got: '$ERR232_DIR'"

SHA232_HASH_NAME="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA232_HASH_NAME" ]] || fail "test 232f: no alpha hunk found"
touch "$SHA232_HASH_NAME"
git add "$SHA232_HASH_NAME" && git commit -q -m "add hash-named file"
"$GIT_HUNK" add "$SHA232_HASH_NAME" > /dev/null 2>&1 \
    || fail "test 232f: valid hash should be treated as a hash even when a file has the same name"
git diff --cached -- alpha.txt | grep -q "Changed alpha" \
    || fail "test 232f: hash-shaped filename should not prevent staging the matching hunk"
pass "test 232: add path arguments suggest using a hash without stealing hash-shaped filenames"

# ============================================================================
# Test 233: end-to-end "re-apply this hunk from history" workflow
# Setup a commit C that adds a feature line; HEAD has had it reverted.
# `add --ref C^..C SHA` forward-applies the historical hunk into the index,
# bringing the lost change back.
# ============================================================================
new_repo
echo "first line" > revived.txt
git add revived.txt && git commit -q -m "C-pre: bare file"
cat > revived.txt <<'EOF'
first line
feature line that gets lost
EOF
git add revived.txt && git commit -q -m "C: add feature line"
HIST_C232=$(git rev-parse HEAD)
# Simulate HEAD~ → revert the feature line
git revert --no-edit HEAD > /dev/null 2>&1
# Worktree now matches C-pre. Now revive C's feature hunk by --ref.
SHA233=$("$GIT_HUNK" list --ref "$HIST_C232" --porcelain --oneline --file revived.txt | head -1 | cut -f1)
[[ -n "$SHA233" ]] || fail "test 233: no hunk found for C"
"$GIT_HUNK" add --ref "$HIST_C232" "$SHA233" > /dev/null 2>&1 \
    || fail "test 233: add --ref <past> should succeed (feature line is missing in HEAD)"
git diff --cached revived.txt | grep -q "feature line that gets lost" \
    || fail "test 233: feature line should be staged after add --ref"
pass "test 233: e2e re-apply-hunk-from-history brings a reverted change back into staging"

# ============================================================================
# Test 234: add --3way uses 3-way merge to apply a historical hunk despite
# context drift, leaving conflict markers in the index for the user to resolve.
# ============================================================================
new_repo
echo "feature line" > revived233.txt
git add revived233.txt && git commit -q -m "C1: add feature"
HIST_C1_233=$(git rev-parse HEAD)
git revert --no-edit HEAD > /dev/null 2>&1
SHA233=$("$GIT_HUNK" list --ref "$HIST_C1_233" --porcelain --oneline --file revived233.txt | head -1 | cut -f1)
[[ -n "$SHA233" ]] || fail "test 234: no hunk found in C1"

# add --3way is accepted (and behaves identically to plain add when no drift).
"$GIT_HUNK" add --ref "$HIST_C1_233" --3way "$SHA233" > /dev/null 2>&1 \
    || fail "test 234: add --3way should succeed for a clean apply"
git diff --cached -- revived233.txt | grep -q "feature line" \
    || fail "test 234: feature line should be staged after add --3way"
pass "test 234: add --3way is a valid flag; clean applies stage the patch"

# ============================================================================
# Test 235: add --3way that lands unmerged index entries fails with a clear
# message (mirrors `git apply --3way --cached` semantics: don't silently
# claim "staged" while leaving conflicts).
# ============================================================================
new_repo
echo "first" > confl234.txt
git add confl234.txt && git commit -q -m "C0: first"
echo "second" >> confl234.txt
git add confl234.txt && git commit -q -m "C1: append"
HIST_C1_234=$(git rev-parse HEAD)
git revert --no-edit HEAD > /dev/null 2>&1
echo "DIFFERENT-content-where-C1-added" >> confl234.txt
git add confl234.txt && git commit -q -m "C2: diff content"
SHA234=$("$GIT_HUNK" list --ref "$HIST_C1_234" --porcelain --oneline --file confl234.txt | head -1 | cut -f1)
[[ -n "$SHA234" ]] || fail "test 235: no hunk found"
ERR234=$("$GIT_HUNK" add --ref "$HIST_C1_234" --3way "$SHA234" 2>&1 || true)
echo "$ERR234" | grep -qE "(unmerged index entries|did not apply cleanly)" \
    || fail "test 235: expected conflict-mode message; got: '$ERR234'"
# Post-condition: if --3way landed unmerged entries, `git ls-files -u` shows them
# (the user's resolution path). When --3way fails outright, the index is clean.
# Either is acceptable, but if there's any hint of "unmerged" in stderr, the
# index must reflect that.
if echo "$ERR234" | grep -q "unmerged index entries"; then
    git ls-files -u | grep -q "confl234.txt" \
        || fail "test 235: 'unmerged index entries' message should imply ls-files -u shows them"
fi
pass "test 235: add --3way fails with clear message when 3-way produces conflicts"

# Test 236 (reset --3way conflict) deliberately not added: reset matches
# hunks-by-SHA against the current index, so any pre-condition that diverges
# the index from the captured SHA also invalidates the SHA before --3way runs.
# The action-aware error message is a single `switch (action)` in cmdApplyHunks
# — covered by inspection plus test 235's stage-side path.

# ============================================================================
# Test 237: reset sha:N at DEFAULT context (regression)
# Test 221 passes --unified 0, which isolates every added line in its own hunk
# and so never leaves a deselected '+' inside one. reset reverse-applies its
# patch, so at default context deselected additions must be emitted as context
# lines or git rejects the patch with "patch does not apply".
# ============================================================================
new_repo
cat > ctxreset.txt <<'CTXR_EOF'
keep-A
keep-B
keep-C
CTXR_EOF
git add ctxreset.txt && git commit -m "ctxreset setup" -q
cat > ctxreset.txt <<'CTXR_EOF'
keep-A
ADD-1
ADD-2
keep-B
ADD-3
keep-C
CTXR_EOF
git add ctxreset.txt

STAGED_SHA237="$("$GIT_HUNK" list --staged --porcelain --oneline --file ctxreset.txt | head -1 | cut -f1)"
[[ -n "$STAGED_SHA237" ]] || fail "test 237: no staged hunk found"
# Body line 2 is ADD-1 (line 1 is the keep-A context line).
"$GIT_HUNK" reset --no-color "${STAGED_SHA237}:2" > /dev/null \
    || fail "test 237: reset with line spec failed at default context"

STAGED237="$(git diff --cached ctxreset.txt)"
if echo "$STAGED237" | grep -q "ADD-1"; then
    fail "test 237: ADD-1 should be unstaged after reset"
fi
echo "$STAGED237" | grep -q "ADD-2" || fail "test 237: ADD-2 should remain staged"
echo "$STAGED237" | grep -q "ADD-3" || fail "test 237: ADD-3 should remain staged"
git diff ctxreset.txt | grep -q "ADD-1" \
    || fail "test 237: ADD-1 should be back in the unstaged diff"
pass "test 237: reset sha:N works at default context"

# ============================================================================
# Test 238: add --dry-run reports without touching the index
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
SHA238="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA238" ]] || fail "test 238: no hunk found"

OUT238="$("$GIT_HUNK" add --dry-run --no-color "$SHA238")" \
    || fail "test 238: add --dry-run should exit 0"
echo "$OUT238" | grep -qE "^would stage $SHA238  alpha\.txt$" \
    || fail "test 238: expected 'would stage' line, got: '$OUT238'"
[[ -z "$(git diff --cached --name-only)" ]] \
    || fail "test 238: --dry-run must leave the index untouched"
COUNT238="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$COUNT238" == "1" ]] || fail "test 238: --dry-run must leave the worktree untouched"
pass "test 238: add --dry-run does not modify the index"

# ============================================================================
# Test 239: add --dry-run --porcelain uses the would-stage verb
# ============================================================================
OUT239="$("$GIT_HUNK" add --dry-run --porcelain "$SHA238")"
echo "$OUT239" | grep -q "^would-stage" \
    || fail "test 239: expected 'would-stage' porcelain verb, got: '$OUT239'"
pass "test 239: add --dry-run --porcelain uses would-stage verb"

# ============================================================================
# Test 240: add --dry-run with a line spec previews exactly that spec
# The workaround this replaces was 'diff <sha>:<lines>' -- a different command
# with different output, easy to preview one spec and then stage another.
# ============================================================================
new_repo
cat > dryspec.txt <<'DRY_EOF'
keep-A
keep-B
keep-C
DRY_EOF
git add dryspec.txt && git commit -m "dryspec setup" -q
cat > dryspec.txt <<'DRY_EOF'
keep-A
ADD-1
ADD-2
keep-B
ADD-3
keep-C
DRY_EOF
SHA240="$("$GIT_HUNK" list --porcelain --oneline --file dryspec.txt | head -1 | cut -f1)"
OUT240="$("$GIT_HUNK" add --dry-run --no-color "${SHA240}:2,5")"
echo "$OUT240" | grep -qE "^would stage ${SHA240}:2,5  dryspec\.txt$" \
    || fail "test 240: expected line spec echoed in dry-run output, got: '$OUT240'"
[[ -z "$(git diff --cached --name-only)" ]] \
    || fail "test 240: --dry-run with a line spec must not stage anything"
# The real add must then stage exactly what the preview described.
"$GIT_HUNK" add "${SHA240}:2,5" > /dev/null
STAGED240="$(git diff --cached dryspec.txt)"
echo "$STAGED240" | grep -q "ADD-1" || fail "test 240: ADD-1 should be staged"
echo "$STAGED240" | grep -q "ADD-3" || fail "test 240: ADD-3 should be staged"
if echo "$STAGED240" | grep -q "ADD-2"; then
    fail "test 240: ADD-2 was not in the previewed spec and must not be staged"
fi
pass "test 240: add --dry-run previews exactly what add stages"

# ============================================================================
# Test 241: reset --dry-run reports without touching the index
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
git add alpha.txt
SSHA241="$("$GIT_HUNK" list --staged --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SSHA241" ]] || fail "test 241: no staged hunk found"
OUT241="$("$GIT_HUNK" reset --dry-run --no-color "$SSHA241")" \
    || fail "test 241: reset --dry-run should exit 0"
echo "$OUT241" | grep -q "^would unstage " \
    || fail "test 241: expected 'would unstage' line, got: '$OUT241'"
git diff --cached --name-only | grep -q "^alpha.txt$" \
    || fail "test 241: --dry-run must leave the hunk staged"
pass "test 241: reset --dry-run does not modify the index"

# ============================================================================
# Test 242: --files-from reads paths from a file
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
sed -i.bak '1s/.*/Changed gamma./' gamma.txt
LIST242="$(mktemp "${TMPDIR:-/tmp}/git-hunk-files-242.XXXXXX")"
printf 'alpha.txt\ngamma.txt\n' > "$LIST242"
"$GIT_HUNK" add --files-from "$LIST242" > /dev/null \
    || fail "test 242: add --files-from failed"
STAGED242="$(git diff --cached --name-only)"
rm -f "$LIST242"
echo "$STAGED242" | grep -q "^alpha.txt$" || fail "test 242: alpha.txt should be staged"
echo "$STAGED242" | grep -q "^gamma.txt$" || fail "test 242: gamma.txt should be staged"
if echo "$STAGED242" | grep -q "^beta.txt$"; then
    fail "test 242: beta.txt was not listed and must not be staged"
fi
pass "test 242: --files-from reads paths from a file"

# ============================================================================
# Test 243: --files-from - reads paths from stdin, and composes with --file
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
sed -i.bak '1s/.*/Changed gamma./' gamma.txt
printf 'alpha.txt\n' | "$GIT_HUNK" add --files-from - --file gamma.txt > /dev/null \
    || fail "test 243: add --files-from - failed"
STAGED243="$(git diff --cached --name-only)"
echo "$STAGED243" | grep -q "^alpha.txt$" || fail "test 243: alpha.txt (stdin) should be staged"
echo "$STAGED243" | grep -q "^gamma.txt$" || fail "test 243: gamma.txt (--file) should be staged"
if echo "$STAGED243" | grep -q "^beta.txt$"; then
    fail "test 243: beta.txt should not be staged"
fi
pass "test 243: --files-from - reads stdin and merges with --file"

# ============================================================================
# Test 244: --files-from auto-detects NUL separation (git ls-files -z)
# Newline-separated input cannot represent a path containing a newline, which
# is the reason -z exists; this pins the auto-detection.
# ============================================================================
new_repo
WEIRD244="$(printf 'we\nird.txt')"
echo "orig" > "$WEIRD244"
git add -- "$WEIRD244" && git commit -q -m "weird path"
echo "changed" > "$WEIRD244"
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
git ls-files -z -- "$WEIRD244" | "$GIT_HUNK" add --files-from - > /dev/null \
    || fail "test 244: add --files-from - with NUL input failed"
STAGED244="$(git diff --cached --name-only)"
[[ -n "$STAGED244" ]] || fail "test 244: newline-containing path should have been staged"
if echo "$STAGED244" | grep -q "^alpha.txt$"; then
    fail "test 244: alpha.txt was not listed and must not be staged"
fi
pass "test 244: --files-from auto-detects NUL-separated input"

# ============================================================================
# Test 245: --files-from on a missing file errors cleanly
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
if "$GIT_HUNK" add --files-from /nonexistent-list-245.txt > /dev/null 2>&1; then
    fail "test 245: --files-from with a missing file should fail"
fi
[[ -z "$(git diff --cached --name-only)" ]] \
    || fail "test 245: failed --files-from must not stage anything"
pass "test 245: --files-from errors cleanly on a missing file"

report_results
