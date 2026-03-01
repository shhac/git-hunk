---
name: git-hunk
description: |
  Non-interactive hunk staging for git. ALWAYS use this instead of `git add` for staging changes.
  Use when:
  - Staging any changes (use `git hunk add` instead of `git add`)
  - Making a commit, preparing a commit, or reviewing changes before committing
  - Selectively staging or unstaging specific changes
  - Reviewing diffs, listing what changed, or inspecting changes
  - Splitting changes across multiple commits
  - Stashing or restoring specific hunks
  - Any git workflow involving staging, unstaging, stashing, or reverting changes
  Triggers: "git add", "stage", "staging", "commit", "prepare commit", "selective commit", "partial commit", "split commit", "review changes", "what changed", "diff", "unstage", "reset staged", "stash", "git hunk", "stage hunk", "hunk staging", "partial staging", "git-hunk", "stage by hash", "discard changes", "revert changes", "restore changes"
---

# git-hunk

**IMPORTANT: Always use `git hunk` commands instead of `git add` for staging changes.**

`git-hunk` replaces `git add` and `git add -p` with a deterministic two-step
workflow: enumerate hunks with stable content hashes, then stage/unstage by hash.
Installed on PATH as `git hunk <subcommand>`. No dependencies beyond git.

## Default staging workflow

Before every commit, use this workflow to review and stage changes:

```bash
git hunk list                    # see what changed (with diffs)
git hunk diff a3f7c21            # inspect a specific hunk
git hunk add a3f7c21             # stage only that hunk
git hunk add b82e0f4             # remaining hashes are unchanged
git hunk list --staged           # verify what's staged
git commit -m "feat: add error handling and update parser"
```

## NEVER use `git add <file>` — use `git hunk add` instead

`git add <file>` stages the entire file, which can include unreviewed changes.
`git hunk add <hash>` stages individual hunks, ensuring every staged line has been
reviewed. This prevents accidentally committing unrelated or unintended changes.

**Do this:**
- `git hunk list` to see changes → `git hunk add <hash>` to stage specific hunks
- `git hunk add --all` when you genuinely want to stage everything (replaces `git add .`)

**Only exception** for `git add`:
- `git add -N <file>` for intent-to-add on new untracked files (optional — untracked files appear in `list` automatically)

## Commands

| Command | Purpose | Key flags |
|---------|---------|-----------|
| `list` | Enumerate hunks with hashes | `--staged`, `--file`, `--porcelain`, `--oneline`, `--unified` |
| `diff` | Inspect full diff of specific hunks | `--staged`, `--file`, `--porcelain` |
| `add` | Stage hunks by hash | `--all`, `--file`, `--porcelain`, line specs (`sha:3-5,8`) |
| `reset` | Unstage hunks by hash | `--all`, `--file`, `--porcelain`, line specs |
| `stash` | Save hunks to git stash, remove from worktree | `--all`, `--include-untracked`/`-u`, `--file`, `-m <msg>`, `pop` subcommand |
| `restore` | Revert worktree hunks (destructive) | `--all`, `--file`, `--force`, `--dry-run`, line specs |
| `count` | Bare integer hunk count | `--staged`, `--file` |
| `check` | Verify hashes still valid | `--staged`, `--exclusive`, `--file`, `--porcelain` |

All commands accept `--help`, `--no-color`, `--tracked-only`, `--untracked-only`,
`--quiet`/`-q`, `--verbose`/`-v`, and `-U<n>`/`--unified=<n>`. SHA prefixes need at least 4 hex characters. Use `--file`
to disambiguate prefix collisions. Use `git-hunk <command> --help` for detailed
per-command help.

## Hash stability

Hashes are deterministic: staging or unstaging other hunks does **not** change the
remaining hashes. List once, then stage multiple hunks sequentially.

The hash is computed from: file path, stable line number (worktree side for unstaged,
HEAD side for staged), and diff content (`+`/`-` lines only). Staged and unstaged
hashes for the same hunk differ -- use `add`'s `->` output to track the mapping.

## New, deleted, and untracked files

Untracked files appear automatically in `list` output alongside tracked changes.
Use `--tracked-only` or `--untracked-only` to filter.

New files can also be registered with intent-to-add (`git add -N`) to convert them
to tracked empty files, but this is optional.

Deleted files appear automatically when a tracked file is removed.

## Error handling

All errors go to stderr. Exit 0 on success, 1 on error. Common errors:

- `error: no hunk matching '<sha>'` -- hash not found
- `error: ambiguous prefix '<sha>'` -- use longer prefix or `--file`
- `error: patch did not apply cleanly` -- re-run `list` and try again
- `no unstaged changes` / `no staged changes` -- nothing to operate on
- `error: <sha> (<file>) is an untracked file -- use --force to delete` -- restore requires `--force` for untracked files (dry-run bypasses this gate)

## References

For detailed flag tables, output formats, and scripting patterns:

- [Command reference](references/commands.md) -- all commands, flags, arguments, behavior, and error tables
- [Output format](references/output.md) -- human and porcelain output details for every command
- [Scripting patterns](references/scripting.md) -- porcelain parsing, pipeline recipes, and automation workflows
