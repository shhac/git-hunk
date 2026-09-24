#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Line specs on whole-file hunks (tests 2100-2112). A line spec picks part of
# a new or deleted file; the patch applied must then describe what is left:
# lines the spec leaves behind keep the file in existence, so a partial
# creation undone or a partial deletion applied is a change to an existing
# file, never the removal of the whole of it. Every command is checked by the
# bytes it leaves in the index, the worktree or the commit.
# ============================================================================

# A repo with d.txt (four lines) committed and n.txt (three lines) untracked.
whole_file_repo() {
    cleanup_repo
    CURRENT_REPO="$(mktemp -d)"
    cd "$CURRENT_REPO"
    git init -q
    git config user.email "test@git-hunk.test"
    git config user.name "git-hunk test"
    printf 'one\ntwo\nthree\nfour\n' > d.txt
    git add d.txt
    git commit -q -m "add d.txt"
    printf 'a\nb\nc\n' > n.txt
}

# Everything a command could change: the index entries, the worktree bytes
# and the commit HEAD points at.
repo_state() {
    git ls-files -s
    git status --porcelain --untracked-files=all
    git rev-parse HEAD
    local f
    for f in *; do [[ -e "$f" ]] && printf '%s: %s\n' "$f" "$(bytes_of "$f")"; done
    return 0
}

# The hash of the one hunk `list <args>` shows for <path>.
sha_for() {
    local path="$1"
    shift
    "$GIT_HUNK" list --porcelain --oneline "$@" | awk -F'\t' -v p="$path" '$2 == p { print $1 }'
}

# run_both <label> <git-hunk args>: the command with --dry-run must succeed
# and change nothing; then the real command must succeed.
run_both() {
    local label="$1"
    shift
    local before after
    before="$(repo_state)"
    "$GIT_HUNK" "$@" --dry-run > /dev/null || fail "$label: git-hunk $* --dry-run failed"
    after="$(repo_state)"
    [[ "$before" == "$after" ]] || fail "$label: git-hunk $* --dry-run changed the repo"
    "$GIT_HUNK" "$@" > /dev/null 2>&1 || fail "$label: git-hunk $* failed"
}

# ============================================================================
# Test 2100: add a line of an untracked file stages a new file of that line
# ============================================================================
whole_file_repo
SHA="$(sha_for n.txt)"
run_both "test 2100" add "$SHA:2"
[[ "$(blob_bytes :n.txt)" == "$(want_bytes 'b\n')" ]] \
    || fail "test 2100: index n.txt is $(blob_bytes :n.txt), want 'b\\n'"
[[ "$(bytes_of n.txt)" == "$(want_bytes 'a\nb\nc\n')" ]] || fail "test 2100: worktree n.txt changed"
[[ "$(git status --porcelain n.txt)" == "AM n.txt" ]] \
    || fail "test 2100: status is '$(git status --porcelain n.txt)', want 'AM n.txt'"
pass "test 2100: add <new-file>:<line> stages a new file holding just that line"

# ============================================================================
# Test 2101: reset a line of a staged new file leaves the other lines staged
# ============================================================================
whole_file_repo
git add n.txt
SHA="$(sha_for n.txt --staged)"
run_both "test 2101" reset "$SHA:2"
[[ "$(blob_bytes :n.txt)" == "$(want_bytes 'a\nc\n')" ]] \
    || fail "test 2101: index n.txt is $(blob_bytes :n.txt), want 'a\\nc\\n'"
[[ "$(bytes_of n.txt)" == "$(want_bytes 'a\nb\nc\n')" ]] || fail "test 2101: worktree n.txt changed"
pass "test 2101: reset <staged-new-file>:<line> keeps the deselected lines staged"

# ============================================================================
# Test 2102: restore --force a line of an untracked file keeps the file
# ============================================================================
whole_file_repo
SHA="$(sha_for n.txt)"
run_both "test 2102" restore --force "$SHA:2"
[[ -f n.txt ]] || fail "test 2102: n.txt was deleted"
[[ "$(bytes_of n.txt)" == "$(want_bytes 'a\nc\n')" ]] \
    || fail "test 2102: n.txt is $(bytes_of n.txt), want 'a\\nc\\n'"
[[ -z "$(git ls-files n.txt)" ]] || fail "test 2102: n.txt became tracked"
pass "test 2102: restore --force <untracked>:<line> removes only that line"

# ============================================================================
# Test 2103: add a line of a worktree deletion keeps the rest in the index
# ============================================================================
whole_file_repo
rm d.txt
SHA="$(sha_for d.txt)"
run_both "test 2103" add "$SHA:2"
[[ "$(blob_bytes :d.txt)" == "$(want_bytes 'one\nthree\nfour\n')" ]] \
    || fail "test 2103: index d.txt is $(blob_bytes :d.txt), want the file without 'two'"
[[ ! -e d.txt ]] || fail "test 2103: d.txt came back to the worktree"
pass "test 2103: add <deletion>:<line> removes only that line from the index"

# ============================================================================
# Test 2104: reset a line of a staged deletion puts back only that line
# ============================================================================
whole_file_repo
git rm -q d.txt
SHA="$(sha_for d.txt --staged)"
run_both "test 2104" reset "$SHA:2"
[[ "$(blob_bytes :d.txt)" == "$(want_bytes 'two\n')" ]] \
    || fail "test 2104: index d.txt is $(blob_bytes :d.txt), want 'two\\n'"
[[ ! -e d.txt ]] || fail "test 2104: d.txt came back to the worktree"
pass "test 2104: reset <staged-deletion>:<line> puts just that line back in the index"

# ============================================================================
# Test 2105: restore a line of a worktree deletion brings back only that line
# ============================================================================
whole_file_repo
rm d.txt
SHA="$(sha_for d.txt)"
run_both "test 2105" restore "$SHA:2"
[[ "$(bytes_of d.txt)" == "$(want_bytes 'two\n')" ]] \
    || fail "test 2105: d.txt is $(bytes_of d.txt), want 'two\\n'"
[[ "$(blob_bytes :d.txt)" == "$(want_bytes 'one\ntwo\nthree\nfour\n')" ]] || fail "test 2105: index d.txt changed"
pass "test 2105: restore <deletion>:<line> brings back just that line"

# ============================================================================
# Test 2106: commit a line of an untracked file commits a new file of it
# ============================================================================
whole_file_repo
SHA="$(sha_for n.txt)"
run_both "test 2106" commit "$SHA:2" -m "part of n.txt"
[[ "$(blob_bytes HEAD:n.txt)" == "$(want_bytes 'b\n')" ]] \
    || fail "test 2106: committed n.txt is $(blob_bytes HEAD:n.txt), want 'b\\n'"
[[ "$(bytes_of n.txt)" == "$(want_bytes 'a\nb\nc\n')" ]] || fail "test 2106: worktree n.txt changed"
pass "test 2106: commit <new-file>:<line> commits a file holding just that line"

# ============================================================================
# Test 2107: commit a line of a deletion keeps the rest of the file committed
# ============================================================================
whole_file_repo
rm d.txt
SHA="$(sha_for d.txt)"
run_both "test 2107" commit "$SHA:2" -m "drop a line of d.txt"
[[ "$(blob_bytes HEAD:d.txt)" == "$(want_bytes 'one\nthree\nfour\n')" ]] \
    || fail "test 2107: committed d.txt is $(blob_bytes HEAD:d.txt), want the file without 'two'"
[[ ! -e d.txt ]] || fail "test 2107: d.txt came back to the worktree"
pass "test 2107: commit <deletion>:<line> commits the file without that line"

# ============================================================================
# Test 2108: selecting every removal of a shrinking file empties it, and it
# stays tracked
# ============================================================================
whole_file_repo
git add n.txt
git commit -q -m "add n.txt"
printf 'x\n' > n.txt
SHA="$(sha_for n.txt)"
run_both "test 2108" add "$SHA:1-3"
[[ "$(git cat-file -s :n.txt)" == "0" ]] || fail "test 2108: index n.txt is $(blob_bytes :n.txt), want empty"
[[ -n "$(git ls-files n.txt)" ]] || fail "test 2108: n.txt is no longer tracked"
[[ "$(git diff --cached --name-status)" == "$(printf 'M\tn.txt')" ]] \
    || fail "test 2108: staged change is '$(git diff --cached --name-status)', want a modification"
pass "test 2108: add <sha>:<all removals> leaves a tracked empty file"

# ============================================================================
# Test 2109: a partial deletion from --ref keeps its index line, so --3way can
# merge it into an index that has drifted from the commit's parent
# ============================================================================
whole_file_repo
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > d.txt
git commit -q -am "grow d.txt"
git rm -q d.txt
git commit -q -m "X: delete d.txt"
git tag X
printf 'one\ntwo\nthree\nfour\nfive\nSIX\n' > d.txt
git add d.txt
SHA="$(sha_for d.txt --ref X)"
BEFORE="$(repo_state)"
"$GIT_HUNK" add --ref X "$SHA:1-2" > /dev/null 2>&1 && fail "test 2109: the drifted patch applied without --3way"
[[ "$(repo_state)" == "$BEFORE" ]] || fail "test 2109: the failed add changed the repo"
"$GIT_HUNK" add --ref X --3way "$SHA:1-2" > /dev/null || fail "test 2109: add --ref X --3way failed"
[[ "$(blob_bytes :d.txt)" == "$(want_bytes 'three\nfour\nfive\nSIX\n')" ]] \
    || fail "test 2109: index d.txt is $(blob_bytes :d.txt), want lines 3-6 with the drift kept"
pass "test 2109: add --ref X --3way <deletion>:<lines> merges over a drifted index"

# ============================================================================
# Test 2110: stash a worktree deletion of a file that has a staged edit
# ============================================================================
whole_file_repo
printf 'one\nTWO\nthree\nfour\n' > d.txt
git add d.txt
rm d.txt
SHA="$(sha_for d.txt)"
"$GIT_HUNK" stash "$SHA" > /dev/null || fail "test 2110: stash failed"
[[ "$(bytes_of d.txt)" == "$(want_bytes 'one\nTWO\nthree\nfour\n')" ]] \
    || fail "test 2110: d.txt is $(bytes_of d.txt), want the staged version back"
[[ "$(blob_bytes :d.txt)" == "$(want_bytes 'one\nTWO\nthree\nfour\n')" ]] || fail "test 2110: the staged edit was lost"
git cat-file -e 'stash@{0}:d.txt' 2> /dev/null && fail "test 2110: the stash still has d.txt"
pass "test 2110: stash of a deletion over a staged edit keeps the edit staged"

report_results
