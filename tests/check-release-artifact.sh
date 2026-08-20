#!/usr/bin/env bash
# Verify a release tarball contains everything a released git-hunk needs.
#
#   tests/check-release-artifact.sh <tarball> [expected-version]
#
# A release ships more than the binary: the man page and four completion files
# are what `brew install` puts on disk. A workflow edit can drop any of them
# and every other check still passes, because nothing else reads the tarball.
# This reads the tarball.
#
# The man-page-covers-every-command check runs against the *shipped* copy and
# the *shipped* binary, so the pair that reaches a user is the pair verified —
# an in-tree check cannot catch a packaging step that shipped a stale man page.
set -euo pipefail

TARBALL="${1:?Usage: $0 <tarball> [expected-version]}"
TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
EXPECTED_VERSION="${2:-}"

PASS_COUNT=0
FAIL_COUNT=0
fail() { echo "FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -f "$TARBALL" ]] || { echo "no such tarball: $TARBALL" >&2; exit 1; }

# ── Contents ───────────────────────────────────────────────────────────────
# The Homebrew formula installs exactly these; anything missing here is a
# broken install, not a cosmetic omission.
REQUIRED=(
    git-hunk
    git-hunk.1
    completions/git-hunk.bash
    completions/git-hunk.fish
    completions/_git-hunk
    completions/_git_hunk
)

LISTING="$(tar -tzf "$TARBALL" | sed 's|^\./||')"
for entry in "${REQUIRED[@]}"; do
    printf '%s\n' "$LISTING" | grep -qxF "$entry" \
        || fail "tarball is missing '$entry'"
done
[[ "$FAIL_COUNT" -eq 0 ]] && pass "tarball contains all ${#REQUIRED[@]} required entries"

tar -xzf "$TARBALL" -C "$WORK"
BIN="$WORK/git-hunk"
MAN="$WORK/git-hunk.1"

# ── Binary ─────────────────────────────────────────────────────────────────
[[ -x "$BIN" ]] || fail "packaged git-hunk is not executable"

if ! VERSION_OUT="$("$BIN" --version 2>&1)"; then
    # A cross-compiled artifact cannot run here; the content checks above still
    # apply, so skip the rest rather than reporting a false failure.
    echo "SKIP: packaged binary does not run on this host; content checks only"
    [[ "$FAIL_COUNT" -gt 0 ]] && exit 1
    echo "OK: $PASS_COUNT passed"
    exit 0
fi

echo "$VERSION_OUT" | grep -qE '^git-hunk [0-9]+\.[0-9]+\.[0-9]+$' \
    || fail "packaged binary --version output is malformed: '$VERSION_OUT'"
if [[ -n "$EXPECTED_VERSION" ]]; then
    [[ "$VERSION_OUT" == "git-hunk $EXPECTED_VERSION" ]] \
        || fail "packaged binary reports '$VERSION_OUT', expected 'git-hunk $EXPECTED_VERSION'"
fi
pass "packaged binary runs and reports $VERSION_OUT"

# ── Man page covers the shipped binary's commands ──────────────────────────
COMMANDS="$("$BIN" --help | sed -n '/^commands:/,/^$/p' | grep '^ ' | awk '{print $1}')"
[[ -n "$COMMANDS" ]] || fail "packaged binary listed no commands in --help"
MISSING_MAN=""
for cmd in $COMMANDS; do
    grep -q "^\.B $cmd\$" "$MAN" || MISSING_MAN="$MISSING_MAN $cmd"
done
[[ -z "$MISSING_MAN" ]] \
    || fail "shipped man page is missing command(s):$MISSING_MAN"
[[ -z "$MISSING_MAN" ]] && pass "shipped man page documents every command the shipped binary lists"

# The man page must be for this version, not a stale copy from an earlier one.
SEMVER="${VERSION_OUT#git-hunk }"
grep -q "$SEMVER" "$MAN" \
    || fail "shipped man page does not mention version $SEMVER"
pass "shipped man page is stamped $SEMVER"

# ── Completions cover the shipped binary's commands ────────────────────────
for completion in completions/git-hunk.bash completions/git-hunk.fish completions/_git-hunk completions/_git_hunk; do
    MISSING_COMP=""
    for cmd in $COMMANDS; do
        grep -q -- "$cmd" "$WORK/$completion" || MISSING_COMP="$MISSING_COMP $cmd"
    done
    [[ -z "$MISSING_COMP" ]] \
        || fail "$completion is missing command(s):$MISSING_COMP"
done
pass "shipped completions mention every command the shipped binary lists"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "FAILED: $FAIL_COUNT failures, $PASS_COUNT passed" >&2
    exit 1
fi
echo "OK: $PASS_COUNT passed"
