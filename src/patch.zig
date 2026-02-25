const std = @import("std");
const types = @import("types.zig");
const diff_mod = @import("diff.zig");

const Allocator = std.mem.Allocator;
const Hunk = types.Hunk;
const MatchedHunk = types.MatchedHunk;
const LineSpec = types.LineSpec;
const LineRange = types.LineRange;

pub fn findHunkByShaPrefix(hunks: []const Hunk, prefix: []const u8, file_filter: ?[]const u8) !*const Hunk {
    var match: ?*const Hunk = null;
    for (hunks) |*h| {
        if (file_filter) |filter| {
            if (!std.mem.eql(u8, h.file_path, filter)) continue;
        }
        if (std.mem.startsWith(u8, &h.sha_hex, prefix)) {
            if (match != null) return error.AmbiguousPrefix;
            match = h;
        }
    }
    return match orelse error.NotFound;
}

pub fn matchedHunkPatchOrder(_: void, a: MatchedHunk, b: MatchedHunk) bool {
    const path_order = std.mem.order(u8, a.hunk.file_path, b.hunk.file_path);
    if (path_order != .eq) return path_order == .lt;
    return a.hunk.old_start < b.hunk.old_start;
}

/// Compare hunks for sorting: by file path, then by old_start (line order within file).
pub fn hunkPatchOrder(_: void, a: *const Hunk, b: *const Hunk) bool {
    const path_order = std.mem.order(u8, a.file_path, b.file_path);
    if (path_order != .eq) return path_order == .lt;
    return a.old_start < b.old_start;
}

pub fn buildCombinedPatch(arena: Allocator, matches: []const MatchedHunk) ![]const u8 {
    var patch: std.ArrayList(u8) = .empty;

    // Group hunks by patch_header to combine hunks from the same file
    // under a single header. We iterate in order and track the last header.
    var last_header: []const u8 = "";
    for (matches) |m| {
        if (!std.mem.eql(u8, m.hunk.patch_header, last_header)) {
            try patch.appendSlice(arena, m.hunk.patch_header);
            last_header = m.hunk.patch_header;
        }
        if (m.line_spec) |ls| {
            const filtered = try buildFilteredHunkPatch(arena, m.hunk, ls);
            try patch.appendSlice(arena, filtered);
        } else {
            try patch.appendSlice(arena, m.hunk.raw_lines);
        }
        // Ensure trailing newline
        if (patch.items.len > 0 and patch.items[patch.items.len - 1] != '\n') {
            try patch.append(arena, '\n');
        }
    }

    return patch.items;
}

/// Build a filtered hunk patch containing only selected lines.
/// Deselected '-' lines become context; deselected '+' lines are dropped.
/// Returns new raw_lines with a rewritten @@ header.
fn buildFilteredHunkPatch(arena: Allocator, h: *const Hunk, line_spec: LineSpec) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var filtered_body: std.ArrayList(u8) = .empty;

    // Manual newline iteration to avoid trailing empty element from splitScalar
    // Skip the @@ header line
    var pos: usize = 0;
    if (std.mem.indexOfScalar(u8, h.raw_lines, '\n')) |nl| {
        pos = nl + 1;
    } else {
        return h.raw_lines; // degenerate: no body
    }

    var new_old_count: u32 = 0;
    var new_new_count: u32 = 0;
    var line_num: u32 = 1;
    var prev_kept = true;
    var has_changes = false;

    while (pos < h.raw_lines.len) {
        const end = std.mem.indexOfScalarPos(u8, h.raw_lines, pos, '\n') orelse h.raw_lines.len;
        const line = h.raw_lines[pos..end];
        pos = if (end < h.raw_lines.len) end + 1 else h.raw_lines.len;

        if (line.len == 0) {
            // Empty context line (git sometimes strips trailing space from blank lines)
            try filtered_body.append(arena, '\n');
            new_old_count += 1;
            new_new_count += 1;
            line_num += 1;
            prev_kept = true;
            continue;
        }

        const first = line[0];
        if (first == ' ') {
            // Context: always keep
            try filtered_body.appendSlice(arena, line);
            try filtered_body.append(arena, '\n');
            new_old_count += 1;
            new_new_count += 1;
            line_num += 1;
            prev_kept = true;
        } else if (first == '-') {
            if (line_spec.containsLine(line_num)) {
                // Selected removal: keep as -
                try filtered_body.appendSlice(arena, line);
                try filtered_body.append(arena, '\n');
                new_old_count += 1;
                has_changes = true;
            } else {
                // Deselected removal: convert to context line
                try filtered_body.append(arena, ' ');
                try filtered_body.appendSlice(arena, line[1..]);
                try filtered_body.append(arena, '\n');
                new_old_count += 1;
                new_new_count += 1;
            }
            line_num += 1;
            prev_kept = true;
        } else if (first == '+') {
            if (line_spec.containsLine(line_num)) {
                // Selected addition: keep as +
                try filtered_body.appendSlice(arena, line);
                try filtered_body.append(arena, '\n');
                new_new_count += 1;
                has_changes = true;
                prev_kept = true;
            } else {
                // Deselected addition: drop entirely
                prev_kept = false;
            }
            line_num += 1;
        } else if (first == '\\') {
            // "\ No newline at end of file" — keep if previous line was kept
            if (prev_kept) {
                try filtered_body.appendSlice(arena, line);
                try filtered_body.append(arena, '\n');
            }
        }
    }

    if (!has_changes) {
        std.debug.print("error: no changes in selected lines of hunk {s}\n", .{h.sha_hex[0..7]});
        std.process.exit(1);
    }

    // Build the @@ header
    try result.writer(arena).print("@@ -{d},{d} +{d},{d} @@", .{ h.old_start, new_old_count, h.new_start, new_new_count });
    if (h.context.len > 0) {
        try result.append(arena, ' ');
        try result.appendSlice(arena, h.context);
    }
    try result.append(arena, '\n');

    // Append the filtered body
    try result.appendSlice(arena, filtered_body.items);

    return result.items;
}

// ============================================================================
// Tests
// ============================================================================

const testMakeHunk = types.testMakeHunk;
const computeHunkSha = diff_mod.computeHunkSha;

test "hunkPatchOrder same file by line" {
    const a = testMakeHunk("a.txt", 5, 3, 5, 3);
    const b = testMakeHunk("a.txt", 10, 2, 10, 2);
    try std.testing.expect(hunkPatchOrder({}, &a, &b));
    try std.testing.expect(!hunkPatchOrder({}, &b, &a));
}

test "hunkPatchOrder different files" {
    const a = testMakeHunk("a.txt", 100, 1, 100, 1);
    const b = testMakeHunk("b.txt", 1, 1, 1, 1);
    try std.testing.expect(hunkPatchOrder({}, &a, &b));
    try std.testing.expect(!hunkPatchOrder({}, &b, &a));
}

test "hunkPatchOrder equal is not less" {
    const a = testMakeHunk("a.txt", 5, 3, 5, 3);
    try std.testing.expect(!hunkPatchOrder({}, &a, &a));
}

test "findHunkByShaPrefix exact match" {
    const sha = computeHunkSha("a.zig", 1, "+line");
    var h = testMakeHunk("a.zig", 1, 1, 1, 1);
    h.sha_hex = sha;
    const hunks = [_]Hunk{h};
    const found = try findHunkByShaPrefix(&hunks, sha[0..7], null);
    try std.testing.expectEqualStrings("a.zig", found.file_path);
}

test "findHunkByShaPrefix not found" {
    const h = testMakeHunk("a.zig", 1, 1, 1, 1);
    const hunks = [_]Hunk{h};
    try std.testing.expectError(error.NotFound, findHunkByShaPrefix(&hunks, "deadbeef", null));
}

test "findHunkByShaPrefix ambiguous" {
    const sha = computeHunkSha("a.zig", 1, "+line");
    var h1 = testMakeHunk("a.zig", 1, 1, 1, 1);
    h1.sha_hex = sha;
    var h2 = testMakeHunk("b.zig", 1, 1, 1, 1);
    h2.sha_hex = sha; // same SHA → same prefix
    const hunks = [_]Hunk{ h1, h2 };
    try std.testing.expectError(error.AmbiguousPrefix, findHunkByShaPrefix(&hunks, sha[0..7], null));
}

test "findHunkByShaPrefix file filter excludes" {
    const sha = computeHunkSha("a.zig", 1, "+line");
    var h = testMakeHunk("a.zig", 1, 1, 1, 1);
    h.sha_hex = sha;
    const hunks = [_]Hunk{h};
    try std.testing.expectError(error.NotFound, findHunkByShaPrefix(&hunks, sha[0..7], "b.zig"));
}

test "findHunkByShaPrefix file filter matches" {
    const sha = computeHunkSha("a.zig", 1, "+line");
    var h = testMakeHunk("a.zig", 1, 1, 1, 1);
    h.sha_hex = sha;
    const hunks = [_]Hunk{h};
    const found = try findHunkByShaPrefix(&hunks, sha[0..7], "a.zig");
    try std.testing.expectEqualStrings("a.zig", found.file_path);
}

test "buildCombinedPatch single hunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 1, 1, 1);
    h.patch_header = "--- a/f.txt\n+++ b/f.txt\n";
    h.raw_lines = "@@ -1 +1 @@\n-old\n+new\n";
    const matches = [_]MatchedHunk{.{ .hunk = &h, .line_spec = null }};
    const patch = try buildCombinedPatch(arena.allocator(), &matches);
    try std.testing.expectEqualStrings(
        "--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n-old\n+new\n",
        patch,
    );
}

test "buildCombinedPatch same file deduplicates header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const header = "--- a/f.txt\n+++ b/f.txt\n";
    var h1 = testMakeHunk("f.txt", 1, 1, 1, 1);
    h1.patch_header = header;
    h1.raw_lines = "@@ -1 +1 @@\n-old1\n+new1\n";
    var h2 = testMakeHunk("f.txt", 10, 1, 10, 1);
    h2.patch_header = header;
    h2.raw_lines = "@@ -10 +10 @@\n-old2\n+new2\n";
    const matches = [_]MatchedHunk{
        .{ .hunk = &h1, .line_spec = null },
        .{ .hunk = &h2, .line_spec = null },
    };
    const patch = try buildCombinedPatch(arena.allocator(), &matches);
    try std.testing.expectEqualStrings(
        "--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n-old1\n+new1\n@@ -10 +10 @@\n-old2\n+new2\n",
        patch,
    );
}

test "buildCombinedPatch multiple files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h1 = testMakeHunk("a.txt", 1, 1, 1, 1);
    h1.patch_header = "--- a/a.txt\n+++ b/a.txt\n";
    h1.raw_lines = "@@ -1 +1 @@\n-a\n+A\n";
    var h2 = testMakeHunk("b.txt", 1, 1, 1, 1);
    h2.patch_header = "--- a/b.txt\n+++ b/b.txt\n";
    h2.raw_lines = "@@ -1 +1 @@\n-b\n+B\n";
    const matches = [_]MatchedHunk{
        .{ .hunk = &h1, .line_spec = null },
        .{ .hunk = &h2, .line_spec = null },
    };
    const patch = try buildCombinedPatch(arena.allocator(), &matches);
    try std.testing.expectEqualStrings(
        "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+A\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-b\n+B\n",
        patch,
    );
}

test "buildCombinedPatch adds trailing newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 1, 1, 1);
    h.patch_header = "--- a/f.txt\n+++ b/f.txt\n";
    h.raw_lines = "@@ -1 +1 @@\n-old\n+new"; // no trailing newline
    const matches = [_]MatchedHunk{.{ .hunk = &h, .line_spec = null }};
    const patch = try buildCombinedPatch(arena.allocator(), &matches);
    try std.testing.expect(patch[patch.len - 1] == '\n');
}

test "buildCombinedPatch with line spec filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 3, 1, 3);
    h.patch_header = "--- a/f.txt\n+++ b/f.txt\n";
    h.raw_lines = "@@ -1,3 +1,3 @@\n ctx\n-old\n+new\n ctx2\n";
    const ranges = [_]LineRange{.{ .start = 2, .end = 3 }};
    const matches = [_]MatchedHunk{.{ .hunk = &h, .line_spec = .{ .ranges = &ranges } }};
    const patch = try buildCombinedPatch(arena.allocator(), &matches);
    // Selecting all changes produces same counts as original
    try std.testing.expectEqualStrings(
        "--- a/f.txt\n+++ b/f.txt\n@@ -1,3 +1,3 @@\n ctx\n-old\n+new\n ctx2\n",
        patch,
    );
}

test "buildFilteredHunkPatch select one addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 3, 1, 3);
    h.raw_lines = "@@ -1,3 +1,3 @@\n context\n-removed\n+added\n context2\n";
    const ranges = [_]LineRange{.{ .start = 3, .end = 3 }}; // select only +added
    const result = try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges });
    // -removed becomes context, +added stays
    // old: context(1) + removed-as-context(2) + context2(3) = 3
    // new: context(1) + removed-as-context(2) + added(3) + context2(4) = 4
    try std.testing.expectEqualStrings(
        "@@ -1,3 +1,4 @@\n context\n removed\n+added\n context2\n",
        result,
    );
}

test "buildFilteredHunkPatch select one removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 3, 1, 3);
    h.raw_lines = "@@ -1,3 +1,3 @@\n context\n-removed\n+added\n context2\n";
    const ranges = [_]LineRange{.{ .start = 2, .end = 2 }}; // select only -removed
    const result = try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges });
    // -removed stays, +added dropped
    // old: context(1) + removed(2) + context2(3) = 3
    // new: context(1) + context2(2) = 2
    try std.testing.expectEqualStrings(
        "@@ -1,3 +1,2 @@\n context\n-removed\n context2\n",
        result,
    );
}

test "buildFilteredHunkPatch select replacement pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 3, 1, 3);
    h.raw_lines = "@@ -1,3 +1,3 @@\n context\n-old\n+new\n";
    const ranges = [_]LineRange{.{ .start = 2, .end = 3 }}; // select both - and +
    const result = try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges });
    // Both kept: old = context(1) + old(2) = 2, new = context(1) + new(2) = 2
    try std.testing.expectEqualStrings(
        "@@ -1,2 +1,2 @@\n context\n-old\n+new\n",
        result,
    );
}

test "buildFilteredHunkPatch preserves func context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 10, 3, 10, 3);
    h.context = "fn main()";
    h.raw_lines = "@@ -10,3 +10,3 @@ fn main()\n context\n-old\n+new\n";
    const ranges = [_]LineRange{.{ .start = 2, .end = 3 }};
    const result = try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges });
    try std.testing.expect(std.mem.startsWith(u8, result, "@@ -10,2 +10,2 @@ fn main()\n"));
}

test "buildFilteredHunkPatch multiple changes partial select" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 5, 1, 5);
    h.raw_lines = "@@ -1,5 +1,5 @@\n ctx1\n-rem1\n+add1\n ctx2\n-rem2\n+add2\n";
    // Select only first replacement (lines 2-3), not second (lines 5-6)
    const ranges = [_]LineRange{.{ .start = 2, .end = 3 }};
    const result = try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges });
    // rem1 kept as -, add1 kept as +, rem2 becomes context, add2 dropped
    // old: ctx1(1) + rem1(2) + ctx2(3) + rem2-as-ctx(4) = 4
    // new: ctx1(1) + add1(2) + ctx2(3) + rem2-as-ctx(4) = 4
    try std.testing.expectEqualStrings(
        "@@ -1,4 +1,4 @@\n ctx1\n-rem1\n+add1\n ctx2\n rem2\n",
        result,
    );
}
