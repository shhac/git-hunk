#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# Interactive zsh completion tests, driven through a pty (completion-harness.zsh).
#
# Regression focus: hunk hashes sharing a prefix must keep completing — both
# when git-hunk is invoked directly (zsh compsys path, _git-hunk) and through
# git's own git-completion.zsh wrapper (`git hunk <TAB>`, bridged by
# _git_hunk). The wrapper's dispatch context breaks _describe/_arguments
# option matching for non-empty words, which once made `git hunk add 9<TAB>`
# complete nothing while `git hunk add <TAB>` worked.

COMPLETIONS_DIR="$SCRIPT_DIR/../completions"
ZSH_HARNESS="$SCRIPT_DIR/completion-harness.zsh"

if ! command -v zsh >/dev/null 2>&1 || ! zsh -c 'zmodload zsh/zpty' 2>/dev/null; then
    echo "SKIP: zsh with zpty not available; skipping completion tests"
    report_results
fi

# Locate git's own zsh completion wrapper for the `git hunk <TAB>` tests.
# Homebrew installs it as _git; other layouts ship git-completion.zsh next
# to git-completion.bash, which is what the wrapper sources.
WRAPPER_DIR=""
BREW_GIT="$(brew --prefix 2>/dev/null || true)/share/zsh/site-functions/_git"
if [[ -f "$BREW_GIT" ]] && grep -q "git-completion.bash" "$BREW_GIT" 2>/dev/null; then
    WRAPPER_DIR="$(dirname "$BREW_GIT")"
else
    for c in /usr/share/doc/git/contrib/completion \
             /Library/Developer/CommandLineTools/usr/share/git-core \
             /Applications/Xcode.app/Contents/Developer/usr/share/git-core; do
        if [[ -f "$c/git-completion.zsh" && -f "$c/git-completion.bash" ]]; then
            WRAPPER_DIR="$(mktemp -d)"
            cp "$c/git-completion.zsh" "$WRAPPER_DIR/_git"
            cp "$c/git-completion.bash" "$WRAPPER_DIR/"
            break
        fi
    done
fi

# The completion functions invoke `git-hunk` by name.
export PATH="$(dirname "$GIT_HUNK"):$PATH"

OUTDIR="${COMP_TEST_OUTDIR:-$(mktemp -d)}"

# complete <tag> <input> <extra-fpath-dir-or-empty>
# Populates COMPLETED_BUFFER and COMPLETED_DISPLAY.
complete() {
    local tag="$1" input="$2" extra="$3"
    local fdirs="$COMPLETIONS_DIR"
    [[ -n "$extra" ]] && fdirs="$COMPLETIONS_DIR:$extra"
    rm -f "$OUTDIR/$tag.buf"
    zsh "$ZSH_HARNESS" "$CURRENT_REPO" "$input" "$OUTDIR/$tag.buf" "$OUTDIR/$tag.disp" "$fdirs" || true
    COMPLETED_BUFFER="$(cat "$OUTDIR/$tag.buf" 2>/dev/null || true)"
    COMPLETED_DISPLAY="$(tr -d '\r\0' < "$OUTDIR/$tag.disp" 2>/dev/null || true)"
}

# ============================================================================
# Setup: a repo whose hunk hashes are guaranteed to share prefixes. 20
# untracked one-line files give 20 hunk hashes over 16 possible first hex
# chars, so at least two share a first char (pigeonhole).
# ============================================================================
new_repo
for i in $(seq -w 0 19); do
    echo "unique content $i" > "u$i.txt"
done

ALL_SHAS="$("$GIT_HUNK" list --porcelain --oneline | cut -f1)"
[[ "$(echo "$ALL_SHAS" | wc -l | tr -d ' ')" -ge 20 ]] || fail "setup: expected >= 20 hunks"

# Shared prefix: the most frequent first hex char, and two hashes under it.
SHARED_CHAR="$(echo "$ALL_SHAS" | cut -c1 | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
SHARED_A="$(echo "$ALL_SHAS" | grep "^$SHARED_CHAR" | sed -n 1p)"
SHARED_B="$(echo "$ALL_SHAS" | grep "^$SHARED_CHAR" | sed -n 2p)"
[[ -n "$SHARED_A" && -n "$SHARED_B" ]] || fail "setup: no shared-prefix hash pair found"

# Unique prefix: shortest prefix of SHARED_A matching only itself (>= 2 chars
# since SHARED_B shares the first).
UNIQ_PREFIX=""
for len in 2 3 4 5 6 7; do
    p="$(echo "$SHARED_A" | cut -c1-"$len")"
    if [[ "$(echo "$ALL_SHAS" | grep -c "^$p")" -eq 1 ]]; then
        UNIQ_PREFIX="$p"
        break
    fi
done
[[ -n "$UNIQ_PREFIX" ]] || fail "setup: no unique prefix found for $SHARED_A"

# ============================================================================
# Test 1400: direct path -- unique hash prefix completes to the full hash
# ============================================================================
complete t1400 "git-hunk add $UNIQ_PREFIX" ""
if [[ "$COMPLETED_BUFFER" == *"git-hunk add $SHARED_A"* ]]; then
    pass "test 1400: direct unique prefix completes to full hash"
else
    fail "test 1400: expected buffer to contain 'git-hunk add $SHARED_A', got '$COMPLETED_BUFFER'"
fi

# ============================================================================
# Test 1401: direct path -- shared prefix lists all matching hashes
# ============================================================================
complete t1401 "git-hunk add $SHARED_CHAR" ""
if [[ "$COMPLETED_DISPLAY" == *"$SHARED_A"* && "$COMPLETED_DISPLAY" == *"$SHARED_B"* ]]; then
    pass "test 1401: direct shared prefix lists all matching hashes"
else
    fail "test 1401: expected display to list $SHARED_A and $SHARED_B"
fi
# Displays mirror `list --oneline`: file column and the dash-joined range
# (single-line files show "1-1"; porcelain showed separate "1  1" fields).
if [[ "$COMPLETED_DISPLAY" == *".txt"* && "$COMPLETED_DISPLAY" == *"1-1"* ]]; then
    pass "test 1401b: candidate display carries oneline file and range columns"
else
    fail "test 1401b: expected oneline-style display with file and '1-1' range"
fi

if [[ -z "$WRAPPER_DIR" ]]; then
    echo "SKIP: git-completion.zsh wrapper not found; skipping 'git hunk' wrapper tests"
else

# ============================================================================
# Test 1402: wrapper path -- unique hash prefix completes to the full hash
# (the original bug: any non-empty word completed nothing via `git hunk`)
# ============================================================================
complete t1402 "git hunk add $UNIQ_PREFIX" "$WRAPPER_DIR"
if [[ "$COMPLETED_BUFFER" == *"git hunk add $SHARED_A"* ]]; then
    pass "test 1402: wrapper unique prefix completes to full hash"
else
    fail "test 1402: expected buffer to contain 'git hunk add $SHARED_A', got '$COMPLETED_BUFFER'"
fi

# ============================================================================
# Test 1403: wrapper path -- shared prefix lists all matching hashes
# ============================================================================
complete t1403 "git hunk add $SHARED_CHAR" "$WRAPPER_DIR"
if [[ "$COMPLETED_DISPLAY" == *"$SHARED_A"* && "$COMPLETED_DISPLAY" == *"$SHARED_B"* ]]; then
    pass "test 1403: wrapper shared prefix lists all matching hashes"
else
    fail "test 1403: expected display to list $SHARED_A and $SHARED_B"
fi

# ============================================================================
# Test 1404: wrapper path -- flag prefix completes
# ============================================================================
complete t1404 "git hunk list --sta" "$WRAPPER_DIR"
if [[ "$COMPLETED_BUFFER" == *"--staged"* ]]; then
    pass "test 1404: wrapper flag prefix completes to --staged"
else
    fail "test 1404: expected buffer to contain '--staged', got '$COMPLETED_BUFFER'"
fi

fi # wrapper tests

# ============================================================================
# Test 1405: listings stay one-candidate-per-row in wide terminals
# (without compadd -l, zsh columnizes short display lines side by side)
# ============================================================================
new_repo
for f in a b c d e f; do
    echo x > "$f.txt"
done
rm -f "$OUTDIR/t1405.buf"
zsh "$ZSH_HARNESS" "$CURRENT_REPO" "git-hunk add " "$OUTDIR/t1405.buf" "$OUTDIR/t1405.disp" "$COMPLETIONS_DIR" 220 || true
DISP1405="$(perl -pe 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x00//g' "$OUTDIR/t1405.disp" 2>/dev/null || true)"
N_SHAS="$(echo "$DISP1405" | grep -cE '[0-9a-f]{7}  ' || true)"
N_DUAL="$(echo "$DISP1405" | grep -cE '([0-9a-f]{7}.*){2}' || true)"
if [[ "$N_SHAS" -ge 2 && "$N_DUAL" -eq 0 ]]; then
    pass "test 1405: wide-terminal listing keeps one candidate per row"
else
    fail "test 1405: expected >=2 candidate rows and none sharing a line (rows=$N_SHAS, shared=$N_DUAL)"
fi

report_results
