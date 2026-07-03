# fish completion for git-hunk
#
# Completes both invocation forms:
#   git-hunk <TAB>
#   git hunk <TAB>
#
# Requires fish >= 3.2 (for `complete -F`).

# Print the git-hunk arguments on the current command line, one per line.
# Fails when the command line is not a git-hunk / git hunk invocation, so
# every condition below is safely scoped when registered on `git`.
function __git_hunk_tokens
    set -l toks (commandline -opc)
    test (count $toks) -ge 1; or return 1
    switch (string replace -r '.*/' '' -- $toks[1])
        case git-hunk
            set -e toks[1]
        case git
            test (count $toks) -ge 2; and test "$toks[2]" = hunk; or return 1
            set -e toks[1..2]
        case '*'
            return 1
    end
    for t in $toks
        echo -- $t
    end
    return 0
end

function __git_hunk_subcommand
    set -l skip 0
    for t in (__git_hunk_tokens)
        if test $skip -eq 1
            set skip 0
            continue
        end
        switch $t
            case --file --ref -U --unified -m --message
                set skip 1
            case '-*'
            case '*'
                echo $t
                return 0
        end
    end
    return 1
end

function __git_hunk_needs_command
    __git_hunk_tokens >/dev/null; or return 1
    set -l cmd (__git_hunk_subcommand)
    test -z "$cmd"
end

function __git_hunk_using_command
    set -l cmd (__git_hunk_subcommand)
    test -n "$cmd"; and contains -- $cmd $argv
end

# True while the value of an option like --file or --ref is being typed.
function __git_hunk_option_pending
    set -l toks (__git_hunk_tokens)
    test (count $toks) -ge 1
    and contains -- $toks[-1] --file --ref -U --unified -m --message
end

# True when completing the token right after `stash` (push/pop position).
function __git_hunk_stash_keyword_position
    set -l toks (__git_hunk_tokens)
    test (count $toks) -ge 1; and test "$toks[-1]" = stash
end

# Hunk hashes as "hash<TAB>file lines" pairs; pass --staged for the staged
# diff. Silently prints nothing outside a repo or if git-hunk is missing.
function __git_hunk_hashes
    git-hunk list $argv --porcelain --oneline 2>/dev/null | while read -l line
        set -l parts (string split \t -- $line)
        if test (count $parts) -ge 2
            printf '%s\t%s\n' $parts[1] (string join ' ' -- $parts[2..-1])
        else if test -n "$parts[1]"
            printf '%s\n' $parts[1]
        end
    end
end

function __git_hunk_hashes_for
    switch $argv[1]
        case reset
            # reset operates on staged hunks (see `git-hunk help reset`).
            __git_hunk_hashes --staged
        case diff check
            # diff/check follow the diff mode already on the command line.
            if contains -- --staged (__git_hunk_tokens)
                __git_hunk_hashes --staged
            else
                __git_hunk_hashes
            end
        case stash
            if not contains -- pop (__git_hunk_tokens)
                __git_hunk_hashes
            end
        case '*'
            __git_hunk_hashes
    end
end

function __git_hunk_refs
    git for-each-ref --format='%(refname:short)' 2>/dev/null
    echo HEAD
end

# Register a completion for both `git-hunk` and `git hunk`. Every entry
# carries a condition that verifies the git-hunk context via
# __git_hunk_tokens, so registering on plain `git` is safe.
function __git_hunk_complete
    complete -c git-hunk $argv
    complete -c git $argv
end

# Offer `hunk` itself as a git subcommand.
complete -c git -f -n __fish_use_subcommand -a hunk -d 'Non-interactive hunk staging'

set -l all_cmds list diff add reset restore count check stash commit
set -l hash_cmds diff add reset restore check stash commit

# Subcommands
__git_hunk_complete -f -n __git_hunk_needs_command -a list -d 'List diff hunks with content hashes'
__git_hunk_complete -f -n __git_hunk_needs_command -a diff -d 'Show diff content of specific hunks'
__git_hunk_complete -f -n __git_hunk_needs_command -a add -d 'Stage hunks (or selected lines) by hash'
__git_hunk_complete -f -n __git_hunk_needs_command -a reset -d 'Unstage hunks (or selected lines) by hash'
__git_hunk_complete -f -n __git_hunk_needs_command -a restore -d 'Restore unstaged worktree changes by hash'
__git_hunk_complete -f -n __git_hunk_needs_command -a count -d 'Count diff hunks'
__git_hunk_complete -f -n __git_hunk_needs_command -a check -d 'Validate hunk hashes exist in current diff'
__git_hunk_complete -f -n __git_hunk_needs_command -a stash -d 'Stash hunks into git stash'
__git_hunk_complete -f -n __git_hunk_needs_command -a commit -d 'Commit specific hunks directly'
__git_hunk_complete -f -n __git_hunk_needs_command -a help -d 'Show help for a command'

# Top-level flags
__git_hunk_complete -f -n __git_hunk_needs_command -s h -l help -d 'Show help'
__git_hunk_complete -f -n __git_hunk_needs_command -s V -l version -d 'Show version'

# Flags common to every command
for cmd in $all_cmds
    __git_hunk_complete -n "__git_hunk_using_command $cmd" -l file -r -F -d 'Restrict to hunks in the given file'
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -s U -l unified -x -d 'Lines of diff context'
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -l tracked-only -d 'Only include hunks from tracked files'
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -l untracked-only -d 'Only include hunks from untracked files'
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -s q -l quiet -d 'Suppress output'
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -s h -l help -d 'Show help'
end

# Output flags (every command except count, which documents only -q)
for cmd in list diff add reset restore check stash commit
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -l porcelain -d 'Machine-readable output'
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -l no-color -d 'Disable colored output'
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -s v -l verbose -d 'Show summary counts'
end

# --ref (every command except stash, which rejects it)
for cmd in list diff add reset restore count check commit
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -l ref -x -a '(__git_hunk_refs)' -d 'Compare against a git ref or range'
end

# --staged
for cmd in list diff count check
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -l staged -d 'Use the staged diff instead of the worktree'
end

# --all
for cmd in add reset restore stash commit
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -l all -d 'Select all hunks'
end

# --3way
for cmd in add reset restore commit
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd" -l 3way -d 'Fall back to a 3-way merge on context drift'
end

# Command-specific flags
__git_hunk_complete -f -n '__git_hunk_using_command list' -l oneline -d 'One hunk per line'
__git_hunk_complete -f -n '__git_hunk_using_command check' -l exclusive -d 'Assert these are the only hunks in the diff'
__git_hunk_complete -f -n '__git_hunk_using_command check' -l allow-empty -d 'Allow zero sha arguments'
__git_hunk_complete -f -n '__git_hunk_using_command restore' -l force -d 'Required to restore untracked files (deletes them)'
__git_hunk_complete -f -n '__git_hunk_using_command restore' -l dry-run -d 'Preview without making changes'
__git_hunk_complete -f -n '__git_hunk_using_command stash' -s u -l include-untracked -d 'Include untracked files (with --all)'
__git_hunk_complete -f -n '__git_hunk_using_command stash' -s m -l message -x -d 'Set the stash message'
__git_hunk_complete -f -n '__git_hunk_using_command commit' -s m -l message -x -d 'Commit message'
__git_hunk_complete -f -n '__git_hunk_using_command commit' -l amend -d 'Amend the previous commit'
__git_hunk_complete -f -n '__git_hunk_using_command commit' -l dry-run -d 'Show what would be committed without committing'

# Positional hunk hashes
for cmd in $hash_cmds
    __git_hunk_complete -f -n "__git_hunk_using_command $cmd; and not __git_hunk_option_pending" -a "(__git_hunk_hashes_for $cmd)"
end

# stash push/pop keywords (only valid immediately after `stash`)
__git_hunk_complete -f -n '__git_hunk_stash_keyword_position' -a push -d 'Stash hunks (default when omitted)'
__git_hunk_complete -f -n '__git_hunk_stash_keyword_position' -a pop -d 'Restore the most recent git-hunk stash'

# help <command>
__git_hunk_complete -f -n '__git_hunk_using_command help' -a 'list diff add reset restore count check stash commit'
