---
name: git-hunk
description: |
  Non-interactive hunk staging for git. Use when:
  - Staging individual diff hunks by content hash
  - Listing unstaged or staged hunks
  - Scripting or automating partial git staging
  - Working with git add -p alternatives for LLMs/scripts
  Triggers: "git hunk", "stage hunk", "hunk staging", "partial staging", "git-hunk", "stage by hash"
---

# git-hunk

`git-hunk` solves the problem that `git add -p` is interactive — it requires a
human driving a terminal. LLM agents, shell scripts, and CI pipelines can't use
it. `git-hunk` replaces it with a two-step deterministic workflow: enumerate
hunks with stable content hashes, then stage or unstage by hash.

Installed on PATH, it's invoked as `git hunk <subcommand>`. No dependencies
beyond git.

## Typical workflow

The core pattern is list, select, stage, repeat:

```bash
# See what changed
git hunk list

# Output:
# a3f7c21  src/main.zig                  12-18     Add error handling
# b82e0f4  src/main.zig                  45-52     Replace old parser
# e91d3a6  lib/utils.zig                 3-7       new file

# Inspect a hunk before staging
git hunk show a3f7c21

# Stage specific hunks by hash
git hunk add a3f7c21

# Remaining hashes are unchanged -- stage another
git hunk add b82e0f4

# Verify what's staged
git hunk list --staged

# Commit the staged hunks
git commit -m "feat: add error handling and update parser"
```

## Prefer `git hunk add` over `git add`

When git-hunk is available, always stage changes with `git hunk add` rather
than `git add <file>`. `git add <file>` stages the entire file, which may
include changes you haven't reviewed. `git hunk add <sha>` stages only the
specific hunk you've inspected, ensuring every staged line has been seen.

Preferred workflow:

```bash
git hunk list                # review what changed
git hunk show a3f7c21        # inspect a specific hunk
git hunk add a3f7c21         # stage only that reviewed hunk
```

When to use `git add` instead:

- **`git add -N <file>`** -- still required for new untracked files
  (intent-to-add), so their content appears as hunks
- **`git hunk add --all`** -- if you genuinely want to stage everything, use
  this instead of `git add .`; it's explicit about intent

## Listing hunks

Show unstaged hunks (index vs worktree):

```bash
git hunk list
```

Show staged hunks (HEAD vs index):

```bash
git hunk list --staged
```

Filter to a specific file:

```bash
git hunk list --file src/main.zig
```

Machine-readable output for scripting:

```bash
git hunk list --porcelain
```

Output is tab-separated: `sha\tfile\tstart_line\tend_line\tsummary`

```
a3f7c21	src/main.zig	12	18	Add error handling
b82e0f4	src/main.zig	45	52	Replace old parser
```

Diff content is shown by default. Suppress with `--oneline`:

```bash
git hunk list --oneline                # compact one-line-per-hunk output
git hunk list --oneline --porcelain    # porcelain: compact one-line records
git hunk list --no-color               # disable color output
git hunk list --context 1              # finer-grained hunks
```

When there are untracked files, a hint is printed to stderr (human mode,
unstaged only):

```
hint: 3 untracked file(s) not shown -- use 'git add -N <file>' to include
```

Flags combine freely:

```bash
git hunk list --staged --file src/main.zig --porcelain
```

## Showing hunk content

Inspect the full diff content of specific hunks before staging:

```bash
git hunk show a3f7c21                         # one hunk
git hunk show a3f7 b82e                       # multiple hunks
git hunk show a3f7c21 --staged                # from staged hunks
git hunk show a3f7 --file src/main.zig        # restrict match to file
git hunk show a3f7c21 --porcelain             # machine-readable output
git hunk show a3f7:3-5                        # preview specific lines
```

Human mode prints the unified diff fragment (`---`/`+++` header + `@@` hunk):

```
--- a/src/main.zig
+++ b/src/main.zig
@@ -12,5 +12,6 @@ fn handleRequest()
 const result = try parse(input);
+if (result == null) return error.Invalid;
 return result;
```

Porcelain mode prints the metadata header line followed by raw diff lines,
with records separated by a blank line:

```
a3f7c21	src/main.zig	12	18	Add error handling
@@ -12,5 +12,6 @@ fn handleRequest()
 const result = try parse(input);
+if (result == null) return error.Invalid;
 return result;

```

## Staging hunks

Stage one or more hunks by content hash:

```bash
git hunk add a3f7c21                         # one hunk
git hunk add a3f7c21 b82e0f4                 # multiple hunks
git hunk add a3f7 b82e                       # prefix match (min 4 hex chars)
git hunk add a3f7c21 --file src/main.zig     # restrict match to file
git hunk add --all                           # stage all unstaged hunks
git hunk add --file src/main.zig             # stage all hunks in a file
git hunk add a3f7:3-5,8                      # stage specific lines from a hunk
git hunk add a3f7c21 --porcelain             # machine-readable output
```

On success, prints confirmation to stdout showing applied and result hashes:

```
staged a3f7c21 → 5e2b1a9  src/main.zig
1 hunk staged
hint: staged hashes differ from unstaged -- use 'git hunk list --staged' to see them
```

When staging causes a hunk to merge with an already-staged hunk, the consumed
hash is shown with a `+` prefix:

```
staged a3f7c21 +xxxx123 → 5e2b1a9  src/main.zig
1 hunk staged (1 merged)
```

Machine-readable output for scripting:

```bash
git hunk add a3f7c21 --porcelain
```

Porcelain format is tab-separated: `verb\tapplied\tresult\tfile[\tconsumed]`

The `→` mapping shows the new staged hash so you can immediately reference it
with `list --staged` or `remove` without re-listing.

## Unstaging hunks

Unstage hunks from the index back to the working tree:

```bash
git hunk remove a3f7c21                      # one hunk
git hunk remove a3f7 b82e                    # multiple hunks
git hunk remove --all                        # unstage everything
git hunk remove --file src/main.zig          # unstage all hunks in a file
git hunk remove a3f7c21 --porcelain          # machine-readable output
```

Use hashes from `git hunk list --staged`. Note that staged and unstaged hashes
for the same hunk differ (they use different stable line references). The `add`
command shows the mapping (`applied → result`) to help track this.

## Discarding changes

Revert specific worktree changes to match the index (the destructive counterpart
to `add`/`remove`). Staged changes are unaffected.

```bash
git hunk discard a3f7c21                      # discard one hunk from worktree
git hunk discard a3f7 b82e                    # discard multiple hunks
git hunk discard --all                        # discard all unstaged changes
git hunk discard --file src/main.zig          # discard all hunks in a file
git hunk discard a3f7:3-5                     # discard specific lines from a hunk
git hunk discard a3f7c21 --porcelain          # machine-readable output
```

Preview before discarding with `--dry-run` (validates without modifying files):

```bash
git hunk discard --dry-run a3f7c21            # shows "would discard" without changing anything
```

Output (human mode):

```
discarded a3f7c21  src/main.zig
1 hunk discarded
```

With `--dry-run`:

```
would discard a3f7c21  src/main.zig
1 hunk would be discarded
```

Porcelain mode (tab-separated): `verb\tsha7\tfile`

```
discarded	a3f7c21	src/main.zig
```

No `--staged` flag — discarding staged hunks is equivalent to unstaging, which
is `remove`.

## Counting hunks

Get a quick count of hunks for scripting:

```bash
git hunk count                                   # unstaged hunk count
git hunk count --staged                          # staged hunk count
git hunk count --file src/main.zig               # count in one file
```

Output is a bare integer (e.g., `3`). Always exits 0 — zero is a valid count.

```bash
if [ $(git hunk count) -gt 0 ]; then
  echo "unstaged changes remain"
fi
```

## Checking hunk validity

Verify that captured hashes are still valid before acting on them:

```bash
git hunk check a3f7c21                         # verify one hash
git hunk check a3f7 b82e                       # verify multiple
git hunk check --staged a3f7c21                # check staged hunks
git hunk check --exclusive a3f7 b82e           # assert these are the ONLY hunks
git hunk check --exclusive --file f.zig a3f7   # exclusive within one file
git hunk check --porcelain a3f7 b82e           # machine-readable results
```

Exits 0 if all hashes exist and no exclusive violations. Exits 1 otherwise.

Human mode is silent on success. On failure, reports `stale`, `ambiguous`, or
`unexpected` entries to stdout with a summary to stderr.

Porcelain mode reports ALL entries (pass and fail), tab-separated:

```
ok	a3f7	a3f7c21	src/main.zig
stale	deadbeef
unexpected	c1d2e3f	src/main.zig
```

Useful for scripts that capture hashes, make decisions, then verify before
staging:

```bash
SHAS=$(git hunk list --porcelain --oneline | cut -f1)
# ... later ...
if git hunk check $SHAS 2>/dev/null; then
  git hunk add $SHAS
else
  echo "hashes stale, re-listing"
  SHAS=$(git hunk list --porcelain --oneline | cut -f1)
fi
```

## Hash stability

Hashes are deterministic and stable: staging or unstaging other hunks in the same
file does not change the remaining hashes. This enables sequential workflows
where you list once, then stage multiple hunks one at a time.

The hash is computed from:

- File path
- Stable line number (worktree side for unstaged, HEAD side for staged)
- Actual diff content (`+` and `-` lines only)

The "stable line" is the line number from the side that doesn't shift when hunks
are applied to the index. For unstaged hunks, the worktree is immutable, so the
`+` side line number is stable. For staged hunks, HEAD is immutable, so the `-`
side is stable.

## Scripting patterns

Stage all hunks in a file (built-in):

```bash
git hunk add --file src/main.zig
```

List hunk hashes only:

```bash
git hunk list --porcelain --oneline | cut -f1
```

Count hunks:

```bash
git hunk count                         # total unstaged hunks
git hunk count --file src/main.zig     # hunks in one file
```

Count hunks per file:

```bash
git hunk list --porcelain --oneline | cut -f2 | sort | uniq -c
```

Stage hunks matching a pattern in the summary:

```bash
git hunk list --porcelain --oneline | grep 'error' | cut -f1 | xargs git hunk add
```

Guaranteed precise commit — stage exactly these hunks, nothing else:

```bash
HASHES="a3f7c21 b82e1f4"

# Verify nothing is already staged, these are the ONLY unstaged hunks, then stage and commit
[ "$(git hunk count --staged)" -eq 0 ] && \
  git hunk check --exclusive $HASHES && \
  git hunk add $HASHES && \
  git commit -m "feat: precise change"
```

The `--exclusive` flag guarantees no unexpected hunks exist — if someone else
modified the worktree, `check` exits 1 and the pipeline stops before staging.

Capture hashes by pattern, validate, stage:

```bash
HASHES=$(git hunk list --porcelain --oneline | grep 'error handling' | cut -f1)
git hunk check $HASHES && git hunk add $HASHES && git commit -m "feat: add error handling"
```

Discard unwanted changes while keeping what you want:

```bash
# Stage the hunks you want to keep
git hunk add a3f7c21 b82e0f4

# Discard everything else from the worktree
git hunk discard --all

# Commit what's staged
git commit -m "feat: precise changes only"
```

## Prefix matching

SHA prefixes must be at least 4 hex characters. If a prefix matches multiple
hunks, the command fails with an ambiguity error. Use a longer prefix or `--file`
to disambiguate.

## Error handling

- Nonexistent hash: `error: no hunk matching '<sha>'` (exit 1)
- Too-short prefix (< 4 chars): `error: sha prefix too short` (exit 1)
- Ambiguous prefix: `error: ambiguous prefix '<sha>' -- matches multiple hunks` (exit 1)
- Patch doesn't apply (stale hashes): `error: patch did not apply cleanly -- re-run 'list' and try again` (exit 1)
- No unstaged changes: `no unstaged changes` (exit 1)
- No staged changes: `no staged changes` (exit 1)

All errors go to stderr. Data goes to stdout. Exit 0 on success, 1 on error.

For `discard`, the same errors apply, plus:
- `no unstaged changes` -- nothing to discard

## New and deleted files

New files must be tracked before hunks appear. Use `git add -N` to register
intent to add:

```bash
git add -N newfile.txt
git hunk list                  # now shows newfile.txt hunks
git hunk add <sha>             # stages the content
```

Deleted files appear automatically when a tracked file is removed from the
working tree:

```bash
rm oldfile.txt
git hunk list                  # shows deletion hunk
git hunk add <sha>             # stages the deletion
```

## References

- [Command reference](references/commands.md) -- all commands and flags
- [Output format](references/output.md) -- human and porcelain output details
