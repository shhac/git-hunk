# Shell completions

Completion scripts for `git-hunk`. All three cover both invocation forms:
`git-hunk <TAB>` and `git hunk <TAB>`. They only depend on git and coreutils,
and hunk-hash completion degrades silently outside a repo.

## bash — `git-hunk.bash`

- Manual: `source /path/to/git-hunk.bash` from `~/.bashrc`
- Homebrew (bash-completion@2): `$(brew --prefix)/share/bash-completion/completions/git-hunk`

The `git hunk <TAB>` form works via git's bash completion, which dispatches
to the `_git_hunk` function this file defines. Note that bash-completion v2
lazy-loads by command name, so in a fresh shell `git hunk <TAB>` only works
after the file has been loaded (complete `git-hunk` once, or source the file
eagerly from `~/.bashrc`).

## zsh — `_git-hunk` and `_git_hunk`

Copy **both files** onto your `$fpath` (before `compinit` runs):

- Homebrew: `$(brew --prefix)/share/zsh/site-functions/`
- Manual: `~/.zsh/completions/` plus `fpath=(~/.zsh/completions $fpath)`

`_git-hunk` is the compsys implementation; zsh's builtin `_git` dispatches
`git hunk <TAB>` to it automatically. `_git_hunk` (underscores) is a
self-contained completer for setups where `_git` is git's own
`git-completion.zsh` wrapper (installed by e.g. Homebrew git or the Apple
Command Line Tools), which dispatches to bash-style `_git_<cmd>` function
names — and whose dispatch context breaks the compsys helpers `_git-hunk`
relies on, so the bridge completes with raw compadd instead. Installing
both covers either setup.

## fish — `git-hunk.fish`

- Homebrew: `$(brew --prefix)/share/fish/vendor_completions.d/git-hunk.fish`
- Manual: `~/.config/fish/completions/git-hunk.fish`

Requires fish >= 3.2. fish autoloads completion files by command name, so
`git hunk <TAB>` becomes active once this file has been loaded (after
completing `git-hunk` once). To have it active immediately in every shell,
place the file in `~/.config/fish/conf.d/` instead (or additionally).
