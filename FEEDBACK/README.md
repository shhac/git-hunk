# Feedback

Where agents record problems they hit using git-hunk in other repositories:
unexpected errors, refusals that blocked something reasonable, advice in the
skill that did not work, workarounds, and output that confused them. A session
where git-hunk worked as expected writes nothing.

Everything here except this README is ignored by Git. Entries come from real
repositories and may name real files, branches and remotes, so turn an entry
into something synthetic before it becomes an issue, a test fixture or a
design note.

## File

`FEEDBACK/<yyyy>-<mm>-<dd>-<session>.md`. `<session>` is the agent's session
id if it has one, otherwise a short kebab-case slug for the task. Use one file
per session and append further entries to it.

## Entry

```markdown
## <one-line summary>

- **git-hunk version:** <output of `git hunk --version`>
- **Command:** `git hunk ...` (exit status N)
- **Context:** optional — repo state that matters (mid-rebase, conflicts, submodules, ...)
- **Expected:** what you were trying to do and what you expected to happen
- **Happened:** what git-hunk did or said instead, quoting the relevant output
- **Workaround:** what you did instead, or "none"
- **Suggestion:** optional — what would have helped
- **Evidence:** the captured output described below
```

## Make it reproducible

An entry that cannot be reproduced cannot be fixed, and the repository's state
is gone once the session moves on. So before working around the problem:

- Run the failing command once more and copy what it printed, exactly. Give
  the whole command as typed, with every flag, and the directory it ran in
  relative to the repository root.
- Capture the state it ran against: `git status --porcelain=v2 --branch`,
  `git hunk list --oneline`, and `git version`. Add the `--staged` listing
  when the index is involved.
- Record any Git configuration that is not default and could matter:
  `git config --show-origin --list`, trimmed to the keys that look related,
  with anything private removed.
- Say whether the problem happens every time or only sometimes.
- If you can, reduce it: the fewest commands that show the problem in a new
  repository (`git init` in a temporary directory) are worth more than
  everything else in the entry.

Report what you saw yourself. When another agent reported the problem to you,
run the command again before writing it up, and if you cannot, say the entry
is second-hand and unverified.
