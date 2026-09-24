# Ref Support (`--ref`)

Compare against arbitrary git refs instead of the default worktree/index diff.
Available on all commands except `stash` (v0.9.0+).

## Syntax

```
--ref <refspec>
```

`<refspec>` is either a single commit or a range:

| Form | Meaning | Equivalent git diff |
|------|---------|-------------------|
| `--ref X` | That commit's changes, against its first parent (the empty tree for a root commit) | `git diff X^ X` |
| `--ref X --staged` | The index against commit X | `git diff --cached X` |
| `--ref X..Y` | Between two commits | `git diff X..Y` |
| `--ref X...Y` | Y's changes since it forked from X | `git diff X...Y` |
| `--ref X..Y --staged` | **Rejected**: `--staged compares the index with one commit; 'X..Y' is a range` | n/a |

`X` can be any valid git revision: `HEAD`, `HEAD~3`, `main`, a commit SHA, a tag,
etc. Either side of a range may be empty, meaning `HEAD`. A revision git cannot
resolve is refused before anything runs, naming it as typed:
`error: bad revision 'nope'`. A file named like a revision (`main`, `HEAD`) never
shadows it.

## Supported commands

| Command | `--ref X` | `--ref X..Y` | Notes |
|---------|-----------|-------------|-------|
| `list` | yes | yes | |
| `diff` | yes | yes | |
| `count` | yes | yes | |
| `check` | yes | yes | |
| `add` | yes | yes | Applies the ref's hunk to the index |
| `reset` | yes | yes | Takes the ref's hunk back out of the index |
| `restore` | yes | yes | Reverts the ref's hunk in the worktree |
| `commit` | yes | yes | Commits the ref's hunk on top of HEAD |
| `stash` | **no** | **no** | `--ref` is rejected with an error |

## Examples

### Browse a commit's changes

```bash
git hunk list --ref HEAD                     # hunks the last commit introduced
git hunk list --ref HEAD~1 --oneline         # the commit before it, compact
git hunk diff --ref HEAD a3f7c21             # inspect one hunk
git hunk count --ref HEAD                    # how many hunks it has
```

### Inspect a commit range

```bash
git hunk list --ref HEAD~3..HEAD             # hunks from last 3 commits
git hunk list --ref main..HEAD --oneline     # hunks on current branch vs main
git hunk diff --ref main..HEAD a3f7c21       # inspect a specific hunk in range
```

### Apply hunks from a ref diff

```bash
git hunk list --ref abc1234                  # find hunks in that commit
git hunk add --ref abc1234 a3f7c21           # stage one of them (cherry-pick a hunk)
git hunk restore --ref abc1234 a3f7c21       # revert one of them in the worktree
```

**Caveat:** `add`, `reset`, `restore` and `commit` apply the ref's patch to the
index or worktree. If that target has diverged from the commit, the patch may
not apply cleanly:
`error: changes from 'abc1234' do not apply cleanly to the index (try --3way)`.

### Ref vs index (staged)

```bash
git hunk list --ref HEAD --staged            # diff HEAD vs index
git hunk list --ref main --staged            # diff main vs index
```

With nothing to show, commands that act on hunks name the source:
`no changes in 'abc1234'`, `no staged changes relative to 'main'`; `list`
prints nothing and `count` prints `0`, as on a clean tree.

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
