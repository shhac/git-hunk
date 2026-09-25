#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# T14 — Binary file handling
# ============================================================================

# ============================================================================
# Test 800: binary file changes produce a single hunk marked as binary
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png

COUNT800="$("$GIT_HUNK" count --file image.png 2>/dev/null)"
[[ "$COUNT800" == "1" ]] \
    || fail "test 800: expected 1 hunk for binary file, got '$COUNT800'"
LIST800="$("$GIT_HUNK" list --porcelain --oneline --file image.png 2>/dev/null)"
echo "$LIST800" | grep -q "binary" \
    || fail "test 800: expected binary marker in list, got '$LIST800'"
SHA800="$(echo "$LIST800" | cut -f1)"
[[ ${#SHA800} -eq 7 ]] \
    || fail "test 800: SHA not 7 chars: '$SHA800'"
pass "test 800: binary file listed with binary marker"

# ============================================================================
# Test 801: binary hunk can be staged with add
# ============================================================================
SHA801="$SHA800"
"$GIT_HUNK" add "$SHA801" > /dev/null
STAGED801="$(git diff --cached --stat image.png | wc -l | tr -d ' ')"
[[ "$STAGED801" -gt 0 ]] \
    || fail "test 801: binary file was not staged"
pass "test 801: binary hunk staged with add"

# ============================================================================
# Test 802: binary hunk can be unstaged with reset
# ============================================================================
STAGED_SHA802="$("$GIT_HUNK" list --staged --porcelain --oneline --file image.png 2>/dev/null | head -1 | cut -f1)"
[[ -n "$STAGED_SHA802" ]] || fail "test 802: no staged binary hunk found"
"$GIT_HUNK" reset "$STAGED_SHA802" > /dev/null
REMAINING802="$(git diff --cached --stat image.png | wc -l | tr -d ' ')"
[[ "$REMAINING802" -eq 0 ]] \
    || fail "test 802: binary hunk was not unstaged"
pass "test 802: binary hunk unstaged with reset"

# ============================================================================
# Test 803: binary hunk restore reverts worktree change
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png
BEFORE803="$(md5sum image.png 2>/dev/null || md5 -q image.png)"
SHA803="$(first_sha --oneline --file image.png)"
"$GIT_HUNK" restore "$SHA803" > /dev/null
AFTER803="$(md5sum image.png 2>/dev/null || md5 -q image.png)"
[[ "$BEFORE803" != "$AFTER803" ]] \
    || fail "test 803: binary file was not restored (checksum unchanged)"
COUNT803="$("$GIT_HUNK" count --file image.png 2>/dev/null)"
[[ "$COUNT803" == "0" ]] \
    || fail "test 803: expected 0 hunks after restore, got '$COUNT803'"
pass "test 803: binary hunk restore reverts worktree"

# ============================================================================
# Test 804: binary hunk can be committed
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png
SHA804="$(first_sha --oneline --file image.png)"
"$GIT_HUNK" commit "$SHA804" -m "update binary" > /dev/null 2>/dev/null
LAST_MSG804="$(git log -1 --format=%s)"
[[ "$LAST_MSG804" == "update binary" ]] \
    || fail "test 804: expected commit message 'update binary', got '$LAST_MSG804'"
pass "test 804: binary hunk committed"

# ============================================================================
# Test 805: binary + text changes together
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png
sed -i.bak '1s/.*/Changed alpha./' alpha.txt
COUNT805="$("$GIT_HUNK" count 2>/dev/null)"
[[ "$COUNT805" -ge 2 ]] \
    || fail "test 805: expected at least 2 hunks (text+binary), got '$COUNT805'"
"$GIT_HUNK" add --all > /dev/null
UNSTAGED805="$("$GIT_HUNK" count 2>/dev/null)"
[[ "$UNSTAGED805" == "0" ]] \
    || fail "test 805: expected 0 unstaged hunks after --all, got '$UNSTAGED805'"
pass "test 805: binary + text changes staged together with --all"

# ============================================================================
# Test 806: line-spec syntax rejected for binary hunks
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png
SHA806="$(first_sha --oneline --file image.png)"
EXIT806=0
"$GIT_HUNK" add "${SHA806}:1-5" > /dev/null 2>/dev/null || EXIT806=$?
[[ "$EXIT806" -ne 0 ]] \
    || fail "test 806: line-spec on binary hunk should fail"
pass "test 806: line-spec rejected for binary hunks"

# ============================================================================
# Test 807: binary diff command shows Binary file changed
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png
SHA807="$(first_sha --oneline --file image.png)"
DIFF807="$("$GIT_HUNK" diff "$SHA807" --no-color 2>/dev/null)"
echo "$DIFF807" | grep -q "Binary file changed" \
    || fail "test 807: expected 'Binary file changed' in diff output, got: '$DIFF807'"
pass "test 807: binary diff shows Binary file changed"

# ============================================================================
# Test 808: new untracked binary file appears in list
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > newimage.png
COUNT808="$("$GIT_HUNK" count --file newimage.png 2>/dev/null)"
[[ "$COUNT808" == "1" ]] \
    || fail "test 808: expected 1 hunk for untracked binary, got '$COUNT808'"
LIST808="$("$GIT_HUNK" list --porcelain --oneline --file newimage.png 2>/dev/null)"
echo "$LIST808" | grep -q "binary" \
    || fail "test 808: expected binary marker for untracked binary, got '$LIST808'"
pass "test 808: untracked binary file listed"

# ============================================================================
# Test 809: binary tracked file can be stashed and popped
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png
BEFORE809="$(md5sum image.png 2>/dev/null || md5 -q image.png)"
SHA809="$(first_sha --oneline --file image.png)"
"$GIT_HUNK" stash "$SHA809" > /dev/null 2>/dev/null
AFTER809="$(md5sum image.png 2>/dev/null || md5 -q image.png)"
[[ "$BEFORE809" != "$AFTER809" ]] \
    || fail "test 809: binary file was not reverted after stash"
COUNT809="$("$GIT_HUNK" count --file image.png 2>/dev/null)"
[[ "$COUNT809" == "0" ]] \
    || fail "test 809: expected 0 hunks after stash, got '$COUNT809'"
STASH_FILES809="$(git stash show --stat 2>/dev/null)"
echo "$STASH_FILES809" | grep -q "image.png" \
    || fail "test 809: stash does not contain image.png"
"$GIT_HUNK" stash pop > /dev/null 2>/dev/null
POPPED809="$(md5sum image.png 2>/dev/null || md5 -q image.png)"
[[ "$BEFORE809" == "$POPPED809" ]] \
    || fail "test 809: binary file not restored after stash pop"
pass "test 809: binary tracked file stash + pop roundtrip"

# ============================================================================
# T15 — Unicode filenames
# ============================================================================

# ============================================================================
# Test 810: unicode filename appears in list with 7-char SHA
# ============================================================================
new_repo
echo "original" > "café.txt"
git add "café.txt" && git commit -q -m "unicode file"
echo "changed" > "café.txt"

LINE810="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | grep -v $'\t[a-z].*\.txt\t' || true)"
LINE810="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | head -1)"
[[ -n "$LINE810" ]] || fail "test 810: no hunk found for unicode filename"
SHA810="$(echo "$LINE810" | cut -f1)"
FILE810="$(echo "$LINE810" | cut -f2)"
[[ ${#SHA810} -eq 7 ]] || fail "test 810: SHA not 7 chars: '$SHA810'"
[[ "$FILE810" == "café.txt" ]] \
    || fail "test 810: expected 'café.txt', got '$FILE810'"
pass "test 810: unicode filename appears in list"

# ============================================================================
# Test 811: unicode filename can be staged with add
# ============================================================================
new_repo
echo "original" > "café.txt"
git add "café.txt" && git commit -q -m "unicode file"
echo "changed" > "café.txt"

SHA811="$(first_sha --oneline)"
[[ -n "$SHA811" ]] || fail "test 811: no hunk for unicode file"
"$GIT_HUNK" add "$SHA811" > /dev/null
STAGED811="$("$GIT_HUNK" count --staged)"
[[ "$STAGED811" -gt 0 ]] \
    || fail "test 811: expected staged hunks after add, got count '$STAGED811'"
pass "test 811: unicode filename can be staged with add"

# ============================================================================
# Test 812: unicode filename can be restored
# ============================================================================
new_repo
echo "original" > "café.txt"
git add "café.txt" && git commit -q -m "unicode file"
ORIG812="$(cat "café.txt")"
echo "changed" > "café.txt"

SHA812="$(first_sha --oneline)"
[[ -n "$SHA812" ]] || fail "test 812: no hunk for unicode file"
"$GIT_HUNK" restore "$SHA812" > /dev/null
[[ "$(cat "café.txt")" == "$ORIG812" ]] \
    || fail "test 812: café.txt not restored to original content"
pass "test 812: unicode filename can be restored"

# ============================================================================
# T16 — Rename detection
# ============================================================================

# ============================================================================
# Test 820: unstaged modification to renamed file appears in list
# ============================================================================
new_repo
echo "original content" > rename_test.txt
git add rename_test.txt && git commit -q -m "add rename_test"
git mv rename_test.txt renamed_test.txt
echo "added line" >> renamed_test.txt

LIST820="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null)"
[[ -n "$LIST820" ]] \
    || fail "test 820: expected hunk for unstaged modification to renamed file"
echo "$LIST820" | grep -q "renamed_test.txt" \
    || fail "test 820: renamed_test.txt not in list, got '$LIST820'"
pass "test 820: unstaged modification to renamed file appears in list"

# ============================================================================
# T17 — Empty repo (no commits) graceful handling
# ============================================================================

# ============================================================================
# Test 830: untracked file in empty repo (no commits) appears in list
# ============================================================================
EMPTY_REPO="$(mktemp -d)"
SAVED_REPO="$CURRENT_REPO"
CURRENT_REPO="$EMPTY_REPO"
cd "$EMPTY_REPO"
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "untracked content" > newfile.txt

LIST830="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null)"
[[ -n "$LIST830" ]] \
    || fail "test 830: expected hunk in empty repo (no commits)"
SHA830="$(echo "$LIST830" | head -1 | cut -f1)"
[[ ${#SHA830} -eq 7 ]] \
    || fail "test 830: SHA not 7 chars in empty repo: '$SHA830'"
cleanup_repo
CURRENT_REPO="$SAVED_REPO"
cd "$CURRENT_REPO"
pass "test 830: untracked file in empty repo (no commits) appears in list"

# ============================================================================
# Tests 831-834: an unborn branch (no commits yet). Where git works there,
# against the empty tree, so does git-hunk; where git refuses, git-hunk
# refuses in git's words instead of printing a raw rev-parse failure.
# ============================================================================
SAVED_REPO831="$CURRENT_REPO"
new_unborn_repo() {
    [[ "$CURRENT_REPO" == "$SAVED_REPO831" ]] || cleanup_repo
    CURRENT_REPO="$(mktemp -d)"
    cd "$CURRENT_REPO"
    git init -q
    git config user.email "t@t.com"
    git config user.name "T"
    printf 'staged\n' > staged.txt
    printf 'bin\000ary\n' > staged.bin
    git add staged.txt staged.bin
    printf 'more\n' >> staged.txt
    printf 'untracked\n' > new.txt
}
# Index entries, worktree state and stash list, for asserting a refusal
# changed nothing.
unborn_state() {
    git ls-files -s
    git status --porcelain=v2 --untracked-files=all
    git stash list 2>&1
}

new_unborn_repo
[[ "$("$GIT_HUNK" count --staged 2>&1)" == "2" ]] \
    || fail "test 831: count --staged should see both staged files against the empty tree"
"$GIT_HUNK" list --staged --porcelain --oneline 2>/dev/null | grep -q "staged.txt" \
    || fail "test 831: list --staged should list staged.txt"
OUT831="$("$GIT_HUNK" reset --all 2>&1)" || fail "test 831: reset --all on an unborn branch failed: $OUT831"
[[ -z "$(git ls-files)" ]] || fail "test 831: reset should empty the index, got '$(git ls-files)'"
[[ -f staged.txt && -f staged.bin ]] || fail "test 831: reset should leave the files in the worktree"
pass "test 831: list --staged and reset work on an unborn branch, as git's do"

new_unborn_repo
SHA832="$(first_sha --file new.txt)"
"$GIT_HUNK" commit --dry-run "$SHA832" > /dev/null 2>&1 \
    || fail "test 832: commit --dry-run on an unborn branch should pass"
OUT832="$("$GIT_HUNK" commit "$SHA832" -m "first" 2>&1)" \
    || fail "test 832: commit on an unborn branch failed: $OUT832"
[[ "$(git rev-list --count HEAD 2>/dev/null)" == "1" ]] || fail "test 832: commit should make the first commit"
[[ "$(git ls-tree --name-only HEAD)" == "new.txt" ]] \
    || fail "test 832: the first commit should hold only new.txt, got '$(git ls-tree --name-only HEAD)'"
[[ "$(git diff --cached --name-only | sort | tr '\n' ' ')" == "staged.bin staged.txt " ]] \
    || fail "test 832: what was staged should stay staged, got '$(git diff --cached --name-only)'"
[[ -z "$(git status --porcelain -- new.txt)" ]] || fail "test 832: new.txt should be clean after commit"
pass "test 832: commit on an unborn branch makes the first commit"

new_unborn_repo
BEFORE833="$(unborn_state)"
for DRY833 in "" --dry-run; do
    EC833=0
    ERR833="$("$GIT_HUNK" commit --amend $DRY833 --file new.txt -m "amend" 2>&1)" || EC833=$?
    [[ "$EC833" -eq 1 ]] || fail "test 833: commit --amend $DRY833 on an unborn branch should exit 1, got $EC833"
    [[ "$ERR833" == "error: you have nothing to amend" ]] \
        || fail "test 833: commit --amend $DRY833 should say there is nothing to amend, got: '$ERR833'"
done
[[ "$(unborn_state)" == "$BEFORE833" ]] || fail "test 833: a refused amend should change nothing"
pass "test 833: commit --amend on an unborn branch says there is nothing to amend"

new_unborn_repo
BEFORE834="$(unborn_state)"
for ARGS834 in "--all" "--all -u" "--file staged.txt"; do
    EC834=0
    ERR834="$("$GIT_HUNK" stash $ARGS834 2>&1)" || EC834=$?
    [[ "$EC834" -eq 1 ]] || fail "test 834: stash $ARGS834 on an unborn branch should exit 1, got $EC834"
    [[ "$ERR834" == "error: you do not have the initial commit yet" ]] \
        || fail "test 834: stash $ARGS834 should say there is no commit yet, got: '$ERR834'"
done
[[ "$(unborn_state)" == "$BEFORE834" ]] || fail "test 834: a refused stash should change nothing"
pass "test 834: stash on an unborn branch says there is no commit yet"

cleanup_repo
CURRENT_REPO="$SAVED_REPO831"
cd "$CURRENT_REPO"

# ============================================================================
# T18 — Merge conflict behavior
# ============================================================================

# ============================================================================
# Test 840: list doesn't crash and shows 0 hunks during merge conflict
# ============================================================================
CONFLICT_REPO="$(mktemp -d)"
SAVED_REPO840="$CURRENT_REPO"
CURRENT_REPO="$CONFLICT_REPO"
cd "$CONFLICT_REPO"
git init -q -b main
echo '*.bak' >> .git/info/exclude
git config user.email "t@t.com"
git config user.name "T"
printf "line 1\nline 2\nline 3\n" > conflict.txt
git add conflict.txt && git commit -q -m "base"
git checkout -q -b branch-a
sed -i.bak 's/line 3/line 3 branch-a/' conflict.txt
git commit -q -am "branch-a change"
git checkout -q main
git checkout -q -b branch-b
sed -i.bak 's/line 3/line 3 branch-b/' conflict.txt
git commit -q -am "branch-b change"
git merge branch-a 2>/dev/null || true  # expect conflict

COUNT840="$("$GIT_HUNK" count 2>/dev/null)"
[[ "$COUNT840" == "0" ]] \
    || fail "test 840: expected 0 hunks during merge conflict, got '$COUNT840'"
cleanup_repo
CURRENT_REPO="$SAVED_REPO840"
cd "$CURRENT_REPO"
pass "test 840: list/count show 0 hunks during merge conflict (no crash)"

# ============================================================================
# T21 — stdout redirected to a regular file
#
# A positional file writer starts at offset 0 and ignores the offset the shell
# already put on the descriptor, so appending or sharing a redirect with other
# commands would silently overwrite what came before. Logs live outside the
# repo so they do not show up as untracked hunks in the listing under test.
# ============================================================================
new_repo
sed -i.bak '5s/.*/Changed line five./' alpha.txt
OUTDIR880="$(mktemp -d)"

# ============================================================================
# Test 880: `list >> file` appends rather than overwriting
# ============================================================================
printf 'PRECEDING-MARKER\n' > "$OUTDIR880/append.log"
"$GIT_HUNK" list --porcelain >> "$OUTDIR880/append.log"
[[ "$(head -1 "$OUTDIR880/append.log")" == "PRECEDING-MARKER" ]] \
    || fail "test 880: append clobbered preceding content:"$'\n'"$(cat "$OUTDIR880/append.log")"
grep -q 'alpha.txt' "$OUTDIR880/append.log" \
    || fail "test 880: appended listing missing from log"
pass "test 880: list appends when stdout is opened for append"

# ============================================================================
# Test 881: stdout shared with other commands in one redirect group
# ============================================================================
{ echo "HEADER881"; "$GIT_HUNK" list --porcelain; echo "FOOTER881"; } > "$OUTDIR880/group.log"
[[ "$(head -1 "$OUTDIR880/group.log")" == "HEADER881" ]] \
    || fail "test 881: HEADER881 was overwritten:"$'\n'"$(cat "$OUTDIR880/group.log")"
[[ "$(tail -1 "$OUTDIR880/group.log")" == "FOOTER881" ]] \
    || fail "test 881: FOOTER881 missing or displaced:"$'\n'"$(cat "$OUTDIR880/group.log")"
grep -q 'alpha.txt' "$OUTDIR880/group.log" \
    || fail "test 881: listing missing from grouped redirect"
pass "test 881: stdout shares the descriptor offset with sibling commands"

# ============================================================================
# Test 882: output to a file matches output through a pipe, byte for byte
# ============================================================================
"$GIT_HUNK" list --porcelain > "$OUTDIR880/direct.log"
"$GIT_HUNK" list --porcelain | cat > "$OUTDIR880/piped.log"
cmp -s "$OUTDIR880/direct.log" "$OUTDIR880/piped.log" \
    || fail "test 882: file and pipe output differ:"$'\n'"$(diff "$OUTDIR880/direct.log" "$OUTDIR880/piped.log")"
pass "test 882: file and pipe output identical"
rm -rf "$OUTDIR880"

# ============================================================================
# Test 890: a staged binary rename is addressed by its new path. Same-length
# names used to split the `diff --git` line down the middle and yield the old
# path; different-length names yielded nothing and the rename was invisible.
# ============================================================================
for NEW890 in b.bin renamed-longer.bin; do
    new_repo
    { printf 'bin\000ary\n'; seq 1 400; } > a.bin
    git add a.bin && git commit -q -m "add binary"
    git mv a.bin "$NEW890"
    echo 401 >> "$NEW890"
    git add "$NEW890"
    git diff --cached --name-status | grep -q '^R' \
        || fail "test 890: fixture broken, git did not detect the rename"

    LIST890="$("$GIT_HUNK" list --staged --porcelain --oneline)"
    echo "$LIST890" | grep -q "$NEW890" \
        || fail "test 890: staged rename should list '$NEW890', got: '$LIST890'"
    echo "$LIST890" | grep -q "a.bin" \
        && fail "test 890: staged rename listed under old path: '$LIST890'"
    "$GIT_HUNK" reset --all > /dev/null 2>&1 \
        || fail "test 890: reset --all of the rename failed"
    git diff --cached --quiet -- "$NEW890" \
        || fail "test 890: '$NEW890' still staged after reset: '$(git status --short)'"
    pass "test 890: staged binary rename to '$NEW890' is listed and reset by its new path"
done

report_results
