#!/usr/bin/env bash
# Re-run the whole integration suite under hostile git configuration.
#
#   tests/run-hostile.sh <git-hunk-binary> [profile ...]
#   tests/run-hostile.sh --list
#
# With no profile named, every profile runs. The value here is not a bespoke
# assertion per config key — it is that *existing* coverage re-runs against a
# git that has been told to write its diffs differently, catching the case
# where git-hunk works by accident on a default machine.
#
# Hostility is applied through GIT_CONFIG_GLOBAL rather than per-repo config,
# so it reaches every git invocation in every test regardless of how that test
# builds its repo — including the git processes git-hunk itself spawns.
#
# Each run is compared against a baseline run of the same suite: a profile
# passes only if it produces the *same number of assertions* as the baseline,
# not merely if it exits 0. Without that, a profile that silently emptied every
# diff would pass by asserting nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/hostile-profiles.sh"

if [[ "${1:-}" == "--list" ]]; then
    printf '%s\n' "${HOSTILE_PROFILES[@]}"
    exit 0
fi

BINARY="${1:?Usage: $0 <git-hunk-binary> [profile ...]}"
BINARY="$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")"
shift

PROFILES=("$@")
[[ ${#PROFILES[@]} -eq 0 ]] && PROFILES=("${HOSTILE_PROFILES[@]}")

WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-hunk-hostile.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Per-suite assertion counts, as "<suite> <count>" lines sorted by suite.
# run-all.sh prints one "OK: N passed" per suite but not which suite, so the
# suites are run here directly.
suite_tallies() {
    local outdir="$1"
    local f suite
    for f in "$SCRIPT_DIR"/test_*.sh; do
        suite="$(basename "$f" .sh)"
        bash "$f" "$BINARY" > "$outdir/$suite.out" 2>&1 &
    done
    # `wait` with no arguments always returns 0, so a suite's failure is
    # detected from its tally line rather than from its exit status.
    wait
    for f in "$SCRIPT_DIR"/test_*.sh; do
        suite="$(basename "$f" .sh)"
        # "OK: N passed" on success; anything else counts as 0 and is reported.
        local n
        n="$(sed -n 's/^OK: \([0-9]*\) passed$/\1/p' "$outdir/$suite.out" | tail -1)"
        printf '%s %s\n' "$suite" "${n:-FAILED}"
    done
}

mkdir -p "$WORK/baseline"
echo "==> baseline (default config)"
suite_tallies "$WORK/baseline" > "$WORK/baseline.tally"
if grep -q ' FAILED$' "$WORK/baseline.tally"; then
    echo "baseline suite failed; fix that before running hostile profiles" >&2
    while read -r suite _; do
        echo "--- $suite ---" >&2
        cat "$WORK/baseline/$suite.out" >&2
    done < <(grep ' FAILED$' "$WORK/baseline.tally")
    exit 1
fi
BASELINE_TOTAL="$(awk '{s+=$2} END {print s}' "$WORK/baseline.tally")"
echo "    $BASELINE_TOTAL assertions across $(wc -l < "$WORK/baseline.tally" | tr -d ' ') suites"
if [[ "$BASELINE_TOTAL" -lt 100 ]]; then
    echo "baseline asserted only $BASELINE_TOTAL times; comparisons would be near-vacuous" >&2
    exit 1
fi

EXIT=0
for profile in "${PROFILES[@]}"; do
    fn="profile_${profile//-/_}"
    if ! declare -F "$fn" > /dev/null; then
        echo "unknown profile: $profile (see --list)" >&2
        exit 2
    fi

    echo "==> profile: $profile"
    RUN="$WORK/$profile"
    mkdir -p "$RUN"
    : > "$RUN/gitconfig"

    # A subshell so exported variables and config never leak between profiles.
    (
        "$fn" "$RUN/gitconfig" "$RUN"
        export GIT_CONFIG_GLOBAL="$RUN/gitconfig"
        export GIT_CONFIG_SYSTEM=/dev/null
        suite_tallies "$RUN" > "$RUN/tally"
    )

    if ! diff -u "$WORK/baseline.tally" "$RUN/tally" > "$RUN/tally.diff"; then
        EXIT=1
        echo "FAIL: $profile changed the suite result" >&2
        cat "$RUN/tally.diff" >&2
        # Show the output of every suite whose tally moved.
        while read -r suite _; do
            [[ -f "$RUN/$suite.out" ]] && { echo "--- $suite ---" >&2; cat "$RUN/$suite.out" >&2; }
        done < <(diff "$WORK/baseline.tally" "$RUN/tally" | sed -n 's/^[<>] \([a-z_]*\) .*/\1/p' | sort -u)
    else
        echo "    identical to baseline ($BASELINE_TOTAL assertions)"
    fi
done

if [[ "$EXIT" -eq 0 ]]; then
    echo ""
    echo "ALL HOSTILE PROFILES MATCHED BASELINE (${#PROFILES[@]} profiles)"
else
    echo ""
    echo "SOME HOSTILE PROFILES DIVERGED" >&2
fi
exit "$EXIT"
