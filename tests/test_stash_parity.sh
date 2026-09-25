#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Stash parity with native git (tests 2200-2229). A `git hunk stash` of whole
# files must record the entry `git stash push --keep-index [-u] -- <paths>`
# records: HEAD as first parent, the real index as the index commit, the
# index plus the stashed changes as the stash tree, and the stashed untracked
# files as a third parent. Every git stash operation then treats it as it
# would the native entry. Each scenario is built once and copied, so both
# sides start from identical repositories; trees are compared by id within
# the same object format, never against a hardcoded id.
#
# A stash of some hunks and not others has no native equivalent; popping it
# must give back exactly the index and worktree it was taken from. Git never
# merges a stash into a file that still has unstaged changes, so where the
# stashed hunk's file keeps another, its pops are refused and must lose
# nothing, while git hunk stash pop merges the hunk back into the file.
# ============================================================================

# A repo with a.txt and b.txt (twenty lines each), d.txt (three lines) and a
# binary bin.dat committed, in $CURRENT_REPO/hunk.
parity_repo() {
    cleanup_repo
    CURRENT_REPO="$(mktemp -d)"
    mkdir "$CURRENT_REPO/hunk"
    cd "$CURRENT_REPO/hunk"
    git init -q
    git config user.email "test@git-hunk.test"
    git config user.name "git-hunk test"
    lines a 1 20 > a.txt
    lines b 1 20 > b.txt
    printf 'd1\nd2\nd3\n' > d.txt
    printf '\000\001bin\n' > bin.dat
    git add a.txt b.txt d.txt bin.dat
    git commit -q -m "base"
}

# lines <prefix> <from> <to>: one line per number, e.g. "a 07".
lines() {
    local i
    for ((i = $2; i <= $3; i++)); do printf '%s %02d\n' "$1" "$i"; done
}

# <file> with line <n> replaced by <text>.
edit_line() {
    local file="$1" n="$2" text="$3"
    awk -v n="$n" -v t="$text" 'NR == n { print t; next } { print }' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

# Everything a stash operation could change: index entries (with stages, so a
# conflict shows), status, every worktree file's bytes and the stash count.
repo_state() {
    git ls-files -s
    git status --porcelain --untracked-files=all
    local f
    for f in *; do [[ -f "$f" ]] && printf '%s: %s\n' "$f" "$(bytes_of "$f")"; done
    printf 'stash entries: %s\n' "$(git stash list | wc -l | tr -d ' ')"
    return 0
}

# The trees and parents of stash@{0}.
stash_trees() {
    printf 'parents: %s\n' "$(git rev-list --parents -1 stash | wc -w | tr -d ' ')"
    printf 'base: %s\n' "$(git rev-parse stash^1)"
    printf 'index tree: %s\n' "$(git rev-parse 'stash^2^{tree}')"
    printf 'stash tree: %s\n' "$(git rev-parse 'stash^{tree}')"
    printf 'untracked tree: %s\n' "$(git rev-parse -q --verify 'stash^3^{tree}' || echo none)"
}

# The messages of stash@{0}: what `git stash list` shows and each commit's subject.
stash_messages() {
    git stash list
    git log -1 --format='stash: %s' stash
    git log -1 --format='index: %s' stash^2
    git rev-parse -q --verify stash^3 > /dev/null && git log -1 --format='untracked: %s' stash^3
    return 0
}

# check_same <label> <what> <actual> <expected> [<expected from>]
check_same() {
    local from="${5:-native}"
    if [[ "$3" == "$4" ]]; then
        pass "$1: $2 same as $from"
        return
    fi
    fail "$1: $2 differs from $from"
    diff <(printf '%s\n' "$4") <(printf '%s\n' "$3") | sed 's/^/    /' >&2 || true
}

# stash_parity <label> <git-hunk stash args...> -- <git stash push args...>:
# from the scenario in $CURRENT_REPO/hunk, stash with git-hunk there and with
# `git stash push --keep-index <args>` in a copy, then compare the entries,
# the states they leave, and the outcome of every way to restore them.
stash_parity() {
    local label="$1"
    shift
    local hunk_args=()
    while [[ "$1" != "--" ]]; do hunk_args+=("$1"); shift; done
    shift

    local top="$CURRENT_REPO"
    cp -Rp "$top/hunk" "$top/native"

    cd "$top/hunk"
    "$GIT_HUNK" stash "${hunk_args[@]}" > /dev/null || fail "$label: git hunk stash ${hunk_args[*]} failed"
    # A pathspec naming an untracked file makes native keep-index report an
    # error after it has stored the entry and cleaned the file away, so the
    # entry is what is checked, not the exit status.
    (cd "$top/native" && git stash push -q --keep-index "$@" > /dev/null 2>&1) || true
    (cd "$top/native" && git rev-parse -q --verify stash > /dev/null) \
        || fail "$label: native git stash push --keep-index $* stored nothing"

    check_same "$label" "stash trees" "$(stash_trees)" "$(cd "$top/native" && stash_trees)"
    check_same "$label" "stash messages" "$(stash_messages)" "$(cd "$top/native" && stash_messages)"
    check_same "$label" "state after stashing" "$(repo_state)" "$(cd "$top/native" && repo_state)"

    local op side
    for op in "git stash pop" "git stash pop --index" "git stash apply --index" "$GIT_HUNK stash pop"; do
        for side in hunk native; do
            rm -rf "$top/op-$side"
            cp -Rp "$top/$side" "$top/op-$side"
            cd "$top/op-$side"
            local status=0
            $op > /dev/null 2>&1 || status=$?
            printf 'exit: %s\n%s\n' "$status" "$(repo_state)" > "$top/$side.out"
        done
        check_same "$label" "results of '${op/#"$GIT_HUNK"/git hunk}'" "$(cat "$top/hunk.out")" "$(cat "$top/native.out")"
    done
    cd "$top/hunk"
}

# pop_each <label> <expected state> <expected from> <expect-success|expect-refusal> [<op>...]:
# each way of popping the entry (every one when none is named) in a copy of
# $CURRENT_REPO/hunk, which must succeed or be refused as told and leave
# <expected state>.
pop_each() {
    local label="$1" want="$2" from="$3" outcome="$4"
    shift 4
    local ops=("$@")
    [[ ${#ops[@]} -gt 0 ]] || ops=("git stash pop" "git stash pop --index" "$GIT_HUNK stash pop")
    local top="$CURRENT_REPO"
    local op status
    for op in "${ops[@]}"; do
        rm -rf "$top/op"
        cp -Rp "$top/hunk" "$top/op"
        cd "$top/op"
        status=0
        $op > /dev/null 2>&1 || status=$?
        if [[ "$outcome" == expect-success && "$status" -ne 0 ]]; then
            fail "$label: '${op/#"$GIT_HUNK"/git hunk}' failed"
        elif [[ "$outcome" == expect-refusal && "$status" -eq 0 ]]; then
            fail "$label: '${op/#"$GIT_HUNK"/git hunk}' was not refused"
        else
            check_same "$label" "state after '${op/#"$GIT_HUNK"/git hunk}'" "$(repo_state)" "$want" "$from"
        fi
    done
    cd "$top/hunk"
}

# round_trip <label> <git-hunk stash args...>: stash, then each way of popping
# the entry must restore exactly the index and worktree it was taken from.
round_trip() {
    local label="$1"
    shift
    local before
    before="$(repo_state)"
    "$GIT_HUNK" stash "$@" > /dev/null || fail "$label: git hunk stash $* failed"
    [[ "$(repo_state)" != "$before" ]] || fail "$label: git hunk stash $* changed nothing"
    pop_each "$label" "$before" "the state before stashing" expect-success
}

# merge_round_trip <label> <git-hunk stash args...>: stash hunks whose files
# keep other changes, which git's pops refuse; git hunk stash pop must merge
# them back to exactly the index and worktree they were taken from.
merge_round_trip() {
    local label="$1"
    shift
    local before
    before="$(repo_state)"
    "$GIT_HUNK" stash "$@" > /dev/null || fail "$label: git hunk stash $* failed"
    [[ "$(repo_state)" != "$before" ]] || fail "$label: git hunk stash $* changed nothing"
    pop_each "$label" "$before" "the state before stashing" expect-success "$GIT_HUNK stash pop"
}

# The hash of the hunk of <file> whose new side starts at line <n>.
hunk_at() {
    "$GIT_HUNK" list --porcelain --oneline --file "$1" | awk -F'\t' -v n="$2" '$3 == n { print $1 }'
}

# ============================================================================
# Test 2200: a staged edit in another file
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
git add a.txt
edit_line b.txt 10 "b 10 stashed"
stash_parity "test 2200" --file b.txt -- -- b.txt

# ============================================================================
# Test 2201: a staged edit in the same file as the stashed one
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
git add a.txt
edit_line a.txt 18 "a 18 stashed"
stash_parity "test 2201" --file a.txt -- -- a.txt

# ============================================================================
# Test 2202: a staged new file
# ============================================================================
parity_repo
printf 'new\n' > new.txt
git add new.txt
edit_line b.txt 10 "b 10 stashed"
stash_parity "test 2202" --file b.txt -- -- b.txt

# ============================================================================
# Test 2203: an untracked file, beside a staged edit
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
git add a.txt
printf 'untracked\n' > u.txt
stash_parity "test 2203" "$(hunk_at u.txt 1)" -- -u -- u.txt

# ============================================================================
# Test 2204: a deletion, beside a staged edit
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
git add a.txt
rm d.txt
stash_parity "test 2204" --file d.txt -- -- d.txt

# ============================================================================
# Test 2205: a deletion of a file with a staged edit. Plain pop meets a
# modify/delete conflict, as it does for the native entry.
# ============================================================================
parity_repo
edit_line d.txt 2 "d2 staged"
git add d.txt
rm d.txt
stash_parity "test 2205" --file d.txt -- -- d.txt

# ============================================================================
# Test 2206: a binary change, beside a staged edit
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
git add a.txt
printf '\000\002bin changed\n' > bin.dat
stash_parity "test 2206" --file bin.dat -- -- bin.dat

# ============================================================================
# Test 2207: nothing staged, with a message
# ============================================================================
parity_repo
edit_line b.txt 10 "b 10 stashed"
stash_parity "test 2207" --file b.txt -m "parked b" -- -m "parked b" -- b.txt

# ============================================================================
# Test 2208: everything, untracked files included, over a staged edit and a
# staged new file
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
printf 'new\n' > new.txt
git add a.txt new.txt
edit_line a.txt 18 "a 18 stashed"
edit_line b.txt 10 "b 10 stashed"
printf '\000\002bin changed\n' > bin.dat
rm d.txt
printf 'untracked\n' > u.txt
stash_parity "test 2208" --all -u -- -u

# ============================================================================
# Test 2210: one of two hunks in a file with a staged edit elsewhere in it.
# The other hunk keeps the file dirty, so git refuses every pop, losing
# nothing; git hunk stash pop merges the hunk back into the file instead,
# restoring exactly the index and worktree it was taken from.
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
git add a.txt
edit_line a.txt 10 "a 10 kept"
edit_line a.txt 18 "a 18 stashed"
BEFORE2210="$(repo_state)"
"$GIT_HUNK" stash "$(hunk_at a.txt 15)" > /dev/null || fail "test 2210: git hunk stash failed"
[[ "$(git diff)" == *"a 10 kept"* && "$(git diff)" != *"a 18 stashed"* ]] \
    || fail "test 2210: the stash did not take out just the hunk at line 18"
pop_each "test 2210" "$(repo_state)" "the state before popping" expect-refusal "git stash pop" "git stash pop --index"
pop_each "test 2210" "$BEFORE2210" "the state before stashing" expect-success "$GIT_HUNK stash pop"

# ============================================================================
# Test 2211: a hunk in one file, beside a staged edit and a kept hunk in
# another, a staged new file and an untracked file that all stay
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
printf 'new\n' > new.txt
git add a.txt new.txt
edit_line a.txt 18 "a 18 kept"
edit_line b.txt 10 "b 10 stashed"
printf 'untracked\n' > u.txt
round_trip "test 2211" "$(hunk_at b.txt 7)"

# ============================================================================
# Test 2212: a hunk right next to a staged edit in the same file, where the
# HEAD-to-worktree diff runs the two together
# ============================================================================
parity_repo
edit_line a.txt 9 "a 09 staged"
git add a.txt
edit_line a.txt 11 "a 11 stashed"
round_trip "test 2212" "$(hunk_at a.txt 8)"

# ============================================================================
# Test 2213: a hunk between two staged edits in the same file
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
edit_line a.txt 18 "a 18 staged"
git add a.txt
edit_line a.txt 10 "a 10 stashed"
round_trip "test 2213" "$(hunk_at a.txt 7)"

# ============================================================================
# Test 2214: an index with a merge conflict has no tree to record, so the
# stash is refused, as native git refuses it, and nothing changes
# ============================================================================
parity_repo
git switch -q -c other
edit_line d.txt 2 "d2 other"
git commit -q -a -m "other"
git switch -q -
edit_line d.txt 2 "d2 main"
git commit -q -a -m "main"
git merge -q other > /dev/null 2>&1 && fail "test 2214: the merge did not conflict"
edit_line b.txt 10 "b 10 stashed"
BEFORE2214="$(repo_state)"
ERR2214="$("$GIT_HUNK" stash --file b.txt 2>&1 > /dev/null)" && fail "test 2214: stash with a conflicted index succeeded"
check_same "test 2214" "error" "$ERR2214" "error: cannot stash while the index has unmerged paths" "the expected error"
git stash push -q --keep-index -- b.txt > /dev/null 2>&1 && fail "test 2214: native stash with a conflicted index succeeded"
check_same "test 2214" "state after both refusals" "$(repo_state)" "$BEFORE2214" "the state before"


# ============================================================================
# Test 2215: a file edited again after stashing one of its hunks. git hunk
# stash pop merges the hunk into it, and a stashed deletion beside it goes
# back too; the index is left exactly as it was and the entry is dropped.
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
edit_line b.txt 3 "b 03 staged"
git add a.txt b.txt
edit_line a.txt 18 "a 18 stashed"
rm d.txt
"$GIT_HUNK" stash "$(hunk_at a.txt 15)" "$(first_sha --file d.txt)" > /dev/null || fail "test 2215: git hunk stash failed"
edit_line a.txt 5 "a 05 later"
INDEX2215="$(git ls-files -s)"
"$GIT_HUNK" stash pop > /dev/null 2>&1 || fail "test 2215: git hunk stash pop failed"
{ lines a 1 1; echo "a 02 staged"; lines a 3 4; echo "a 05 later"; lines a 6 17; echo "a 18 stashed"; lines a 19 20; } > "$CURRENT_REPO/want2215"
check_same "test 2215" "a.txt" "$(bytes_of a.txt)" "$(bytes_of "$CURRENT_REPO/want2215")" "the merged file"
[[ ! -e d.txt ]] || fail "test 2215: the stashed deletion of d.txt was not restored"
check_same "test 2215" "index" "$(git ls-files -s)" "$INDEX2215" "the index before popping"
[[ -z "$(git stash list)" ]] || fail "test 2215: the entry was not dropped"

# ============================================================================
# Test 2216: the hunk conflicts with a later edit of the same line. Git's
# markers and unmerged entries are left for the path, a path that merged
# cleanly is restored unstaged, and the entry is kept.
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
git add a.txt
edit_line a.txt 10 "a 10 kept"
edit_line a.txt 18 "a 18 stashed"
edit_line b.txt 10 "b 10 stashed"
"$GIT_HUNK" stash "$(hunk_at a.txt 15)" "$(hunk_at b.txt 7)" > /dev/null || fail "test 2216: git hunk stash failed"
STASH2216="$(git rev-parse stash)"
edit_line a.txt 18 "a 18 later"
OURS2216="$(git hash-object a.txt)"
STATUS=0
ERR2216="$("$GIT_HUNK" stash pop 2>&1 > /dev/null)" || STATUS=$?
[[ "$STATUS" -eq 1 ]] || fail "test 2216: expected exit 1, got $STATUS"
check_same "test 2216" "report" "$ERR2216" "$(printf 'CONFLICT (content): Merge conflict in a.txt\nThe stash entry is kept in case you need it again.')" "git's report"
{ lines a 1 1; echo "a 02 staged"; lines a 3 9; echo "a 10 kept"; lines a 11 17
  printf '%s\n' "<<<<<<< Updated upstream" "a 18 later" "=======" "a 18 stashed" ">>>>>>> Stashed changes"
  lines a 19 20; } > "$CURRENT_REPO/want2216"
check_same "test 2216" "a.txt" "$(bytes_of a.txt)" "$(bytes_of "$CURRENT_REPO/want2216")" "git's conflict markers"
check_same "test 2216" "a.txt's index stages" "$(git ls-files -s a.txt | awk '{ print $2, $3 }')" \
    "$(printf '%s 1\n%s 2\n%s 3' "$(git rev-parse "$STASH2216^2:a.txt")" "$OURS2216" "$(git rev-parse "$STASH2216:a.txt")")" "base, worktree and stash"
[[ "$(git diff b.txt)" == *"+b 10 stashed"* && -z "$(git diff --cached b.txt)" ]] \
    || fail "test 2216: b.txt should have its hunk back, unstaged"
[[ "$(git rev-parse -q --verify stash)" == "$STASH2216" ]] || fail "test 2216: the entry was not kept"

# ============================================================================
# Test 2217: untracked files come back with a merged hunk; an untracked file
# already in the way refuses the pop before anything changes, whether the
# pop would merge or leave the work to git
# ============================================================================
parity_repo
edit_line a.txt 10 "a 10 kept"
edit_line a.txt 18 "a 18 stashed"
printf 'untracked\n' > u.txt
merge_round_trip "test 2217" "$(hunk_at a.txt 15)" "$(hunk_at u.txt 1)"

for kept in yes no; do
    parity_repo
    [[ "$kept" == yes ]] && edit_line a.txt 10 "a 10 kept"
    edit_line a.txt 18 "a 18 stashed"
    printf 'untracked\n' > u.txt
    "$GIT_HUNK" stash "$(hunk_at a.txt 15)" "$(hunk_at u.txt 1)" > /dev/null || fail "test 2217: git hunk stash failed"
    printf 'in the way\n' > u.txt
    BEFORE2217="$(repo_state)"
    STATUS=0
    ERR2217="$("$GIT_HUNK" stash pop 2>&1 > /dev/null)" || STATUS=$?
    [[ "$STATUS" -eq 1 ]] || fail "test 2217 (kept hunk: $kept): expected exit 1, got $STATUS"
    check_same "test 2217 (kept hunk: $kept)" "report" "$ERR2217" \
        "$(printf 'u.txt already exists, no checkout\nerror: could not restore untracked files from stash\nThe stash entry is kept in case you need it again.')" "git's report"
    check_same "test 2217 (kept hunk: $kept)" "state after the refusal" "$(repo_state)" "$BEFORE2217" "the state before"
done

# ============================================================================
# Test 2218: a binary file goes back whole beside a merged hunk; a binary
# changed since conflicts, as git cannot merge it, and keeps its new content
# ============================================================================
parity_repo
edit_line a.txt 10 "a 10 kept"
edit_line a.txt 18 "a 18 stashed"
printf '\000\002bin changed\n' > bin.dat
merge_round_trip "test 2218" "$(hunk_at a.txt 15)" "$(first_sha --file bin.dat)"

parity_repo
edit_line a.txt 10 "a 10 kept"
edit_line a.txt 18 "a 18 stashed"
printf '\000\002bin changed\n' > bin.dat
"$GIT_HUNK" stash "$(hunk_at a.txt 15)" "$(first_sha --file bin.dat)" > /dev/null || fail "test 2218: git hunk stash failed"
printf '\000\003bin later\n' > bin.dat
STATUS=0
ERR2218="$("$GIT_HUNK" stash pop 2>&1 > /dev/null)" || STATUS=$?
[[ "$STATUS" -eq 1 ]] || fail "test 2218: expected exit 1, got $STATUS"
check_same "test 2218" "report" "$ERR2218" \
    "$(printf 'warning: Cannot merge binary files: bin.dat (Updated upstream vs. Stashed changes)\nCONFLICT (content): Merge conflict in bin.dat\nThe stash entry is kept in case you need it again.')" "git's report"
check_same "test 2218" "bin.dat" "$(bytes_of bin.dat)" "$(want_bytes '\000\003bin later\n')" "its content before popping"
[[ "$(git diff a.txt)" == *"+a 18 stashed"* ]] || fail "test 2218: a.txt's hunk did not go back"
[[ "$(git stash list | wc -l | tr -d ' ')" == 1 ]] || fail "test 2218: the entry was not kept"

# ============================================================================
# Test 2219: where git's pop succeeds, git hunk stash pop leaves what
# `git stash pop --index` leaves
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
printf 'new\n' > new.txt
git add a.txt new.txt
edit_line a.txt 18 "a 18 stashed"
edit_line b.txt 10 "b 10 stashed"
rm d.txt
printf 'untracked\n' > u.txt
"$GIT_HUNK" stash --all -u > /dev/null || fail "test 2219: git hunk stash failed"
for op in "git stash pop --index" "$GIT_HUNK stash pop"; do
    rm -rf "$CURRENT_REPO/op"
    cp -Rp "$CURRENT_REPO/hunk" "$CURRENT_REPO/op"
    STATUS=0
    (cd "$CURRENT_REPO/op" && $op > /dev/null 2>&1) || STATUS=$?
    printf 'exit: %s\n%s\n' "$STATUS" "$(cd "$CURRENT_REPO/op" && repo_state)" > "$CURRENT_REPO/${op##* }.out"
done
check_same "test 2219" "results of 'git hunk stash pop'" "$(cat "$CURRENT_REPO/pop.out")" "$(cat "$CURRENT_REPO/--index.out")" "git stash pop --index"
grep -q '^exit: 0$' "$CURRENT_REPO/pop.out" || fail "test 2219: git hunk stash pop failed"

# ============================================================================
# Test 2220: a conflict in a pop git makes itself is reported as git
# reports it
# ============================================================================
parity_repo
edit_line b.txt 10 "b 10 stashed"
"$GIT_HUNK" stash --file b.txt > /dev/null || fail "test 2220: git hunk stash failed"
edit_line b.txt 10 "b 10 staged since"
git add b.txt
STATUS=0
ERR2220="$("$GIT_HUNK" stash pop 2>&1 > /dev/null)" || STATUS=$?
[[ "$STATUS" -eq 1 ]] || fail "test 2220: expected exit 1, got $STATUS"
[[ "$ERR2220" == *"CONFLICT (content): Merge conflict in b.txt"* ]] || fail "test 2220: no conflict reported, got '$ERR2220'"
[[ "$ERR2220" == *"The stash entry is kept in case you need it again."* ]] || fail "test 2220: not told the entry was kept, got '$ERR2220'"

# ============================================================================
# Test 2221: an entry `git stash push` made without --keep-index took a
# staged edit out of the index and the worktree. Merging only its worktree
# changes into the file edited since would lose the edit, so the pop is
# refused, as git's is, and nothing is lost.
# ============================================================================
parity_repo
edit_line a.txt 2 "a 02 staged"
git add a.txt
edit_line a.txt 18 "a 18 stashed"
git stash push -q
edit_line a.txt 10 "a 10 later"
BEFORE2221="$(repo_state)"
"$GIT_HUNK" stash pop > /dev/null 2>&1 && fail "test 2221: git hunk stash pop was not refused"
check_same "test 2221" "state after the refusal" "$(repo_state)" "$BEFORE2221" "the state before"

report_results
