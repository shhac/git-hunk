#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test reverts a single unstaged hunk
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA500="$(first_sha --oneline --file alpha.txt)"
[[ -n "$SHA500" ]] || fail "test 500: no unstaged hunk found"
"$GIT_HUNK" restore --no-color "$SHA500" > /dev/null
REMAINING500="$("$GIT_HUNK" count --file alpha.txt)"
[[ "$REMAINING500" == "0" ]] || fail "test 500: expected 0 unstaged hunks after restore, got '$REMAINING500'"
pass "test 500: restore reverts single hunk"

# ============================================================================
# Test --all reverts all unstaged hunks
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt

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
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA502="$(first_sha --oneline --file alpha.txt)"
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
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA503="$(first_sha --oneline --file alpha.txt)"
DISCARD_OUT="$("$GIT_HUNK" restore --no-color "$SHA503")"
echo "$DISCARD_OUT" | grep -qE '^restored [a-f0-9]{7}  alpha\.txt$' \
    || fail "test 503: restore output format wrong, got: '$DISCARD_OUT'"
pass "test 503: restore output format"

# ============================================================================
# Test --porcelain output is tab-separated
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA504="$(first_sha --oneline --file alpha.txt)"
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
sed -i.bak '1s/.*/Staged content./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null
STAGED505_BEFORE="$("$GIT_HUNK" count --staged)"

sed -i.bak '1s/.*/Additional unstaged change./' alpha.txt
"$GIT_HUNK" restore --all > /dev/null
STAGED505_AFTER="$("$GIT_HUNK" count --staged)"
[[ "$STAGED505_BEFORE" == "$STAGED505_AFTER" ]] \
    || fail "test 505: restore should not affect staged changes (before=$STAGED505_BEFORE, after=$STAGED505_AFTER)"
pass "test 505: restore preserves staged changes"

# ============================================================================
# Test --file only restores hunks in specified file
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt

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
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA508="$(first_sha --oneline)"
OUT508="$("$GIT_HUNK" restore --dry-run --porcelain "$SHA508")"
echo "$OUT508" | grep -q "^would-restore" \
    || fail "test 508: expected 'would-restore' verb in porcelain output, got: '$OUT508'"
pass "test 508: restore --dry-run --porcelain uses would-restore verb"

# ============================================================================
# Test untracked file without --force exits 1
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA509="$(first_sha --oneline --file untracked.txt)"
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

SHA510="$(first_sha --oneline --file untracked.txt)"
[[ -n "$SHA510" ]] || fail "test 510: no untracked hunk found"
"$GIT_HUNK" restore --force "$SHA510" > /dev/null
[[ ! -f untracked.txt ]] || fail "test 510: untracked file should be deleted after --force restore"
pass "test 510: restore --force deletes untracked file"

# ============================================================================
# Test --all without --force skips untracked files
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

if "$GIT_HUNK" restore --all > /dev/null 2>/dev/null; then
    fail "test 511: expected exit 1 for --all with untracked (no --force)"
fi
pass "test 511: restore --all without --force errors on untracked"

# ============================================================================
# Test --force --all restores everything including untracked
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
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

SHA513="$(first_sha --oneline --file untracked.txt)"
[[ -n "$SHA513" ]] || fail "test 513: no untracked hunk found"
OUT513="$("$GIT_HUNK" restore --dry-run "$SHA513" 2>/dev/null)"
echo "$OUT513" | grep -q "would restore" || fail "test 513: expected 'would restore' in output, got: '$OUT513'"
[[ -f untracked.txt ]] || fail "test 513: file should still exist after dry-run"
pass "test 513: restore --dry-run works for untracked without --force"

# ============================================================================
# Test --tracked-only excludes untracked from --all
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

"$GIT_HUNK" restore --all --tracked-only > /dev/null
[[ -f untracked.txt ]] || fail "test 514: untracked file should survive --tracked-only restore"
REMAINING514="$("$GIT_HUNK" list --tracked-only --porcelain --oneline)"
[[ -z "$REMAINING514" ]] || fail "test 514: tracked hunks should be restored"
pass "test 514: restore --tracked-only excludes untracked from --all"

# ============================================================================
# Test 515: restore sha:N-M discards only selected lines, leaves others intact
# Using pure insertions with --unified 0 so context lines match worktree.
# ============================================================================
new_repo
cat > linespec.txt <<'LINESPEC_EOF'
line 1
line 2
line 3
line 4
line 5
LINESPEC_EOF
git add linespec.txt && git commit -m "linespec setup" -q
cat > linespec.txt <<'LINESPEC_EOF'
line 1
line 2
new line A
new line B
new line C
line 3
line 4
line 5
LINESPEC_EOF

SHA515="$("$GIT_HUNK" list --unified 0 --porcelain --oneline --file linespec.txt | head -1 | cut -f1)"
[[ -n "$SHA515" ]] || fail "test 515: no hunk found"
"$GIT_HUNK" restore --no-color --unified 0 "${SHA515}:1-2" > /dev/null

WORKTREE515="$(git diff linespec.txt)"
if echo "$WORKTREE515" | grep -q "new line A"; then
    fail "test 515: new line A should be restored (removed from worktree)"
fi
if echo "$WORKTREE515" | grep -q "new line B"; then
    fail "test 515: new line B should be restored (removed from worktree)"
fi
echo "$WORKTREE515" | grep -q "new line C" \
    || fail "test 515: new line C should remain in worktree"
pass "test 515: restore sha:N-M discards only selected lines"

# ============================================================================
# Test 516: restore with line spec shows sha:N-M suffix in output
# ============================================================================
new_repo
cat > linespec.txt <<'LINESPEC_EOF'
line 1
line 2
line 3
line 4
line 5
LINESPEC_EOF
git add linespec.txt && git commit -m "linespec setup" -q
cat > linespec.txt <<'LINESPEC_EOF'
line 1
line 2
new line A
new line B
new line C
line 3
line 4
line 5
LINESPEC_EOF

SHA516="$("$GIT_HUNK" list --unified 0 --porcelain --oneline --file linespec.txt | head -1 | cut -f1)"
[[ -n "$SHA516" ]] || fail "test 516: no hunk found"
OUT516="$("$GIT_HUNK" restore --no-color --unified 0 "${SHA516}:1-2")"
echo "$OUT516" | grep -qE '^restored [a-f0-9]{7}:1-2  linespec\.txt$' \
    || fail "test 516: restore output format wrong, got: '$OUT516'"
pass "test 516: restore output format includes line spec suffix"

# ============================================================================
# Test 517: restore hunk A does not bleed into adjacent hunk B
# ============================================================================
new_repo
cat > adjacency.txt <<'ADJ_EOF'
line 1
line 2 original
line 3
line 4
line 5
line 6
line 7
line 8
line 9
line 10
line 11
line 12
line 13
line 14
line 15
line 16
line 17
line 18 original
line 19
line 20
ADJ_EOF
git add adjacency.txt && git commit -m "adjacency setup" -q
sed -i.bak 's/line 2 original/line 2 changed/' adjacency.txt
sed -i.bak 's/line 18 original/line 18 changed/' adjacency.txt

HUNKS517="$("$GIT_HUNK" list --porcelain --oneline --file adjacency.txt)"
HUNK_COUNT517="$(echo "$HUNKS517" | wc -l | tr -d ' ')"
[[ "$HUNK_COUNT517" -eq 2 ]] \
    || fail "test 517: expected 2 hunks, got $HUNK_COUNT517"

SHA517_TOP="$(echo "$HUNKS517" | sort -t$'\t' -k3 -n | head -1 | cut -f1)"
SHA517_BOT="$(echo "$HUNKS517" | sort -t$'\t' -k3 -n | tail -1 | cut -f1)"
[[ -n "$SHA517_TOP" && -n "$SHA517_BOT" ]] \
    || fail "test 517: could not extract both hunk SHAs"

"$GIT_HUNK" restore --no-color "$SHA517_TOP" > /dev/null

WORKTREE517="$(git diff adjacency.txt)"
if echo "$WORKTREE517" | grep -q "line 2 changed"; then
    fail "test 517: top hunk should be restored (line 2 should be reverted)"
fi
echo "$WORKTREE517" | grep -q "line 18 changed" \
    || fail "test 517: bottom hunk should still be present in worktree"
pass "test 517: restore hunk A does not affect adjacent hunk B"

# ============================================================================
# Test 518: restore --file a --file c restores union of files (multi-file)
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
sed -i.bak '1s/.*/Changed gamma./' gamma.txt
"$GIT_HUNK" restore --file alpha.txt --file gamma.txt > /dev/null 2>/dev/null
UNSTAGED518="$(git diff --name-only)"
echo "$UNSTAGED518" | grep -q "beta.txt" || fail "test 518: beta.txt should remain modified"
echo "$UNSTAGED518" | grep -q "alpha.txt" && fail "test 518: alpha.txt should have been restored" || true
echo "$UNSTAGED518" | grep -q "gamma.txt" && fail "test 518: gamma.txt should have been restored" || true
pass "test 518: restore --file a --file c restores union, leaves b"

# ============================================================================
# Test 519: restore --ref <past-commit> with drifted context fails without --3way.
# Setup: a 5-line file is committed (C0). C1 modifies line 3. C2 modifies the
# *surrounding lines* (not line 3) — context for C1's hunk drifts. Plain
# reverse-apply of C1 should fail because the surrounding lines don't match.
# ============================================================================
new_repo
cat > drift.txt <<'EOF_C0'
alpha
beta
gamma
delta
epsilon
EOF_C0
git add drift.txt && git commit -q -m "C0: 5-line file"
# C1: modify line 3 (gamma → GAMMA-modified)
sed -i.bak 's/^gamma$/GAMMA-modified/' drift.txt && rm drift.txt.bak
git add drift.txt && git commit -q -m "C1: modify line 3"
HIST_C1=$(git rev-parse HEAD)
# C2: rewrite the surrounding context lines so C1's hunk context drifts
cat > drift.txt <<'EOF_C2'
ALPHA-rewritten
BETA-rewritten
GAMMA-modified
DELTA-rewritten
EPSILON-rewritten
EOF_C2
git add drift.txt && git commit -q -m "C2: rewrite context lines"

SHA519=$("$GIT_HUNK" list --ref "$HIST_C1" --porcelain --oneline --file drift.txt | head -1 | cut -f1)
[[ -n "$SHA519" ]] || fail "test 519: no hunk found in C1"

# Plain reverse-apply: the patch recorded "context: alpha/beta/delta/epsilon"
# but the worktree has "ALPHA/BETA/DELTA/EPSILON" → patch does not apply.
if "$GIT_HUNK" restore --ref "$HIST_C1" "$SHA519" 2>/dev/null; then
    fail "test 519: plain restore should fail when context has drifted"
fi
pass "test 519: plain restore fails on context drift"

# ============================================================================
# Test 520: --3way uses recorded blob ids to merge despite context drift.
# Setup as in 519: --3way should reverse-apply C1's line-3 change while
# keeping C2's surrounding-line changes — i.e. line 3 reverts to "gamma"
# while ALPHA/BETA/DELTA/EPSILON remain rewritten.
# ============================================================================
"$GIT_HUNK" restore --ref "$HIST_C1" --3way "$SHA519" > /dev/null 2>&1 || true
grep -q "^gamma$" drift.txt \
    || fail "test 520: --3way should revert line 3 to 'gamma'; got: $(cat drift.txt)"
grep -q "^ALPHA-rewritten$" drift.txt \
    || fail "test 520: --3way should preserve C2's line-1 rewrite; got: $(cat drift.txt)"
pass "test 520: restore --3way merges around context drift, preserving unrelated edits"
git reset --hard HEAD > /dev/null 2>&1

# ============================================================================
# Test 522: when --3way is already set, the "try --3way" hint is suppressed
# in the failure-path error message (regression for the misleading hint).
# Force a hard failure: a hunk against a worktree whose blob is unrelated.
# ============================================================================
new_repo
echo "completely unrelated worktree content" > unrelated.txt
git add unrelated.txt && git commit -q -m "C0: unrelated.txt"
HIST_FAIL=$(git rev-parse HEAD)
echo "totally different content" > unrelated.txt
git add unrelated.txt && git commit -q -m "C1: rewrite"
git revert --no-edit HEAD~1 > /dev/null 2>&1 || true
# Try restoring the C0 hunk against a worktree that no longer matches.
SHA522=$("$GIT_HUNK" list --ref "$HIST_FAIL" --porcelain --oneline --file unrelated.txt | head -1 | cut -f1)
ERR522=$("$GIT_HUNK" restore --ref "$HIST_FAIL" --3way "$SHA522" 2>&1 1>/dev/null || true)
echo "$ERR522" | grep -q "try --3way" \
    && fail "test 522: '(try --3way)' hint should NOT appear when --3way already set; got: '$ERR522'" || true
pass "test 522: --3way suppresses the misleading 'try --3way' hint"
git reset --hard HEAD > /dev/null 2>&1

# ============================================================================
# Test 523: restore --3way that leaves conflict markers exits non-zero with a
# clear message (mirrors add --3way / commit --3way fail-loud behaviour).
# ============================================================================
new_repo
echo "C0-line-one" > confl523.txt
git add confl523.txt && git commit -q -m "C0"
HIST_C0=$(git rev-parse HEAD)
echo "C1-line-one" > confl523.txt
git add confl523.txt && git commit -q -m "C1"
SHA523=$("$GIT_HUNK" list --ref "$HIST_C0" --porcelain --oneline --file confl523.txt | head -1 | cut -f1)
[[ -n "$SHA523" ]] || fail "test 523: no hunk found"

# C0 created the file with content X; reverse-applying that = delete the file.
# But the worktree currently has different content for confl523.txt, so 3-way
# can't fully resolve. Two acceptable outcomes:
#   (a) "left conflict markers" — markers MUST exist in the worktree file
#       (this is the resolution path the user is told to follow)
#   (b) "do not apply cleanly" — worktree MUST be unchanged from pre-attempt
ERR523=$("$GIT_HUNK" restore --ref "$HIST_C0" --3way "$SHA523" 2>&1 || true)
PRE523=$(cat confl523.txt)
if echo "$ERR523" | grep -q "left conflict markers"; then
    grep -q "<<<<<<<" confl523.txt \
        || fail "test 523: 'left conflict markers' message but no <<<<<<< in confl523.txt"
elif echo "$ERR523" | grep -q "do not apply cleanly"; then
    [[ "$PRE523" == "C1-line-one" ]] \
        || fail "test 523: 'do not apply cleanly' should leave worktree untouched; got: '$PRE523'"
else
    fail "test 523: expected 'left conflict markers' or 'do not apply cleanly'; got: '$ERR523'"
fi
pass "test 523: restore --3way fails clearly when 3-way produces conflicts"
git reset --hard HEAD > /dev/null 2>&1

# ============================================================================
# Test 521: end-to-end "undo this hunk from history" workflow
# Setup a commit C that introduces a bug; later HEAD has unrelated state.
# `restore --ref C^..C SHA` reverse-applies the bad hunk to make worktree
# match (the file no longer contains the buggy content).
# ============================================================================
new_repo
cat > buggy.txt <<'EOF'
working line
EOF
git add buggy.txt && git commit -q -m "C-pre: working state"
cat > buggy.txt <<'EOF'
working line
buggy line
EOF
git add buggy.txt && git commit -q -m "C: introduce bug"
HIST_C=$(git rev-parse HEAD)
echo "still bad" >> buggy.txt
# At this point worktree has both buggy + extra. We want to undo C's bug only.
SHA521=$("$GIT_HUNK" list --ref "$HIST_C" --porcelain --oneline --file buggy.txt | head -1 | cut -f1)
[[ -n "$SHA521" ]] || fail "test 521: no hunk found for C"

# The worktree has an unrelated edit the index does not, and --3way must
# neither trip over it nor stage the undo.
INDEX521="$(git ls-files -s buggy.txt)"
"$GIT_HUNK" restore --ref "$HIST_C" --3way "$SHA521" > /dev/null 2>&1 \
    || fail "test 521: undoing C's hunk with --3way failed"
[[ "$(bytes_of buggy.txt)" == "$(want_bytes 'working line\nstill bad\n')" ]] \
    || fail "test 521: the buggy line should be gone and the unrelated edit kept, got: '$(cat buggy.txt)'"
[[ "$(git ls-files -s buggy.txt)" == "$INDEX521" ]] || fail "test 521: the undo should not be staged"
pass "test 521: e2e undo-hunk-from-history preserves unrelated worktree edits"

# ============================================================================
# Test 525: restore sha:N at DEFAULT context (regression)
# Tests 515/516 pass --unified 0, which gives every added line its own hunk and
# so never produces a deselected '+' inside a hunk. At default context the
# reverse-apply patch has to keep deselected additions as context lines or git
# rejects it with "patch does not apply".
# ============================================================================
new_repo
cat > ctxspec.txt <<'CTX_EOF'
keep-A
keep-B
keep-C
CTX_EOF
git add ctxspec.txt && git commit -m "ctxspec setup" -q
cat > ctxspec.txt <<'CTX_EOF'
keep-A
ADD-1
ADD-2
keep-B
ADD-3
keep-C
CTX_EOF

SHA525="$(first_sha --oneline --file ctxspec.txt)"
[[ -n "$SHA525" ]] || fail "test 525: no hunk found"
# Body line 2 is ADD-1 (line 1 is the keep-A context line).
"$GIT_HUNK" restore --no-color "${SHA525}:2" > /dev/null \
    || fail "test 525: restore with line spec failed at default context"

if grep -q "ADD-1" ctxspec.txt; then fail "test 525: ADD-1 should have been restored away"; fi
grep -q "ADD-2" ctxspec.txt || fail "test 525: ADD-2 should remain in worktree"
grep -q "ADD-3" ctxspec.txt || fail "test 525: ADD-3 should remain in worktree"
pass "test 525: restore sha:N works at default context"

# ============================================================================
# Test 526: restore sha:N at default context, deletion hunk (regression)
# Mirror of 525 for removals: a deselected '-' must be dropped from the
# reverse-apply patch, not turned into a context line.
# ============================================================================
new_repo
cat > delspec.txt <<'DEL_EOF'
keep-A
DEL-1
DEL-2
keep-B
DEL-3
keep-C
DEL_EOF
git add delspec.txt && git commit -m "delspec setup" -q
cat > delspec.txt <<'DEL_EOF'
keep-A
keep-B
keep-C
DEL_EOF

SHA526="$(first_sha --oneline --file delspec.txt)"
[[ -n "$SHA526" ]] || fail "test 526: no hunk found"
# Body line 2 is the '-DEL-1' line; restoring it puts DEL-1 back.
"$GIT_HUNK" restore --no-color "${SHA526}:2" > /dev/null \
    || fail "test 526: restore of a removal failed at default context"

grep -q "DEL-1" delspec.txt || fail "test 526: DEL-1 should have been restored"
if grep -q "DEL-2" delspec.txt; then fail "test 526: DEL-2 should stay deleted"; fi
if grep -q "DEL-3" delspec.txt; then fail "test 526: DEL-3 should stay deleted"; fi
pass "test 526: restore sha:N of a removal works at default context"

# ============================================================================
# Test 527: restore mixed add+delete hunk with a partial spec (regression)
# Exercises both filtering rules in one patch: a deselected '-' must be dropped
# while a deselected '+' must become context.
# ============================================================================
new_repo
cat > mixspec.txt <<'MIX_EOF'
ctx
OLD-1
OLD-2
ctx2
MIX_EOF
git add mixspec.txt && git commit -m "mixspec setup" -q
cat > mixspec.txt <<'MIX_EOF'
ctx
NEW-1
NEW-2
ctx2
MIX_EOF

SHA527="$(first_sha --oneline --file mixspec.txt)"
[[ -n "$SHA527" ]] || fail "test 527: no hunk found"
# Body lines: 1=' ctx' 2='-OLD-1' 3='-OLD-2' 4='+NEW-1' 5='+NEW-2' 6=' ctx2'
"$GIT_HUNK" restore --no-color "${SHA527}:2,4" > /dev/null \
    || fail "test 527: restore of mixed hunk failed at default context"

grep -q "OLD-1" mixspec.txt || fail "test 527: OLD-1 should have been restored"
if grep -q "NEW-1" mixspec.txt; then fail "test 527: NEW-1 should have been restored away"; fi
if grep -q "OLD-2" mixspec.txt; then fail "test 527: OLD-2 should stay deleted"; fi
grep -q "NEW-2" mixspec.txt || fail "test 527: NEW-2 should remain"
pass "test 527: restore mixed add+delete hunk with partial spec"

# ============================================================================
# Test 528: restore --3way changes the worktree and leaves the index alone,
# except to record a conflict. `git apply --3way` implies --index, so without
# --ref every restore --3way failed ("does not match index") or, for a partial
# restore of a deletion, wrote conflict markers; with --ref a clean restore
# was silently staged.
# ============================================================================
lines528() { for i in $(seq 1 20); do echo "line $i"; done; }
index528() { git ls-files -s -- "$@"; }

# No --ref: the hunk comes from the current diff, so there is nothing to
# merge and --3way changes nothing.
new_repo
lines528 > f528.txt
git add f528.txt && git commit -q -m "f528"
sed -i.bak 's/^line 2$/line 2 staged/' f528.txt && git add f528.txt
sed -i.bak 's/^line 15$/line 15 unstaged/' f528.txt
INDEX528="$(index528 f528.txt)"
"$GIT_HUNK" restore --3way "$(first_sha --file f528.txt)" > /dev/null 2>&1 \
    || fail "test 528: restore --3way without --ref failed"
[[ "$(bytes_of f528.txt)" == "$(blob_bytes :f528.txt)" ]] \
    || fail "test 528: restore --3way should bring f528.txt back to the index"
[[ "$(index528 f528.txt)" == "$INDEX528" ]] || fail "test 528: restore --3way without --ref changed the index"

new_repo
lines528 > gone528.txt
git add gone528.txt && git commit -q -m "gone528"
rm gone528.txt
INDEX528="$(index528 gone528.txt)"
"$GIT_HUNK" restore --3way "$(first_sha --file gone528.txt):3" > /dev/null 2>&1 \
    || fail "test 528: partial restore --3way of a deletion failed"
[[ "$(bytes_of gone528.txt)" == "$(want_bytes 'line 3\n')" ]] \
    || fail "test 528: partial restore of a deletion should bring back line 3 alone, got: '$(cat gone528.txt 2>&1)'"
[[ "$(index528 gone528.txt)" == "$INDEX528" ]] || fail "test 528: partial restore --3way of a deletion changed the index"

# --ref, applying cleanly: the worktree changes, the index does not.
new_repo
lines528 > f528.txt
git add f528.txt && git commit -q -m "f528"
sed -i.bak 's/^line 5$/line 5 changed/' f528.txt && git commit -q -am "change 528"
CHANGE528="$(git rev-parse HEAD)"
SHA528="$(first_sha --ref "$CHANGE528" --file f528.txt)"
INDEX528="$(index528 f528.txt)"
"$GIT_HUNK" restore --ref "$CHANGE528" --3way "$SHA528" > /dev/null 2>&1 \
    || fail "test 528: restore --ref --3way that applies cleanly failed"
[[ "$(bytes_of f528.txt)" == "$(blob_bytes "$CHANGE528~1:f528.txt")" ]] \
    || fail "test 528: restore --ref --3way should revert line 5 in the worktree"
[[ "$(index528 f528.txt)" == "$INDEX528" ]] || fail "test 528: a clean restore --ref --3way staged the restore"

# --ref, merging cleanly around drifted context: still worktree only.
git reset -q --hard
sed -i.bak 's/^line 8$/line 8 drifted/' f528.txt && git commit -q -am "drift 528"
INDEX528="$(index528 f528.txt)"
"$GIT_HUNK" restore --ref "$CHANGE528" --3way "$SHA528" > /dev/null 2>&1 \
    || fail "test 528: restore --ref --3way that merges cleanly failed"
[[ "$(sed -n 5p f528.txt)" == "line 5" && "$(sed -n 8p f528.txt)" == "line 8 drifted" ]] \
    || fail "test 528: the merge should revert line 5 and keep line 8, got: '$(sed -n 5,8p f528.txt)'"
[[ "$(index528 f528.txt)" == "$INDEX528" ]] || fail "test 528: a merged restore --ref --3way staged the restore"
[[ -z "$(git ls-files -u)" ]] || fail "test 528: a clean merge left unmerged entries"

# --ref, conflicting: markers in the worktree, the conflict in the index,
# with what was staged as "ours".
git reset -q --hard
sed -i.bak 's/^line 5 changed$/line 5 changed again/' f528.txt && git add f528.txt
OURS528="$(git rev-parse :f528.txt)"
EC528=0
"$GIT_HUNK" restore --ref "$CHANGE528" --3way "$SHA528" > /dev/null 2>&1 || EC528=$?
[[ "$EC528" -eq 1 ]] || fail "test 528: a conflicting restore --3way should exit 1, got $EC528"
grep -q '^<<<<<<<' f528.txt || fail "test 528: a conflicting restore --3way should leave markers in f528.txt"
[[ "$(git ls-files -u -- f528.txt | cut -f1 | cut -d' ' -f3 | tr '\n' ' ')" == "1 2 3 " ]] \
    || fail "test 528: the conflict should be recorded as stages 1-3, got: '$(git ls-files -s f528.txt)'"
[[ "$(git ls-files -u -- f528.txt | awk '$3 == 2 {print $2}')" == "$OURS528" ]] \
    || fail "test 528: stage 2 should be what was staged"
pass "test 528: restore --3way touches the index only to record a conflict"

report_results
