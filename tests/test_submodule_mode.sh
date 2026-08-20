#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# T24 — Changes git-hunk deliberately has no hash for
#
# Two kinds of change carry no line-level content: a submodule pointer bump
# (mode 160000) and a mode flip (100644 → 100755). Both are documented skips
# — they have nothing a line spec could address, and `git add <path>` is the
# whole operation. These tests pin the skip, pin that it does not leak into
# neighbouring content hunks, and pin that `--verbose` names the skipped path
# so a tree git calls dirty is never reported here as having nothing to do.
# ============================================================================

# A standalone repo with two commits, to be used as a submodule.
make_submodule_source() {
    SUBSRC="$(mktemp -d)"
    (
        cd "$SUBSRC"
        git init -q .
        git config user.email "test@git-hunk.test"
        git config user.name "git-hunk test"
        echo "first" > s.txt && git add . && git commit -q -m "sub commit 1"
        echo "second" > s.txt && git commit -q -a -m "sub commit 2"
    )
    SUB_OLD="$(git -C "$SUBSRC" rev-parse HEAD~1)"
    SUB_NEW="$(git -C "$SUBSRC" rev-parse HEAD)"
}

# Repo with `sub` committed at SUB_OLD and checked out at SUB_NEW, i.e. an
# unstaged gitlink bump.
submodule_repo() {
    new_repo
    git -c protocol.file.allow=always submodule add -q "$SUBSRC" sub 2>/dev/null \
        || fail "setup: submodule add failed"
    git -C sub checkout -q "$SUB_OLD"
    git add . && git commit -q -m "add submodule at old pointer"
    git -C sub checkout -q "$SUB_NEW"
}

make_submodule_source
trap 'rm -rf "$SUBSRC"; cleanup_repo' EXIT

# ============================================================================
# Test 1800: the fixture really does produce a gitlink diff
# (without this the skip assertions below would pass vacuously)
# ============================================================================
submodule_repo
git diff --no-ext-diff | grep -q "160000" \
    || fail "test 1800: fixture produced no gitlink diff:"$'\n'"$(git diff --no-ext-diff)"
[[ "$(git status --porcelain sub)" == " M sub" ]] \
    || fail "test 1800: expected sub to be modified, got '$(git status --porcelain sub)'"
pass "test 1800: fixture produces an unstaged submodule pointer bump"

# ============================================================================
# Test 1801: a submodule bump produces no hunk
# ============================================================================
[[ -z "$("$GIT_HUNK" list --porcelain 2>/dev/null)" ]] \
    || fail "test 1801: expected no hunks, got:"$'\n'"$("$GIT_HUNK" list --porcelain 2>/dev/null)"
[[ "$("$GIT_HUNK" count 2>/dev/null)" == "0" ]] \
    || fail "test 1801: expected count 0, got '$("$GIT_HUNK" count 2>/dev/null)'"
pass "test 1801: submodule pointer bump produces no hunk"

# ============================================================================
# Test 1802: --verbose names the submodule so the skip is not silent
# ============================================================================
NOTE1802="$("$GIT_HUNK" count --verbose 2>&1 >/dev/null)"
echo "$NOTE1802" | grep -q "sub: submodule pointer change has no hunk" \
    || fail "test 1802: expected a note naming the submodule, got '$NOTE1802'"
[[ -z "$("$GIT_HUNK" count 2>&1 >/dev/null)" ]] \
    || fail "test 1802: non-verbose count should print no note"
pass "test 1802: --verbose reports the skipped submodule"

# ============================================================================
# Test 1803: `add --all` alongside a submodule bump stages the file changes
# and leaves the gitlink alone
# ============================================================================
submodule_repo
sed -i.bak '5s/.*/Changed line five./' alpha.txt
LIST1803="$("$GIT_HUNK" list --porcelain 2>/dev/null)"
echo "$LIST1803" | grep -q "alpha.txt" \
    || fail "test 1803: alpha.txt hunk missing alongside a submodule bump"
echo "$LIST1803" | grep -q "sub" \
    && fail "test 1803: submodule appeared in the listing"
"$GIT_HUNK" add --all > /dev/null 2>&1 || fail "test 1803: add --all failed"
[[ "$(git status --porcelain sub)" == " M sub" ]] \
    || fail "test 1803: add --all touched the gitlink: '$(git status --porcelain sub)'"
[[ "$(git status --porcelain alpha.txt)" == "M  alpha.txt" ]] \
    || fail "test 1803: alpha.txt not staged: '$(git status --porcelain alpha.txt)'"
pass "test 1803: add --all stages files and leaves the gitlink unstaged"

# ============================================================================
# Test 1804: a staged submodule bump is likewise not listed, and `check
# --exclusive --staged` does not invent a hunk for it
# ============================================================================
submodule_repo
git add sub
[[ "$("$GIT_HUNK" count --staged 2>/dev/null)" == "0" ]] \
    || fail "test 1804: staged gitlink produced a hunk"
"$GIT_HUNK" check --exclusive --allow-empty --staged > /dev/null 2>&1 \
    || fail "test 1804: check --exclusive --staged failed on a staged gitlink"
pass "test 1804: staged gitlink neither listed nor flagged by check"

# ============================================================================
# Test 1805: restore leaves a submodule alone even with --all
# ============================================================================
submodule_repo
BEFORE1805="$(git -C sub rev-parse HEAD)"
"$GIT_HUNK" restore --all > /dev/null 2>&1 || true
[[ "$(git -C sub rev-parse HEAD)" == "$BEFORE1805" ]] \
    || fail "test 1805: restore --all moved the submodule pointer"
pass "test 1805: restore --all leaves the submodule pointer alone"

# ============================================================================
# T24b — Pure mode changes
# ============================================================================

# alpha.txt gets a mode change only; beta.txt gets both a mode change and a
# content change. gamma.txt is the control: content only.
mode_repo() {
    new_repo
    chmod +x alpha.txt
    chmod +x beta.txt
    sed -i.bak '5s/.*/Changed beta line five./' beta.txt
    sed -i.bak '5s/.*/Changed gamma line five./' gamma.txt
}

# ============================================================================
# Test 1810: the fixture really does produce a mode-change diff
# ============================================================================
mode_repo
git diff --no-ext-diff | grep -q "new mode 100755" \
    || fail "test 1810: fixture produced no mode change"
pass "test 1810: fixture produces mode changes"

# ============================================================================
# Test 1811: a mode-only change produces no hunk
# ============================================================================
[[ -z "$("$GIT_HUNK" list --porcelain --file alpha.txt 2>/dev/null)" ]] \
    || fail "test 1811: mode-only change produced a hunk for alpha.txt"
pass "test 1811: mode-only change produces no hunk"

# ============================================================================
# Test 1812: --verbose names both the mode-only file and the mode+content file
# ============================================================================
NOTE1812="$("$GIT_HUNK" list --verbose 2>&1 >/dev/null)"
echo "$NOTE1812" | grep -q "alpha.txt: mode change has no hunk" \
    || fail "test 1812: no note for the mode-only file, got '$NOTE1812'"
echo "$NOTE1812" | grep -q "beta.txt: mode change has no hunk" \
    || fail "test 1812: no note for the mode+content file, got '$NOTE1812'"
echo "$NOTE1812" | grep -q "gamma.txt" \
    && fail "test 1812: content-only file was reported as skipped"
pass "test 1812: --verbose reports mode changes, including alongside content"

# ============================================================================
# Test 1813: staging the content hunk of a mode+content file leaves the mode
# change unstaged
# ============================================================================
SHA1813="$(first_sha --file beta.txt)"
[[ -n "$SHA1813" ]] || fail "test 1813: no content hunk for beta.txt"
"$GIT_HUNK" add "$SHA1813" > /dev/null 2>&1 || fail "test 1813: add failed"
RAW1813="$(git diff --cached --raw -- beta.txt)"
echo "$RAW1813" | grep -q "^:100644 100644 " \
    || fail "test 1813: mode change leaked into the index: '$RAW1813'"
[[ "$(git status --porcelain beta.txt)" == "MM beta.txt" ]] \
    || fail "test 1813: expected 'MM beta.txt', got '$(git status --porcelain beta.txt)'"
pass "test 1813: staging content leaves the mode change unstaged"

# ============================================================================
# Test 1814: the content hunk's hash is unchanged by the mode change
#
# The same edit, with and without a mode flip, must hash identically —
# otherwise a chmod would silently invalidate every hash a caller holds.
# ============================================================================
new_repo
sed -i.bak '5s/.*/Changed beta line five./' beta.txt
PLAIN1814="$(first_sha --file beta.txt)"
chmod +x beta.txt
CHMOD1814="$(first_sha --file beta.txt)"
[[ -n "$PLAIN1814" && "$PLAIN1814" == "$CHMOD1814" ]] \
    || fail "test 1814: hash changed with the mode ('$PLAIN1814' → '$CHMOD1814')"
pass "test 1814: a mode change does not alter the content hunk's hash"

# ============================================================================
# Test 1815: reset of the content hunk leaves an already-staged mode change
# in place (the mode lives only in the index, so a careless reset to HEAD
# would silently drop it)
# ============================================================================
new_repo
chmod +x beta.txt
git update-index --chmod=+x beta.txt
sed -i.bak '5s/.*/Changed beta line five./' beta.txt
SHA1815="$(first_sha --file beta.txt)"
"$GIT_HUNK" add "$SHA1815" > /dev/null 2>&1 || fail "test 1815: add failed"
STAGED1815="$(first_sha --staged --file beta.txt)"
"$GIT_HUNK" reset "$STAGED1815" > /dev/null 2>&1 || fail "test 1815: reset failed"
RAW1815="$(git ls-files --stage -- beta.txt | cut -d' ' -f1)"
[[ "$RAW1815" == "100755" ]] \
    || fail "test 1815: reset reverted the staged mode, index mode is '$RAW1815'"
pass "test 1815: reset of a content hunk preserves the staged mode"

# ============================================================================
# Test 1816: restore of the content hunk leaves the worktree mode alone
# ============================================================================
mode_repo
SHA1816="$(first_sha --file beta.txt)"
"$GIT_HUNK" restore "$SHA1816" > /dev/null 2>&1 || fail "test 1816: restore failed"
[[ -x beta.txt ]] || fail "test 1816: restore cleared the executable bit"
git diff --no-ext-diff -- beta.txt | grep -q "new mode 100755" \
    || fail "test 1816: mode change disappeared after restore"
pass "test 1816: restore of a content hunk preserves the worktree mode"

# ============================================================================
# Test 1817: commit of the content hunk does not carry the mode change
# ============================================================================
mode_repo
SHA1817="$(first_sha --file beta.txt)"
"$GIT_HUNK" commit "$SHA1817" -m "beta content only" > /dev/null 2>&1 \
    || fail "test 1817: commit failed"
MODE1817="$(git ls-tree HEAD -- beta.txt | cut -d' ' -f1)"
[[ "$MODE1817" == "100644" ]] \
    || fail "test 1817: commit carried the mode change, tree mode is '$MODE1817'"
git diff --no-ext-diff -- beta.txt | grep -q "new mode 100755" \
    || fail "test 1817: mode change lost from the worktree diff after commit"
pass "test 1817: commit of a content hunk excludes the mode change"

report_results
