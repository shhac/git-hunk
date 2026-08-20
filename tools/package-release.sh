#!/usr/bin/env bash
# Package a release tarball from an existing build.
#
#   tools/package-release.sh <platform> [outdir]
#
# Produces <outdir>/git-hunk-<platform>.tar.gz containing the binary, the man
# page and the completion files. Used by the release workflow and by CI, so
# what CI verifies is the same payload a release publishes — not a second
# description of it that can drift.
set -euo pipefail

PLATFORM="${1:?Usage: $0 <platform> [outdir]}"
OUTDIR="${2:-.}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="$(cd "$OUTDIR" && pwd)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$ROOT/zig-out/bin/git-hunk" "$STAGE/"
cp "$ROOT/doc/git-hunk.1" "$STAGE/"
cp -R "$ROOT/completions" "$STAGE/completions"

tar -czf "$OUTDIR/git-hunk-$PLATFORM.tar.gz" -C "$STAGE" git-hunk git-hunk.1 completions
echo "$OUTDIR/git-hunk-$PLATFORM.tar.gz"
