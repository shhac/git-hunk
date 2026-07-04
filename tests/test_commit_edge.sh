#!/usr/bin/env bash
# Edge-case and fault-injection tests for `git hunk commit` (tests 1100-1119).
#
# These pin the OBSERVABLE unhappy-path contract of the transactional commit
# (exit code, staged diff byte-preserved, no .git/index.hunk-backup left, log
# unchanged, worktree untouched) so an internal redesign of the transaction
# can be validated against unchanged tests. Scenario names S2..S9 refer to
# the behavior matrix in .ai-cache/plan-commit-temp-index.md.
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 1100 (S2): staged + unstaged edits in the same region; committing the
# unstaged hunk aborts cleanly (patch context references the staged content,
# which is absent from the HEAD-reset index).
# ============================================================================
new_repo
sed -i.bak '5s/.*/staged five s2/' alpha.txt
git add alpha.txt
sed -i.bak '6s/.*/unstaged six s2/' alpha.txt

STAGED1100="$(git diff --cached)"
HEAD1100="$(git rev-parse HEAD)"
WT1100="$(cat alpha.txt)"
SHA1100="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA1100" ]] || fail "test 1100: no unstaged hunk found"
EC1100=0
ERR1100="$("$GIT_HUNK" commit "$SHA1100" -m "s2 overlap" 2>&1)" || EC1100=$?
[[ "$EC1100" -eq 1 ]] \
    || fail "test 1100: expected exit 1, got $EC1100"
[[ "$(git diff --cached)" == "$STAGED1100" ]] \
    || fail "test 1100: staged diff not byte-preserved after abort"
[[ "$(git rev-parse HEAD)" == "$HEAD1100" ]] \
    || fail "test 1100: HEAD moved despite abort"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1100: index backup left behind after abort"
[[ "$(cat alpha.txt)" == "$WT1100" ]] \
    || fail "test 1100: worktree file changed despite abort"
echo "$ERR1100" | grep -q "did not apply cleanly" \
    || fail "test 1100: expected 'did not apply cleanly' on stderr, got: '$ERR1100'"
pass "test 1100: S2 same-region staged+unstaged overlap aborts cleanly"

# ============================================================================
# Test 1101 (S2b): same overlap with --3way aborts before committing with a
# "produced conflicts" error. Observed: the conflict lives only in the
# momentary index (apply --cached --3way); the abort rolls it back and the
# WORKTREE file is left byte-unchanged — no conflict markers on disk.
# ============================================================================
new_repo
sed -i.bak '5s/.*/staged five s2b/' alpha.txt
git add alpha.txt
sed -i.bak '6s/.*/unstaged six s2b/' alpha.txt

STAGED1101="$(git diff --cached)"
HEAD1101="$(git rev-parse HEAD)"
WT1101="$(cat alpha.txt)"
SHA1101="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA1101" ]] || fail "test 1101: no unstaged hunk found"
EC1101=0
ERR1101="$("$GIT_HUNK" commit --3way "$SHA1101" -m "s2b overlap 3way" 2>&1)" || EC1101=$?
[[ "$EC1101" -eq 1 ]] \
    || fail "test 1101: expected exit 1, got $EC1101"
echo "$ERR1101" | grep -q "produced conflicts" \
    || fail "test 1101: expected 'produced conflicts' on stderr, got: '$ERR1101'"
[[ "$(git diff --cached)" == "$STAGED1101" ]] \
    || fail "test 1101: staged diff not byte-preserved after --3way abort"
[[ "$(git rev-parse HEAD)" == "$HEAD1101" ]] \
    || fail "test 1101: HEAD moved despite --3way abort"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1101: index backup left behind after --3way abort"
[[ "$(cat alpha.txt)" == "$WT1101" ]] \
    || fail "test 1101: worktree file should be untouched (no conflict markers)"
pass "test 1101: S2b --3way conflict aborts before commit, worktree clean"

# ============================================================================
# Test 1102 (S5): staged deletion + recreated worktree file; committing the
# recreation hunk aborts ("already exists in index" against the HEAD-reset
# index). Staged deletion preserved, recreated file untouched.
# ============================================================================
new_repo
git rm -q alpha.txt
printf 'recreated line one\nrecreated line two\n' > alpha.txt

STAGED1102="$(git diff --cached)"
HEAD1102="$(git rev-parse HEAD)"
SHA1102="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA1102" ]] || fail "test 1102: no recreation hunk found"
EC1102=0
ERR1102="$("$GIT_HUNK" commit "$SHA1102" -m "s5 recreate" 2>&1)" || EC1102=$?
[[ "$EC1102" -eq 1 ]] \
    || fail "test 1102: expected exit 1, got $EC1102"
[[ "$(git diff --cached)" == "$STAGED1102" ]] \
    || fail "test 1102: staged deletion not preserved after abort"
git diff --cached --name-status | grep -q "^D	alpha.txt" \
    || fail "test 1102: alpha.txt deletion should still be staged"
[[ "$(git rev-parse HEAD)" == "$HEAD1102" ]] \
    || fail "test 1102: HEAD moved despite abort"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1102: index backup left behind after abort"
[[ "$(cat alpha.txt)" == "$(printf 'recreated line one\nrecreated line two\n')" ]] \
    || fail "test 1102: recreated worktree file changed despite abort"
echo "$ERR1102" | grep -q "already exists in index" \
    || fail "test 1102: expected 'already exists in index' on stderr, got: '$ERR1102'"
pass "test 1102: S5 staged-delete + recreate aborts cleanly"

# ============================================================================
# Test 1103 (S6): staged modification + worktree file deleted; committing the
# deletion hunk aborts (deletion patch pre-image is the staged content, which
# the HEAD-reset index doesn't have). Staged modification preserved.
# ============================================================================
new_repo
sed -i.bak '1s/.*/staged modification s6/' alpha.txt
git add alpha.txt
rm alpha.txt

STAGED1103="$(git diff --cached)"
HEAD1103="$(git rev-parse HEAD)"
SHA1103="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA1103" ]] || fail "test 1103: no deletion hunk found"
EC1103=0
ERR1103="$("$GIT_HUNK" commit "$SHA1103" -m "s6 delete" 2>&1)" || EC1103=$?
[[ "$EC1103" -eq 1 ]] \
    || fail "test 1103: expected exit 1, got $EC1103"
[[ "$(git diff --cached)" == "$STAGED1103" ]] \
    || fail "test 1103: staged modification not preserved after abort"
[[ "$(git rev-parse HEAD)" == "$HEAD1103" ]] \
    || fail "test 1103: HEAD moved despite abort"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1103: index backup left behind after abort"
[[ ! -f alpha.txt ]] \
    || fail "test 1103: worktree deletion should be untouched by abort"
echo "$ERR1103" | grep -q "did not apply cleanly" \
    || fail "test 1103: expected 'did not apply cleanly' on stderr, got: '$ERR1103'"
pass "test 1103: S6 staged-mod + worktree-delete aborts cleanly"

# ============================================================================
# Test 1104 (S8 + S8b): proximity decides the outcome for staged + unstaged
# edits in one file.
#   S8:  within patch-context distance (<=3 lines) -> clean abort (the
#        unstaged hunk's context lines include the staged content).
#   S8b: far apart -> success; commit created; staged half survives in the
#        index; no backup left.
# ============================================================================
new_repo
sed -i.bak '5s/.*/staged five s8/' alpha.txt
git add alpha.txt
sed -i.bak '7s/.*/unstaged seven s8/' alpha.txt

STAGED1104="$(git diff --cached)"
HEAD1104="$(git rev-parse HEAD)"
SHA1104="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA1104" ]] || fail "test 1104: no unstaged hunk found (S8)"
EC1104=0
"$GIT_HUNK" commit "$SHA1104" -m "s8 near" > /dev/null 2>&1 || EC1104=$?
[[ "$EC1104" -eq 1 ]] \
    || fail "test 1104: S8 expected exit 1, got $EC1104"
[[ "$(git diff --cached)" == "$STAGED1104" ]] \
    || fail "test 1104: S8 staged diff not byte-preserved after abort"
[[ "$(git rev-parse HEAD)" == "$HEAD1104" ]] \
    || fail "test 1104: S8 HEAD moved despite abort"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1104: S8 index backup left behind after abort"

# S8b: far-apart regions succeed.
new_repo
sed -i.bak '3s/.*/staged three s8b/' alpha.txt
git add alpha.txt
sed -i.bak '25s/.*/unstaged twentyfive s8b/' alpha.txt

COMMITS1104B="$(git rev-list --count HEAD)"
SHA1104B="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA1104B" ]] || fail "test 1104: no unstaged hunk found (S8b)"
"$GIT_HUNK" commit "$SHA1104B" -m "s8b far" > /dev/null 2>&1 \
    || fail "test 1104: S8b far-apart commit should succeed"
[[ "$(git rev-list --count HEAD)" -eq "$((COMMITS1104B + 1))" ]] \
    || fail "test 1104: S8b expected exactly one new commit"
git log --oneline -1 | grep -q "s8b far" \
    || fail "test 1104: S8b commit message not found"
git diff --cached | grep -q "staged three s8b" \
    || fail "test 1104: S8b staged half should still be staged after commit"
git diff --cached | grep -q "unstaged twentyfive s8b" \
    && fail "test 1104: S8b committed hunk leaked into staged diff" || true
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1104: S8b index backup left behind after success"
pass "test 1104: S8 near-overlap aborts, S8b far-apart succeeds with staged half intact"

# ============================================================================
# Test 1105 (S9): a pre-commit hook that creates + `git add`s a file gets that
# file INTO the commit (hooks see the transaction index), and afterwards the
# hook-created path is fully clean: its index entry is synced to the new
# HEAD, so there is no phantom staged deletion and no untracked leftover.
# User-staged paths (including staged deletions) must survive the cleanup.
# ============================================================================
new_repo
mkdir -p .git/hooks
printf '#!/bin/sh\necho fixed > hookfix.txt\ngit add hookfix.txt\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
sed -i.bak '1s/.*/unstaged one s9/' alpha.txt
printf 'staged s9\n' > staged1105.txt
git add staged1105.txt              # user-staged addition: must survive
git rm -q beta.txt                  # user-staged deletion: must survive

SHA1105="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA1105" ]] || fail "test 1105: no unstaged hunk found"
"$GIT_HUNK" commit "$SHA1105" -m "s9 hook add" > /dev/null 2>&1 \
    || fail "test 1105: commit with file-adding hook should succeed"
COMMITTED1105="$(git show --name-only --pretty=format: HEAD)"
echo "$COMMITTED1105" | grep -q "^alpha.txt$" \
    || fail "test 1105: alpha.txt missing from commit"
echo "$COMMITTED1105" | grep -q "^hookfix.txt$" \
    || fail "test 1105: hook-added hookfix.txt missing from commit"
STATUS1105="$(git status --short)"
echo "$STATUS1105" | grep -q "hookfix.txt" \
    && fail "test 1105: hook-created path should be clean after commit, got: '$STATUS1105'"
echo "$STATUS1105" | grep -q "^A  staged1105.txt$" \
    || fail "test 1105: user-staged addition lost, got: '$STATUS1105'"
echo "$STATUS1105" | grep -q "^D  beta.txt$" \
    || fail "test 1105: user-staged deletion lost, got: '$STATUS1105'"
[[ "$(cat hookfix.txt)" == "fixed" ]] \
    || fail "test 1105: hookfix.txt worktree content wrong"
pass "test 1105: S9 hook-added file lands in commit; index synced, staged work intact"

# ============================================================================
# Tests 1106-1109: fault injection via tests/git-shim.sh — a `git` shim
# prepended to PATH for the git-hunk invocation only. Setup for each: one
# staged file (beta.txt) plus one unstaged alpha.txt hunk being committed.
#
# Matching-invocation counts observed for one successful single-patch commit
# (learned by running the shim in count-only mode, no FAIL_ON):
#   read-tree: 1   (step 2: reset index to HEAD)
#   apply:     2   (step 3: stage hunk into index; step 6: post-commit resync)
#   commit:    1   (step 4)
# ============================================================================
SHIM_DIR="$(mktemp -d)"
cp "$SCRIPT_DIR/git-shim.sh" "$SHIM_DIR/git"
chmod +x "$SHIM_DIR/git"
trap 'cleanup_repo; rm -rf "$SHIM_DIR"' EXIT
SHIM_COUNT="$SHIM_DIR/count"

# ============================================================================
# Test 1106: fail the 1st `git read-tree` -> abort; staged diff unchanged; no
# backup left; no new commit.
# ============================================================================
new_repo
sed -i.bak '1s/.*/staged beta 1106/' beta.txt
git add beta.txt
sed -i.bak '15s/.*/unstaged alpha 1106/' alpha.txt

STAGED1106="$(git diff --cached)"
HEAD1106="$(git rev-parse HEAD)"
SHA1106="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
echo 0 > "$SHIM_COUNT"
EC1106=0
PATH="$SHIM_DIR:$PATH" GIT_HUNK_SHIM_FAIL=read-tree GIT_HUNK_SHIM_FAIL_ON=1 GIT_HUNK_SHIM_COUNT_FILE="$SHIM_COUNT" \
    "$GIT_HUNK" commit "$SHA1106" -m "fail read-tree" > /dev/null 2>&1 || EC1106=$?
[[ "$EC1106" -ne 0 ]] \
    || fail "test 1106: expected non-zero exit when read-tree fails"
[[ "$(git diff --cached)" == "$STAGED1106" ]] \
    || fail "test 1106: staged diff not byte-preserved after read-tree failure"
[[ "$(git rev-parse HEAD)" == "$HEAD1106" ]] \
    || fail "test 1106: HEAD moved despite read-tree failure"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1106: index backup left behind after read-tree failure"
pass "test 1106: injected read-tree failure aborts cleanly"

# ============================================================================
# Test 1107: fail the 1st `git apply` (staging the hunk into the index) ->
# abort; staged diff unchanged; no backup; no new commit.
# ============================================================================
new_repo
sed -i.bak '1s/.*/staged beta 1107/' beta.txt
git add beta.txt
sed -i.bak '15s/.*/unstaged alpha 1107/' alpha.txt

STAGED1107="$(git diff --cached)"
HEAD1107="$(git rev-parse HEAD)"
SHA1107="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
echo 0 > "$SHIM_COUNT"
EC1107=0
PATH="$SHIM_DIR:$PATH" GIT_HUNK_SHIM_FAIL=apply GIT_HUNK_SHIM_FAIL_ON=1 GIT_HUNK_SHIM_COUNT_FILE="$SHIM_COUNT" \
    "$GIT_HUNK" commit "$SHA1107" -m "fail apply" > /dev/null 2>&1 || EC1107=$?
[[ "$EC1107" -ne 0 ]] \
    || fail "test 1107: expected non-zero exit when apply fails"
[[ "$(git diff --cached)" == "$STAGED1107" ]] \
    || fail "test 1107: staged diff not byte-preserved after apply failure"
[[ "$(git rev-parse HEAD)" == "$HEAD1107" ]] \
    || fail "test 1107: HEAD moved despite apply failure"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1107: index backup left behind after apply failure"
pass "test 1107: injected apply failure aborts cleanly"

# ============================================================================
# Test 1108: fail the 1st `git commit` -> abort; staged diff unchanged; no
# backup; no new commit. Then the --amend variant: HEAD sha unchanged.
# ============================================================================
new_repo
sed -i.bak '1s/.*/staged beta 1108/' beta.txt
git add beta.txt
sed -i.bak '15s/.*/unstaged alpha 1108/' alpha.txt

STAGED1108="$(git diff --cached)"
HEAD1108="$(git rev-parse HEAD)"
SHA1108="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
echo 0 > "$SHIM_COUNT"
EC1108=0
PATH="$SHIM_DIR:$PATH" GIT_HUNK_SHIM_FAIL=commit GIT_HUNK_SHIM_FAIL_ON=1 GIT_HUNK_SHIM_COUNT_FILE="$SHIM_COUNT" \
    "$GIT_HUNK" commit "$SHA1108" -m "fail commit" > /dev/null 2>&1 || EC1108=$?
[[ "$EC1108" -ne 0 ]] \
    || fail "test 1108: expected non-zero exit when commit fails"
[[ "$(git diff --cached)" == "$STAGED1108" ]] \
    || fail "test 1108: staged diff not byte-preserved after commit failure"
[[ "$(git rev-parse HEAD)" == "$HEAD1108" ]] \
    || fail "test 1108: HEAD moved despite commit failure"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1108: index backup left behind after commit failure"

# --amend variant: injected commit failure must leave HEAD untouched.
new_repo
sed -i.bak '1s/.*/staged beta 1108b/' beta.txt
git add beta.txt
sed -i.bak '15s/.*/unstaged alpha 1108b/' alpha.txt

STAGED1108B="$(git diff --cached)"
HEAD1108B="$(git rev-parse HEAD)"
SHA1108B="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
echo 0 > "$SHIM_COUNT"
EC1108B=0
PATH="$SHIM_DIR:$PATH" GIT_HUNK_SHIM_FAIL=commit GIT_HUNK_SHIM_FAIL_ON=1 GIT_HUNK_SHIM_COUNT_FILE="$SHIM_COUNT" \
    "$GIT_HUNK" commit --amend "$SHA1108B" -m "fail amend" > /dev/null 2>&1 || EC1108B=$?
[[ "$EC1108B" -ne 0 ]] \
    || fail "test 1108: --amend expected non-zero exit when commit fails"
[[ "$(git rev-parse HEAD)" == "$HEAD1108B" ]] \
    || fail "test 1108: --amend HEAD sha changed despite commit failure"
[[ "$(git diff --cached)" == "$STAGED1108B" ]] \
    || fail "test 1108: --amend staged diff not byte-preserved after commit failure"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1108: --amend index backup left behind after commit failure"
pass "test 1108: injected commit failure aborts cleanly (plain and --amend)"

# ============================================================================
# Test 1109: fail the 2nd `git apply` (the post-commit index resync) -> the
# commit already landed, so exit 0, new commit EXISTS, and stderr warns that
# the index sync failed with a re-sync instruction. The staged half (beta)
# must still be present in the index.
# ============================================================================
new_repo
sed -i.bak '1s/.*/staged beta 1109/' beta.txt
git add beta.txt
sed -i.bak '15s/.*/unstaged alpha 1109/' alpha.txt

COMMITS1109="$(git rev-list --count HEAD)"
SHA1109="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
echo 0 > "$SHIM_COUNT"
EC1109=0
ERR1109="$(PATH="$SHIM_DIR:$PATH" GIT_HUNK_SHIM_FAIL=apply GIT_HUNK_SHIM_FAIL_ON=2 GIT_HUNK_SHIM_COUNT_FILE="$SHIM_COUNT" \
    "$GIT_HUNK" commit "$SHA1109" -m "fail resync" 2>&1 >/dev/null)" || EC1109=$?
[[ "$EC1109" -eq 0 ]] \
    || fail "test 1109: expected exit 0 when only the post-commit resync fails, got $EC1109"
[[ "$(git rev-list --count HEAD)" -eq "$((COMMITS1109 + 1))" ]] \
    || fail "test 1109: expected the commit to exist despite resync failure"
git log --oneline -1 | grep -q "fail resync" \
    || fail "test 1109: commit message not found"
echo "$ERR1109" | grep -qi "re-sync" \
    || fail "test 1109: expected a warning mentioning re-sync, got: '$ERR1109'"
git diff --cached | grep -q "staged beta 1109" \
    || fail "test 1109: staged beta change should survive resync failure"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1109: index backup left behind after resync failure"
pass "test 1109: injected resync failure keeps commit, warns, exit 0"

# ============================================================================
# Test 1110: hard crash (kill -9) mid-`git commit` leaves the user's index
# untouched -- no backup, no partial commit, no recovery needed on rerun.
# (The pre-temp-index design left the index reset to HEAD with staged work
# recoverable only from .git/index.hunk-backup.)
# ============================================================================
new_repo
printf 'crash staged\n' > beta.txt
git add beta.txt
sed -i.bak '1s/.*/crash worktree change/' alpha.txt && rm alpha.txt.bak
STAGED1110="$(git diff --cached)"
SHA1110="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
COMMITS1110="$(git rev-list --count HEAD)"

KILLSHIM="$(mktemp -d)"
REALGIT="$(command -v git)"
cat > "$KILLSHIM/git" << KILLEOF
#!/bin/sh
if [ "\$1" = "commit" ]; then kill -9 \$PPID; sleep 1; exit 1; fi
exec "$REALGIT" "\$@"
KILLEOF
chmod +x "$KILLSHIM/git"

EC1110=0
PATH="$KILLSHIM:$PATH" "$GIT_HUNK" commit "$SHA1110" -m "crash" >/dev/null 2>&1 || EC1110=$?
[[ "$EC1110" -ne 0 ]] \
    || fail "test 1110: expected nonzero exit after kill -9"
[[ "$(git diff --cached)" == "$STAGED1110" ]] \
    || fail "test 1110: staged diff changed across a mid-commit crash"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1110: crash left an index backup behind"
[[ "$(git rev-list --count HEAD)" -eq "$COMMITS1110" ]] \
    || fail "test 1110: crash produced a commit"
# Rerun must succeed with no stale-backup recovery warning.
ERR1110="$("$GIT_HUNK" commit "$SHA1110" -m "after crash" 2>&1 >/dev/null)" \
    || fail "test 1110: rerun after crash failed"
echo "$ERR1110" | grep -q "stale index backup" \
    && fail "test 1110: rerun printed a recovery warning"
[[ "$(git rev-list --count HEAD)" -eq "$((COMMITS1110 + 1))" ]] \
    || fail "test 1110: rerun did not commit"
rm -rf "$KILLSHIM"
pass "test 1110: kill -9 mid-commit leaves index untouched, rerun clean"

# ============================================================================
# Test 1111: binary commit preserves the full transactional contract
# (the binary path uses separate git-add plumbing for temp staging and
# real-index resync; previously only the commit message was asserted)
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf 'staged bin1111\n' > staged1111.txt
git add staged1111.txt                 # user-staged addition: must survive
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png
STAGED1111="$(git diff --cached)"
SHA1111="$("$GIT_HUNK" list --porcelain --oneline --file image.png | head -1 | cut -f1)"
"$GIT_HUNK" commit "$SHA1111" -m "binary invariants" >/dev/null 2>&1 \
    || fail "test 1111: binary commit failed"
git show --name-only --pretty=format: HEAD | grep -q "^image.png$" \
    || fail "test 1111: image.png missing from commit"
[[ "$(git diff --cached)" == "$STAGED1111" ]] \
    || fail "test 1111: staged diff changed across the binary commit"
STATUS1111="$(git status --short)"
echo "$STATUS1111" | grep -q "image.png" \
    && fail "test 1111: binary path not clean after commit, got: '$STATUS1111'"
echo "$STATUS1111" | grep -q "^A  staged1111.txt$" \
    || fail "test 1111: user-staged addition lost, got: '$STATUS1111'"
[[ ! -f .git/index.hunk-backup ]] \
    || fail "test 1111: backup left behind"
pass "test 1111: binary commit keeps index clean and staged work intact"

# ============================================================================
# Test 1112: binary resync failure downgrades to a warning, commit stands
# (shim: 1st `add` stages into the temp index, 2nd is the real-index resync)
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png
COMMITS1112="$(git rev-list --count HEAD)"
SHA1112="$("$GIT_HUNK" list --porcelain --oneline --file image.png | head -1 | cut -f1)"
echo 0 > "$SHIM_COUNT"
EC1112=0
ERR1112="$(PATH="$SHIM_DIR:$PATH" GIT_HUNK_SHIM_FAIL=add GIT_HUNK_SHIM_FAIL_ON=2 GIT_HUNK_SHIM_COUNT_FILE="$SHIM_COUNT" \
    "$GIT_HUNK" commit "$SHA1112" -m "bin resync fail" 2>&1 >/dev/null)" || EC1112=$?
[[ "$EC1112" -eq 0 ]] \
    || fail "test 1112: expected exit 0 when only binary resync fails, got $EC1112"
[[ "$(git rev-list --count HEAD)" -eq "$((COMMITS1112 + 1))" ]] \
    || fail "test 1112: commit should exist despite binary resync failure"
echo "$ERR1112" | grep -qi "binary file index sync failed" \
    || fail "test 1112: expected binary re-sync warning, got: '$ERR1112'"
pass "test 1112: binary resync failure warns, commit stands, exit 0"

# ============================================================================
# Test 1113: resync failure warning names the failed patch's first path
# (a multi-file selection builds ONE combined patch — apply runs once for
# temp staging and once for resync, so FAIL_ON=2 hits the resync; a
# patches-count > 1 needs a typechange split and is not exercised here)
# ============================================================================
new_repo
sed -i.bak '1s/.*/multi one/' alpha.txt && rm alpha.txt.bak
sed -i.bak '1s/.*/multi two/' beta.txt && rm beta.txt.bak
COMMITS1113="$(git rev-list --count HEAD)"
SHA1113A="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
SHA1113B="$("$GIT_HUNK" list --porcelain --oneline --file beta.txt | head -1 | cut -f1)"
echo 0 > "$SHIM_COUNT"
EC1113=0
ERR1113="$(PATH="$SHIM_DIR:$PATH" GIT_HUNK_SHIM_FAIL=apply GIT_HUNK_SHIM_FAIL_ON=2 GIT_HUNK_SHIM_COUNT_FILE="$SHIM_COUNT" \
    "$GIT_HUNK" commit "$SHA1113A" "$SHA1113B" -m "multi resync" 2>&1 >/dev/null)" || EC1113=$?
[[ "$EC1113" -eq 0 ]] \
    || fail "test 1113: expected exit 0, got $EC1113"
[[ "$(git rev-list --count HEAD)" -eq "$((COMMITS1113 + 1))" ]] \
    || fail "test 1113: commit should exist"
echo "$ERR1113" | grep -q "index sync failed for 1 patch(es)" \
    || fail "test 1113: expected sync failure warning, got: '$ERR1113'"
echo "$ERR1113" | grep -qE "First failure: (alpha|beta).txt" \
    || fail "test 1113: expected first-failure path in warning, got: '$ERR1113'"
pass "test 1113: resync failure warning reports count and first path"

# ============================================================================
# Test 1114: --dry-run of a binary-only selection mutates nothing
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png
COMMITS1114="$(git rev-list --count HEAD)"
HUNKS1114="$("$GIT_HUNK" count)"
SHA1114="$("$GIT_HUNK" list --porcelain --oneline --file image.png | head -1 | cut -f1)"
OUT1114="$("$GIT_HUNK" commit --dry-run "$SHA1114" -m "preview" 2>/dev/null)" \
    || fail "test 1114: binary dry-run should exit 0"
echo "$OUT1114" | grep -q "would commit" \
    || fail "test 1114: expected 'would commit' output, got: '$OUT1114'"
[[ "$(git rev-list --count HEAD)" -eq "$COMMITS1114" ]] \
    || fail "test 1114: dry-run created a commit"
[[ "$("$GIT_HUNK" count)" -eq "$HUNKS1114" ]] \
    || fail "test 1114: dry-run changed the hunk count"
pass "test 1114: binary-only dry-run previews without mutating"

report_results
