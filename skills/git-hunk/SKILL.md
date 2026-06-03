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
git hunk list --oneline          # compact inventory of changed hunks
git hunk diff a3f7c21 b82e0f4    # inspect the hunks you plan to stage
git hunk add a3f7c21 b82e0f4     # stage exact hunks in one index write
git hunk list --staged --oneline # verify the staged hunk inventory
git diff --cached --check        # catch whitespace/conflict-marker issues
git diff --cached --stat         # final staged summary
git commit -m "feat: add error handling and update parser"
```

Do not run multiple staging commands in parallel. Git index writes contend on
`.git/index.lock`; collect the intended hashes and pass them to one
`git hunk add <hash>...` command.

## NEVER use `git add <file>` — use `git hunk add` instead

`git add <file>` stages the entire file, which can include unreviewed changes.
`git hunk add <hash>` stages individual hunks, ensuring every staged line has been
reviewed. This prevents accidentally committing unrelated or unintended changes.

**Do this:**
- `git hunk list` to see changes → `git hunk add <hash>` to stage specific hunks
- `git hunk add --all` when you genuinely want to stage everything (replaces `git add .`)

Prefer hash staging for hand-edited files. Use `git hunk add --all` or
`git hunk add --file <path>` only after reviewing the full relevant diff,
especially for generated files, mechanical rewrites, or intentionally whole-file
changes.

**Only exception** for `git add`:
- `git add -N <file>` for intent-to-add on new untracked files (optional — untracked files appear in `list` automatically)

## Commands

| Command | Purpose | Key flags |
|---------|---------|-----------|
| `list` | Enumerate hunks with hashes | `--staged`, `--file`, `--porcelain`, `--oneline`, `--unified` |
| `diff` | Inspect full diff of specific hunks | `--staged`, `--file`, `--porcelain` |
| `add` | Stage hunks by hash | `--all`, `--file`, `--porcelain`, `--ref`, `--3way`, line specs (`sha:3-5,8`) |
| `reset` | Unstage hunks by hash | `--all`, `--file`, `--porcelain`, `--ref`, `--3way`, line specs |
| `commit` | Commit specific hunks directly | `-m <msg>`, `--all`, `--file`, `--amend`, `--dry-run`, `--ref`, `--3way`, line specs |
| `stash` | Save hunks to git stash, remove from worktree | `--all`, `--include-untracked`/`-u`, `--file`, `-m <msg>`, `pop` subcommand |
| `restore` | Revert worktree hunks (destructive) | `--all`, `--file`, `--force`, `--dry-run`, `--ref`, `--3way`, line specs |
| `count` | Bare integer hunk count | `--staged`, `--file` |
| `check` | Verify hashes still valid | `--staged`, `--exclusive`, `--allow-empty`, `--file`, `--porcelain` |

All commands accept `--help`, `--no-color`, `--tracked-only`, `--untracked-only`,
`--quiet`/`-q`, `--verbose`/`-v`, and `-U<n>`/`--unified=<n>`. SHA prefixes need at least 4 hex characters. Use `--file`
to disambiguate prefix collisions. Use `git-hunk <command> --help` for detailed
per-command help.

## Hash stability

Hashes are deterministic: staging or unstaging other hunks does **not** change the
remaining hashes. List once, then stage multiple hunks together in one command.

The hash is computed from: file path, stable line number (worktree side for unstaged,
HEAD side for staged), and diff content (`+`/`-` lines only). Staged and unstaged
hashes for the same hunk differ -- use `add`'s `->` output to track the mapping.

## New, deleted, and untracked files

Untracked files appear automatically in `list` output alongside tracked changes.
Use `--tracked-only` or `--untracked-only` to filter.

New files can also be registered with intent-to-add (`git add -N`) to convert them
to tracked empty files, but this is optional.

Deleted files appear automatically when a tracked file is removed.

## Working with hunks from history (`--ref` and `--3way`)

Every command accepts `--ref <refspec>`. A **single ref** like `HEAD~1`, `abc1234`,
or a branch name is shorthand for `<ref>^..<ref>` — i.e. *that commit's diff*
(matching `git show <ref>` semantics). A **range** like `main..HEAD` keeps its
literal "diff between two refs" meaning. To compare a ref against the worktree,
write the range form `main..HEAD` explicitly.

This unlocks two cherry-pick-by-hunk workflows:

### Re-apply a hunk from a past commit

```bash
git hunk list --ref HEAD~3            # see hunks introduced by HEAD~3
git hunk add  --ref HEAD~3 abc1234    # forward-apply that hunk into the index
git commit -m "rescue: re-apply lost helper"
```

Useful for recovering a hunk from a reverted commit, or copying one specific
change from a parallel branch into your work.

### Undo a hunk from a past commit

```bash
git hunk list --ref HEAD~3            # see hunks introduced by HEAD~3
git hunk restore --ref HEAD~3 abc1234 # reverse-apply that hunk to the worktree
```

Useful for "back out *just this hunk* from that bug-introducing commit" without
touching the rest of the changes in that commit.

### When context has drifted: `--3way`

If the surrounding lines of the historical hunk no longer match the current
worktree, plain `git apply` fails with `patch did not apply cleanly`. Add
`--3way` to fall back to a 3-way merge:

```bash
git hunk restore --ref HEAD~10 --3way abc1234
# either succeeds cleanly, or leaves <<<<<<< conflict markers in the worktree
```

`--3way` is supported by `add`, `reset`, `restore`, and `commit`.

### Cherry-pick a hunk into a fresh commit

```bash
git hunk commit --ref HEAD~5 abc1234 -m "cherry-pick: rescue"
```

Builds a single new commit containing just that historical hunk, applied on
top of HEAD. Useful when you want the rescue to be its own commit.

### Initial-commit edge case

`--ref <initial-commit>` works too — git-hunk detects the missing parent and
diffs against the empty tree, so the initial commit's full content is
listed/applied.

For deeper walkthroughs and recipes, see [docs/history-workflow.md](../../docs/history-workflow.md).

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
- [Ref support](references/ref-support.md) -- `--ref <refspec>` for diffing against branches, commits, and ranges
