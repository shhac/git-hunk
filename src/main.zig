const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const args_mod = @import("args.zig");
const commands = @import("commands.zig");
const git = @import("git.zig");
const help = @import("help.zig");
const path_mod = @import("path.zig");

// Import modules to ensure their tests are discovered by `zig build test`.
// A module missing here has its tests silently skipped, not reported — every
// module carrying `test` blocks must be listed, including ones already
// imported above for their symbols.
comptime {
    _ = @import("args.zig");
    _ = @import("check.zig");
    _ = @import("commands.zig");
    _ = @import("commit.zig");
    _ = @import("diff.zig");
    _ = @import("format.zig");
    _ = @import("git.zig");
    _ = @import("head_match.zig");
    _ = @import("help.zig");
    _ = @import("patch.zig");
    _ = @import("path.zig");
    _ = @import("result_groups.zig");
    _ = @import("source.zig");
    _ = @import("stash.zig");
}

const fatal = types.fatal;

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        if (err == error.PatchFailed or err == error.NoSelectedLines) {
            // Descriptive message already printed where the error arose
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
    // Parsing runs after the chdir, so every user-supplied path it reads
    // (--file, --files-from) needs the prefix to stay cwd-relative.
    types.setRepoPrefix(prefix);

    if (std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "-V")) {
        try stdout.print("git-hunk {s}\n", .{build_options.version});
        try stdout.flush();
        return;
    }
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "help")) {
        try printHelp(stdout, if (process_args.len > 2) process_args[2] else null);
        try stdout.flush();
        return;
    }

    const cmd = help.commandFromString(subcmd) orelse try exitUnknownCommand(stdout, subcmd);
    const sub_args = process_args[2..];
    switch (cmd) {
        .list => try runSubcommand(allocator, arena, stdout, sub_args, .list, args_mod.parseListArgs, commands.cmdList),
        .diff => try runSubcommand(allocator, arena, stdout, sub_args, .diff, args_mod.parseDiffArgs, commands.cmdDiff),
        .add => try runSubcommand(allocator, arena, stdout, sub_args, .add, args_mod.parseAddArgs, commands.cmdAdd),
        .reset => try runSubcommand(allocator, arena, stdout, sub_args, .reset, args_mod.parseResetArgs, commands.cmdReset),
        .restore => try runSubcommand(allocator, arena, stdout, sub_args, .restore, args_mod.parseRestoreArgs, commands.cmdRestore),
        .count => try runSubcommand(allocator, arena, stdout, sub_args, .count, args_mod.parseCountArgs, commands.cmdCount),
        .check => try runSubcommand(allocator, arena, stdout, sub_args, .check, args_mod.parseCheckArgs, commands.cmdCheck),
        .stash => try runSubcommand(allocator, arena, stdout, sub_args, .stash, args_mod.parseStashArgs, commands.cmdStash),
        .commit => try runSubcommand(allocator, arena, stdout, sub_args, .commit, args_mod.parseCommitArgs, commands.cmdCommit),
    }
    try stdout.flush();
}

/// The lifecycle every subcommand shares: parse, resolve the diff source, run, free.
fn runSubcommand(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    sub_args: []const [:0]const u8,
    comptime cmd: help.Command,
    comptime parse: anytype,
    comptime exec: anytype,
) !void {
    var opts = parse(allocator, sub_args) catch |err| handleParseError(stdout, err, cmd);
    defer args_mod.deinitOptions(allocator, &opts);
    try resolveSource(arena, &opts.common.source);
    try exec(allocator, stdout, opts);
}

fn printHelp(stdout: *std.Io.Writer, topic: ?[]const u8) !void {
    const name = topic orelse return printUsage(stdout);
    const cmd = help.commandFromString(name) orelse try exitUnknownCommand(stdout, name);
    try help.printCommandHelp(stdout, cmd);
}

fn exitUnknownCommand(stdout: *std.Io.Writer, name: []const u8) !noreturn {
    std.debug.print("error: unknown command '{s}'\n", .{name});
    try printUsage(stdout);
    try stdout.flush();
    std.process.exit(1);
}

/// Check every revision the source names, and find what a single commit is
/// compared with: its first parent, or the empty tree for a root commit,
/// whose changes are then its whole content. Parsing cannot, since both
/// take running git.
fn resolveSource(arena: std.mem.Allocator, source: *types.DiffSource) !void {
    switch (source.*) {
        .worktree, .index => {},
        .index_against, .worktree_against => |ref| requireRevision(arena, ref.text),
        .range => |range| {
            // An empty side is HEAD, which git reports itself if it is unborn.
            if (range.from.len > 0) requireRevision(arena, range.from);
            if (range.to.len > 0) requireRevision(arena, range.to);
        },
        .rev => |*rev| {
            requireRevision(arena, rev.ref.text);
            rev.base = if (git.refHasParent(arena, rev.ref.text))
                try std.fmt.allocPrint(arena, "{s}^", .{rev.ref.text})
            else
                try git.runGitEmptyTree(arena);
        },
    }
}

/// Exit naming `rev` as typed, in git's own words, if it resolves to nothing
/// git can diff.
fn requireRevision(arena: std.mem.Allocator, rev: []const u8) void {
    if (git.revisionExists(arena, rev)) return;
    fatal("bad revision '{s}'", .{rev});
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
