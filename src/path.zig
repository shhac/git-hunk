const std = @import("std");
const Io = std.Io;
const git = @import("git.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const defaultIo = types.getIo;

/// Resolve a path relative to the original cwd into a repo-relative path.
/// prefix: path components from repo root to original cwd (e.g., "bar/sub")
/// rel_path: user-provided path relative to original cwd
/// Returns repo-relative path. Caller owns the memory.
pub fn resolveToRepoRelative(allocator: Allocator, prefix: []const u8, rel_path: []const u8) ![]const u8 {
    if (prefix.len == 0) return try allocator.dupe(u8, rel_path);

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    // Add prefix components
    var prefix_iter = std.mem.splitScalar(u8, prefix, '/');
    while (prefix_iter.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        try parts.append(allocator, p);
    }

    // Process rel_path components
    var path_iter = std.mem.splitScalar(u8, rel_path, '/');
    while (path_iter.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
        } else {
            try parts.append(allocator, p);
        }
    }

    return try std.mem.join(allocator, "/", parts.items);
}

/// Compute the prefix (relative path from repo root to original cwd) and chdir to the repo root.
/// Returns the prefix string (empty if already at root). Caller owns the memory.
pub fn chdirToRepoRoot(allocator: Allocator) ![]const u8 {
    const toplevel_raw = git.runGitToplevel(allocator) catch return try allocator.dupe(u8, "");
    defer allocator.free(toplevel_raw);

    const io = defaultIo();
    const cwd_dir = Io.Dir.cwd();

    // Resolve symlinks (e.g., /tmp → /private/tmp on macOS)
    var toplevel_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const toplevel: []const u8 = blk: {
        const n = cwd_dir.realPathFile(io, toplevel_raw, &toplevel_buf) catch break :blk toplevel_raw;
        break :blk toplevel_buf[0..n];
    };

    var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_n = std.process.currentPath(io, &cwd_buf) catch return try allocator.dupe(u8, "");
    const cwd = cwd_buf[0..cwd_n];

    if (std.mem.eql(u8, cwd, toplevel)) {
        return try allocator.dupe(u8, "");
    }

    if (cwd.len > toplevel.len and cwd[toplevel.len] == '/' and std.mem.startsWith(u8, cwd, toplevel)) {
        const prefix = try allocator.dupe(u8, cwd[toplevel.len + 1 ..]);
        try std.Io.Threaded.chdir(toplevel);
        return prefix;
    }

    return try allocator.dupe(u8, "");
}

/// `repo_path` as a shell argument naming it from the directory the user ran
/// git-hunk in, `prefix` below the repo root: relative to there, quoted when a
/// shell would split or expand it, and kept from reading as an option. For
/// hints whose command is meant to be pasted as is. Double quotes where they
/// suffice, since hints already wrap the whole command in single quotes.
pub fn shellArgFromCwd(allocator: Allocator, prefix: []const u8, repo_path: []const u8) ![]const u8 {
    var rest = repo_path;
    var ups: usize = 0;
    var components = std.mem.tokenizeScalar(u8, prefix, '/');
    while (components.next()) |c| {
        if (ups == 0 and rest.len > c.len and std.mem.startsWith(u8, rest, c) and rest[c.len] == '/') {
            rest = rest[c.len + 1 ..];
            continue;
        }
        ups += 1;
    }

    var arg: std.ArrayList(u8) = .empty;
    defer arg.deinit(allocator);
    for (0..ups) |_| try arg.appendSlice(allocator, "../");
    if (ups == 0 and std.mem.startsWith(u8, rest, "-")) try arg.appendSlice(allocator, "./");
    try arg.appendSlice(allocator, rest);

    for (arg.items) |c| {
        if (!isShellSafe(c)) break;
    } else return allocator.dupe(u8, arg.items);
    for (arg.items) |c| {
        if (std.mem.indexOfScalar(u8, "$`\\\"!", c) != null) break;
    } else return std.fmt.allocPrint(allocator, "\"{s}\"", .{arg.items});

    var quoted: std.ArrayList(u8) = .empty;
    errdefer quoted.deinit(allocator);
    try quoted.append(allocator, '\'');
    for (arg.items) |c| {
        if (c == '\'') try quoted.appendSlice(allocator, "'\\''") else try quoted.append(allocator, c);
    }
    try quoted.append(allocator, '\'');
    return quoted.toOwnedSlice(allocator);
}

fn isShellSafe(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._-/+@%=:,", c) != null;
}

// ============================================================================
// Tests
// ============================================================================

test "resolveToRepoRelative: empty prefix passes through" {
    const allocator = std.testing.allocator;
    const result = try resolveToRepoRelative(allocator, "", "foo.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo.txt", result);
}

test "resolveToRepoRelative: simple prefix join" {
    const allocator = std.testing.allocator;
    const result = try resolveToRepoRelative(allocator, "bar", "baz.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("bar/baz.txt", result);
}

test "resolveToRepoRelative: parent traversal" {
    const allocator = std.testing.allocator;
    const result = try resolveToRepoRelative(allocator, "bar", "../foo.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo.txt", result);
}

test "resolveToRepoRelative: nested prefix with partial traversal" {
    const allocator = std.testing.allocator;
    const result = try resolveToRepoRelative(allocator, "a/b/c", "../../d.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a/d.txt", result);
}

test "resolveToRepoRelative: prefix with trailing slash" {
    const allocator = std.testing.allocator;
    const result = try resolveToRepoRelative(allocator, "bar/", "baz.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("bar/baz.txt", result);
}

test "resolveToRepoRelative: traversal to root" {
    const allocator = std.testing.allocator;
    const result = try resolveToRepoRelative(allocator, "a/b", "../../root.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("root.txt", result);
}

test "resolveToRepoRelative: dot components ignored" {
    const allocator = std.testing.allocator;
    const result = try resolveToRepoRelative(allocator, "bar", "./baz.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("bar/baz.txt", result);
}

test "resolveToRepoRelative: complex path" {
    const allocator = std.testing.allocator;
    const result = try resolveToRepoRelative(allocator, "src/lib", "../bin/./main.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("src/bin/main.zig", result);
}

test "shellArgFromCwd: names the path from the user's directory" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { prefix: []const u8, path: []const u8, want: []const u8 }{
        .{ .prefix = "", .path = "f.txt", .want = "f.txt" },
        .{ .prefix = "", .path = "src/f.txt", .want = "src/f.txt" },
        .{ .prefix = "src", .path = "src/f.txt", .want = "f.txt" },
        .{ .prefix = "src", .path = "f.txt", .want = "../f.txt" },
        .{ .prefix = "src/lib", .path = "src/bin/main.zig", .want = "../bin/main.zig" },
        .{ .prefix = "src/lib", .path = "srcx/f", .want = "../../srcx/f" },
        .{ .prefix = "", .path = "-rf", .want = "./-rf" },
        .{ .prefix = "", .path = "with space.txt", .want = "\"with space.txt\"" },
        .{ .prefix = "a", .path = "b/it's", .want = "\"../b/it's\"" },
        .{ .prefix = "", .path = "it's $5", .want = "'it'\\''s $5'" },
        .{ .prefix = "", .path = "$HOME", .want = "'$HOME'" },
    };
    for (cases) |case| {
        const got = try shellArgFromCwd(allocator, case.prefix, case.path);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}
