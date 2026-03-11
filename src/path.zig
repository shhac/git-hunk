const std = @import("std");
const posix = std.posix;
const git = @import("git.zig");

const Allocator = std.mem.Allocator;

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

    // Resolve symlinks (e.g., /tmp → /private/tmp on macOS)
    var toplevel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const toplevel = posix.realpath(toplevel_raw, &toplevel_buf) catch toplevel_raw;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.realpath(".", &cwd_buf) catch return try allocator.dupe(u8, "");

    if (std.mem.eql(u8, cwd, toplevel)) {
        return try allocator.dupe(u8, "");
    }

    if (cwd.len > toplevel.len and cwd[toplevel.len] == '/' and std.mem.startsWith(u8, cwd, toplevel)) {
        const prefix = try allocator.dupe(u8, cwd[toplevel.len + 1 ..]);
        try posix.chdir(toplevel);
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
