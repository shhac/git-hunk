#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh" "$1"

# ============================================================================
# Test 600: global --help exits 0 and shows commands
# ============================================================================
OUT600="$("$GIT_HUNK" --help)"
echo "$OUT600" | grep -q "commands:" \
    || fail "test 600: --help should contain 'commands:'"
echo "$OUT600" | grep -q "git-hunk <command> --help" \
    || fail "test 600: --help should mention per-command help"
pass "test 600: global --help exits 0 and shows commands"

# ============================================================================
# Test 601: subcommand --help shows per-command help and exits 0
# ============================================================================
OUT601="$("$GIT_HUNK" list --help)"
echo "$OUT601" | grep -q "USAGE" \
    || fail "test 601: list --help should contain 'USAGE'"
echo "$OUT601" | grep -q "\-\-staged" \
    || fail "test 601: list --help should describe --staged"
echo "$OUT601" | grep -q "EXAMPLES" \
    || fail "test 601: list --help should contain 'EXAMPLES'"
pass "test 601: list --help shows per-command help"

# ============================================================================
# Test 602: help <command> shows same per-command help
# ============================================================================
OUT602="$("$GIT_HUNK" help stash)"
echo "$OUT602" | grep -q "USAGE" \
    || fail "test 602: help stash should contain 'USAGE'"
echo "$OUT602" | grep -q "pop" \
    || fail "test 602: help stash should describe pop subcommand"
pass "test 602: help <command> shows per-command help"

# ============================================================================
# Test 603: help <unknown> exits 1
# ============================================================================
if "$GIT_HUNK" help badcmd > /dev/null 2>/dev/null; then
    fail "test 603: expected exit 1 for help badcmd"
fi
pass "test 603: help <unknown> exits 1"

# ============================================================================
# Test 604: all commands support --help
# ============================================================================
for CMD in list diff add reset restore count check stash; do
    OUT604="$("$GIT_HUNK" "$CMD" --help)"
    echo "$OUT604" | grep -q "USAGE" \
        || fail "test 604: $CMD --help should contain 'USAGE'"
    echo "$OUT604" | grep -q "git-hunk $CMD" \
        || fail "test 604: $CMD --help should mention 'git-hunk $CMD'"
done
pass "test 604: all commands support --help"

# ============================================================================
# Test 605: man page lists all commands from --help
# ============================================================================
if [[ -f "$MANPAGE" ]]; then
    HELP_CMDS="$("$GIT_HUNK" --help | sed -n '/^commands:/,/^$/p' | grep '^ ' | awk '{print $1}')"
    for CMD in $HELP_CMDS; do
        grep -q "^\.B $CMD" "$MANPAGE" \
            || fail "test 605: man page missing command '$CMD'"
    done
    pass "test 605: man page lists all commands from --help"
else
    echo "SKIP: test 605: man page not found at $MANPAGE"
fi

report_results
