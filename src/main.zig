const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const args_mod = @import("args.zig");
const commands = @import("commands.zig");
const help = @import("help.zig");
const path_mod = @import("path.zig");

// Import modules to ensure their tests are discovered by `zig build test`.
// A module missing here has its tests silently skipped, not reported — every
// module carrying `test` blocks must be listed, including ones already
// imported above for their symbols.
comptime {
    _ = @import("args.zig");
    _ = @import("commands.zig");
    _ = @import("diff.zig");
    _ = @import("format.zig");
    _ = @import("git.zig");
    _ = @import("help.zig");
    _ = @import("patch.zig");
    _ = @import("path.zig");
    _ = @import("stash.zig");
}

const fatal = types.fatal;

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        if (err == error.PatchFailed) {
            // Descriptive message already printed by runGitApply
            std.process.exit(1);
        }
        fatal("{s}", .{@errorName(err)});
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    types.setIo(io);
    types.setEnvMap(init.environ_map);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    // Streaming, not positional: a positional writer starts at offset 0 and
    // ignores the offset the shell already put on the inherited descriptor, so
    // `git hunk list >> log` and `{ echo hi; git hunk list; } > out` would
    // overwrite whatever preceded them.
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const process_args = try init.minimal.args.toSlice(init.arena.allocator());

    if (process_args.len < 2) {
        try printUsage(stdout);
        try stdout.flush();
        std.process.exit(1);
    }

    const subcmd = process_args[1];

    // chdir to repo root so all git operations use repo-relative paths.
    // Must happen before any command runs. Non-fatal: if we're not in a repo,
    // let downstream git commands report the error.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix = path_mod.chdirToRepoRoot(arena) catch "";
    // Parsing runs after the chdir, so anything that opens a user-supplied path
    // during parsing (--files-from) needs the prefix to stay cwd-relative.
    types.setRepoPrefix(prefix);

    if (std.mem.eql(u8, subcmd, "list")) {
        var opts = args_mod.parseListArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .list);
        defer args_mod.deinitFileFilter(allocator, opts.file_filter);
        try resolveFileFilter(allocator, arena, prefix, opts.file_filter);
        try expandRefShorthand(arena, &opts.ref, opts.mode == .staged);
        try commands.cmdList(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        var opts = args_mod.parseAddResetArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .add);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        defer args_mod.deinitFileFilter(allocator, opts.file_filter);
        try resolveFileFilter(allocator, arena, prefix, opts.file_filter);
        try expandRefShorthand(arena, &opts.ref, false);
        try commands.cmdAdd(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "reset")) {
        var opts = args_mod.parseAddResetArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .reset);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        defer args_mod.deinitFileFilter(allocator, opts.file_filter);
        try resolveFileFilter(allocator, arena, prefix, opts.file_filter);
        try expandRefShorthand(arena, &opts.ref, false);
        try commands.cmdReset(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "count")) {
        var opts = args_mod.parseCountArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .count);
        defer args_mod.deinitFileFilter(allocator, opts.file_filter);
        try resolveFileFilter(allocator, arena, prefix, opts.file_filter);
        try expandRefShorthand(arena, &opts.ref, opts.mode == .staged);
        try commands.cmdCount(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "check")) {
        var opts = args_mod.parseCheckArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .check);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        defer args_mod.deinitFileFilter(allocator, opts.file_filter);
        try resolveFileFilter(allocator, arena, prefix, opts.file_filter);
        try expandRefShorthand(arena, &opts.ref, opts.mode == .staged);
        try commands.cmdCheck(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "restore")) {
        var opts = args_mod.parseRestoreArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .restore);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        defer args_mod.deinitFileFilter(allocator, opts.file_filter);
        try resolveFileFilter(allocator, arena, prefix, opts.file_filter);
        try expandRefShorthand(arena, &opts.ref, false);
        try commands.cmdRestore(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "diff")) {
        var opts = args_mod.parseDiffArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .diff);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        defer args_mod.deinitFileFilter(allocator, opts.file_filter);
        try resolveFileFilter(allocator, arena, prefix, opts.file_filter);
        try expandRefShorthand(arena, &opts.ref, opts.mode == .staged);
        try commands.cmdDiff(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "stash")) {
        var opts = args_mod.parseStashArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .stash);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        defer args_mod.deinitFileFilter(allocator, opts.file_filter);
        try resolveFileFilter(allocator, arena, prefix, opts.file_filter);
        try expandRefShorthand(arena, &opts.ref, false);
        try commands.cmdStash(allocator, stdout, opts, init.environ_map);
    } else if (std.mem.eql(u8, subcmd, "commit")) {
        var opts = args_mod.parseCommitArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .commit);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        defer args_mod.deinitFileFilter(allocator, opts.file_filter);
        try resolveFileFilter(allocator, arena, prefix, opts.file_filter);
        try expandRefShorthand(arena, &opts.ref, false);
        try commands.cmdCommit(allocator, stdout, opts, init.environ_map);
    } else if (std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "-V")) {
        try stdout.print("git-hunk {s}\n", .{build_options.version});
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "help")) {
        if (process_args.len > 2) {
            if (help.commandFromString(process_args[2])) |cmd| {
                try help.printCommandHelp(stdout, cmd);
            } else {
                std.debug.print("error: unknown command '{s}'\n", .{process_args[2]});
                try printUsage(stdout);
                try stdout.flush();
                std.process.exit(1);
            }
        } else {
            try printUsage(stdout);
        }
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{subcmd});
        try printUsage(stdout);
        try stdout.flush();
        std.process.exit(1);
    }
    try stdout.flush();
}

/// Rewrite each `--file`/`--files-from` path to be repo-relative, in place.
///
/// Entries stay owned by `allocator` (see `args.deinitFileFilter`): the
/// resolved path is copied back onto the same allocator and the old entry
/// freed, so the caller's `deinitFileFilter` remains correct. `arena` holds
/// only the short-lived resolution scratch.
fn resolveFileFilter(allocator: std.mem.Allocator, arena: std.mem.Allocator, prefix: []const u8, filter: []const []const u8) !void {
    if (prefix.len == 0) return;
    const spine: [][]const u8 = @constCast(filter);
    for (spine) |*entry| {
        const resolved = try path_mod.resolveToRepoRelative(arena, prefix, entry.*);
        const owned = try allocator.dupe(u8, resolved);
        allocator.free(entry.*);
        entry.* = owned;
    }
}

/// Well-known empty-tree SHA in git. `git diff <empty-tree>..<commit>` shows
/// the full content of `<commit>` as additions — used to handle parentless
/// commits where `<commit>^` doesn't exist.
const EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// Expand a single-ref `--ref <commit>` into the equivalent range `<commit>^..<commit>`
/// (matching `git show <commit>` semantics). For commits without a parent (initial
/// commits), expands to `<empty-tree>..<commit>` so the full content is shown.
/// Range refs (containing `..`) and null refs pass through unchanged.
///
/// `is_staged` short-circuits the expansion: with `--staged`, the user-visible
/// meaning of `--ref X` is "diff staged index against X" — git diff with `--cached`
/// silently ignores the second tree if a range is passed, so we must keep the
/// single-ref form here.
fn expandRefShorthand(arena: std.mem.Allocator, ref: *?[]const u8, is_staged: bool) !void {
    if (is_staged) return;
    const r = ref.* orelse return;
    if (std.mem.indexOf(u8, r, "..") != null) return;
    ref.* = if (try refHasParent(arena, r))
        try std.fmt.allocPrint(arena, "{s}^..{s}", .{ r, r })
    else
        try std.fmt.allocPrint(arena, "{s}..{s}", .{ EMPTY_TREE_SHA, r });
}

/// Returns true if `git rev-parse --verify <ref>^` succeeds — i.e. the ref has
/// a parent commit. Soft-fails to false on any error so callers can use the
/// empty-tree fallback.
fn refHasParent(arena: std.mem.Allocator, ref: []const u8) !bool {
    const probe = try std.fmt.allocPrint(arena, "{s}^", .{ref});
    const argv = [_][]const u8{ "git", "rev-parse", "--verify", "--quiet", probe };
    const io = types.getIo();
    const result = std.process.run(arena, io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    arena.free(result.stdout);
    arena.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn handleParseError(stdout: *std.Io.Writer, err: anyerror, cmd: help.Command) noreturn {
    if (err == error.ConflictingFilter) {
        std.debug.print("error: --tracked-only and --untracked-only are mutually exclusive\n", .{});
        std.process.exit(1);
    }
    if (err == error.HelpRequested) {
        help.printCommandHelp(stdout, cmd) catch {};
        stdout.flush() catch {};
        std.process.exit(0);
    }
    printUsage(stdout) catch {};
    stdout.flush() catch {};
    std.process.exit(1);
}

fn printUsage(stdout: *std.Io.Writer) !void {
    try stdout.print("git-hunk {s}\n", .{build_options.version});
    try stdout.writeAll(help.top_help);
}
