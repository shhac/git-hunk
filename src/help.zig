const std = @import("std");

pub const Command = enum {
    list,
    diff,
    add,
    reset,
    restore,
    count,
    check,
    stash,
    commit,
};

pub fn commandFromString(s: []const u8) ?Command {
    const map = std.StaticStringMap(Command).initComptime(.{
        .{ "list", .list },
        .{ "diff", .diff },
        .{ "add", .add },
        .{ "reset", .reset },
        .{ "restore", .restore },
        .{ "count", .count },
        .{ "check", .check },
        .{ "stash", .stash },
        .{ "commit", .commit },
    });
    return map.get(s);
}

pub fn printCommandHelp(stdout: *std.Io.Writer, cmd: Command) !void {
    const text = switch (cmd) {
        .list => list_help,
        .diff => diff_help,
        .add => add_help,
        .reset => reset_help,
        .restore => restore_help,
        .count => count_help,
        .check => check_help,
        .stash => stash_help,
        .commit => commit_help,
    };
    try stdout.writeAll(text);
}

const list_help: []const u8 =
    \\git-hunk list - List diff hunks with content hashes
    \\
    \\USAGE
    \\  git-hunk list [options]
    \\
    \\OPTIONS
    \\  --staged          List hunks from the staged (index) diff instead of worktree
    \\  --ref <refspec>   Compare against a git ref instead of the default.
    \\                    Single ref (e.g. HEAD, main) diffs ref vs worktree.
    \\                    Range (e.g. main..HEAD) diffs between two refs.
    \\                    Combines with --staged for ref vs index comparison.
    \\  --file <path>     Restrict output to hunks in the given file
    \\  --porcelain       Machine-readable output (tab-separated fields)
    \\  --oneline         One hunk per line: hash, file, and line range
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only show hunks from tracked files
    \\  --untracked-only  Only show hunks from untracked files
    \\  -U, --unified <n> Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\EXAMPLES
    \\  git-hunk list                          List all unstaged hunks
    \\  git-hunk list --oneline                Compact one-line-per-hunk output
    \\  git-hunk list --staged                 List hunks in the staging area
    \\  git-hunk list --file src/main.zig      List hunks for a specific file
    \\  git-hunk list --porcelain --oneline    Machine-readable compact output
    \\  git-hunk list --unified 0              List hunks with no surrounding context
    \\  git-hunk list --ref main               List all changes vs main
    \\  git-hunk list --ref HEAD~1..HEAD       List hunks from the last commit
    \\
;

const diff_help: []const u8 =
    \\git-hunk diff - Show diff content of specific hunks
    \\
    \\USAGE
    \\  git-hunk diff [options] <sha[:lines]>...
    \\
    \\ARGUMENTS
    \\  <sha[:lines]>...  One or more hunk hashes (prefix match, min 4 hex chars).
    \\                    Append :lines to select specific lines (e.g. a3f7:3-5,8).
    \\
    \\OPTIONS
    \\  --staged          Show hunks from the staged diff instead of worktree
    \\  --ref <refspec>   Compare against a git ref instead of the default.
    \\                    Single ref (e.g. HEAD, main) diffs ref vs worktree.
    \\                    Range (e.g. main..HEAD) diffs between two refs.
    \\                    Combines with --staged for ref vs index comparison.
    \\  --file <path>     Restrict to hunks in the given file
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only show hunks from tracked files
    \\  --untracked-only  Only show hunks from untracked files
    \\  -U, --unified <n> Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\EXAMPLES
    \\  git-hunk diff a3f7c21                  Show a hunk by full hash
    \\  git-hunk diff a3f7 b82e                Show multiple hunks by prefix
    \\  git-hunk diff a3f7c21 --staged         Show a staged hunk
    \\  git-hunk diff a3f7:3-5,8               Show specific lines of a hunk
    \\  git-hunk diff --ref main a3f7          Show a hunk from diff vs main
    \\
;

const add_help: []const u8 =
    \\git-hunk add - Stage hunks (or selected lines) by hash
    \\
    \\USAGE
    \\  git-hunk add [options] [<sha[:lines]>...]
    \\
    \\ARGUMENTS
    \\  <sha[:lines]>...  Hunk hashes to stage (prefix match, min 4 hex chars).
    \\                    Append :lines to stage specific lines (e.g. a3f7:3-5,8).
    \\                    Optional when --all or --file is used.
    \\
    \\OPTIONS
    \\  --ref <refspec>   Compare against a git ref instead of the default.
    \\                    Single ref (e.g. HEAD, main) diffs ref vs worktree.
    \\                    Range (e.g. main..HEAD) diffs between two refs.
    \\                    Combines with --staged for ref vs index comparison.
    \\  --all             Stage all unstaged hunks
    \\  --file <path>     Stage all hunks in the given file
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only include hunks from tracked files
    \\  --untracked-only  Only include hunks from untracked files
    \\  -U, --unified <n> Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\EXAMPLES
    \\  git-hunk add a3f7c21                   Stage a single hunk
    \\  git-hunk add a3f7 b82e                 Stage multiple hunks by prefix
    \\  git-hunk add --all                     Stage all unstaged hunks
    \\  git-hunk add --file src/main.zig       Stage all hunks in a file
    \\  git-hunk add a3f7:3-5,8               Stage specific lines from a hunk
    \\
;

const reset_help: []const u8 =
    \\git-hunk reset - Unstage hunks (or selected lines) by hash
    \\
    \\USAGE
    \\  git-hunk reset [options] [<sha[:lines]>...]
    \\
    \\ARGUMENTS
    \\  <sha[:lines]>...  Staged hunk hashes to unstage (use `list --staged` to find).
    \\                    Prefix match, min 4 hex chars. Append :lines for specific lines.
    \\                    Optional when --all or --file is used.
    \\
    \\OPTIONS
    \\  --ref <refspec>   Compare against a git ref instead of the default.
    \\                    Single ref (e.g. HEAD, main) diffs ref vs worktree.
    \\                    Range (e.g. main..HEAD) diffs between two refs.
    \\                    Combines with --staged for ref vs index comparison.
    \\  --all             Unstage all staged hunks
    \\  --file <path>     Unstage all hunks in the given file
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only include hunks from tracked files
    \\  --untracked-only  Only include hunks from untracked files
    \\  -U, --unified <n> Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\EXAMPLES
    \\  git-hunk reset a3f7c21                Unstage a single hunk
    \\  git-hunk reset --all                  Unstage all staged hunks
    \\  git-hunk reset --file src/main.zig    Unstage all hunks in a file
    \\
;

const restore_help: []const u8 =
    \\git-hunk restore - Restore unstaged worktree changes by hash
    \\
    \\USAGE
    \\  git-hunk restore [options] [<sha[:lines]>...]
    \\
    \\ARGUMENTS
    \\  <sha[:lines]>...  Hunk hashes to restore (prefix match, min 4 hex chars).
    \\                    Append :lines for specific lines. Optional when --all or --file is used.
    \\
    \\OPTIONS
    \\  --ref <refspec>   Compare against a git ref instead of the default.
    \\                    Single ref (e.g. HEAD, main) diffs ref vs worktree.
    \\                    Range (e.g. main..HEAD) diffs between two refs.
    \\                    Combines with --staged for ref vs index comparison.
    \\  --all             Restore all unstaged hunks (DESTRUCTIVE)
    \\  --file <path>     Restore all hunks in the given file
    \\  --force           Required to restore untracked files (deletes them permanently)
    \\  --dry-run         Show what would be restored without making changes
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only include hunks from tracked files
    \\  --untracked-only  Only include hunks from untracked files
    \\  -U, --unified <n> Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\  WARNING: This command is DESTRUCTIVE. Restored changes cannot be recovered.
    \\  Untracked files require --force to restore (they will be deleted entirely).
    \\  Use --dry-run to preview before restoring.
    \\
    \\EXAMPLES
    \\  git-hunk restore a3f7c21               Restore a single hunk
    \\  git-hunk restore --all                 Restore all unstaged changes
    \\  git-hunk restore --dry-run a3f7c21     Preview what would be restored
    \\  git-hunk restore a3f7:3-5              Restore specific lines from a hunk
    \\  git-hunk restore --force a3f7c21       Restore an untracked file (deletes it)
    \\
;

const count_help: []const u8 =
    \\git-hunk count - Count diff hunks
    \\
    \\USAGE
    \\  git-hunk count [options]
    \\
    \\OUTPUT
    \\  Prints a single integer (the number of hunks) and always exits 0.
    \\
    \\OPTIONS
    \\  --staged          Count staged hunks instead of unstaged
    \\  --ref <refspec>   Compare against a git ref instead of the default.
    \\                    Single ref (e.g. HEAD, main) diffs ref vs worktree.
    \\                    Range (e.g. main..HEAD) diffs between two refs.
    \\                    Combines with --staged for ref vs index comparison.
    \\  --file <path>     Count hunks in the given file only
    \\  --tracked-only    Only count hunks from tracked files
    \\  --untracked-only  Only count hunks from untracked files
    \\  -U, --unified <n> Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\EXAMPLES
    \\  git-hunk count                         Count all unstaged hunks
    \\  git-hunk count --staged                Count staged hunks
    \\  git-hunk count --file src/main.zig     Count hunks in a specific file
    \\
;

const check_help: []const u8 =
    \\git-hunk check - Validate hunk hashes exist in current diff
    \\
    \\USAGE
    \\  git-hunk check [options] <sha>...
    \\
    \\ARGUMENTS
    \\  <sha>...          One or more hunk hashes to validate (no line specs allowed).
    \\
    \\OPTIONS
    \\  --staged          Check against staged diff instead of worktree
    \\  --ref <refspec>   Compare against a git ref instead of the default.
    \\                    Single ref (e.g. HEAD, main) diffs ref vs worktree.
    \\                    Range (e.g. main..HEAD) diffs between two refs.
    \\                    Combines with --staged for ref vs index comparison.
    \\  --exclusive       Assert these are the ONLY hunks in the diff (exits 1 otherwise)
    \\  --allow-empty     Allow zero SHA arguments (useful with --exclusive to assert no hunks)
    \\  --file <path>     Restrict check to hunks in the given file
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only check hunks from tracked files
    \\  --untracked-only  Only check hunks from untracked files
    \\  -U, --unified <n> Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\EXIT STATUS
    \\  0  All specified hashes exist (and are exclusive, if --exclusive)
    \\  1  One or more hashes not found, or extra hunks exist with --exclusive
    \\
    \\EXAMPLES
    \\  git-hunk check a3f7c21                 Verify a hash exists
    \\  git-hunk check a3f7 b82e               Verify multiple hashes
    \\  git-hunk check --exclusive a3f7 b82e   Assert these are the only hunks
    \\  git-hunk check --exclusive --allow-empty --staged
    \\                                         Assert no staged hunks exist
    \\
;

const stash_help: []const u8 =
    \\git-hunk stash - Stash hunks into git stash, remove from worktree
    \\
    \\USAGE
    \\  git-hunk stash [push] [options] [<sha>...]
    \\  git-hunk stash pop
    \\
    \\SUBCOMMANDS
    \\  push              Stash hunks (default when omitted)
    \\  pop               Restore the most recent git-hunk stash
    \\
    \\ARGUMENTS
    \\  <sha>...          Hunk hashes to stash (no line specs). Optional when --all
    \\                    or --file is used.
    \\
    \\OPTIONS (push only)
    \\  --all             Stash all unstaged tracked hunks
    \\  --include-untracked, -u
    \\                    Include untracked files (use with --all)
    \\  --file <path>     Stash all hunks in the given file
    \\  -m, --message <msg>
    \\                    Set the stash message
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only include hunks from tracked files
    \\  --untracked-only  Only include hunks from untracked files
    \\  -U, --unified <n> Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\  Note: --all without -u stashes only tracked changes (like git stash push).
    \\  Explicit hashes always stash the specified hunks regardless of -u.
    \\
    \\EXAMPLES
    \\  git-hunk stash a3f7c21                 Stash a single hunk
    \\  git-hunk stash --all                   Stash all tracked unstaged hunks
    \\  git-hunk stash --all -u                Stash all hunks including untracked
    \\  git-hunk stash push -m "wip"           Stash with a message
    \\  git-hunk stash pop                     Restore the most recent stash
    \\
;

const commit_help: []const u8 =
    \\git-hunk commit - Commit specific hunks directly, bypassing manual staging
    \\
    \\USAGE
    \\  git-hunk commit [options] [<sha[:lines]>...]
    \\
    \\ARGUMENTS
    \\  <sha[:lines]>...  Hunk hashes to commit (prefix match, min 4 hex chars).
    \\                    Append :lines to commit specific lines (e.g. a3f7:3-5,8).
    \\                    Optional when --all or --file is used.
    \\
    \\OPTIONS
    \\  -m, --message <msg>
    \\                    Commit message (required unless --dry-run)
    \\  --amend           Amend the previous commit
    \\  --dry-run         Show what would be committed without committing
    \\  --all             Commit all unstaged hunks
    \\  --file <path>     Commit all hunks in a file
    \\  --ref <refspec>   Compare against a git ref instead of the default.
    \\                    Single ref (e.g. HEAD, main) diffs ref vs worktree.
    \\                    Range (e.g. main..HEAD) diffs between two refs.
    \\  -U, --unified <n> Lines of diff context (default: git's diff.context or 3)
    \\  --tracked-only    Only include hunks from tracked files
    \\  --untracked-only  Only include hunks from untracked files
    \\  --no-color        Disable colored output
    \\  --porcelain       Machine-readable output
    \\  -v, --verbose     Show summary counts
    \\  -q, --quiet       Suppress output
    \\  --help, -h        Show this help
    \\
    \\  Note: --staged is not supported. Use 'git commit' directly for staged changes.
    \\
    \\EXAMPLES
    \\  git-hunk commit a3f7 b82e -m "feat: add validation"
    \\  git-hunk commit --all -m "feat: everything"
    \\  git-hunk commit --file src/foo.zig -m "refactor: cleanup"
    \\  git-hunk commit a3f7:3-5 -m "fix: specific lines"
    \\  git-hunk commit a3f7 --amend -m "fix: forgotten change"
    \\  git-hunk commit --dry-run a3f7 -m "check first"
    \\
;
