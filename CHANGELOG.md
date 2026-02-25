# Changelog

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
