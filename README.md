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
git hunk list                          # unstaged hunks
git hunk list --staged                 # staged hunks
git hunk list --file src/main.zig      # filter by file
git hunk list --porcelain              # machine-readable output
```

Example output:

```
a3f7c21  src/main.zig                  12-18     Add error handling
b82e0f4  src/main.zig                  45-52     Replace old parser
e91d3a6  README.md                     3-7       new file
```

Each line shows a 7-character content hash, file path, line range, and optional
function context or summary.

### Stage hunks

```
git hunk add a3f7c21                   # stage one hunk
git hunk add a3f7 b82e                 # stage multiple (prefix match, min 4 chars)
git hunk add a3f7c21 --file src/main.zig   # restrict match to file
```

### Unstage hunks

```
git hunk remove a3f7c21               # unstage from index
git hunk remove a3f7 b82e             # unstage multiple
```

### Typical workflow

```
git hunk list                          # see what changed
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
sha\tfile\told_start\tnew_start\tsummary
```

Fields:
- `sha` -- 7-character content hash
- `file` -- file path
- `old_start` -- start line on the old (pre-image) side
- `new_start` -- start line on the new (post-image) side
- `summary` -- function context, "new file", "deleted", or empty

Example:

```
a3f7c21	src/main.zig	12	12	Add error handling
b82e0f4	src/main.zig	45	52	Replace old parser
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

## Handles

- Modified files (single and multi-hunk)
- New files (via `git add -N`)
- Deleted files
- Files with no trailing newline
- Prefix matching (minimum 4 hex characters)
- Ambiguous prefix detection

## License

MIT
