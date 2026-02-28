const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const args_mod = @import("args.zig");
const commands = @import("commands.zig");

// Import modules to ensure their tests are discovered by `zig build test`
comptime {
    _ = @import("diff.zig");
    _ = @import("format.zig");
    _ = @import("git.zig");
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
        const opts = args_mod.parseListArgs(process_args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        try commands.cmdList(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        var opts = args_mod.parseAddRemoveArgs(allocator, process_args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdAdd(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        var opts = args_mod.parseAddRemoveArgs(allocator, process_args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdRemove(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "count")) {
        const opts = args_mod.parseCountArgs(process_args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        try commands.cmdCount(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "check")) {
        var opts = args_mod.parseCheckArgs(allocator, process_args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdCheck(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "discard")) {
        var opts = args_mod.parseDiscardArgs(allocator, process_args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdDiscard(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "show")) {
        var opts = args_mod.parseShowArgs(allocator, process_args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdShow(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "stash")) {
        var opts = args_mod.parseStashArgs(allocator, process_args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        defer args_mod.deinitShaArgs(allocator, &opts.sha_args);
        try commands.cmdStash(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "-V")) {
        try stdout.print("git-hunk {s}\n", .{build_options.version});
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "help")) {
        try printUsage(stdout);
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{subcmd});
        try printUsage(stdout);
        try stdout.flush();
        std.process.exit(1);
    }
    try stdout.flush();
}

fn printUsage(stdout: *std.Io.Writer) !void {
    try stdout.print("git-hunk {s}\n", .{build_options.version});
    try stdout.print(
        \\
        \\usage: git-hunk <command> [<args>]
        \\
        \\commands:
        \\  list [--staged] [--file <path>] [--porcelain] [--oneline] [--no-color] [--context <n>]
        \\                                                List diff hunks
        \\  show <sha[:lines]>... [--staged] [--file <path>] [--porcelain] [--no-color] [--context <n>]
        \\                                                Show diff content of hunks
        \\  add [--all] [--file <path>] [--porcelain] [--no-color] [--context <n>] [<sha[:lines]>...]
        \\                                                Stage hunks (or selected lines)
        \\  remove [--all] [--file <path>] [--porcelain] [--no-color] [--context <n>] [<sha[:lines]>...]
        \\                                                Unstage hunks (or selected lines)
        \\  discard [--all] [--file <path>] [--dry-run] [--porcelain] [--no-color] [--context <n>] [<sha[:lines]>...]
        \\                                                Discard unstaged worktree changes
        \\  count [--staged] [--file <path>] [--context <n>]
        \\                                                Count diff hunks
        \\  check [--staged] [--exclusive] [--file <path>] [--porcelain] [--no-color] [--context <n>] <sha>...
        \\                                                Validate hunk hashes exist
        \\  stash [--all] [--file <path>] [-m <msg>] [--pop] [--porcelain] [--no-color] [--context <n>] [<sha>...]
        \\                                                Stash hunks, remove from worktree
        \\
        \\options:
        \\  --context <n>  Lines of diff context (default: git's diff.context or 3)
        \\
        \\line selection:
        \\  <sha>:3-5,8    Stage only specific lines from a hunk (1-based, hunk-relative)
        \\
    , .{});
}
