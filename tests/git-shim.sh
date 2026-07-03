#!/usr/bin/env bash
# git interceptor for fault-injection tests.
#
# Install: copy (or symlink) this file as an executable named `git` into a
# temp directory, then prepend that directory to PATH for the git-hunk
# invocation under test. git-hunk spawns plain `git` via PATH lookup, so
# every subprocess it runs flows through here.
#
# Control via environment:
#   GIT_HUNK_SHIM_FAIL       git subcommand to intercept (e.g. "commit",
#                            "read-tree", "apply"). Unset = pure passthrough.
#   GIT_HUNK_SHIM_FAIL_ON    1-based ordinal: the Nth matching invocation
#                            fails (exit 1 + stderr message). Unset = count
#                            only, never fail (used to learn invocation
#                            counts).
#   GIT_HUNK_SHIM_COUNT_FILE file holding the running count of matching
#                            invocations. Callers create/reset it; the shim
#                            increments it on every match.
#
# Non-matching invocations (and matching ones other than the Nth) exec the
# real git, resolved by stripping this shim's directory from PATH first.
set -u

SHIM_DIR="$(cd "$(dirname "$0")" && pwd)"

CLEAN_PATH=""
IFS=':' read -r -a _parts <<< "$PATH"
for _p in "${_parts[@]}"; do
    [[ "$_p" == "$SHIM_DIR" ]] && continue
    CLEAN_PATH="${CLEAN_PATH:+$CLEAN_PATH:}$_p"
done
REAL_GIT="$(PATH="$CLEAN_PATH" command -v git)" || {
    echo "git-shim: cannot resolve real git" >&2
    exit 127
}

if [[ -n "${GIT_HUNK_SHIM_FAIL:-}" && "${1:-}" == "$GIT_HUNK_SHIM_FAIL" ]]; then
    n=1
    if [[ -n "${GIT_HUNK_SHIM_COUNT_FILE:-}" ]]; then
        [[ -f "$GIT_HUNK_SHIM_COUNT_FILE" ]] && n="$(( $(cat "$GIT_HUNK_SHIM_COUNT_FILE") + 1 ))"
        echo "$n" > "$GIT_HUNK_SHIM_COUNT_FILE"
    fi
    if [[ -n "${GIT_HUNK_SHIM_FAIL_ON:-}" && "$n" -eq "$GIT_HUNK_SHIM_FAIL_ON" ]]; then
        echo "git-shim: injected failure for 'git $1' (matching invocation $n)" >&2
        exit 1
    fi
fi

exec "$REAL_GIT" "$@"
