#!/usr/bin/env zsh
# Drives one interactive TAB completion in a pty and captures the result.
#
# Usage: completion-harness.zsh <repo-dir> <input> <buffer-out> <display-out> <fpath-dirs-colon-separated> [columns]
#
# Types <input><TAB> in an interactive zsh started in <repo-dir> with the
# given dirs prepended to fpath, then writes the resulting edit buffer to
# <buffer-out> and the raw completion display output to <display-out>.
zmodload zsh/zpty || exit 3

typeset repo=$1 input=$2 bufout=$3 dispout=$4 cols=${6:-}
typeset -a fdirs=("${(@s/:/)5}")

zpty z "TERM=vt100 zsh -f -i"

drain() {
  local out='' chunk
  integer quiet=0
  while (( quiet < $1 )); do
    if zpty -rt z chunk 2>/dev/null; then
      out+="$chunk"
      quiet=0
    else
      (( quiet++ ))
      sleep 0.1
    fi
  done
  print -r -- "$out"
}

# PATH is inherited from the (exported) caller environment; sending it
# through the pty would exceed the tty input-line limit and wedge the
# child shell in a quote-continuation prompt.
# Quote each fpath dir individually (interpolating the array directly
# inside double quotes would join the elements into one bogus path).
typeset fpath_words=''
for d in "${fdirs[@]}"; do fpath_words+=" ${(qq)d}"; done
zpty -w z "fpath=($fpath_words \$fpath)"
drain 6 >/dev/null
zpty -w z "autoload -Uz compinit; compinit -u -d ${(qq):-$bufout.zcompdump}"
drain 6 >/dev/null
zpty -w z "builtin cd ${(qq)repo}"
drain 6 >/dev/null
if [[ -n $cols ]]; then
  # ZLE reads COLUMNS/LINES; a wide value lets listings columnize, which
  # the one-per-row tests must be able to provoke.
  zpty -w z "COLUMNS=$cols LINES=50"
  drain 6 >/dev/null
fi
zpty -w z "dumpbuf() { print -r -- \$BUFFER >! ${(qq)bufout}; zle kill-whole-line }; zle -N dumpbuf; bindkey '^G' dumpbuf"
drain 6 >/dev/null

zpty -wn z "${input}"$'\t'
drain 15 >! "$dispout"
zpty -wn z $'\C-g'
drain 8 >/dev/null
zpty -d z 2>/dev/null
[[ -f $bufout ]]
