# Working with hunks from history

`git-hunk` supports cherry-picking and reverting at the **single hunk** level
across your commit history. This document walks through the workflows.

## The shorthand: `--ref <commit>`

Every `git-hunk` command accepts `--ref <refspec>`. A single ref (no `..`) is
shorthand for `<ref>^..<ref>` — i.e. the diff that commit introduced. This
matches `git show <ref>` semantics:

```bash
git hunk list --ref HEAD~1            # hunks from the most recent commit
git hunk list --ref abc1234           # hunks from a specific commit
git hunk list --ref main              # hunks from the tip of main
```

To compare a ref **against the worktree** (the previous behaviour for single
refs), write the range form explicitly:

```bash
git hunk list --ref main..HEAD        # everything you've added on top of main
```

**Initial commits** (no parent) work too — `git-hunk` detects the missing
parent and diffs against git's empty tree, so the initial commit's full
content shows up.

## Recipe 1: Re-apply a hunk from a past commit

Use case: a useful change got reverted, lost in a merge, or lives on a parallel
branch and you want exactly one hunk of it.

```bash
# 1. Find the hunk you want.
git log --oneline -20                       # locate the commit (say abc1234)
git hunk list --ref abc1234 --oneline       # see its hunks

#    aaaa111  src/lib.zig     12-15        helper definition
#    bbbb222  src/lib.zig     30-30        unrelated tweak
#    cccc333  README.md       42-45        unrelated docs

# 2. Forward-apply just one of them into the index.
git hunk add --ref abc1234 aaaa111

# 3. Commit normally.
git commit -m "rescue: re-apply the helper from abc1234"
```

If you want it to be a single self-contained commit without going through the
index:

```bash
git hunk commit --ref abc1234 aaaa111 -m "rescue: re-apply the helper"
```

`commit --ref` builds the commit in a throwaway temp index (read HEAD into
it → apply → commit → resync the real index), so your existing staging
state is never touched.

## Recipe 2: Undo a hunk from a past commit

Use case: a commit introduced a regression but most of it is fine — you want
to back out *just one hunk* without reverting the whole commit.

```bash
# 1. Find the bad hunk.
git hunk list --ref bad_commit --oneline

# 2. Reverse-apply it to the worktree.
git hunk restore --ref bad_commit aaaa111

# 3. Stage and commit the un-doing.
git hunk add aaaa111   # or: git add src/lib.zig
git commit -m "fix: revert the bad hunk from bad_commit"
```

Note the asymmetry: **`add --ref X`** forward-applies (cherry-pick); **`restore
--ref X`** reverse-applies (revert). Same hash on both sides because the hunk's
identity is content-based.

## Recipe 3: Surrounding context has drifted — `--3way`

If you reach far enough back that the lines around the hunk have changed,
plain `git apply` fails:

```
error: patch did not apply cleanly — the diff from 'HEAD~10' may conflict
       with the current state (try --3way)
```

Add `--3way`:

```bash
git hunk restore --ref HEAD~10 --3way aaaa111
```

`--3way` passes through to `git apply --3way`. Two outcomes:

- **Clean merge**: the worktree is updated and you can `git diff` to inspect.
- **Conflict**: `<<<<<<<` markers appear in the conflicting files. Resolve
  them like any other merge, then `git add` and continue.

`--3way` is supported on `add`, `reset`, `restore`, and `commit`.

## How it works under the hood

1. `--ref <commit>` is expanded to `<commit>^..<commit>` (or
   `<empty-tree>..<commit>` for initial commits) by `expandRefShorthand` in
   `main.zig`.
2. `git diff <range>` produces the patch.
3. `git-hunk` parses hunks from that diff and computes content-stable hashes —
   the same SHA you'd see if those hunks were live in your worktree today.
4. `git apply [--reverse] [--3way] [--cached]` applies the matching hunk's
   patch to the index (for `add`/`reset`/`commit`) or worktree (for
   `restore`).

Because hashes are content-based, the same hunk has the same SHA whether you
list it from the worktree or from a 10-year-old commit. You don't need to
re-derive the SHA when context drifts: `--3way` lets `git apply` figure out
the placement.

## Limitations

- Conflict markers from `--3way` need manual resolution — `git-hunk` doesn't
  re-parse the resulting conflict zones.
- Cherry-picking a hunk whose surrounding context contains another change
  may cherry-pick more than you expected; `--unified 0` and `git hunk diff`
  are your friends for inspecting before applying.
- Renames across the historical span aren't followed automatically — list
  with `--ref X..Y` to see the actual rename hunks if needed.
- `--3way` requires the patch to record the original blob ids, which `git
  apply` synthesises from `git diff`'s `index <hash>..<hash>` lines.
  Diffs without those lines can't 3-way merge.
