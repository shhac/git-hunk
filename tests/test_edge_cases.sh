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
FILE850="$(echo "$LINE850" | cut -f2)"
[[ "$FILE850" == "mylink.txt@" ]] \
    || fail "test 850: expected 'mylink.txt@' (with @ suffix), got '$FILE850'"
pass "test 850: untracked symlink appears in list with @ suffix"

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
FILE851="$(echo "$LINE851" | cut -f2)"
[[ "$FILE851" == "mylink851.txt@" ]] \
    || fail "test 851: expected 'mylink851.txt@' (with @ suffix), got '$FILE851'"
ADD_OUT851="$("$GIT_HUNK" add --porcelain "$SHA851")"
echo "$ADD_OUT851" | grep -q "mylink851.txt@" \
    || fail "test 851: add output should include @ suffix, got '$ADD_OUT851'"
STAGED851="$(git diff --cached --name-only)"
echo "$STAGED851" | grep -q "mylink851.txt" \
    || fail "test 851: symlink change not staged after add, got '$STAGED851'"
pass "test 851: tracked symlink shows @ suffix in list and add output"

# ============================================================================
# Test 852: untracked symlink can be staged with add
# ============================================================================
new_repo
ln -s alpha.txt mylink852.txt

SHA852="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | grep "mylink852.txt" | cut -f1)"
[[ -n "$SHA852" ]] || fail "test 852: no hunk for untracked symlink"
"$GIT_HUNK" add "$SHA852" > /dev/null
STAGED852="$(git diff --cached --name-only)"
echo "$STAGED852" | grep -q "mylink852.txt" \
    || fail "test 852: untracked symlink not staged after add, got '$STAGED852'"
# verify it's still a symlink in the index
MODE852="$(git ls-files -s mylink852.txt | awk '{print $1}')"
[[ "$MODE852" == "120000" ]] \
    || fail "test 852: expected mode 120000 in index, got '$MODE852'"
pass "test 852: untracked symlink can be staged with add"

# ============================================================================
# Test 853: staged symlink can be unstaged with reset
# ============================================================================
new_repo
ln -s alpha.txt mylink853.txt
git add mylink853.txt && git commit -q -m "add symlink"
ln -sf beta.txt mylink853.txt

SHA853="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | grep "mylink853.txt" | cut -f1)"
[[ -n "$SHA853" ]] || fail "test 853: no hunk for symlink change"
"$GIT_HUNK" add "$SHA853" > /dev/null
STAGED853="$(git diff --cached --name-only)"
echo "$STAGED853" | grep -q "mylink853.txt" \
    || fail "test 853: symlink not staged before reset"

STAGED_SHA853="$("$GIT_HUNK" list --staged --porcelain --oneline 2>/dev/null | grep "mylink853.txt" | cut -f1)"
[[ -n "$STAGED_SHA853" ]] || fail "test 853: no staged hunk found for symlink"
"$GIT_HUNK" reset "$STAGED_SHA853" > /dev/null
REMAINING853="$(git diff --cached --name-only)"
if echo "$REMAINING853" | grep -q "mylink853.txt"; then
    fail "test 853: symlink should be unstaged after reset, got '$REMAINING853'"
fi
pass "test 853: staged symlink can be unstaged with reset"

# ============================================================================
# Test 854: symlink can be stashed and popped
# ============================================================================
new_repo
ln -s alpha.txt mylink854.txt
git add mylink854.txt && git commit -q -m "add symlink"
ln -sf beta.txt mylink854.txt

SHA854="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | grep "mylink854.txt" | cut -f1)"
[[ -n "$SHA854" ]] || fail "test 854: no hunk for symlink change"
STASH_OUT854="$("$GIT_HUNK" stash --porcelain "$SHA854")"
echo "$STASH_OUT854" | grep -q "mylink854.txt@" \
    || fail "test 854: stash output should include @ suffix, got '$STASH_OUT854'"
TARGET854="$(readlink mylink854.txt)"
[[ "$TARGET854" == "alpha.txt" ]] \
    || fail "test 854: expected symlink target 'alpha.txt' after stash, got '$TARGET854'"

"$GIT_HUNK" stash pop > /dev/null 2>/dev/null
TARGET854_POP="$(readlink mylink854.txt)"
[[ "$TARGET854_POP" == "beta.txt" ]] \
    || fail "test 854: expected symlink target 'beta.txt' after pop, got '$TARGET854_POP'"
pass "test 854: symlink can be stashed and popped"

# ============================================================================
# Test 855: stash preserves other changes when stashing symlink
# ============================================================================
new_repo
ln -s alpha.txt mylink855.txt
git add mylink855.txt && git commit -q -m "add symlink"
ln -sf beta.txt mylink855.txt
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

SHA855="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | grep "mylink855.txt" | cut -f1)"
[[ -n "$SHA855" ]] || fail "test 855: no hunk for symlink"
"$GIT_HUNK" stash "$SHA855" > /dev/null
# symlink should be reverted
TARGET855="$(readlink mylink855.txt)"
[[ "$TARGET855" == "alpha.txt" ]] \
    || fail "test 855: symlink should revert after stash, got '$TARGET855'"
# alpha.txt change should be preserved
[[ "$(head -1 alpha.txt)" == "Changed alpha." ]] \
    || fail "test 855: alpha.txt change should be preserved"
pass "test 855: stash preserves other changes when stashing symlink"

# ============================================================================
# Test 856: restore reverts symlink target change
# ============================================================================
new_repo
ln -s alpha.txt mylink856.txt
git add mylink856.txt && git commit -q -m "add symlink"
ln -sf beta.txt mylink856.txt

SHA856="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | grep "mylink856.txt" | cut -f1)"
[[ -n "$SHA856" ]] || fail "test 856: no hunk for symlink"
RESTORE_OUT856="$("$GIT_HUNK" restore --porcelain "$SHA856")"
echo "$RESTORE_OUT856" | grep -q "mylink856.txt@" \
    || fail "test 856: restore output should include @ suffix, got '$RESTORE_OUT856'"
TARGET856="$(readlink mylink856.txt)"
[[ "$TARGET856" == "alpha.txt" ]] \
    || fail "test 856: expected symlink target 'alpha.txt' after restore, got '$TARGET856'"
COUNT856="$("$GIT_HUNK" count --file mylink856.txt)"
[[ "$COUNT856" == "0" ]] \
    || fail "test 856: expected 0 hunks after restore, got '$COUNT856'"
pass "test 856: restore reverts symlink target change"

# ============================================================================
# Test 857: deleted symlink appears in list and can be staged
# ============================================================================
new_repo
ln -s alpha.txt mylink857.txt
git add mylink857.txt && git commit -q -m "add symlink"
rm mylink857.txt

LINE857="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | grep "mylink857.txt" || true)"
[[ -n "$LINE857" ]] \
    || fail "test 857: deleted symlink not found in list"
SHA857="$(echo "$LINE857" | cut -f1)"
"$GIT_HUNK" add "$SHA857" > /dev/null
STAGED857="$(git diff --cached --name-only)"
echo "$STAGED857" | grep -q "mylink857.txt" \
    || fail "test 857: deleted symlink not staged after add, got '$STAGED857'"
pass "test 857: deleted symlink appears in list and can be staged"

# ============================================================================
# Test 858: restore untracked symlink requires --force
# ============================================================================
new_repo
ln -s alpha.txt mylink858.txt

SHA858="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | grep "mylink858.txt" | cut -f1)"
[[ -n "$SHA858" ]] || fail "test 858: no hunk for untracked symlink"
if "$GIT_HUNK" restore "$SHA858" > /dev/null 2>/dev/null; then
    fail "test 858: expected exit 1 without --force for untracked symlink"
fi
[[ -L mylink858.txt ]] || fail "test 858: symlink should still exist without --force"
"$GIT_HUNK" restore --force "$SHA858" > /dev/null
[[ ! -e mylink858.txt ]] \
    || fail "test 858: untracked symlink should be deleted after --force restore"
pass "test 858: restore untracked symlink requires --force"

# ============================================================================
# Test 859: untracked symlink stash --all -u roundtrip preserves symlink
# ============================================================================
new_repo
ln -s gamma.txt newlink859.txt

"$GIT_HUNK" stash --all -u > /dev/null
[[ ! -e newlink859.txt ]] \
    || fail "test 859: symlink should be gone after stash --all -u"
"$GIT_HUNK" stash pop > /dev/null 2>/dev/null
[[ -L newlink859.txt ]] \
    || fail "test 859: symlink should be restored as symlink after pop"
TARGET859="$(readlink newlink859.txt)"
[[ "$TARGET859" == "gamma.txt" ]] \
    || fail "test 859: expected target 'gamma.txt' after pop, got '$TARGET859'"
pass "test 859: untracked symlink stash --all -u roundtrip preserves symlink"

# ============================================================================
# Test 860: regular files do NOT get @ suffix in list output
# ============================================================================
new_repo
sed -i.bak '1s/.*/Changed alpha./' alpha.txt

FILE860="$("$GIT_HUNK" list --porcelain --oneline 2>/dev/null | head -1 | cut -f2)"
[[ "$FILE860" == "alpha.txt" ]] \
    || fail "test 860: regular file should not have @ suffix, got '$FILE860'"
pass "test 860: regular files do not get @ suffix"

# ============================================================================
# Test 861: human-mode list shows @ suffix for symlinks
# ============================================================================
new_repo
ln -s alpha.txt mylink861.txt
git add mylink861.txt && git commit -q -m "add symlink"
ln -sf beta.txt mylink861.txt

HUMAN861="$("$GIT_HUNK" list --no-color --oneline 2>/dev/null | grep "mylink861" || true)"
[[ -n "$HUMAN861" ]] || fail "test 861: symlink not in human list"
echo "$HUMAN861" | grep -q "mylink861.txt@" \
    || fail "test 861: human list should show @ suffix, got '$HUMAN861'"
pass "test 861: human-mode list shows @ suffix for symlinks"

# ============================================================================
# T20 — Typechange support (file replaced by symlink)
# ============================================================================

# ============================================================================
# Test 870: typechange (file → symlink) both hunks can be staged together
# ============================================================================
new_repo
echo "content" > target870.txt
git add target870.txt && git commit -q -m "add target"
rm target870.txt && ln -s alpha.txt target870.txt

COUNT870="$("$GIT_HUNK" count --file target870.txt)"
[[ "$COUNT870" == "2" ]] \
    || fail "test 870: expected 2 hunks for typechange, got '$COUNT870'"
"$GIT_HUNK" add --all --file target870.txt > /dev/null
STATUS870="$(git status --porcelain target870.txt)"
[[ "$STATUS870" == "T  target870.txt" ]] \
    || fail "test 870: expected typechange staged, got '$STATUS870'"
pass "test 870: typechange (file → symlink) both hunks staged together"

# ============================================================================
# Test 871: typechange can be staged and then unstaged (reset roundtrip)
# ============================================================================
new_repo
echo "content" > target871.txt
git add target871.txt && git commit -q -m "add target"
rm target871.txt && ln -s alpha.txt target871.txt

"$GIT_HUNK" add --all --file target871.txt > /dev/null
"$GIT_HUNK" reset --all --file target871.txt > /dev/null
STATUS871="$(git diff --cached --name-only)"
if echo "$STATUS871" | grep -q "target871.txt"; then
    fail "test 871: typechange should be unstaged after reset, got '$STATUS871'"
fi
pass "test 871: typechange add + reset roundtrip"

# ============================================================================
# Test 872: typechange can be committed
# ============================================================================
new_repo
echo "content" > target872.txt
git add target872.txt && git commit -q -m "add target"
rm target872.txt && ln -s alpha.txt target872.txt

"$GIT_HUNK" commit --all --file target872.txt -m "typechange commit" > /dev/null
STATUS872="$(git status --porcelain)"
[[ -z "$STATUS872" ]] \
    || fail "test 872: expected clean status after typechange commit, got '$STATUS872'"
MODE872="$(git ls-files -s target872.txt | awk '{print $1}')"
[[ "$MODE872" == "120000" ]] \
    || fail "test 872: expected mode 120000 after commit, got '$MODE872'"
pass "test 872: typechange can be committed"

# ============================================================================
# Test 873: typechange by explicit SHAs (both hunks specified)
# ============================================================================
new_repo
echo "content" > target873.txt
git add target873.txt && git commit -q -m "add target"
rm target873.txt && ln -s alpha.txt target873.txt

SHAS873="$("$GIT_HUNK" list --porcelain --oneline --file target873.txt 2>/dev/null)"
SHA873_1="$(echo "$SHAS873" | head -1 | cut -f1)"
SHA873_2="$(echo "$SHAS873" | tail -1 | cut -f1)"
[[ -n "$SHA873_1" && -n "$SHA873_2" ]] || fail "test 873: couldn't get both typechange SHAs"
"$GIT_HUNK" add "$SHA873_1" "$SHA873_2" > /dev/null
STATUS873="$(git status --porcelain target873.txt)"
[[ "$STATUS873" == "T  target873.txt" ]] \
    || fail "test 873: expected typechange staged via explicit SHAs, got '$STATUS873'"
pass "test 873: typechange by explicit SHAs"

# ============================================================================
# Test 874: typechange alongside normal changes
# ============================================================================
new_repo
echo "content" > target874.txt
git add target874.txt && git commit -q -m "add target"
rm target874.txt && ln -s alpha.txt target874.txt
sed -i.bak '1s/.*/Changed beta./' beta.txt

"$GIT_HUNK" add --all > /dev/null
STAGED874="$(git diff --cached --name-only | sort)"
echo "$STAGED874" | grep -q "beta.txt" \
    || fail "test 874: beta.txt should be staged"
echo "$STAGED874" | grep -q "target874.txt" \
    || fail "test 874: target874.txt should be staged"
pass "test 874: typechange alongside normal changes"

report_results
