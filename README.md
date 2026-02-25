# git-hunk

Non-interactive, deterministic hunk staging for git. Enumerate hunks, select by
foo content hash, stage or unstage them -- no TUI required.

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
git hunk list                          # unstaged hunks
git hunk list --staged                 # staged hunks
git hunk list --file src/main.zig      # filter by file
git hunk list --porcelain              # machine-readable output
git hunk list --diff                   # include inline diff content
git hunk list --no-color               # disable color output
```

Example output:

```
a3f7c21  src/main.zig                  12-18     Add error handling
b82e0f4  src/main.zig                  45-52     Replace old parser
e91d3a6  README.md                     3-7       new file
```

Each line shows a 7-character content hash, file path, line range, and optional
function context or summary.

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
```

Prints the full unified diff content for the specified hunks. Useful for
inspecting a hunk before staging it.

### Stage hunks

```
git hunk add a3f7c21                   # stage one hunk
git hunk add a3f7 b82e                 # stage multiple (prefix match, min 4 chars)
git hunk add a3f7c21 --file src/main.zig   # restrict match to file
git hunk add --all                     # stage all unstaged hunks
git hunk add --file src/main.zig       # stage all hunks in a file
```

### Unstage hunks

```
git hunk remove a3f7c21               # unstage from index
git hunk remove a3f7 b82e             # unstage multiple
git hunk remove --all                  # unstage everything
git hunk remove --file src/main.zig    # unstage all hunks in a file
```

### Typical workflow

```
git hunk list                          # see what changed
git hunk show a3f7c21                  # inspect a hunk's diff
git hunk add a3f7c21                   # stage first hunk
git hunk add b82e0f4                   # stage second hunk
git hunk list                          # verify remaining (hashes unchanged)
git hunk list --staged                 # verify staged
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

`list --diff` and `show` include inline diff content after hunk metadata.

In human mode (`list --diff`), each hunk's diff lines are indented by 4 spaces:

```
a3f7c21  src/main.zig                  12-18     Add error handling
    @@ -12,5 +12,6 @@ fn handleRequest()
     const result = try parse(input);
    +if (result == null) return error.Invalid;
     return result;
```

In porcelain mode, the raw diff lines follow the metadata line verbatim, with
records separated by a blank line:

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

In human mode, output is colorized when stdout is a TTY:

- SHA hashes in yellow
- Added lines (`+`) in green
- Removed lines (`-`) in red

Color is disabled automatically when piping output. Use `--no-color` to disable
explicitly, or set the `NO_COLOR` environment variable.

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

## License

MIT
