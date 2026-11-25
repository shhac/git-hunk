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
for CMD in list diff add reset restore count check stash commit; do
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

# ============================================================================
# Test 606: --version outputs git-hunk X.Y.Z format
# ============================================================================
OUT606="$("$GIT_HUNK" --version)"
echo "$OUT606" | grep -qE '^git-hunk [0-9]+\.[0-9]+\.[0-9]+$' \
    || fail "test 606: --version output format wrong, got '$OUT606'"
pass "test 606: --version outputs git-hunk X.Y.Z format"

# ============================================================================
# Test 607: -V outputs same version string as --version
# ============================================================================
OUT607="$("$GIT_HUNK" -V)"
[[ "$OUT607" == "$OUT606" ]] \
    || fail "test 607: -V output '$OUT607' differs from --version '$OUT606'"
pass "test 607: -V outputs same version string as --version"

# ============================================================================
# Test 608: --3way is rejected on commands that don't apply patches.
# Silently accepting it would mislead users into thinking it had an effect.
# ============================================================================
new_repo
echo "x" > f608.txt
git add f608.txt && git commit -q -m "c0"
echo "y" >> f608.txt
ERR608=$("$GIT_HUNK" list --3way 2>&1 || true)
echo "$ERR608" | grep -q "not supported for this subcommand" \
    || fail "test 608: list --3way should error 'not supported'; got: '$ERR608'"
ERR608B=$("$GIT_HUNK" diff --3way 2>&1 || true)
echo "$ERR608B" | grep -q "not supported for this subcommand" \
    || fail "test 608: diff --3way should error 'not supported'; got: '$ERR608B'"
ERR608C=$("$GIT_HUNK" stash --3way 2>&1 || true)
echo "$ERR608C" | grep -q "not supported for this subcommand" \
    || fail "test 608: stash --3way should error 'not supported'; got: '$ERR608C'"
pass "test 608: --3way rejected on commands that don't apply patches"

# ============================================================================
# Test 609: every command names an unknown flag rather than dumping usage
#
# `list` used to return a bare error.UnknownFlag instead of routing through
# args.zig's unknownFlag() helper, so it printed the whole usage banner and
# never said which flag was wrong. Covering all eight commands keeps the set
# consistent as new ones are added.
# ============================================================================
new_repo
for CMD in list count add reset diff check restore stash commit; do
    ERR609="$("$GIT_HUNK" "$CMD" --definitely-not-a-flag 2>&1 || true)"
    echo "$ERR609" | grep -q "unknown flag '--definitely-not-a-flag'" \
        || fail "test 609: $CMD should name the unknown flag; got: '$(echo "$ERR609" | head -1)'"
done
pass "test 609: all commands name an unknown flag"

# ============================================================================
# Test 610: an unknown command's error comes after the usage, with the
# command git's own word maps to. `git hunk stage` used to print the error
# first and bury it under the usage.
# ============================================================================
new_repo
EC610=0
OUT610="$("$GIT_HUNK" stage 2>&1)" || EC610=$?
[[ "$EC610" -eq 1 ]] || fail "test 610: unknown command should exit 1, got $EC610"
[[ "$(echo "$OUT610" | tail -2)" == "error: unknown command 'stage'
hint: did you mean 'git hunk add'?" ]] \
    || fail "test 610: error and suggestion should end the output, got: '$(echo "$OUT610" | tail -3)'"
echo "$OUT610" | grep -q "^commands:$" || fail "test 610: the command list should still be shown"
OUT610B="$("$GIT_HUNK" frobnicate 2>&1 || true)"
[[ "$(echo "$OUT610B" | tail -1)" == "error: unknown command 'frobnicate'" ]] \
    || fail "test 610: an unrecognised word gets no suggestion, got: '$(echo "$OUT610B" | tail -2)'"
for CASE610 in "list --file|--file requires a value" "list -U x|invalid number of context lines 'x'" "commit --all -m|-m requires a value"; do
    ERR610="$("$GIT_HUNK" ${CASE610%%|*} 2>&1 || true)"
    [[ "$(echo "$ERR610" | head -1)" == "error: ${CASE610##*|}" ]] \
        || fail "test 610: '${CASE610%%|*}' should say what is wrong, got: '$ERR610'"
done
pass "test 610: unknown commands and bad values end with a message that says what to do"

report_results
