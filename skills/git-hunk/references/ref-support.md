# Ref Support (`--ref`)

Compare against arbitrary git refs instead of the default worktree/index diff.
Available on all commands except `stash` (v0.9.0+).

## Syntax

```
--ref <refspec>
```

`<refspec>` is either a single ref or a two-dot range:

| Form | Meaning | Equivalent git diff |
|------|---------|-------------------|
| `--ref X` | Diff ref X vs worktree | `git diff X` |
| `--ref X --staged` | Diff ref X vs index | `git diff --cached X` |
| `--ref X..Y` | Diff between two refs | `git diff X Y` |
| `--ref X..Y --staged` | **Rejected** (nonsensical) | n/a |

`X` can be any valid git ref: `HEAD`, `HEAD~3`, `main`, a commit SHA, a tag, etc.

## Supported commands

| Command | `--ref X` | `--ref X..Y` | Notes |
|---------|-----------|-------------|-------|
| `list` | yes | yes | |
| `diff` | yes | yes | |
| `add` | yes | yes | Applies patch to index; may conflict if worktree diverges from diff endpoint |
| `reset` | yes | yes | Same conflict caveat as `add` |
| `restore` | yes | yes | Same conflict caveat as `add` |
| `count` | yes | yes | |
| `check` | yes | yes | |
| `stash` | **no** | **no** | `--ref` is rejected with an error |

## Examples

### Browse changes relative to a branch

```bash
git hunk list --ref main                     # all hunks between main and worktree
git hunk list --ref main --oneline           # compact view
git hunk diff --ref main a3f7c21             # inspect one hunk
git hunk count --ref main                    # how many hunks vs main
```

### Inspect a commit range

```bash
git hunk list --ref HEAD~3..HEAD             # hunks from last 3 commits
git hunk list --ref main..HEAD --oneline     # hunks on current branch vs main
git hunk diff --ref main..HEAD a3f7c21       # inspect a specific hunk in range
```

### Stage hunks from a ref diff

```bash
git hunk list --ref main                     # find hunks vs main
git hunk add --ref main a3f7c21              # stage one hunk from that diff
```

**Caveat:** `add`, `reset`, and `restore` apply patches to the worktree or index.
When using `--ref`, the patch is derived from the ref diff, not the default
worktree/index diff. If the apply target has diverged from a diff endpoint, the
patch may not apply cleanly -- you'll get a `patch did not apply cleanly` error.

### Ref vs index (staged)

```bash
git hunk list --ref HEAD --staged            # diff HEAD vs index
git hunk list --ref main --staged            # diff main vs index
```

### Invalid combinations

```bash
git hunk list --ref main..HEAD --staged      # ERROR: range + --staged is rejected
git hunk stash --ref main --all              # ERROR: --ref not supported for stash
```

## Hash stability with `--ref`

Hashes are deterministic for a given ref diff, following the same rules as
worktree/index diffs. However, hashes from `--ref main` and plain `list` (no
`--ref`) will differ for the same logical change because the diff bases differ.
Always use the same `--ref` value when listing and then operating on hashes.
