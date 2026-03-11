#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 1100: list from subdirectory shows hunks for files at repo root
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line./' alpha.txt
mkdir -p subdir

SHA="$(cd subdir && "$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$SHA" ]] || fail "test 1100: no hunks listed from subdirectory"
pass "test 1100: list from subdirectory shows hunks"

# ============================================================================
# Test 1101: add from subdirectory stages correct file (not subdir-prefixed)
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line./' alpha.txt
mkdir -p subdir

SHA="$(cd subdir && "$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$SHA" ]] || fail "test 1101: no hunk found from subdirectory"
(cd subdir && "$GIT_HUNK" add "$SHA" > /dev/null)

STAGED="$(git diff --cached --name-only)"
echo "$STAGED" | grep -q "^alpha.txt$" \
    || fail "test 1101: expected alpha.txt staged, got: '$STAGED'"
if echo "$STAGED" | grep -q "subdir/"; then
    fail "test 1101: subdir/ prefix incorrectly added to staged file"
fi
pass "test 1101: add from subdirectory stages correct file"

# ============================================================================
# Test 1102: reset from subdirectory works correctly
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line./' alpha.txt
mkdir -p subdir

(cd subdir && "$GIT_HUNK" add --all > /dev/null 2>/dev/null)
STAGED_SHA="$(cd subdir && "$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$STAGED_SHA" ]] || fail "test 1102: no staged hunk found"
(cd subdir && "$GIT_HUNK" reset "$STAGED_SHA" > /dev/null)

REMAINING="$(git diff --cached | wc -l | tr -d ' ')"
[[ "$REMAINING" -eq 0 ]] || fail "test 1102: hunk was not unstaged from subdirectory"
pass "test 1102: reset from subdirectory works correctly"

# ============================================================================
# Test 1103: --file resolves relative to original cwd (file inside subdir)
# ============================================================================
new_repo
mkdir -p subdir
cat > subdir/inner.txt <<'EOF'
inner file line 1
inner file line 2
EOF
git add subdir/inner.txt && git commit -m "add inner" -q
sed -i.bak '1s/.*/inner modified./' subdir/inner.txt

# From subdir, --file inner.txt should find subdir/inner.txt
OUT="$(cd subdir && "$GIT_HUNK" list --porcelain --oneline --file inner.txt)"
[[ -n "$OUT" ]] || fail "test 1103: --file inner.txt from subdir should find subdir/inner.txt"
echo "$OUT" | grep -q "inner.txt" \
    || fail "test 1103: output should reference inner.txt"
pass "test 1103: --file resolves relative to original cwd"

# ============================================================================
# Test 1104: --file with parent traversal (../alpha.txt from subdir)
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line./' alpha.txt
mkdir -p subdir

OUT="$(cd subdir && "$GIT_HUNK" list --porcelain --oneline --file ../alpha.txt)"
[[ -n "$OUT" ]] || fail "test 1104: --file ../alpha.txt from subdir should find root alpha.txt"
echo "$OUT" | grep -q "alpha.txt" \
    || fail "test 1104: output should reference alpha.txt"
pass "test 1104: --file with parent traversal works from subdirectory"

# ============================================================================
# Test 1105: add file inside subdirectory from repo root still works
# ============================================================================
new_repo
mkdir -p subdir
cat > subdir/inner.txt <<'EOF'
inner file line 1
inner file line 2
EOF
git add subdir/inner.txt && git commit -m "add inner" -q
sed -i.bak '1s/.*/inner modified./' subdir/inner.txt

SHA="$("$GIT_HUNK" list --porcelain --oneline --file subdir/inner.txt | head -1 | cut -f1)"
[[ -n "$SHA" ]] || fail "test 1105: no hunk found for subdir/inner.txt from root"
"$GIT_HUNK" add "$SHA" > /dev/null

STAGED="$(git diff --cached --name-only)"
echo "$STAGED" | grep -q "^subdir/inner.txt$" \
    || fail "test 1105: expected subdir/inner.txt staged, got: '$STAGED'"
pass "test 1105: add file inside subdirectory from repo root still works"

# ============================================================================
# Test 1106: count from subdirectory returns correct count
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line./' alpha.txt
mkdir -p subdir

COUNT_ROOT="$("$GIT_HUNK" count)"
COUNT_SUB="$(cd subdir && "$GIT_HUNK" count)"
[[ "$COUNT_ROOT" == "$COUNT_SUB" ]] \
    || fail "test 1106: count from subdir ($COUNT_SUB) differs from root ($COUNT_ROOT)"
pass "test 1106: count from subdirectory matches root"

# ============================================================================
# Test 1107: commit from subdirectory works correctly
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line./' alpha.txt
mkdir -p subdir

SHA="$(cd subdir && "$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$SHA" ]] || fail "test 1107: no hunk found from subdirectory"
(cd subdir && "$GIT_HUNK" commit "$SHA" -m "commit from subdir" > /dev/null 2>/dev/null)

LAST_MSG="$(git log -1 --format=%s)"
[[ "$LAST_MSG" == "commit from subdir" ]] \
    || fail "test 1107: expected commit message 'commit from subdir', got: '$LAST_MSG'"
pass "test 1107: commit from subdirectory works correctly"

# ============================================================================
# Test 1108: user's shell cwd is unchanged after git-hunk runs from subdir
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line./' alpha.txt
mkdir -p subdir

BEFORE="$(cd subdir && pwd)"
AFTER="$(cd subdir && "$GIT_HUNK" list > /dev/null 2>&1 && pwd)"
[[ "$BEFORE" == "$AFTER" ]] \
    || fail "test 1108: cwd changed from '$BEFORE' to '$AFTER'"
pass "test 1108: user shell cwd unchanged after git-hunk"

# ============================================================================
# Test 1109: git -C <dir> works from outside the repo
# ============================================================================
new_repo
REPO_DIR="$CURRENT_REPO"
sed -i.bak '1s/.*/Modified first line./' alpha.txt

# Run from /tmp (outside the repo) using git -C
# Add binary dir to PATH so `git hunk` can find `git-hunk`
GIT_HUNK_DIR="$(dirname "$GIT_HUNK")"
OUT="$(cd /tmp && PATH="$GIT_HUNK_DIR:$PATH" git -C "$REPO_DIR" hunk list --porcelain --oneline 2>&1)"
[[ -n "$OUT" ]] || fail "test 1109: no output from git -C"
echo "$OUT" | grep -q "alpha.txt" \
    || fail "test 1109: expected alpha.txt in output, got: '$OUT'"
pass "test 1109: git -C <dir> works from outside the repo"

# ============================================================================
# Test 1110: deeply nested subdirectory works
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line./' alpha.txt
mkdir -p a/b/c

SHA="$(cd a/b/c && "$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$SHA" ]] || fail "test 1110: no hunks from deeply nested dir"
(cd a/b/c && "$GIT_HUNK" add "$SHA" > /dev/null)

STAGED="$(git diff --cached --name-only)"
echo "$STAGED" | grep -q "^alpha.txt$" \
    || fail "test 1110: expected alpha.txt staged from deep subdir, got: '$STAGED'"
pass "test 1110: deeply nested subdirectory works"

report_results
