#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 1000: basic commit with SHA
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha first line./' alpha.txt

SHA1000="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA1000" ]] || fail "test 1000: no unstaged hunk found"
OUT1000="$("$GIT_HUNK" commit --no-color "$SHA1000" -m "test basic commit" 2>/dev/null)"
git log --oneline -1 | grep -q "test basic commit" \
    || fail "test 1000: commit message not found in log"
echo "$OUT1000" | grep -qE '^committed [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 1000: output format wrong, got: '$OUT1000'"
REMAINING1000="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING1000" == "0" ]] \
    || fail "test 1000: expected 0 unstaged hunks after commit, got '$REMAINING1000'"
head -1 alpha.txt | grep -q "Changed alpha first line" \
    || fail "test 1000: worktree content should be unchanged"
pass "test 1000: basic commit with SHA"

# ============================================================================
# Test 1001: commit multiple SHAs
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt

SHAS1001="$("$GIT_HUNK" list --porcelain --oneline)"
SHA1001A="$(echo "$SHAS1001" | grep "alpha.txt" | head -1 | cut -f1)"
SHA1001B="$(echo "$SHAS1001" | grep "beta.txt" | head -1 | cut -f1)"
[[ -n "$SHA1001A" && -n "$SHA1001B" ]] || fail "test 1001: couldn't find both hunks"
"$GIT_HUNK" commit "$SHA1001A" "$SHA1001B" -m "commit multiple" > /dev/null 2>/dev/null
REMAINING1001="$("$GIT_HUNK" count)"
[[ "$REMAINING1001" == "0" ]] \
    || fail "test 1001: expected 0 unstaged hunks after commit, got '$REMAINING1001'"
git log --oneline -1 | grep -q "commit multiple" \
    || fail "test 1001: commit message not found"
pass "test 1001: commit multiple SHAs"

# ============================================================================
# Test 1002: commit --all
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
sed -i.bak '1s/.*/Changed gamma./' gamma.txt

"$GIT_HUNK" commit --all -m "commit all" > /dev/null 2>/dev/null
REMAINING1002="$("$GIT_HUNK" count)"
[[ "$REMAINING1002" == "0" ]] \
    || fail "test 1002: expected 0 unstaged hunks after --all, got '$REMAINING1002'"
git log --oneline -1 | grep -q "commit all" \
    || fail "test 1002: commit message not found"
pass "test 1002: commit --all"

# ============================================================================
# Test 1003: commit --file only commits hunks in specified file
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt

"$GIT_HUNK" commit --file alpha.txt -m "commit file" > /dev/null 2>/dev/null
ALPHA1003="$("$GIT_HUNK" count --file alpha.txt)"
BETA1003="$("$GIT_HUNK" count --file beta.txt)"
[[ "$ALPHA1003" == "0" ]] \
    || fail "test 1003: alpha.txt should have 0 hunks after --file commit, got '$ALPHA1003'"
[[ "$BETA1003" -gt 0 ]] \
    || fail "test 1003: beta.txt should still have hunks, got '$BETA1003'"
git log --oneline -1 | grep -q "commit file" \
    || fail "test 1003: commit message not found"
pass "test 1003: commit --file only commits hunks in specified file"

# ============================================================================
# Test 1004: commit --amend does not increase commit count
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
SHA1004="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
"$GIT_HUNK" commit "$SHA1004" -m "initial commit" > /dev/null 2>/dev/null
COMMIT_COUNT_BEFORE="$(git rev-list --count HEAD)"

sed -i.bak '1s/.*/Changed beta./' beta.txt
SHA1004B="$("$GIT_HUNK" list --porcelain --oneline --file beta.txt | head -1 | cut -f1)"
"$GIT_HUNK" commit "$SHA1004B" --amend -m "amended commit" > /dev/null 2>/dev/null
COMMIT_COUNT_AFTER="$(git rev-list --count HEAD)"
[[ "$COMMIT_COUNT_AFTER" -eq "$COMMIT_COUNT_BEFORE" ]] \
    || fail "test 1004: commit count should not increase with --amend (before=$COMMIT_COUNT_BEFORE, after=$COMMIT_COUNT_AFTER)"
git log --oneline -1 | grep -q "amended commit" \
    || fail "test 1004: amended commit message not found"
pass "test 1004: commit --amend does not increase commit count"

# ============================================================================
# Test 1005: commit --dry-run does not modify state
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

COUNT1005_BEFORE="$("$GIT_HUNK" count)"
COMMITS1005_BEFORE="$(git rev-list --count HEAD)"
SHA1005="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
DRY_OUT="$("$GIT_HUNK" commit --dry-run --no-color "$SHA1005" -m "dry run test")"
echo "$DRY_OUT" | grep -q "would commit" \
    || fail "test 1005: expected 'would commit' in output, got '$DRY_OUT'"
COUNT1005_AFTER="$("$GIT_HUNK" count)"
COMMITS1005_AFTER="$(git rev-list --count HEAD)"
[[ "$COUNT1005_AFTER" == "$COUNT1005_BEFORE" ]] \
    || fail "test 1005: hunk count should not change with --dry-run (before=$COUNT1005_BEFORE, after=$COUNT1005_AFTER)"
[[ "$COMMITS1005_AFTER" == "$COMMITS1005_BEFORE" ]] \
    || fail "test 1005: commit count should not change with --dry-run"
pass "test 1005: commit --dry-run does not modify state"

# ============================================================================
# Test 1006: commit preserves existing staged changes
# ============================================================================
new_repo
sed -i.bak '1s/.*/Stage this alpha change./' alpha.txt
sed -i.bak '1s/.*/Commit this beta change./' beta.txt

git add alpha.txt
STAGED1006_BEFORE="$(git diff --cached --name-only)"
echo "$STAGED1006_BEFORE" | grep -q "alpha.txt" \
    || fail "test 1006: alpha.txt should be staged before commit"

SHA1006="$("$GIT_HUNK" list --porcelain --oneline --file beta.txt | head -1 | cut -f1)"
[[ -n "$SHA1006" ]] || fail "test 1006: no beta.txt hunk found"
"$GIT_HUNK" commit "$SHA1006" -m "commit beta only" > /dev/null 2>/dev/null
STAGED1006_AFTER="$(git diff --cached --name-only)"
echo "$STAGED1006_AFTER" | grep -q "alpha.txt" \
    || fail "test 1006: alpha.txt should still be staged after commit"
git log --oneline -1 | grep -q "commit beta only" \
    || fail "test 1006: commit message not found"
pass "test 1006: commit preserves existing staged changes"

# ============================================================================
# Test 1007: commit --porcelain output format
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA1007="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
PORC_OUT="$("$GIT_HUNK" commit --porcelain "$SHA1007" -m "porcelain test" 2>/dev/null)"
PORC_VERB="$(echo "$PORC_OUT" | cut -f1)"
PORC_SHA="$(echo "$PORC_OUT" | cut -f2)"
PORC_FILE="$(echo "$PORC_OUT" | cut -f3)"
[[ "$PORC_VERB" == "committed" ]] \
    || fail "test 1007: porcelain verb not 'committed', got '$PORC_VERB'"
[[ ${#PORC_SHA} -eq 7 ]] \
    || fail "test 1007: porcelain sha not 7 chars, got '$PORC_SHA'"
[[ "$PORC_FILE" == "alpha.txt" ]] \
    || fail "test 1007: porcelain file not 'alpha.txt', got '$PORC_FILE'"
pass "test 1007: commit --porcelain output format"

# ============================================================================
# Test 1008: commit --quiet suppresses stdout
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA1008="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
QUIET_OUT="$("$GIT_HUNK" commit --quiet "$SHA1008" -m "quiet test" 2>/dev/null)"
[[ -z "$QUIET_OUT" ]] \
    || fail "test 1008: expected empty stdout with --quiet, got '$QUIET_OUT'"
git log --oneline -1 | grep -q "quiet test" \
    || fail "test 1008: commit should still succeed with --quiet"
pass "test 1008: commit --quiet suppresses stdout"

# ============================================================================
# Test 1009: commit --verbose shows summary on stderr
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA1009="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
STDERR1009="$("$GIT_HUNK" commit --verbose --no-color "$SHA1009" -m "verbose test" 2>&1 >/dev/null)"
echo "$STDERR1009" | grep -q "1 hunk committed" \
    || fail "test 1009: expected '1 hunk committed' on stderr, got '$STDERR1009'"
pass "test 1009: commit --verbose shows summary on stderr"

# ============================================================================
# Test 1010: hook failure recovery restores index
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA1010="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
COMMITS1010_BEFORE="$(git rev-list --count HEAD)"
mkdir -p .git/hooks
printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
if "$GIT_HUNK" commit "$SHA1010" -m "hook fail" > /dev/null 2>/dev/null; then
    fail "test 1010: expected non-zero exit for hook failure"
fi
COMMITS1010_AFTER="$(git rev-list --count HEAD)"
[[ "$COMMITS1010_AFTER" -eq "$COMMITS1010_BEFORE" ]] \
    || fail "test 1010: commit count should not change after hook failure"
REMAINING1010="$("$GIT_HUNK" count)"
[[ "$REMAINING1010" -gt 0 ]] \
    || fail "test 1010: hunks should still be present after hook failure"
STAGED1010="$(git diff --cached --name-only)"
[[ -z "$STAGED1010" ]] \
    || fail "test 1010: index should be clean after hook failure recovery, got '$STAGED1010'"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1010: backup file should be deleted after recovery"
pass "test 1010: hook failure recovery restores index"

# ============================================================================
# Test 1011: stale backup cleanup and recovery
# ============================================================================
new_repo
cp .git/index .git/index.hunk-backup
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA1011="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
STDERR1011="$("$GIT_HUNK" commit "$SHA1011" -m "stale backup test" 2>&1 >/dev/null)"
echo "$STDERR1011" | grep -q "stale index backup" \
    || fail "test 1011: expected stale backup warning, got '$STDERR1011'"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1011: backup file should be cleaned up"
git log --oneline -1 | grep -q "stale backup test" \
    || fail "test 1011: commit should succeed after stale backup cleanup"
pass "test 1011: stale backup cleanup and recovery"

# ============================================================================
# Test 1012: --staged is rejected
# ============================================================================
new_repo
if "$GIT_HUNK" commit --staged -m "test" > /dev/null 2>/dev/null; then
    fail "test 1012: expected non-zero exit for --staged"
fi
pass "test 1012: --staged is rejected"

# ============================================================================
# Test 1013: missing -m is rejected
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
SHA1013="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
if "$GIT_HUNK" commit "$SHA1013" > /dev/null 2>/dev/null; then
    fail "test 1013: expected non-zero exit for missing -m"
fi
pass "test 1013: missing -m is rejected"

# ============================================================================
# Test 1014: commit --ref
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA1014="$("$GIT_HUNK" list --ref HEAD --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$SHA1014" ]] || fail "test 1014: no hunk found with --ref HEAD"
"$GIT_HUNK" commit --ref HEAD "$SHA1014" -m "ref commit" > /dev/null 2>/dev/null
git log --oneline -1 | grep -q "ref commit" \
    || fail "test 1014: commit message not found"
REMAINING1014="$("$GIT_HUNK" count)"
[[ "$REMAINING1014" == "0" ]] \
    || fail "test 1014: hunks still present after commit with --ref"
pass "test 1014: commit --ref"

# ============================================================================
# Test 1015: commit --dry-run --porcelain uses would-commit verb
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA1015="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
OUT1015="$("$GIT_HUNK" commit --dry-run --porcelain "$SHA1015" -m "dry porcelain")"
echo "$OUT1015" | grep -q "^would-commit" \
    || fail "test 1015: expected 'would-commit' verb in porcelain dry-run, got: '$OUT1015'"
pass "test 1015: commit --dry-run --porcelain uses would-commit verb"

report_results
