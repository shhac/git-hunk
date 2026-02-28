# Changelog

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
