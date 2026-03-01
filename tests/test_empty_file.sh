#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 74: list shows empty untracked file
# ============================================================================
new_repo
touch empty.txt

COUNT74="$("$GIT_HUNK" count)"
[[ "$COUNT74" == "1" ]] || fail "test 74: expected 1 hunk for empty file, got $COUNT74"
OUT74="$("$GIT_HUNK" list --porcelain --oneline)"
echo "$OUT74" | grep -q 'empty.txt' \
    || fail "test 74: expected empty.txt in list output, got: '$OUT74'"
echo "$OUT74" | grep -qE '^[a-f0-9]{7}\t' \
    || fail "test 74: expected SHA prefix in porcelain output"
pass "test 74: list shows empty untracked file"

# ============================================================================
# Test 75: add stages empty untracked file
# ============================================================================
new_repo
touch empty.txt

SHA75="$("$GIT_HUNK" list --porcelain --oneline | grep empty.txt | cut -f1)"
[[ -n "$SHA75" ]] || fail "test 75: no SHA for empty file"
"$GIT_HUNK" add "$SHA75" > /dev/null
STATUS75="$(git status --short empty.txt)"
[[ "$STATUS75" == "A  empty.txt" ]] \
    || fail "test 75: expected 'A  empty.txt' after add, got '$STATUS75'"
pass "test 75: add stages empty untracked file"

# ============================================================================
# Test 76: reset unstages empty file
# ============================================================================
new_repo
touch empty.txt

SHA76="$("$GIT_HUNK" list --porcelain --oneline | grep empty.txt | cut -f1)"
"$GIT_HUNK" add "$SHA76" > /dev/null
STAGED_SHA76="$("$GIT_HUNK" list --staged --porcelain --oneline | grep empty.txt | cut -f1)"
[[ -n "$STAGED_SHA76" ]] || fail "test 76: no staged SHA for empty file"
"$GIT_HUNK" reset "$STAGED_SHA76" > /dev/null
STATUS76="$(git status --short empty.txt)"
[[ "$STATUS76" == "?? empty.txt" ]] \
    || fail "test 76: expected '?? empty.txt' after reset, got '$STATUS76'"
pass "test 76: reset unstages empty file"

# ============================================================================
# Test 77: show displays patch header for empty file
# ============================================================================
new_repo
touch empty.txt

SHA77="$("$GIT_HUNK" list --porcelain --oneline | grep empty.txt | cut -f1)"
SHOW77="$("$GIT_HUNK" show "$SHA77")"
echo "$SHOW77" | grep -q 'new file mode' \
    || fail "test 77: expected 'new file mode' in show output"
echo "$SHOW77" | grep -q '\-\-\- /dev/null' \
    || fail "test 77: expected '--- /dev/null' in show output"
echo "$SHOW77" | grep -q '+++ b/empty.txt' \
    || fail "test 77: expected '+++ b/empty.txt' in show output"
pass "test 77: show displays patch header for empty file"

# ============================================================================
# Test 78: stash roundtrip for empty untracked file
# ============================================================================
new_repo
touch empty.txt

SHA78="$("$GIT_HUNK" list --porcelain --oneline | grep empty.txt | cut -f1)"
"$GIT_HUNK" stash "$SHA78" > /dev/null
[[ ! -f empty.txt ]] || fail "test 78: expected empty.txt removed after stash"
STASH78="$(git stash list)"
[[ -n "$STASH78" ]] || fail "test 78: expected non-empty stash list"

"$GIT_HUNK" stash pop > /dev/null
[[ -f empty.txt ]] || fail "test 78: expected empty.txt restored after pop"
SIZE78="$(wc -c < empty.txt | tr -d ' ')"
[[ "$SIZE78" == "0" ]] || fail "test 78: expected 0 bytes after pop, got $SIZE78"
STASH_AFTER78="$(git stash list)"
[[ -z "$STASH_AFTER78" ]] || fail "test 78: expected empty stash list after pop"
pass "test 78: stash roundtrip for empty untracked file"

# ============================================================================
# Test 79: add --all includes empty files
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
touch empty.txt

COUNT79="$("$GIT_HUNK" count)"
[[ "$COUNT79" == "2" ]] || fail "test 79: expected 2 hunks before --all, got $COUNT79"
"$GIT_HUNK" add --all > /dev/null
UNSTAGED79="$("$GIT_HUNK" count)"
[[ "$UNSTAGED79" == "0" ]] \
    || fail "test 79: expected 0 unstaged after --all, got $UNSTAGED79"
STATUS79="$(git status --short empty.txt)"
[[ "$STATUS79" == "A  empty.txt" ]] \
    || fail "test 79: expected 'A  empty.txt', got '$STATUS79'"
pass "test 79: add --all includes empty files"

# ============================================================================
# Test 80: stash --all with --include-untracked includes empty files
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
touch empty.txt

"$GIT_HUNK" stash --all --include-untracked > /dev/null
[[ ! -f empty.txt ]] || fail "test 80: expected empty.txt removed after stash --all -u"
ALPHA80="$(head -1 alpha.txt)"
[[ "$ALPHA80" != "Changed alpha." ]] \
    || fail "test 80: expected alpha.txt reverted after stash --all"
STASH80="$(git stash list)"
[[ -n "$STASH80" ]] || fail "test 80: expected non-empty stash list"

"$GIT_HUNK" stash pop > /dev/null
[[ -f empty.txt ]] || fail "test 80: expected empty.txt restored after pop"
[[ "$(head -1 alpha.txt)" == "Changed alpha." ]] \
    || fail "test 80: expected alpha.txt restored after pop"
pass "test 80: stash --all --include-untracked includes empty files"

# ============================================================================
# Test 81: deleted empty file shows up in staged mode
# ============================================================================
new_repo
touch empty.txt && git add empty.txt && git commit -m "add empty file" -q
git rm -q empty.txt

COUNT81="$("$GIT_HUNK" count --staged)"
[[ "$COUNT81" == "1" ]] || fail "test 81: expected 1 staged hunk for deleted empty file, got $COUNT81"
OUT81="$("$GIT_HUNK" list --staged --porcelain --oneline)"
echo "$OUT81" | grep -q 'empty.txt' \
    || fail "test 81: expected empty.txt in staged list output, got: '$OUT81'"
SHA81="$(echo "$OUT81" | grep empty.txt | cut -f1)"
SHOW81="$("$GIT_HUNK" show "$SHA81" --staged)"
echo "$SHOW81" | grep -q 'deleted file mode' \
    || fail "test 81: expected 'deleted file mode' in show output"
"$GIT_HUNK" reset "$SHA81" > /dev/null
STATUS81="$(git status --short empty.txt)"
[[ "$STATUS81" == " D empty.txt" ]] \
    || fail "test 81: expected ' D empty.txt' after reset (unstaged deletion), got '$STATUS81'"
pass "test 81: deleted empty file shows up in staged mode"

# ============================================================================
# Test 82: filenames with spaces
# ============================================================================
new_repo
touch "empty file.txt"

COUNT82="$("$GIT_HUNK" count)"
[[ "$COUNT82" == "1" ]] || fail "test 82: expected 1 hunk for file with spaces, got $COUNT82"
OUT82="$("$GIT_HUNK" list --porcelain --oneline)"
echo "$OUT82" | grep -q 'empty file.txt' \
    || fail "test 82: expected 'empty file.txt' in list output, got: '$OUT82'"
SHA82="$(echo "$OUT82" | grep 'empty file.txt' | cut -f1)"
[[ -n "$SHA82" ]] || fail "test 82: no SHA for file with spaces"
"$GIT_HUNK" add "$SHA82" > /dev/null
STATUS82="$(git status --short "empty file.txt")"
[[ "$STATUS82" == 'A  "empty file.txt"' ]] \
    || fail "test 82: expected 'A  \"empty file.txt\"' after add, got '$STATUS82'"
pass "test 82: filenames with spaces"

report_results
