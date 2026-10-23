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
```
