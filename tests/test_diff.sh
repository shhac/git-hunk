#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 900: diff tracked file displays diff content
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA900="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$SHA900" ]] || fail "test 900: no unstaged hunk found"
OUT900="$("$GIT_HUNK" diff --no-color "$SHA900")"
echo "$OUT900" | grep -q '@@' || fail "test 900: diff output missing @@ header, got: '$OUT900'"
echo "$OUT900" | grep -q 'Changed alpha' || fail "test 900: diff output missing changed content, got: '$OUT900'"
pass "test 900: diff tracked file displays diff content"

# ============================================================================
# Test 901: diff untracked file displays new file header and content
# ============================================================================
new_repo
echo "unique_untracked_content_901" > show_untracked.txt

SHA901="$("$GIT_HUNK" list --porcelain --oneline --file show_untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA901" ]] || fail "test 901: no untracked hunk found"
OUT901="$("$GIT_HUNK" diff --no-color "$SHA901")"
echo "$OUT901" | grep -qE '(new file|@@)' || fail "test 901: diff output missing header, got: '$OUT901'"
echo "$OUT901" | grep -q 'unique_untracked_content_901' || fail "test 901: diff output missing file content, got: '$OUT901'"
pass "test 901: diff untracked file displays new file header and content"

# ============================================================================
# Test 902: diff --no-color omits ANSI escape codes
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA902="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
OUT902="$("$GIT_HUNK" diff --no-color "$SHA902")"
echo "$OUT902" | grep -q $'\033' && fail "test 902: diff --no-color output contains ANSI escape codes" || true
pass "test 902: diff --no-color omits ANSI escape codes"

# ============================================================================
# Test 903: diff multiple SHAs displays content from both hunks
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

SHAS903="$("$GIT_HUNK" list --porcelain --oneline)"
SHA903A="$(echo "$SHAS903" | grep "alpha.txt" | head -1 | cut -f1)"
SHA903B="$(echo "$SHAS903" | grep "beta.txt" | head -1 | cut -f1)"
[[ -n "$SHA903A" && -n "$SHA903B" ]] || fail "test 903: couldn't find both hunks"
OUT903="$("$GIT_HUNK" diff --no-color "$SHA903A" "$SHA903B")"
echo "$OUT903" | grep -q 'Changed alpha' || fail "test 903: alpha content missing from diff output"
echo "$OUT903" | grep -q 'Changed beta' || fail "test 903: beta content missing from diff output"
pass "test 903: diff multiple SHAs displays content from both hunks"

# ============================================================================
# Test 904: diff diff header includes filename
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA904="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
OUT904="$("$GIT_HUNK" diff --no-color "$SHA904")"
echo "$OUT904" | grep -q 'alpha.txt' || fail "test 904: diff output missing filename in diff header, got: '$OUT904'"
pass "test 904: diff diff header includes filename"

# ============================================================================
# Test 905: diff --porcelain outputs tab-separated metadata
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA905="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
OUT905="$("$GIT_HUNK" diff --porcelain "$SHA905")"
[[ -n "$OUT905" ]] || fail "test 905: diff --porcelain produced no output"
FIRST905="$(echo "$OUT905" | head -1)"
echo "$FIRST905" | grep -q $'\t' || fail "test 905: first line has no tabs (not tab-separated), got: '$FIRST905'"
FIELD1_905="$(echo "$FIRST905" | cut -f1)"
[[ ${#FIELD1_905} -eq 7 ]] || fail "test 905: first field not 7-char SHA, got '$FIELD1_905'"
echo "$FIRST905" | grep -q 'alpha.txt' || fail "test 905: filename missing from porcelain header"
pass "test 905: diff --porcelain outputs tab-separated metadata"

# ============================================================================
# Test 906: diff --porcelain output includes raw diff content
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA906="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
OUT906="$("$GIT_HUNK" diff --porcelain "$SHA906")"
echo "$OUT906" | grep -q '@@' || fail "test 906: porcelain output missing @@ diff marker, got: '$OUT906'"
echo "$OUT906" | grep -q 'Changed alpha' || fail "test 906: porcelain output missing changed content"
pass "test 906: diff --porcelain includes raw diff content"

# ============================================================================
# Test 907: diff --porcelain for untracked file includes filename
# ============================================================================
new_repo
echo "porcelain untracked 907" > untracked_porc.txt

SHA907="$("$GIT_HUNK" list --porcelain --oneline --file untracked_porc.txt | head -1 | cut -f1)"
OUT907="$("$GIT_HUNK" diff --porcelain "$SHA907")"
echo "$OUT907" | grep -q 'untracked_porc.txt' || fail "test 907: filename missing from porcelain output"
echo "$OUT907" | grep -q $'\t' || fail "test 907: porcelain output has no tabs"
pass "test 907: diff --porcelain for untracked file includes filename"

# ============================================================================
# Test 908: diff --staged shows staged changes for modified file
# ============================================================================
new_repo
sed -i '' '1s/.*/Staged change 908./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null

STAGED_SHA908="$("$GIT_HUNK" list --staged --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
[[ -n "$STAGED_SHA908" ]] || fail "test 908: no staged hunk found"
OUT908="$("$GIT_HUNK" diff --no-color "$STAGED_SHA908" --staged)"
echo "$OUT908" | grep -q '@@' || fail "test 908: diff --staged missing @@ header"
echo "$OUT908" | grep -q 'Staged change 908' || fail "test 908: diff --staged missing staged content"
pass "test 908: diff --staged shows staged changes for modified file"

# ============================================================================
# Test 909: diff --staged shows deleted file
# ============================================================================
new_repo
git rm alpha.txt -q

STAGED_SHA909="$("$GIT_HUNK" list --staged --porcelain --oneline | grep alpha.txt | head -1 | cut -f1)"
[[ -n "$STAGED_SHA909" ]] || fail "test 909: no staged hunk for deleted file"
OUT909="$("$GIT_HUNK" diff --no-color "$STAGED_SHA909" --staged)"
echo "$OUT909" | grep -q 'deleted file mode' || fail "test 909: diff --staged missing 'deleted file mode', got: '$OUT909'"
pass "test 909: diff --staged shows deleted file"

# ============================================================================
# Test 910: diff --porcelain --staged shows staged hunk metadata
# ============================================================================
new_repo
sed -i '' '1s/.*/Staged for porcelain 910./' alpha.txt
"$GIT_HUNK" add --all > /dev/null 2>/dev/null

STAGED_SHA910="$("$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$STAGED_SHA910" ]] || fail "test 910: no staged hunk found"
OUT910="$("$GIT_HUNK" diff --porcelain --staged "$STAGED_SHA910")"
[[ -n "$OUT910" ]] || fail "test 910: diff --porcelain --staged produced no output"
echo "$OUT910" | grep -q $'\t' || fail "test 910: diff --porcelain --staged output has no tabs"
echo "$OUT910" | grep -q '@@' || fail "test 910: diff --porcelain --staged missing diff content"
pass "test 910: diff --porcelain --staged shows staged hunk metadata"

# ============================================================================
# Test 911: diff SHA:1 displays line numbers and > marker for selected line
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA911="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
OUT911="$("$GIT_HUNK" diff --no-color "${SHA911}:1")"
echo "$OUT911" | grep -q '>' || fail "test 911: line spec output missing '>' marker for selected line"
echo "$OUT911" | grep -qE '[0-9]+:' || fail "test 911: line spec output missing line numbers"
pass "test 911: diff SHA:1 displays line numbers and > marker"

# ============================================================================
# Test 912: diff SHA:1-3 marks multiple lines with > markers
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA912="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | head -1 | cut -f1)"
OUT912="$("$GIT_HUNK" diff --no-color "${SHA912}:1-3")"
echo "$OUT912" | grep -q '>' || fail "test 912: multi-range line spec missing '>' marker"
echo "$OUT912" | grep -qE '[0-9]+:' || fail "test 912: multi-range line spec missing line numbers"
pass "test 912: diff SHA:1-3 marks multiple lines with > markers"

# ============================================================================
# Test 913: diff SHA:1 on empty file reports empty file message
# ============================================================================
new_repo
touch empty_show.txt

SHA913="$("$GIT_HUNK" list --porcelain --oneline | grep empty_show.txt | cut -f1)"
[[ -n "$SHA913" ]] || fail "test 913: no SHA for empty file"
OUT913="$("$GIT_HUNK" diff "${SHA913}:1" 2>&1 || true)"
echo "$OUT913" | grep -qi 'empty' || fail "test 913: expected 'empty' in output for line spec on empty file, got: '$OUT913'"
pass "test 913: diff SHA:1 on empty file reports empty file message"

# ============================================================================
# Test 914: diff --tracked-only excludes untracked SHA
# ============================================================================
new_repo
echo "untracked content 914" > untracked_tracked.txt

SHA914="$("$GIT_HUNK" list --untracked-only --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$SHA914" ]] || fail "test 914: no untracked hunk found"
if "$GIT_HUNK" diff --no-color --tracked-only "$SHA914" > /dev/null 2>/dev/null; then
    fail "test 914: diff --tracked-only should not find untracked SHA"
fi
pass "test 914: diff --tracked-only excludes untracked SHA"

# ============================================================================
# Test 915: diff --untracked-only excludes tracked SHA
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA915="$("$GIT_HUNK" list --tracked-only --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$SHA915" ]] || fail "test 915: no tracked hunk found"
if "$GIT_HUNK" diff --no-color --untracked-only "$SHA915" > /dev/null 2>/dev/null; then
    fail "test 915: diff --untracked-only should not find tracked SHA"
fi
pass "test 915: diff --untracked-only excludes tracked SHA"

# ============================================================================
# Test 916: diff invalid SHA exits 1 with "no hunk" error
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

if OUT916="$("$GIT_HUNK" diff --no-color "aaaa1111" 2>&1)"; then
    fail "test 916: expected exit 1 for non-matching SHA, got exit 0"
fi
echo "$OUT916" | grep -qi 'no hunk' || fail "test 916: expected 'no hunk' in error, got: '$OUT916'"
pass "test 916: diff invalid SHA exits 1 with error message"

# ============================================================================
# Test 917: diff SHA too short (< 4 chars) exits 1 with error
# ============================================================================
new_repo
if OUT917="$("$GIT_HUNK" diff --no-color "abc" 2>&1)"; then
    fail "test 917: expected exit 1 for too-short SHA"
fi
echo "$OUT917" | grep -qi 'too short' || fail "test 917: expected 'too short' in error, got: '$OUT917'"
pass "test 917: diff SHA too short exits 1 with error"

# ============================================================================
# Test 918: diff with no SHA exits 1
# ============================================================================
new_repo
if "$GIT_HUNK" diff > /dev/null 2>/dev/null; then
    fail "test 918: expected exit 1 when no SHA provided"
fi
pass "test 918: diff with no SHA exits 1"

# ============================================================================
# Test 919: diff with default unified includes surrounding context
# ============================================================================
new_repo
cat > context_test.txt <<'EOF'
line 1
line 2
line 3
line 4 to change
line 5
line 6
line 7
EOF
git add context_test.txt && git commit -m "context test setup" -q
sed -i '' 's/line 4 to change/line 4 changed/' context_test.txt

# List and diff with matching unified level (SHA is context-dependent)
SHA919="$("$GIT_HUNK" list --porcelain --oneline --file context_test.txt | head -1 | cut -f1)"
[[ -n "$SHA919" ]] || fail "test 919: no hunk found for context_test.txt"
OUT919="$("$GIT_HUNK" diff --no-color "$SHA919")"
# 'line 3' is a context line 1 line before the change — should appear with default context
echo "$OUT919" | grep -q 'line 3' || fail "test 919: expected 'line 3' as context in default diff output"
# 'line 4 changed' is the actual changed content — must always be present
echo "$OUT919" | grep -q 'line 4 changed' || fail "test 919: diff output missing changed content"
pass "test 919: diff with default unified includes surrounding context"

# ============================================================================
# Test 920: diff --unified 0 excludes context lines
# ============================================================================
new_repo
cat > context_test2.txt <<'EOF'
line 1
line 2
line 3
line 4 to change
line 5
line 6
line 7
EOF
git add context_test2.txt && git commit -m "context test2 setup" -q
sed -i '' 's/line 4 to change/line 4 changed/' context_test2.txt

# Must use --unified 0 when listing to get the SHA for a -U0 diff
SHA920="$("$GIT_HUNK" list --porcelain --oneline --unified 0 --file context_test2.txt | head -1 | cut -f1)"
[[ -n "$SHA920" ]] || fail "test 920: no hunk found with --unified 0"
OUT920="$("$GIT_HUNK" diff --no-color "$SHA920" --unified 0)"
# 'line 3' as a context line (space prefix) should NOT appear with -U0
# (note: 'line 3' may appear in the @@ header, so anchor to start of line with space)
echo "$OUT920" | grep -q '^ line 3' && fail "test 920: -U0 should not include 'line 3' as context" || true
# The changed content must still be present
echo "$OUT920" | grep -q 'line 4 changed' || fail "test 920: diff -U0 missing changed content"
pass "test 920: diff --unified 0 excludes context lines"

report_results
