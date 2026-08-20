#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# T25 — An inherited git environment
#
# Hooks, rebases, filter-branch and CI all run commands with GIT_DIR,
# GIT_WORK_TREE or GIT_INDEX_FILE already exported. git-hunk sets
# GIT_INDEX_FILE itself for the temp index its commit path builds, so it has
# to compose with a caller that already set one rather than fight it.
#
# The policy pinned here is: defer to the caller's environment exactly as any
# other git command would. Where that is not obviously right, the assertion
# compares against what plain git does rather than against a hand-picked
# answer.
# ============================================================================

# Two independent hunks so "only the selected one moved" is provable.
env_repo() {
    new_repo
    sed -i.bak '5s/.*/Changed alpha line five./' alpha.txt
    sed -i.bak '5s/.*/Changed beta line five./' beta.txt
}

# ============================================================================
# Test 1900: the harness scrubs an inherited git environment
#
# Without this, a caller's GIT_DIR would redirect every test in the suite at
# whatever repository it named — asserting against, and writing to, someone
# else's repo.
# ============================================================================
# pwd -P: on macOS mktemp hands back /var/... while git reports /private/var/...,
# and a plain string comparison would pass without proving anything.
DECOY1900="$(cd "$(mktemp -d)" && pwd -P)"
(
    cd "$DECOY1900"
    command git init -q .
    command git config user.email "test@git-hunk.test"
    command git config user.name "git-hunk test"
    echo decoy > decoy.txt
    command git add . && command git commit -q -m "decoy"
)
DECOY_HEAD1900="$(command git -C "$DECOY1900" rev-parse HEAD)"
# A probe script that uses the harness exactly as a test script does. It has to
# live beside harness.sh, because the harness resolves its own directory from
# BASH_SOURCE of the script that sourced it. The name is dot-prefixed so
# run-all.sh's test_*.sh glob never picks it up, and pid-suffixed so two
# concurrent runs do not delete each other's.
PROBE1900="$SCRIPT_DIR/.probe-git-env.$$.sh"
cat > "$PROBE1900" <<'PROBE'
source "$(dirname "$0")/harness.sh" "$1"
new_repo
git rev-parse --show-toplevel
PROBE
GIT_DIR="$DECOY1900/.git" GIT_WORK_TREE="$DECOY1900" GIT_INDEX_FILE="$DECOY1900/.git/index" \
    bash "$PROBE1900" "$GIT_HUNK" > "$DECOY1900/toplevel" 2>/dev/null \
    || fail "test 1900: harness failed under an inherited git environment"
rm -f "$PROBE1900"
TOP1900="$(cat "$DECOY1900/toplevel")"
[[ "$TOP1900" != "$DECOY1900" ]] \
    || fail "test 1900: an inherited GIT_DIR redirected the harness at the decoy repo"
[[ "$(command git -C "$DECOY1900" rev-parse HEAD)" == "$DECOY_HEAD1900" ]] \
    || fail "test 1900: the decoy repo was written to"
rm -rf "$DECOY1900"
pass "test 1900: harness ignores an inherited git environment"

# ============================================================================
# Test 1901: with GIT_INDEX_FILE inherited, list reads that index
# ============================================================================
env_repo
ALT1901="$CURRENT_REPO/alt.index"
cp .git/index "$ALT1901"
BASE1901="$("$GIT_HUNK" list --porcelain 2>/dev/null)"
ALT_LIST1901="$(GIT_INDEX_FILE="$ALT1901" "$GIT_HUNK" list --porcelain 2>/dev/null)"
[[ -n "$BASE1901" && "$ALT_LIST1901" == "$BASE1901" ]] \
    || fail "test 1901: listing differed against an identical copy of the index"
pass "test 1901: list honours an inherited GIT_INDEX_FILE"

# ============================================================================
# Test 1902: add writes to the inherited index and leaves the repo index alone
# ============================================================================
SHA1902="$(first_sha --file alpha.txt)"
[[ -n "$SHA1902" ]] || fail "test 1902: no hunk for alpha.txt"
GIT_INDEX_FILE="$ALT1901" "$GIT_HUNK" add "$SHA1902" > /dev/null 2>&1 \
    || fail "test 1902: add failed under an inherited GIT_INDEX_FILE"
ALT_STAGED1902="$(GIT_INDEX_FILE="$ALT1901" git diff --cached --name-only)"
[[ "$ALT_STAGED1902" == "alpha.txt" ]] \
    || fail "test 1902: expected alpha.txt staged in the alt index, got '$ALT_STAGED1902'"
[[ -z "$(git diff --cached --name-only)" ]] \
    || fail "test 1902: the repo's own index was modified: '$(git diff --cached --name-only)'"
pass "test 1902: add writes to the inherited index, not the repo's"

# ============================================================================
# Test 1903: commit composes with an inherited GIT_INDEX_FILE
#
# The commit path builds its own temp index via GIT_INDEX_FILE. That must not
# collide with the caller's, and must not leave the caller's index deleted.
# ============================================================================
env_repo
ALT1903="$CURRENT_REPO/alt.index"
cp .git/index "$ALT1903"
SHA1903="$(first_sha --file alpha.txt)"
GIT_INDEX_FILE="$ALT1903" "$GIT_HUNK" commit "$SHA1903" -m "alpha only" > /dev/null 2>&1 \
    || fail "test 1903: commit failed under an inherited GIT_INDEX_FILE"
[[ "$(git log -1 --format=%s)" == "alpha only" ]] \
    || fail "test 1903: commit did not land"
FILES1903="$(git show --stat --format= HEAD | grep -c 'alpha.txt')"
[[ "$FILES1903" == "1" ]] || fail "test 1903: alpha.txt missing from the commit"
git show --stat --format= HEAD | grep -q 'beta.txt' \
    && fail "test 1903: beta.txt leaked into the commit"
[[ -f "$ALT1903" ]] \
    || fail "test 1903: the caller's index file was deleted"
pass "test 1903: commit composes with an inherited GIT_INDEX_FILE"

# ============================================================================
# Test 1904: the temp index the commit path creates does not survive
#
# TMPDIR is redirected at an empty directory of our own, so the check is exact
# rather than a count of shared /tmp entries that other runs also write to.
# ============================================================================
env_repo
TMPD1904="$CURRENT_REPO/tmpdir"
mkdir -p "$TMPD1904"
TMPDIR="$TMPD1904" "$GIT_HUNK" commit "$(first_sha --file alpha.txt)" -m "temp index check" > /dev/null 2>&1 \
    || fail "test 1904: commit failed"
LEFT1904="$(ls -A "$TMPD1904")"
[[ -z "$LEFT1904" ]] \
    || fail "test 1904: commit left files in TMPDIR: '$LEFT1904'"
[[ "$(git log -1 --format=%s)" == "temp index check" ]] \
    || fail "test 1904: commit did not land"
pass "test 1904: commit builds its temp index under TMPDIR and removes it"

# ============================================================================
# Test 1905: GIT_DIR + GIT_WORK_TREE from outside the repo
# ============================================================================
env_repo
REPO1905="$CURRENT_REPO"
OUT1905="$(cd /tmp && GIT_DIR="$REPO1905/.git" GIT_WORK_TREE="$REPO1905" \
    "$GIT_HUNK" list --porcelain 2>/dev/null)"
echo "$OUT1905" | grep -q "alpha.txt" \
    || fail "test 1905: alpha.txt hunk missing when driven via GIT_DIR/GIT_WORK_TREE"
echo "$OUT1905" | grep -q "beta.txt" \
    || fail "test 1905: beta.txt hunk missing when driven via GIT_DIR/GIT_WORK_TREE"
SHA1905="$(echo "$OUT1905" | grep -oE '^[0-9a-f]{7}' | head -1)"
(cd /tmp && GIT_DIR="$REPO1905/.git" GIT_WORK_TREE="$REPO1905" \
    "$GIT_HUNK" add "$SHA1905" > /dev/null 2>&1) \
    || fail "test 1905: add failed when driven via GIT_DIR/GIT_WORK_TREE"
[[ -n "$(git diff --cached --name-only)" ]] \
    || fail "test 1905: add via GIT_DIR/GIT_WORK_TREE staged nothing"
pass "test 1905: driven correctly from outside the repo via GIT_DIR/GIT_WORK_TREE"

# ============================================================================
# Test 1906: a GIT_DIR naming another repo is deferred to, exactly as plain
# git defers to it — git-hunk must not invent a third answer
# ============================================================================
# new_repo deletes the previous repo, so the other repo is built outside the
# harness's single-repo slot and cleaned up by hand.
OTHER1906="$(bash "$SETUP")"
(
    cd "$OTHER1906"
    sed -i.bak '5s/.*/Changed alpha line five./' alpha.txt
    sed -i.bak '5s/.*/Changed beta line five./' beta.txt
)
new_repo
sed -i.bak '5s/.*/Changed gamma line five./' gamma.txt
GIT_FILES1906="$(GIT_DIR="$OTHER1906/.git" git diff --name-only | sort | tr '\n' ' ')"
HUNK_FILES1906="$(GIT_DIR="$OTHER1906/.git" "$GIT_HUNK" list --porcelain 2>/dev/null \
    | grep -E '^[0-9a-f]{7}' | cut -f2 | sort -u | tr '\n' ' ')"
[[ -n "$GIT_FILES1906" ]] \
    || fail "test 1906: reference git diff was empty, comparison would be vacuous"
[[ "$HUNK_FILES1906" == "$GIT_FILES1906" ]] \
    || fail "test 1906: git-hunk and git disagree under an inherited GIT_DIR"$'\n'"  git-hunk: '$HUNK_FILES1906'"$'\n'"  git:      '$GIT_FILES1906'"
rm -rf "$OTHER1906"
pass "test 1906: an inherited GIT_DIR resolves the same way plain git resolves it"

report_results
