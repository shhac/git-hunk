const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Hunk = types.Hunk;
const MatchedHunk = types.MatchedHunk;
const LineSpec = types.LineSpec;
const LineRange = types.LineRange;

/// Worktree line range [start, end] inclusive.
const WorktreeRange = struct {
    start: u32,
    end: u32,
};

/// Compute the worktree line range for a hunk.
/// For count=0 (pure deletion), the range is [new_start, new_start].
fn worktreeRange(ns: u32, nc: u32) WorktreeRange {
    return .{
        .start = ns,
        .end = if (nc == 0) ns else ns + nc - 1,
    };
}

/// Check whether two line ranges overlap (treating count=0 as spanning 1 line).
fn rangesOverlap(a_start: u32, a_count: u32, b_start: u32, b_count: u32) bool {
    const a_end = a_start + @max(a_count, 1) - 1;
    const b_end = b_start + @max(b_count, 1) - 1;
    return a_start <= b_end and b_start <= a_end;
}

/// Check if a worktree line position falls within any of the target ranges.
fn inAnyRange(line: u32, ranges: []const WorktreeRange) bool {
    for (ranges) |r| {
        if (line >= r.start and line <= r.end) return true;
    }
    return false;
}

/// Compute the worktree line range covered by only the changed (+/-) lines in a hunk.
/// This excludes context lines, giving the precise range of modifications.
/// Returns null if the hunk has no changed lines (shouldn't happen in practice).
fn changedLinesWorktreeRange(hunk: *const Hunk) ?WorktreeRange {
    var new_line = hunk.new_start;
    var min_pos: ?u32 = null;
    var max_pos: ?u32 = null;

    // Skip @@ header line
    var pos: usize = 0;
    if (std.mem.indexOfScalar(u8, hunk.raw_lines, '\n')) |nl| {
        pos = nl + 1;
    } else {
        return null;
    }

    while (pos < hunk.raw_lines.len) {
        const end = std.mem.indexOfScalarPos(u8, hunk.raw_lines, pos, '\n') orelse hunk.raw_lines.len;
        const line = hunk.raw_lines[pos..end];
        pos = if (end < hunk.raw_lines.len) end + 1 else hunk.raw_lines.len;

        if (line.len == 0) {
            // Empty context line
            new_line += 1;
            continue;
        }

        const first = line[0];
        if (first == ' ') {
            new_line += 1;
        } else if (first == '-') {
            // Removal at current worktree position
            if (min_pos == null or new_line < min_pos.?) min_pos = new_line;
            if (max_pos == null or new_line > max_pos.?) max_pos = new_line;
        } else if (first == '+') {
            // Addition at current worktree position
            if (min_pos == null or new_line < min_pos.?) min_pos = new_line;
            if (max_pos == null or new_line > max_pos.?) max_pos = new_line;
            new_line += 1;
        }
        // '\' lines: skip
    }

    if (min_pos) |mn| {
        return .{ .start = mn, .end = max_pos.? };
    }
    return null;
}

/// Match selected index-relative hunks to HEAD-relative hunks for stash construction.
///
/// For each HEAD hunk, finds overlapping selected index hunks by worktree line range.
/// Returns MatchedHunk entries pointing into `head_hunks` with optional LineSpec
/// for partial overlaps (merged hunk case).
///
/// Iterates over HEAD hunks (not index hunks) so that when multiple index hunks
/// overlap with the same HEAD hunk, the result is naturally deduplicated.
///
/// Fast path: if all selected index hunks have SHA matches in head_hunks (clean
/// index), returns head hunks directly with no line-spec computation.
pub fn matchIndexToHead(
    arena: Allocator,
    selected_idx_hunks: []const *const Hunk,
    head_hunks: []const Hunk,
) ![]const MatchedHunk {
    if (selected_idx_hunks.len == 0) return &.{};

    // Fast path: clean index (all SHAs match)
    if (try tryFastPathShaMatch(arena, selected_idx_hunks, head_hunks)) |matches| {
        return matches;
    }

    // Slow path: match by worktree line overlap.
    var matches: std.ArrayList(MatchedHunk) = .empty;

    for (head_hunks) |*head_h| {
        // Collect all overlapping worktree ranges from selected index hunks
        var target_ranges: std.ArrayList(WorktreeRange) = .empty;

        for (selected_idx_hunks) |idx_h| {
            if (!std.mem.eql(u8, idx_h.file_path, head_h.file_path)) continue;
            if (!rangesOverlap(idx_h.new_start, idx_h.new_count, head_h.new_start, head_h.new_count)) continue;
            // Use only the changed (+/-) line positions, not the full context range.
            // This prevents nearby staged changes from being swept up into the target range.
            const changed_range = changedLinesWorktreeRange(idx_h) orelse
                worktreeRange(idx_h.new_start, idx_h.new_count);
            try target_ranges.append(arena, changed_range);
        }

        if (target_ranges.items.len == 0) continue;

        // Check if any single target range fully contains the HEAD hunk's changed lines.
        // Use changed-lines range (not context range) for precision.
        const head_changed = changedLinesWorktreeRange(head_h) orelse
            worktreeRange(head_h.new_start, head_h.new_count);
        var fully_contained = false;
        for (target_ranges.items) |tr| {
            if (head_changed.start >= tr.start and head_changed.end <= tr.end) {
                fully_contained = true;
                break;
            }
        }

        if (fully_contained) {
            try matches.append(arena, .{ .hunk = head_h, .line_spec = null });
        } else {
            const line_spec = try computeLineSpecForRanges(arena, head_h, target_ranges.items);
            if (line_spec.ranges.len > 0) {
                try matches.append(arena, .{ .hunk = head_h, .line_spec = line_spec });
            }
        }
    }

    return matches.items;
}

/// Try fast-path SHA matching. Returns null if any selected index hunk
/// has no SHA match in head_hunks (dirty index case).
fn tryFastPathShaMatch(
    arena: Allocator,
    selected_idx_hunks: []const *const Hunk,
    head_hunks: []const Hunk,
) !?[]const MatchedHunk {
    for (selected_idx_hunks) |idx_h| {
        var found = false;
        for (head_hunks) |*head_h| {
            if (std.mem.eql(u8, &idx_h.sha_hex, &head_h.sha_hex)) {
                found = true;
                break;
            }
        }
        if (!found) return null;
    }

    // All matched — build result using head hunk pointers
    var matches: std.ArrayList(MatchedHunk) = .empty;
    for (selected_idx_hunks) |idx_h| {
        for (head_hunks) |*head_h| {
            if (std.mem.eql(u8, &idx_h.sha_hex, &head_h.sha_hex)) {
                try matches.append(arena, .{ .hunk = head_h, .line_spec = null });
                break;
            }
        }
    }
    return matches.items;
}

/// Compute a LineSpec that selects only the body lines of `head_hunk` whose
/// worktree position falls within the target range [target_start, target_end].
///
/// Walks the hunk body tracking worktree line position:
/// - Context (` `) and empty lines: advance worktree position, not included in LineSpec
/// - Removal (`-`): check worktree position, DON'T advance (removals don't occupy worktree lines)
/// - Addition (`+`): check worktree position, then advance
/// - `\ No newline`: skip — handled automatically by buildFilteredHunkPatch
pub fn computeLineSpecForOverlap(
    arena: Allocator,
    head_hunk: *const Hunk,
    target_start: u32,
    target_end: u32,
) !LineSpec {
    const ranges = [_]WorktreeRange{.{ .start = target_start, .end = target_end }};
    return computeLineSpecForRanges(arena, head_hunk, &ranges);
}

/// Internal: compute LineSpec checking body lines against multiple target worktree ranges.
fn computeLineSpecForRanges(
    arena: Allocator,
    head_hunk: *const Hunk,
    target_ranges: []const WorktreeRange,
) !LineSpec {
    var new_line = head_hunk.new_start;
    var body_line_num: u32 = 1;
    var result_ranges: std.ArrayList(LineRange) = .empty;

    // Track current contiguous range being built
    var range_start: ?u32 = null;
    var range_end: u32 = 0;

    // Skip @@ header line
    var pos: usize = 0;
    if (std.mem.indexOfScalar(u8, head_hunk.raw_lines, '\n')) |nl| {
        pos = nl + 1;
    } else {
        return .{ .ranges = &.{} };
    }

    while (pos < head_hunk.raw_lines.len) {
        const end = std.mem.indexOfScalarPos(u8, head_hunk.raw_lines, pos, '\n') orelse head_hunk.raw_lines.len;
        const line = head_hunk.raw_lines[pos..end];
        pos = if (end < head_hunk.raw_lines.len) end + 1 else head_hunk.raw_lines.len;

        if (line.len == 0) {
            // Empty context line
            new_line += 1;
            body_line_num += 1;
            continue;
        }

        const first = line[0];
        if (first == ' ') {
            // Context: advances worktree position, not added to LineSpec
            new_line += 1;
            body_line_num += 1;
        } else if (first == '-') {
            // Removal: worktree position is new_line, does NOT advance
            if (inAnyRange(new_line, target_ranges)) {
                if (range_start == null) range_start = body_line_num;
                range_end = body_line_num;
            } else {
                if (range_start) |rs| {
                    try result_ranges.append(arena, .{ .start = rs, .end = range_end });
                    range_start = null;
                }
            }
            body_line_num += 1;
        } else if (first == '+') {
            // Addition: exists in worktree at new_line, then advance
            if (inAnyRange(new_line, target_ranges)) {
                if (range_start == null) range_start = body_line_num;
                range_end = body_line_num;
            } else {
                if (range_start) |rs| {
                    try result_ranges.append(arena, .{ .start = rs, .end = range_end });
                    range_start = null;
                }
            }
            new_line += 1;
            body_line_num += 1;
        } else if (first == '\\') {
            // "\ No newline at end of file"
            // Do NOT increment body_line_num — buildFilteredHunkPatch doesn't
            // count these, and handles them via prev_kept tracking.
        }
    }

    // Flush final range
    if (range_start) |rs| {
        try result_ranges.append(arena, .{ .start = rs, .end = range_end });
    }

    return .{ .ranges = try result_ranges.toOwnedSlice(arena) };
}

// ============================================================================
// Tests
// ============================================================================

const testMakeHunk = types.testMakeHunk;
const computeHunkSha = @import("diff.zig").computeHunkSha;

test "rangesOverlap basic overlap" {
    try std.testing.expect(rangesOverlap(1, 5, 3, 5)); // [1,5] ∩ [3,7]
    try std.testing.expect(rangesOverlap(3, 5, 1, 5)); // symmetric
}

test "rangesOverlap no overlap" {
    try std.testing.expect(!rangesOverlap(1, 3, 5, 3)); // [1,3] and [5,7]
    try std.testing.expect(!rangesOverlap(5, 3, 1, 3)); // symmetric
}

test "rangesOverlap adjacent not overlapping" {
    try std.testing.expect(!rangesOverlap(1, 3, 4, 3)); // [1,3] and [4,6]
}

test "rangesOverlap count zero treated as 1" {
    try std.testing.expect(rangesOverlap(5, 0, 5, 1)); // [5,5] ∩ [5,5]
    try std.testing.expect(!rangesOverlap(5, 0, 6, 1)); // [5,5] and [6,6]
}

test "computeLineSpecForOverlap merged hunk walkthrough" {
    // From investigation notes: HEAD diff merges B→X (staged) and D→Y (unstaged)
    // @@ -1,5 +1,5 @@
    //  A          body=1, new_line=1→2
    // -B          body=2, new_line=2
    // +X          body=3, new_line=2→3
    //  C          body=4, new_line=3→4
    // -D          body=5, new_line=4
    // +Y          body=6, new_line=4→5
    //  E          body=7, new_line=5→6
    //
    // Index hunk target: [3,5] (the D→Y change from git diff)
    // Expected: body lines 5 (-D) and 6 (+Y) → LineSpec {[5,6]}
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var h = testMakeHunk("f.txt", 1, 5, 1, 5);
    h.raw_lines = "@@ -1,5 +1,5 @@\n A\n-B\n+X\n C\n-D\n+Y\n E\n";

    const spec = try computeLineSpecForOverlap(arena.allocator(), &h, 3, 5);

    try std.testing.expectEqual(@as(usize, 1), spec.ranges.len);
    try std.testing.expectEqual(@as(u32, 5), spec.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 6), spec.ranges[0].end);
}

test "computeLineSpecForOverlap all changes in range" {
    // Target covers entire hunk → all +/- lines included
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var h = testMakeHunk("f.txt", 1, 3, 1, 3);
    h.raw_lines = "@@ -1,3 +1,3 @@\n ctx\n-old\n+new\n";

    const spec = try computeLineSpecForOverlap(arena.allocator(), &h, 1, 3);

    try std.testing.expectEqual(@as(usize, 1), spec.ranges.len);
    try std.testing.expectEqual(@as(u32, 2), spec.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 3), spec.ranges[0].end);
}

test "computeLineSpecForOverlap no changes in range" {
    // Target range [10,20] doesn't overlap any +/- lines in hunk at lines 1-5
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var h = testMakeHunk("f.txt", 1, 3, 1, 3);
    h.raw_lines = "@@ -1,3 +1,3 @@\n ctx\n-old\n+new\n";

    const spec = try computeLineSpecForOverlap(arena.allocator(), &h, 10, 20);

    try std.testing.expectEqual(@as(usize, 0), spec.ranges.len);
}

test "computeLineSpecForOverlap removal only" {
    // Target covers only the removal line
    // @@ -1,3 +1,2 @@
    //  ctx        body=1, new_line=1→2
    // -removed    body=2, new_line=2
    //  ctx2       body=3, new_line=2→3
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var h = testMakeHunk("f.txt", 1, 3, 1, 2);
    h.raw_lines = "@@ -1,3 +1,2 @@\n ctx\n-removed\n ctx2\n";

    const spec = try computeLineSpecForOverlap(arena.allocator(), &h, 2, 2);

    try std.testing.expectEqual(@as(usize, 1), spec.ranges.len);
    try std.testing.expectEqual(@as(u32, 2), spec.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 2), spec.ranges[0].end);
}

test "computeLineSpecForOverlap addition only" {
    // Target covers only the addition line
    // @@ -1,2 +1,3 @@
    //  ctx        body=1, new_line=1→2
    // +added      body=2, new_line=2→3
    //  ctx2       body=3, new_line=3→4
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var h = testMakeHunk("f.txt", 1, 2, 1, 3);
    h.raw_lines = "@@ -1,2 +1,3 @@\n ctx\n+added\n ctx2\n";

    const spec = try computeLineSpecForOverlap(arena.allocator(), &h, 2, 2);

    try std.testing.expectEqual(@as(usize, 1), spec.ranges.len);
    try std.testing.expectEqual(@as(u32, 2), spec.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 2), spec.ranges[0].end);
}

test "computeLineSpecForOverlap discontiguous ranges" {
    // Two separate change regions, target covers only the second
    // @@ -1,7 +1,7 @@
    //  ctx1       body=1, new_line=1→2
    // -rem1       body=2, new_line=2
    // +add1       body=3, new_line=2→3
    //  ctx2       body=4, new_line=3→4
    //  ctx3       body=5, new_line=4→5
    // -rem2       body=6, new_line=5
    // +add2       body=7, new_line=5→6
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var h = testMakeHunk("f.txt", 1, 7, 1, 7);
    h.raw_lines = "@@ -1,7 +1,7 @@\n ctx1\n-rem1\n+add1\n ctx2\n ctx3\n-rem2\n+add2\n";

    // Target [5,6] should select only rem2/add2 (body lines 6,7)
    const spec = try computeLineSpecForOverlap(arena.allocator(), &h, 5, 6);

    try std.testing.expectEqual(@as(usize, 1), spec.ranges.len);
    try std.testing.expectEqual(@as(u32, 6), spec.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 7), spec.ranges[0].end);
}

test "computeLineSpecForOverlap no newline marker not counted" {
    // Ensure "\ No newline" doesn't affect body line numbering
    // @@ -1,2 +1,2 @@
    // -old        body=1, new_line=1
    // +new        body=2, new_line=1→2
    // \ No newline at end of file   (NOT counted as body line)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var h = testMakeHunk("f.txt", 1, 2, 1, 2);
    h.raw_lines = "@@ -1,2 +1,2 @@\n-old\n+new\n\\ No newline at end of file\n";

    const spec = try computeLineSpecForOverlap(arena.allocator(), &h, 1, 2);

    try std.testing.expectEqual(@as(usize, 1), spec.ranges.len);
    try std.testing.expectEqual(@as(u32, 1), spec.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 2), spec.ranges[0].end);
}

test "computeLineSpecForOverlap consecutive removals same position" {
    // Multiple consecutive removals all at the same worktree position
    // @@ -1,4 +1,2 @@
    //  ctx        body=1, new_line=1→2
    // -rem1       body=2, new_line=2
    // -rem2       body=3, new_line=2
    //  ctx2       body=4, new_line=2→3
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var h = testMakeHunk("f.txt", 1, 4, 1, 2);
    h.raw_lines = "@@ -1,4 +1,2 @@\n ctx\n-rem1\n-rem2\n ctx2\n";

    const spec = try computeLineSpecForOverlap(arena.allocator(), &h, 2, 2);

    try std.testing.expectEqual(@as(usize, 1), spec.ranges.len);
    try std.testing.expectEqual(@as(u32, 2), spec.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 3), spec.ranges[0].end);
}

test "matchIndexToHead empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const empty_hunks = [_]*const Hunk{};
    const empty_head = [_]Hunk{};
    const result = try matchIndexToHead(arena.allocator(), &empty_hunks, &empty_head);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "matchIndexToHead fast path clean index" {
    // Index and HEAD have identical SHAs → fast path returns head hunks directly
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sha = computeHunkSha("f.txt", 10, "+added line");
    var idx_hunk = testMakeHunk("f.txt", 8, 3, 10, 4);
    idx_hunk.sha_hex = sha;
    var head_hunk = testMakeHunk("f.txt", 8, 3, 10, 4);
    head_hunk.sha_hex = sha;
    head_hunk.raw_lines = "@@ -8,3 +10,4 @@\n ctx\n-old\n+new\n+added line\n";

    const selected = [_]*const Hunk{&idx_hunk};
    const head = [_]Hunk{head_hunk};
    const result = try matchIndexToHead(arena.allocator(), &selected, &head);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].line_spec == null);
    try std.testing.expectEqual(@as(u32, 10), result[0].hunk.new_start);
}

test "matchIndexToHead separate hunks direct match" {
    // Two separate HEAD hunks, index hunk overlaps with one
    // HEAD hunk 1: lines 2-2, HEAD hunk 2: lines 4-4
    // Index hunk: lines 4-4 (overlaps HEAD hunk 2 only)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sha1 = computeHunkSha("f.txt", 2, "-B\n+X");
    const sha2 = computeHunkSha("f.txt", 4, "-D\n+Y");
    const sha_idx = computeHunkSha("f.txt", 4, "-D\n+Y_different");

    var head1 = testMakeHunk("f.txt", 2, 1, 2, 1);
    head1.sha_hex = sha1;
    head1.raw_lines = "@@ -2,1 +2,1 @@\n-B\n+X\n";

    var head2 = testMakeHunk("f.txt", 4, 1, 4, 1);
    head2.sha_hex = sha2;
    head2.raw_lines = "@@ -4,1 +4,1 @@\n-D\n+Y\n";

    // Index hunk covers worktree line 4 (different SHA → no fast path)
    var idx_hunk = testMakeHunk("f.txt", 3, 3, 3, 3);
    idx_hunk.sha_hex = sha_idx;
    idx_hunk.new_start = 3;
    idx_hunk.new_count = 3;

    const selected = [_]*const Hunk{&idx_hunk};
    const head = [_]Hunk{ head1, head2 };
    const result = try matchIndexToHead(arena.allocator(), &selected, &head);

    // Head hunk 2 (lines 4-4) is fully within index range [3,5]
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].line_spec == null);
    try std.testing.expectEqual(@as(u32, 4), result[0].hunk.new_start);
}

test "matchIndexToHead merged hunk partial overlap" {
    // Single merged HEAD hunk covering lines 1-5
    // Index hunk covers only lines 3-5 (the second change)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sha_head = computeHunkSha("f.txt", 1, "-B\n+X\n-D\n+Y");
    const sha_idx = computeHunkSha("f.txt", 3, "-D\n+Y");

    var head_h = testMakeHunk("f.txt", 1, 5, 1, 5);
    head_h.sha_hex = sha_head;
    head_h.raw_lines = "@@ -1,5 +1,5 @@\n A\n-B\n+X\n C\n-D\n+Y\n E\n";

    var idx_hunk = testMakeHunk("f.txt", 3, 3, 3, 3);
    idx_hunk.sha_hex = sha_idx;

    const selected = [_]*const Hunk{&idx_hunk};
    const head = [_]Hunk{head_h};
    const result = try matchIndexToHead(arena.allocator(), &selected, &head);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].line_spec != null);

    // LineSpec should select body lines 5-6 (-D, +Y)
    const spec = result[0].line_spec.?;
    try std.testing.expectEqual(@as(usize, 1), spec.ranges.len);
    try std.testing.expectEqual(@as(u32, 5), spec.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 6), spec.ranges[0].end);
}

test "matchIndexToHead different file no match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sha_idx = computeHunkSha("a.txt", 1, "+line");
    const sha_head = computeHunkSha("b.txt", 1, "+line");

    var idx_hunk = testMakeHunk("a.txt", 1, 1, 1, 1);
    idx_hunk.sha_hex = sha_idx;

    var head_h = testMakeHunk("b.txt", 1, 1, 1, 1);
    head_h.sha_hex = sha_head;
    head_h.raw_lines = "@@ -1 +1 @@\n+line\n";

    const selected = [_]*const Hunk{&idx_hunk};
    const head = [_]Hunk{head_h};
    const result = try matchIndexToHead(arena.allocator(), &selected, &head);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "matchIndexToHead multiple index hunks same HEAD hunk dedup" {
    // Two index hunks both overlap with the same merged HEAD hunk.
    // Result should contain one MatchedHunk (dedup via head-iteration).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sha_head = computeHunkSha("f.txt", 1, "-A\n+X\n-C\n+Z");
    const sha_idx1 = computeHunkSha("f.txt", 1, "-A\n+X");
    const sha_idx2 = computeHunkSha("f.txt", 3, "-C\n+Z");

    var head_h = testMakeHunk("f.txt", 1, 4, 1, 4);
    head_h.sha_hex = sha_head;
    head_h.raw_lines = "@@ -1,4 +1,4 @@\n-A\n+X\n B\n-C\n+Z\n";

    // Two index hunks: [1,1] and [3,3], both overlap HEAD [1,4]
    var idx1 = testMakeHunk("f.txt", 1, 1, 1, 1);
    idx1.sha_hex = sha_idx1;
    var idx2 = testMakeHunk("f.txt", 3, 1, 3, 1);
    idx2.sha_hex = sha_idx2;

    const selected = [_]*const Hunk{ &idx1, &idx2 };
    const head = [_]Hunk{head_h};
    const result = try matchIndexToHead(arena.allocator(), &selected, &head);

    // Deduplicated: single MatchedHunk covering both ranges
    try std.testing.expectEqual(@as(usize, 1), result.len);
    // Both index hunks together cover [1,3], head is [1,4] → partial
    // But combined target ranges cover all changes, so let's verify the LineSpec
    try std.testing.expect(result[0].line_spec != null);
    const spec = result[0].line_spec.?;
    // Body: -A(1), +X(2), ' B'(3), -C(4), +Z(5)
    // new_line: -A@1, +X@1→2, B@2→3, -C@3, +Z@3→4
    // Range [1,1]: -A@1 ✓, +X@1 ✓
    // Range [3,3]: -C@3 ✓, +Z@3 ✓
    // Ranges coalesce through context line ' B' into single {1,5}.
    // This is correct: buildFilteredHunkPatch only calls containsLine for
    // +/- lines, context lines are always kept regardless of LineSpec.
    try std.testing.expectEqual(@as(usize, 1), spec.ranges.len);
    try std.testing.expectEqual(@as(u32, 1), spec.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 5), spec.ranges[0].end);
}

test "matchIndexToHead index hunk fully covers HEAD hunk" {
    // Index hunk range [1,10] fully covers HEAD hunk range [3,5]
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sha_idx = computeHunkSha("f.txt", 1, "+big_change");
    const sha_head = computeHunkSha("f.txt", 3, "-old\n+new");

    var idx_hunk = testMakeHunk("f.txt", 1, 10, 1, 10);
    idx_hunk.sha_hex = sha_idx;

    var head_h = testMakeHunk("f.txt", 3, 3, 3, 3);
    head_h.sha_hex = sha_head;
    head_h.raw_lines = "@@ -3,3 +3,3 @@\n ctx\n-old\n+new\n";

    const selected = [_]*const Hunk{&idx_hunk};
    const head = [_]Hunk{head_h};
    const result = try matchIndexToHead(arena.allocator(), &selected, &head);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].line_spec == null); // fully contained
}

test "matchIndexToHead deletion hunk count zero" {
    // Pure deletion: new_count=0
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sha_idx = computeHunkSha("f.txt", 5, "-deleted");
    const sha_head = computeHunkSha("f.txt", 5, "-deleted_head");

    var idx_hunk = testMakeHunk("f.txt", 5, 2, 5, 0);
    idx_hunk.sha_hex = sha_idx;

    var head_h = testMakeHunk("f.txt", 5, 2, 5, 0);
    head_h.sha_hex = sha_head;
    head_h.raw_lines = "@@ -5,2 +5,0 @@\n-line1\n-line2\n";

    const selected = [_]*const Hunk{&idx_hunk};
    const head = [_]Hunk{head_h};
    const result = try matchIndexToHead(arena.allocator(), &selected, &head);

    // count=0 → range is [5,5], both overlap → fully contained
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].line_spec == null);
}

test "changedLinesWorktreeRange basic" {
    // Hunk with context + one change at worktree line 3
    // @@ -1,5 +1,5 @@
    //  ctx1       new_line=1→2
    //  ctx2       new_line=2→3
    // -old        new_line=3
    // +new        new_line=3→4
    //  ctx3       new_line=4→5
    var h = testMakeHunk("f.txt", 1, 5, 1, 5);
    h.raw_lines = "@@ -1,5 +1,5 @@\n ctx1\n ctx2\n-old\n+new\n ctx3\n";

    const range = changedLinesWorktreeRange(&h).?;
    try std.testing.expectEqual(@as(u32, 3), range.start);
    try std.testing.expectEqual(@as(u32, 3), range.end);
}

test "changedLinesWorktreeRange multiple changes" {
    // Two changes at worktree lines 2 and 4
    // @@ -1,5 +1,5 @@
    //  A          new_line=1→2
    // -B          new_line=2
    // +X          new_line=2→3
    //  C          new_line=3→4
    // -D          new_line=4
    // +Y          new_line=4→5
    //  E          new_line=5→6
    var h = testMakeHunk("f.txt", 1, 5, 1, 5);
    h.raw_lines = "@@ -1,5 +1,5 @@\n A\n-B\n+X\n C\n-D\n+Y\n E\n";

    const range = changedLinesWorktreeRange(&h).?;
    try std.testing.expectEqual(@as(u32, 2), range.start);
    try std.testing.expectEqual(@as(u32, 4), range.end);
}

test "matchIndexToHead dirty index nearby staged change not captured" {
    // Dirty index scenario: line 5→FIVE is staged, line 8→EIGHT is unstaged.
    // git diff (index vs worktree) produces one hunk covering context lines 5-11
    // but the actual change is only at line 8.
    // git diff HEAD produces a merged hunk with changes at lines 5 AND 8.
    // The matcher should only capture line 8 changes, not line 5 (staged).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sha_idx = computeHunkSha("f.txt", 5, "-line 8\n+line EIGHT");
    const sha_head = computeHunkSha("f.txt", 2, "-line 5\n+line FIVE\n-line 8\n+line EIGHT");

    // Index hunk: context range [5,11] but changed line at position 8 only
    var idx_hunk = testMakeHunk("f.txt", 5, 7, 5, 7);
    idx_hunk.sha_hex = sha_idx;
    idx_hunk.raw_lines = "@@ -5,7 +5,7 @@\n line 5\n line 6\n line 7\n-line 8\n+line EIGHT\n line 9\n line 10\n";

    // HEAD hunk: merged, changes at lines 5 and 8
    var head_h = testMakeHunk("f.txt", 2, 10, 2, 10);
    head_h.sha_hex = sha_head;
    head_h.raw_lines = "@@ -2,10 +2,10 @@\n line 2\n line 3\n line 4\n-line 5\n+line FIVE\n line 6\n line 7\n-line 8\n+line EIGHT\n line 9\n line 10\n";

    const selected = [_]*const Hunk{&idx_hunk};
    const head = [_]Hunk{head_h};
    const result = try matchIndexToHead(arena.allocator(), &selected, &head);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    // Must have a LineSpec — not null (would be null if it captured everything)
    try std.testing.expect(result[0].line_spec != null);

    const spec = result[0].line_spec.?;
    // LineSpec should capture only the line 8 changes (body lines 7=-line 8, 8=+line EIGHT)
    // Body walk: line2(1), line3(2), line4(3), -line5(4), +lineFIVE(5), line6(6), line7(7), -line8(8), +lineEIGHT(9), line9(10), line10(11)
    // Wait — let me recount with the header skipped:
    // body_line 1: " line 2" ctx, new_line=2→3
    // body_line 2: " line 3" ctx, new_line=3→4
    // body_line 3: " line 4" ctx, new_line=4→5
    // body_line 4: "-line 5" rem, new_line=5 → check [8,8] → NO
    // body_line 5: "+line FIVE" add, new_line=5→6 → check [8,8] → NO
    // body_line 6: " line 6" ctx, new_line=6→7
    // body_line 7: " line 7" ctx, new_line=7→8
    // body_line 8: "-line 8" rem, new_line=8 → check [8,8] → YES
    // body_line 9: "+line EIGHT" add, new_line=8→9 → check [8,8] → YES
    // body_line 10: " line 9" ctx, new_line=9→10
    // body_line 11: " line 10" ctx, new_line=10→11
    try std.testing.expectEqual(@as(usize, 1), spec.ranges.len);
    try std.testing.expectEqual(@as(u32, 8), spec.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 9), spec.ranges[0].end);
}
