#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 29: discard reverts a single unstaged hunk
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA29="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA29" ]] || fail "test 29: no unstaged hunk found"
"$GIT_HUNK" discard --no-color "$SHA29" > /dev/null
REMAINING29="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING29" == "0" ]] || fail "test 29: expected 0 unstaged hunks after discard, got '$REMAINING29'"
pass "test 29: discard reverts single hunk"

# ============================================================================
# Test 30: discard --all reverts all unstaged hunks
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

COUNT30_BEFORE="$("$GIT_HUNK" count)"
[[ "$COUNT30_BEFORE" -gt 0 ]] || fail "test 30: expected unstaged hunks before discard --all"
"$GIT_HUNK" discard --all > /dev/null
COUNT30_AFTER="$("$GIT_HUNK" count)"
[[ "$COUNT30_AFTER" == "0" ]] || fail "test 30: expected 0 unstaged hunks after discard --all, got '$COUNT30_AFTER'"
pass "test 30: discard --all reverts all hunks"

# ============================================================================
# Test 31: discard --dry-run does NOT modify worktree
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA31="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA31" ]] || fail "test 31: no unstaged hunk found"
DRY_OUT="$("$GIT_HUNK" discard --no-color --dry-run "$SHA31")"
echo "$DRY_OUT" | grep -q "would discard" || fail "test 31: expected 'would discard' in output, got '$DRY_OUT'"
REMAINING31="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING31" -gt 0 ]] || fail "test 31: dry-run should not have modified worktree"
pass "test 31: discard --dry-run does not modify worktree"

# ============================================================================
# Test 32: discard output format (human mode)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA32="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
DISCARD_OUT="$("$GIT_HUNK" discard --no-color "$SHA32")"
echo "$DISCARD_OUT" | grep -qE '^discarded [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 32: discard output format wrong, got: '$DISCARD_OUT'"
pass "test 32: discard output format"

# ============================================================================
# Test 33: discard --porcelain output is tab-separated
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA33="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
PORC33="$("$GIT_HUNK" discard --porcelain "$SHA33")"
PORC33_VERB="$(echo "$PORC33" | cut -f1)"
PORC33_SHA="$(echo "$PORC33" | cut -f2)"
PORC33_FILE="$(echo "$PORC33" | cut -f3)"
[[ "$PORC33_VERB" == "discarded" ]] || fail "test 33: porcelain verb not 'discarded', got '$PORC33_VERB'"
[[ ${#PORC33_SHA} -eq 7 ]] || fail "test 33: porcelain sha not 7 chars, got '$PORC33_SHA'"
[[ "$PORC33_FILE" == "alpha.txt" ]] || fail "test 33: porcelain file not 'alpha.txt', got '$PORC33_FILE'"
pass "test 33: discard --porcelain output format"

# ============================================================================
# Test 34: discard preserves staged changes
# ============================================================================
new_repo
sed -i '' '1s/.*/Staged content./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED34_BEFORE="$("$GIT_HUNK" count --staged)"

sed -i '' '1s/.*/Additional unstaged change./' alpha.txt
"$GIT_HUNK" discard --all > /dev/null
STAGED34_AFTER="$("$GIT_HUNK" count --staged)"
[[ "$STAGED34_BEFORE" == "$STAGED34_AFTER" ]] \
    || fail "test 34: discard should not affect staged changes (before=$STAGED34_BEFORE, after=$STAGED34_AFTER)"
pass "test 34: discard preserves staged changes"

# ============================================================================
# Test 35: discard --file only discards hunks in specified file
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

"$GIT_HUNK" discard --file alpha.txt > /dev/null
ALPHA35="$("$GIT_HUNK" count --file alpha.txt)"
BETA35="$("$GIT_HUNK" count --file beta.txt)"
[[ "$ALPHA35" == "0" ]] || fail "test 35: alpha.txt should have 0 hunks after discard --file, got '$ALPHA35'"
[[ "$BETA35" -gt 0 ]] || fail "test 35: beta.txt should still have hunks, got '$BETA35'"
pass "test 35: discard --file only discards hunks in specified file"

# ============================================================================
# Test 38: discard with stale hash exits 1
# ============================================================================
new_repo
if "$GIT_HUNK" discard deadbeef > /dev/null 2>/dev/null; then
    fail "test 38: expected exit 1 for stale hash"
fi
pass "test 38: discard with stale hash exits 1"

# ============================================================================
# Test 39: discard --dry-run --porcelain uses would-discard verb
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA39="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
OUT39="$("$GIT_HUNK" discard --dry-run --porcelain "$SHA39")"
echo "$OUT39" | grep -q "^would-discard" \
    || fail "test 39: expected 'would-discard' verb in porcelain output, got: '$OUT39'"
pass "test 39: discard --dry-run --porcelain uses would-discard verb"

# ============================================================================
# Test 56: discard untracked file without --force exits 1
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA56="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA56" ]] || fail "test 56: no untracked hunk found"
if "$GIT_HUNK" discard "$SHA56" > /dev/null 2>/dev/null; then
    fail "test 56: expected exit 1 without --force"
fi
[[ -f untracked.txt ]] || fail "test 56: file should still exist"
pass "test 56: discard untracked without --force exits 1"

# ============================================================================
# Test 57: discard untracked file with --force deletes it
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA57="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA57" ]] || fail "test 57: no untracked hunk found"
"$GIT_HUNK" discard --force "$SHA57" > /dev/null
[[ ! -f untracked.txt ]] || fail "test 57: untracked file should be deleted after --force discard"
pass "test 57: discard --force deletes untracked file"

# ============================================================================
# Test 58: discard --all without --force skips untracked files
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

if "$GIT_HUNK" discard --all > /dev/null 2>/dev/null; then
    fail "test 58: expected exit 1 for --all with untracked (no --force)"
fi
pass "test 58: discard --all without --force errors on untracked"

# ============================================================================
# Test 59: discard --force --all discards everything including untracked
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

"$GIT_HUNK" discard --force --all > /dev/null
REMAINING59="$("$GIT_HUNK" count)"
[[ "$REMAINING59" == "0" ]] || fail "test 59: expected 0 hunks after --force --all, got '$REMAINING59'"
[[ ! -f untracked.txt ]] || fail "test 59: untracked file should be deleted"
pass "test 59: discard --force --all discards everything"

# ============================================================================
# Test 60: discard --dry-run works for untracked files without --force
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA60="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA60" ]] || fail "test 60: no untracked hunk found"
OUT60="$("$GIT_HUNK" discard --dry-run "$SHA60" 2>/dev/null)"
echo "$OUT60" | grep -q "would discard" || fail "test 60: expected 'would discard' in output, got: '$OUT60'"
[[ -f untracked.txt ]] || fail "test 60: file should still exist after dry-run"
pass "test 60: discard --dry-run works for untracked without --force"

# ============================================================================
# Test 61: discard --tracked-only excludes untracked from --all
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

"$GIT_HUNK" discard --all --tracked-only > /dev/null
[[ -f untracked.txt ]] || fail "test 61: untracked file should survive --tracked-only discard"
REMAINING61="$("$GIT_HUNK" list --tracked-only --porcelain --oneline)"
[[ -z "$REMAINING61" ]] || fail "test 61: tracked hunks should be discarded"
pass "test 61: discard --tracked-only excludes untracked from --all"

report_results
