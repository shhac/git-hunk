#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# T20 — External / textconv diff drivers
#
# `git diff` is the parse basis for every command. A `diff.external` config
# key, an exported GIT_EXTERNAL_DIFF, or a `diff.<driver>.textconv` filter all
# change what git writes to stdout — the first two to *nothing at all*, with
# exit 0, which is indistinguishable from a clean tree.
# ============================================================================

# A program that consumes an external-diff invocation and prints nothing.
# `true` lives in different places on macOS and Linux, so resolve it.
TRUE_BIN="$(command -v true)"

# Build a repo with one modified tracked file and one untracked file, so both
# the `git diff` path and the `git diff --no-index` path are exercised.
setup_driver_repo() {
    new_repo
    printf 'l%s\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 > driver.txt
    git add driver.txt && git commit -q -m "add driver.txt"
    printf 'l%s\n' 1 TWO 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 SEVENTEEN 20 > driver.txt
    printf 'fresh\nlines\n' > driver-new.txt
}

# Install a textconv driver that uppercases the blob. The converted text is
# readable but does not apply back to the real content.
install_textconv() {
    git config diff.upper.textconv "tr a-z A-Z <"
    echo 'driver.txt diff=upper' > .git/info/attributes
}

# ============================================================================
# Test 1500: baseline is non-empty (guards every comparison below from
# passing vacuously against two empty strings)
# ============================================================================
setup_driver_repo
BASE_LIST="$("$GIT_HUNK" list --porcelain 2>/dev/null)"
BASE_COUNT="$("$GIT_HUNK" count 2>/dev/null)"
[[ -n "$BASE_LIST" && "$BASE_COUNT" -ge 3 ]] \
    || fail "test 1500: baseline is empty or too small (count='$BASE_COUNT'), later comparisons would be vacuous"
pass "test 1500: baseline diff is non-empty"

# ============================================================================
# Test 1501: diff.external does not blank out the hunk listing
# ============================================================================
git config diff.external "$TRUE_BIN"
EXT_LIST="$("$GIT_HUNK" list --porcelain 2>/dev/null)"
[[ "$EXT_LIST" == "$BASE_LIST" ]] \
    || fail "test 1501: diff.external changed list output"$'\n'"--- expected ---"$'\n'"$BASE_LIST"$'\n'"--- got ---"$'\n'"$EXT_LIST"
pass "test 1501: list unaffected by diff.external"

# ============================================================================
# Test 1502: count / diff / check agree under diff.external
# ============================================================================
ALL_SHAS="$(echo "$BASE_LIST" | cut -f1 | grep -E '^[0-9a-f]{7}$' | tr '\n' ' ')"
BASE_DIFF="$("$GIT_HUNK" diff $ALL_SHAS 2>/dev/null)"
EXT_COUNT="$("$GIT_HUNK" count 2>/dev/null)"
[[ "$EXT_COUNT" == "$BASE_COUNT" ]] \
    || fail "test 1502: count under diff.external was '$EXT_COUNT', expected '$BASE_COUNT'"
EXT_DIFF="$("$GIT_HUNK" diff $ALL_SHAS 2>/dev/null)"
[[ -n "$BASE_DIFF" && "$EXT_DIFF" == "$BASE_DIFF" ]] \
    || fail "test 1502: diff output changed under diff.external"
FIRST_SHA="$(echo "$BASE_LIST" | head -1 | cut -f1)"
"$GIT_HUNK" check "$FIRST_SHA" > /dev/null 2>&1 \
    || fail "test 1502: check failed under diff.external"
pass "test 1502: count/diff/check unaffected by diff.external"

# ============================================================================
# Test 1503: add applies identically under diff.external
# ============================================================================
"$GIT_HUNK" add "$FIRST_SHA" > /dev/null 2>&1 \
    || fail "test 1503: add failed under diff.external"
STAGED1503="$(git diff --cached --numstat --no-ext-diff | tr -s ' \t' ' ')"
[[ "$STAGED1503" == "1 1 driver.txt" ]] \
    || fail "test 1503: expected '1 1 driver.txt' staged, got '$STAGED1503'"
git config --unset diff.external
pass "test 1503: add applies correctly under diff.external"

# ============================================================================
# Test 1504: exported GIT_EXTERNAL_DIFF does not blank out the listing
# ============================================================================
setup_driver_repo
BASE_LIST="$("$GIT_HUNK" list --porcelain 2>/dev/null)"
ENV_LIST="$(GIT_EXTERNAL_DIFF="$TRUE_BIN" "$GIT_HUNK" list --porcelain 2>/dev/null)"
[[ -n "$BASE_LIST" && "$ENV_LIST" == "$BASE_LIST" ]] \
    || fail "test 1504: GIT_EXTERNAL_DIFF changed list output"
ENV_COUNT="$(GIT_EXTERNAL_DIFF="$TRUE_BIN" "$GIT_HUNK" count 2>/dev/null)"
[[ "$ENV_COUNT" == "$BASE_COUNT" ]] \
    || fail "test 1504: count under GIT_EXTERNAL_DIFF was '$ENV_COUNT', expected '$BASE_COUNT'"
pass "test 1504: list/count unaffected by GIT_EXTERNAL_DIFF"

# ============================================================================
# Test 1505: untracked files still listed under an external diff driver
# (the untracked path is a separate `git diff --no-index` call site)
# ============================================================================
UNTRACKED1505="$(GIT_EXTERNAL_DIFF="$TRUE_BIN" "$GIT_HUNK" list --porcelain --untracked-only 2>/dev/null)"
echo "$UNTRACKED1505" | grep -q "driver-new.txt" \
    || fail "test 1505: untracked file missing under GIT_EXTERNAL_DIFF: '$UNTRACKED1505'"
pass "test 1505: untracked hunks survive an external diff driver"

# ============================================================================
# Test 1506: mutating commands work under GIT_EXTERNAL_DIFF
# ============================================================================
SHA1506="$(echo "$BASE_LIST" | grep -F 'driver.txt' | head -1 | cut -f1)"
GIT_EXTERNAL_DIFF="$TRUE_BIN" "$GIT_HUNK" add "$SHA1506" > /dev/null 2>&1 \
    || fail "test 1506: add failed under GIT_EXTERNAL_DIFF"
STAGED1506="$(git diff --cached --numstat --no-ext-diff | tr -s ' \t' ' ')"
[[ "$STAGED1506" == "1 1 driver.txt" ]] \
    || fail "test 1506: expected '1 1 driver.txt' staged, got '$STAGED1506'"
STAGED_SHA1506="$(GIT_EXTERNAL_DIFF="$TRUE_BIN" "$GIT_HUNK" list --staged --porcelain 2>/dev/null | head -1 | cut -f1)"
GIT_EXTERNAL_DIFF="$TRUE_BIN" "$GIT_HUNK" reset "$STAGED_SHA1506" > /dev/null 2>&1 \
    || fail "test 1506: reset failed under GIT_EXTERNAL_DIFF"
[[ -z "$(git diff --cached --name-only --no-ext-diff)" ]] \
    || fail "test 1506: reset under GIT_EXTERNAL_DIFF left changes staged"
pass "test 1506: add/reset round-trip under GIT_EXTERNAL_DIFF"

# ============================================================================
# Test 1507: a textconv driver does not leak converted text into the listing
# ============================================================================
setup_driver_repo
SHAS1507="$("$GIT_HUNK" list --porcelain --file driver.txt 2>/dev/null | cut -f1 | grep -E '^[0-9a-f]{7}$' | tr '\n' ' ')"
BASE_DIFF1507="$("$GIT_HUNK" diff $SHAS1507 2>/dev/null)"
install_textconv
TC_DIFF="$("$GIT_HUNK" diff $SHAS1507 2>/dev/null)"
[[ -n "$BASE_DIFF1507" && "$TC_DIFF" == "$BASE_DIFF1507" ]] \
    || fail "test 1507: textconv changed diff output"$'\n'"--- expected ---"$'\n'"$BASE_DIFF1507"$'\n'"--- got ---"$'\n'"$TC_DIFF"
# The driver uppercases the blob, so converted output would read "L1"/"L20"
# where the real content reads "l1"/"l20".
echo "$TC_DIFF" | grep -q "L20" \
    && fail "test 1507: uppercased (textconv) text leaked into diff output"
echo "$TC_DIFF" | grep -q "l20" \
    || fail "test 1507: real (lowercase) content missing from diff output"
pass "test 1507: textconv does not alter diff output"

# ============================================================================
# Test 1508: hunks from a textconv path still apply
# ============================================================================
SHA1508="$("$GIT_HUNK" list --porcelain --file driver.txt 2>/dev/null | head -1 | cut -f1)"
[[ -n "$SHA1508" ]] || fail "test 1508: no hunk listed for a textconv path"
"$GIT_HUNK" add "$SHA1508" > /dev/null 2>&1 \
    || fail "test 1508: add failed for a hunk on a textconv path"
STAGED1508="$(git diff --cached --numstat --no-ext-diff --no-textconv | tr -s ' \t' ' ')"
[[ "$STAGED1508" == "1 1 driver.txt" ]] \
    || fail "test 1508: expected '1 1 driver.txt' staged, got '$STAGED1508'"
BLOB1508="$(git cat-file -p :driver.txt)"
[[ "$BLOB1508" == "$(printf 'l%s\n' 1 TWO 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)" ]] \
    || fail "test 1508: staged blob was mangled by textconv:"$'\n'"$BLOB1508"
pass "test 1508: textconv hunks stage the real blob content"

# ============================================================================
# Test 1509: restore under a textconv driver restores real bytes
# ============================================================================
setup_driver_repo
install_textconv
SHA1509="$("$GIT_HUNK" list --porcelain --file driver.txt 2>/dev/null | head -1 | cut -f1)"
"$GIT_HUNK" restore "$SHA1509" > /dev/null 2>&1 \
    || fail "test 1509: restore failed on a textconv path"
[[ "$(cat driver.txt)" == "$(printf 'l%s\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 SEVENTEEN 20)" ]] \
    || fail "test 1509: restore under textconv produced wrong bytes:"$'\n'"$(cat driver.txt)"
pass "test 1509: restore under textconv writes real bytes"

# ============================================================================
# Test 1510: commit under an external diff driver
# ============================================================================
setup_driver_repo
SHA1510="$("$GIT_HUNK" list --porcelain --file driver.txt 2>/dev/null | head -1 | cut -f1)"
git config diff.external "$TRUE_BIN"
GIT_EXTERNAL_DIFF="$TRUE_BIN" "$GIT_HUNK" commit "$SHA1510" -m "hostile driver commit" > /dev/null 2>&1 \
    || fail "test 1510: commit failed under external diff drivers"
[[ "$(git log -1 --format=%s)" == "hostile driver commit" ]] \
    || fail "test 1510: commit did not land"
COMMITTED1510="$(git show --stat --format= --no-ext-diff HEAD | tr -s ' ' | grep -c 'driver.txt')"
[[ "$COMMITTED1510" == "1" ]] \
    || fail "test 1510: expected driver.txt in the commit"
git config --unset diff.external
pass "test 1510: commit works under external diff drivers"

report_results
