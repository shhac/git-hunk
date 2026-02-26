# git-hunk

Non-interactive, deterministic hunk staging for git. Enumerate hunks, select by
content hash, stage or unstage them -- no TUI required.

## Why

`git add -p` is interactive. It requires a human driving a terminal. LLM agents,
shell scripts, and CI pipelines can't use it.

git-hunk provides an enumerate-then-select workflow: list available hunks with
stable content hashes, then stage or unstage specific hunks by hash. Hashes are
deterministic and remain stable as other hunks are staged or unstaged, so
multi-step staging workflows produce consistent results.

## Install

Requires [Zig](https://ziglang.org/) 0.15.2 or later.

```
git clone <repo-url>
cd git-hunk
zig build
```

The binary is at `zig-out/bin/git-hunk`. Add it to your PATH to use it as a git
subcommand:

```
cp zig-out/bin/git-hunk ~/.local/bin/
git hunk list
```

## Usage

### List hunks

```
git hunk list                          # unstaged hunks (includes diff content)
git hunk list --oneline                # compact one-line-per-hunk output
git hunk list --staged                 # staged hunks
git hunk list --file src/main.zig      # filter by file
git hunk list --porcelain              # machine-readable output
git hunk list --context 1              # finer-grained hunks
git hunk list --no-color               # disable color output
```

Example output:

```
a3f7c21  src/main.zig                  12-18     Add error handling
    @@ -12,1 +12,2 @@ fn handleRequest()
     const result = try parse(input);
    +if (result == null) return error.Invalid;

b82e0f4  src/main.zig                  45-52     Replace old parser
    @@ -45,1 +45,1 @@
    -old_parser(input);
    +new_parser(input);
```

Each hunk shows a 7-character content hash, file path, line range, summary, and
inline diff content. Use `--oneline` for compact output without diffs.

When there are untracked files, a hint is printed to stderr:

```
hint: 3 untracked file(s) not shown -- use 'git add -N <file>' to include
```

### Show hunk content

```
git hunk show a3f7c21                  # show diff for one hunk
git hunk show a3f7 b82e               # show multiple hunks
git hunk show a3f7c21 --staged        # show a staged hunk
git hunk show a3f7 --file src/main.zig # restrict match to file
git hunk show a3f7c21 --porcelain     # machine-readable output
git hunk show a3f7:3-5                # preview specific lines (hunk-relative)
```

Prints the full unified diff content for the specified hunks. With line
selection syntax (`sha:lines`), shows numbered lines with selection markers.

### Stage hunks

```
git hunk add a3f7c21                   # stage one hunk
git hunk add a3f7 b82e                 # stage multiple (prefix match, min 4 chars)
git hunk add a3f7c21 --file src/main.zig   # restrict match to file
git hunk add --all                     # stage all unstaged hunks
git hunk add --file src/main.zig       # stage all hunks in a file
git hunk add a3f7:3-5,8               # stage specific lines from a hunk
git hunk add a3f7c21 --no-color        # disable color in confirmation output
```

Output shows both the old (unstaged) and new (staged) hash:

```
staged a3f7c21 → 5e2b1a9  src/main.zig
1 hunk staged
hint: staged hashes differ from unstaged -- use 'git hunk list --staged' to see them
```

### Unstage hunks

```
git hunk remove a3f7c21               # unstage from index
git hunk remove a3f7 b82e             # unstage multiple
git hunk remove --all                  # unstage everything
git hunk remove --file src/main.zig    # unstage all hunks in a file
git hunk remove a3f7c21 --no-color     # disable color in confirmation output
```

### Typical workflow

```
git hunk list                          # see what changed (with inline diffs)
git hunk add a3f7c21                   # stage first hunk
git hunk add b82e0f4                   # stage second hunk
git hunk list --oneline                # verify remaining (hashes unchanged)
git hunk list --staged --oneline       # verify staged
git commit -m "feat: add error handling"
```

## Porcelain format

`--porcelain` outputs tab-separated fields, one hunk per line, with no headers
or alignment padding:

```
sha\tfile\tstart_line\tend_line\tsummary
```

Fields:
- `sha` -- 7-character content hash
- `file` -- file path
- `start_line` -- first line of the hunk range
- `end_line` -- last line of the hunk range
- `summary` -- function context, first changed line, "new file", or "deleted"

Line ranges are mode-aware: for unstaged hunks they refer to worktree lines, for
staged hunks they refer to HEAD lines. This ensures hashes and ranges remain
stable as other hunks are staged or unstaged.

Example:

```
a3f7c21	src/main.zig	12	18	Add error handling
b82e0f4	src/main.zig	45	52	Replace old parser
```

## Diff output

`list` shows inline diff content by default. Use `--oneline` to suppress it.

In human mode, each hunk's diff lines are indented by 4 spaces:

```
a3f7c21  src/main.zig                  12-18     Add error handling
    @@ -12,1 +12,2 @@ fn handleRequest()
     const result = try parse(input);
    +if (result == null) return error.Invalid;
```

In porcelain mode, the raw diff lines follow the metadata line verbatim, with
records separated by a blank line:

```
a3f7c21	src/main.zig	12	18	Add error handling
@@ -12,1 +12,2 @@ fn handleRequest()
 const result = try parse(input);
+if (result == null) return error.Invalid;

b82e0f4	src/main.zig	45	52	Replace old parser
@@ -45,1 +45,1 @@
...
```

## Context lines

By default, git-hunk respects git's `diff.context` setting (default: 3 lines).
Override with `--context N`:

```
git hunk list --context 1              # finer-grained hunks
git hunk list --context 0              # zero context (maximum granularity)
```

The `--context` flag is available on all commands (`list`, `show`, `add`,
`remove`). Context must be consistent within a workflow -- hashes change with
different context values.

## Line selection

Stage or preview specific lines from a hunk using `sha:line-spec` syntax:

```
git hunk show a3f7:3-5                 # preview lines 3-5 (hunk-relative)
git hunk show a3f7:3-5,8               # preview lines 3-5 and 8
git hunk add a3f7:3-5                  # stage only lines 3-5
```

Line numbers are 1-based and relative to the hunk body (line 1 is the first
line after the `@@` header). Use `show` to preview what would be staged before
running `add`.

When showing a line selection, lines are numbered with `>` markers indicating
which lines are selected:

```
--- a/src/main.zig
+++ b/src/main.zig
  1   @@ -12,3 +12,4 @@ fn handleRequest()
  2    const result = try parse(input);
> 3  +if (result == null) return error.Invalid;
  4    return result;
```

Unselected `-` lines become context in the patch; unselected `+` lines are
dropped. This produces a valid partial patch that `git apply` can process.

## How hashing works

Each hunk gets a SHA-1 hash computed from:

```
SHA1(file_path + '\0' + stable_line + '\0' + diff_lines)
```

- `file_path` -- canonical path from the diff
- `stable_line` -- the line number from the side that doesn't shift during
  staging. For unstaged hunks this is the new (worktree) side; for staged hunks
  this is the old (HEAD) side.
- `diff_lines` -- only the `+` and `-` lines (context lines excluded)

Because the hash uses the stable line number and the actual diff content, it
remains constant as other hunks in the same file are staged or unstaged. This
means you can list hashes, stage some hunks, and the remaining hashes stay the
same.

## Color output

Output is colorized when stdout is a TTY:

- SHA hashes in yellow (in `list`, `show`, `add`, and `remove` output)
- Added lines (`+`) in green
- Removed lines (`-`) in red

Color is disabled automatically when piping output. Use `--no-color` to disable
explicitly, or set the `NO_COLOR` environment variable. The `--no-color` flag is
accepted by all commands (`list`, `show`, `add`, `remove`).

## Handles

- Modified files (single and multi-hunk)
- New files (via `git add -N`)
- Deleted files
- Renamed files (with content changes)
- Files with C-quoted paths (tabs, backslashes)
- Files with no trailing newline
- Prefix matching (minimum 4 hex characters)
- Ambiguous prefix detection
- Bulk staging via `--all` or `--file` without SHAs
- Per-line staging via `sha:line-spec` syntax
- Configurable context lines via `--context N`

## License

MIT
