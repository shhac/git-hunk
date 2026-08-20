//! Mapping applied hunks onto their post-apply result hashes.
//!
//! `add`/`reset` re-diff the target side after applying a patch, then have to
//! explain what happened: which input hunk became which result hash, and which
//! pre-existing target hunks were absorbed when adjacent regions merged. That
//! bookkeeping is pure set arithmetic over two hunk snapshots, independent of
//! how the patch was applied, so it lives here rather than in the command flow.

const std = @import("std");
const types = @import("types.zig");
const format = @import("format.zig");

const Allocator = std.mem.Allocator;
const Hunk = types.Hunk;
const MatchedHunk = types.MatchedHunk;
const rangesOverlap = types.rangesOverlap;

/// An applied input hunk (what the user asked to stage/unstage).
pub const AppliedInput = struct {
    sha7: []const u8,
    line_spec: ?types.LineSpec,
};

/// A result group represents one output line: the set of applied + consumed
/// input hunks that combined into one (or more) result hunks on the target side.
pub const ResultGroup = struct {
    /// 7-char result hash(es) on the target side. Usually length 1.
    /// Multiple when a line-spec operation splits into several output hunks.
    /// Empty if no result could be resolved.
    result_shas: []const []const u8,
    /// Input hunks the user asked to stage/unstage.
    applied: []const AppliedInput,
    /// 7-char hashes of pre-existing target-side hunks absorbed into the result.
    consumed: []const []const u8,
    /// File path.
    file_path: []const u8,
    /// Whether this file is a symlink (mode 120000).
    is_symlink: bool,
};

/// Returns pointers to hunks in `minuend` whose `sha_hex` is absent from
/// `subtrahend`. Used to compute "consumed" (old\new) and "created" (new\old).
fn shaSetDifference(arena: Allocator, minuend: []const Hunk, subtrahend: []const Hunk) ![]*const Hunk {
    var list: std.ArrayList(*const Hunk) = .empty;
    outer: for (minuend) |*m| {
        for (subtrahend) |*s| {
            if (std.mem.eql(u8, &m.sha_hex, &s.sha_hex)) continue :outer;
        }
        try list.append(arena, m);
    }
    return list.items;
}

/// Pre-existing target-side hunks absorbed into the result (sha not in new_target).
fn findConsumed(arena: Allocator, old_target: []const Hunk, new_target: []const Hunk) ![]*const Hunk {
    return shaSetDifference(arena, old_target, new_target);
}

/// New target-side hunks that didn't exist before (sha not in old_target).
fn findCreated(arena: Allocator, old_target: []const Hunk, new_target: []const Hunk) ![]*const Hunk {
    return shaSetDifference(arena, new_target, old_target);
}

/// For each created hunk, attribute contributing applied inputs (by content or
/// new-side line overlap) and consumed hunks (by old-side line overlap). Marks
/// `applied_used` / `consumed_used` flags as it goes.
/// Find applied inputs that contributed to `created`. Match by content
/// (line_spec=null + identical diff_lines) first, otherwise by new-side line
/// overlap. Marks `applied_used[i]=true` for each match so a single applied
/// hunk maps to at most one created hunk.
fn collectAppliedFor(
    arena: Allocator,
    matched: []const MatchedHunk,
    applied_used: []bool,
    created: *const Hunk,
) ![]AppliedInput {
    var app_buf: std.ArrayList(AppliedInput) = .empty;
    for (matched, 0..) |m, i| {
        if (applied_used[i]) continue;
        if (!std.mem.eql(u8, m.hunk.file_path, created.file_path)) continue;
        const content_match = m.line_spec == null and
            std.mem.eql(u8, m.hunk.diff_lines, created.diff_lines);
        const line_match = !content_match and rangesOverlap(
            m.hunk.new_start,
            m.hunk.new_count,
            created.new_start,
            created.new_count,
        );
        if (content_match or line_match) {
            try app_buf.append(arena, .{ .sha7 = m.hunk.sha_hex[0..7], .line_spec = m.line_spec });
            applied_used[i] = true;
        }
    }
    return app_buf.items;
}

/// Find consumed hunks whose old-side range overlaps `created`'s old-side
/// range and same file. Marks `consumed_used[i]=true` per match.
fn collectConsumedFor(
    arena: Allocator,
    consumed: []const *const Hunk,
    consumed_used: []bool,
    created: *const Hunk,
) ![][]const u8 {
    var con_buf: std.ArrayList([]const u8) = .empty;
    for (consumed, 0..) |con, i| {
        if (consumed_used[i]) continue;
        if (!std.mem.eql(u8, con.file_path, created.file_path)) continue;
        if (rangesOverlap(con.old_start, con.old_count, created.old_start, created.old_count)) {
            try con_buf.append(arena, con.sha_hex[0..7]);
            consumed_used[i] = true;
        }
    }
    return con_buf.items;
}

fn assignAppliedAndConsumed(
    arena: Allocator,
    matched: []const MatchedHunk,
    consumed: []const *const Hunk,
    created: []const *const Hunk,
    applied_used: []bool,
    consumed_used: []bool,
) ![]ResultGroup {
    var groups: std.ArrayList(ResultGroup) = .empty;
    for (created) |c| {
        const applied = try collectAppliedFor(arena, matched, applied_used, c);
        const con_paths = try collectConsumedFor(arena, consumed, consumed_used, c);
        const result_sha = try arena.alloc([]const u8, 1);
        result_sha[0] = c.sha_hex[0..7];
        try groups.append(arena, .{
            .result_shas = result_sha,
            .applied = applied,
            .consumed = con_paths,
            .file_path = c.file_path,
            .is_symlink = c.is_symlink,
        });
    }
    return groups.items;
}

/// Append unmatched applied hunks as standalone groups with no result_shas.
fn appendOrphanedApplied(
    arena: Allocator,
    groups: *std.ArrayList(ResultGroup),
    matched: []const MatchedHunk,
    applied_used: []const bool,
) !void {
    for (matched, 0..) |m, i| {
        if (applied_used[i]) continue;
        const app = try arena.alloc(AppliedInput, 1);
        app[0] = .{ .sha7 = m.hunk.sha_hex[0..7], .line_spec = m.line_spec };
        try groups.append(arena, .{
            .result_shas = &.{},
            .applied = app,
            .consumed = &.{},
            .file_path = m.hunk.file_path,
            .is_symlink = m.hunk.is_symlink,
        });
    }
}

/// A line-spec operation (e.g. `aaaa:1,10`) can produce multiple result hunks.
/// The applied input matches the first created hunk exclusively, so later
/// created hunks have empty `applied`. Merge these orphans into the sibling
/// group that holds the applied input for the same file.
fn mergeOrphansIntoSiblings(arena: Allocator, groups: []ResultGroup) ![]const ResultGroup {
    var final_groups: std.ArrayList(ResultGroup) = .empty;
    for (groups) |rg| {
        if (rg.applied.len > 0) try final_groups.append(arena, rg);
    }
    for (groups) |orphan| {
        if (orphan.applied.len > 0) continue;
        if (orphan.result_shas.len == 0) continue;

        var merged = false;
        for (final_groups.items) |*target| {
            if (!std.mem.eql(u8, target.file_path, orphan.file_path)) continue;

            const combined_res = try arena.alloc([]const u8, target.result_shas.len + orphan.result_shas.len);
            @memcpy(combined_res[0..target.result_shas.len], target.result_shas);
            @memcpy(combined_res[target.result_shas.len..], orphan.result_shas);
            target.result_shas = combined_res;

            if (orphan.consumed.len > 0) {
                const combined_con = try arena.alloc([]const u8, target.consumed.len + orphan.consumed.len);
                @memcpy(combined_con[0..target.consumed.len], target.consumed);
                @memcpy(combined_con[target.consumed.len..], orphan.consumed);
                target.consumed = combined_con;
            }
            merged = true;
            break;
        }
        // No sibling found — keep as standalone group (shouldn't happen in practice).
        if (!merged) try final_groups.append(arena, orphan);
    }
    return final_groups.items;
}

/// Build result groups by comparing old vs new target-side hunks and matching
/// applied/consumed inputs to created results.
///
/// Algorithm:
///   1. Consumed = old target hunks whose sha is absent from new target
///   2. Created  = new target hunks whose sha is absent from old target
///   3. For each created hunk, attribute contributing applied + consumed
///   4. Unmatched applied hunks get their own group with no result hash
///   5. Merge orphan result-only groups (from line-spec splits) into sibling
///      groups that share a file with an applied input
pub fn buildResultGroups(
    arena: Allocator,
    matched: []const MatchedHunk,
    old_target: []const Hunk,
    new_target: []const Hunk,
) ![]const ResultGroup {
    const consumed = try findConsumed(arena, old_target, new_target);
    const created = try findCreated(arena, old_target, new_target);

    const applied_used = try arena.alloc(bool, matched.len);
    @memset(applied_used, false);
    const consumed_used = try arena.alloc(bool, consumed.len);
    @memset(consumed_used, false);

    var groups: std.ArrayList(ResultGroup) = .empty;
    const initial = try assignAppliedAndConsumed(arena, matched, consumed, created, applied_used, consumed_used);
    try groups.appendSlice(arena, initial);
    try appendOrphanedApplied(arena, &groups, matched, applied_used);

    return try mergeOrphansIntoSiblings(arena, groups.items);
}

/// Print one result group in human-readable format:
///   {verb} {applied...} [+{consumed}...] → {result[,result...]}  {file}
pub fn printResultGroupHuman(stdout: *std.Io.Writer, verb: []const u8, rg: ResultGroup, use_color: bool) !void {
    // Verb
    try stdout.print("{s} ", .{verb});

    // Applied hashes (yellow), space-separated, with optional :line_spec
    for (rg.applied, 0..) |ai, i| {
        if (i > 0) try stdout.print(" ", .{});
        if (use_color) try stdout.print("{s}", .{format.COLOR_YELLOW});
        try stdout.print("{s}", .{ai.sha7});
        if (ai.line_spec) |ls| {
            try stdout.print(":", .{});
            try format.writeLineSpec(stdout, ls);
        }
        if (use_color) try stdout.print("{s}", .{format.COLOR_RESET});
    }

    // Consumed hashes (dim), space-separated, +-prefixed
    for (rg.consumed) |con| {
        if (use_color) {
            try stdout.print(" {s}+{s}{s}", .{ format.COLOR_DIM, con, format.COLOR_RESET });
        } else {
            try stdout.print(" +{s}", .{con});
        }
    }

    // Arrow (always present)
    try stdout.print(" \xe2\x86\x92 ", .{});

    // Result hashes (green), comma-separated
    if (rg.result_shas.len > 0) {
        for (rg.result_shas, 0..) |rs, i| {
            if (i > 0) try stdout.print(",", .{});
            if (use_color) try stdout.print("{s}", .{format.COLOR_GREEN});
            try stdout.print("{s}", .{rs});
            if (use_color) try stdout.print("{s}", .{format.COLOR_RESET});
        }
    } else {
        try stdout.print("?", .{});
    }

    // File path (two spaces before file)
    try stdout.writeAll("  ");
    try stdout.writeAll(rg.file_path);
    if (rg.is_symlink) try stdout.writeByte('@');
    try stdout.writeByte('\n');
}

/// Print one result group in porcelain (tab-separated) format:
///   {verb}\t{applied}\t{result}\t{file}[\t{consumed}]
pub fn printResultGroupPorcelain(stdout: *std.Io.Writer, verb: []const u8, rg: ResultGroup) !void {
    // verb
    try stdout.print("{s}\t", .{verb});

    // applied: space-separated with optional :line_spec
    for (rg.applied, 0..) |ai, i| {
        if (i > 0) try stdout.print(" ", .{});
        try stdout.print("{s}", .{ai.sha7});
        if (ai.line_spec) |ls| {
            try stdout.print(":", .{});
            try format.writeLineSpec(stdout, ls);
        }
    }

    // result: comma-separated
    try stdout.print("\t", .{});
    for (rg.result_shas, 0..) |rs, i| {
        if (i > 0) try stdout.print(",", .{});
        try stdout.print("{s}", .{rs});
    }

    // file
    try stdout.writeByte('\t');
    try stdout.writeAll(rg.file_path);
    if (rg.is_symlink) try stdout.writeByte('@');

    // consumed: comma-separated (optional field, only if non-empty)
    if (rg.consumed.len > 0) {
        try stdout.print("\t", .{});
        for (rg.consumed, 0..) |con, i| {
            if (i > 0) try stdout.print(",", .{});
            try stdout.print("{s}", .{con});
        }
    }

    try stdout.print("\n", .{});
}

// ============================================================================
// Tests
// ============================================================================

test "buildResultGroups simple 1-to-1 mapping" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Applied hunk (from unstaged diff)
    var applied_hunk = types.testMakeHunk("src/main.zig", 10, 3, 10, 5);
    applied_hunk.diff_lines = "+new line\n-old line";
    applied_hunk.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "aaaaaaa");
        @memset(h[7..], '0');
        break :blk h;
    };

    // Result hunk (from staged diff after apply) — same content, different hash
    var result_hunk = types.testMakeHunk("src/main.zig", 10, 3, 10, 5);
    result_hunk.diff_lines = "+new line\n-old line";
    result_hunk.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "yyyyyyy");
        @memset(h[7..], '0');
        break :blk h;
    };

    const matched = [_]MatchedHunk{.{ .hunk = &applied_hunk, .line_spec = null }};
    const old_target = [_]Hunk{}; // no pre-existing staged hunks
    const new_target = [_]Hunk{result_hunk};

    const groups = try buildResultGroups(arena, &matched, &old_target, &new_target);

    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].applied.len);
    try std.testing.expectEqual(@as(usize, 0), groups[0].consumed.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].result_shas.len);
    try std.testing.expectEqualStrings("aaaaaaa", groups[0].applied[0].sha7);
    try std.testing.expectEqualStrings("yyyyyyy", groups[0].result_shas[0]);
    try std.testing.expectEqualStrings("src/main.zig", groups[0].file_path);
}

test "buildResultGroups merge with existing staged hunk" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Applied hunk: unstaged change at lines 10-12 in worktree
    var applied_hunk = types.testMakeHunk("src/main.zig", 10, 2, 10, 3);
    applied_hunk.diff_lines = "+applied line";
    applied_hunk.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "aaaaaaa");
        @memset(h[7..], '0');
        break :blk h;
    };

    // Pre-existing staged hunk: HEAD lines 8-15
    var old_staged = types.testMakeHunk("src/main.zig", 8, 8, 8, 10);
    old_staged.diff_lines = "+old staged line";
    old_staged.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "xxxxxxx");
        @memset(h[7..], '0');
        break :blk h;
    };

    // Combined result: HEAD lines 8-15 (overlaps with old_staged on HEAD side)
    var result_hunk = types.testMakeHunk("src/main.zig", 8, 8, 8, 12);
    result_hunk.diff_lines = "+combined result";
    result_hunk.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "zzzzzzz");
        @memset(h[7..], '0');
        break :blk h;
    };

    const matched = [_]MatchedHunk{.{ .hunk = &applied_hunk, .line_spec = null }};
    const old_target = [_]Hunk{old_staged};
    const new_target = [_]Hunk{result_hunk}; // old_staged is gone, result_hunk is new

    const groups = try buildResultGroups(arena, &matched, &old_target, &new_target);

    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].applied.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].consumed.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].result_shas.len);
    try std.testing.expectEqualStrings("aaaaaaa", groups[0].applied[0].sha7);
    try std.testing.expectEqualStrings("xxxxxxx", groups[0].consumed[0]);
    try std.testing.expectEqualStrings("zzzzzzz", groups[0].result_shas[0]);
}

test "buildResultGroups batch no interaction produces separate groups" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two applied hunks in different files
    var hunk_a = types.testMakeHunk("a.zig", 1, 3, 1, 5);
    hunk_a.diff_lines = "+aaa";
    hunk_a.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "aaaaaaa");
        @memset(h[7..], '0');
        break :blk h;
    };
    var hunk_b = types.testMakeHunk("b.zig", 1, 3, 1, 5);
    hunk_b.diff_lines = "+bbb";
    hunk_b.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "bbbbbbb");
        @memset(h[7..], '0');
        break :blk h;
    };

    // Results: one per file, matching content
    var res_a = types.testMakeHunk("a.zig", 1, 3, 1, 5);
    res_a.diff_lines = "+aaa";
    res_a.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "xxxxxxx");
        @memset(h[7..], '0');
        break :blk h;
    };
    var res_b = types.testMakeHunk("b.zig", 1, 3, 1, 5);
    res_b.diff_lines = "+bbb";
    res_b.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "yyyyyyy");
        @memset(h[7..], '0');
        break :blk h;
    };

    const matched = [_]MatchedHunk{
        .{ .hunk = &hunk_a, .line_spec = null },
        .{ .hunk = &hunk_b, .line_spec = null },
    };
    const old_target = [_]Hunk{};
    const new_target = [_]Hunk{ res_a, res_b };

    const groups = try buildResultGroups(arena, &matched, &old_target, &new_target);

    try std.testing.expectEqual(@as(usize, 2), groups.len);
    // Each group has 1 applied, 0 consumed, 1 result
    try std.testing.expectEqual(@as(usize, 1), groups[0].applied.len);
    try std.testing.expectEqual(@as(usize, 0), groups[0].consumed.len);
    try std.testing.expectEqual(@as(usize, 1), groups[1].applied.len);
    try std.testing.expectEqual(@as(usize, 0), groups[1].consumed.len);
}

test "buildResultGroups line-spec multi-output merges into one group" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Applied hunk with a line_spec, covering a wide range (lines 1-20 in worktree)
    var applied_hunk = types.testMakeHunk("src/main.zig", 1, 15, 1, 20);
    applied_hunk.diff_lines = "+big change spanning many lines";
    applied_hunk.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "aaaaaaa");
        @memset(h[7..], '0');
        break :blk h;
    };

    // Line spec selects non-contiguous lines (1 and 10), producing two result hunks
    const ranges = [_]types.LineRange{
        .{ .start = 1, .end = 1 },
        .{ .start = 10, .end = 10 },
    };
    const line_spec = types.LineSpec{ .ranges = &ranges };

    // Two created result hunks at different positions in the same file
    var result_1 = types.testMakeHunk("src/main.zig", 1, 1, 1, 2);
    result_1.diff_lines = "+line at top";
    result_1.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "yyyyyyy");
        @memset(h[7..], '0');
        break :blk h;
    };
    var result_2 = types.testMakeHunk("src/main.zig", 10, 1, 10, 2);
    result_2.diff_lines = "+line at bottom";
    result_2.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "zzzzzzz");
        @memset(h[7..], '0');
        break :blk h;
    };

    const matched = [_]MatchedHunk{.{ .hunk = &applied_hunk, .line_spec = line_spec }};
    const old_target = [_]Hunk{};
    const new_target = [_]Hunk{ result_1, result_2 };

    const groups = try buildResultGroups(arena, &matched, &old_target, &new_target);

    // Should be merged into 1 group with 2 result hashes
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].applied.len);
    try std.testing.expectEqual(@as(usize, 2), groups[0].result_shas.len);
    try std.testing.expectEqual(@as(usize, 0), groups[0].consumed.len);
    try std.testing.expectEqualStrings("aaaaaaa", groups[0].applied[0].sha7);
    try std.testing.expectEqualStrings("yyyyyyy", groups[0].result_shas[0]);
    try std.testing.expectEqualStrings("zzzzzzz", groups[0].result_shas[1]);
    try std.testing.expect(groups[0].applied[0].line_spec != null);
}

test "buildResultGroups orphan with no sibling becomes standalone" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No applied hunks — simulates a scenario where a result exists with no matching applied input
    const matched = [_]MatchedHunk{};
    const old_target = [_]Hunk{};

    // One result hunk with no applied hunk to match
    var orphan_result = types.testMakeHunk("orphan.zig", 1, 1, 1, 2);
    orphan_result.diff_lines = "+orphaned";
    orphan_result.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "ooooooo");
        @memset(h[7..], '0');
        break :blk h;
    };
    const new_target = [_]Hunk{orphan_result};

    const groups = try buildResultGroups(arena, &matched, &old_target, &new_target);

    // Orphan with no sibling file becomes a standalone group
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 0), groups[0].applied.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].result_shas.len);
    try std.testing.expectEqualStrings("ooooooo", groups[0].result_shas[0]);
}

test "findConsumed returns hunks whose sha is absent from new_target" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h_old1 = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    h_old1.sha_hex = comptime [_]u8{'a'} ** 40;
    var h_old2 = types.testMakeHunk("a.txt", 5, 1, 5, 1);
    h_old2.sha_hex = comptime [_]u8{'b'} ** 40;
    var h_new = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    h_new.sha_hex = comptime [_]u8{'a'} ** 40; // h_old1 survives, h_old2 consumed

    const consumed = try findConsumed(arena, &.{ h_old1, h_old2 }, &.{h_new});
    try std.testing.expectEqual(@as(usize, 1), consumed.len);
    try std.testing.expectEqualSlices(u8, &h_old2.sha_hex, &consumed[0].sha_hex);
}

test "findConsumed returns empty when all hunks survive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    h.sha_hex = comptime [_]u8{'a'} ** 40;
    const consumed = try findConsumed(arena, &.{h}, &.{h});
    try std.testing.expectEqual(@as(usize, 0), consumed.len);
}

test "findCreated returns hunks whose sha is absent from old_target" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h_old = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    h_old.sha_hex = comptime [_]u8{'a'} ** 40;
    var h_new1 = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    h_new1.sha_hex = comptime [_]u8{'a'} ** 40; // already existed
    var h_new2 = types.testMakeHunk("a.txt", 5, 1, 5, 1);
    h_new2.sha_hex = comptime [_]u8{'c'} ** 40; // genuinely new

    const created = try findCreated(arena, &.{h_old}, &.{ h_new1, h_new2 });
    try std.testing.expectEqual(@as(usize, 1), created.len);
    try std.testing.expectEqualSlices(u8, &h_new2.sha_hex, &created[0].sha_hex);
}

test "collectAppliedFor: content match takes precedence over line match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    m_hunk.diff_lines = "+identical";
    const matched = [_]MatchedHunk{.{ .hunk = &m_hunk, .line_spec = null }};

    var c_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    c_hunk.diff_lines = "+identical";

    var applied_used = [_]bool{false};
    const applied = try collectAppliedFor(arena, &matched, &applied_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 1), applied.len);
    try std.testing.expect(applied_used[0]);
}

test "collectAppliedFor: line overlap matches when content differs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m_hunk = types.testMakeHunk("a.txt", 5, 3, 5, 3);
    m_hunk.diff_lines = "+different";
    const matched = [_]MatchedHunk{.{ .hunk = &m_hunk, .line_spec = null }};

    var c_hunk = types.testMakeHunk("a.txt", 5, 3, 6, 3);
    c_hunk.diff_lines = "+merged";

    var applied_used = [_]bool{false};
    const applied = try collectAppliedFor(arena, &matched, &applied_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 1), applied.len);
    try std.testing.expect(applied_used[0]);
}

test "collectAppliedFor: applied_used flag prevents double-attribution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    const matched = [_]MatchedHunk{.{ .hunk = &m_hunk, .line_spec = null }};

    var c_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);

    var applied_used = [_]bool{true}; // already attributed
    const applied = try collectAppliedFor(arena, &matched, &applied_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 0), applied.len);
}

test "collectAppliedFor: different file path skips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    const matched = [_]MatchedHunk{.{ .hunk = &m_hunk, .line_spec = null }};

    var c_hunk = types.testMakeHunk("b.txt", 1, 1, 1, 1);

    var applied_used = [_]bool{false};
    const applied = try collectAppliedFor(arena, &matched, &applied_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 0), applied.len);
    try std.testing.expect(!applied_used[0]);
}

test "collectConsumedFor: range overlap on same file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var con_hunk = types.testMakeHunk("a.txt", 5, 3, 5, 3);
    @memcpy(con_hunk.sha_hex[0..7], "deadbef");
    @memset(con_hunk.sha_hex[7..], '0');
    const consumed = [_]*const Hunk{&con_hunk};

    var c_hunk = types.testMakeHunk("a.txt", 5, 3, 5, 3);

    var consumed_used = [_]bool{false};
    const con_paths = try collectConsumedFor(arena, &consumed, &consumed_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 1), con_paths.len);
    try std.testing.expectEqualStrings("deadbef", con_paths[0]);
    try std.testing.expect(consumed_used[0]);
}

test "collectConsumedFor: no overlap returns empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var con_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    const consumed = [_]*const Hunk{&con_hunk};

    var c_hunk = types.testMakeHunk("a.txt", 100, 1, 100, 1);

    var consumed_used = [_]bool{false};
    const con_paths = try collectConsumedFor(arena, &consumed, &consumed_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 0), con_paths.len);
}

test "appendOrphanedApplied: unmatched applied hunks become standalone groups" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h1 = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h1.sha_hex[0..7], "abcdef0");
    @memset(h1.sha_hex[7..], '0');
    var h2 = types.testMakeHunk("b.txt", 1, 1, 1, 1);
    @memcpy(h2.sha_hex[0..7], "1234567");
    @memset(h2.sha_hex[7..], '0');
    const matched = [_]MatchedHunk{
        .{ .hunk = &h1, .line_spec = null },
        .{ .hunk = &h2, .line_spec = null },
    };

    var groups: std.ArrayList(ResultGroup) = .empty;
    const applied_used = [_]bool{ false, true }; // h1 unmatched, h2 already used
    try appendOrphanedApplied(arena, &groups, &matched, &applied_used);

    try std.testing.expectEqual(@as(usize, 1), groups.items.len);
    try std.testing.expectEqualStrings("a.txt", groups.items[0].file_path);
    try std.testing.expectEqual(@as(usize, 0), groups.items[0].result_shas.len);
    try std.testing.expectEqual(@as(usize, 1), groups.items[0].applied.len);
}

test "mergeOrphansIntoSiblings: orphan with sibling for same file gets merged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sibling_apps = try arena.alloc(AppliedInput, 1);
    sibling_apps[0] = .{ .sha7 = "abcdef0", .line_spec = null };
    const sibling_shas = try arena.alloc([]const u8, 1);
    sibling_shas[0] = "result1";

    const orphan_shas = try arena.alloc([]const u8, 1);
    orphan_shas[0] = "result2";

    var groups = [_]ResultGroup{
        .{ .result_shas = sibling_shas, .applied = sibling_apps, .consumed = &.{}, .file_path = "a.txt", .is_symlink = false },
        .{ .result_shas = orphan_shas, .applied = &.{}, .consumed = &.{}, .file_path = "a.txt", .is_symlink = false },
    };

    const final = try mergeOrphansIntoSiblings(arena, &groups);
    try std.testing.expectEqual(@as(usize, 1), final.len);
    try std.testing.expectEqual(@as(usize, 2), final[0].result_shas.len);
}

test "mergeOrphansIntoSiblings: orphan without sibling kept as-is (fallback path)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const orphan_shas = try arena.alloc([]const u8, 1);
    orphan_shas[0] = "stranger";

    var groups = [_]ResultGroup{
        .{ .result_shas = orphan_shas, .applied = &.{}, .consumed = &.{}, .file_path = "lonely.txt", .is_symlink = false },
    };

    const final = try mergeOrphansIntoSiblings(arena, &groups);
    try std.testing.expectEqual(@as(usize, 1), final.len);
    try std.testing.expectEqualStrings("lonely.txt", final[0].file_path);
}

test "printResultGroupHuman: simple 1->1 case (no consumed, no line_spec)" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupHuman(&w, "staged", rg, false);
    try std.testing.expectEqualStrings("staged abcdef0 \xe2\x86\x92 1234567  foo.txt\n", w.buffered());
}

test "printResultGroupHuman: with consumed shows + prefix and `?` when no result" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const consumed = [_][]const u8{"deadbef"};
    const rg = ResultGroup{
        .result_shas = &.{},
        .applied = &applied,
        .consumed = &consumed,
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupHuman(&w, "staged", rg, false);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "+deadbef") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "?") != null);
}

test "printResultGroupHuman: symlink suffix" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "link",
        .is_symlink = true,
    };
    try printResultGroupHuman(&w, "staged", rg, false);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "link@\n"));
}

test "printResultGroupHuman: line_spec on applied input" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ranges = [_]types.LineRange{.{ .start = 3, .end = 5 }};
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = .{ .ranges = &ranges } }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupHuman(&w, "staged", rg, false);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "abcdef0:3-5") != null);
}

test "printResultGroupHuman: multi-applied + multi-result joined correctly" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{
        .{ .sha7 = "aaaa000", .line_spec = null },
        .{ .sha7 = "bbbb000", .line_spec = null },
    };
    const result_shas = [_][]const u8{ "rrrr000", "ssss000" };
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupHuman(&w, "staged", rg, false);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "aaaa000 bbbb000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rrrr000,ssss000") != null);
}

test "printResultGroupPorcelain: tab-separated layout" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupPorcelain(&w, "staged", rg);
    try std.testing.expectEqualStrings("staged\tabcdef0\t1234567\tfoo.txt\n", w.buffered());
}

test "printResultGroupPorcelain: omits consumed field when empty" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupPorcelain(&w, "staged", rg);
    // Only 4 fields when consumed is empty: verb, applied, result, file.
    var tab_count: usize = 0;
    for (w.buffered()) |c| if (c == '\t') {
        tab_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), tab_count);
}

test "printResultGroupPorcelain: appends consumed field when present" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const consumed = [_][]const u8{ "deadbef", "feedabc" };
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &consumed,
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupPorcelain(&w, "staged", rg);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\tdeadbef,feedabc\n"));
}

test "printResultGroupPorcelain: symlink @ suffix on file path" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "link",
        .is_symlink = true,
    };
    try printResultGroupPorcelain(&w, "staged", rg);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\tlink@\n"));
}
