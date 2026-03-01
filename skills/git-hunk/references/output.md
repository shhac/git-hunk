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

1. **`new file`** for new files
2. **`deleted`** for deleted files
3. **First changed line** content, with `+`/`-` prefix and leading whitespace stripped
4. **Function context** from the `@@` header (e.g., `fn main()`) as fallback
5. Empty string if none of the above apply

## Diff output (default)

By default, each hunk's raw diff content is printed after the metadata line.
Use `--oneline` to suppress diff content for compact output.

### Human mode

Diff lines are indented by 4 spaces, followed by a blank line:

```
a3f7c21  src/main.zig                              12-18     Add error handling
    @@ -12,5 +12,6 @@ fn handleRequest()
     const result = try parse(input);
    +if (result == null) return error.Invalid;
     return result;

b82e0f4  src/main.zig                              45-52     Replace old parser
    @@ -45,6 +45,7 @@
    ...
```

### Porcelain mode

Raw diff lines follow the metadata line verbatim (no indentation). Records are
separated by a blank line:

```
a3f7c21	src/main.zig	12	18	Add error handling
@@ -12,5 +12,6 @@ fn handleRequest()
 const result = try parse(input);
+if (result == null) return error.Invalid;
 return result;

b82e0f4	src/main.zig	45	52	Replace old parser
@@ -45,6 +45,7 @@
...
```

Blank lines are safe as record separators because unified diff hunk body lines
always start with ` `, `+`, `-`, or `\`.

## Diff command output

`diff` prints the full diff content for specific hunks.

### Human mode

Prints the patch header (`---`/`+++` lines) followed by `raw_lines` (the `@@`
header and body). Multiple hunks are separated by a blank line:

```
--- a/src/main.zig
+++ b/src/main.zig
@@ -12,5 +12,6 @@ fn handleRequest()
 const result = try parse(input);
+if (result == null) return error.Invalid;
 return result;

--- a/src/main.zig
+++ b/src/main.zig
@@ -45,6 +45,7 @@
-old_parser(input);
+new_parser(input);
 return result;
```

### Porcelain mode

Same format as `list --porcelain` (without `--oneline`): metadata header line, then raw diff
lines, then blank line separator:

```
a3f7c21	src/main.zig	12	18	Add error handling
@@ -12,5 +12,6 @@ fn handleRequest()
 const result = try parse(input);
+if (result == null) return error.Invalid;
 return result;

```

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
git hunk list --porcelain --oneline | cut -f1

# Extract file paths
git hunk list --porcelain --oneline | cut -f2

# Filter by file
git hunk list --porcelain --oneline | awk -F'\t' '$2 == "src/main.zig"'

# Get start line of first hunk
git hunk list --porcelain --oneline | head -1 | cut -f3
```

## Staging/unstaging confirmation

`add` and `reset` print one line per **result hunk** to stdout. Each line shows
the applied (input) hashes, any consumed (merged) hashes, and the new result
hash on the target side:

```
{verb} {applied...} [+{consumed}...] → {result[,result...]}  {file}
```

### Tokens

| Token | Meaning |
|-------|---------|
| `{verb}` | `staged` or `unstaged` |
| `{applied}` | Hash the user asked to stage/unstage. Space-separated if multiple inputs merged. May include `:line-spec`. |
| `+{consumed}` | Existing target-side hash absorbed into the result. Prefixed with `+`. |
| `→` | Unicode arrow (U+2192). Always present. |
| `{result}` | New target-side hash. Comma-separated if line-spec produced multiple outputs. `?` if no mapping found. |
| `{file}` | File path (two spaces after result hash). |

### Examples

Simple staging (1→1):

```
staged a3f7c21 → 5e2b1a9  src/main.zig
```

Merge with existing staged hunk:

```
staged a3f7c21 +xxxx123 → 5e2b1a9  src/main.zig
```

Two inputs merge with each other:

```
staged a3f7c21 b82e0f4 → 5e2b1a9  src/main.zig
```

Two inputs + existing merge (bridge):

```
staged a3f7c21 b82e0f4 +xxxx123 +yyyy456 → 5e2b1a9  src/main.zig
```

Line spec with multiple outputs:

```
staged a3f7c21:1,10 → 5e2b1a9,8c3d7f2  src/main.zig
```

Unstaging:

```
unstaged 5e2b1a9 → a3f7c21  src/main.zig
unstaged 5e2b1a9 +dddd789 → a3f7c21  src/main.zig
```

### Color (human mode, when TTY)

- Applied hashes: yellow (`\x1b[33m`)
- Consumed hashes (including `+` prefix): dim (`\x1b[2m`)
- Result hashes: green (`\x1b[32m`)
- Arrow, file path: default

Disable with `--no-color` or the `NO_COLOR` environment variable.

### Porcelain format

With `--porcelain`, output is tab-separated, one line per result hunk:

```
{verb}\t{applied}\t{result}\t{file}[\t{consumed}]
```

| Field | Description |
|-------|-------------|
| `verb` | `staged` or `unstaged` |
| `applied` | Space-separated applied hashes (with `:line-spec` if any) |
| `result` | Comma-separated result hashes on target side |
| `file` | File path |
| `consumed` | Optional. Comma-separated consumed hashes. Omitted if none. |

Examples:

```
staged	a3f7c21	5e2b1a9	src/main.zig
staged	a3f7c21	5e2b1a9	src/main.zig	xxxx123
staged	a3f7c21 b82e0f4	5e2b1a9	src/main.zig	xxxx123
staged	a3f7c21:1,10	5e2b1a9,8c3d7f2	src/main.zig
```

### Summary line (stderr, `--verbose` only)

After all per-hunk lines, a count summary is printed to stderr when `--verbose` is given:

```
1 hunk staged
3 hunks staged
3 hunks staged (2 merged)
```

The `(N merged)` count reflects how many existing target-side hunks were
consumed (the `+`-prefixed hashes).

### Hint (stderr, `--verbose` only)

```
hint: staged hashes differ from unstaged -- use 'git hunk list --staged' to see them
```

## Restore confirmation

`restore` prints one line per restored hunk to stdout. Simpler than `add`/`reset`
— no arrow, no result hashes, no consumed hashes (the hunk simply disappears
from the worktree).

### Human mode

```
{verb} {sha7}  {file}
```

| Token | Meaning |
|-------|---------|
| `{verb}` | `restored` or `would restore` (with `--dry-run`) |
| `{sha7}` | 7-char content hash (yellow when color enabled). May include `:line-spec`. |
| `{file}` | File path (two spaces after hash). |

Examples:

```
restored a3f7c21  src/main.zig
would restore a3f7c21  src/main.zig
restored a3f7c21:3-5  src/main.zig
```

### Porcelain mode

Tab-separated, 3 fields:

```
{verb}\t{sha7}\t{file}
```

| Field | Description |
|-------|-------------|
| `verb` | `restored` or `would-restore` |
| `sha7` | 7-char hash (with `:line-spec` if any) |
| `file` | File path |

Examples:

```
restored	a3f7c21	src/main.zig
would-restore	a3f7c21	src/main.zig
restored	a3f7c21:3-5	src/main.zig
```

### Summary line (stderr, `--verbose` only)

```
1 hunk restored
3 hunks restored
1 hunk would be restored
3 hunks would be restored
```

No stderr summary in porcelain mode.

## Stash confirmation

`stash` prints one line per stashed hunk to stdout. Similar to `discard` — no
arrow, no result hashes (the hunk is moved to the stash).

### Human mode

```
stashed {sha7}  {file}
```

Examples:

```
stashed a3f7c21  src/main.zig
stashed b8e4d2f  src/args.zig
```

SHA in yellow when color is enabled.

### Porcelain mode

Tab-separated, 3 fields:

```
stashed\t{sha7}\t{file}
```

Examples:

```
stashed	a3f7c21	src/main.zig
stashed	b8e4d2f	src/args.zig
```

### Summary line (stderr, `--verbose` only)

```
1 hunk stashed
3 hunks stashed
```

### Hint (stderr, `--verbose` only)

```
hint: use 'git stash list' to see stashed entries, 'git hunk stash pop' to restore
```

### Pop output (stderr)

```
popped stash@{0}
```

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
| 0 | Success. For `list`, may produce empty output (no matching hunks). For `count`, always exits 0. |
| 1 | Error. Message written to stderr. |
