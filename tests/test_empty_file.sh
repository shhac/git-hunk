#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 800: list shows empty untracked file
# ============================================================================
new_repo
touch empty.txt

COUNT800="$("$GIT_HUNK" count)"
[[ "$COUNT800" == "1" ]] || fail "test 800: expected 1 hunk for empty file, got $COUNT800"
OUT800="$("$GIT_HUNK" list --porcelain --oneline)"
echo "$OUT800" | grep -q 'empty.txt' \
    || fail "test 800: expected empty.txt in list output, got: '$OUT800'"
echo "$OUT800" | grep -qE '^[a-f0-9]{7}\t' \
    || fail "test 800: expected SHA prefix in porcelain output"
pass "test 800: list shows empty untracked file"

# ============================================================================
# Test 801: add stages empty untracked file
# ============================================================================
new_repo
touch empty.txt

SHA801="$("$GIT_HUNK" list --porcelain --oneline | grep empty.txt | cut -f1)"
[[ -n "$SHA801" ]] || fail "test 801: no SHA for empty file"
"$GIT_HUNK" add "$SHA801" > /dev/null
STATUS801="$(git status --short empty.txt)"
[[ "$STATUS801" == "A  empty.txt" ]] \
    || fail "test 801: expected 'A  empty.txt' after add, got '$STATUS801'"
pass "test 801: add stages empty untracked file"

# ============================================================================
# Test 802: reset unstages empty file
# ============================================================================
new_repo
touch empty.txt

SHA802="$("$GIT_HUNK" list --porcelain --oneline | grep empty.txt | cut -f1)"
"$GIT_HUNK" add "$SHA802" > /dev/null
STAGED_SHA802="$("$GIT_HUNK" list --staged --porcelain --oneline | grep empty.txt | cut -f1)"
[[ -n "$STAGED_SHA802" ]] || fail "test 802: no staged SHA for empty file"
"$GIT_HUNK" reset "$STAGED_SHA802" > /dev/null
STATUS802="$(git status --short empty.txt)"
[[ "$STATUS802" == "?? empty.txt" ]] \
    || fail "test 802: expected '?? empty.txt' after reset, got '$STATUS802'"
pass "test 802: reset unstages empty file"

# ============================================================================
# Test 803: diff displays patch header for empty file
# ============================================================================
new_repo
touch empty.txt

SHA803="$("$GIT_HUNK" list --porcelain --oneline | grep empty.txt | cut -f1)"
DIFF803="$("$GIT_HUNK" diff "$SHA803")"
echo "$DIFF803" | grep -q 'new file mode' \
    || fail "test 803: expected 'new file mode' in diff output"
echo "$DIFF803" | grep -q '\-\-\- /dev/null' \
    || fail "test 803: expected '--- /dev/null' in diff output"
echo "$DIFF803" | grep -q '+++ b/empty.txt' \
    || fail "test 803: expected '+++ b/empty.txt' in diff output"
pass "test 803: diff displays patch header for empty file"

# ============================================================================
# Test 804: stash roundtrip for empty untracked file
# ============================================================================
new_repo
touch empty.txt

SHA804="$("$GIT_HUNK" list --porcelain --oneline | grep empty.txt | cut -f1)"
"$GIT_HUNK" stash "$SHA804" > /dev/null
[[ ! -f empty.txt ]] || fail "test 804: expected empty.txt removed after stash"
STASH804="$(git stash list)"
[[ -n "$STASH804" ]] || fail "test 804: expected non-empty stash list"

"$GIT_HUNK" stash pop > /dev/null
[[ -f empty.txt ]] || fail "test 804: expected empty.txt restored after pop"
SIZE804="$(wc -c < empty.txt | tr -d ' ')"
[[ "$SIZE804" == "0" ]] || fail "test 804: expected 0 bytes after pop, got $SIZE804"
STASH_AFTER804="$(git stash list)"
[[ -z "$STASH_AFTER804" ]] || fail "test 804: expected empty stash list after pop"
pass "test 804: stash roundtrip for empty untracked file"

# ============================================================================
# Test 805: add --all includes empty files
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
touch empty.txt

COUNT805="$("$GIT_HUNK" count)"
[[ "$COUNT805" == "2" ]] || fail "test 805: expected 2 hunks before --all, got $COUNT805"
"$GIT_HUNK" add --all > /dev/null
UNSTAGED805="$("$GIT_HUNK" count)"
[[ "$UNSTAGED805" == "0" ]] \
    || fail "test 805: expected 0 unstaged after --all, got $UNSTAGED805"
STATUS805="$(git status --short empty.txt)"
[[ "$STATUS805" == "A  empty.txt" ]] \
    || fail "test 805: expected 'A  empty.txt', got '$STATUS805'"
pass "test 805: add --all includes empty files"

# ============================================================================
# Test 806: stash --all with --include-untracked includes empty files
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
touch empty.txt

"$GIT_HUNK" stash --all --include-untracked > /dev/null
[[ ! -f empty.txt ]] || fail "test 806: expected empty.txt removed after stash --all -u"
ALPHA806="$(head -1 alpha.txt)"
[[ "$ALPHA806" != "Changed alpha." ]] \
    || fail "test 806: expected alpha.txt reverted after stash --all"
STASH806="$(git stash list)"
[[ -n "$STASH806" ]] || fail "test 806: expected non-empty stash list"

"$GIT_HUNK" stash pop > /dev/null
[[ -f empty.txt ]] || fail "test 806: expected empty.txt restored after pop"
[[ "$(head -1 alpha.txt)" == "Changed alpha." ]] \
    || fail "test 806: expected alpha.txt restored after pop"
pass "test 806: stash --all --include-untracked includes empty files"

# ============================================================================
# Test 807: deleted empty file shows up in staged mode
# ============================================================================
new_repo
touch empty.txt && git add empty.txt && git commit -m "add empty file" -q
git rm -q empty.txt

COUNT807="$("$GIT_HUNK" count --staged)"
[[ "$COUNT807" == "1" ]] || fail "test 807: expected 1 staged hunk for deleted empty file, got $COUNT807"
OUT807="$("$GIT_HUNK" list --staged --porcelain --oneline)"
echo "$OUT807" | grep -q 'empty.txt' \
    || fail "test 807: expected empty.txt in staged list output, got: '$OUT807'"
SHA807="$(echo "$OUT807" | grep empty.txt | cut -f1)"
DIFF807="$("$GIT_HUNK" diff "$SHA807" --staged)"
echo "$DIFF807" | grep -q 'deleted file mode' \
    || fail "test 807: expected 'deleted file mode' in diff output"
"$GIT_HUNK" reset "$SHA807" > /dev/null
STATUS807="$(git status --short empty.txt)"
[[ "$STATUS807" == " D empty.txt" ]] \
    || fail "test 807: expected ' D empty.txt' after reset (unstaged deletion), got '$STATUS807'"
pass "test 807: deleted empty file shows up in staged mode"

# ============================================================================
# Test 808: filenames with spaces
# ============================================================================
new_repo
touch "empty file.txt"

COUNT808="$("$GIT_HUNK" count)"
[[ "$COUNT808" == "1" ]] || fail "test 808: expected 1 hunk for file with spaces, got $COUNT808"
OUT808="$("$GIT_HUNK" list --porcelain --oneline)"
echo "$OUT808" | grep -q 'empty file.txt' \
    || fail "test 808: expected 'empty file.txt' in list output, got: '$OUT808'"
SHA808="$(echo "$OUT808" | grep 'empty file.txt' | cut -f1)"
[[ -n "$SHA808" ]] || fail "test 808: no SHA for file with spaces"
"$GIT_HUNK" add "$SHA808" > /dev/null
STATUS808="$(git status --short "empty file.txt")"
[[ "$STATUS808" == 'A  "empty file.txt"' ]] \
    || fail "test 808: expected 'A  \"empty file.txt\"' after add, got '$STATUS808'"
pass "test 808: filenames with spaces"

report_results
