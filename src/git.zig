const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const EnvMap = std.process.EnvMap;
const DiffMode = types.DiffMode;
const fatal = types.fatal;

pub fn runGitDiff(allocator: Allocator, mode: DiffMode, context: ?u32) ![]u8 {
    return runGitDiffFiles(allocator, mode, context, &.{});
}

/// Like runGitDiff but scoped to specific file paths via `-- file1 file2 ...`.
/// Pass an empty slice for no file filter (equivalent to runGitDiff).
pub fn runGitDiffFiles(allocator: Allocator, mode: DiffMode, context: ?u32, file_paths: []const []const u8) ![]u8 {
    // Base args: git diff [--cached] [-U<n>] --src-prefix=a/ --dst-prefix=b/ --no-color [-- file1 ...]
    // Use stack buffer for the common case (no file paths); heap-allocate only when needed.
    var stack_buf: [8][]const u8 = undefined;
    const argv_buf = if (file_paths.len == 0)
        &stack_buf
    else blk: {
        const max_args = 8 + 1 + file_paths.len;
        break :blk try allocator.alloc([]const u8, max_args);
    };
    defer if (file_paths.len > 0) allocator.free(argv_buf);
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
                if (check_only) {
                    std.debug.print("error: patch would not apply cleanly — hashes may be stale\n", .{});
                } else {
                    std.debug.print("error: patch did not apply cleanly — re-run 'list' and try again\n", .{});
                }
                return error.PatchFailed;
            }
        },
        else => {
            std.debug.print("error: git apply terminated abnormally\n", .{});
            return error.PatchFailed;
        },
    }
}

/// Generate diff output for untracked files using `git diff --no-index`.
/// The output matches the standard `git diff` format expected by parseDiff.
/// Only files matching `file_filter` are included (null = all untracked files).
/// Allocates the result with `allocator`; caller must free the returned slice.
pub fn diffUntrackedFiles(allocator: Allocator, file_filter: ?[]const u8) ![]u8 {
    // Get list of untracked file paths
    const ls_argv: []const []const u8 = &.{ "git", "ls-files", "--others", "--exclude-standard" };

    var ls_child = std.process.Child.init(ls_argv, allocator);
    ls_child.stdout_behavior = .Pipe;
    ls_child.stderr_behavior = .Pipe;
    try ls_child.spawn();

    var ls_stdout: std.ArrayList(u8) = .empty;
    defer ls_stdout.deinit(allocator);
    var ls_stderr: std.ArrayList(u8) = .empty;
    defer ls_stderr.deinit(allocator);

    const ls_max = 1 * 1024 * 1024;
    try ls_child.collectOutput(allocator, &ls_stdout, &ls_stderr, ls_max);
    const ls_term = try ls_child.wait();

    switch (ls_term) {
        .Exited => |code| {
            if (code != 0) return try allocator.alloc(u8, 0);
        },
        else => return try allocator.alloc(u8, 0),
    }

    const ls_output = std.mem.trimRight(u8, ls_stdout.items, "\n");
    if (ls_output.len == 0) return try allocator.alloc(u8, 0);

    // Collect diffs for each untracked file
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var iter = std.mem.splitScalar(u8, ls_output, '\n');
    while (iter.next()) |file_path| {
        if (file_path.len == 0) continue;

        // Apply file filter
        if (file_filter) |filter| {
            if (!std.mem.eql(u8, file_path, filter)) continue;
        }

        const diff = diffSingleUntrackedFile(allocator, file_path) catch continue;
        defer allocator.free(diff);

        if (diff.len > 0) {
            try result.appendSlice(allocator, diff);
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Run `git diff --no-index --src-prefix=a/ --dst-prefix=b/ --no-color -- /dev/null <file>`
/// for a single untracked file. Exit code 1 is expected (differences found).
fn diffSingleUntrackedFile(allocator: Allocator, file_path: []const u8) ![]u8 {
    const argv: []const []const u8 = &.{
        "git",             "diff",            "--no-index",
        "--src-prefix=a/", "--dst-prefix=b/", "--no-color",
        "--",              "/dev/null",       file_path,
    };

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
        if (err == error.StreamTooLong) return error.StreamTooLong;
        return err;
    };
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            // Exit code 1 means "differences found" — this is expected for --no-index
            if (code != 0 and code != 1) {
                child_stdout.deinit(allocator);
                return try allocator.alloc(u8, 0);
            }
        },
        else => {
            child_stdout.deinit(allocator);
            return try allocator.alloc(u8, 0);
        },
    }

    return try child_stdout.toOwnedSlice(allocator);
}

// ─── Stash plumbing helpers ───────────────────────────────────────────

/// Run `git rev-parse HEAD^{tree}` and return the trimmed tree SHA.
pub fn runGitRevParseTree(allocator: Allocator) ![]u8 {
    const argv: []const []const u8 = &.{ "git", "rev-parse", "HEAD^{tree}" };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

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
                if (child_stderr.items.len > 0) std.debug.print("{s}", .{child_stderr.items});
                fatal("git rev-parse exited with code {d}", .{code});
            }
        },
        else => fatal("git rev-parse terminated abnormally", .{}),
    }

    return try allocator.dupe(u8, std.mem.trimRight(u8, child_stdout.items, "\n"));
}

/// Run `git rev-parse <ref>` and return the trimmed SHA.
pub fn runGitRevParse(allocator: Allocator, ref: []const u8) ![]u8 {
    const argv: []const []const u8 = &.{ "git", "rev-parse", ref };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

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
                if (child_stderr.items.len > 0) std.debug.print("{s}", .{child_stderr.items});
                fatal("git rev-parse exited with code {d}", .{code});
            }
        },
        else => fatal("git rev-parse terminated abnormally", .{}),
    }

    return try allocator.dupe(u8, std.mem.trimRight(u8, child_stdout.items, "\n"));
}

/// Run `git symbolic-ref --short HEAD` and return the branch name,
/// or null if HEAD is detached (non-zero exit).
pub fn runGitSymbolicRef(allocator: Allocator) !?[]u8 {
    const argv: []const []const u8 = &.{ "git", "symbolic-ref", "--short", "HEAD" };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var child_stdout: std.ArrayList(u8) = .empty;
    defer child_stdout.deinit(allocator);
    var child_stderr: std.ArrayList(u8) = .empty;
    defer child_stderr.deinit(allocator);

    const max_bytes = 1 * 1024 * 1024;
    try child.collectOutput(allocator, &child_stdout, &child_stderr, max_bytes);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }

    return try allocator.dupe(u8, std.mem.trimRight(u8, child_stdout.items, "\n"));
}

/// Run `git log --oneline -1 HEAD` and return the trimmed output.
pub fn runGitLogOneline(allocator: Allocator) ![]u8 {
    const argv: []const []const u8 = &.{ "git", "log", "--oneline", "-1", "HEAD" };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

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
                if (child_stderr.items.len > 0) std.debug.print("{s}", .{child_stderr.items});
                fatal("git log exited with code {d}", .{code});
            }
        },
        else => fatal("git log terminated abnormally", .{}),
    }

    return try allocator.dupe(u8, std.mem.trimRight(u8, child_stdout.items, "\n"));
}

/// Run `git read-tree <sha>` with a custom environment map.
pub fn runGitReadTreeWithEnv(allocator: Allocator, sha: []const u8, env_map: *const EnvMap) !void {
    const argv: []const []const u8 = &.{ "git", "read-tree", sha };

    var child = std.process.Child.init(argv, allocator);
    child.env_map = env_map;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

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
                if (child_stderr.items.len > 0) std.debug.print("{s}", .{child_stderr.items});
                fatal("git read-tree exited with code {d}", .{code});
            }
        },
        else => fatal("git read-tree terminated abnormally", .{}),
    }
}

/// Run `git apply --cached --unidiff-zero` with patch on stdin and custom env.
pub fn runGitApplyWithEnv(allocator: Allocator, patch: []const u8, env_map: *const EnvMap) !void {
    const argv: []const []const u8 = &.{ "git", "apply", "--cached", "--unidiff-zero" };

    var child = std.process.Child.init(argv, allocator);
    child.env_map = env_map;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

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
                if (child_stderr.items.len > 0) std.debug.print("{s}", .{child_stderr.items});
                fatal("git apply exited with code {d}", .{code});
            }
        },
        else => fatal("git apply terminated abnormally", .{}),
    }
}

/// Run `git write-tree` with a custom environment map, return the trimmed tree SHA.
pub fn runGitWriteTreeWithEnv(allocator: Allocator, env_map: *const EnvMap) ![]u8 {
    const argv: []const []const u8 = &.{ "git", "write-tree" };

    var child = std.process.Child.init(argv, allocator);
    child.env_map = env_map;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

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
                if (child_stderr.items.len > 0) std.debug.print("{s}", .{child_stderr.items});
                fatal("git write-tree exited with code {d}", .{code});
            }
        },
        else => fatal("git write-tree terminated abnormally", .{}),
    }

    return try allocator.dupe(u8, std.mem.trimRight(u8, child_stdout.items, "\n"));
}

/// Run `git commit-tree -p <p1> [-p <p2>] -m <msg> <tree>` and return the trimmed commit SHA.
pub fn runGitCommitTree(allocator: Allocator, tree_sha: []const u8, parents: []const []const u8, message: []const u8) ![]u8 {
    // Args: "git" "commit-tree" [-p <parent>]... "-m" <message> <tree>
    const arg_count = 5 + 2 * parents.len;
    var stack_buf: [9][]const u8 = undefined; // fits up to 2 parents
    const argv_buf = if (arg_count <= stack_buf.len)
        &stack_buf
    else
        try allocator.alloc([]const u8, arg_count);
    defer if (arg_count > stack_buf.len) allocator.free(argv_buf);

    var argc: usize = 0;
    argv_buf[argc] = "git";
    argc += 1;
    argv_buf[argc] = "commit-tree";
    argc += 1;
    for (parents) |p| {
        argv_buf[argc] = "-p";
        argc += 1;
        argv_buf[argc] = p;
        argc += 1;
    }
    argv_buf[argc] = "-m";
    argc += 1;
    argv_buf[argc] = message;
    argc += 1;
    argv_buf[argc] = tree_sha;
    argc += 1;
    const argv: []const []const u8 = argv_buf[0..argc];

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

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
                if (child_stderr.items.len > 0) std.debug.print("{s}", .{child_stderr.items});
                fatal("git commit-tree exited with code {d}", .{code});
            }
        },
        else => fatal("git commit-tree terminated abnormally", .{}),
    }

    return try allocator.dupe(u8, std.mem.trimRight(u8, child_stdout.items, "\n"));
}

/// Run `git stash store -m <msg> <sha>`.
pub fn runGitStashStore(allocator: Allocator, message: []const u8, commit_sha: []const u8) !void {
    const argv: []const []const u8 = &.{ "git", "stash", "store", "-m", message, commit_sha };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

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
                if (child_stderr.items.len > 0) std.debug.print("{s}", .{child_stderr.items});
                fatal("git stash store exited with code {d}", .{code});
            }
        },
        else => fatal("git stash store terminated abnormally", .{}),
    }
}

/// Run `git stash pop`. On conflict (non-zero exit), print stderr and exit 1.
pub fn runGitStashPop(allocator: Allocator) !void {
    const argv: []const []const u8 = &.{ "git", "stash", "pop" };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

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
                if (child_stderr.items.len > 0) std.debug.print("{s}", .{child_stderr.items});
                std.process.exit(1);
            }
        },
        else => fatal("git stash pop terminated abnormally", .{}),
    }
}

/// Run `git diff HEAD [-U<n>] --src-prefix=a/ --dst-prefix=b/ --no-color [-- files...]`
/// and return the raw diff output.
pub fn runGitDiffHead(allocator: Allocator, context: ?u32, file_paths: []const []const u8) ![]u8 {
    var stack_buf: [8][]const u8 = undefined;
    const argv_buf = if (file_paths.len == 0)
        &stack_buf
    else blk: {
        const max_args = 9 + 1 + file_paths.len;
        break :blk try allocator.alloc([]const u8, max_args);
    };
    defer if (file_paths.len > 0) allocator.free(argv_buf);

    var argc: usize = 0;
    argv_buf[argc] = "git";
    argc += 1;
    argv_buf[argc] = "diff";
    argc += 1;
    argv_buf[argc] = "HEAD";
    argc += 1;
    var context_buf: [16]u8 = undefined;
    if (context) |ctx| {
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
