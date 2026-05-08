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
