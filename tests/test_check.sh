#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 300: check with valid hashes exits 0 (silent success)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

SHAS300="$("$GIT_HUNK" list --porcelain --oneline)"
SHA300A="$(echo "$SHAS300" | grep "alpha.txt" | head -1 | cut -f1)"
SHA300B="$(echo "$SHAS300" | grep "beta.txt" | head -1 | cut -f1)"
[[ -n "$SHA300A" && -n "$SHA300B" ]] || fail "test 300: couldn't find both hunks"
OUT300="$("$GIT_HUNK" check "$SHA300A" "$SHA300B" 2>/dev/null)"
[[ -z "$OUT300" ]] || fail "test 300: expected no stdout on success, got '$OUT300'"
pass "test 300: check with valid hashes exits 0"

# ============================================================================
# Test 301: check with stale hash exits 1
# ============================================================================
new_repo
if OUT301="$("$GIT_HUNK" check --no-color "deadbeef" 2>/dev/null)"; then
    fail "test 301: expected exit 1, got 0"
fi
echo "$OUT301" | grep -q "stale" || fail "test 301: expected 'stale' in output, got '$OUT301'"
pass "test 301: check with stale hash exits 1"

# ============================================================================
# Test 302: check --exclusive with exact set exits 0
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

ALL_ALPHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | cut -f1)"
[[ -n "$ALL_ALPHA" ]] || fail "test 302: no alpha.txt hunks found"
# shellcheck disable=SC2086
"$GIT_HUNK" check --exclusive --file alpha.txt $ALL_ALPHA > /dev/null 2>/dev/null
pass "test 302: check --exclusive with exact set exits 0"

# ============================================================================
# Test 303: check --exclusive with extra hunks exits 1
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

SHA303="$("$GIT_HUNK" list --porcelain --oneline | grep "alpha.txt" | head -1 | cut -f1)"
if OUT303="$("$GIT_HUNK" check --no-color --exclusive "$SHA303" 2>/dev/null)"; then
    fail "test 303: expected exit 1 for exclusive with extras"
fi
echo "$OUT303" | grep -q "unexpected" || fail "test 303: expected 'unexpected' in output, got '$OUT303'"
pass "test 303: check --exclusive with extra hunks exits 1"

# ============================================================================
# Test 304: check --porcelain reports both ok and stale entries
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA304="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
if PORC304="$("$GIT_HUNK" check --porcelain "$SHA304" "deadbeef" 2>/dev/null)"; then
    fail "test 304: expected exit 1"
fi
echo "$PORC304" | grep -qE '^ok	' || fail "test 304: expected 'ok' line in porcelain, got '$PORC304'"
echo "$PORC304" | grep -qE '^stale	' || fail "test 304: expected 'stale' line in porcelain, got '$PORC304'"
pass "test 304: check --porcelain reports all entries"

# ============================================================================
# Test 305: check rejects line specs
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA305="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
if "$GIT_HUNK" check "${SHA305}:1-3" > /dev/null 2>/dev/null; then
    fail "test 305: expected exit 1 for line spec"
fi
pass "test 305: check rejects line specs"

# ============================================================================
# Test 306: check --staged validates staged hashes
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA306="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
"$GIT_HUNK" add "$SHA306" > /dev/null 2>/dev/null
STAGED_SHA306="$("$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
"$GIT_HUNK" check --staged "$STAGED_SHA306"
[[ $? -eq 0 ]] || fail "test 306: check --staged should exit 0 for valid staged hash"
pass "test 306: check --staged validates staged hashes"

# ============================================================================
# Test 307: check --exclusive --porcelain shows unexpected entries
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

ALL_SHAS307="$("$GIT_HUNK" list --porcelain --oneline | cut -f1)"
FIRST_SHA307="$(echo "$ALL_SHAS307" | head -1)"
TOTAL307="$(echo "$ALL_SHAS307" | wc -l | tr -d ' ')"
if [[ "$TOTAL307" -gt 1 ]]; then
    OUT307="$("$GIT_HUNK" check --porcelain --exclusive "$FIRST_SHA307" 2>/dev/null || true)"
    echo "$OUT307" | grep -q "^unexpected" \
        || fail "test 307: expected 'unexpected' in porcelain exclusive output, got: '$OUT307'"
    pass "test 307: check --exclusive --porcelain shows unexpected entries"
else
    "$GIT_HUNK" check --porcelain --exclusive "$FIRST_SHA307" > /dev/null 2>/dev/null
    pass "test 307: check --exclusive --porcelain (single hunk, trivial pass)"
fi

# ============================================================================
# Test 308: check validates untracked file hash
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA308="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA308" ]] || fail "test 308: no untracked hunk found"
"$GIT_HUNK" check "$SHA308" 2>/dev/null
[[ $? -eq 0 ]] || fail "test 308: check should exit 0 for valid untracked hash"
pass "test 308: check validates untracked file hash"

# ============================================================================
# Test 309: check --exclusive accounts for untracked files
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

ALL_SHAS309="$("$GIT_HUNK" list --porcelain --oneline | cut -f1)"
[[ -n "$ALL_SHAS309" ]] || fail "test 309: no hunks found"
# shellcheck disable=SC2086
"$GIT_HUNK" check --exclusive $ALL_SHAS309 > /dev/null 2>/dev/null
[[ $? -eq 0 ]] || fail "test 309: check --exclusive should pass with all hashes including untracked"
pass "test 309: check --exclusive accounts for untracked"

# ============================================================================
# Test 310: check --tracked-only ignores untracked hashes
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

UT_SHA310="$("$GIT_HUNK" list --untracked-only --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$UT_SHA310" ]] || fail "test 310: no untracked hunk found"
if "$GIT_HUNK" check --tracked-only "$UT_SHA310" 2>/dev/null; then
    fail "test 310: untracked hash should be stale with --tracked-only"
fi
pass "test 310: check --tracked-only ignores untracked hashes"

report_results
