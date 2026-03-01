# Command Reference

## git-hunk list

List diff hunks with content hashes.

```
git-hunk list [--staged] [--file <path>] [--porcelain] [--oneline] [--unified <n>] [--no-color]
```

### Flags

| Flag | Description |
|------|-------------|
| `--staged` | Show staged hunks (HEAD vs index) instead of unstaged (index vs worktree) |
| `--file <path>` | Only show hunks for the given file path. Path must match exactly as shown in diff output. |
| `--porcelain` | Tab-separated machine-readable output. See [output format](output.md). |
| `--oneline` | Compact one-line-per-hunk output without inline diff content. |
| `--unified <n>` / `-U<n>` / `--unified=<n>` | Number of context lines to use in diffs (default: git's `diff.context` or 3). Lower values produce more granular hunks. |
| `--tracked-only` | Only show hunks from tracked files. |
| `--untracked-only` | Only show hunks from untracked files. |
| `--no-color` | Disable color output. Color is also disabled automatically when stdout is not a TTY, or when the `NO_COLOR` environment variable is set. |
| `--quiet` / `-q` | Suppress all output except errors. Mutually exclusive with `--verbose`. |
| `--verbose` / `-v` | Show summary counts and hints after action output. Mutually exclusive with `--quiet`. |

### Examples

```bash
git-hunk list                                    # all unstaged hunks (with diffs)
git-hunk list --oneline                          # compact one-line-per-hunk
git-hunk list --staged                           # all staged hunks
git-hunk list --file src/main.zig                # unstaged hunks in one file
git-hunk list --staged --porcelain               # staged hunks, machine-readable
git-hunk list --oneline --porcelain              # compact porcelain output
git-hunk list --unified 1                        # finer-grained hunks
git-hunk list --no-color                         # disable color output
```

### Behavior

- Exits 0 with empty output if there are no hunks (or no hunks matching the filter).
- Binary files are skipped.
- Rename-only changes (no content diff) are skipped.
- Mode-only changes are skipped.
- Untracked files are included by default in unstaged mode. Use `--tracked-only` or `--untracked-only` to filter.

---

## git-hunk diff

Show the full diff content of specific hunks.

```
git-hunk diff <sha[:lines]>... [--staged] [--file <path>] [--porcelain] [--unified <n>] [--no-color]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `<sha[:lines]>...` | One or more SHA hex prefixes (minimum 4 characters). Prefix matching is supported. Optional `:lines` suffix selects specific hunk-relative lines (e.g., `a3f7:3-5,8`). |

### Flags

| Flag | Description |
|------|-------------|
| `--staged` | Show hunks from staged diff (HEAD vs index) instead of unstaged (index vs worktree) |
| `--file <path>` | Restrict hash matching to hunks in this file. |
| `--porcelain` | Machine-readable output: metadata header line + raw diff lines + blank separator. |
| `--tracked-only` | Only show hunks from tracked files. |
| `--untracked-only` | Only show hunks from untracked files. |
| `--unified <n>` / `-U<n>` / `--unified=<n>` | Number of context lines (default: git's `diff.context` or 3). Must match the value used with `list`. |
| `--no-color` | Disable color output. Color is also disabled automatically when stdout is not a TTY, or when the `NO_COLOR` environment variable is set. |
| `--quiet` / `-q` | Suppress all output except errors. Mutually exclusive with `--verbose`. |
| `--verbose` / `-v` | Show summary counts and hints after action output. Mutually exclusive with `--quiet`. |

### Examples

```bash
git-hunk diff a3f7c21                            # show one hunk's diff
git-hunk diff a3f7 b82e                          # show multiple hunks
git-hunk diff a3f7c21 --staged                   # show a staged hunk
git-hunk diff a3f7 --file src/main.zig           # restrict to file
git-hunk diff a3f7c21 --porcelain                # machine-readable output
git-hunk diff a3f7:3-5                           # preview specific lines
git-hunk diff a3f7:3-5,8                         # preview lines 3-5 and 8
git-hunk diff a3f7c21 --no-color                 # disable color output
```

### Behavior

- Reads the diff (unstaged by default, staged with `--staged`), resolves each SHA prefix to a hunk, and prints the diff content.
- Human mode prints `patch_header` (`---`/`+++` lines) followed by `raw_lines` (`@@` header + body). Multiple hunks are separated by a blank line.
- Porcelain mode prints the metadata header line (same format as `list --porcelain`: `sha\tfile\tstart\tend\tsummary`), then the raw diff lines verbatim, then a blank line separator.
- Duplicate SHA prefixes that resolve to the same hunk are deduplicated.
- Exits 1 if any SHA prefix doesn't match or is ambiguous.

### Errors

Same error types as `add`:

| Error | Cause |
|-------|-------|
| `error: sha prefix too short (minimum 4 chars): '<sha>'` | Prefix is less than 4 hex characters |
| `error: invalid hex in sha prefix: '<sha>'` | Prefix contains non-hex characters |
| `error: no hunk matching '<sha>'` | No hunk matches the prefix (with optional file filter) |
| `error: ambiguous prefix '<sha>' -- matches multiple hunks` | Multiple hunks match the prefix |
| `no unstaged changes` / `no staged changes` | Nothing to diff |
| `error: at least one <sha> argument required` | No SHA arguments provided |

---

## git-hunk add

Stage hunks by content hash.

```
git-hunk add [<sha[:lines]>...] [--file <path>] [--all] [--porcelain] [--unified <n>] [--no-color]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `<sha[:lines]>...` | One or more SHA hex prefixes (minimum 4 characters). Prefix matching is supported. Optional `:lines` suffix stages specific hunk-relative lines (e.g., `a3f7:3-5,8`). Optional when `--all` or `--file` is used. |

### Flags

| Flag | Description |
|------|-------------|
| `--file <path>` | Restrict hash matching to hunks in this file. When used without SHAs, stages all hunks in the file. |
| `--all` | Stage all unstaged hunks. No SHA arguments required. |
| `--porcelain` | Tab-separated machine-readable output. See [output format](output.md#porcelain-format-1). |
| `--tracked-only` | Only include hunks from tracked files. |
| `--untracked-only` | Only include hunks from untracked files. |
| `--unified <n>` / `-U<n>` / `--unified=<n>` | Number of context lines (default: git's `diff.context` or 3). Must match the value used with `list`. |
| `--no-color` | Disable color output. Color is also disabled automatically when stdout is not a TTY, or when the `NO_COLOR` environment variable is set. |
| `--quiet` / `-q` | Suppress all output except errors. Mutually exclusive with `--verbose`. |
| `--verbose` / `-v` | Show summary counts and hints after action output. Mutually exclusive with `--quiet`. |

### Examples

```bash
git-hunk add a3f7c21                             # stage one hunk (full 7-char hash)
git-hunk add a3f7                                # stage by 4-char prefix
git-hunk add a3f7c21 b82e0f4 e91d3a6            # stage multiple hunks
git-hunk add a3f7 --file src/main.zig            # restrict to file
git-hunk add --all                               # stage all unstaged hunks
git-hunk add --file src/main.zig                 # stage all hunks in a file
git-hunk add a3f7:3-5,8                          # stage specific lines from a hunk
git-hunk add a3f7c21 --porcelain                 # machine-readable output
git-hunk add a3f7c21 --no-color                  # disable color output
```

### Behavior

- Reads unstaged diff, matches each SHA prefix to a hunk, builds a combined patch, applies via `git apply --cached`.
- All matched hunks are applied in a single `git apply` invocation.
- With `--all`, stages every unstaged hunk. With `--file` and no SHAs, stages all hunks in that file.
- Captures target-side (staged) hunks before and after applying to detect merges.
- On success, prints one line per **result hunk** to stdout: `staged {applied...} [+{consumed}...] → {result}  {file}`. Applied hashes are yellow, consumed hashes are dim, result hashes are green.
- When staging causes a hunk to merge with an already-staged hunk, the consumed hash appears with a `+` prefix.
- With `--verbose`, prints a count summary to stderr: `N hunk(s) staged`. Appends `(M merged)` when target-side hunks were consumed.
- With `--verbose`, prints a hint to stderr: `hint: staged hashes differ from unstaged -- use 'git hunk list --staged' to see them`.
- With `--porcelain`, output is tab-separated: `verb\tapplied\tresult\tfile[\tconsumed]`.
- Exits 1 if any SHA prefix doesn't match or is ambiguous.
- Exits 1 if the patch doesn't apply (index changed since listing).

### Errors

| Error | Cause |
|-------|-------|
| `error: sha prefix too short (minimum 4 chars): '<sha>'` | Prefix is less than 4 hex characters |
| `error: invalid hex in sha prefix: '<sha>'` | Prefix contains non-hex characters |
| `error: no hunk matching '<sha>'` | No hunk matches the prefix (with optional file filter) |
| `error: ambiguous prefix '<sha>' -- matches multiple hunks` | Multiple hunks match the prefix |
| `error: patch did not apply cleanly` | Index changed since hunks were listed |
| `no unstaged changes` | Nothing to stage |
| `error: at least one <sha> argument required` | No SHA arguments and no `--all`/`--file` flag |

---

## git-hunk reset

Unstage hunks by content hash.

```
git-hunk reset [<sha[:lines]>...] [--file <path>] [--all] [--porcelain] [--unified <n>] [--no-color]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `<sha[:lines]>...` | One or more SHA hex prefixes (minimum 4 characters) from `git-hunk list --staged`. Optional `:lines` suffix unstages specific lines. Optional when `--all` or `--file` is used. |

### Flags

| Flag | Description |
|------|-------------|
| `--file <path>` | Restrict hash matching to hunks in this file. When used without SHAs, unstages all hunks in the file. |
| `--all` | Unstage all staged hunks. No SHA arguments required. |
| `--porcelain` | Tab-separated machine-readable output. See [output format](output.md#porcelain-format-1). |
| `--tracked-only` | Only include hunks from tracked files. |
| `--untracked-only` | Only include hunks from untracked files. |
| `--unified <n>` / `-U<n>` / `--unified=<n>` | Number of context lines (default: git's `diff.context` or 3). Must match the value used with `list`. |
| `--no-color` | Disable color output. Color is also disabled automatically when stdout is not a TTY, or when the `NO_COLOR` environment variable is set. |
| `--quiet` / `-q` | Suppress all output except errors. Mutually exclusive with `--verbose`. |
| `--verbose` / `-v` | Show summary counts and hints after action output. Mutually exclusive with `--quiet`. |

### Examples

```bash
git-hunk reset a3f7c21                          # unstage one hunk
git-hunk reset a3f7 b82e                        # unstage multiple
git-hunk reset a3f7 --file src/main.zig         # restrict to file
git-hunk reset --all                            # unstage everything
git-hunk reset --file src/main.zig              # unstage all hunks in a file
git-hunk reset a3f7c21 --porcelain              # machine-readable output
git-hunk reset a3f7c21 --no-color               # disable color output
```

### Behavior

- Reads staged diff (`--cached`), matches SHA prefixes, applies the patch in reverse via `git apply --cached --reverse`.
- With `--all`, unstages every staged hunk. With `--file` and no SHAs, unstages all hunks in that file.
- Captures target-side (unstaged) hunks before and after applying to detect merges.
- On success, prints one line per **result hunk** to stdout: `unstaged {applied...} [+{consumed}...] → {result}  {file}`. When unstaging causes a merge with an existing unstaged hunk, the consumed hash appears with a `+` prefix.
- With `--verbose`, prints a count summary to stderr: `N hunk(s) unstaged`. Appends `(M merged)` when target-side hunks were consumed.
- With `--porcelain`, output is tab-separated: `verb\tapplied\tresult\tfile[\tconsumed]`.
- Important: staged hashes differ from unstaged hashes for the same hunk. Always use hashes from `git-hunk list --staged`.

### Errors

Same error types as `add`, with `no staged changes` instead of `no unstaged changes`.

---

## git-hunk restore

Restore worktree to match the index. Reverts specific hunks to match the index.

```
git-hunk restore [<sha[:lines]>...] [--file <path>] [--all] [--dry-run] [--porcelain] [--unified <n>] [--no-color]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `<sha[:lines]>...` | One or more SHA hex prefixes (minimum 4 characters). Prefix matching is supported. Optional `:lines` suffix restores specific hunk-relative lines (e.g., `a3f7:3-5,8`). Optional when `--all` or `--file` is used. |

### Flags

| Flag | Description |
|------|-------------|
| `--file <path>` | Restrict hash matching to hunks in this file. When used without SHAs, restores all hunks in the file. |
| `--all` | Restore all unstaged hunks. No SHA arguments required. |
| `--dry-run` | Preview what would be restored without modifying the worktree. Uses `git apply --check`. |
| `--force` | Required to restore untracked files (they are deleted permanently). |
| `--porcelain` | Tab-separated machine-readable output. |
| `--tracked-only` | Only include hunks from tracked files. |
| `--untracked-only` | Only include hunks from untracked files. |
| `--unified <n>` / `-U<n>` / `--unified=<n>` | Number of context lines (default: git's `diff.context` or 3). Must match the value used with `list`. |
| `--no-color` | Disable color output. Color is also disabled automatically when stdout is not a TTY, or when the `NO_COLOR` environment variable is set. |
| `--quiet` / `-q` | Suppress all output except errors. Mutually exclusive with `--verbose`. |
| `--verbose` / `-v` | Show summary counts and hints after action output. Mutually exclusive with `--quiet`. |

No `--staged` flag. Restoring staged changes is equivalent to unstaging, which is `reset`.

### Examples

```bash
git-hunk restore a3f7c21                             # restore one hunk
git-hunk restore a3f7                                # restore by 4-char prefix
git-hunk restore a3f7c21 b82e0f4                     # restore multiple hunks
git-hunk restore a3f7 --file src/main.zig            # restrict to file
git-hunk restore --all                               # restore all unstaged hunks
git-hunk restore --file src/main.zig                 # restore all hunks in a file
git-hunk restore a3f7:3-5,8                          # restore specific lines
git-hunk restore --dry-run a3f7c21                   # preview without modifying
git-hunk restore --force a3f7c21                     # restore untracked file (deletes it)
git-hunk restore a3f7c21 --porcelain                 # machine-readable output
git-hunk restore a3f7c21 --no-color                  # disable color output
```

### Behavior

- Reads unstaged diff, matches each SHA prefix to a hunk, builds a combined patch, applies via `git apply --reverse --unidiff-zero` (no `--cached`).
- All matched hunks are applied in a single `git apply` invocation (atomic).
- With `--all`, restores every unstaged hunk. With `--file` and no SHAs, restores all hunks in that file.
- With `--dry-run`, validates via `git apply --reverse --check` without modifying the worktree.
- Staged changes are unaffected — only the worktree is modified.
- On success, prints one line per restored hunk to stdout: `restored {sha7}  {file}`. SHA in yellow for human mode.
- With `--dry-run`, verb is `would restore` (human) or `would-restore` (porcelain).
- With `--verbose`, prints a count summary to stderr: `N hunk(s) restored` or `N hunk(s) would be restored`.
- With `--porcelain`, output is tab-separated: `verb\tsha7\tfile`.
- Untracked files require `--force` to restore. Without `--force`, any matched untracked hunk causes exit 1 with an error message. With `--force`, untracked files are deleted permanently.
- Exits 1 if any SHA prefix doesn't match or is ambiguous.
- Exits 1 if the patch doesn't apply (worktree changed since listing).

### Errors

| Error | Cause |
|-------|-------|
| `error: sha prefix too short (minimum 4 chars): '<sha>'` | Prefix is less than 4 hex characters |
| `error: invalid hex in sha prefix: '<sha>'` | Prefix contains non-hex characters |
| `error: no hunk matching '<sha>'` | No hunk matches the prefix (with optional file filter) |
| `error: ambiguous prefix '<sha>' -- matches multiple hunks` | Multiple hunks match the prefix |
| `error: <sha> (<file>) is an untracked file -- use --force to delete` | Untracked file matched without `--force` (bypassed by `--dry-run`) |
| `error: patch did not apply cleanly` | Worktree changed since hunks were listed |
| `no unstaged changes` | Nothing to restore |
| `error: at least one <sha> argument required` | No SHA arguments and no `--all`/`--file` flag |

---

## git-hunk count

Count diff hunks.

```
git-hunk count [--staged] [--file <path>] [--unified <n>]
```

### Flags

| Flag | Description |
|------|-------------|
| `--staged` | Count staged hunks (HEAD vs index) instead of unstaged (index vs worktree) |
| `--file <path>` | Only count hunks for the given file path. |
| `--tracked-only` | Only count hunks from tracked files. |
| `--untracked-only` | Only count hunks from untracked files. |
| `--unified <n>` / `-U<n>` / `--unified=<n>` | Number of context lines (default: git's `diff.context` or 3). Affects hunk splitting and therefore count. |
| `--quiet` / `-q` | Suppress all output except errors. Mutually exclusive with `--verbose`. |
| `--verbose` / `-v` | Show summary counts and hints after action output. Mutually exclusive with `--quiet`. |

`--porcelain` and `--no-color` are accepted for consistency but have no effect.

### Examples

```bash
git-hunk count                                   # count all unstaged hunks
git-hunk count --staged                          # count all staged hunks
git-hunk count --file src/main.zig               # count unstaged hunks in one file
git-hunk count --unified 0                       # count with zero context (finer granularity)

# Use in scripts
if [ $(git-hunk count) -gt 0 ]; then
  echo "unstaged changes remain"
fi
```

### Behavior

- Outputs a bare integer followed by a newline. No labels, no padding.
- Always exits 0. Zero hunks is a valid count, not an error.
- Output is identical with or without `--porcelain`.
- No stderr output.

---

## git-hunk check

Validate that hunk hashes exist in the current diff.

```
git-hunk check [--staged] [--exclusive] [--file <path>] [--porcelain] [--no-color] [--unified <n>] <sha>...
```

### Arguments

| Argument | Description |
|----------|-------------|
| `<sha>...` | One or more SHA hex prefixes (minimum 4 characters). Line specs (e.g., `sha:1-3`) are rejected. |

### Flags

| Flag | Description |
|------|-------------|
| `--staged` | Check against staged hunks (HEAD vs index) instead of unstaged (index vs worktree) |
| `--exclusive` | Assert the provided hashes are the ONLY hunks (scoped by `--file` if given) |
| `--file <path>` | Scope all lookups to hunks in this file |
| `--porcelain` | Machine-parseable tab-separated output (reports all entries) |
| `--tracked-only` | Only check hunks from tracked files. |
| `--untracked-only` | Only check hunks from untracked files. |
| `--no-color` | Disable colored output |
| `--unified <n>` / `-U<n>` / `--unified=<n>` | Number of context lines (default: git's `diff.context` or 3). Must match the value used with `list`. |
| `--quiet` / `-q` | Suppress all output except errors. Mutually exclusive with `--verbose`. |
| `--verbose` / `-v` | Show summary counts and hints after action output. Mutually exclusive with `--quiet`. |

### Examples

```bash
git-hunk check a3f7c21                           # verify one hash exists
git-hunk check a3f7 b82e                         # verify multiple
git-hunk check a3f7c21 --staged                  # check staged hunks
git-hunk check --exclusive a3f7 b82e             # assert these are the only hunks
git-hunk check --exclusive --file f.zig a3f7     # exclusive within one file
git-hunk check --porcelain a3f7 b82e             # machine-readable results
git-hunk check a3f7c21 --no-color                # disable color output
```

### Behavior

- Reads the diff (unstaged by default, staged with `--staged`), resolves each SHA prefix, and reports validity.
- Human mode: silent on success (exit 0). On failure, prints `stale`, `ambiguous`, or `unexpected` lines to stdout, summary to stderr.
- Porcelain mode: reports ALL entries. `ok\t{prefix}\t{sha7}\t{file}`, `stale\t{prefix}`, `ambiguous\t{prefix}`, `unexpected\t{sha7}\t{file}`.
- Duplicate SHA prefixes in input are deduplicated (checked once).
- With `--exclusive`, any hunks not matched by provided hashes are reported as `unexpected`.
- `--file` scopes the universe for both lookup and exclusive checks.
- Line specs (`sha:lines`) are rejected: `error: line specs not supported for check`.
- Exits 0 if all checks pass. Exits 1 if any hash is stale/ambiguous or exclusive constraint is violated.

### Errors

| Error | Cause |
|-------|-------|
| `error: at least one <sha> argument required` | No SHA arguments provided |
| `error: sha prefix too short (minimum 4 chars): '<sha>'` | Prefix is less than 4 hex characters |
| `error: invalid hex in sha prefix: '<sha>'` | Prefix contains non-hex characters |
| `error: line specs not supported for check` | Line spec used with check command |

---

## git-hunk stash

Stash hunks into a real git stash entry and remove them from the worktree.

```
git-hunk stash [push] [<sha>...] [--file <path>] [--all] [-u] [-m <message>] [--porcelain] [--unified <n>] [--no-color]
git-hunk stash pop
```

### Subcommands

| Subcommand | Description |
|------------|-------------|
| `push` | Stash hunks (default, keyword optional). |
| `pop` | Restore the most recent stash via `git stash pop`. No other flags or args accepted. |

### Arguments

| Argument | Description |
|----------|-------------|
| `<sha>...` | One or more SHA hex prefixes (minimum 4 characters). Prefix matching is supported. Line specs are NOT supported — whole hunks only. Optional when `--all` or `--file` is used. |

### Flags

| Flag | Description |
|------|-------------|
| `--file <path>` | Restrict hash matching to hunks in this file. When used without SHAs, stashes all hunks in the file. |
| `--all` | Stash all unstaged hunks. Excludes untracked files by default (like `git stash`). Use `-u`/`--include-untracked` to include them. |
| `-u`, `--include-untracked` | Include untracked files when using `--all`. Not needed when targeting untracked hunks by explicit hash. |
| `-m`, `--message <msg>` | Custom stash message. If omitted, auto-generates from affected file paths. |
| `--tracked-only` | Only include hunks from tracked files. |
| `--untracked-only` | Only include hunks from untracked files. |
| `--porcelain` | Tab-separated machine-readable output. |
| `--unified <n>` / `-U<n>` / `--unified=<n>` | Number of context lines (default: git's `diff.context` or 3). Must match the value used with `list`. |
| `--no-color` | Disable color output. Color is also disabled automatically when stdout is not a TTY, or when the `NO_COLOR` environment variable is set. |
| `--quiet` / `-q` | Suppress all output except errors. Mutually exclusive with `--verbose`. |
| `--verbose` / `-v` | Show summary counts and hints after action output. Mutually exclusive with `--quiet`. |

### Examples

```bash
git-hunk stash a3f7c21                          # stash one hunk
git-hunk stash a3f7 b82e                        # stash multiple hunks
git-hunk stash --all                            # stash all tracked unstaged hunks
git-hunk stash --all -u                         # stash all including untracked files
git-hunk stash push --all --include-untracked   # same (explicit push keyword)
git-hunk stash --file src/main.zig              # stash hunks in one file
git-hunk stash -m "wip: auth refactor"          # custom stash message
git-hunk stash pop                              # restore most recent stash
git-hunk stash a3f7c21 --porcelain              # machine-readable output
```

### Behavior

- Reads unstaged diff, matches each SHA prefix to a hunk, creates a git stash containing those hunks, then removes them from the worktree.
- The stash is a real git stash entry visible in `git stash list`, `git stash show`, and `git stash pop`.
- Uses a two-diff strategy to ensure correct stash content even when the index is dirty.
- With `--all`, stashes tracked hunks only (matching `git stash` behavior). Use `-u`/`--include-untracked` to include untracked files. Explicit hash targeting always works for untracked hunks regardless of `-u`.
- Untracked files are stored using git's native 3-parent stash format (HEAD, index, untracked tree). `git stash pop` restores them as untracked files. Executable file permissions are preserved.
- Auto-generates a stash message from affected file paths (e.g., `git hunk stash: src/main.zig, src/args.zig`) unless `-m` is provided.
- On success, prints one line per stashed hunk to stdout: `stashed {sha7}  {file}`. SHA in yellow for human mode.
- With `--verbose`, prints a count summary to stderr: `N hunk(s) stashed`.
- With `--verbose`, prints a hint to stderr: `hint: use 'git stash list' to see stashed entries, 'git hunk stash pop' to restore`.
- With `--porcelain`, output is tab-separated: `stashed\t{sha7}\t{file}`.
- `pop` runs `git stash pop` and prints `popped stash@{0}` to stderr. Rejects all other flags and arguments.
- Line specs (`sha:lines`) are rejected: `error: line specs not supported for stash`.
- `--include-untracked` conflicts with `--tracked-only` — error if both given.
- `git apply` failures during worktree cleanup are handled gracefully (error returned, not process exit).
- Exits 1 if any SHA prefix doesn't match, is ambiguous, or if there are no unstaged changes.

### Errors

| Error | Cause |
|-------|-------|
| `error: sha prefix too short (minimum 4 chars): '<sha>'` | Prefix is less than 4 hex characters |
| `error: invalid hex in sha prefix: '<sha>'` | Prefix contains non-hex characters |
| `error: no hunk matching '<sha>'` | No hunk matches the prefix (with optional file filter) |
| `error: ambiguous prefix '<sha>' -- matches multiple hunks` | Multiple hunks match the prefix |
| `error: line specs not supported for stash` | Line spec used with stash command |
| `error: pop does not accept arguments or flags` | `pop` used with other flags or arguments |
| `error: --include-untracked cannot be combined with --tracked-only` | Conflicting filter flags |
| `no unstaged changes` | Nothing to stash |
| `error: at least one <sha> argument required` | No SHA arguments and no `--all`/`--file` flag |

---

## git-hunk help

Show usage information. All commands accept `--help` / `-h` for per-command help.

```
git-hunk --help                    # global help (commands overview)
git-hunk -h                        # same
git-hunk help                      # same
git-hunk <command> --help          # per-command help (flags, examples, behavior)
git-hunk <command> -h              # same
git-hunk help <command>            # same
```

### Note on git subcommand usage

When invoked as `git hunk --help`, git intercepts the `--help` flag and opens
`man git-hunk` instead of passing it to the binary. Use `git hunk help [command]`
for inline help when using the git subcommand form.

---

## git-hunk --version

Show version.

```
git-hunk --version
git-hunk -V
```
