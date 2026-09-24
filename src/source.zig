//! Where a command's hunks come from. `--staged` and `--ref` choose a diff
//! source once, while parsing; everything that depends on that choice (the
//! git diff arguments, which side of the diff anchors a hash, whether
//! untracked files join in) asks the source instead of re-deriving it.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The side of a diff whose line numbers identify a hunk: the side a command
/// leaves alone, so a hash survives changes made on the other.
pub const Anchor = enum { old, new };

/// A revision as the user typed it: git resolves it, and messages quote it back.
pub const Ref = struct { text: []const u8 };

/// Two revisions joined by `..` or `...`, which git diff reads itself.
pub const Range = struct {
    /// As typed, e.g. `main..HEAD` or `A...B`.
    text: []const u8,
    /// Either side may be empty, which git reads as HEAD.
    from: []const u8,
    to: []const u8,
};

/// One commit's own changes.
pub const Rev = struct {
    ref: Ref,
    /// What the commit is compared with: its first parent, or the empty tree
    /// for a root commit. Finding it runs git, so it is filled in after parsing.
    base: ?[]const u8 = null,
};

pub const StagedRangeError = error{StagedRange};

pub const DiffSource = union(enum) {
    /// Index to worktree: `git diff`.
    worktree,
    /// HEAD to index: `git diff --cached`.
    index,
    /// A commit to the index: `git diff --cached <ref>`.
    index_against: Ref,
    /// A commit's own changes: `git diff <base> <ref>`.
    rev: Rev,
    /// `git diff A..B` or `git diff A...B`.
    range: Range,

    /// The source a command reads given `--ref` and `--staged`. `default` is
    /// the command's own source when neither is given. A range names two
    /// commits while --staged compares the index with one, so they conflict.
    pub fn fromFlags(ref: ?[]const u8, staged: bool, default: DiffSource) StagedRangeError!DiffSource {
        const text = ref orelse return if (staged) .index else default;
        if (parseRange(text)) |range| {
            if (staged) return error.StagedRange;
            return .{ .range = range };
        }
        if (staged) return .{ .index_against = .{ .text = text } };
        return .{ .rev = .{ .ref = .{ .text = text } } };
    }

    pub fn anchor(self: DiffSource) Anchor {
        return switch (self) {
            .index, .index_against => .old,
            .worktree, .rev, .range => .new,
        };
    }

    /// Untracked files are part of the index-to-worktree diff only.
    pub fn includesUntracked(self: DiffSource) bool {
        return self == .worktree;
    }

    /// The revisions as the user typed them; null for the default diffs.
    pub fn refText(self: DiffSource) ?[]const u8 {
        return switch (self) {
            .worktree, .index => null,
            .index_against => |ref| ref.text,
            .rev => |rev| rev.ref.text,
            .range => |range| range.text,
        };
    }

    /// What the source's hunks are, naming any ref as typed; messages print
    /// it after "no" when there are none.
    pub fn describe(self: DiffSource) std.fmt.Alt(DiffSource, writeDescription) {
        return .{ .data = self };
    }

    fn writeDescription(self: DiffSource, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .worktree => try w.writeAll("unstaged changes"),
            .index => try w.writeAll("staged changes"),
            .index_against => |ref| try w.print("staged changes relative to '{s}'", .{ref.text}),
            .rev => |rev| try w.print("changes in '{s}'", .{rev.ref.text}),
            .range => |range| try w.print("changes in '{s}'", .{range.text}),
        }
    }

    /// Append the `git diff` arguments that select this source.
    pub fn appendDiffArgs(self: DiffSource, allocator: Allocator, argv: *std.ArrayList([]const u8)) !void {
        switch (self) {
            .worktree => {},
            .index => try argv.append(allocator, "--cached"),
            .index_against => |ref| try argv.appendSlice(allocator, &.{ "--cached", ref.text }),
            .rev => |rev| try argv.appendSlice(allocator, &.{ rev.base.?, rev.ref.text }),
            .range => |range| try argv.append(allocator, range.text),
        }
    }
};

/// Split `text` at its first `..` or `...`; null for a single revision.
fn parseRange(text: []const u8) ?Range {
    const dots = std.mem.indexOf(u8, text, "..") orelse return null;
    const to_start = if (std.mem.startsWith(u8, text[dots..], "...")) dots + 3 else dots + 2;
    return .{ .text = text, .from = text[0..dots], .to = text[to_start..] };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "fromFlags: no ref keeps the command's default, or the index with --staged" {
    try testing.expectEqual(DiffSource.worktree, try DiffSource.fromFlags(null, false, .worktree));
    try testing.expectEqual(DiffSource.index, try DiffSource.fromFlags(null, false, .index));
    try testing.expectEqual(DiffSource.index, try DiffSource.fromFlags(null, true, .worktree));
}

test "fromFlags: a single ref is that commit's changes, or the index against it with --staged" {
    const rev = try DiffSource.fromFlags("HEAD~1", false, .index);
    try testing.expectEqualStrings("HEAD~1", rev.rev.ref.text);
    try testing.expectEqual(@as(?[]const u8, null), rev.rev.base);

    const against = try DiffSource.fromFlags("main", true, .worktree);
    try testing.expectEqualStrings("main", against.index_against.text);
}

test "fromFlags: a range splits into its sides and keeps the text as typed" {
    const cases = [_]struct { text: []const u8, from: []const u8, to: []const u8 }{
        .{ .text = "main..HEAD", .from = "main", .to = "HEAD" },
        .{ .text = "A...B", .from = "A", .to = "B" },
        .{ .text = "main..", .from = "main", .to = "" },
        .{ .text = "...side", .from = "", .to = "side" },
    };
    for (cases) |case| {
        const source = try DiffSource.fromFlags(case.text, false, .worktree);
        try testing.expectEqualStrings(case.text, source.range.text);
        try testing.expectEqualStrings(case.from, source.range.from);
        try testing.expectEqualStrings(case.to, source.range.to);
    }
}

test "fromFlags: a range with --staged is rejected" {
    try testing.expectError(error.StagedRange, DiffSource.fromFlags("main..HEAD", true, .worktree));
    try testing.expectError(error.StagedRange, DiffSource.fromFlags("A...B", true, .worktree));
}

const sample_sources = [_]DiffSource{
    .worktree,
    .index,
    .{ .index_against = .{ .text = "X" } },
    .{ .rev = .{ .ref = .{ .text = "X" }, .base = "X^" } },
    .{ .range = .{ .text = "A..B", .from = "A", .to = "B" } },
};

test "anchor: index sources anchor on the old side, the rest on the new" {
    const want = [_]Anchor{ .new, .old, .old, .new, .new };
    for (sample_sources, want) |source, anchor| {
        try testing.expectEqual(anchor, source.anchor());
    }
}

test "includesUntracked: only the worktree source" {
    const want = [_]bool{ true, false, false, false, false };
    for (sample_sources, want) |source, includes| {
        try testing.expectEqual(includes, source.includesUntracked());
    }
}

test "describe: names the ref as typed" {
    const want = [_][]const u8{
        "unstaged changes",
        "staged changes",
        "staged changes relative to 'X'",
        "changes in 'X'",
        "changes in 'A..B'",
    };
    for (sample_sources, want) |source, text| {
        const got = try std.fmt.allocPrint(testing.allocator, "{f}", .{source.describe()});
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(text, got);
    }
}

test "refText: the ref as typed, never the resolved base" {
    const want = [_]?[]const u8{ null, null, "X", "X", "A..B" };
    for (sample_sources, want) |source, text| {
        if (text) |t| try testing.expectEqualStrings(t, source.refText().?) else try testing.expect(source.refText() == null);
    }
}

test "appendDiffArgs: the git diff arguments for each source" {
    const want = [_][]const []const u8{
        &.{},
        &.{"--cached"},
        &.{ "--cached", "X" },
        &.{ "X^", "X" },
        &.{"A..B"},
    };
    for (sample_sources, want) |source, args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try source.appendDiffArgs(testing.allocator, &argv);
        try testing.expectEqual(args.len, argv.items.len);
        for (args, argv.items) |a, b| try testing.expectEqualStrings(a, b);
    }
}
