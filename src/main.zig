const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const args_mod = @import("args.zig");
const commands = @import("commands.zig");
const help = @import("help.zig");

// Import modules to ensure their tests are discovered by `zig build test`
comptime {
    _ = @import("diff.zig");
    _ = @import("format.zig");
    _ = @import("git.zig");
    _ = @import("help.zig");
    _ = @import("patch.zig");
    _ = @import("stash.zig");
}

const fatal = types.fatal;

pub fn main() void {
    run() catch |err| {
        fatal("{s}", .{@errorName(err)});
    };
}

fn run() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const process_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, process_args);

    if (process_args.len < 2) {
        try printUsage(stdout);
        try stdout.flush();
        std.process.exit(1);
    }

    const subcmd = process_args[1];

    if (std.mem.eql(u8, subcmd, "list")) {
        const opts = args_mod.parseListArgs(process_args[2..]) catch |err|
            handleParseError(stdout, err, .list);
        try commands.cmdList(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        var opts = args_mod.parseAddResetArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .add);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdAdd(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "reset")) {
        var opts = args_mod.parseAddResetArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .reset);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdReset(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "count")) {
        const opts = args_mod.parseCountArgs(process_args[2..]) catch |err|
            handleParseError(stdout, err, .count);
        try commands.cmdCount(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "check")) {
        var opts = args_mod.parseCheckArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .check);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdCheck(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "discard")) {
        var opts = args_mod.parseDiscardArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .discard);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdDiscard(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "show")) {
        var opts = args_mod.parseShowArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .show);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdShow(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "stash")) {
        var opts = args_mod.parseStashArgs(allocator, process_args[2..]) catch |err|
            handleParseError(stdout, err, .stash);
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdStash(allocator, stdout, opts);
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
    try stdout.print(
        \\
        \\usage: git-hunk <command> [options] [args]
        \\
        \\commands:
        \\  list      List diff hunks with content hashes
        \\  show      Show diff content of specific hunks
        \\  add       Stage hunks (or selected lines) by hash
        \\  reset     Unstage hunks (or selected lines) by hash
        \\  discard   Discard unstaged worktree changes by hash
        \\  count     Count diff hunks (bare integer output)
        \\  check     Validate hunk hashes exist in current diff
        \\  stash     Stash hunks into git stash, remove from worktree
        \\
        \\common options:
        \\  -U, --unified <n> Lines of diff context (default: git's diff.context or 3)
        \\  --file <path>     Restrict to hunks in a specific file
        \\  --tracked-only    Only include hunks from tracked files
        \\  --untracked-only  Only include hunks from untracked files
        \\  --porcelain       Machine-readable tab-separated output
        \\  --no-color        Disable colored output
        \\  --help, -h        Show help for a command
        \\
        \\examples:
        \\  git-hunk list                       List unstaged hunks
        \\  git-hunk add a3f7c21                Stage a hunk by hash
        \\  git-hunk add a3f7:3-5,8             Stage specific lines from a hunk
        \\  git-hunk add --all                  Stage all unstaged hunks
        \\  git-hunk list --staged --oneline    Verify what's staged
        \\
        \\Run 'git-hunk <command> --help' for detailed usage of each command.
        \\
        \\note: 'git hunk --help' opens the man page. Use 'git hunk help [command]'
        \\for inline help when using the git subcommand form.
        \\
    , .{});
}
