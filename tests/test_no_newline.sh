#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# T22 — `\ No newline at end of file`, end to end
#
# Patches are rebuilt by hand and applied with --unidiff-zero, so the marker is
# the most plausible place for a silent byte-level regression. Every assertion
# below compares the resulting file/blob bytes, not just an exit code.
# ============================================================================

# Byte-exact rendering of a file, for comparison and for failure messages.
bytes_of() { od -An -c "$1" | tr -s ' \n' ' '; }
# Byte-exact rendering of an index or HEAD blob. $1 is a git object spec.
blob_bytes() { git cat-file -p "$1" | od -An -c | tr -s ' \n' ' '; }
# Byte-exact rendering of a printf format string, as the expected value.
want_bytes() { printf "$1" | od -An -c | tr -s ' \n' ' '; }

# Build a one-file repo: $1 committed content, $2 worktree content (printf fmts).
nl_repo() {
    new_repo
    printf "$1" > nl.txt
    git add nl.txt && git commit -q -m "commit nl.txt"
    printf "$2" > nl.txt
}

first_sha() { "$GIT_HUNK" list --porcelain "$@" 2>/dev/null | grep -oE '^[0-9a-f]{7}' | head -1; }

# The four sides of the cross-product. `NL` = trailing newline present.
#   OLD_NL_NEW_NONL : marker appears only on the new side
#   OLD_NONL_NEW_NL : marker appears only on the old side
#   BOTH_NONL       : marker on both sides
#   NONL_UNTOUCHED  : file ends without a newline, but the change is elsewhere
CASE_NAMES=(OLD_NL_NEW_NONL OLD_NONL_NEW_NL BOTH_NONL NONL_UNTOUCHED)
CASE_OLD=('l1\nl2\nl3\n' 'l1\nl2\nl3'      'l1\nl2\nl3'      'l1\nl2\nl3')
CASE_NEW=('l1\nl2\nCHANGED' 'l1\nl2\nCHANGED\n' 'l1\nl2\nCHANGED' 'l1\nCHANGED\nl3')

# ============================================================================
# Tests 1600-1603: add stages the exact new bytes
# ============================================================================
for i in "${!CASE_NAMES[@]}"; do
    N=$((1600 + i)); NAME="${CASE_NAMES[$i]}"
    nl_repo "${CASE_OLD[$i]}" "${CASE_NEW[$i]}"
    SHA="$(first_sha)"
    [[ -n "$SHA" ]] || fail "test $N ($NAME): no hunk listed"
    "$GIT_HUNK" add "$SHA" > /dev/null 2>&1 || fail "test $N ($NAME): add failed"
    GOT="$(blob_bytes :nl.txt)"; WANT="$(want_bytes "${CASE_NEW[$i]}")"
    [[ "$GOT" == "$WANT" ]] \
        || fail "test $N ($NAME): staged blob bytes wrong"$'\n'"  got:  $GOT"$'\n'"  want: $WANT"
    pass "test $N: add stages exact bytes ($NAME)"
done

# ============================================================================
# Tests 1604-1607: add then reset leaves the worktree byte-identical and the
# index clean
# ============================================================================
for i in "${!CASE_NAMES[@]}"; do
    N=$((1604 + i)); NAME="${CASE_NAMES[$i]}"
    nl_repo "${CASE_OLD[$i]}" "${CASE_NEW[$i]}"
    BEFORE="$(bytes_of nl.txt)"
    SHA="$(first_sha)"
    "$GIT_HUNK" add "$SHA" > /dev/null 2>&1 || fail "test $N ($NAME): add failed"
    STAGED_SHA="$(first_sha --staged)"
    [[ -n "$STAGED_SHA" ]] || fail "test $N ($NAME): nothing listed as staged"
    "$GIT_HUNK" reset "$STAGED_SHA" > /dev/null 2>&1 || fail "test $N ($NAME): reset failed"
    [[ -z "$(git diff --cached --name-only)" ]] \
        || fail "test $N ($NAME): index not clean after reset"
    AFTER="$(bytes_of nl.txt)"
    [[ "$BEFORE" == "$AFTER" ]] \
        || fail "test $N ($NAME): reset changed worktree bytes"$'\n'"  before: $BEFORE"$'\n'"  after:  $AFTER"
    pass "test $N: add/reset round-trip is byte-exact ($NAME)"
done

# ============================================================================
# Tests 1608-1611: restore returns the exact committed bytes
# ============================================================================
for i in "${!CASE_NAMES[@]}"; do
    N=$((1608 + i)); NAME="${CASE_NAMES[$i]}"
    nl_repo "${CASE_OLD[$i]}" "${CASE_NEW[$i]}"
    SHA="$(first_sha)"
    "$GIT_HUNK" restore "$SHA" > /dev/null 2>&1 || fail "test $N ($NAME): restore failed"
    GOT="$(bytes_of nl.txt)"; WANT="$(want_bytes "${CASE_OLD[$i]}")"
    [[ "$GOT" == "$WANT" ]] \
        || fail "test $N ($NAME): restored bytes wrong"$'\n'"  got:  $GOT"$'\n'"  want: $WANT"
    [[ "$("$GIT_HUNK" count)" == "0" ]] \
        || fail "test $N ($NAME): hunks remain after restore"
    pass "test $N: restore returns exact committed bytes ($NAME)"
done

# ============================================================================
# Tests 1612-1615: commit writes the exact new bytes into the tree
# ============================================================================
for i in "${!CASE_NAMES[@]}"; do
    N=$((1612 + i)); NAME="${CASE_NAMES[$i]}"
    nl_repo "${CASE_OLD[$i]}" "${CASE_NEW[$i]}"
    SHA="$(first_sha)"
    "$GIT_HUNK" commit "$SHA" -m "commit $NAME" > /dev/null 2>&1 \
        || fail "test $N ($NAME): commit failed"
    [[ "$(git log -1 --format=%s)" == "commit $NAME" ]] \
        || fail "test $N ($NAME): commit did not land"
    GOT="$(blob_bytes "HEAD:nl.txt")"; WANT="$(want_bytes "${CASE_NEW[$i]}")"
    [[ "$GOT" == "$WANT" ]] \
        || fail "test $N ($NAME): committed blob bytes wrong"$'\n'"  got:  $GOT"$'\n'"  want: $WANT"
    pass "test $N: commit writes exact bytes ($NAME)"
done

# ============================================================================
# Test 1616: a line spec that selects only the trailing no-newline change
#
# One hunk holds two changes: the first line, and the last line which lacks a
# trailing newline on both sides. Selecting the trailing pair alone must stage
# it — and only it — with the missing newline preserved.
# ============================================================================
nl_repo 'l1\nl2\nl3\nl4\nl5' 'FIRST\nl2\nl3\nl4\nLAST'
SHA1616="$(first_sha)"
"$GIT_HUNK" add "$SHA1616:6-7" > /dev/null 2>&1 \
    || fail "test 1616: add with line spec failed"
GOT1616="$(blob_bytes :nl.txt)"; WANT1616="$(want_bytes 'l1\nl2\nl3\nl4\nLAST')"
[[ "$GOT1616" == "$WANT1616" ]] \
    || fail "test 1616: wrong bytes staged"$'\n'"  got:  $GOT1616"$'\n'"  want: $WANT1616"
pass "test 1616: line spec selects only the no-newline change"

# ============================================================================
# Test 1617: the inverse spec leaves the no-newline change unstaged, and the
# staged blob still ends without a newline
# ============================================================================
nl_repo 'l1\nl2\nl3\nl4\nl5' 'FIRST\nl2\nl3\nl4\nLAST'
SHA1617="$(first_sha)"
"$GIT_HUNK" add "$SHA1617:1-2" > /dev/null 2>&1 \
    || fail "test 1617: add with line spec failed"
GOT1617="$(blob_bytes :nl.txt)"; WANT1617="$(want_bytes 'FIRST\nl2\nl3\nl4\nl5')"
[[ "$GOT1617" == "$WANT1617" ]] \
    || fail "test 1617: wrong bytes staged"$'\n'"  got:  $GOT1617"$'\n'"  want: $WANT1617"
pass "test 1617: line spec leaves the no-newline change unstaged"

# ============================================================================
# Test 1618: restore with a line spec on a no-newline hunk
# ============================================================================
nl_repo 'l1\nl2\nl3\nl4\nl5' 'FIRST\nl2\nl3\nl4\nLAST'
SHA1618="$(first_sha)"
"$GIT_HUNK" restore "$SHA1618:6-7" > /dev/null 2>&1 \
    || fail "test 1618: restore with line spec failed"
GOT1618="$(bytes_of nl.txt)"; WANT1618="$(want_bytes 'FIRST\nl2\nl3\nl4\nl5')"
[[ "$GOT1618" == "$WANT1618" ]] \
    || fail "test 1618: wrong bytes after restore"$'\n'"  got:  $GOT1618"$'\n'"  want: $WANT1618"
pass "test 1618: restore with line spec on a no-newline hunk"

# ============================================================================
# Test 1619: at --unified 0 the trailing change is its own hunk and stages
# independently of the leading one
# ============================================================================
nl_repo 'l1\nl2\nl3\nl4\nl5' 'FIRST\nl2\nl3\nl4\nLAST'
SHAS1619="$("$GIT_HUNK" list -U0 --porcelain 2>/dev/null | grep -oE '^[0-9a-f]{7}')"
[[ "$(echo "$SHAS1619" | wc -l | tr -d ' ')" == "2" ]] \
    || fail "test 1619: expected 2 hunks at -U0, got:"$'\n'"$SHAS1619"
LAST1619="$(echo "$SHAS1619" | tail -1)"
"$GIT_HUNK" add -U0 "$LAST1619" > /dev/null 2>&1 \
    || fail "test 1619: add at -U0 failed"
GOT1619="$(blob_bytes :nl.txt)"; WANT1619="$(want_bytes 'l1\nl2\nl3\nl4\nLAST')"
[[ "$GOT1619" == "$WANT1619" ]] \
    || fail "test 1619: wrong bytes staged at -U0"$'\n'"  got:  $GOT1619"$'\n'"  want: $WANT1619"
pass "test 1619: -U0 stages the no-newline hunk independently"

# ============================================================================
# Test 1620: stash of a no-newline hunk restores byte-exactly on pop
# ============================================================================
nl_repo 'l1\nl2\nl3' 'l1\nl2\nCHANGED'
BEFORE1620="$(bytes_of nl.txt)"
SHA1620="$(first_sha)"
"$GIT_HUNK" stash "$SHA1620" > /dev/null 2>&1 || fail "test 1620: stash failed"
GOT1620="$(bytes_of nl.txt)"; WANT1620="$(want_bytes 'l1\nl2\nl3')"
[[ "$GOT1620" == "$WANT1620" ]] \
    || fail "test 1620: worktree wrong after stash"$'\n'"  got:  $GOT1620"$'\n'"  want: $WANT1620"
git stash pop -q 2>/dev/null || fail "test 1620: stash pop failed"
[[ "$(bytes_of nl.txt)" == "$BEFORE1620" ]] \
    || fail "test 1620: stash pop did not restore exact bytes"
pass "test 1620: stash/pop of a no-newline hunk is byte-exact"

report_results
