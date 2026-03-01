#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# T14 — Binary file handling
# ============================================================================

# ============================================================================
# Test 800: binary file changes are gracefully skipped (no crash, 0 hunks)
# ============================================================================
new_repo
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00' > image.png
git add image.png && git commit -q -m "add binary"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff' > image.png

COUNT800="$("$GIT_HUNK" count --file image.png 2>/dev/null)"
[[ "$COUNT800" == "0" ]] \
    || fail "test 800: expected 0 hunks for binary file, got '$COUNT800'"
LIST800="$("$GIT_HUNK" list --porcelain --oneline --file image.png 2>/dev/null)"
[[ -z "$LIST800" ]] \
    || fail "test 800: expected empty list for binary file, got '$LIST800'"
pass "test 800: binary file changes skipped gracefully"

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

SHA811="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | head -1 | cut -f1)"
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

SHA812="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | head -1 | cut -f1)"
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
# T18 — Merge conflict behavior
# ============================================================================

# ============================================================================
# Test 840: list doesn't crash and shows 0 hunks during merge conflict
# ============================================================================
CONFLICT_REPO="$(mktemp -d)"
SAVED_REPO840="$CURRENT_REPO"
CURRENT_REPO="$CONFLICT_REPO"
cd "$CONFLICT_REPO"
git init -q
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
# T19 — Symlink support
# ============================================================================

# ============================================================================
# Test 850: untracked symlink appears in list
# ============================================================================
new_repo
ln -s alpha.txt mylink.txt

LINE850="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | grep "mylink.txt" || true)"
[[ -n "$LINE850" ]] \
    || fail "test 850: untracked symlink not found in list"
SHA850="$(echo "$LINE850" | cut -f1)"
[[ ${#SHA850} -eq 7 ]] \
    || fail "test 850: symlink SHA not 7 chars: '$SHA850'"
pass "test 850: untracked symlink appears in list"

# ============================================================================
# Test 851: tracked symlink target change appears in list and can be staged
# ============================================================================
new_repo
ln -s alpha.txt mylink851.txt
git add mylink851.txt && git commit -q -m "add symlink"
ln -sf beta.txt mylink851.txt

LINE851="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | grep "mylink851.txt" || true)"
[[ -n "$LINE851" ]] \
    || fail "test 851: tracked symlink change not found in list"
SHA851="$(echo "$LINE851" | cut -f1)"
[[ ${#SHA851} -eq 7 ]] \
    || fail "test 851: symlink SHA not 7 chars: '$SHA851'"
"$GIT_HUNK" add "$SHA851" > /dev/null
STAGED851="$(git diff --cached --name-only)"
echo "$STAGED851" | grep -q "mylink851.txt" \
    || fail "test 851: symlink change not staged after add, got '$STAGED851'"
pass "test 851: tracked symlink target change appears in list and can be staged"

report_results
