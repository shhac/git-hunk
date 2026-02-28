#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 23: check with valid hashes exits 0 (silent success)
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

SHAS23="$("$GIT_HUNK" list --porcelain --oneline)"
SHA23A="$(echo "$SHAS23" | grep "alpha.txt" | head -1 | cut -f1)"
SHA23B="$(echo "$SHAS23" | grep "beta.txt" | head -1 | cut -f1)"
[[ -n "$SHA23A" && -n "$SHA23B" ]] || fail "test 23: couldn't find both hunks"
OUT23="$("$GIT_HUNK" check "$SHA23A" "$SHA23B" 2>/dev/null)"
[[ -z "$OUT23" ]] || fail "test 23: expected no stdout on success, got '$OUT23'"
pass "test 23: check with valid hashes exits 0"

# ============================================================================
# Test 24: check with stale hash exits 1
# ============================================================================
new_repo
if OUT24="$("$GIT_HUNK" check --no-color "deadbeef" 2>/dev/null)"; then
    fail "test 24: expected exit 1, got 0"
fi
echo "$OUT24" | grep -q "stale" || fail "test 24: expected 'stale' in output, got '$OUT24'"
pass "test 24: check with stale hash exits 1"

# ============================================================================
# Test 25: check --exclusive with exact set exits 0
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

ALL_ALPHA="$("$GIT_HUNK" list --porcelain --oneline --file alpha.txt | cut -f1)"
[[ -n "$ALL_ALPHA" ]] || fail "test 25: no alpha.txt hunks found"
# shellcheck disable=SC2086
"$GIT_HUNK" check --exclusive --file alpha.txt $ALL_ALPHA > /dev/null 2>/dev/null
pass "test 25: check --exclusive with exact set exits 0"

# ============================================================================
# Test 26: check --exclusive with extra hunks exits 1
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

SHA26="$("$GIT_HUNK" list --porcelain --oneline | grep "alpha.txt" | head -1 | cut -f1)"
if OUT26="$("$GIT_HUNK" check --no-color --exclusive "$SHA26" 2>/dev/null)"; then
    fail "test 26: expected exit 1 for exclusive with extras"
fi
echo "$OUT26" | grep -q "unexpected" || fail "test 26: expected 'unexpected' in output, got '$OUT26'"
pass "test 26: check --exclusive with extra hunks exits 1"

# ============================================================================
# Test 27: check --porcelain reports both ok and stale entries
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA27="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
if PORC27="$("$GIT_HUNK" check --porcelain "$SHA27" "deadbeef" 2>/dev/null)"; then
    fail "test 27: expected exit 1"
fi
echo "$PORC27" | grep -qE '^ok	' || fail "test 27: expected 'ok' line in porcelain, got '$PORC27'"
echo "$PORC27" | grep -qE '^stale	' || fail "test 27: expected 'stale' line in porcelain, got '$PORC27'"
pass "test 27: check --porcelain reports all entries"

# ============================================================================
# Test 28: check rejects line specs
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA28="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
if "$GIT_HUNK" check "${SHA28}:1-3" > /dev/null 2>/dev/null; then
    fail "test 28: expected exit 1 for line spec"
fi
pass "test 28: check rejects line specs"

# ============================================================================
# Test 36: check --staged validates staged hashes
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt

SHA36="$("$GIT_HUNK" list --porcelain --oneline | head -1 | cut -f1)"
"$GIT_HUNK" add "$SHA36" > /dev/null 2>/dev/null
STAGED_SHA36="$("$GIT_HUNK" list --staged --porcelain --oneline | head -1 | cut -f1)"
"$GIT_HUNK" check --staged "$STAGED_SHA36"
[[ $? -eq 0 ]] || fail "test 36: check --staged should exit 0 for valid staged hash"
pass "test 36: check --staged validates staged hashes"

# ============================================================================
# Test 37: check --exclusive --porcelain shows unexpected entries
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
sed -i '' '1s/.*/Changed beta./' beta.txt

ALL_SHAS37="$("$GIT_HUNK" list --porcelain --oneline | cut -f1)"
FIRST_SHA37="$(echo "$ALL_SHAS37" | head -1)"
TOTAL37="$(echo "$ALL_SHAS37" | wc -l | tr -d ' ')"
if [[ "$TOTAL37" -gt 1 ]]; then
    OUT37="$("$GIT_HUNK" check --porcelain --exclusive "$FIRST_SHA37" 2>/dev/null || true)"
    echo "$OUT37" | grep -q "^unexpected" \
        || fail "test 37: expected 'unexpected' in porcelain exclusive output, got: '$OUT37'"
    pass "test 37: check --exclusive --porcelain shows unexpected entries"
else
    "$GIT_HUNK" check --porcelain --exclusive "$FIRST_SHA37" > /dev/null 2>/dev/null
    pass "test 37: check --exclusive --porcelain (single hunk, trivial pass)"
fi

# ============================================================================
# Test 62: check validates untracked file hash
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

SHA62="$("$GIT_HUNK" list --porcelain --oneline --file untracked.txt | head -1 | cut -f1)"
[[ -n "$SHA62" ]] || fail "test 62: no untracked hunk found"
"$GIT_HUNK" check "$SHA62" 2>/dev/null
[[ $? -eq 0 ]] || fail "test 62: check should exit 0 for valid untracked hash"
pass "test 62: check validates untracked file hash"

# ============================================================================
# Test 63: check --exclusive accounts for untracked files
# ============================================================================
new_repo
echo "untracked content" > untracked.txt

ALL_SHAS63="$("$GIT_HUNK" list --porcelain --oneline | cut -f1)"
[[ -n "$ALL_SHAS63" ]] || fail "test 63: no hunks found"
# shellcheck disable=SC2086
"$GIT_HUNK" check --exclusive $ALL_SHAS63 > /dev/null 2>/dev/null
[[ $? -eq 0 ]] || fail "test 63: check --exclusive should pass with all hashes including untracked"
pass "test 63: check --exclusive accounts for untracked"

# ============================================================================
# Test 64: check --tracked-only ignores untracked hashes
# ============================================================================
new_repo
sed -i '' '1s/.*/Changed alpha./' alpha.txt
echo "untracked content" > untracked.txt

UT_SHA64="$("$GIT_HUNK" list --untracked-only --porcelain --oneline | head -1 | cut -f1)"
[[ -n "$UT_SHA64" ]] || fail "test 64: no untracked hunk found"
if "$GIT_HUNK" check --tracked-only "$UT_SHA64" 2>/dev/null; then
    fail "test 64: untracked hash should be stale with --tracked-only"
fi
pass "test 64: check --tracked-only ignores untracked hashes"

report_results
