# Scripting Patterns

## Porcelain output

All list/show output is available in machine-readable form with `--porcelain`.
Tab-separated fields: `sha\tfile\tstart_line\tend_line\tsummary`

```bash
# Extract all hashes
git hunk list --porcelain --oneline | cut -f1

# Extract file paths
git hunk list --porcelain --oneline | cut -f2

# Filter by file
git hunk list --porcelain --oneline | awk -F'\t' '$2 == "src/main.zig"'

# Count hunks per file
git hunk list --porcelain --oneline | cut -f2 | sort | uniq -c
```

## Stage by pattern

```bash
# Stage hunks matching a pattern in the summary
git hunk list --porcelain --oneline | grep 'error' | cut -f1 | xargs git hunk add
```

## Guaranteed precise commit

Stage exactly the hunks you want, verify nothing extra, commit:

```bash
HASHES="a3f7c21 b82e1f4"

[ "$(git hunk count --staged)" -eq 0 ] && \
  git hunk check --exclusive $HASHES && \
  git hunk add $HASHES && \
  git commit -m "feat: precise change"
```

The `--exclusive` flag guarantees no unexpected hunks exist — if the worktree changed,
`check` exits 1 and the pipeline stops before staging.

## Capture, validate, stage

```bash
HASHES=$(git hunk list --porcelain --oneline | grep 'error handling' | cut -f1)
git hunk check $HASHES && git hunk add $HASHES && git commit -m "feat: add error handling"
```

## Stash and restore

Save hunks you're not ready to commit, then restore later:

```bash
git hunk stash a3f7c21 b82e0f4 -m "wip: experimental approach"
git commit -m "feat: main changes"
git hunk stash --pop
```

## Discard unwanted changes

Stage what you want, discard the rest:

```bash
git hunk add a3f7c21 b82e0f4
git hunk discard --all
git commit -m "feat: precise changes only"
```

## Counting

```bash
git hunk count                         # total unstaged hunks
git hunk count --staged                # total staged hunks
git hunk count --file src/main.zig     # hunks in one file

# Use in conditionals
if [ $(git hunk count) -gt 0 ]; then
  echo "unstaged changes remain"
fi
```

## Add/remove porcelain output

`add` and `remove` produce tab-separated confirmation:

```
verb\tapplied\tresult\tfile[\tconsumed]
```

Example: `staged\ta3f7c21\t5e2b1a9\tsrc/main.zig`

The result hash is the new staged/unstaged hash — use it for subsequent operations
without re-listing.
