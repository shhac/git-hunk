# Changelog

## [Unreleased]

### Fixed
- Line specs now work on `reset` and `restore` at any context width. Both commands reverse-apply their patch, but the filtered patch was built for forward apply only: deselected `+` lines were dropped instead of kept as context, so the patch's new side no longer matched the index/worktree and git rejected it with "patch does not apply". `git hunk reset <sha>:2` and `git hunk restore <sha>:2` failed on any hunk containing more than one change. Only `--unified 0` worked, because zero context puts every change in its own hunk and leaves nothing deselected to mishandle. Deselected lines are now kept on whichever side the apply direction matches against, mirrored per direction.
- `git hunk commit --dry-run` no longer requires `-m`. The message check ran ahead of the dry-run branch, so the behaviour documented in `--help` ("required unless `--dry-run`") — and already allowed by the argument parser — was unreachable.

### Added
- Regression tests for line specs at default context on `reset` (test 237) and `restore` (tests 525–527, covering insertions, deletions, and a mixed add+delete hunk), plus `commit --dry-run` without `-m` (tests 1020–1021). The previously existing line-spec tests for these commands all passed `--unified 0`, which is why the bug survived; the new tests deliberately do not.

## [0.16.0] - 2026-07-04

### Changed
- `git hunk commit` now builds the commit in a throwaway temp index (`GIT_INDEX_FILE`) instead of backing up, rewriting, and restoring the real index. Your staged work is never touched: a crash at any point mid-commit (verified with kill -9 fault injection) leaves the index byte-identical with no recovery needed — at worst a stray temp file in `/tmp`. Hooks still fire normally and see exactly the content being committed. Stale `.git/index.hunk-backup` files from commits interrupted under older versions are still restored automatically.
- Internal structure pass over the commit/git-subprocess layer: one error-returning capture core replaces six hand-rolled helper bodies, the parallel `*WithEnv` helper family is gone, temp-index plumbing moved to the git layer with self-contained ownership, and the hook-path selection logic is a pure, unit-tested function.

### Fixed
- Pre-commit hooks that `git add` files (lint fixers etc.) no longer leave a phantom staged deletion plus untracked twin after the commit — hook-created paths are synced into the real index, while user-staged work (including staged deletions) is provably untouched.
- A binary-add failure mid-commit no longer strands transaction state; it aborts cleanly with user state untouched.
- Paths containing spaces are parsed correctly from patch headers; previously the hook-path cleanup could mistake a committed spaced path for hook-created, and resync diagnostics printed a truncated name.

### Added
- 16 commit edge-case integration tests: overlapping staged/unstaged regions in every flavor, `--3way` conflict escalation, git fault injection at each transaction step (via a PATH shim), kill -9 crash recovery, index-modifying hooks, binary-commit transactional invariants, and spaced-path handling.

## [0.15.3] - 2026-07-03

### Fixed
- zsh hash completion listings no longer columnize side by side in wide terminals — candidates always display one per row (`compadd -l`), keeping the `list --oneline` table readable.

## [0.15.2] - 2026-07-03

### Changed
- zsh and fish hash completion displays now mirror `git hunk list --oneline` exactly — aligned file column, `empty`/`N-M` line ranges, truncated summaries, list order (by file/line) instead of hash order. The display is sourced from the binary's own `--oneline --no-color` output, so future `list` improvements flow into completions automatically.

### Added
- zsh completion listings colour the hunk hash yellow, matching `list --oneline` (and `git log --oneline`). Shipped as a soft default: a `hunk-hashes` `list-colors` zstyle applied only when the user has no matching style of their own, and skipped when `NO_COLOR` is set. Menu selection keeps zsh's standard `ma=` highlight, user-tunable as usual.

## [0.15.1] - 2026-07-03

### Fixed
- zsh completion via git's own `git-completion.zsh` wrapper (Homebrew git, Apple Command Line Tools) now completes non-empty words. Previously any typed prefix — `git hunk add 9<TAB>`, `git hunk list --sta<TAB>`, even a unique hash prefix — completed nothing, because the wrapper's dispatch context breaks the compsys engines behind `_describe` and `_arguments` option matching. The `_git_hunk` bridge is now a self-contained wrapper-native completer built on raw `compadd`/`_wanted`/`_files`, and hash candidates gain oneline-style descriptions (`9ab03ef  foo  0  0  new file`). zsh's builtin `_git` dispatch and direct `git-hunk` completion are unchanged.

### Added
- Interactive completion regression tests (`tests/test_completions.sh`): drives real TAB completion in a pty for both the direct and `git hunk` wrapper dispatch paths, with hash-prefix overlap guaranteed by construction. Skips gracefully when zsh/zpty or a git-completion.zsh wrapper is unavailable.

## [0.15.0] - 2026-07-03

### Added
- Shell completions for bash, zsh, and fish (`completions/`), covering both `git-hunk` and `git hunk` invocation forms, with live hunk-hash completion from `list --porcelain --oneline` (staged hashes for `reset`), `--ref` completion from git refs, and `--file` path completion. Release tarballs now ship them and the Homebrew formula installs them.
- `zig build fuzz` — a brute-force mutating fuzzer for the diff parser (`src/fuzz_driver.zig`), plus a corpus-seeded fuzz test in `src/diff.zig` that replays deterministic regression inputs under `zig build test`. 8 million mutated inputs survived clean at time of writing. (Coverage-guided `zig build test --fuzz` is blocked on a Zig 0.16.0 stdlib bug.)
- `zig build docs` — CLI documentation facts (commands, flags, arguments, examples) are now single-sourced in `src/spec.zig`. `--help` and top-level usage render from it at comptime; the man page's COMMANDS/GLOBAL OPTIONS sections are generated from it; and the skill reference plus all three shell completions are coverage-checked against it. `zig build docs -- --check` runs in CI as a drift gate.

### Changed
- `--help` flag display normalized to short-form-first (`-h, --help`, `-u, --include-untracked`); example columns aligned consistently across commands.
- `count` now documents its accepted no-op flags (`--porcelain`, `--no-color`, `-v`); top-level help now documents `-V, --version`.
- The version string is single-sourced from `build.zig.zon` (`build.zig` imports it; release builds still override via `-Dversion` from the tag).

### Fixed
- Help and man page no longer claim `--ref` "combines with `--staged`" on `add`, `reset`, and `restore` — those commands reject `--staged`.
- Skill reference (`commands.md`): added previously missing `--ref` and `--3way` flag documentation across seven commands; corrected the stale claim that `--file` paths must match diff output exactly (they resolve relative to the current directory since 0.10.2).

## [0.14.3] - 2026-06-13

### Added
- The man page now documents `--ref` and `--3way` under GLOBAL OPTIONS, expands the `commit` command entry, and includes examples for committing hunks directly and cherry-picking hunks from past commits.
- Top-level `--help` now lists `-v`/`--verbose` and `-q`/`--quiet` alongside the other common options.
- Releases now update the Homebrew tap formula automatically via a tag-scoped deploy key.

### Changed
- CI now enforces `zig fmt --check`.

## [0.14.2] - 2026-06-05

### Fixed
- `git hunk add <path>` and `git hunk reset <path>` now fail with a clearer path-vs-hash diagnostic when a path is provided where a hunk hash is expected, including a `hint:` to run `git hunk list --oneline` and use `--file <path>` only to narrow by path. Valid hash-like filenames still resolve as hunk hashes, and missed hash fragments continue to report `no hunk matching`.

## [0.14.1] - 2026-05-31

### Fixed
- Untracked symlinks to directories are now listed and staged correctly. Previously `git hunk list --untracked-only` and `git hunk add --all` skipped symlink entries like `.claude/commands -> ../.agents/commands` because `git diff --no-index /dev/null <path>` treated the symlink target as a directory.

## [0.14.0] - 2026-05-09

### Added
- `--ref <commit>` single-ref shorthand: passing a single commit (e.g. `--ref HEAD~1`) now expands to `<commit>^..<commit>` (the diff of that commit, like `git show`). Range form (`A..B`, `A...B`) still works as before. Initial (parentless) commits expand against the empty tree so the workflow works on the very first commit.
- `--3way` flag on `add`, `reset`, `restore`, and `commit`: passes `--3way` to the underlying `git apply`, enabling 3-way merge fallback when patch context drifts. Useful for "undo this hunk from history" / "re-apply this hunk from history" workflows where the worktree has moved on. On conflict, leaves unmerged index entries (or `<<<<<<<` markers in the worktree) and exits non-zero with a clear, action-aware resolution hint.
- New section in the skill (`SKILL.md`) and a dedicated `docs/history-workflow.md` covering `--ref` + `--3way` for cherry-pick-by-hunk and undo-by-hunk from history.
- Tests pinning every new path: `--ref` shorthand on initial commits and three-dot ranges, `--staged --ref` short-circuit, `--3way` clean-apply and conflict paths for add/restore/commit, end-to-end undo-and-re-apply-from-history workflows.

### Changed
- Transactional commit (`git hunk commit`) hardened: when index-restore (step 5) fails after a successful commit, the backup is now preserved (step 7 cleanup is gated on restore success) and the warning includes a concrete `cp <backup> <index>` recovery command. When `--3way` was used to land patches with drift, step 6 now also runs with `--3way` so the user's restored index reflects the merged content (previously index ≠ HEAD on drift).
- `--3way` is now rejected (not silently swallowed) on commands that don't apply patches (`list`, `diff`, `count`, `check`, `stash`).
- `cmdCommit --dry-run` no longer runs stale-backup recovery — a read-only preview should not modify the index.
- `--3way` conflict messages are action-aware (stage path suggests `git add` once resolved; unstage path suggests `git checkout --` or re-stage the resolved version) and stdout is flushed before stderr so per-hunk output appears above the error on a TTY.
- The "N hunks staged/restored" success summary is now suppressed when `--3way` lands unmerged entries — the conflict error is the single coherent signal.

### Fixed
- `--3way` 3-way fallback used to fail with "lacks the necessary blob" because reconstructed patches stripped the `index <oldsha>..<newsha>` line; that line is now preserved end-to-end and `--full-index` is passed to `git diff`.
- `git apply --3way --cached` returning non-zero on soft-success (applied with conflicts) is now treated as a soft-success internally, with `runGitApply` returning `ApplyResult { applied_clean, applied_with_conflicts }` so callers can render correctly.
- Three-dot ranges (`A...B`) are no longer corrupted by a manual `..` split — the ref string is passed verbatim to `git diff`.
- `--staged --ref X` no longer silently drops `--cached` (single-ref expansion now short-circuits when `--staged` is set).
- `commit --3way` with conflicts no longer silently rolls back the transactional commit; it aborts early with a "use restore --ref X --3way then commit normally" hint.

## [0.13.1] - 2026-05-09

### Changed
- Internal quality work: 4 iterations of structured refactoring and test coverage. No user-visible behavior changes.
- `parseDiff` decomposed into focused helpers: `parseExtendedHeaders`, `buildPatchHeader`, `synthesizeWholeFileHunk`, `parseHunkBody`, etc. The 320-LOC state-machine body is now a 70-line orchestrator.
- `cmdCheck` decomposed: `runChecks` + `renderCheckPorcelain` + `renderCheckHuman` replace a 200-LOC inline pipeline.
- `assignAppliedAndConsumed` split into `collectAppliedFor` + `collectConsumedFor` helpers.
- `printRawLinesWithLineNumbers` body printer flattened into `countBodyLines` + `digitWidth` + `printNumberedBodyLine` — output is identical.
- New helpers: `format.printMatchedHunks`, `format.printHunkCountSummary`, `format.printRawLines`, `commands.exitNoChanges`, `patch.partitionByKind`, `patch.HunkPartition.combinedText/combinedBinary`, `commands.shaSetDifference`, `git.trimAndShrink`, `args.unknownFlag`, `args.validateRefStagedCombo`, `stash.createTempIndex` + `TempIndex` struct. Each replaces 2-7 inline duplicates.
- `runGitDiffHead` removed (folded into `runGitDiffFiles`); argv-builder pattern in `git.zig` switched to `std.ArrayList` (no more manual `argc` counters).
- `applyCommonFlags` hardened: the `common.file_filter` list is always freed on error, removing a class of leaks if a parser forgets the pre-call errdefer.

### Added
- ~150 new unit tests across `format.zig`, `patch.zig`, `types.zig`, `git.zig`, `args.zig`, `stash.zig`, `commands.zig`, and `diff.zig`. Coverage now spans every newly-extracted helper, the 5 phases of `buildResultGroups` directly, all parser leak-detection paths, every `parseExtendedHeaders` state branch, and the human/porcelain renderer outputs.
- Integration tests for multi-`--file` filter across all 8 commands (was previously only `list`), `chdirToRepoRoot` regression for macOS-symlinked toplevel, mixed binary+text stash round-trip, and "no [un]staged changes" stderr messages.

## [0.13.0] - 2026-05-09

### Added
- `--file` flag is now repeatable: `git hunk add --file a.zig --file b.zig` matches hunks in either file (an any-of filter). Help text and man page updated accordingly.

### Changed
- Migrated from Zig 0.15.2 to Zig 0.16.0. The minimum required Zig version is now 0.16.0; CI and the README reflect this. Subprocess, allocator, filesystem, env, and args APIs were all rewritten against the new standard library.
- Internal refactoring: 5 duplicate `defaultIo()` helpers consolidated into one alias; the trim-and-shrink, argv-builder, and temp-index pipeline patterns each centralized; `computeHunkSha` moved to its natural home in `types.zig`. The four big command bodies (`cmdCommit`, `cmdStash`, `cmdCheck`, `cmdApplyHunks`) and the shared `buildResultGroups` helper are now ~30-line orchestrators over named, individually-readable phases.
- `patch.partitionByKind` replaces four open-coded text/binary partition loops across the apply, restore, stash, and commit pipelines.

### Fixed
- Previously, `git hunk add --file a.zig --file b.zig` silently kept only the last `--file` (last-wins overwrite) and produced confusing "no hunk matching" errors when SHAs lived in the dropped file. Now multiple `--file` flags accumulate as expected.

## [0.12.0] - 2026-04-11

### Added
- Binary files (images, databases, compiled assets, etc.) are now visible in all commands — they appear as single whole-file hunks with a `(binary)` marker and can be staged, unstaged, restored, committed, and stashed by hash like any other hunk
- Line-spec syntax (e.g., `hash:3-5`) is rejected for binary hunks with a clear error message, since binary files have no line-level granularity

### Changed
- Internal refactoring: extracted shared helpers, moved stash orchestration to `stash.zig`, deduplicated git subprocess boilerplate (-473 lines net)

## [0.11.1] - 2026-04-09

### Fixed
- Typechange diffs (file replaced by symlink or vice versa) can now be staged, unstaged, committed, stashed, and restored — previously `git hunk add` failed with `error: wrong type` when both hunks were applied together

## [0.11.0] - 2026-03-26

### Added
- Symlinks now display with a trailing `@` suffix in all output (list, add, reset, restore, stash, commit, check) — matching the `ls -F` convention — in both human and porcelain modes

### Fixed
- Stashing untracked symlinks now preserves symlink mode — previously `stash pop` would restore them as regular files containing the diff output instead of as symlinks

## [0.10.2] - 2026-03-11

### Fixed
- Running `git hunk` from a subdirectory within a repo now works correctly — previously `git apply` would create wrong index entries (e.g., staging `bar/foo.txt` instead of `foo.txt`)
- `--file` argument now resolves relative to the user's current directory, matching `git` conventions (e.g., `--file ../foo.txt` from a subdirectory correctly refers to `foo.txt` at the repo root)

## [0.10.1] - 2026-03-03

### Fixed
- `list --quiet` now correctly suppresses output (was silently ignored)
- Added `--verbose`/`-v` and `--quiet`/`-q` to man page GLOBAL OPTIONS section
- Added `--verbose`/`-v` and `--quiet`/`-q` to all command help text (previously only `commit` documented them)

## [0.10.0] - 2026-03-03

### Added
- `commit` command — commit specific hunks directly without manual staging (`git hunk commit <sha>... -m "message"`)
  - Uses save/restore index approach so pre-commit, commit-msg, and post-commit hooks run normally
  - Existing staged changes are preserved — only specified hunks are committed
  - `--all` to commit all unstaged hunks, `--file` to commit hunks in a specific file
  - `--amend` to amend the previous commit with additional hunks
  - `--dry-run` to preview what would be committed
  - `--ref <refspec>` to commit hunks from a ref-based diff
  - Line specs supported (e.g., `sha:3-5,8`) for partial-hunk commits
  - Crash recovery: detects and restores stale index backups from interrupted commits
  - 16 integration tests covering basic usage, hooks, crash recovery, and edge cases

## [0.9.1] - 2026-03-03

### Added
- `--allow-empty` flag on `check` command — allows zero SHA arguments, useful with `--exclusive` to assert no hunks exist (e.g., `check --exclusive --allow-empty --staged` asserts nothing is staged)

## [0.9.0] - 2026-03-03

### Added
- `--ref <refspec>` flag for diffing against arbitrary git refs
  - Single ref (e.g. `--ref HEAD`, `--ref main`) diffs ref vs worktree
  - Range (e.g. `--ref main..HEAD`) diffs between two refs
  - Composes with `--staged` for ref vs index comparison
  - Supported on all commands except `stash`
  - Contextual error messages when ref-based patches don't apply cleanly

### Fixed
- Redundant "PatchFailed" error line no longer printed after descriptive error message

## [0.8.3] - 2026-03-01

### Fixed
- Cross-platform test compatibility: replace BSD-only `sed -i ''` with portable `sed -i.bak`
- Handle empty file diffs on Linux where git includes `---`/`+++` lines without `@@` hunks
- Fix default branch name assumption in merge conflict test (`git init -b main`)
- Use ANSI-C quoting for tab in grep pattern (GNU grep compatibility)

## [0.8.0] - 2026-03-01

### Added
- `--quiet` / `-q` flag on all commands (suppress output, exit code only)
- `--verbose` / `-v` flag on all commands (show summary counts and hints)
- `-U<n>` flag form (no space, e.g., `-U0`) alongside existing `-U <n>`
- `--unified=<n>` flag form (with equals) alongside existing `--unified <n>`
- CI workflow for unit and integration tests on push/PR
- Comprehensive test coverage: line spec staging, restore adjacency, cross-repo SHA determinism, stale SHA detection, round-trip byte-exact verification, idempotency, unified-value-affects-SHA, stash dirty index, reset --all, binary files, unicode filenames, rename detection, empty repo, merge conflicts, symlinks, --version output
- Dedicated `test_diff.sh` test suite (23 tests)
- Edge case test suite (`test_edge_cases.sh`, 9 tests)

### Changed
- **Breaking:** `discard` command renamed to `restore` (matches `git restore`)
- **Breaking:** `show` command renamed to `diff` (matches `git diff`)
- **Breaking:** Summary counts and hint messages now require `--verbose` (previously always shown)
- `--porcelain` implies quiet for human-readable output
- Integration tests renumbered to per-file ranges (100s, 200s, etc.) eliminating all cross-file collisions

### Fixed
- Preserve colored output when git pager is active (`GIT_PAGER_IN_USE` environment variable)
- Handle empty files in diff parser
- Handle escaped quotes in C-quoted diff path extraction
- Improve empty file output formatting

### Internal
- Extract `resolveMatchedHunks` — deduplicate SHA resolution across 4 commands
- Extract `collectUniqueFilePaths` — deduplicate file path collection across 3 commands
- Extract `shouldUseColor` into `format.zig` — deduplicate color computation across 6 sites
- Deduplicate `rangesOverlap` — move to `types.zig` from two files
- Decompose `cmdStash` (328 lines) into 5 focused helpers
- Extract `handleParseError` — reduce `main.zig` dispatch boilerplate by ~80 lines
- Extract `parseCommonFlag` — reduce `args.zig` flag parsing duplication by ~50%

## [0.7.1] - 2026-03-01

### Fixed
- Include man page (`git-hunk.1`) in release tarballs so `git hunk --help` works after Homebrew install

## [0.7.0] - 2026-02-28

### Added
- `--verbose` / `-v` flag on `add`, `reset`, and `stash` commands
- Unknown flag errors now print the offending flag name

### Changed
- Hint messages (staging hash hint, stash next-steps) only shown with `--verbose`

## [0.6.0] - 2026-02-28

### Added
- Per-command `--help`/`-h` flag on all subcommands
- `help <command>` form for per-command help (`git hunk help list`)
- Man page (`doc/git-hunk.1`) for `git hunk --help` integration
- Untracked file support: untracked files shown by default in all commands
- `--tracked-only` and `--untracked-only` filter flags on all commands
- Stash support for untracked files using git's native 3-parent stash format
- `stash push` optional keyword (matches `git stash push` pattern)
- `stash --include-untracked` / `-u` flag for `stash --all`
- `discard --force` gate for untracked files (permanent deletion)
- `discard --dry-run` works for untracked files without requiring `--force`
- Mutual exclusion validation for `--tracked-only` + `--untracked-only`
- Integration tests split into 7 parallel suites (93 tests)

### Changed
- **Breaking:** `remove` command renamed to `reset` (matches `git reset`)
- **Breaking:** `--context <n>` renamed to `--unified <n>` / `-U <n>` (matches git convention)
- **Breaking:** `stash --pop` changed to `stash pop` subcommand (matches `git stash pop`)
- **Breaking:** `stash --all` now excludes untracked files by default (use `-u` to include)
- Reformatted global help text for scannability

### Fixed
- Executable bit preserved when stashing untracked files
- Discard error message now shows both SHA and file path
- Discard error message uses consistent `--` (was Unicode em dash)

## [0.5.0] - 2026-02-28

### Added
- `stash` command: saves selected hunks into a real git stash entry and removes them from the worktree
- `stash --pop`: restores most recent stash via `git stash pop`
- `stash --all`: stash all unstaged hunks at once
- `stash --file <path>`: stash hunks in a specific file
- `stash -m <msg>`: custom stash message (auto-generates from file paths if omitted)
- `--porcelain` output for `stash` command
- Two-diff strategy ensures correct stash content even with dirty index

### Fixed
- `git apply` failures in stash worktree cleanup now handled gracefully instead of process exit

## [0.4.0] - 2026-02-27

### Added
- `count` command: outputs bare hunk count as integer (always exit 0)
- `check` command: validates hunk hashes exist in current diff (silent success, exit 1 on failure)
- `check --exclusive`: asserts provided hashes are the *only* hunks (no extras)
- `discard` command: reverts unstaged worktree changes by hunk hash (`git apply --reverse`)
- `discard --dry-run`: preview what would be discarded without modifying the worktree
- `discard --all`: discard all unstaged hunks at once
- `--porcelain` output for `add`, `remove`, `check`, and `discard` commands
- Scripting workflow: `count --staged` + `check --exclusive` + `add` + `commit` for guaranteed precise commits

### Changed
- Add/remove summary line suppressed in `--porcelain` mode for clean machine parsing
- Staging hint only shown in human output mode (not porcelain)
- `check` stderr summary uses "failed" instead of "stale" for clarity

### Fixed
- Usage text now shows `--porcelain` flag for `add` and `remove` commands
- Dry-run apply failure message distinguishes from normal apply failure
- Empty matched hunk list in discard reports helpful error instead of silent no-op

## [0.3.1] - 2026-02-26

### Added
- `--no-color` flag for `add` and `remove` commands (all commands now accept it)
- Colored SHA output in add/remove confirmation (yellow, matching list/show)
- Hash mapping display: `staged X → Y  file` shows both old and new hash after staging
- Count summary after add/remove (e.g., `3 hunks staged`) printed to stderr
- Hint after staging about hash differences printed to stderr

### Changed
- Summary column now shows first changed line instead of function context (answers "what changed?" instead of "where?")
- `getTerminalWidth()` reads `COLUMNS` env var as fallback when ioctl fails (CI/agent support)

### Fixed
- Narrow terminal formatting: graceful degradation with 40-column minimum floor and summary truncation
- Staging hint only shows in interactive TTY contexts (not when piped)

## [0.3.0] - 2026-02-25

### Added
- Per-SHA line selection syntax (`sha:3-5,8`) for `add` and `show` commands
- `--context N` flag to control diff context lines (respects git's `diff.context` setting)
- `--oneline` flag for compact one-line-per-hunk output (list now shows diffs by default)
- `--all` flag for `add` and `remove` to stage/unstage all hunks at once
- `--no-color` flag to disable color output
- `--file <path>` without SHAs to bulk stage/unstage all hunks in a file
- Color output: yellow SHAs, green additions, red deletions (auto-detected TTY)
- Dynamic column widths based on terminal size
- Summary truncation for long function contexts
- Hunk count summary line in human mode
- Comprehensive unit test suite (113 tests) and integration test suite (9 tests)

### Changed
- List command now shows inline diff content by default (previously required `--diff`)
- Respects git's `diff.context` gitconfig setting instead of hardcoding 3 lines
- Always passes `--unidiff-zero` to `git apply` for compatibility with any context level
- Refactored monolithic `main.zig` into 7 focused modules for testability

### Fixed
- Correct file mode handling and patch ordering for edge cases
- Overflow detection in `parseU32` and debug assertions in slice helpers
- Standardized em dash to double-hyphen in help text
- Eliminated unnecessary memcpy in diff parser
- Validated semver before awk interpolation in release workflow

### Security
- Pinned CI GitHub Actions to commit SHAs for supply chain security

## [0.2.0] - 2026-02-25

### Added
- `git hunk show <sha>...` command to display full diff content of specific hunks
- `--diff` flag on `list` command to inline diff body alongside each hunk
- Untracked file hint: warns when untracked files exist (use `git add -N` to include)
- `--staged` and `--porcelain` flags on `show` command
- Porcelain multi-line record format for `--diff` and `show` output

## [0.1.0] - 2026-02-25

### Added
- `git hunk list` command with human-readable and `--porcelain` output
- `git hunk add <sha>...` to stage hunks by content hash
- `git hunk remove <sha>...` to unstage hunks
- `--staged` flag for listing staged hunks
- `--file <path>` flag for filtering by file
- SHA prefix matching (minimum 4 hex characters)
- Stable content-based SHA1 hashing (hashes don't change when other hunks are staged/unstaged)
- Support for new files, deleted files, and no-trailing-newline
- Duplicate SHA dedup in multi-hunk operations
