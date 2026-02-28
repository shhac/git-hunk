const std = @import("std");

pub const Command = enum {
    list,
    show,
    add,
    remove,
    discard,
    count,
    check,
    stash,
};

pub fn commandFromString(s: []const u8) ?Command {
    const map = std.StaticStringMap(Command).initComptime(.{
        .{ "list", .list },
        .{ "show", .show },
        .{ "add", .add },
        .{ "remove", .remove },
        .{ "discard", .discard },
        .{ "count", .count },
        .{ "check", .check },
        .{ "stash", .stash },
    });
    return map.get(s);
}

pub fn printCommandHelp(stdout: *std.Io.Writer, cmd: Command) !void {
    const text = switch (cmd) {
        .list => list_help,
        .show => show_help,
        .add => add_help,
        .remove => remove_help,
        .discard => discard_help,
        .count => count_help,
        .check => check_help,
        .stash => stash_help,
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
    \\  --file <path>     Restrict output to hunks in the given file
    \\  --porcelain       Machine-readable output (tab-separated fields)
    \\  --oneline         One hunk per line: hash, file, and line range
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only show hunks from tracked files
    \\  --untracked-only  Only show hunks from untracked files
    \\  --context <n>     Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\EXAMPLES
    \\  git-hunk list                          List all unstaged hunks
    \\  git-hunk list --oneline                Compact one-line-per-hunk output
    \\  git-hunk list --staged                 List hunks in the staging area
    \\  git-hunk list --file src/main.zig      List hunks for a specific file
    \\  git-hunk list --porcelain --oneline    Machine-readable compact output
    \\  git-hunk list --context 0              List hunks with no surrounding context
    \\
;

const show_help: []const u8 =
    \\git-hunk show - Show diff content of specific hunks
    \\
    \\USAGE
    \\  git-hunk show [options] <sha[:lines]>...
    \\
    \\ARGUMENTS
    \\  <sha[:lines]>...  One or more hunk hashes (prefix match, min 4 hex chars).
    \\                    Append :lines to select specific lines (e.g. a3f7:3-5,8).
    \\
    \\OPTIONS
    \\  --staged          Show hunks from the staged diff instead of worktree
    \\  --file <path>     Restrict to hunks in the given file
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only show hunks from tracked files
    \\  --untracked-only  Only show hunks from untracked files
    \\  --context <n>     Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\EXAMPLES
    \\  git-hunk show a3f7c21                  Show a hunk by full hash
    \\  git-hunk show a3f7 b82e                Show multiple hunks by prefix
    \\  git-hunk show a3f7c21 --staged         Show a staged hunk
    \\  git-hunk show a3f7:3-5,8               Show specific lines of a hunk
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
    \\  --all             Stage all unstaged hunks
    \\  --file <path>     Stage all hunks in the given file
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only include hunks from tracked files
    \\  --untracked-only  Only include hunks from untracked files
    \\  --context <n>     Lines of diff context (default: git's diff.context or 3)
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

const remove_help: []const u8 =
    \\git-hunk remove - Unstage hunks (or selected lines) by hash
    \\
    \\USAGE
    \\  git-hunk remove [options] [<sha[:lines]>...]
    \\
    \\ARGUMENTS
    \\  <sha[:lines]>...  Staged hunk hashes to unstage (use `list --staged` to find).
    \\                    Prefix match, min 4 hex chars. Append :lines for specific lines.
    \\                    Optional when --all or --file is used.
    \\
    \\OPTIONS
    \\  --all             Unstage all staged hunks
    \\  --file <path>     Unstage all hunks in the given file
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only include hunks from tracked files
    \\  --untracked-only  Only include hunks from untracked files
    \\  --context <n>     Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\EXAMPLES
    \\  git-hunk remove a3f7c21                Unstage a single hunk
    \\  git-hunk remove --all                  Unstage all staged hunks
    \\  git-hunk remove --file src/main.zig    Unstage all hunks in a file
    \\
;

const discard_help: []const u8 =
    \\git-hunk discard - Discard unstaged worktree changes by hash
    \\
    \\USAGE
    \\  git-hunk discard [options] [<sha[:lines]>...]
    \\
    \\ARGUMENTS
    \\  <sha[:lines]>...  Hunk hashes to discard (prefix match, min 4 hex chars).
    \\                    Append :lines for specific lines. Optional when --all or --file is used.
    \\
    \\OPTIONS
    \\  --all             Discard all unstaged hunks (DESTRUCTIVE)
    \\  --file <path>     Discard all hunks in the given file
    \\  --force           Required to discard untracked files (deletes them permanently)
    \\  --dry-run         Show what would be discarded without making changes
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only include hunks from tracked files
    \\  --untracked-only  Only include hunks from untracked files
    \\  --context <n>     Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\  WARNING: This command is DESTRUCTIVE. Discarded changes cannot be recovered.
    \\  Untracked files require --force to discard (they will be deleted entirely).
    \\  Use --dry-run to preview before discarding.
    \\
    \\EXAMPLES
    \\  git-hunk discard a3f7c21               Discard a single hunk
    \\  git-hunk discard --all                 Discard all unstaged changes
    \\  git-hunk discard --dry-run a3f7c21     Preview what would be discarded
    \\  git-hunk discard a3f7:3-5              Discard specific lines from a hunk
    \\  git-hunk discard --force a3f7c21       Discard an untracked file (deletes it)
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
    \\  --file <path>     Count hunks in the given file only
    \\  --tracked-only    Only count hunks from tracked files
    \\  --untracked-only  Only count hunks from untracked files
    \\  --context <n>     Lines of diff context (default: git's diff.context or 3)
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
    \\  --exclusive       Assert these are the ONLY hunks in the diff (exits 1 otherwise)
    \\  --file <path>     Restrict check to hunks in the given file
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only check hunks from tracked files
    \\  --untracked-only  Only check hunks from untracked files
    \\  --context <n>     Lines of diff context (default: git's diff.context or 3)
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
    \\
;

const stash_help: []const u8 =
    \\git-hunk stash - Stash hunks into git stash, remove from worktree
    \\
    \\USAGE
    \\  git-hunk stash [options] [<sha>...]
    \\
    \\ARGUMENTS
    \\  <sha>...          Hunk hashes to stash (no line specs). Optional when --all,
    \\                    --file, or --pop is used.
    \\
    \\OPTIONS
    \\  --all             Stash all unstaged hunks
    \\  --file <path>     Stash all hunks in the given file
    \\  --pop             Restore the most recent git-hunk stash (cannot combine with
    \\                    other flags)
    \\  -m, --message <msg>
    \\                    Set the stash message
    \\  --porcelain       Machine-readable output
    \\  --no-color        Disable colored output
    \\  --tracked-only    Only include hunks from tracked files
    \\  --untracked-only  Only include hunks from untracked files
    \\  --context <n>     Lines of diff context (default: git's diff.context or 3)
    \\  --help, -h        Show this help
    \\
    \\EXAMPLES
    \\  git-hunk stash a3f7c21                 Stash a single hunk
    \\  git-hunk stash --all                   Stash all unstaged hunks
    \\  git-hunk stash -m "wip"                Stash with a message
    \\  git-hunk stash --pop                   Restore the most recent stash
    \\
;
