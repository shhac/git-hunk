#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test reverts a single unstaged hunk
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA500="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA500" ]] || fail "test 500: no unstaged hunk found"
"$GIT_HUNK" restore --no-color "$SHA500" > /dev/null
REMAINING500="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING500" == "0" ]] || fail "test 500: expected 0 unstaged hunks after restore, got '$REMAINING500'"
pass "test 500: restore reverts single hunk"

# ============================================================================
# Test --all reverts all unstaged hunks
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

COUNT501_BEFORE="$("$GIT_HUNK" count)"
[[ "$COUNT501_BEFORE" -gt 0 ]] || fail "test 501: expected unstaged hunks before restore --all"
"$GIT_HUNK" restore --all > /dev/null
COUNT501_AFTER="$("$GIT_HUNK" count)"
[[ "$COUNT501_AFTER" == "0" ]] || fail "test 501: expected 0 unstaged hunks after restore --all, got '$COUNT501_AFTER'"
pass "test 501: restore --all reverts all hunks"

# ============================================================================
# Test --dry-run does NOT modify worktree
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA502="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA502" ]] || fail "test 502: no unstaged hunk found"
DRY_OUT="$("$GIT_HUNK" restore --no-color --dry-run "$SHA502")"
echo "$DRY_OUT" | grep -q "would restore" || fail "test 502: expected 'would restore' in output, got '$DRY_OUT'"
REMAINING502="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING502" -gt 0 ]] || fail "test 502: dry-run should not have modified worktree"
pass "test 502: restore --dry-run does not modify worktree"

# ============================================================================
# Test output format (human mode)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA503="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
DISCARD_OUT="$("$GIT_HUNK" restore --no-color "$SHA503")"
echo "$DISCARD_OUT" | grep -qE '^restored [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 503: restore output format wrong, got: '$DISCARD_OUT'"
pass "test 503: restore output format"

# ============================================================================
# Test --porcelain output is tab-separated
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA504="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
PORC504="$("$GIT_HUNK" restore --porcelain "$SHA504")"
PORC504_VERB="$(echo "$PORC504" | cut -f1)"
PORC504_SHA="$(echo "$PORC504" | cut -f2)"
PORC504_FILE="$(echo "$PORC504" | cut -f3)"
[[ "$PORC504_VERB" == "restored" ]] || fail "test 504: porcelain verb not 'restored', got '$PORC504_VERB'"
[[ ${#PORC504_SHA} -eq 7 ]] || fail "test 504: porcelain sha not 7 chars, got '$PORC504_SHA'"
[[ "$PORC504_FILE" == "alpha.txt" ]] || fail "test 504: porcelain file not 'alpha.txt', got '$PORC504_FILE'"
pass "test 504: restore --porcelain output format"

# ============================================================================
# Test preserves staged changes
# ============================================================================
new_repo
sed -i '' '1s/.*/Staged content./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED505_BEFORE="$("$GIT_HUNK" count --staged)"

sed -i '' '1s/.*/Additional unstaged change./' alpha.txt
"$GIT_HUNK" restore --all > /dev/null
STAGED505_AFTER="$("$GIT_HUNK" count --staged)"
[[ "$STAGED505_BEFORE" == "$STAGED505_AFTER" ]] \
    || fail "test 505: restore should not affect staged changes (before=$STAGED505_BEFORE, after=$STAGED505_AFTER)"
pass "test 505: restore preserves staged changes"

# ============================================================================
# Test --file only restores hunks in specified file
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

"$GIT_HUNK" restore --file alpha.txt > /dev/null
ALPHA506="$("$GIT_HUNK" count --file alpha.txt)"
BETA506="$("$GIT_HUNK" count --file beta.txt)"
[[ "$ALPHA506" == "0" ]] || fail "test 506: alpha.txt should have 0 hunks after restore --file, got '$ALPHA506'"
[[ "$BETA506" -gt 0 ]] || fail "test 506: beta.txt should still have hunks, got '$BETA506'"
pass "test 506: restore --file only restores hunks in specified file"

# ============================================================================
# Test with stale hash exits 1
# ============================================================================
new_repo
if "$GIT_HUNK" restore deadbeef > /dev/null 2>/dev/null; then
    fail "test 507: expected exit 1 for stale hash"
fi
pass "test 507: restore with stale hash exits 1"

# ============================================================================
# Test --dry-run --porcelain uses would-restore verb
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA508="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
OUT508="$("$GIT_HUNK" restore --dry-run --porcelain "$SHA508")"
echo "$OUT508" | grep -q "^would-restore" \
    || fail "test 508: expected 'would-restore' verb in porcelain output, got: '$OUT508'"
pass "test 508: restore --dry-run --porcelain uses would-restore verb"

# ============================================================================
# Test untracked file without --force exits 1
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA509="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA509" ]] || fail "test 509: no untracked hunk found"
if "$GIT_HUNK" restore "$SHA509" > /dev/null 2>/dev/null; then
    fail "test 509: expected exit 1 without --force"
fi
[[ -f untracked.txt ]] || fail "test 509: file should still exist"
pass "test 509: restore untracked without --force exits 1"

# ============================================================================
# Test untracked file with --force deletes it
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA510="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA510" ]] || fail "test 510: no untracked hunk found"
"$GIT_HUNK" restore --force "$SHA510" > /dev/null
[[ ! -f untracked.txt ]] || fail "test 510: untracked file should be deleted after --force restore"
pass "test 510: restore --force deletes untracked file"

# ============================================================================
# Test --all without --force skips untracked files
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

if "$GIT_HUNK" restore --all > /dev/null 2>/dev/null; then
    fail "test 511: expected exit 1 for --all with untracked (no --force)"
fi
pass "test 511: restore --all without --force errors on untracked"

# ============================================================================
# Test --force --all restores everything including untracked
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

"$GIT_HUNK" restore --force --all > /dev/null
REMAINING512="$("$GIT_HUNK" count)"
[[ "$REMAINING512" == "0" ]] || fail "test 512: expected 0 hunks after --force --all, got '$REMAINING512'"
[[ ! -f untracked.txt ]] || fail "test 512: untracked file should be deleted"
pass "test 512: restore --force --all restores everything"

# ============================================================================
# Test --dry-run works for untracked files without --force
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA513="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA513" ]] || fail "test 513: no untracked hunk found"
OUT513="$("$GIT_HUNK" restore --dry-run "$SHA513" 2>/dev/null)"
echo "$OUT513" | grep -q "would restore" || fail "test 513: expected 'would restore' in output, got: '$OUT513'"
[[ -f untracked.txt ]] || fail "test 513: file should still exist after dry-run"
pass "test 513: restore --dry-run works for untracked without --force"

# ============================================================================
# Test --tracked-only excludes untracked from --all
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

"$GIT_HUNK" restore --all --tracked-only > /dev/null
[[ -f untracked.txt ]] || fail "test 514: untracked file should survive --tracked-only restore"
REMAINING514="$("$GIT_HUNK" list --tracked-only --porcelain --oneline)"
[[ -z "$REMAINING514" ]] || fail "test 514: tracked hunks should be restored"
pass "test 514: restore --tracked-only excludes untracked from --all"

report_results
