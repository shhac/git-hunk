#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# T23 — Content bytes: non-UTF-8 payloads and line-ending normalisation
#
# Unicode *filenames* are covered in test_edge_cases.sh. This file covers the
# diff *body*: bytes that no decoder should touch, and bytes that git itself
# deliberately rewrites between blob and worktree.
# ============================================================================

# Latin-1 and lone high bytes. Not valid UTF-8 in any position, but git still
# treats the file as text (no NUL byte), so it goes through the normal
# line-oriented diff path rather than the binary path.
OLD_LATIN='caf\xe9 na\xefve\nsecond \xff\xfe line\nthird \xc0\xc1 line\n'
NEW_LATIN='caf\xe9 na\xefve\nCHANGED \xff\xfe line\nthird \xc0\xc1 line\n'

latin_repo() {
    new_repo
    printf "$OLD_LATIN" > latin.txt
    git add latin.txt && git commit -q -m "add latin.txt"
    printf "$NEW_LATIN" > latin.txt
}

# ============================================================================
# Test 1700: a non-UTF-8 file diffs as text, not as binary
# ============================================================================
latin_repo
LIST1700="$("$GIT_HUNK" list --porcelain 2>/dev/null)"
[[ -n "$LIST1700" ]] || fail "test 1700: no hunk listed for a non-UTF-8 file"
echo "$LIST1700" | grep -q "binary" \
    && fail "test 1700: non-UTF-8 text file was treated as binary"
pass "test 1700: non-UTF-8 file listed as a text hunk"

# ============================================================================
# Test 1701: add stages the exact high bytes
# ============================================================================
SHA1701="$(first_sha)"
"$GIT_HUNK" add "$SHA1701" > /dev/null 2>&1 || fail "test 1701: add failed"
GOT1701="$(blob_bytes :latin.txt)"; WANT1701="$(want_bytes "$NEW_LATIN")"
[[ "$GOT1701" == "$WANT1701" ]] \
    || fail "test 1701: staged blob bytes wrong"$'\n'"  got:  $GOT1701"$'\n'"  want: $WANT1701"
pass "test 1701: add preserves non-UTF-8 bytes exactly"

# ============================================================================
# Test 1702: add then reset leaves the worktree byte-identical
# ============================================================================
latin_repo
BEFORE1702="$(bytes_of latin.txt)"
SHA1702="$(first_sha)"
"$GIT_HUNK" add "$SHA1702" > /dev/null 2>&1 || fail "test 1702: add failed"
"$GIT_HUNK" reset "$(first_sha --staged)" > /dev/null 2>&1 || fail "test 1702: reset failed"
[[ -z "$(git diff --cached --name-only)" ]] || fail "test 1702: index not clean after reset"
[[ "$(bytes_of latin.txt)" == "$BEFORE1702" ]] \
    || fail "test 1702: worktree bytes changed by add/reset"$'\n'"  before: $BEFORE1702"$'\n'"  after:  $(bytes_of latin.txt)"
pass "test 1702: add/reset round-trip preserves non-UTF-8 bytes"

# ============================================================================
# Test 1703: restore returns the exact committed high bytes
# ============================================================================
latin_repo
"$GIT_HUNK" restore "$(first_sha)" > /dev/null 2>&1 || fail "test 1703: restore failed"
GOT1703="$(bytes_of latin.txt)"; WANT1703="$(want_bytes "$OLD_LATIN")"
[[ "$GOT1703" == "$WANT1703" ]] \
    || fail "test 1703: restored bytes wrong"$'\n'"  got:  $GOT1703"$'\n'"  want: $WANT1703"
pass "test 1703: restore preserves non-UTF-8 bytes exactly"

# ============================================================================
# Test 1704: commit writes the exact high bytes into the tree
# ============================================================================
latin_repo
"$GIT_HUNK" commit "$(first_sha)" -m "latin commit" > /dev/null 2>&1 \
    || fail "test 1704: commit failed"
GOT1704="$(blob_bytes "HEAD:latin.txt")"; WANT1704="$(want_bytes "$NEW_LATIN")"
[[ "$GOT1704" == "$WANT1704" ]] \
    || fail "test 1704: committed blob bytes wrong"$'\n'"  got:  $GOT1704"$'\n'"  want: $WANT1704"
pass "test 1704: commit preserves non-UTF-8 bytes exactly"

# ============================================================================
# Test 1705: a high byte in the hunk's own preview column does not corrupt
# the listing or the hash
# ============================================================================
latin_repo
SHA_A="$(first_sha)"
SHA_B="$(first_sha)"
[[ -n "$SHA_A" && "$SHA_A" == "$SHA_B" ]] \
    || fail "test 1705: hash is unstable across runs ('$SHA_A' vs '$SHA_B')"
"$GIT_HUNK" check "$SHA_A" > /dev/null 2>&1 \
    || fail "test 1705: check rejected a hash from a non-UTF-8 file"
pass "test 1705: hashes over non-UTF-8 content are stable"

# ============================================================================
# T23b — Line-ending normalisation
#
# With core.autocrlf / core.eol / a `text=auto` attribute, worktree bytes and
# blob bytes deliberately differ. git-hunk must land in exactly the same place
# plain git does: the staged blob must match `git add`, and a restore must
# match `git checkout --`.
# ============================================================================

CRLF_OLD='l1\r\nl2\r\nl3\r\nl4\r\nl5\r\n'
CRLF_NEW='l1\r\nCHANGED\r\nl3\r\nl4\r\nl5\r\n'

# Build a CRLF repo under the eol config named by $1 (a shell snippet).
crlf_repo() {
    new_repo
    eval "$1"
    printf "$CRLF_OLD" > crlf.txt
    git add crlf.txt 2>/dev/null && git commit -q -m "add crlf.txt"
    printf "$CRLF_NEW" > crlf.txt
}

EOL_NAMES=(autocrlf-true autocrlf-input text-auto-eol-crlf no-normalisation)
EOL_SETUP=(
    'git config core.autocrlf true'
    'git config core.autocrlf input'
    'git config core.eol crlf; printf "* text=auto\n" > .git/info/attributes'
    'true'
)

# ============================================================================
# Tests 1710-1713: the staged blob matches what plain `git add` would produce
# ============================================================================
for i in "${!EOL_NAMES[@]}"; do
    N=$((1710 + i)); NAME="${EOL_NAMES[$i]}"
    # Reference: what plain git stages.
    crlf_repo "${EOL_SETUP[$i]}"
    git add crlf.txt 2>/dev/null
    REF="$(blob_bytes :crlf.txt)"
    [[ -n "$REF" ]] || fail "test $N ($NAME): reference blob is empty"
    # Subject: what git-hunk stages.
    crlf_repo "${EOL_SETUP[$i]}"
    SHA="$(first_sha)"
    [[ -n "$SHA" ]] || fail "test $N ($NAME): no hunk listed"
    "$GIT_HUNK" add "$SHA" > /dev/null 2>&1 || fail "test $N ($NAME): add failed"
    GOT="$(blob_bytes :crlf.txt)"
    [[ "$GOT" == "$REF" ]] \
        || fail "test $N ($NAME): staged blob differs from plain git add"$'\n'"  git-hunk: $GOT"$'\n'"  git add:  $REF"
    pass "test $N: staged blob matches plain git add ($NAME)"
done

# ============================================================================
# Tests 1714-1717: add then reset leaves worktree bytes untouched
# ============================================================================
for i in "${!EOL_NAMES[@]}"; do
    N=$((1714 + i)); NAME="${EOL_NAMES[$i]}"
    crlf_repo "${EOL_SETUP[$i]}"
    BEFORE="$(bytes_of crlf.txt)"
    SHA="$(first_sha)"
    "$GIT_HUNK" add "$SHA" > /dev/null 2>&1 || fail "test $N ($NAME): add failed"
    "$GIT_HUNK" reset "$(first_sha --staged)" > /dev/null 2>&1 || fail "test $N ($NAME): reset failed"
    [[ -z "$(git diff --cached --name-only)" ]] || fail "test $N ($NAME): index not clean after reset"
    [[ "$(bytes_of crlf.txt)" == "$BEFORE" ]] \
        || fail "test $N ($NAME): add/reset changed worktree bytes"$'\n'"  before: $BEFORE"$'\n'"  after:  $(bytes_of crlf.txt)"
    pass "test $N: add/reset leaves worktree bytes untouched ($NAME)"
done

# ============================================================================
# Tests 1718-1721: restore lands where `git checkout --` lands
#
# Under core.autocrlf=input git does not convert on checkout, so the reference
# itself comes back as LF. Pinning against git's own answer rather than the
# pre-edit bytes is the point: git-hunk must not invent a third behaviour.
# ============================================================================
for i in "${!EOL_NAMES[@]}"; do
    N=$((1718 + i)); NAME="${EOL_NAMES[$i]}"
    crlf_repo "${EOL_SETUP[$i]}"
    git checkout -- crlf.txt
    REF="$(bytes_of crlf.txt)"
    crlf_repo "${EOL_SETUP[$i]}"
    SHA="$(first_sha)"
    "$GIT_HUNK" restore "$SHA" > /dev/null 2>&1 || fail "test $N ($NAME): restore failed"
    GOT="$(bytes_of crlf.txt)"
    [[ "$GOT" == "$REF" ]] \
        || fail "test $N ($NAME): restore differs from git checkout --"$'\n'"  git-hunk: $GOT"$'\n'"  git:      $REF"
    pass "test $N: restore matches git checkout -- ($NAME)"
done

report_results
