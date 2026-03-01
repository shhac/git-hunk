#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 700: basic stash push by SHA
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

SHA700="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" stash "$SHA700" > /dev/null
STASH_LIST700="$(git stash list)"
[[ -n "$STASH_LIST700" ]] || fail "test 700: expected non-empty stash list"
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 700: expected alpha.txt reverted to committed content"
[[ "$(head -1 beta.txt)" == "Changed beta." ]] \
    || fail "test 700: beta.txt should be unchanged"
pass "test 700: basic stash push by SHA"

# ============================================================================
# Test 701: stash pop roundtrip
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

SHA701="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" stash "$SHA701" > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] || fail "test 701: not reverted after stash"

"$GIT_HUNK" stash pop > /dev/null 2>/dev/null
[[ "$(head -1 alpha.txt)" == "Changed alpha." ]] \
    || fail "test 701: expected alpha.txt restored after pop"
STASH_LIST701="$(git stash list)"
[[ -z "$STASH_LIST701" ]] || fail "test 701: expected empty stash list after pop"
pass "test 701: stash pop roundtrip"

# ============================================================================
# Test 702: stash --all
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"
ORIG_BETA="$(git show HEAD:beta.txt | head -1)"

"$GIT_HUNK" stash --all > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 702: expected alpha.txt reverted"
[[ "$(head -1 beta.txt)" == "$ORIG_BETA" ]] \
    || fail "test 702: expected beta.txt reverted"
git stash show > /dev/null 2>/dev/null \
    || fail "test 702: git stash show should succeed"
pass "test 702: stash --all"

# ============================================================================
# Test 703: stash -m custom message
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

"$GIT_HUNK" stash --all -m "custom stash msg" > /dev/null
STASH_LIST703="$(git stash list)"
echo "$STASH_LIST703" | grep -q "custom stash msg" \
    || fail "test 703: expected 'custom stash msg' in stash list, got '$STASH_LIST703'"
pass "test 703: stash -m custom message"

# ============================================================================
# Test 704: stash --file filter
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

"$GIT_HUNK" stash --file alpha.txt > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 704: expected alpha.txt reverted"
[[ "$(head -1 beta.txt)" == "Changed beta." ]] \
    || fail "test 704: beta.txt should be unchanged"
pass "test 704: stash --file filter"

# ============================================================================
# Test 705: stash preserves staged changes
# ============================================================================
new_repo
sed -i.bak '1s/.*/Staged beta./' beta.txt
git add beta.txt
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA705="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" stash "$SHA705" > /dev/null
STAGED705="$(git diff --cached --name-only)"
echo "$STAGED705" | grep -q "beta.txt" \
    || fail "test 705: expected beta.txt still staged, got '$STAGED705'"
pass "test 705: stash preserves staged changes"

# ============================================================================
# Test 706: stale SHA error (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash deadbeef > /dev/null 2>/dev/null; then
    fail "test 706: expected exit 1 for stale SHA"
fi
pass "test 706: stale SHA error"

# ============================================================================
# Test 707: no-changes error (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash --all > /dev/null 2>/dev/null; then
    fail "test 707: expected exit 1 for no unstaged changes"
fi
pass "test 707: no-changes error"

# ============================================================================
# Test 708: pop with no stash entries (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash pop > /dev/null 2>/dev/null; then
    fail "test 708: expected exit 1 for pop with no stash"
fi
pass "test 708: pop with no stash entries"

# ============================================================================
# Test 709: pop rejects extra flags (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash pop --all > /dev/null 2>/dev/null; then
    fail "test 709: expected exit 1 for pop --all"
fi
pass "test 709: pop rejects extra flags"

# ============================================================================
# Test 710: line spec rejection (exit 1)
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA710="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
if "$GIT_HUNK" stash "${SHA710}:1-3" > /dev/null 2>/dev/null; then
    fail "test 710: expected exit 1 for line spec"
fi
pass "test 710: line spec rejection"

# ============================================================================
# Test 711: stash untracked file by hash
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA711="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA711" ]] || fail "test 711: no untracked hunk found"
"$GIT_HUNK" stash "$SHA711" > /dev/null
[[ ! -f untracked.txt ]] || fail "test 711: untracked.txt should be deleted after stash"
STASH_LIST711="$(git stash list)"
[[ -n "$STASH_LIST711" ]] || fail "test 711: expected non-empty stash list"
pass "test 711: stash untracked file by hash"

# ============================================================================
# Test 712: stash --all -u with mixed tracked+untracked
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

"$GIT_HUNK" stash --all -u > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 712: expected alpha.txt reverted"
[[ ! -f untracked.txt ]] \
    || fail "test 712: untracked.txt should be deleted after stash"
pass "test 712: stash --all -u with mixed tracked+untracked"

# ============================================================================
# Test 713: stash pop restores untracked file
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

"$GIT_HUNK" stash --all -u > /dev/null
[[ ! -f untracked.txt ]] || fail "test 713: untracked.txt should be gone after stash"

"$GIT_HUNK" stash pop > /dev/null 2>/dev/null
[[ -f untracked.txt ]] || fail "test 713: untracked.txt should be restored after pop"
[[ "$(cat untracked.txt)" == "untracked content" ]] \
    || fail "test 713: untracked.txt content mismatch after pop"
# Verify it's still untracked (not staged)
UNTRACKED713="$(git ls-files --others --exclude-standard)"
echo "$UNTRACKED713" | grep -q "untracked.txt" \
    || fail "test 713: untracked.txt should be untracked after pop"
pass "test 713: stash pop restores untracked file"

# ============================================================================
# Test 714: stash untracked preserves staged changes
# ============================================================================
new_repo
sed -i.bak '1s/.*/Staged beta./' beta.txt
git add beta.txt
echo "untracked content" > untracked.txt

SHA714="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
"$GIT_HUNK" stash "$SHA714" > /dev/null
[[ ! -f untracked.txt ]] || fail "test 714: untracked.txt should be gone after stash"
STAGED714="$(git diff --cached --name-only)"
echo "$STAGED714" | grep -q "beta.txt" \
    || fail "test 714: expected beta.txt still staged, got '$STAGED714'"
"$GIT_HUNK" stash pop > /dev/null 2>/dev/null
[[ -f untracked.txt ]] || fail "test 714: untracked.txt should be restored after pop"
pass "test 714: stash untracked preserves staged changes"

# ============================================================================
# Test 715: stash --all --tracked-only excludes untracked
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

"$GIT_HUNK" stash --all --tracked-only > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 715: expected alpha.txt reverted"
[[ -f untracked.txt ]] \
    || fail "test 715: untracked.txt should still exist (not stashed)"
pass "test 715: stash --all --tracked-only excludes untracked"

# ============================================================================
# Test 716: stash untracked preserves executable bit
# ============================================================================
new_repo
echo '#!/bin/sh' > script.sh
chmod +x script.sh
[[ -x script.sh ]] || fail "test 716: precondition: script.sh should be executable"

HASH=$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)
"$GIT_HUNK" stash "$HASH" > /dev/null
[[ ! -f script.sh ]] || fail "test 716: script.sh should be removed after stash"

git stash pop --quiet
[[ -x script.sh ]] || fail "test 716: script.sh should be executable after pop"
pass "test 716: stash untracked preserves executable bit"

# ============================================================================
# Test 717: stash --all without -u excludes untracked
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

"$GIT_HUNK" stash --all > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 717: expected alpha.txt reverted"
[[ -f untracked.txt ]] \
    || fail "test 717: untracked.txt should still exist (not stashed without -u)"
pass "test 717: stash --all without -u excludes untracked"

# ============================================================================
# Test 718: stash push explicit keyword works
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

"$GIT_HUNK" stash push --all > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 718: expected alpha.txt reverted"
STASH_LIST718="$(git stash list)"
[[ -n "$STASH_LIST718" ]] || fail "test 718: expected non-empty stash list"
pass "test 718: stash push explicit keyword works"

# ============================================================================
# Test 719: stash push --include-untracked works
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

"$GIT_HUNK" stash push --all --include-untracked > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 719: expected alpha.txt reverted"
[[ ! -f untracked.txt ]] \
    || fail "test 719: untracked.txt should be deleted after stash with --include-untracked"
pass "test 719: stash push --include-untracked works"

# ============================================================================
# Test 720: explicit untracked hash works without -u
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA720="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA720" ]] || fail "test 720: no untracked hunk found"
"$GIT_HUNK" stash "$SHA720" > /dev/null
[[ ! -f untracked.txt ]] || fail "test 720: untracked.txt should be deleted after stash"
STASH_LIST720="$(git stash list)"
[[ -n "$STASH_LIST720" ]] || fail "test 720: expected non-empty stash list"
pass "test 720: explicit untracked hash works without -u"

# ============================================================================
# Test 721: stash with dirty index — staged changes are preserved, not stashed
# ============================================================================
new_repo
sed -i.bak '1s/.*/Staged change to alpha./' alpha.txt
sed -i.bak '1s/.*/Unstaged change to beta./' beta.txt

# Stage alpha.txt only (leave beta.txt unstaged)
git add alpha.txt

SHA721="$("$GIT_HUNK" list --porcelain --oneline --file beta.txt | head -1 | cut -f1)"
[[ -n "$SHA721" ]] || fail "test 721: no unstaged hunk found for beta.txt"
"$GIT_HUNK" stash "$SHA721" > /dev/null

STASH_SHOW721="$(git stash show)"
echo "$STASH_SHOW721" | grep -q "beta.txt" \
    || fail "test 721: stash should contain beta.txt, got: '$STASH_SHOW721'"
if echo "$STASH_SHOW721" | grep -q "alpha.txt"; then
    fail "test 721: stash should not contain alpha.txt (it was staged)"
fi

STAGED721="$(git diff --cached --name-only)"
echo "$STAGED721" | grep -q "alpha.txt" \
    || fail "test 721: alpha.txt should still be staged after stashing beta.txt"
pass "test 721: stash preserves staged index, only stashes the specified hunk"

report_results
