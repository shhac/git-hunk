#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# A conflicted path has an index entry per side of the merge and no staged
# version, so it has no hunks. Every command that passes over one says so and
# how to resolve it, instead of reading as if there were nothing there.

# conflict_repo: a merge stopped on two conflicts, alpha.txt changed on both
# sides (UU) and gamma.txt changed here but deleted there (UD), with an
# unrelated unstaged edit to beta.txt.
conflict_repo() {
    new_repo
    git switch -q -c other
    sed -i.bak '1s/.*/Alpha from other./' alpha.txt
    git rm -q gamma.txt
    git commit -q -a -m "other"
    git switch -q -
    sed -i.bak '1s/.*/Alpha from main./' alpha.txt
    sed -i.bak '1s/.*/Gamma from main./' gamma.txt
    git commit -q -a -m "main"
    git merge -q other > /dev/null 2>&1 && fail "conflict_repo: the merge did not conflict"
    sed -i.bak '1s/.*/Beta edited./' beta.txt
}

HINT_ANY="hint: a conflicted file has no hunks; resolve the conflict, then mark it resolved with 'git add <path>' (or 'git rm <path>' to delete it)"
HINT_ALPHA_RESTORE="hint: a conflicted file has no hunks; 'git checkout --merge -- alpha.txt' recreates its conflict markers, or 'git checkout --ours -- alpha.txt' (or --theirs) takes one side"
HINT_ALPHA="hint: a conflicted file has no hunks; resolve the conflict, then mark it resolved with 'git add alpha.txt' (or 'git rm alpha.txt' to delete it)"

# Everything a refusal must leave as it was: the index stages, the worktree,
# HEAD, any merge in progress and the stash list.
repo_state() {
    git status --porcelain=v1
    git ls-files -s
    git diff
    git rev-parse HEAD
    git rev-parse -q --verify MERGE_HEAD || true
    git stash list
}

# ============================================================================
# Test 2300: list names each conflicted path after the hunks, on stderr
# ============================================================================
conflict_repo
OUT2300="$("$GIT_HUNK" list --oneline 2>/dev/null)"
ERR2300="$("$GIT_HUNK" list --oneline 2>&1 >/dev/null)"
[[ "$(echo "$OUT2300" | wc -l | tr -d ' ')" == "1" && "$OUT2300" == *beta.txt* ]] \
    || fail "test 2300: stdout should list beta.txt's hunk alone, got: '$OUT2300'"
WANT2300="note: alpha.txt: unresolved merge conflict — not listed
note: gamma.txt: unresolved merge conflict — not listed
$HINT_ANY"
[[ "$ERR2300" == "$WANT2300" ]] || fail "test 2300: stderr was: '$ERR2300'"
pass "test 2300: list names each conflicted path after the hunks"

# ============================================================================
# Test 2301: --porcelain stdout is unchanged; the notes stay on stderr
# ============================================================================
OUT2301="$("$GIT_HUNK" list --porcelain 2>/dev/null)"
echo "$OUT2301" | grep -q "alpha.txt" && fail "test 2301: porcelain stdout mentions alpha.txt"
"$GIT_HUNK" list --porcelain 2>&1 >/dev/null | grep -q "^note: alpha.txt: unresolved merge conflict" \
    || fail "test 2301: porcelain run should still note alpha.txt on stderr"
pass "test 2301: porcelain stdout carries no conflict records"

# ============================================================================
# Test 2302: --staged notes them too (git diff --cached only says "Unmerged path")
# ============================================================================
ERR2302="$("$GIT_HUNK" list --staged 2>&1 >/dev/null)"
[[ "$ERR2302" == *"note: alpha.txt: unresolved merge conflict — not listed"* ]] \
    || fail "test 2302: list --staged stderr was: '$ERR2302'"
pass "test 2302: list --staged notes conflicted paths"

# ============================================================================
# Test 2303: --file scopes the notes, and names the path in the hint
# ============================================================================
ERR2303="$("$GIT_HUNK" list --file alpha.txt 2>&1 >/dev/null)" || fail "test 2303: list --file of a conflicted path should exit 0"
WANT2303="note: alpha.txt: unresolved merge conflict — not listed
$HINT_ALPHA"
[[ "$ERR2303" == "$WANT2303" ]] || fail "test 2303: stderr was: '$ERR2303'"
ERR2303B="$("$GIT_HUNK" list --file beta.txt 2>&1 >/dev/null)"
[[ -z "$ERR2303B" ]] || fail "test 2303: --file beta.txt should note nothing, got: '$ERR2303B'"
pass "test 2303: --file scopes the conflict notes"

# ============================================================================
# Test 2304: count notes them; -q silences the notes as it does the count
# ============================================================================
OUT2304="$("$GIT_HUNK" count 2>/dev/null)"
[[ "$OUT2304" == "1" ]] || fail "test 2304: count should be 1, got '$OUT2304'"
"$GIT_HUNK" count 2>&1 >/dev/null | grep -q "^note: alpha.txt: unresolved merge conflict — not counted$" \
    || fail "test 2304: count should note alpha.txt"
ERR2304Q="$("$GIT_HUNK" count -q 2>&1)"
[[ -z "$ERR2304Q" ]] || fail "test 2304: count -q should print nothing, got: '$ERR2304Q'"
pass "test 2304: count notes conflicted paths, -q silences them"

# ============================================================================
# Test 2305: history and untracked-only listings have no conflicted paths
# ============================================================================
ERR2305="$("$GIT_HUNK" list --ref HEAD 2>&1 >/dev/null)"
[[ -z "$ERR2305" ]] || fail "test 2305: list --ref HEAD should note nothing, got: '$ERR2305'"
ERR2305U="$("$GIT_HUNK" list --untracked-only 2>&1 >/dev/null)"
[[ -z "$ERR2305U" ]] || fail "test 2305: list --untracked-only should note nothing, got: '$ERR2305U'"
pass "test 2305: --ref and --untracked-only note nothing"

# ============================================================================
# Test 2306: from a subdirectory, a conflict elsewhere in the repo is noted
# ============================================================================
mkdir -p sub
ERR2306="$(cd sub && "$GIT_HUNK" list 2>&1 >/dev/null)"
[[ "$ERR2306" == *"note: alpha.txt: unresolved merge conflict — not listed"* ]] \
    || fail "test 2306: list from sub/ stderr was: '$ERR2306'"
pass "test 2306: list from a subdirectory notes repo-wide conflicts"

# ============================================================================
# Test 2307: once resolved with git add, the path is an ordinary staged change
# ============================================================================
grep -vE '^(<<<<<<<|=======|>>>>>>>)' alpha.txt > alpha.resolved && mv alpha.resolved alpha.txt
git add alpha.txt
ERR2307="$("$GIT_HUNK" list 2>&1 >/dev/null)"
[[ "$ERR2307" != *alpha.txt* ]] || fail "test 2307: resolved alpha.txt still noted: '$ERR2307'"
[[ -n "$(first_sha --staged --file alpha.txt)" ]] || fail "test 2307: resolved alpha.txt should list as staged"
pass "test 2307: a resolved path drops out of the notes"

# ============================================================================
# Test 2308: add --file of a conflicted path refuses, naming it, and changes nothing
# ============================================================================
conflict_repo
BEFORE2308="$(repo_state)"
ERR2308="$("$GIT_HUNK" add --file alpha.txt 2>&1 >/dev/null)" && fail "test 2308: add --file alpha.txt succeeded"
WANT2308="error: cannot stage 'alpha.txt' while it has an unresolved merge conflict
$HINT_ALPHA"
[[ "$ERR2308" == "$WANT2308" ]] || fail "test 2308: stderr was: '$ERR2308'"
[[ "$(repo_state)" == "$BEFORE2308" ]] || fail "test 2308: the repo changed"
pass "test 2308: add --file of a conflicted path refuses"

# ============================================================================
# Test 2309: --file naming a conflicted path refuses even beside a clean one
# ============================================================================
"$GIT_HUNK" add --file beta.txt --file alpha.txt > /dev/null 2>&1 && fail "test 2309: add succeeded"
[[ "$(repo_state)" == "$BEFORE2308" ]] || fail "test 2309: the repo changed"
pass "test 2309: a conflicted path in --file refuses the whole add"

# ============================================================================
# Test 2310: add --all stages the rest and notes what it left out, exit 0
# ============================================================================
ERR2310="$("$GIT_HUNK" add --all 2>&1 >/dev/null)" || fail "test 2310: add --all failed"
WANT2310="note: alpha.txt: unresolved merge conflict — not staged
note: gamma.txt: unresolved merge conflict — not staged
$HINT_ANY"
[[ "$ERR2310" == "$WANT2310" ]] || fail "test 2310: stderr was: '$ERR2310'"
[[ "$(git diff --cached --name-only --diff-filter=M)" == "beta.txt" ]] || fail "test 2310: only beta.txt should be staged"
[[ "$(git ls-files -u alpha.txt | wc -l | tr -d ' ')" == "3" ]] || fail "test 2310: alpha.txt should still be unmerged"
git reset -q beta.txt 2>/dev/null || true
OUT2310Q="$("$GIT_HUNK" add --all -q 2>&1)"
[[ -z "$OUT2310Q" ]] || fail "test 2310: -q should silence the notes, got: '$OUT2310Q'"
pass "test 2310: add --all notes conflicted paths it left out"

# ============================================================================
# Test 2311: with nothing but conflicts, add --all says why there is nothing
# ============================================================================
conflict_repo
git checkout -q beta.txt
ERR2311="$("$GIT_HUNK" add --all 2>&1 >/dev/null)" && fail "test 2311: add --all succeeded"
WANT2311="no unstaged changes
note: alpha.txt: unresolved merge conflict — not staged
note: gamma.txt: unresolved merge conflict — not staged
$HINT_ANY"
[[ "$ERR2311" == "$WANT2311" ]] || fail "test 2311: stderr was: '$ERR2311'"
pass "test 2311: add --all with only conflicts explains the empty diff"

# ============================================================================
# Test 2312: reset and restore say what they left out, restore with its own hint
# ============================================================================
conflict_repo
ERR2312R="$("$GIT_HUNK" reset --all 2>&1 >/dev/null)" && fail "test 2312: reset --all with nothing staged succeeded"
[[ "$ERR2312R" == "no staged changes"$'\n'"note: alpha.txt: unresolved merge conflict — not unstaged"* ]] \
    || fail "test 2312: reset stderr was: '$ERR2312R'"
ERR2312="$("$GIT_HUNK" restore --file alpha.txt 2>&1 >/dev/null)" && fail "test 2312: restore --file alpha.txt succeeded"
WANT2312="error: cannot restore 'alpha.txt' while it has an unresolved merge conflict
$HINT_ALPHA_RESTORE"
[[ "$ERR2312" == "$WANT2312" ]] || fail "test 2312: restore stderr was: '$ERR2312'"
"$GIT_HUNK" restore --all --dry-run 2>&1 >/dev/null | grep -q "^note: gamma.txt: unresolved merge conflict — not restored$" \
    || fail "test 2312: restore --all --dry-run should note gamma.txt"
pass "test 2312: reset and restore name conflicted paths"

# ============================================================================
# Test 2313: a hunk from --ref that writes a conflicted path is refused by name
# ============================================================================
conflict_repo
REF_SHA2313="$(first_sha --ref HEAD --file alpha.txt)"
[[ -n "$REF_SHA2313" ]] || fail "test 2313: HEAD should have an alpha.txt hunk"
BEFORE2313="$(repo_state)"
ERR2313="$("$GIT_HUNK" reset --ref HEAD "$REF_SHA2313" 2>&1 >/dev/null)" && fail "test 2313: reset --ref succeeded"
[[ "$ERR2313" == "error: cannot unstage 'alpha.txt' while it has an unresolved merge conflict"* ]] \
    || fail "test 2313: stderr was: '$ERR2313'"
"$GIT_HUNK" add --ref HEAD "$REF_SHA2313" 2>&1 >/dev/null | grep -q "^error: cannot stage 'alpha.txt' while" \
    || fail "test 2313: add --ref should refuse alpha.txt by name"
[[ "$(repo_state)" == "$BEFORE2313" ]] || fail "test 2313: the repo changed"
pass "test 2313: hunks from --ref cannot write a conflicted path"

# ============================================================================
# Test 2314: commit refuses during a merge, conflicted or resolved, and leaves it
# ============================================================================
conflict_repo
BEFORE2314="$(repo_state)"
ERR2314="$("$GIT_HUNK" commit --all -m "partial" 2>&1 >/dev/null)" && fail "test 2314: commit during a conflicted merge succeeded"
WANT2314="error: cannot commit selected hunks during a merge; its commit must record the whole resolution
note: alpha.txt: unresolved merge conflict
note: gamma.txt: unresolved merge conflict
hint: resolve the conflicts and mark each resolved with 'git add <path>' (or 'git rm <path>'), then run 'git commit' to conclude the merge (or 'git merge --abort' to abandon it)"
[[ "$ERR2314" == "$WANT2314" ]] || fail "test 2314: stderr was: '$ERR2314'"
"$GIT_HUNK" commit --all --dry-run > /dev/null 2>&1 && fail "test 2314: commit --dry-run during a merge succeeded"
"$GIT_HUNK" commit --amend --all -m "amend" > /dev/null 2>&1 && fail "test 2314: commit --amend during a merge succeeded"
[[ "$(repo_state)" == "$BEFORE2314" ]] || fail "test 2314: the repo changed"
git add alpha.txt
git rm -q gamma.txt
ERR2314B="$("$GIT_HUNK" commit --all -m "partial" 2>&1 >/dev/null)" && fail "test 2314: commit during a resolved merge succeeded"
WANT2314B="error: cannot commit selected hunks during a merge; its commit must record the whole resolution
hint: run 'git commit' to conclude the merge (or 'git merge --abort' to abandon it), then commit hunks"
[[ "$ERR2314B" == "$WANT2314B" ]] || fail "test 2314: resolved-merge stderr was: '$ERR2314B'"
git rev-parse -q --verify MERGE_HEAD > /dev/null || fail "test 2314: MERGE_HEAD is gone"
pass "test 2314: commit refuses to conclude a merge with some hunks"

# ============================================================================
# Test 2315: commit refuses during a cherry-pick and a revert, naming the way on
# ============================================================================
new_repo
git switch -q -c other
sed -i.bak '1s/.*/Alpha from other./' alpha.txt
git commit -q -a -m "other"
git switch -q -
sed -i.bak '1s/.*/Alpha from main./' alpha.txt
git commit -q -a -m "main"
git cherry-pick other > /dev/null 2>&1 && fail "test 2315: the cherry-pick did not conflict"
sed -i.bak '1s/.*/Beta edited./' beta.txt
"$GIT_HUNK" commit --all -m "partial" 2>&1 >/dev/null | grep -q "^hint: .*'git cherry-pick --continue' to conclude the cherry-pick (or 'git cherry-pick --abort' to abandon it)$" \
    || fail "test 2315: cherry-pick hint missing"
git cherry-pick --abort
git checkout -q beta.txt
sed -i.bak '3s/.*/Alpha three, first./' alpha.txt
git commit -q -a -m "first"
sed -i.bak '3s/.*/Alpha three, second./' alpha.txt
git commit -q -a -m "second"
git revert --no-edit HEAD~1 > /dev/null 2>&1 && fail "test 2315: the revert did not conflict"
sed -i.bak '1s/.*/Beta edited./' beta.txt
"$GIT_HUNK" commit --all -m "partial" 2>&1 >/dev/null | grep -q "^error: cannot commit selected hunks during a revert;" \
    || fail "test 2315: revert refusal missing"
git rev-parse -q --verify REVERT_HEAD > /dev/null || fail "test 2315: REVERT_HEAD is gone"
pass "test 2315: commit refuses during a cherry-pick and a revert"

# ============================================================================
# Test 2316: mid-rebase, other work commits beside a conflict, as git allows
# ============================================================================
new_repo
git switch -q -c other
sed -i.bak '1s/.*/Alpha from other./' alpha.txt
git commit -q -a -m "other"
git switch -q -
sed -i.bak '1s/.*/Alpha from main./' alpha.txt
git commit -q -a -m "main"
git switch -q other
git rebase -q - > /dev/null 2>&1 && fail "test 2316: the rebase did not conflict"
sed -i.bak '1s/.*/Beta edited./' beta.txt
ERR2316="$("$GIT_HUNK" commit --all -m "beside the conflict" 2>&1 >/dev/null)" || fail "test 2316: commit mid-rebase failed: '$ERR2316'"
[[ "$ERR2316" == *"note: alpha.txt: unresolved merge conflict — not committed"* ]] \
    || fail "test 2316: stderr was: '$ERR2316'"
[[ "$(git log -1 --format=%s)" == "beside the conflict" && -z "$(git log -1 --format=%P | grep ' ')" ]] \
    || fail "test 2316: expected a one-parent commit"
[[ "$(git ls-files -u alpha.txt | wc -l | tr -d ' ')" == "3" ]] || fail "test 2316: alpha.txt should still be unmerged"
git rebase --abort
pass "test 2316: a rebase stop allows committing other hunks"

# ============================================================================
# Test 2317: stash and stash pop refuse while a conflict stands
# ============================================================================
conflict_repo
BEFORE2317="$(repo_state)"
ERR2317="$("$GIT_HUNK" stash --file beta.txt 2>&1 >/dev/null)" && fail "test 2317: stash succeeded"
[[ "$ERR2317" == "error: cannot stash while 2 files have unresolved merge conflicts"$'\n'"note: alpha.txt: unresolved merge conflict"$'\n'* ]] \
    || fail "test 2317: stash stderr was: '$ERR2317'"
git merge --abort
"$GIT_HUNK" stash --file beta.txt > /dev/null
git merge -q other > /dev/null 2>&1 && fail "test 2317: the merge did not conflict"
BEFORE2317P="$(repo_state)"
ERR2317P="$("$GIT_HUNK" stash pop 2>&1 >/dev/null)" && fail "test 2317: stash pop succeeded"
[[ "$ERR2317P" == "error: cannot pop a stash while 2 files have unresolved merge conflicts"* ]] \
    || fail "test 2317: stash pop stderr was: '$ERR2317P'"
[[ "$(repo_state)" == "$BEFORE2317P" ]] || fail "test 2317: stash pop changed the repo"
pass "test 2317: stash and stash pop refuse while a conflict stands"

# ============================================================================
# Test 2318: check and diff note conflicts instead of passing over them
# ============================================================================
conflict_repo
ERR2318="$("$GIT_HUNK" check --exclusive --allow-empty --staged 2>&1 >/dev/null)" || fail "test 2318: check failed"
[[ "$ERR2318" == "note: alpha.txt: unresolved merge conflict — not checked"* ]] || fail "test 2318: check stderr was: '$ERR2318'"
ERR2318D="$("$GIT_HUNK" diff --staged abcd 2>&1 >/dev/null)" && fail "test 2318: diff --staged succeeded"
[[ "$ERR2318D" == "no staged changes"$'\n'"note: alpha.txt: unresolved merge conflict — not shown"* ]] \
    || fail "test 2318: diff stderr was: '$ERR2318D'"
pass "test 2318: check and diff note conflicted paths"

# ============================================================================
# Test 2319: the hint's command runs as printed from a subdirectory, and quotes
# a path the shell would split
# ============================================================================
new_repo
mkdir -p "dir/sub"
printf 'base\n' > "dir/my file.txt"
git add . && git commit -q -m "spaced"
git switch -q -c other
printf 'other\n' > "dir/my file.txt"
git commit -q -a -m "other"
git switch -q -
printf 'main\n' > "dir/my file.txt"
git commit -q -a -m "main"
git merge -q other > /dev/null 2>&1 && fail "test 2319: the merge did not conflict"
ERR2319="$(cd dir/sub && "$GIT_HUNK" add --file "../my file.txt" 2>&1 >/dev/null)" && fail "test 2319: add succeeded"
[[ "$ERR2319" == *"'git add \"../my file.txt\"'"* ]] || fail "test 2319: hint should quote the cwd-relative path, got: '$ERR2319'"
printf 'resolved\n' > "dir/my file.txt"
(cd dir/sub && git add "../my file.txt") || fail "test 2319: the hinted command failed"
[[ -z "$(git ls-files -u)" ]] || fail "test 2319: the hinted command did not resolve the conflict"
pass "test 2319: the hint names the path from the user's directory, quoted"

# ============================================================================
# Test 2320: both-added and rename/delete conflicts are noted like the rest
# ============================================================================
new_repo
git switch -q -c other
printf 'other\n' > added.txt
git mv beta.txt renamed.txt
git add . && git commit -q -m "other"
git switch -q -
printf 'main\n' > added.txt
git rm -q beta.txt
git add . && git commit -q -m "main"
git merge -q other > /dev/null 2>&1 && fail "test 2320: the merge did not conflict"
ERR2320="$("$GIT_HUNK" list 2>&1 >/dev/null)"
for p2320 in added.txt renamed.txt; do
    if git ls-files -u "$p2320" | grep -q .; then
        [[ "$ERR2320" == *"note: $p2320: unresolved merge conflict — not listed"* ]] \
            || fail "test 2320: $p2320 is unmerged but not noted: '$ERR2320'"
    fi
done
[[ "$ERR2320" == *"note: added.txt: unresolved merge conflict"* ]] || fail "test 2320: added.txt (AA) not noted"
pass "test 2320: add/add and rename conflicts are noted"

# ============================================================================
# Test 2321: a large conflict is summed up past ten notes
# ============================================================================
new_repo
for i in $(seq 1 12); do printf 'base\n' > "c$i.txt"; done
git add . && git commit -q -m "base"
git switch -q -c other
for i in $(seq 1 12); do printf 'other\n' > "c$i.txt"; done
git commit -q -a -m "other"
git switch -q -
for i in $(seq 1 12); do printf 'main\n' > "c$i.txt"; done
git commit -q -a -m "main"
git merge -q other > /dev/null 2>&1 && fail "test 2321: the merge did not conflict"
ERR2321="$("$GIT_HUNK" list 2>&1 >/dev/null)"
[[ "$(echo "$ERR2321" | grep -c '^note: c[0-9]*\.txt: unresolved merge conflict')" == "10" ]] \
    || fail "test 2321: expected ten per-path notes, got: '$ERR2321'"
echo "$ERR2321" | grep -q "^note: 2 more unresolved merge conflicts ('git diff --name-only --diff-filter=U' lists them all)$" \
    || fail "test 2321: expected a summary of the other two, got: '$ERR2321'"
pass "test 2321: notes past ten are summed up"

# ============================================================================
# Test 2322: a conflict --3way left behind (no merge in progress) is noted too
# ============================================================================
new_repo
sed -i.bak '2s/.*/Beta line two from history./' beta.txt
git commit -q -a -m "history"
git reset -q --hard HEAD~1
sed -i.bak '2s/.*/Beta line two here./' beta.txt
git commit -q -a -m "here"
SHA2322="$(git log --all --format=%H -1 --grep=history)"
REF2322="$(first_sha --ref "$SHA2322")"
"$GIT_HUNK" add --3way --ref "$SHA2322" "$REF2322" > /dev/null 2>&1 && fail "test 2322: --3way did not conflict"
if git ls-files -u beta.txt | grep -q .; then
    "$GIT_HUNK" list 2>&1 >/dev/null | grep -q "^note: beta.txt: unresolved merge conflict — not listed$" \
        || fail "test 2322: a --3way leftover should be noted"
    sed -i.bak '1s/.*/Alpha edited./' alpha.txt
    "$GIT_HUNK" commit --all -m "beside it" > /dev/null 2>&1 || fail "test 2322: with no merge in progress, commit should go ahead"
fi
pass "test 2322: --3way leftovers are noted and do not block a commit"

report_results
