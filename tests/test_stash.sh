#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 41: basic stash push by SHA
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

SHA41="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" stash "$SHA41" > /dev/null
STASH_LIST41="$(git stash list)"
[[ -n "$STASH_LIST41" ]] || fail "test 41: expected non-empty stash list"
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 41: expected alpha.txt reverted to committed content"
[[ "$(head -1 beta.txt)" == "Changed beta." ]] \
    || fail "test 41: beta.txt should be unchanged"
pass "test 41: basic stash push by SHA"

# ============================================================================
# Test 42: stash pop roundtrip
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

SHA42="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" stash "$SHA42" > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] || fail "test 42: not reverted after stash"

"$GIT_HUNK" stash --pop > /dev/null 2>/dev/null
[[ "$(head -1 alpha.txt)" == "Changed alpha." ]] \
    || fail "test 42: expected alpha.txt restored after pop"
STASH_LIST42="$(git stash list)"
[[ -z "$STASH_LIST42" ]] || fail "test 42: expected empty stash list after pop"
pass "test 42: stash pop roundtrip"

# ============================================================================
# Test 43: stash --all
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"
ORIG_BETA="$(git show HEAD:beta.txt | head -1)"

"$GIT_HUNK" stash --all > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 43: expected alpha.txt reverted"
[[ "$(head -1 beta.txt)" == "$ORIG_BETA" ]] \
    || fail "test 43: expected beta.txt reverted"
git stash show > /dev/null 2>/dev/null \
    || fail "test 43: git stash show should succeed"
pass "test 43: stash --all"

# ============================================================================
# Test 44: stash -m custom message
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

"$GIT_HUNK" stash --all -m "custom stash msg" > /dev/null
STASH_LIST44="$(git stash list)"
echo "$STASH_LIST44" | grep -q "custom stash msg" \
    || fail "test 44: expected 'custom stash msg' in stash list, got '$STASH_LIST44'"
pass "test 44: stash -m custom message"

# ============================================================================
# Test 45: stash --file filter
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

"$GIT_HUNK" stash --file alpha.txt > /dev/null
[[ "$(head -1 alpha.txt)" == "$ORIG_ALPHA" ]] \
    || fail "test 45: expected alpha.txt reverted"
[[ "$(head -1 beta.txt)" == "Changed beta." ]] \
    || fail "test 45: beta.txt should be unchanged"
pass "test 45: stash --file filter"

# ============================================================================
# Test 46: stash preserves staged changes
# ============================================================================
new_repo
sed -i '' '1s/.*/Staged beta./' beta.txt
git add beta.txt
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA46="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" stash "$SHA46" > /dev/null
STAGED46="$(git diff --cached --name-only)"
echo "$STAGED46" | grep -q "beta.txt" \
    || fail "test 46: expected beta.txt still staged, got '$STAGED46'"
pass "test 46: stash preserves staged changes"

# ============================================================================
# Test 47: stale SHA error (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash deadbeef > /dev/null 2>/dev/null; then
    fail "test 47: expected exit 1 for stale SHA"
fi
pass "test 47: stale SHA error"

# ============================================================================
# Test 48: no-changes error (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash --all > /dev/null 2>/dev/null; then
    fail "test 48: expected exit 1 for no unstaged changes"
fi
pass "test 48: no-changes error"

# ============================================================================
# Test 49: pop with no stash entries (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash --pop > /dev/null 2>/dev/null; then
    fail "test 49: expected exit 1 for pop with no stash"
fi
pass "test 49: pop with no stash entries"

# ============================================================================
# Test 50: --pop rejects conflicting flags (exit 1)
# ============================================================================
new_repo
if "$GIT_HUNK" stash --pop --all > /dev/null 2>/dev/null; then
    fail "test 50: expected exit 1 for --pop --all"
fi
pass "test 50: --pop rejects conflicting flags"

# ============================================================================
# Test 51: line spec rejection (exit 1)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA51="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
if "$GIT_HUNK" stash "${SHA51}:1-3" > /dev/null 2>/dev/null; then
    fail "test 51: expected exit 1 for line spec"
fi
pass "test 51: line spec rejection"

# ============================================================================
# Test 64: stash rejects untracked file hash
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA64="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA64" ]] || fail "test 64: no untracked hunk found"
if "$GIT_HUNK" stash "$SHA64" > /dev/null 2>/dev/null; then
    fail "test 64: expected exit 1 for untracked file stash"
fi
pass "test 64: stash rejects untracked file hash"

# ============================================================================
# Test 65: stash --all with only tracked changes works (untracked skipped)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

# stash --all should fail because it includes untracked hunks
if "$GIT_HUNK" stash --all > /dev/null 2>/dev/null; then
    fail "test 65: expected exit 1 for --all with untracked files"
fi
pass "test 65: stash --all rejects when untracked files present"

report_results
