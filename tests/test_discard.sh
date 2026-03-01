#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 500: discard reverts a single unstaged hunk
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA500="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA500" ]] || fail "test 500: no unstaged hunk found"
"$GIT_HUNK" discard --no-color "$SHA500" > /dev/null
REMAINING500="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING500" == "0" ]] || fail "test 500: expected 0 unstaged hunks after discard, got '$REMAINING500'"
pass "test 500: discard reverts single hunk"

# ============================================================================
# Test 501: discard --all reverts all unstaged hunks
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

COUNT501_BEFORE="$("$GIT_HUNK" count)"
[[ "$COUNT501_BEFORE" -gt 0 ]] || fail "test 501: expected unstaged hunks before discard --all"
"$GIT_HUNK" discard --all > /dev/null
COUNT501_AFTER="$("$GIT_HUNK" count)"
[[ "$COUNT501_AFTER" == "0" ]] || fail "test 501: expected 0 unstaged hunks after discard --all, got '$COUNT501_AFTER'"
pass "test 501: discard --all reverts all hunks"

# ============================================================================
# Test 502: discard --dry-run does NOT modify worktree
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA502="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA502" ]] || fail "test 502: no unstaged hunk found"
DRY_OUT="$("$GIT_HUNK" discard --no-color --dry-run "$SHA502")"
echo "$DRY_OUT" | grep -q "would discard" || fail "test 502: expected 'would discard' in output, got '$DRY_OUT'"
REMAINING502="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING502" -gt 0 ]] || fail "test 502: dry-run should not have modified worktree"
pass "test 502: discard --dry-run does not modify worktree"

# ============================================================================
# Test 503: discard output format (human mode)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA503="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
DISCARD_OUT="$("$GIT_HUNK" discard --no-color "$SHA503")"
echo "$DISCARD_OUT" | grep -qE '^discarded [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 503: discard output format wrong, got: '$DISCARD_OUT'"
pass "test 503: discard output format"

# ============================================================================
# Test 504: discard --porcelain output is tab-separated
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA504="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
PORC504="$("$GIT_HUNK" discard --porcelain "$SHA504")"
PORC504_VERB="$(echo "$PORC504" | cut -f1)"
PORC504_SHA="$(echo "$PORC504" | cut -f2)"
PORC504_FILE="$(echo "$PORC504" | cut -f3)"
[[ "$PORC504_VERB" == "discarded" ]] || fail "test 504: porcelain verb not 'discarded', got '$PORC504_VERB'"
[[ ${#PORC504_SHA} -eq 7 ]] || fail "test 504: porcelain sha not 7 chars, got '$PORC504_SHA'"
[[ "$PORC504_FILE" == "alpha.txt" ]] || fail "test 504: porcelain file not 'alpha.txt', got '$PORC504_FILE'"
pass "test 504: discard --porcelain output format"

# ============================================================================
# Test 505: discard preserves staged changes
# ============================================================================
new_repo
sed -i '' '1s/.*/Staged content./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED505_BEFORE="$("$GIT_HUNK" count --staged)"

sed -i '' '1s/.*/Additional unstaged change./' alpha.txt
"$GIT_HUNK" discard --all > /dev/null
STAGED505_AFTER="$("$GIT_HUNK" count --staged)"
[[ "$STAGED505_BEFORE" == "$STAGED505_AFTER" ]] \
    || fail "test 505: discard should not affect staged changes (before=$STAGED505_BEFORE, after=$STAGED505_AFTER)"
pass "test 505: discard preserves staged changes"

# ============================================================================
# Test 506: discard --file only discards hunks in specified file
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

"$GIT_HUNK" discard --file alpha.txt > /dev/null
ALPHA506="$("$GIT_HUNK" count --file alpha.txt)"
BETA506="$("$GIT_HUNK" count --file beta.txt)"
[[ "$ALPHA506" == "0" ]] || fail "test 506: alpha.txt should have 0 hunks after discard --file, got '$ALPHA506'"
[[ "$BETA506" -gt 0 ]] || fail "test 506: beta.txt should still have hunks, got '$BETA506'"
pass "test 506: discard --file only discards hunks in specified file"

# ============================================================================
# Test 507: discard with stale hash exits 1
# ============================================================================
new_repo
if "$GIT_HUNK" discard deadbeef > /dev/null 2>/dev/null; then
    fail "test 507: expected exit 1 for stale hash"
fi
pass "test 507: discard with stale hash exits 1"

# ============================================================================
# Test 508: discard --dry-run --porcelain uses would-discard verb
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA508="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
OUT508="$("$GIT_HUNK" discard --dry-run --porcelain "$SHA508")"
echo "$OUT508" | grep -q "^would-discard" \
    || fail "test 508: expected 'would-discard' verb in porcelain output, got: '$OUT508'"
pass "test 508: discard --dry-run --porcelain uses would-discard verb"

# ============================================================================
# Test 509: discard untracked file without --force exits 1
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA509="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA509" ]] || fail "test 509: no untracked hunk found"
if "$GIT_HUNK" discard "$SHA509" > /dev/null 2>/dev/null; then
    fail "test 509: expected exit 1 without --force"
fi
[[ -f untracked.txt ]] || fail "test 509: file should still exist"
pass "test 509: discard untracked without --force exits 1"

# ============================================================================
# Test 510: discard untracked file with --force deletes it
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA510="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA510" ]] || fail "test 510: no untracked hunk found"
"$GIT_HUNK" discard --force "$SHA510" > /dev/null
[[ ! -f untracked.txt ]] || fail "test 510: untracked file should be deleted after --force discard"
pass "test 510: discard --force deletes untracked file"

# ============================================================================
# Test 511: discard --all without --force skips untracked files
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

if "$GIT_HUNK" discard --all > /dev/null 2>/dev/null; then
    fail "test 511: expected exit 1 for --all with untracked (no --force)"
fi
pass "test 511: discard --all without --force errors on untracked"

# ============================================================================
# Test 512: discard --force --all discards everything including untracked
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

"$GIT_HUNK" discard --force --all > /dev/null
REMAINING512="$("$GIT_HUNK" count)"
[[ "$REMAINING512" == "0" ]] || fail "test 512: expected 0 hunks after --force --all, got '$REMAINING512'"
[[ ! -f untracked.txt ]] || fail "test 512: untracked file should be deleted"
pass "test 512: discard --force --all discards everything"

# ============================================================================
# Test 513: discard --dry-run works for untracked files without --force
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA513="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA513" ]] || fail "test 513: no untracked hunk found"
OUT513="$("$GIT_HUNK" discard --dry-run "$SHA513" 2>/dev/null)"
echo "$OUT513" | grep -q "would discard" || fail "test 513: expected 'would discard' in output, got: '$OUT513'"
[[ -f untracked.txt ]] || fail "test 513: file should still exist after dry-run"
pass "test 513: discard --dry-run works for untracked without --force"

# ============================================================================
# Test 514: discard --tracked-only excludes untracked from --all
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

"$GIT_HUNK" discard --all --tracked-only > /dev/null
[[ -f untracked.txt ]] || fail "test 514: untracked file should survive --tracked-only discard"
REMAINING514="$("$GIT_HUNK" list --tracked-only --porcelain --oneline)"
[[ -z "$REMAINING514" ]] || fail "test 514: tracked hunks should be discarded"
pass "test 514: discard --tracked-only excludes untracked from --all"

report_results
