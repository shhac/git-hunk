# Command Reference

## git-hunk list

List diff hunks with content hashes.

```
git-hunk list [--staged] [--file <path>] [--porcelain]
```

### Flags

| Flag | Description |
|------|-------------|
| `--staged` | Show staged hunks (HEAD vs index) instead of unstaged (index vs worktree) |
| `--file <path>` | Only show hunks for the given file path. Path must match exactly as shown in diff output. |
| `--porcelain` | Tab-separated machine-readable output. See [output format](output.md). |

### Examples

```bash
git-hunk list                                    # all unstaged hunks
git-hunk list --staged                           # all staged hunks
git-hunk list --file src/main.zig                # unstaged hunks in one file
git-hunk list --staged --porcelain               # staged hunks, machine-readable
git-hunk list --file src/main.zig --porcelain    # combine filters
```

### Behavior

- Exits 0 with empty output if there are no hunks (or no hunks matching the filter).
- Binary files are skipped.
- Rename-only changes (no content diff) are skipped.
- Mode-only changes are skipped.

---

## git-hunk add

Stage hunks by content hash.

```
git-hunk add <sha>... [--file <path>]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `<sha>...` | One or more SHA hex prefixes (minimum 4 characters). Prefix matching is supported. |

### Flags

| Flag | Description |
|------|-------------|
| `--file <path>` | Restrict hash matching to hunks in this file. Useful for disambiguating short prefixes. |

### Examples

```bash
git-hunk add a3f7c21                             # stage one hunk (full 7-char hash)
git-hunk add a3f7                                # stage by 4-char prefix
git-hunk add a3f7c21 b82e0f4 e91d3a6            # stage multiple hunks
git-hunk add a3f7 --file src/main.zig            # restrict to file
```

### Behavior

- Reads unstaged diff, matches each SHA prefix to a hunk, builds a combined patch, applies via `git apply --cached`.
- All matched hunks are applied in a single `git apply` invocation.
- On success, prints one confirmation line per hunk to stdout: `staged <sha7>  <file>`
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
| `error: at least one <sha> argument required` | No SHA arguments provided |

---

## git-hunk remove

Unstage hunks by content hash.

```
git-hunk remove <sha>... [--file <path>]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `<sha>...` | One or more SHA hex prefixes (minimum 4 characters) from `git-hunk list --staged`. |

### Flags

| Flag | Description |
|------|-------------|
| `--file <path>` | Restrict hash matching to hunks in this file. |

### Examples

```bash
git-hunk remove a3f7c21                          # unstage one hunk
git-hunk remove a3f7 b82e                        # unstage multiple
git-hunk remove a3f7 --file src/main.zig         # restrict to file
```

### Behavior

- Reads staged diff (`--cached`), matches SHA prefixes, applies the patch in reverse via `git apply --cached --reverse`.
- On success, prints: `unstaged <sha7>  <file>`
- Important: staged hashes differ from unstaged hashes for the same hunk. Always use hashes from `git-hunk list --staged`.

### Errors

Same error types as `add`, with `no staged changes` instead of `no unstaged changes`.

---

## git-hunk help

Show usage information.

```
git-hunk help
git-hunk --help
git-hunk -h
```

---

## git-hunk --version

Show version.

```
git-hunk --version
git-hunk -V
```
