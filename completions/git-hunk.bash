# bash completion for git-hunk                             -*- shell-script -*-
#
# Completes both invocation forms:
#   git-hunk <TAB>      (registered at the bottom of this file)
#   git hunk <TAB>      (git's bash completion dispatches to _git_hunk)
#
# No dependencies beyond git and coreutils. Safe to source multiple times.

__git_hunk_commands="list diff add reset restore count check stash commit help"

# Print hunk hashes from `git-hunk list`; pass --staged for the staged diff.
# Produces no output (and no errors) outside a repo or if git-hunk is missing.
__git_hunk_hashes()
{
    git-hunk list "$@" --porcelain --oneline 2>/dev/null | cut -f1
}

__git_hunk_refs()
{
    git for-each-ref --format='%(refname:short)' 2>/dev/null
    echo HEAD
}

# Add completions from a word list. Reuses git's __gitcomp when available so
# candidates get proper suffix handling under git completion's nospace mode.
__git_hunk_compgen()
{
    if declare -F __gitcomp >/dev/null 2>&1; then
        __gitcomp "$1"
    else
        COMPREPLY=($(compgen -W "$1" -- "$cur"))
    fi
}

_git_hunk()
{
    local cur prev words cword
    if declare -F _get_comp_words_by_ref >/dev/null 2>&1; then
        _get_comp_words_by_ref -n =: cur prev words cword
    else
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
        cur=${words[cword]}
        prev=${words[cword - 1]}
    fi

    # Locate the git-hunk subcommand, skipping the "hunk" word (git
    # subcommand form), flags, and values of flags that take an argument.
    local subcommand="" sub_idx=0 start=1 skip_next="" i w
    if [[ (${words[0]} == git || ${words[0]} == */git) && ${words[1]} == hunk ]]; then
        start=2
    fi
    for ((i = start; i < cword; i++)); do
        w=${words[i]}
        if [[ -n $skip_next ]]; then
            skip_next=""
            continue
        fi
        case $w in
        --file | --ref | -U | --unified | -m | --message)
            skip_next=1
            ;;
        -*) ;;
        *)
            subcommand=$w
            sub_idx=$i
            break
            ;;
        esac
    done

    # Complete the value of an option that takes one.
    case $prev in
    --file)
        compopt -o filenames 2>/dev/null
        if declare -F _filedir >/dev/null 2>&1; then
            _filedir
        else
            COMPREPLY=($(compgen -f -- "$cur"))
        fi
        return
        ;;
    --ref)
        __git_hunk_compgen "$(__git_hunk_refs)"
        return
        ;;
    -U | --unified | -m | --message)
        return
        ;;
    esac

    if [[ -z $subcommand ]]; then
        case $cur in
        -*) __git_hunk_compgen "--help -h --version -V" ;;
        *) __git_hunk_compgen "$__git_hunk_commands" ;;
        esac
        return
    fi

    local opts="" hash_source=""
    case $subcommand in
    list)
        opts="--staged --oneline --ref --file --porcelain --no-color --tracked-only --untracked-only -U --unified -v --verbose -q --quiet -h --help"
        ;;
    diff)
        opts="--staged --ref --file --porcelain --no-color --tracked-only --untracked-only -U --unified -v --verbose -q --quiet -h --help"
        hash_source=auto
        ;;
    add)
        opts="--all --3way --ref --file --porcelain --no-color --tracked-only --untracked-only -U --unified -v --verbose -q --quiet -h --help"
        hash_source=unstaged
        ;;
    reset)
        opts="--all --3way --ref --file --porcelain --no-color --tracked-only --untracked-only -U --unified -v --verbose -q --quiet -h --help"
        hash_source=staged
        ;;
    restore)
        opts="--all --3way --force --dry-run --ref --file --porcelain --no-color --tracked-only --untracked-only -U --unified -v --verbose -q --quiet -h --help"
        hash_source=unstaged
        ;;
    count)
        opts="--staged --ref --file --tracked-only --untracked-only -U --unified -q --quiet -h --help"
        ;;
    check)
        opts="--staged --exclusive --allow-empty --ref --file --porcelain --no-color --tracked-only --untracked-only -U --unified -v --verbose -q --quiet -h --help"
        hash_source=auto
        ;;
    stash)
        # `stash pop` takes no further flags or arguments.
        [[ ${words[sub_idx + 1]} == pop ]] && return
        opts="--all --include-untracked -u -m --message --file --porcelain --no-color --tracked-only --untracked-only -U --unified -v --verbose -q --quiet -h --help"
        hash_source=unstaged
        ;;
    commit)
        opts="-m --message --amend --dry-run --all --3way --ref --file -U --unified --tracked-only --untracked-only --no-color --porcelain -v --verbose -q --quiet -h --help"
        hash_source=unstaged
        ;;
    help)
        __git_hunk_compgen "$__git_hunk_commands"
        return
        ;;
    *)
        return
        ;;
    esac

    if [[ $cur == -* ]]; then
        __git_hunk_compgen "$opts"
        return
    fi

    case $hash_source in
    staged)
        # reset operates on staged hunks (see `git-hunk help reset`).
        __git_hunk_compgen "$(__git_hunk_hashes --staged)"
        ;;
    auto)
        # diff/check follow the diff mode already on the command line.
        local staged=""
        for ((i = sub_idx + 1; i < ${#words[@]}; i++)); do
            [[ ${words[i]} == --staged ]] && staged=--staged
        done
        __git_hunk_compgen "$(__git_hunk_hashes $staged)"
        ;;
    unstaged)
        local extra=""
        if [[ $subcommand == stash && $cword -eq $((sub_idx + 1)) ]]; then
            extra="push pop "
        fi
        __git_hunk_compgen "$extra$(__git_hunk_hashes)"
        ;;
    esac
}

complete -F _git_hunk git-hunk
