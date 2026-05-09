#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 100: porcelain list shows expected fields
# ============================================================================
new_repo
sed -i.bak '1s/.*/Modified first line of alpha./' alpha.txt

LINE="$("$GIT_HUNK" list --porcelain --oneline | head -1)"
[[ -n "$LINE" ]] || fail "test 100: expected output from list --porcelain"
SHA="$(echo "$LINE" | cut -f1)"
FILE="$(echo "$LINE" | cut -f2)"
START="$(echo "$LINE" | cut -f3)"
[[ ${#SHA} -eq 7 ]] || fail "test 100: expected 7-char SHA, got '${SHA}'"
[[ "$FILE" == "alpha.txt" ]] || fail "test 100: expected alpha.txt, got '${FILE}'"
[[ "$START" -gt 0 ]] || fail "test 100: expected positive start line, got '${START}'"
pass "test 100: porcelain output format"

# ============================================================================
# Test 101: new file with intent-to-add appears in list
# ============================================================================
new_repo
echo "brand new content" > new_file.txt
git add -N new_file.txt

LINE="$("$GIT_HUNK" list --porcelain --oneline | grep "new_file.txt" || true)"
[[ -n "$LINE" ]] || fail "test 101: new file hunk not listed (try git add -N)"
SHA="$(echo "$LINE" | cut -f1)"
[[ ${#SHA} -eq 7 ]] || fail "test 101: new file SHA not 7 chars"
pass "test 101: new file with intent-to-add listed"

# ============================================================================
# Test 102: deleted file appears in staged list
# ============================================================================
new_repo
git rm alpha.txt -q

DEL_LINE="$("$GIT_HUNK" list --staged --porcelain --oneline | grep "alpha.txt" || true)"
[[ -n "$DEL_LINE" ]] || fail "test 102: deleted file not in staged list"
pass "test 102: deleted file in staged list"

# ============================================================================
# Test 103: --file filter restricts output to matching file
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt

FILTERED="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt)"
[[ -n "$FILTERED" ]] || fail "test 103: no output with --file alpha.txt"
while IFS= read -r line; do
    FILE_COL="$(echo "$line" | cut -f2)"
    [[ "$FILE_COL" == "alpha.txt" ]] || fail "test 103: --file filter returned non-matching file '$FILE_COL'"
done <<< "$FILTERED"
echo "$FILTERED" | grep "beta.txt" && fail "test 103: --file filter leaked beta.txt" || true
pass "test 103: --file filter restricts output"

# ============================================================================
# Test 104: human output contains 7-char SHA and file name
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

HUMAN="$("$GIT_HUNK" list 2>/dev/null | head -1)"
[[ -n "$HUMAN" ]] || fail "test 104: empty human output"
FIRST_TOKEN="$(echo "$HUMAN" | awk '{print $1}')"
[[ ${#FIRST_TOKEN} -eq 7 ]] || fail "test 104: first token not 7 chars: '${FIRST_TOKEN}'"
pass "test 104: human output format"

# ============================================================================
# Test 105: untracked file appears in list output
# ============================================================================
new_repo
echo "brand new untracked content" > untracked.txt

LINE105="$("$GIT_HUNK" list --porcelain --oneline | grep "untracked.txt" || true)"
[[ -n "$LINE105" ]] || fail "test 105: untracked file not shown in list"
SHA105="$(echo "$LINE105" | cut -f1)"
[[ ${#SHA105} -eq 7 ]] || fail "test 105: untracked SHA not 7 chars"
pass "test 105: untracked file appears in list"

# ============================================================================
# Test 106: untracked file does NOT appear in list --staged
# ============================================================================
new_repo
echo "brand new untracked content" > untracked.txt

STAGED106="$("$GIT_HUNK" list --staged --porcelain --oneline 2>/dev/null | grep "untracked.txt" || true)"
[[ -z "$STAGED106" ]] || fail "test 106: untracked file should not appear in --staged list"
pass "test 106: untracked file not in staged list"

# ============================================================================
# Test 107: untracked file hint no longer shown
# ============================================================================
new_repo
echo "some content" > untracked.txt

STDERR107="$("$GIT_HUNK" list --no-color 2>&1 >/dev/null || true)"
echo "$STDERR107" | grep -q "untracked file(s) not shown" && fail "test 107: old untracked hint still showing" || true
pass "test 107: old untracked hint removed"

# ============================================================================
# Test 108: --file filter works with untracked files
# ============================================================================
new_repo
echo "untracked alpha" > untracked_a.txt
echo "untracked beta" > untracked_b.txt

FILTERED108="$("$GIT_HUNK" list --porcelain --oneline --file untracked_a.txt)"
[[ -n "$FILTERED108" ]] || fail "test 108: no output with --file untracked_a.txt"
echo "$FILTERED108" | grep "untracked_b.txt" && fail "test 108: --file leaked untracked_b.txt" || true
pass "test 108: --file filter works with untracked files"

# ============================================================================
# Test 109: --tracked-only excludes untracked files
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked_filter.txt

TRACKED_ONLY="$("$GIT_HUNK" list --tracked-only --porcelain --oneline)"
[[ -n "$TRACKED_ONLY" ]] || fail "test 109: expected tracked hunks in output"
echo "$TRACKED_ONLY" | grep -q "alpha.txt" || fail "test 109: tracked file missing from --tracked-only"
echo "$TRACKED_ONLY" | grep -q "untracked_filter.txt" && fail "test 109: untracked file leaked into --tracked-only" || true
pass "test 109: --tracked-only excludes untracked files"

# ============================================================================
# Test 110: --untracked-only excludes tracked files
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked_filter.txt

UNTRACKED_ONLY="$("$GIT_HUNK" list --untracked-only --porcelain --oneline)"
[[ -n "$UNTRACKED_ONLY" ]] || fail "test 110: expected untracked hunks in output"
echo "$UNTRACKED_ONLY" | grep -q "untracked_filter.txt" || fail "test 110: untracked file missing from --untracked-only"
echo "$UNTRACKED_ONLY" | grep -q "alpha.txt" && fail "test 110: tracked file leaked into --untracked-only" || true
pass "test 110: --untracked-only excludes tracked files"

# ============================================================================
# Test 111: --untracked-only with no untracked files shows nothing
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

EMPTY111="$("$GIT_HUNK" list --untracked-only --porcelain --oneline 2>/dev/null || true)"
[[ -z "$EMPTY111" ]] || fail "test 111: expected no output with --untracked-only and no untracked files, got: '$EMPTY111'"
pass "test 111: --untracked-only with no untracked files shows nothing"

# ============================================================================
# Test 112: diff displays untracked file content
# ============================================================================
new_repo
echo "unique_marker_for_show_test" > untracked_show.txt

SHA112="$("$GIT_HUNK" list --porcelain --oneline --file untracked_show.txt | head -1 | cut -f1)"
[[ -n "$SHA112" ]] || fail "test 112: no untracked hunk found"
DIFF_OUT="$("$GIT_HUNK" diff --no-color "$SHA112")"
echo "$DIFF_OUT" | grep -q "unique_marker_for_show_test" \
    || fail "test 112: diff output missing file content, got: '$DIFF_OUT'"
echo "$DIFF_OUT" | grep -qE '(new file|@@)' \
    || fail "test 112: diff output missing new file or @@ header, got: '$DIFF_OUT'"
pass "test 112: diff displays untracked file content"

# ============================================================================
# Test 113: SHA depends only on file path + content, not repo location
# ============================================================================
# Repo 1: use new_repo (setup-repo.sh creates deterministic content)
new_repo
sed -i.bak '1s/.*/Cross-repo SHA test line./' alpha.txt
SHA113A="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA113A" ]] || fail "test 113: no hunk found in repo 1"

# Repo 2: new_repo creates another identical repo (same deterministic content)
new_repo
sed -i.bak '1s/.*/Cross-repo SHA test line./' alpha.txt
SHA113B="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA113B" ]] || fail "test 113: no hunk found in repo 2"

[[ "$SHA113A" == "$SHA113B" ]] \
    || fail "test 113: SHAs differ across repos: '$SHA113A' vs '$SHA113B'"
pass "test 113: SHA is identical across two repos with same content"

# ============================================================================
# Test 114: --unified context value affects the SHA
# Two nearby changes that stay separate with -U0 but merge into one hunk
# with -U3, producing different diff content and thus different SHAs.
# ============================================================================
new_repo
cat > proximity.txt <<'PROX_EOF'
line 1
line 2 original
line 3
line 4 original
line 5
PROX_EOF
git add proximity.txt && git commit -m "proximity setup" -q
sed -i.bak 's/line 2 original/line 2 changed/' proximity.txt
sed -i.bak 's/line 4 original/line 4 changed/' proximity.txt

SHA114_U0="$("$GIT_HUNK" list --porcelain --oneline --unified 0 --file proximity.txt | head -1 | cut -f1)"
SHA114_U3="$("$GIT_HUNK" list --porcelain --oneline --unified 3 --file proximity.txt | head -1 | cut -f1)"
[[ -n "$SHA114_U0" ]] || fail "test 114: no hunk found with -U0"
[[ -n "$SHA114_U3" ]] || fail "test 114: no hunk found with -U3"
[[ "$SHA114_U0" != "$SHA114_U3" ]] \
    || fail "test 114: -U0 and -U3 produced the same SHA '$SHA114_U0'"
pass "test 114: --unified context value produces different SHAs"

# ============================================================================
# Test 115: multiple --file flags filter to the union of those files
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt
sed -i.bak '1s/.*/Changed gamma./' gamma.txt

OUT115="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt --file gamma.txt)"
echo "$OUT115" | grep -q "alpha.txt" || fail "test 115: alpha.txt missing from multi-file filter"
echo "$OUT115" | grep -q "gamma.txt" || fail "test 115: gamma.txt missing from multi-file filter"
echo "$OUT115" | grep -q "beta.txt" && fail "test 115: beta.txt leaked into multi-file filter" || true
pass "test 115: multiple --file flags select the union of files"

# ============================================================================
# Test 116: --ref <commit> shorthand shows that commit's hunks (== <ref>^..<ref>)
# This is `git show <commit>` semantics for hunks: ref alone means "the diff
# this commit introduced", not "ref vs worktree".
# ============================================================================
new_repo
echo "history line one" > history.txt
git add history.txt && git commit -q -m "history: initial"
echo "history line two added" >> history.txt
git add history.txt && git commit -q -m "history: append"
HIST_HEAD=$(git rev-parse HEAD)
HIST_PARENT=$(git rev-parse HEAD^)

# Sanity: the explicit-range form has worked since v0.13 — capture its output.
RANGE116=$("$GIT_HUNK" list --ref "${HIST_PARENT}..${HIST_HEAD}" --porcelain --oneline)
[[ -n "$RANGE116" ]] || fail "test 116a: explicit ${HIST_PARENT}..${HIST_HEAD} produced no hunks"

# Single-ref shorthand should produce identical output to the explicit range.
SHORT116=$("$GIT_HUNK" list --ref "$HIST_HEAD" --porcelain --oneline)
[[ "$SHORT116" == "$RANGE116" ]] \
    || fail "test 116: --ref <commit> should equal --ref <commit>^..<commit>; range='$RANGE116', short='$SHORT116'"
pass "test 116: --ref <commit> shorthand emits the commit's diff (git show semantics)"

# ============================================================================
# Test 117: --ref HEAD~1 shows penultimate commit's hunks
# ============================================================================
SHORT117=$("$GIT_HUNK" list --ref "HEAD~1" --porcelain --oneline)
echo "$SHORT117" | grep -q "history.txt" \
    || fail "test 117: HEAD~1 shorthand should include history.txt, got: '$SHORT117'"
pass "test 117: --ref HEAD~1 shorthand shows penultimate commit hunks"

# ============================================================================
# Test 118: --ref <commit> shorthand is unaffected by worktree state
# (it shows commit content, not a diff against the worktree)
# ============================================================================
echo "DIRTY WORKTREE EDIT" > history.txt
DIRTY118=$("$GIT_HUNK" list --ref "$HIST_HEAD" --porcelain --oneline)
[[ "$DIRTY118" == "$RANGE116" ]] \
    || fail "test 118: --ref shorthand should ignore worktree state; before='$RANGE116', after='$DIRTY118'"
pass "test 118: --ref <commit> shorthand ignores worktree state"

# ============================================================================
# Test 119: --ref <initial-commit> works (no parent — diff against empty tree)
# Regression for the parent-less commit edge case.
# ============================================================================
INIT_REPO=$(mktemp -d)
cd "$INIT_REPO"
git init -q
git config user.email t@t.test
git config user.name t
echo "first content" > first.txt
git add first.txt && git commit -q -m "initial"
INIT_SHA=$(git rev-parse HEAD)

OUT119=$("$GIT_HUNK" list --ref "$INIT_SHA" --porcelain --oneline 2>&1) || true
echo "$OUT119" | grep -q "first.txt" \
    || fail "test 119: --ref <initial-commit> should show its hunks; got: '$OUT119'"
pass "test 119: --ref <initial-commit> handled (no parent → diff against empty tree)"
cd /tmp && rm -rf "$INIT_REPO"

report_results
