//! `check`'s verdicts: which hashes still resolve, which are stale or
//! ambiguous, and (with --exclusive) which hunks no hash accounted for. The
//! summary is plain data so it can be rendered either way and unit-tested
//! without git. `cmdCheck` itself stays in commands.zig with the other
//! subcommand entry points.

const std = @import("std");
const types = @import("types.zig");
const patch_mod = @import("patch.zig");
const format = @import("format.zig");

const Allocator = std.mem.Allocator;
const Hunk = types.Hunk;

pub const CheckStatus = enum { ok, stale, ambiguous };

pub const CheckResult = struct {
    prefix: []const u8,
    status: CheckStatus,
    resolved_sha7: []const u8,
    file_path: []const u8,
};

pub const CheckSummary = struct {
    results: []const CheckResult,
    unexpected: []const *const Hunk,
    has_failure: bool,
};

/// Resolve each unique SHA prefix against `hunks` and (if `exclusive`) collect
/// hunks that no provided prefix matched. Returns a pure data summary.
pub fn runChecks(
    arena: Allocator,
    hunks: []const Hunk,
    sha_args: []const types.ShaArg,
    file_filter: []const []const u8,
    exclusive: bool,
) !CheckSummary {
    var unique_prefixes: std.ArrayList([]const u8) = .empty;
    for (sha_args) |sha_arg| {
        for (unique_prefixes.items) |p| {
            if (std.mem.eql(u8, p, sha_arg.prefix)) break;
        } else try unique_prefixes.append(arena, sha_arg.prefix);
    }

    var results: std.ArrayList(CheckResult) = .empty;
    var matched_sha_hexes: std.ArrayList(*const [40]u8) = .empty;
    var has_failure = false;

    for (unique_prefixes.items) |prefix| {
        if (patch_mod.findHunkByShaPrefix(hunks, prefix, file_filter)) |hunk| {
            try results.append(arena, .{
                .prefix = prefix,
                .status = .ok,
                .resolved_sha7 = hunk.sha_hex[0..7],
                .file_path = hunk.file_path,
            });
            try matched_sha_hexes.append(arena, &hunk.sha_hex);
        } else |err| {
            const status: CheckStatus = switch (err) {
                error.NotFound => .stale,
                error.AmbiguousPrefix => .ambiguous,
            };
            try results.append(arena, .{
                .prefix = prefix,
                .status = status,
                .resolved_sha7 = "",
                .file_path = "",
            });
            has_failure = true;
        }
    }

    var unexpected: std.ArrayList(*const Hunk) = .empty;
    if (exclusive) {
        for (hunks) |*h| {
            if (!types.matchesFileFilter(h.file_path, file_filter)) continue;
            for (matched_sha_hexes.items) |sha_ptr| {
                if (std.mem.eql(u8, &h.sha_hex, sha_ptr)) break;
            } else {
                try unexpected.append(arena, h);
                has_failure = true;
            }
        }
    }

    return .{ .results = results.items, .unexpected = unexpected.items, .has_failure = has_failure };
}

/// Render a check summary in tab-separated porcelain form (every entry, success or failure).
pub fn renderCheckPorcelain(stdout: *std.Io.Writer, summary: CheckSummary) !void {
    for (summary.results) |r| {
        switch (r.status) {
            .ok => try stdout.print("ok\t{s}\t{s}\t{s}\n", .{ r.prefix, r.resolved_sha7, r.file_path }),
            .stale => try stdout.print("stale\t{s}\n", .{r.prefix}),
            .ambiguous => try stdout.print("ambiguous\t{s}\n", .{r.prefix}),
        }
    }
    for (summary.unexpected) |h| {
        try stdout.print("unexpected\t{s}\t", .{h.sha_hex[0..7]});
        try format.writeFilePath(stdout, h.*);
        try stdout.writeByte('\n');
    }
}

/// Render a check summary in human form (failures only, with stderr summary line).
pub fn renderCheckHuman(stdout: *std.Io.Writer, summary: CheckSummary, use_color: bool) !void {
    if (!summary.has_failure) return;
    const sha = format.paint(use_color, format.COLOR_YELLOW);
    for (summary.results) |r| {
        switch (r.status) {
            .ok => {},
            .stale => try stdout.print("stale {s}{s}{s}\n", .{ sha.on, r.prefix, sha.off }),
            .ambiguous => try stdout.print("ambiguous {s}{s}{s}\n", .{ sha.on, r.prefix, sha.off }),
        }
    }
    for (summary.unexpected) |h| {
        try stdout.print("unexpected {s}{s}{s}  ", .{ sha.on, h.sha_hex[0..7], sha.off });
        try format.writeFilePath(stdout, h.*);
        try stdout.writeByte('\n');
    }

    var fail_count: usize = 0;
    for (summary.results) |r| {
        if (r.status != .ok) fail_count += 1;
    }
    const unexpected_count = summary.unexpected.len;
    if (fail_count > 0 and unexpected_count > 0) {
        std.debug.print("{d} of {d} hashes failed, {d} unexpected hunk{s}\n", .{
            fail_count,
            summary.results.len,
            unexpected_count,
            @as([]const u8, if (unexpected_count == 1) "" else "s"),
        });
    } else if (fail_count > 0) {
        std.debug.print("{d} of {d} hashes failed\n", .{ fail_count, summary.results.len });
    } else if (unexpected_count > 0) {
        std.debug.print("exclusive check failed: {d} unexpected hunk{s}\n", .{
            unexpected_count,
            @as([]const u8, if (unexpected_count == 1) "" else "s"),
        });
    }
}

// ============================================================================
// Tests
// ============================================================================

test "runChecks: ok status for matching SHA" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h.sha_hex[0..7], "1234567");
    @memset(h.sha_hex[7..], '0');

    const sha_args = [_]types.ShaArg{.{ .prefix = "1234567", .line_spec = null }};
    const summary = try runChecks(arena, &.{h}, &sha_args, &.{}, false);
    try std.testing.expectEqual(@as(usize, 1), summary.results.len);
    try std.testing.expectEqual(CheckStatus.ok, summary.results[0].status);
    try std.testing.expect(!summary.has_failure);
}

test "runChecks: stale status for missing SHA" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sha_args = [_]types.ShaArg{.{ .prefix = "deadbeef", .line_spec = null }};
    const summary = try runChecks(arena, &.{}, &sha_args, &.{}, false);
    try std.testing.expectEqual(@as(usize, 1), summary.results.len);
    try std.testing.expectEqual(CheckStatus.stale, summary.results[0].status);
    try std.testing.expect(summary.has_failure);
}

test "runChecks: ambiguous status for prefix matching multiple hunks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h1 = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h1.sha_hex[0..7], "1234567");
    @memset(h1.sha_hex[7..], '0');
    var h2 = types.testMakeHunk("b.txt", 1, 1, 1, 1);
    @memcpy(h2.sha_hex[0..7], "1234567"); // same prefix
    @memset(h2.sha_hex[7..], '1');

    const sha_args = [_]types.ShaArg{.{ .prefix = "1234567", .line_spec = null }};
    const summary = try runChecks(arena, &.{ h1, h2 }, &sha_args, &.{}, false);
    try std.testing.expectEqual(CheckStatus.ambiguous, summary.results[0].status);
    try std.testing.expect(summary.has_failure);
}

test "runChecks: deduplicates repeated prefixes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h.sha_hex[0..7], "1234567");
    @memset(h.sha_hex[7..], '0');

    const sha_args = [_]types.ShaArg{
        .{ .prefix = "1234567", .line_spec = null },
        .{ .prefix = "1234567", .line_spec = null },
    };
    const summary = try runChecks(arena, &.{h}, &sha_args, &.{}, false);
    try std.testing.expectEqual(@as(usize, 1), summary.results.len);
}

test "runChecks: --exclusive populates unexpected for unmatched hunks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h1 = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h1.sha_hex[0..7], "1234567");
    @memset(h1.sha_hex[7..], '0');
    var h2 = types.testMakeHunk("a.txt", 5, 1, 5, 1);
    @memcpy(h2.sha_hex[0..7], "abcdefg");
    @memset(h2.sha_hex[7..], '0');

    const sha_args = [_]types.ShaArg{.{ .prefix = "1234567", .line_spec = null }};
    const summary = try runChecks(arena, &.{ h1, h2 }, &sha_args, &.{}, true);
    try std.testing.expectEqual(@as(usize, 1), summary.unexpected.len);
    try std.testing.expectEqualSlices(u8, &h2.sha_hex, &summary.unexpected[0].sha_hex);
    try std.testing.expect(summary.has_failure);
}

test "runChecks: file_filter scopes both prefix lookup and unexpected scan" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h_a = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h_a.sha_hex[0..7], "1234567");
    @memset(h_a.sha_hex[7..], '0');
    var h_b = types.testMakeHunk("b.txt", 1, 1, 1, 1);
    @memcpy(h_b.sha_hex[0..7], "abcdefg");
    @memset(h_b.sha_hex[7..], '0');

    const filter = [_][]const u8{"a.txt"};
    const summary = try runChecks(arena, &.{ h_a, h_b }, &.{}, &filter, true);
    try std.testing.expectEqual(@as(usize, 1), summary.unexpected.len);
    try std.testing.expectEqualStrings("a.txt", summary.unexpected[0].file_path);
}
