#!/usr/bin/env bash
# Shared test utilities sourced by each test_*.sh script.
# Usage: source "$(dirname "$0")/harness.sh" "$1"
#
# Deliberately no `pipefail`. The suite is built on `echo "$OUT" | grep -q X`
# and `... | head -1`, where the consumer exits on its first match and the
# producer then dies of SIGPIPE with status 141. Under pipefail that 141
# becomes the pipeline's status, so a passing assertion fails at random --
# observed on Ubuntu as one grep in a pair failing while its neighbour passed.
# The status these pipelines want is the consumer's, which is what the
# pipeline returns without pipefail.
set -eu

# An inherited git environment must not be able to redirect the suite at some
# other repository. Every test builds its own repo and cds into it; a stray
# GIT_DIR or GIT_INDEX_FILE from the caller would silently override that, and
# the suite would assert against — and write to — whatever it named.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_CEILING_DIRECTORIES GIT_PREFIX

# Resolved before the `git` function below exists, so it is the real binary
# and not the function's own name. Tests that build a PATH shim must use this
# to reach the real git — `command -v git` would report the function and the
# shim would exec itself forever.
GIT_BIN="$(command -v git)"

# Tests observe the repo with plain git. Output-reshaping config — an external
# diff driver, a textconv filter, forced colour — must not reach the observer:
# under it, an assertion that something *is* present fails while its negation
# passes vacuously, which is the wrong answer in both directions. The tool
# under test pins these flags for itself; this pins them for the observer.
#
# The colour keys are listed individually rather than relying on color.ui,
# because a more specific key (color.status, color.diff) overrides it.
GIT_OBSERVE=(-c color.ui=false -c color.status=false -c color.diff=false -c color.branch=false)

# Calls go straight to $GIT_BIN, so a test that has put a shim on PATH for the
# tool under test still observes through the real git.
git() {
    case "${1:-}" in
        diff | diff-tree | diff-files | diff-index | show | log | whatchanged)
            "$GIT_BIN" "${GIT_OBSERVE[@]}" "$1" --no-ext-diff --no-textconv --no-color "${@:2}" ;;
        *)
            "$GIT_BIN" "${GIT_OBSERVE[@]}" "$@" ;;
    esac
}

GIT_HUNK="${1:?Usage: $0 <git-hunk-binary>}"
GIT_HUNK="$(cd "$(dirname "$GIT_HUNK")" && pwd)/$(basename "$GIT_HUNK")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
SETUP="$SCRIPT_DIR/setup-repo.sh"
MANPAGE="$SCRIPT_DIR/../doc/git-hunk.1"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_REPO=""

fail() { echo "FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup_repo() {
    if [[ -n "$CURRENT_REPO" && -d "$CURRENT_REPO" ]]; then
        cd /
        rm -rf "$CURRENT_REPO"
    fi
    CURRENT_REPO=""
}
trap cleanup_repo EXIT

new_repo() {
    cleanup_repo
    CURRENT_REPO="$(bash "$SETUP")"
    cd "$CURRENT_REPO"
}

# ── Shared assertion helpers ──────────────────────────────────────────
#
# Byte-exact renderings, for comparisons and for failure messages. `od -An -c`
# makes a trailing-newline difference and a high byte both visible, which a
# bare string comparison hides.

# Bytes of a worktree file.
bytes_of() { od -An -c "$1" | tr -s ' \n' ' '; }

# Bytes of a git object: `blob_bytes :path` for the index, `blob_bytes HEAD:path`
# for a commit.
blob_bytes() { git cat-file -p "$1" | od -An -c | tr -s ' \n' ' '; }

# Bytes a printf format string would produce, as the expected value.
want_bytes() { printf "$1" | od -An -c | tr -s ' \n' ' '; }

# The first hunk hash from `list`, with any extra flags passed through
# (e.g. `first_sha --staged --file f.txt`). Empty when there are no hunks;
# callers assert on that rather than relying on an exit status.
first_sha() { "$GIT_HUNK" list --porcelain "$@" 2>/dev/null | grep -oE '^[0-9a-f]{7}' | head -1; }

# Call at end of each test script:
report_results() {
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        echo "FAILED: $FAIL_COUNT failures, $PASS_COUNT passed" >&2
        exit 1
    fi
    echo "OK: $PASS_COUNT passed"
    exit 0
}
