#!/usr/bin/env bash
# Hostile git-config profiles, sourced by run-hostile.sh.
#
# Each profile names git configuration that changes what `git diff` writes, or
# how it writes it, or which defaults a new repository gets (object format, ref
# backend), without changing what actually differs. Running the whole
# suite under one of these catches the case where git-hunk works by accident on
# a default machine. `diff.context` is deliberately absent: it is documented as
# honoured, so it legitimately changes hunk boundaries.
#
# A profile is a function named `profile_<name>` that writes git config into
# the file named by $1 and may export environment variables. $2 is a scratch
# directory it may write helper files into.

HOSTILE_PROFILES=(
    external-diff
    textconv
    prefixes
    color-ui
    color-diff
    algorithm
    quotepath
    pager
    git3-defaults
    copies
    apply-whitespace
)

# `diff.external` and GIT_EXTERNAL_DIFF both hand the diff to another program
# and leave git's stdout empty with exit 0 — a dirty tree that reads as clean.
profile_external_diff() {
    cat >> "$1" <<EOF
[diff]
	external = $(command -v true)
EOF
    export GIT_EXTERNAL_DIFF="$(command -v true)"
}

# A textconv driver emits a converted rendering of the blob. Readable, but it
# does not apply back to the real content.
profile_textconv() {
    cat > "$2/attributes" <<'EOF'
* diff=hostile
EOF
    cat >> "$1" <<EOF
[core]
	attributesFile = $2/attributes
[diff "hostile"]
	textconv = cat
EOF
}

# Path prefixes: mnemonicPrefix swaps a//b/ for i//w//c/, noprefix removes them
# entirely, relative re-roots paths at the cwd.
profile_prefixes() {
    cat >> "$1" <<'EOF'
[diff]
	mnemonicPrefix = true
	noprefix = true
	relative = true
EOF
}

# color.ui and color.diff reach git's colorization through different config
# lookups, so they are separate profiles rather than one.
profile_color_ui() {
    cat >> "$1" <<'EOF'
[color]
	ui = always
EOF
}

profile_color_diff() {
    cat >> "$1" <<'EOF'
[color]
	diff = always
	diff = always
[color "diff"]
	meta = bold red
	frag = magenta bold
	old = red bold
	new = green bold
[diff]
	wsErrorHighlight = all
EOF
}

# A different diff algorithm and heuristics move hunk boundaries; blank-line
# suppression drops the leading space from empty context lines.
profile_algorithm() {
    cat >> "$1" <<'EOF'
[diff]
	algorithm = histogram
	indentHeuristic = false
	suppressBlankEmpty = true
EOF
}

# diff.renames = copies reports a new file that resembles a changed one as a
# copy of it: `copy from`/`copy to` headers, and hunks relative to the source.
profile_copies() {
    cat >> "$1" <<'EOF'
[diff]
	renames = copies
EOF
}

# apply.whitespace = error makes `git apply` reject a patch that adds a line
# core.whitespace flags; git-hunk applies patches of content already in the
# repository, which must move as it is.
profile_apply_whitespace() {
    cat >> "$1" <<'EOF'
[apply]
	whitespace = error
[core]
	whitespace = trailing-space,space-before-tab,tab-in-indent,blank-at-eof
EOF
}

# core.quotePath = false emits non-ASCII path bytes raw instead of \NNN-escaped.
profile_quotepath() {
    cat >> "$1" <<'EOF'
[core]
	quotePath = false
EOF
}

# A pager configured for diff/log, plus an order file that reshuffles the
# order files appear in.
profile_pager() {
    printf 'zzz*\n*\n' > "$2/orderfile"
    cat >> "$1" <<EOF
[core]
	pager = cat
[pager]
	diff = true
	log = true
[diff]
	orderFile = $2/orderfile
EOF
}

# Git 3.0's defaults for new repositories: SHA-256 object IDs, the reftable ref
# backend, `main` as the first branch, and no implicit bare-repo discovery.
# Every repo the suite creates takes these on, so a SHA-1 constant or direct
# `.git/refs` access fails here. The environment variables reach older git than
# the equivalent config keys; the probe refuses a git that silently ignores
# them, since the profile would then match the baseline vacuously. Commits
# start `git maintenance run --auto --detach`, which under reftable has refs
# to compact and can still be writing into .git while a test deletes the
# repo; running it in the foreground keeps teardown deterministic.
profile_git3_defaults() {
    cat >> "$1" <<'EOF'
[init]
	defaultBranch = main
[safe]
	bareRepository = explicit
[maintenance]
	autoDetach = false
[gc]
	autoDetach = false
EOF
    export GIT_DEFAULT_HASH=sha256
    export GIT_DEFAULT_REF_FORMAT=reftable
    git init -q "$2/probe"
    local formats
    formats="$(git -C "$2/probe" rev-parse --show-object-format --show-ref-format | tr '\n' ' ')"
    if [[ "$formats" != "sha256 reftable " ]]; then
        echo "git3-defaults: $(git --version) ignores GIT_DEFAULT_HASH/GIT_DEFAULT_REF_FORMAT (got: $formats)" >&2
        return 1
    fi
}
