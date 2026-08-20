#!/usr/bin/env bash
# Hostile git-config profiles, sourced by run-hostile.sh.
#
# Each profile names git configuration that changes what `git diff` writes, or
# how it writes it, without changing what actually differs. Running the whole
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
