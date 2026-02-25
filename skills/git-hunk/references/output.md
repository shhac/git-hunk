# Output Format

## Human-readable (default)

Columnar output with fixed-width alignment:

```
{sha7}  {file:<40}  {range:<8}  {summary}
```

Example:

```
a3f7c21  src/main.zig                              12-18     Add error handling
b82e0f4  src/main.zig                              45-52     Replace old parser
e91d3a6  lib/utils.zig                             3-7       new file
d4c891f  README.md                                 1-1       deleted
```

### Columns

| Column | Width | Description |
|--------|-------|-------------|
| sha | 7 chars | Content hash, always 7 hex characters |
| file | left-aligned, 40 chars | File path from diff |
| range | left-aligned, 8 chars | `start-end` line range |
| summary | variable | Function context, first changed line, or status |

### Line range

The range shows `start_line-end_line` using the stable side:

- **Unstaged hunks**: worktree (new/`+`) side line numbers
- **Staged hunks**: HEAD (old/`-`) side line numbers

For deleted files: `0-0` (no new-side lines).

### Summary

Summary is derived in priority order:

1. **Function context** from the `@@` header (e.g., `Add error handling`, `fn main()`)
2. **First changed line** content, with `+`/`-` prefix and leading whitespace stripped
3. **`new file`** for new files
4. **`deleted`** for deleted files
5. Empty string if none of the above apply

## Porcelain (`--porcelain`)

Tab-separated fields, one hunk per line. No headers, no alignment padding.

```
sha\tfile\tstart_line\tend_line\tsummary\n
```

Example:

```
a3f7c21	src/main.zig	12	18	Add error handling
b82e0f4	src/main.zig	45	52	Replace old parser
e91d3a6	lib/utils.zig	1	3	new file
d4c891f	README.md	1	5	deleted
```

### Fields

| # | Field | Type | Description |
|---|-------|------|-------------|
| 1 | sha | string | 7-character hex content hash |
| 2 | file | string | File path (no quoting, no escaping) |
| 3 | start_line | integer | First line of hunk range (stable side) |
| 4 | end_line | integer | Last line of hunk range (stable side) |
| 5 | summary | string | Function context, first changed line, or status. May be empty. |

### Line numbers

Line numbers refer to the stable side of the diff:

- **Unstaged**: new-side (worktree) lines. The worktree doesn't change when
  hunks are staged, so these numbers remain valid.
- **Staged**: old-side (HEAD) lines. HEAD doesn't change when hunks are
  unstaged, so these numbers remain valid.

For new files (`@@ -0,0 +1,N @@`): `start_line=1`, `end_line=N` (unstaged).
For deleted files (`@@ -1,N +0,0 @@`): `start_line=0`, `end_line=0` (unstaged);
`start_line=1`, `end_line=N` (staged).

### Parsing

```bash
# Extract all hashes
git hunk list --porcelain | cut -f1

# Extract file paths
git hunk list --porcelain | cut -f2

# Filter by file
git hunk list --porcelain | awk -F'\t' '$2 == "src/main.zig"'

# Get start line of first hunk
git hunk list --porcelain | head -1 | cut -f3
```

## Staging/unstaging confirmation

`add` and `remove` print one line per hunk to stdout:

```
staged a3f7c21  src/main.zig
staged b82e0f4  src/main.zig
```

```
unstaged a3f7c21  src/main.zig
```

Format: `{verb} {sha7}  {file}` (two spaces between hash and file).

## Error output

All errors are written to stderr. Examples:

```
error: no hunk matching 'deadbeef'
error: ambiguous prefix 'a3f7' -- matches multiple hunks
error: sha prefix too short (minimum 4 chars): 'ab'
error: patch did not apply cleanly -- re-run 'list' and try again
no unstaged changes
no staged changes
error: at least one <sha> argument required
error: unknown command 'badcmd'
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success. For `list`, may produce empty output (no matching hunks). |
| 1 | Error. Message written to stderr. |
