const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Hunk = types.Hunk;
const FileSection = types.FileSection;
const MatchedHunk = types.MatchedHunk;
const LineSpec = types.LineSpec;
const LineRange = types.LineRange;
const BodyLine = types.BodyLine;

pub const ShaLookupError = error{ NotFound, AmbiguousPrefix };

pub fn findHunkByShaPrefix(hunks: []const Hunk, prefix: []const u8, file_filter: []const []const u8) ShaLookupError!*const Hunk {
    var match: ?*const Hunk = null;
    for (hunks) |*h| {
        if (!types.matchesFileFilter(h.file_path, file_filter)) continue;
        if (std.mem.startsWith(u8, &h.sha_hex, prefix)) {
            if (match != null) return error.AmbiguousPrefix;
            match = h;
        }
    }
    return match orelse error.NotFound;
}

fn matchedHunkPatchOrder(_: void, a: MatchedHunk, b: MatchedHunk) bool {
    const path_order = std.mem.order(u8, a.hunk.file_path, b.hunk.file_path);
    if (path_order != .eq) return path_order == .lt;
    // Typechange: deleted file before new file (delete must apply first)
    const a_deletes = a.hunk.section.is_deleted_file;
    if (a_deletes != b.hunk.section.is_deleted_file) return a_deletes;
    return a.hunk.old_start < b.hunk.old_start;
}

/// Collect unique file paths from matched hunks (preserving first-seen order).
pub fn collectUniqueFilePaths(arena: Allocator, matches: []const MatchedHunk) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (matches) |m| {
        for (list.items) |fp| {
            if (std.mem.eql(u8, fp, m.hunk.file_path)) break;
        } else try list.append(arena, m.hunk.file_path);
    }
    return list.items;
}

/// The paths a diff must cover to show what became of `matches` once
/// applied: git only detects a rename when both its paths are in scope.
pub fn collectResultPaths(arena: Allocator, matches: []const MatchedHunk) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, try collectUniqueFilePaths(arena, matches));
    for (matches) |m| {
        const from = m.hunk.section.renamed_from_path orelse continue;
        for (list.items) |fp| {
            if (std.mem.eql(u8, fp, from)) break;
        } else try list.append(arena, from);
    }
    return list.items;
}

/// A 4-way split of matched hunks by `is_untracked` × `is_binary`, plus deduped
/// path lists for the binary buckets. Every slice is arena-owned.
pub const HunkPartition = struct {
    tracked_text: []const MatchedHunk,
    tracked_binary: []const MatchedHunk,
    untracked_text: []const MatchedHunk,
    untracked_binary: []const MatchedHunk,
    /// Deduped file paths from `tracked_binary`.
    tracked_binary_paths: []const []const u8,
    /// Deduped file paths from `untracked_binary`.
    untracked_binary_paths: []const []const u8,
    /// Tracked + untracked text hunks combined into a single arena-owned slice.
    pub fn combinedText(self: HunkPartition, arena: Allocator) ![]MatchedHunk {
        var combined: std.ArrayList(MatchedHunk) = .empty;
        try combined.appendSlice(arena, self.tracked_text);
        try combined.appendSlice(arena, self.untracked_text);
        return combined.items;
    }

    /// Tracked + untracked binary hunks combined into a single arena-owned slice.
    pub fn combinedBinary(self: HunkPartition, arena: Allocator) ![]MatchedHunk {
        var combined: std.ArrayList(MatchedHunk) = .empty;
        try combined.appendSlice(arena, self.tracked_binary);
        try combined.appendSlice(arena, self.untracked_binary);
        return combined.items;
    }

    /// Deduped file paths from `tracked_binary` + `untracked_binary`. Allocated on
    /// `arena` on demand so callers that don't need the union don't pay for it.
    pub fn allBinaryPaths(self: HunkPartition, arena: Allocator) ![]const []const u8 {
        const combined = try self.combinedBinary(arena);
        return collectUniqueFilePaths(arena, combined);
    }
};

/// Partition matched hunks into tracked-text, tracked-binary, untracked-text,
/// untracked-binary buckets plus deduped path lists for the binary cases.
/// Arena-allocates all returned slices.
pub fn partitionByKind(arena: Allocator, matches: []const MatchedHunk) !HunkPartition {
    var tracked_text: std.ArrayList(MatchedHunk) = .empty;
    var tracked_binary: std.ArrayList(MatchedHunk) = .empty;
    var untracked_text: std.ArrayList(MatchedHunk) = .empty;
    var untracked_binary: std.ArrayList(MatchedHunk) = .empty;
    for (matches) |m| {
        const section = m.hunk.section;
        const list = if (section.is_untracked)
            (if (section.is_binary) &untracked_binary else &untracked_text)
        else
            (if (section.is_binary) &tracked_binary else &tracked_text);
        try list.append(arena, m);
    }

    return .{
        .tracked_text = tracked_text.items,
        .tracked_binary = tracked_binary.items,
        .untracked_text = untracked_text.items,
        .untracked_binary = untracked_binary.items,
        .tracked_binary_paths = try collectUniqueFilePaths(arena, tracked_binary.items),
        .untracked_binary_paths = try collectUniqueFilePaths(arena, untracked_binary.items),
    };
}

/// How the caller will hand the resulting patch to `git apply`. Line-spec
/// filtering is direction-sensitive: a forward apply matches the patch's old
/// side against the target, a reverse apply matches its new side, so each
/// direction must keep a different set of deselected lines as context.
const ApplyDirection = enum { forward, reverse };

/// Build one or more patches from matched hunks, in the order `direction`
/// must apply them. Returns multiple patches when typechanges are present
/// (same file with delete + create requires separate git-apply calls because
/// git cannot apply both in a single patch): a forward apply deletes the old
/// file before creating the new one, and a reverse apply undoes the creation
/// before restoring the deleted file, so reverse gets the patches back to front.
/// Sorts `matches` in place first: buildCombinedPatches relies on typechange
/// deletions preceding creations, and this keeps the pair inseparable.
pub fn sortAndBuildPatches(arena: Allocator, matches: []MatchedHunk, direction: ApplyDirection) ![]const []const u8 {
    std.mem.sort(MatchedHunk, matches, {}, matchedHunkPatchOrder);
    const patches = try buildCombinedPatches(arena, matches, direction);
    if (direction == .reverse) std.mem.reverse([]const u8, patches);
    return patches;
}

fn buildCombinedPatches(arena: Allocator, matches: []const MatchedHunk, direction: ApplyDirection) ![][]const u8 {
    var patches: std.ArrayList([]const u8) = .empty;
    var patch: std.ArrayList(u8) = .empty;

    // Paths already in the current patch. A second section for one of them is
    // the other half of a typechange, which git cannot apply in the same patch.
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;

    var start: usize = 0;
    while (start < matches.len) {
        const end = sectionRunEnd(matches, start);
        const file_path = matches[start].hunk.file_path;
        if (seen.contains(file_path) and patch.items.len > 0) {
            try patches.append(arena, patch.items);
            patch = .empty;
            seen.clearRetainingCapacity();
        }
        try appendSectionPatch(arena, &patch, matches[start..end], direction);
        try seen.put(arena, file_path, {});
        start = end;
    }

    if (patch.items.len > 0) {
        try patches.append(arena, patch.items);
    }

    return patches.items;
}

/// End of the run of matches that share `matches[start]`'s section.
fn sectionRunEnd(matches: []const MatchedHunk, start: usize) usize {
    const section = matches[start].hunk.section;
    var end = start + 1;
    while (end < matches.len and matches[end].hunk.section == section) end += 1;
    return end;
}

/// Append one file's part of a patch: its hunks, filtered, under a header
/// rendered to agree with them.
fn appendSectionPatch(arena: Allocator, patch: *std.ArrayList(u8), run: []const MatchedHunk, direction: ApplyDirection) !void {
    var body: std.ArrayList(u8) = .empty;
    var old_lines: u32 = 0;
    var new_lines: u32 = 0;
    for (run) |m| {
        const hunk = if (m.line_spec) |ls|
            try buildFilteredHunkPatch(arena, m.hunk, ls, direction)
        else
            PatchHunk.whole(m.hunk);
        try body.appendSlice(arena, hunk.text);
        if (body.items.len > 0 and body.items[body.items.len - 1] != '\n') {
            try body.append(arena, '\n');
        }
        old_lines += hunk.old_count;
        new_lines += hunk.new_count;
    }

    // A side the source lacks exists afterwards only if filtering left lines
    // on it: a new file whose deselected lines stay as context on the old
    // side is a change to an existing file, not a creation.
    const section = run[0].hunk.section;
    const sides: Sides = .{
        .old = !section.is_new_file or old_lines > 0,
        .new = !section.is_deleted_file or new_lines > 0,
    };
    try appendSectionHeader(arena, patch, section, sides);
    try patch.appendSlice(arena, body.items);
}

/// Which sides of the file a patch has: false where it is `/dev/null`.
const Sides = struct { old: bool, new: bool };

fn sourceSides(section: *const FileSection) Sides {
    return .{ .old = !section.is_new_file, .new = !section.is_deleted_file };
}

/// The header of a file section as `diff` shows it, before any filtering.
pub fn renderSectionHeader(arena: Allocator, section: *const FileSection) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendSectionHeader(arena, &out, section, sourceSides(section));
    return out.items;
}

/// `diff --git`, rename and index lines are kept verbatim whatever the
/// sides: filtering never changes the side `git apply` matches, so the index
/// line's preimage id stays true, and `--3way` needs it.
fn appendSectionHeader(arena: Allocator, out: *std.ArrayList(u8), section: *const FileSection, sides: Sides) !void {
    try appendLine(arena, out, section.diff_git_line);
    if (!sides.old) {
        try out.print(arena, "new file mode {s}\n", .{section.file_mode});
    } else if (!sides.new) {
        try out.print(arena, "deleted file mode {s}\n", .{section.file_mode});
    }
    if (!section.is_binary) {
        if (section.rename_from) |from| try out.print(arena, "rename from {s}\n", .{from});
        if (section.rename_to) |to| try out.print(arena, "rename to {s}\n", .{to});
    }
    if (section.index_line) |line| try appendLine(arena, out, line);
    if (section.is_binary) return;

    // An empty file's section has no ---/+++ lines, and git applies it as is.
    const minus_line = section.minus_line orelse return;
    const plus_line = section.plus_line.?;
    const source = sourceSides(section);
    try appendLine(arena, out, if (sides.old and !source.old) try otherSideLine(arena, plus_line) else minus_line);
    try appendLine(arena, out, if (sides.new and !source.new) try otherSideLine(arena, minus_line) else plus_line);
}

/// The `---`/`+++` line naming the same path on the other side: `+++ b/p`
/// gives `--- a/p` and `+++ "b/p"` gives `--- "a/p"`. The path is reused as
/// git quoted it rather than quoted again.
fn otherSideLine(arena: Allocator, line: []const u8) ![]const u8 {
    const to_old = std.mem.startsWith(u8, line, "+++ ");
    const rest = line["+++ ".len..];
    const quote: []const u8 = if (std.mem.startsWith(u8, rest, "\"")) "\"" else "";
    // Past the quote, the path starts with git's one-letter prefix and '/'.
    const path = rest[quote.len + 1 ..];
    const marker: []const u8 = if (to_old) "--- " else "+++ ";
    const prefix: []const u8 = if (to_old) "a" else "b";
    return std.mem.concat(arena, u8, &.{ marker, quote, prefix, path });
}

fn appendLine(arena: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    try out.appendSlice(arena, line);
    try out.append(arena, '\n');
}

/// What becomes of one body line when a line spec filters its hunk.
const LineFate = enum { keep, as_context, drop };

/// Deselected lines must survive on whichever side `git apply` will match
/// against the target, and vanish from the other:
///   - forward: the old side is matched, so a deselected '-' (a line the target
///     still has) becomes context and a deselected '+' is dropped.
///   - reverse: the new side is matched, so the mirror holds — a deselected '+'
///     (a line the target already has) becomes context and a deselected '-' is
///     dropped.
/// Getting this backwards produces a patch whose matched side disagrees with
/// the target, which git rejects with "patch does not apply".
fn lineFate(kind: BodyLine.Kind, selected: bool, direction: ApplyDirection) LineFate {
    if (selected or kind == .context) return .keep;
    const on_matched_side = switch (direction) {
        .forward => kind == .removal,
        .reverse => kind == .addition,
    };
    return if (on_matched_side) .as_context else .drop;
}

/// One hunk as it goes into a patch, with the side lengths its `@@` line
/// declares.
const PatchHunk = struct {
    text: []const u8,
    old_count: u32,
    new_count: u32,

    fn whole(h: *const Hunk) PatchHunk {
        return .{ .text = h.raw_lines, .old_count = h.old_count, .new_count = h.new_count };
    }
};

/// Build a filtered hunk patch containing only selected lines, under a
/// rewritten @@ header. A selection that leaves every line where it was
/// yields the hunk unchanged.
fn buildFilteredHunkPatch(arena: Allocator, h: *const Hunk, line_spec: LineSpec, direction: ApplyDirection) !PatchHunk {
    if (std.mem.indexOfScalar(u8, h.raw_lines, '\n') == null) return .whole(h);

    var body: std.ArrayList(u8) = .empty;
    var old_count: u32 = 0;
    var new_count: u32 = 0;
    // "\ No newline at end of file" qualifies the line before it, so it goes
    // wherever that line went.
    var prev_kept = true;
    var has_changes = false;
    var altered = false;

    var lines = h.bodyLines();
    while (lines.next()) |line| {
        const number = line.number orelse {
            if (line.kind == .no_newline and prev_kept) {
                try body.appendSlice(arena, line.text);
                try body.append(arena, '\n');
            }
            continue;
        };

        const fate = lineFate(line.kind, line_spec.containsLine(number), direction);
        prev_kept = fate != .drop;
        if (fate != .keep) altered = true;
        const emitted_kind: BodyLine.Kind = switch (fate) {
            .drop => continue,
            .keep => blk: {
                try body.appendSlice(arena, line.text);
                break :blk line.kind;
            },
            .as_context => blk: {
                try body.append(arena, ' ');
                try body.appendSlice(arena, line.text[1..]);
                break :blk .context;
            },
        };
        try body.append(arena, '\n');
        if (emitted_kind != .addition) old_count += 1;
        if (emitted_kind != .removal) new_count += 1;
        if (emitted_kind != .context) has_changes = true;
    }

    if (!has_changes) {
        std.debug.print("error: no changes in selected lines of hunk {s}\n", .{h.sha_hex[0..7]});
        return error.NoSelectedLines;
    }
    if (!altered) return .whole(h);

    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(arena, "@@ -");
    try appendRange(arena, &result, filteredStart(h.old_start, h.old_count, old_count), old_count);
    try result.appendSlice(arena, " +");
    try appendRange(arena, &result, filteredStart(h.new_start, h.new_count, new_count), new_count);
    try result.appendSlice(arena, " @@");
    if (h.context.len > 0) {
        try result.append(arena, ' ');
        try result.appendSlice(arena, h.context);
    }
    try result.append(arena, '\n');
    try result.appendSlice(arena, body.items);
    return .{ .text = result.items, .old_count = old_count, .new_count = new_count };
}

/// Where a side starts once filtering has changed its length. git numbers an
/// empty side by the line before it (`-0,0` for a file that is not there),
/// so a side that gains its first line or loses its last moves by one.
fn filteredStart(start: u32, count: u32, filtered_count: u32) u32 {
    if (count == 0 and filtered_count > 0) return start + 1;
    if (count > 0 and filtered_count == 0) return start -| 1;
    return start;
}

/// One side of an `@@` line the way git writes it: the count is left out
/// when it is 1.
fn appendRange(arena: Allocator, out: *std.ArrayList(u8), start: u32, count: u32) !void {
    if (count == 1) return out.print(arena, "{d}", .{start});
    try out.print(arena, "{d},{d}", .{ start, count });
}

// ============================================================================
// Tests
// ============================================================================

const testMakeHunk = types.testMakeHunk;
const computeHunkSha = types.computeHunkSha;

test "findHunkByShaPrefix exact match" {
    const sha = computeHunkSha("a.zig", 1, "+line");
    var h = testMakeHunk("a.zig", 1, 1, 1, 1);
    h.sha_hex = sha;
    const hunks = [_]Hunk{h};
    const found = try findHunkByShaPrefix(&hunks, sha[0..7], &.{});
    try std.testing.expectEqualStrings("a.zig", found.file_path);
}

test "findHunkByShaPrefix not found" {
    const h = testMakeHunk("a.zig", 1, 1, 1, 1);
    const hunks = [_]Hunk{h};
    try std.testing.expectError(error.NotFound, findHunkByShaPrefix(&hunks, "deadbeef", &.{}));
}

test "findHunkByShaPrefix ambiguous" {
    const sha = computeHunkSha("a.zig", 1, "+line");
    var h1 = testMakeHunk("a.zig", 1, 1, 1, 1);
    h1.sha_hex = sha;
    var h2 = testMakeHunk("b.zig", 1, 1, 1, 1);
    h2.sha_hex = sha; // same SHA → same prefix
    const hunks = [_]Hunk{ h1, h2 };
    try std.testing.expectError(error.AmbiguousPrefix, findHunkByShaPrefix(&hunks, sha[0..7], &.{}));
}

test "findHunkByShaPrefix file filter excludes" {
    const sha = computeHunkSha("a.zig", 1, "+line");
    var h = testMakeHunk("a.zig", 1, 1, 1, 1);
    h.sha_hex = sha;
    const hunks = [_]Hunk{h};
    const filter = [_][]const u8{"b.zig"};
    try std.testing.expectError(error.NotFound, findHunkByShaPrefix(&hunks, sha[0..7], &filter));
}

test "findHunkByShaPrefix file filter matches" {
    const sha = computeHunkSha("a.zig", 1, "+line");
    var h = testMakeHunk("a.zig", 1, 1, 1, 1);
    h.sha_hex = sha;
    const hunks = [_]Hunk{h};
    const filter = [_][]const u8{"a.zig"};
    const found = try findHunkByShaPrefix(&hunks, sha[0..7], &filter);
    try std.testing.expectEqualStrings("a.zig", found.file_path);
}

test "findHunkByShaPrefix file filter matches any-of" {
    const sha = computeHunkSha("a.zig", 1, "+line");
    var h = testMakeHunk("a.zig", 1, 1, 1, 1);
    h.sha_hex = sha;
    const hunks = [_]Hunk{h};
    const filter = [_][]const u8{ "z.zig", "a.zig", "x.zig" };
    const found = try findHunkByShaPrefix(&hunks, sha[0..7], &filter);
    try std.testing.expectEqualStrings("a.zig", found.file_path);
}

test "buildFilteredHunkPatch select one addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 3, 1, 3);
    h.raw_lines = "@@ -1,3 +1,3 @@\n context\n-removed\n+added\n context2\n";
    const ranges = [_]LineRange{.{ .start = 3, .end = 3 }}; // select only +added
    const result = (try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges }, .forward)).text;
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
    const result = (try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges }, .forward)).text;
    // -removed stays, +added dropped
    // old: context(1) + removed(2) + context2(3) = 3
    // new: context(1) + context2(2) = 2
    try std.testing.expectEqualStrings(
        "@@ -1,3 +1,2 @@\n context\n-removed\n context2\n",
        result,
    );
}

test "buildFilteredHunkPatch reverse keeps deselected additions as context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 3, 1, 3);
    h.raw_lines = "@@ -1,3 +1,3 @@\n context\n-removed\n+added\n context2\n";
    const ranges = [_]LineRange{.{ .start = 2, .end = 2 }}; // select only -removed
    const result = (try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges }, .reverse)).text;
    // Mirror of the forward case: the reverse apply matches the NEW side against
    // the target, so +added (which the target has) must survive as context.
    // old: context(1) + removed(2) + added-as-context(3) + context2(4) = 4
    // new: context(1) + added-as-context(2) + context2(3) = 3
    try std.testing.expectEqualStrings(
        "@@ -1,4 +1,3 @@\n context\n-removed\n added\n context2\n",
        result,
    );
}

test "buildFilteredHunkPatch reverse drops deselected removals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 3, 1, 3);
    h.raw_lines = "@@ -1,3 +1,3 @@\n context\n-removed\n+added\n context2\n";
    const ranges = [_]LineRange{.{ .start = 3, .end = 3 }}; // select only +added
    const result = (try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges }, .reverse)).text;
    // -removed is absent from the target's (new-side) content, so it must be
    // dropped rather than emitted as context.
    // old: context(1) + added(2) + context2(3) = 3
    // new: context(1) + context2(2) = 2 ... plus the +added line on the new side
    try std.testing.expectEqualStrings(
        "@@ -1,2 +1,3 @@\n context\n+added\n context2\n",
        result,
    );
}

test "buildFilteredHunkPatch reverse partial select over multiple additions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 3, 1, 6);
    // The regression shape: pure insertions at default context.
    h.raw_lines = "@@ -1,3 +1,6 @@\n keep-A\n+ADD-1\n+ADD-2\n keep-B\n+ADD-3\n keep-C\n";
    const ranges = [_]LineRange{.{ .start = 2, .end = 2 }}; // select only +ADD-1
    const result = (try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges }, .reverse)).text;
    // ADD-2 and ADD-3 stay as context so the new side (6 lines) matches the
    // worktree exactly; the old side (5) is that minus the reverted ADD-1.
    try std.testing.expectEqualStrings(
        "@@ -1,5 +1,6 @@\n keep-A\n+ADD-1\n ADD-2\n keep-B\n ADD-3\n keep-C\n",
        result,
    );
}

test "buildFilteredHunkPatch selecting every change leaves the hunk as it was" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 2, 1, 2);
    h.raw_lines = "@@ -1,2 +1,2 @@ fn f()\n context\n-old\n+new\n";
    const ranges = [_]LineRange{.{ .start = 2, .end = 3 }}; // select both - and +
    for ([_]ApplyDirection{ .forward, .reverse }) |direction| {
        const result = try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges }, direction);
        try std.testing.expectEqualStrings(h.raw_lines, result.text);
    }
}

test "buildFilteredHunkPatch preserves func context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 10, 2, 10, 2);
    h.context = "fn main()";
    h.raw_lines = "@@ -10,2 +10,2 @@ fn main()\n context\n-old\n+new\n";
    const ranges = [_]LineRange{.{ .start = 3, .end = 3 }};
    const result = (try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges }, .forward)).text;
    try std.testing.expectEqualStrings("@@ -10,2 +10,3 @@ fn main()\n context\n old\n+new\n", result);
}

test "buildFilteredHunkPatch multiple changes partial select" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 5, 1, 5);
    h.raw_lines = "@@ -1,5 +1,5 @@\n ctx1\n-rem1\n+add1\n ctx2\n-rem2\n+add2\n";
    // Select only first replacement (lines 2-3), not second (lines 5-6)
    const ranges = [_]LineRange{.{ .start = 2, .end = 3 }};
    const result = (try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges }, .forward)).text;
    // rem1 kept as -, add1 kept as +, rem2 becomes context, add2 dropped
    // old: ctx1(1) + rem1(2) + ctx2(3) + rem2-as-ctx(4) = 4
    // new: ctx1(1) + add1(2) + ctx2(3) + rem2-as-ctx(4) = 4
    try std.testing.expectEqualStrings(
        "@@ -1,4 +1,4 @@\n ctx1\n-rem1\n+add1\n ctx2\n rem2\n",
        result,
    );
}

test "buildFilteredHunkPatch no-newline marker with partial select" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 2, 1, 2);
    // Hunk has two changes, second has no trailing newline
    h.raw_lines = "@@ -1,2 +1,2 @@\n-old1\n+new1\n-old2\n+new2\n\\ No newline at end of file\n";
    // Select only lines 1-2 (first pair), deselect lines 3-4 (second pair)
    const ranges = [_]LineRange{.{ .start = 1, .end = 2 }};
    const result = (try buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges }, .forward)).text;
    // old2 becomes context, new2 is dropped, "\ No newline" follows the dropped + so it's dropped too
    try std.testing.expect(std.mem.indexOf(u8, result, "\\ No newline") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-old1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "+new1") != null);
}

test "buildFilteredHunkPatch rejects a selection with no changed lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h = testMakeHunk("f.txt", 1, 3, 1, 3);
    h.raw_lines = "@@ -1,3 +1,3 @@\n context\n-removed\n+added\n context2\n";
    const ranges = [_]LineRange{.{ .start = 1, .end = 1 }}; // context only
    try std.testing.expectError(
        error.NoSelectedLines,
        buildFilteredHunkPatch(arena.allocator(), &h, .{ .ranges = &ranges }, .forward),
    );
}

test "lineFate keeps selected lines and mirrors deselected ones by direction" {
    const Row = struct { kind: BodyLine.Kind, direction: ApplyDirection, fate: LineFate };
    const deselected = [_]Row{
        .{ .kind = .removal, .direction = .forward, .fate = .as_context },
        .{ .kind = .addition, .direction = .forward, .fate = .drop },
        .{ .kind = .removal, .direction = .reverse, .fate = .drop },
        .{ .kind = .addition, .direction = .reverse, .fate = .as_context },
    };
    for (deselected) |row| {
        try std.testing.expectEqual(row.fate, lineFate(row.kind, false, row.direction));
        try std.testing.expectEqual(LineFate.keep, lineFate(row.kind, true, row.direction));
    }
    try std.testing.expectEqual(LineFate.keep, lineFate(.context, false, .forward));
    try std.testing.expectEqual(LineFate.keep, lineFate(.context, false, .reverse));
}

const typechange_delete: FileSection = .{
    .diff_git_line = "diff --git a/b.txt b/b.txt",
    .is_deleted_file = true,
    .minus_line = "--- a/b.txt",
    .plus_line = "+++ /dev/null",
};
const typechange_create: FileSection = .{
    .diff_git_line = "diff --git a/b.txt b/b.txt",
    .is_new_file = true,
    .file_mode = "120000",
    .is_symlink = true,
    .minus_line = "--- /dev/null",
    .plus_line = "+++ b/b.txt",
};

fn testModifiedSection(comptime path: []const u8) FileSection {
    return .{
        .diff_git_line = "diff --git a/" ++ path ++ " b/" ++ path,
        .minus_line = "--- a/" ++ path,
        .plus_line = "+++ b/" ++ path,
    };
}

test "buildCombinedPatches typechange splits into two patches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h1 = testMakeHunk("b.txt", 1, 1, 0, 0);
    h1.section = &typechange_delete;
    h1.raw_lines = "@@ -1 +0,0 @@\n-world\n";
    var h2 = testMakeHunk("b.txt", 0, 0, 1, 1);
    h2.section = &typechange_create;
    h2.raw_lines = "@@ -0,0 +1 @@\n+a.txt\n";
    // Sorted: deleted before new (matching matchedHunkPatchOrder)
    const matches = [_]MatchedHunk{
        .{ .hunk = &h1, .line_spec = null },
        .{ .hunk = &h2, .line_spec = null },
    };
    const patches = try buildCombinedPatches(arena.allocator(), &matches, .forward);
    try std.testing.expectEqual(@as(usize, 2), patches.len);
    try std.testing.expectEqualStrings(
        "diff --git a/b.txt b/b.txt\ndeleted file mode 100644\n--- a/b.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-world\n",
        patches[0],
    );
    try std.testing.expectEqualStrings(
        "diff --git a/b.txt b/b.txt\nnew file mode 120000\n--- /dev/null\n+++ b/b.txt\n@@ -0,0 +1 @@\n+a.txt\n",
        patches[1],
    );
}

test "buildCombinedPatches normal case returns single patch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a_section = testModifiedSection("a.txt");
    const b_section = testModifiedSection("b.txt");
    var h1 = testMakeHunk("a.txt", 1, 1, 1, 1);
    h1.section = &a_section;
    h1.raw_lines = "@@ -1 +1 @@\n-a\n+A\n";
    var h2 = testMakeHunk("b.txt", 1, 1, 1, 1);
    h2.section = &b_section;
    h2.raw_lines = "@@ -1 +1 @@\n-b\n+B\n";
    const matches = [_]MatchedHunk{
        .{ .hunk = &h1, .line_spec = null },
        .{ .hunk = &h2, .line_spec = null },
    };
    const patches = try buildCombinedPatches(arena.allocator(), &matches, .forward);
    try std.testing.expectEqual(@as(usize, 1), patches.len);
}

test "buildCombinedPatches writes one header for hunks of one section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const section = testModifiedSection("a.txt");
    var h1 = testMakeHunk("a.txt", 1, 1, 1, 1);
    h1.section = &section;
    h1.raw_lines = "@@ -1 +1 @@\n-a\n+A\n";
    var h2 = testMakeHunk("a.txt", 9, 1, 9, 1);
    h2.section = &section;
    h2.raw_lines = "@@ -9 +9 @@\n-i\n+I\n";
    const matches = [_]MatchedHunk{
        .{ .hunk = &h1, .line_spec = null },
        .{ .hunk = &h2, .line_spec = null },
    };
    const patches = try buildCombinedPatches(arena.allocator(), &matches, .forward);
    try std.testing.expectEqual(@as(usize, 1), patches.len);
    try std.testing.expectEqualStrings(
        "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+A\n@@ -9 +9 @@\n-i\n+I\n",
        patches[0],
    );
}

test "buildCombinedPatches typechange with other files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // a.txt: normal change
    const a_section = testModifiedSection("a.txt");
    var h_a = testMakeHunk("a.txt", 1, 1, 1, 1);
    h_a.section = &a_section;
    h_a.raw_lines = "@@ -1 +1 @@\n-a\n+A\n";
    // b.txt: typechange (delete + create)
    var h_del = testMakeHunk("b.txt", 1, 1, 0, 0);
    h_del.section = &typechange_delete;
    h_del.raw_lines = "@@ -1 +0,0 @@\n-world\n";
    var h_new = testMakeHunk("b.txt", 0, 0, 1, 1);
    h_new.section = &typechange_create;
    h_new.raw_lines = "@@ -0,0 +1 @@\n+a.txt\n";
    // Order: a.txt, b.txt(del), b.txt(new) — matching sort order
    const matches = [_]MatchedHunk{
        .{ .hunk = &h_a, .line_spec = null },
        .{ .hunk = &h_del, .line_spec = null },
        .{ .hunk = &h_new, .line_spec = null },
    };
    const patches = try buildCombinedPatches(arena.allocator(), &matches, .forward);
    try std.testing.expectEqual(@as(usize, 2), patches.len);
    // First patch: a.txt + b.txt deletion
    try std.testing.expect(std.mem.indexOf(u8, patches[0], "a/a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, patches[0], "deleted file") != null);
    // Second patch: b.txt creation
    try std.testing.expect(std.mem.indexOf(u8, patches[1], "new file mode 120000") != null);
}

test "sortAndBuildPatches reverse undoes a typechange's creation first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h_del = testMakeHunk("b.txt", 1, 1, 0, 0);
    h_del.section = &typechange_delete;
    h_del.raw_lines = "@@ -1 +0,0 @@\n-world\n";
    var h_new = testMakeHunk("b.txt", 0, 0, 1, 1);
    h_new.section = &typechange_create;
    h_new.raw_lines = "@@ -0,0 +1 @@\n+a.txt\n";
    // Arrival order is irrelevant: the builder sorts before building.
    var forward_in = [_]MatchedHunk{
        .{ .hunk = &h_new, .line_spec = null },
        .{ .hunk = &h_del, .line_spec = null },
    };
    var reverse_in = forward_in;

    const forward = try sortAndBuildPatches(arena.allocator(), &forward_in, .forward);
    try std.testing.expectEqual(@as(usize, 2), forward.len);
    try std.testing.expect(std.mem.indexOf(u8, forward[0], "deleted file mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, forward[1], "new file mode") != null);

    const reverse = try sortAndBuildPatches(arena.allocator(), &reverse_in, .reverse);
    try std.testing.expectEqual(@as(usize, 2), reverse.len);
    try std.testing.expect(std.mem.indexOf(u8, reverse[0], "new file mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, reverse[1], "deleted file mode") != null);
}

test "matchedHunkPatchOrder typechange sorts deleted before new" {
    var h_del = testMakeHunk("b.txt", 1, 1, 0, 0);
    h_del.section = &typechange_delete;
    var h_new = testMakeHunk("b.txt", 0, 0, 1, 1);
    h_new.section = &typechange_create;
    const m_del = MatchedHunk{ .hunk = &h_del, .line_spec = null };
    const m_new = MatchedHunk{ .hunk = &h_new, .line_spec = null };
    // Deleted should sort before new for same file
    try std.testing.expect(matchedHunkPatchOrder({}, m_del, m_new));
    try std.testing.expect(!matchedHunkPatchOrder({}, m_new, m_del));
}

test "renderSectionHeader reproduces each kind of section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Row = struct { section: FileSection, want: []const u8 };
    const rows = [_]Row{
        .{
            .section = .{
                .diff_git_line = "diff --git a/old.txt b/new.txt",
                .rename_from = "old.txt",
                .rename_to = "new.txt",
                .index_line = "index 1234567..89abcde 100644",
                .minus_line = "--- a/old.txt",
                .plus_line = "+++ b/new.txt",
            },
            .want = "diff --git a/old.txt b/new.txt\nrename from old.txt\nrename to new.txt\n" ++
                "index 1234567..89abcde 100644\n--- a/old.txt\n+++ b/new.txt\n",
        },
        .{
            .section = .{
                .diff_git_line = "diff --git a/img.png b/img.png",
                .is_new_file = true,
                .index_line = "index 0000000..89abcde",
                .is_binary = true,
            },
            .want = "diff --git a/img.png b/img.png\nnew file mode 100644\nindex 0000000..89abcde\n",
        },
        .{
            .section = .{
                .diff_git_line = "diff --git a/f.txt b/f.txt",
                .is_new_file = true,
                .index_line = "index 0000000..e69de29",
            },
            .want = "diff --git a/f.txt b/f.txt\nnew file mode 100644\nindex 0000000..e69de29\n",
        },
        .{
            .section = .{
                .diff_git_line = "diff --git a/f.txt b/f.txt",
                .is_deleted_file = true,
                .index_line = "index e69de29..0000000",
            },
            .want = "diff --git a/f.txt b/f.txt\ndeleted file mode 100644\nindex e69de29..0000000\n",
        },
    };
    for (rows) |row| {
        try std.testing.expectEqualStrings(row.want, try renderSectionHeader(arena.allocator(), &row.section));
    }
}

/// One file section and hunk, filtered and rendered as a whole patch.
const WholeFileCase = struct {
    section: FileSection,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    raw_lines: []const u8,

    fn render(self: *const WholeFileCase, arena: Allocator, ranges: []const LineRange, direction: ApplyDirection) ![]const u8 {
        var h = testMakeHunk("n.txt", self.old_start, self.old_count, self.new_start, self.new_count);
        h.section = &self.section;
        h.raw_lines = self.raw_lines;
        const matches = [_]MatchedHunk{.{ .hunk = &h, .line_spec = .{ .ranges = ranges } }};
        const patches = try buildCombinedPatches(arena, &matches, direction);
        try std.testing.expectEqual(@as(usize, 1), patches.len);
        return patches[0];
    }
};

const new_file_case: WholeFileCase = .{
    .section = .{
        .diff_git_line = "diff --git a/n.txt b/n.txt",
        .is_new_file = true,
        .index_line = "index 0000000..de98044",
        .minus_line = "--- /dev/null",
        .plus_line = "+++ b/n.txt",
    },
    .old_start = 0,
    .old_count = 0,
    .new_start = 1,
    .new_count = 3,
    .raw_lines = "@@ -0,0 +1,3 @@\n+a\n+b\n+c\n",
};
const deleted_file_case: WholeFileCase = .{
    .section = .{
        .diff_git_line = "diff --git a/n.txt b/n.txt",
        .is_deleted_file = true,
        .index_line = "index de98044..0000000",
        .minus_line = "--- a/n.txt",
        .plus_line = "+++ /dev/null",
    },
    .old_start = 1,
    .old_count = 3,
    .new_start = 0,
    .new_count = 0,
    .raw_lines = "@@ -1,3 +0,0 @@\n-a\n-b\n-c\n",
};
const shrink_to_one_case: WholeFileCase = .{
    .section = .{
        .diff_git_line = "diff --git a/n.txt b/n.txt",
        .index_line = "index de98044..587be6b 100644",
        .minus_line = "--- a/n.txt",
        .plus_line = "+++ b/n.txt",
    },
    .old_start = 1,
    .old_count = 3,
    .new_start = 1,
    .new_count = 1,
    .raw_lines = "@@ -1,3 +1 @@\n-a\n-b\n-c\n+x\n",
};
const zero_context_insertion_case: WholeFileCase = .{
    .section = .{
        .diff_git_line = "diff --git a/n.txt b/n.txt",
        .index_line = "index de98044..9d6d6a3 100644",
        .minus_line = "--- a/n.txt",
        .plus_line = "+++ b/n.txt",
    },
    .old_start = 3,
    .old_count = 0,
    .new_start = 4,
    .new_count = 2,
    .raw_lines = "@@ -3,0 +4,2 @@\n+p\n+q\n",
};

test "line specs on whole-file hunks render the header of the patch applied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Row = struct {
        case: *const WholeFileCase,
        ranges: []const LineRange,
        direction: ApplyDirection,
        /// Null: the selection leaves the hunk whole, so the patch is the
        /// source's own, byte for byte.
        want: ?[]const u8,
    };
    const all_three = &[_]LineRange{.{ .start = 1, .end = 3 }};
    const second = &[_]LineRange{.{ .start = 2, .end = 2 }};
    const rows = [_]Row{
        // A new file keeps being created forward; reverse, the deselected
        // lines stay behind as an existing file.
        .{ .case = &new_file_case, .ranges = all_three, .direction = .forward, .want = null },
        .{ .case = &new_file_case, .ranges = all_three, .direction = .reverse, .want = null },
        .{
            .case = &new_file_case,
            .ranges = second,
            .direction = .forward,
            .want = "diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0000000..de98044\n" ++
                "--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+b\n",
        },
        .{
            .case = &new_file_case,
            .ranges = second,
            .direction = .reverse,
            .want = "diff --git a/n.txt b/n.txt\nindex 0000000..de98044\n" ++
                "--- a/n.txt\n+++ b/n.txt\n@@ -1,2 +1,3 @@\n a\n+b\n c\n",
        },
        // The mirror image for a deletion.
        .{ .case = &deleted_file_case, .ranges = all_three, .direction = .forward, .want = null },
        .{ .case = &deleted_file_case, .ranges = all_three, .direction = .reverse, .want = null },
        .{
            .case = &deleted_file_case,
            .ranges = second,
            .direction = .forward,
            .want = "diff --git a/n.txt b/n.txt\nindex de98044..0000000\n" ++
                "--- a/n.txt\n+++ b/n.txt\n@@ -1,3 +1,2 @@\n a\n-b\n c\n",
        },
        .{
            .case = &deleted_file_case,
            .ranges = second,
            .direction = .reverse,
            .want = "diff --git a/n.txt b/n.txt\ndeleted file mode 100644\nindex de98044..0000000\n" ++
                "--- a/n.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-b\n",
        },
        // Emptying a side of a modification leaves an empty file, never a
        // deletion or a creation.
        .{ .case = &shrink_to_one_case, .ranges = &.{.{ .start = 1, .end = 4 }}, .direction = .forward, .want = null },
        .{ .case = &shrink_to_one_case, .ranges = &.{.{ .start = 1, .end = 4 }}, .direction = .reverse, .want = null },
        .{
            .case = &shrink_to_one_case,
            .ranges = all_three,
            .direction = .forward,
            .want = "diff --git a/n.txt b/n.txt\nindex de98044..587be6b 100644\n" ++
                "--- a/n.txt\n+++ b/n.txt\n@@ -1,3 +0,0 @@\n-a\n-b\n-c\n",
        },
        .{
            .case = &shrink_to_one_case,
            .ranges = &.{.{ .start = 4, .end = 4 }},
            .direction = .reverse,
            .want = "diff --git a/n.txt b/n.txt\nindex de98044..587be6b 100644\n" ++
                "--- a/n.txt\n+++ b/n.txt\n@@ -0,0 +1 @@\n+x\n",
        },
        // Without context, a side that gains a line moves to it.
        .{ .case = &zero_context_insertion_case, .ranges = &.{.{ .start = 1, .end = 2 }}, .direction = .forward, .want = null },
        .{ .case = &zero_context_insertion_case, .ranges = &.{.{ .start = 1, .end = 2 }}, .direction = .reverse, .want = null },
        .{
            .case = &zero_context_insertion_case,
            .ranges = &.{.{ .start = 1, .end = 1 }},
            .direction = .forward,
            .want = "diff --git a/n.txt b/n.txt\nindex de98044..9d6d6a3 100644\n" ++
                "--- a/n.txt\n+++ b/n.txt\n@@ -3,0 +4 @@\n+p\n",
        },
        .{
            .case = &zero_context_insertion_case,
            .ranges = &.{.{ .start = 1, .end = 1 }},
            .direction = .reverse,
            .want = "diff --git a/n.txt b/n.txt\nindex de98044..9d6d6a3 100644\n" ++
                "--- a/n.txt\n+++ b/n.txt\n@@ -4 +4,2 @@\n+p\n q\n",
        },
    };
    for (rows) |row| {
        const got = try row.case.render(arena.allocator(), row.ranges, row.direction);
        const want = row.want orelse try std.mem.concat(arena.allocator(), u8, &.{
            try renderSectionHeader(arena.allocator(), &row.case.section),
            row.case.raw_lines,
        });
        try std.testing.expectEqualStrings(want, got);
    }
}

test "a deselected last line takes its no-newline marker with it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var case = new_file_case;
    case.new_count = 2;
    case.raw_lines = "@@ -0,0 +1,2 @@\n+a\n+b\n\\ No newline at end of file\n";
    const first = &[_]LineRange{.{ .start = 1, .end = 1 }};
    try std.testing.expectEqualStrings(
        "diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0000000..de98044\n" ++
            "--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+a\n",
        try case.render(arena.allocator(), first, .forward),
    );
    try std.testing.expectEqualStrings(
        "diff --git a/n.txt b/n.txt\nindex 0000000..de98044\n" ++
            "--- a/n.txt\n+++ b/n.txt\n@@ -1 +1,2 @@\n+a\n b\n\\ No newline at end of file\n",
        try case.render(arena.allocator(), first, .reverse),
    );
}

test "a derived ---/+++ line keeps git's quoting of the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var created = new_file_case;
    created.section.diff_git_line = "diff --git \"a/h\\303\\251llo.txt\" \"b/h\\303\\251llo.txt\"";
    created.section.plus_line = "+++ \"b/h\\303\\251llo.txt\"";
    const second = &[_]LineRange{.{ .start = 2, .end = 2 }};
    const reverse = try created.render(arena.allocator(), second, .reverse);
    try std.testing.expect(std.mem.indexOf(u8, reverse, "\n--- \"a/h\\303\\251llo.txt\"\n+++ \"b/h\\303\\251llo.txt\"\n") != null);

    var deleted = deleted_file_case;
    deleted.section.minus_line = "--- \"a/h\\303\\251llo.txt\"";
    const forward = try deleted.render(arena.allocator(), second, .forward);
    try std.testing.expect(std.mem.indexOf(u8, forward, "\n--- \"a/h\\303\\251llo.txt\"\n+++ \"b/h\\303\\251llo.txt\"\n") != null);
}

const binary_section: FileSection = .{ .is_binary = true };
const untracked_text_section: FileSection = .{ .is_untracked = true };
const untracked_binary_section: FileSection = .{ .is_binary = true, .is_untracked = true };

test "partitionByKind empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try partitionByKind(arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 0), p.tracked_text.len);
    try std.testing.expectEqual(@as(usize, 0), p.tracked_binary.len);
    try std.testing.expectEqual(@as(usize, 0), p.untracked_text.len);
    try std.testing.expectEqual(@as(usize, 0), p.untracked_binary.len);
    const all_bin = try p.allBinaryPaths(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), all_bin.len);
}

test "partitionByKind sorts into 4 buckets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ht = testMakeHunk("a.txt", 1, 1, 1, 1);
    var hb = testMakeHunk("b.png", 1, 1, 1, 1);
    hb.section = &binary_section;
    var hut = testMakeHunk("u.txt", 1, 1, 1, 1);
    hut.section = &untracked_text_section;
    var hub = testMakeHunk("u.png", 1, 1, 1, 1);
    hub.section = &untracked_binary_section;
    const matches = [_]MatchedHunk{
        .{ .hunk = &ht, .line_spec = null },
        .{ .hunk = &hb, .line_spec = null },
        .{ .hunk = &hut, .line_spec = null },
        .{ .hunk = &hub, .line_spec = null },
    };
    const p = try partitionByKind(arena.allocator(), &matches);
    try std.testing.expectEqual(@as(usize, 1), p.tracked_text.len);
    try std.testing.expectEqual(@as(usize, 1), p.tracked_binary.len);
    try std.testing.expectEqual(@as(usize, 1), p.untracked_text.len);
    try std.testing.expectEqual(@as(usize, 1), p.untracked_binary.len);
    try std.testing.expectEqualStrings("a.txt", p.tracked_text[0].hunk.file_path);
    try std.testing.expectEqualStrings("b.png", p.tracked_binary[0].hunk.file_path);
    try std.testing.expectEqualStrings("u.txt", p.untracked_text[0].hunk.file_path);
    try std.testing.expectEqualStrings("u.png", p.untracked_binary[0].hunk.file_path);
}

test "partitionByKind dedups paths with multiple hunks per file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h1 = testMakeHunk("img.png", 1, 1, 1, 1);
    h1.section = &binary_section;
    var h2 = testMakeHunk("img.png", 5, 1, 5, 1);
    h2.section = &binary_section;
    const matches = [_]MatchedHunk{
        .{ .hunk = &h1, .line_spec = null },
        .{ .hunk = &h2, .line_spec = null },
    };
    const p = try partitionByKind(arena.allocator(), &matches);
    try std.testing.expectEqual(@as(usize, 2), p.tracked_binary.len);
    try std.testing.expectEqual(@as(usize, 1), p.tracked_binary_paths.len);
    const all_bin = try p.allBinaryPaths(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), all_bin.len);
    try std.testing.expectEqualStrings("img.png", all_bin[0]);
}

test "partitionByKind allBinaryPaths combines tracked + untracked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ht = testMakeHunk("a.png", 1, 1, 1, 1);
    ht.section = &binary_section;
    var hu = testMakeHunk("b.png", 1, 1, 1, 1);
    hu.section = &untracked_binary_section;
    const matches = [_]MatchedHunk{
        .{ .hunk = &ht, .line_spec = null },
        .{ .hunk = &hu, .line_spec = null },
    };
    const p = try partitionByKind(arena.allocator(), &matches);
    try std.testing.expectEqual(@as(usize, 1), p.tracked_binary_paths.len);
    try std.testing.expectEqual(@as(usize, 1), p.untracked_binary_paths.len);
    const all_bin = try p.allBinaryPaths(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), all_bin.len);
}

test "collectResultPaths adds a rename's old path once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rename_section: types.FileSection = .{ .renamed_from_path = "old.txt" };
    var first = types.testMakeHunk("new.txt", 1, 1, 1, 1);
    first.section = &rename_section;
    var second = types.testMakeHunk("new.txt", 9, 1, 9, 1);
    second.section = &rename_section;
    const other = types.testMakeHunk("other.txt", 1, 1, 1, 1);

    const matched = [_]MatchedHunk{
        .{ .hunk = &first, .line_spec = null },
        .{ .hunk = &other, .line_spec = null },
        .{ .hunk = &second, .line_spec = null },
    };
    const paths = try collectResultPaths(arena, &matched);
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    try std.testing.expectEqualStrings("new.txt", paths[0]);
    try std.testing.expectEqualStrings("other.txt", paths[1]);
    try std.testing.expectEqualStrings("old.txt", paths[2]);
}
