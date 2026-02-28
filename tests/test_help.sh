#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 52: global --help exits 0 and shows commands
# ============================================================================
OUT52="$("$GIT_HUNK" --help)"
echo "$OUT52" | grep -q "commands:" \
    || fail "test 52: --help should contain 'commands:'"
echo "$OUT52" | grep -q "git-hunk <command> --help" \
    || fail "test 52: --help should mention per-command help"
pass "test 52: global --help exits 0 and shows commands"

# ============================================================================
# Test 53: subcommand --help shows per-command help and exits 0
# ============================================================================
OUT53="$("$GIT_HUNK" list --help)"
echo "$OUT53" | grep -q "USAGE" \
    || fail "test 53: list --help should contain 'USAGE'"
echo "$OUT53" | grep -q "\-\-staged" \
    || fail "test 53: list --help should describe --staged"
echo "$OUT53" | grep -q "EXAMPLES" \
    || fail "test 53: list --help should contain 'EXAMPLES'"
pass "test 53: list --help shows per-command help"

# ============================================================================
# Test 54: help <command> shows same per-command help
# ============================================================================
OUT54="$("$GIT_HUNK" help stash)"
echo "$OUT54" | grep -q "USAGE" \
    || fail "test 54: help stash should contain 'USAGE'"
echo "$OUT54" | grep -q "\-\-pop" \
    || fail "test 54: help stash should describe --pop"
pass "test 54: help <command> shows per-command help"

# ============================================================================
# Test 55: help <unknown> exits 1
# ============================================================================
if "$GIT_HUNK" help badcmd > /dev/null 2>/dev/null; then
    fail "test 55: expected exit 1 for help badcmd"
fi
pass "test 55: help <unknown> exits 1"

# ============================================================================
# Test 56: all commands support --help
# ============================================================================
for CMD in list show add remove discard count check stash; do
    OUT56="$("$GIT_HUNK" "$CMD" --help)"
    echo "$OUT56" | grep -q "USAGE" \
        || fail "test 56: $CMD --help should contain 'USAGE'"
    echo "$OUT56" | grep -q "git-hunk $CMD" \
        || fail "test 56: $CMD --help should mention 'git-hunk $CMD'"
done
pass "test 56: all commands support --help"

# ============================================================================
# Test 57: man page lists all commands from --help
# ============================================================================
if [[ -f "$MANPAGE" ]]; then
    HELP_CMDS="$("$GIT_HUNK" --help | sed -n '/^commands:/,/^$/p' | grep '^ ' | awk '{print $1}')"
    for CMD in $HELP_CMDS; do
        grep -q "^\.B $CMD" "$MANPAGE" \
            || fail "test 57: man page missing command '$CMD'"
    done
    pass "test 57: man page lists all commands from --help"
else
    echo "SKIP: test 57: man page not found at $MANPAGE"
fi

report_results
