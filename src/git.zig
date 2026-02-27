const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const DiffMode = types.DiffMode;
const fatal = types.fatal;

pub fn runGitDiff(allocator: Allocator, mode: DiffMode, context: ?u32) ![]u8 {
    return runGitDiffFiles(allocator, mode, context, &.{});
}

/// Like runGitDiff but scoped to specific file paths via `-- file1 file2 ...`.
/// Pass an empty slice for no file filter (equivalent to runGitDiff).
pub fn runGitDiffFiles(allocator: Allocator, mode: DiffMode, context: ?u32, file_paths: []const []const u8) ![]u8 {
    // Base args: git diff [--cached] [-U<n>] --src-prefix=a/ --dst-prefix=b/ --no-color [-- file1 ...]
    const max_args = 8 + 1 + file_paths.len; // 8 base + "--" separator + file paths
    const argv_buf = try allocator.alloc([]const u8, max_args);
    defer allocator.free(argv_buf);
    var argc: usize = 0;
    argv_buf[argc] = "git";
    argc += 1;
    argv_buf[argc] = "diff";
    argc += 1;
    if (mode == .staged) {
        argv_buf[argc] = "--cached";
        argc += 1;
    }
    if (context) |ctx| {
        var context_buf: [16]u8 = undefined;
        argv_buf[argc] = std.fmt.bufPrint(&context_buf, "-U{d}", .{ctx}) catch "-U0";
        argc += 1;
    }
    argv_buf[argc] = "--src-prefix=a/";
    argc += 1;
    argv_buf[argc] = "--dst-prefix=b/";
    argc += 1;
    argv_buf[argc] = "--no-color";
    argc += 1;
    if (file_paths.len > 0) {
        argv_buf[argc] = "--";
        argc += 1;
        for (file_paths) |fp| {
            argv_buf[argc] = fp;
            argc += 1;
        }
    }
    const argv: []const []const u8 = argv_buf[0..argc];

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var child_stdout: std.ArrayList(u8) = .empty;
    errdefer child_stdout.deinit(allocator);
    var child_stderr: std.ArrayList(u8) = .empty;
    defer child_stderr.deinit(allocator);

    const max_bytes = 10 * 1024 * 1024; // 10 MB
    child.collectOutput(allocator, &child_stdout, &child_stderr, max_bytes) catch |err| {
        if (err == error.StreamTooLong) {
            std.debug.print("error: diff output exceeds 10 MB -- use --file to narrow scope\n", .{});
            std.process.exit(1);
        }
        return err;
    };
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                if (child_stderr.items.len > 0) {
                    std.debug.print("{s}", .{child_stderr.items});
                }
                fatal("git diff exited with code {d}", .{code});
            }
        },
        else => fatal("git diff terminated abnormally", .{}),
    }

    return try child_stdout.toOwnedSlice(allocator);
}

pub const ApplyTarget = enum { index, worktree };

pub fn runGitApply(allocator: Allocator, patch: []const u8, reverse: bool, target: ApplyTarget, check_only: bool) !void {
    var argv_buf: [7][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "git";
    argc += 1;
    argv_buf[argc] = "apply";
    argc += 1;
    if (target == .index) {
        argv_buf[argc] = "--cached";
        argc += 1;
    }
    if (reverse) {
        argv_buf[argc] = "--reverse";
        argc += 1;
    }
    argv_buf[argc] = "--unidiff-zero";
    argc += 1;
    if (check_only) {
        argv_buf[argc] = "--check";
        argc += 1;
    }
    const argv: []const []const u8 = argv_buf[0..argc];

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Write patch to stdin, then close
    const stdin_file = child.stdin.?;
    stdin_file.writeAll(patch) catch {};
    stdin_file.close();
    child.stdin = null;

    var child_stdout: std.ArrayList(u8) = .empty;
    defer child_stdout.deinit(allocator);
    var child_stderr: std.ArrayList(u8) = .empty;
    defer child_stderr.deinit(allocator);

    const max_bytes = 1 * 1024 * 1024;
    try child.collectOutput(allocator, &child_stdout, &child_stderr, max_bytes);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                if (child_stderr.items.len > 0) {
                    std.debug.print("{s}", .{child_stderr.items});
                }
                std.debug.print("error: patch did not apply cleanly — re-run 'list' and try again\n", .{});
                std.process.exit(1);
            }
        },
        else => fatal("git apply terminated abnormally", .{}),
    }
}

pub fn countUntrackedFiles(allocator: Allocator) !u32 {
    const argv: []const []const u8 = &.{ "git", "ls-files", "--others", "--exclude-standard" };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var child_stdout: std.ArrayList(u8) = .empty;
    defer child_stdout.deinit(allocator);
    var child_stderr: std.ArrayList(u8) = .empty;
    defer child_stderr.deinit(allocator);

    const max_bytes = 1 * 1024 * 1024; // 1 MB
    try child.collectOutput(allocator, &child_stdout, &child_stderr, max_bytes);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) return 0; // Best-effort: silently ignore errors
        },
        else => return 0,
    }

    const output = std.mem.trimRight(u8, child_stdout.items, "\n");
    if (output.len == 0) return 0;

    var count: u32 = 1;
    for (output) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}
