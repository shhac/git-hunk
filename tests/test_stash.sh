#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 700: basic stash push by SHA
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
ORIG_ALPHA="$(git show HEAD:alpha.txt | head -1)"

SHA700="$(first_sha --oneline --file alpha.txt)"
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

SHA701="$(first_sha --oneline --file alpha.txt)"
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

SHA705="$(first_sha --oneline --file alpha.txt)"
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

SHA710="$(first_sha --oneline --file alpha.txt)"
if "$GIT_HUNK" stash "${SHA710}:1-3" > /dev/null 2>/dev/null; then
    fail "test 710: expected exit 1 for line spec"
fi
pass "test 710: line spec rejection"

# ============================================================================
# Test 711: stash untracked file by hash
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA711="$(first_sha --oneline --file untracked.txt)"
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

SHA714="$(first_sha --oneline --file untracked.txt)"
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

HASH=$(first_sha --oneline)
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

SHA720="$(first_sha --oneline --file untracked.txt)"
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

SHA721="$(first_sha --oneline --file beta.txt)"
[[ -n "$SHA721" ]] || fail "test 721: no unstaged hunk found for beta.txt"
"$GIT_HUNK" stash "$SHA721" > /dev/null

# Like a `git stash push --keep-index` entry, the stash tree is the index plus
# the stashed changes, so what the stash adds over its index commit is beta.txt
# alone; `git stash show` (against HEAD) lists the staged alpha.txt too.
STASHED721="$(git diff --name-only 'stash^2' stash)"
[[ "$STASHED721" == "beta.txt" ]] \
    || fail "test 721: stash should add only beta.txt over its index, got: '$STASHED721'"

STAGED721="$(git diff --cached --name-only)"
echo "$STAGED721" | grep -q "alpha.txt" \
    || fail "test 721: alpha.txt should still be staged after stashing beta.txt"
pass "test 721: stash preserves staged index, only stashes the specified hunk"

# ============================================================================
# Test 722: stash --file a --file c stashes union of files (multi-file filter)
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
sed -i.bak '1s/.*/Changed gamma./' gamma.txt
"$GIT_HUNK" stash --file alpha.txt --file gamma.txt > /dev/null 2>/dev/null
WT722="$(git diff --name-only)"
echo "$WT722" | grep -q "beta.txt" || fail "test 722: beta.txt should remain modified"
echo "$WT722" | grep -q "alpha.txt" && fail "test 722: alpha.txt should have been stashed" || true
echo "$WT722" | grep -q "gamma.txt" && fail "test 722: gamma.txt should have been stashed" || true
"$GIT_HUNK" stash pop > /dev/null 2>/dev/null
WT722_POPPED="$(git diff --name-only)"
echo "$WT722_POPPED" | grep -q "alpha.txt" || fail "test 722: alpha.txt should be restored after pop"
echo "$WT722_POPPED" | grep -q "gamma.txt" || fail "test 722: gamma.txt should be restored after pop"
pass "test 722: stash --file a --file c stashes union, restores after pop"

# ============================================================================
# Test 723: stash mixed binary + text in --all preserves both after pop (T3)
# ============================================================================
new_repo
sed -i.bak '1s/.*/Mixed test./' alpha.txt
printf '\x00\x01\x02BIN' > binfile.bin
git add binfile.bin > /dev/null 2>&1
git commit -q -m "add binfile" > /dev/null 2>&1
printf '\x00\x01\x02BINMODIFIED' > binfile.bin

"$GIT_HUNK" stash --all > /dev/null 2>/dev/null

# Both should be removed from worktree by stash
[[ "$(cat alpha.txt | head -1)" != "Mixed test." ]] \
    || fail "test 723: alpha.txt change should be stashed away"
[[ "$(cat binfile.bin)" != *"MODIFIED"* ]] \
    || fail "test 723: binfile.bin change should be stashed away"

"$GIT_HUNK" stash pop > /dev/null 2>/dev/null

# Both should be restored
[[ "$(head -1 alpha.txt)" == "Mixed test." ]] \
    || fail "test 723: alpha.txt should be restored after pop"
grep -q "MODIFIED" binfile.bin \
    || fail "test 723: binfile.bin should be restored with MODIFIED contents after pop"
pass "test 723: stash --all with mixed text + binary survives a pop round-trip"

# ============================================================================
# Test 724: a stash whose worktree cleanup fails says so and exits 1. The
# entry is already stored, so the changes are in both places; that used to
# be only a warning with exit 0.
# ============================================================================
SHIM_DIR724="$(mktemp -d)"
cp "$SCRIPT_DIR/git-shim.sh" "$SHIM_DIR724/git"
chmod +x "$SHIM_DIR724/git"
new_repo
sed -i.bak '3s/.*/stashed but kept 724/' alpha.txt
SHA724="$(first_sha --file alpha.txt)"
echo 0 > "$SHIM_DIR724/count"
# The first `git apply` builds the stash tree; the second is the cleanup.
EC724=0
ERR724="$(PATH="$SHIM_DIR724:$PATH" GIT_HUNK_SHIM_FAIL=apply GIT_HUNK_SHIM_FAIL_ON=2 \
    GIT_HUNK_SHIM_COUNT_FILE="$SHIM_DIR724/count" "$GIT_HUNK" stash "$SHA724" 2>&1)" || EC724=$?
rm -rf "$SHIM_DIR724"
[[ "$EC724" -eq 1 ]] || fail "test 724: stash with a failed cleanup should exit 1, got $EC724"
echo "$ERR724" | grep -q "^error: cannot remove the stashed changes from the worktree$" \
    || fail "test 724: should say the worktree still has the changes, got: '$ERR724'"
echo "$ERR724" | grep -q "saved in stash@{0}" \
    || fail "test 724: should say the entry was stored, got: '$ERR724'"
[[ "$(git stash list | wc -l | tr -d ' ')" == "1" ]] || fail "test 724: the stash entry should be stored"
[[ "$(sed -n 3p alpha.txt)" == "stashed but kept 724" ]] || fail "test 724: the worktree should still have the change"
pass "test 724: a failed stash cleanup is an error that says where the changes are"


# ============================================================================
# Tests 725-727: an intent-to-add entry (`git add -N`) is refused, as
# `git stash` refuses it, and the refusal changes nothing. Stashing one used
# to take the file out of the worktree and leave the entry naming it, so the
# file showed as deleted.
# ============================================================================
# Index entries, worktree state, file contents and stash list, for comparing
# before and after a refused stash.
stash_state() {
    git ls-files -s --debug
    git status --porcelain=v2 --untracked-files=all
    git stash list
    cat -- "$@"
}

new_repo
sed -i.bak '3s/.*/kept 725/' alpha.txt
printf 'intent to add 725\n' > ita.txt
git add -N ita.txt
BEFORE725="$(stash_state alpha.txt ita.txt)"
EC725=0
ERR725="$("$GIT_HUNK" stash --all 2>&1)" || EC725=$?
[[ "$EC725" -eq 1 ]] || fail "test 725: stash --all with an intent-to-add file should exit 1, got $EC725"
echo "$ERR725" | grep -q "^error: cannot stash intent-to-add entry 'ita.txt'$" \
    || fail "test 725: should name the intent-to-add entry, got: '$ERR725'"
echo "$ERR725" | grep -q "^hint: stage it with 'git add'" \
    || fail "test 725: should hint how to proceed, got: '$ERR725'"
[[ "$(stash_state alpha.txt ita.txt)" == "$BEFORE725" ]] \
    || fail "test 725: a refused stash should change nothing"
EC725=0
ERR725="$("$GIT_HUNK" stash "$(first_sha --file ita.txt)" 2>&1)" || EC725=$?
[[ "$EC725" -eq 1 ]] || fail "test 725: stashing the entry's hunk by hash should exit 1, got $EC725"
[[ "$(stash_state alpha.txt ita.txt)" == "$BEFORE725" ]] \
    || fail "test 725: a refused stash by hash should change nothing"
pass "test 725: stash refuses an intent-to-add entry and changes nothing"

new_repo
sed -i.bak '3s/.*/stashed 726/' alpha.txt
printf 'intent to add 726\n' > ita.txt
git add -N ita.txt
BEFORE726="$(stash_state alpha.txt ita.txt)"
EC726=0
ERR726="$("$GIT_HUNK" stash --file ita.txt 2>&1)" || EC726=$?
[[ "$EC726" -eq 1 ]] || fail "test 726: stash --file of an intent-to-add file should exit 1, got $EC726"
echo "$ERR726" | grep -q "^error: cannot stash intent-to-add entry 'ita.txt'$" \
    || fail "test 726: should name the intent-to-add entry, got: '$ERR726'"
[[ "$(stash_state alpha.txt ita.txt)" == "$BEFORE726" ]] \
    || fail "test 726: a refused --file stash should change nothing"
# Only the paths being stashed matter: the entry stays as it is while another
# file's hunks are stashed.
"$GIT_HUNK" stash --file alpha.txt > /dev/null 2>&1 \
    || fail "test 726: stash --file of another file should succeed"
[[ "$(git stash list | wc -l | tr -d ' ')" == "1" ]] || fail "test 726: the other file should be stashed"
[[ "$(sed -n 3p alpha.txt)" != "stashed 726" ]] || fail "test 726: alpha.txt should be clean after its stash"
[[ "$(git status --porcelain -- ita.txt)" == " A ita.txt" ]] \
    || fail "test 726: the intent-to-add entry should be untouched, got '$(git status --porcelain -- ita.txt)'"
pass "test 726: stash --file refuses an intent-to-add file but stashes others"

new_repo
mv alpha.txt moved.txt
printf 'moved 727\n' >> moved.txt
git add -N moved.txt
BEFORE727="$(stash_state moved.txt)"
EC727=0
ERR727="$("$GIT_HUNK" stash --file moved.txt 2>&1)" || EC727=$?
[[ "$EC727" -eq 1 ]] || fail "test 727: stash of a rename's intent-to-add new side should exit 1, got $EC727"
echo "$ERR727" | grep -q "^error: cannot stash intent-to-add entry 'moved.txt'$" \
    || fail "test 727: should name the rename's new side, got: '$ERR727'"
[[ "$(stash_state moved.txt)" == "$BEFORE727" ]] \
    || fail "test 727: a refused rename stash should change nothing"
EC727=0
"$GIT_HUNK" stash --all > /dev/null 2>&1 || EC727=$?
[[ "$EC727" -eq 1 ]] || fail "test 727: stash --all with the rename should exit 1, got $EC727"
[[ "$(stash_state moved.txt)" == "$BEFORE727" ]] \
    || fail "test 727: a refused stash --all should change nothing"
pass "test 727: stash refuses a rename whose new side is intent-to-add"

report_results
