const std = @import("std");

pub const Hunk = struct {
    file_path: []const u8,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    /// Function context from @@ line (text after closing @@), or empty.
    context: []const u8,
    /// The @@ header line plus all body lines, as a slice into the diff buffer.
    raw_lines: []const u8,
    /// Only the +/- lines (and "\ No newline" markers), joined by \n.
    diff_lines: []const u8,
    /// SHA1 hex digest (full 40 chars). Display truncates to 7.
    sha_hex: [40]u8,
    is_new_file: bool,
    is_deleted_file: bool,
    is_untracked: bool,
    /// Patch header for applying: ---/+++ lines (and diff --git + mode for new/deleted).
    patch_header: []const u8,
};

pub const LineRange = struct {
    start: u32, // 1-based, inclusive
    end: u32, // 1-based, inclusive
};

pub const LineSpec = struct {
    ranges: []const LineRange,

    pub fn containsLine(self: LineSpec, line: u32) bool {
        for (self.ranges) |r| {
            if (line >= r.start and line <= r.end) return true;
        }
        return false;
    }
};

pub const ShaArg = struct {
    prefix: []const u8,
    line_spec: ?LineSpec, // null = whole hunk
};

pub const MatchedHunk = struct {
    hunk: *const Hunk,
    line_spec: ?LineSpec,
};

pub const DiffMode = enum { unstaged, staged };

pub const DiffFilter = enum { all, tracked_only, untracked_only };

pub const OutputMode = enum { human, porcelain };

pub const ListOptions = struct {
    mode: DiffMode = .unstaged,
    diff_filter: DiffFilter = .all,
    file_filter: ?[]const u8 = null,
    output: OutputMode = .human,
    oneline: bool = false,
    no_color: bool = false,
    context: ?u32 = null,
};

pub const AddResetOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    diff_filter: DiffFilter = .all,
    file_filter: ?[]const u8 = null,
    select_all: bool = false,
    verbose: bool = false,
    output: OutputMode = .human,
    no_color: bool = false,
    context: ?u32 = null,
};

pub const DiffOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    diff_filter: DiffFilter = .all,
    file_filter: ?[]const u8 = null,
    mode: DiffMode = .unstaged,
    output: OutputMode = .human,
    no_color: bool = false,
    context: ?u32 = null,
};

pub const CountOptions = struct {
    mode: DiffMode = .unstaged,
    diff_filter: DiffFilter = .all,
    file_filter: ?[]const u8 = null,
    context: ?u32 = null,
};

pub const CheckOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    diff_filter: DiffFilter = .all,
    file_filter: ?[]const u8 = null,
    mode: DiffMode = .unstaged,
    exclusive: bool = false,
    output: OutputMode = .human,
    no_color: bool = false,
    context: ?u32 = null,
};

pub const RestoreOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    diff_filter: DiffFilter = .all,
    file_filter: ?[]const u8 = null,
    select_all: bool = false,
    dry_run: bool = false,
    force: bool = false,
    output: OutputMode = .human,
    no_color: bool = false,
    context: ?u32 = null,
};

pub const StashOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    diff_filter: DiffFilter = .all,
    file_filter: ?[]const u8 = null,
    select_all: bool = false,
    pop: bool = false,
    include_untracked: bool = false,
    message: ?[]const u8 = null,
    verbose: bool = false,
    output: OutputMode = .human,
    no_color: bool = false,
    context: ?u32 = null,
};

/// Check whether two line ranges overlap (treating count=0 as spanning 1 line).
pub fn rangesOverlap(a_start: u32, a_count: u32, b_start: u32, b_count: u32) bool {
    const a_end = a_start + @max(a_count, 1) - 1;
    const b_end = b_start + @max(b_count, 1) - 1;
    return a_start <= b_end and b_start <= a_end;
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", args);
    std.process.exit(1);
}

pub fn testMakeHunk(file_path: []const u8, old_start: u32, old_count: u32, new_start: u32, new_count: u32) Hunk {
    return .{
        .file_path = file_path,
        .old_start = old_start,
        .old_count = old_count,
        .new_start = new_start,
        .new_count = new_count,
        .context = "",
        .raw_lines = "",
        .diff_lines = "+line",
        .sha_hex = [_]u8{0} ** 40,
        .is_new_file = false,
        .is_deleted_file = false,
        .is_untracked = false,
        .patch_header = "",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "rangesOverlap basic cases" {
    // Overlapping ranges
    try std.testing.expect(rangesOverlap(1, 5, 3, 5)); // [1,5] ∩ [3,7]
    try std.testing.expect(rangesOverlap(3, 5, 1, 5)); // symmetric
    try std.testing.expect(rangesOverlap(10, 5, 12, 5)); // [10,14] vs [12,16]
    try std.testing.expect(rangesOverlap(12, 5, 10, 5)); // symmetric

    // Adjacent (touching) ranges do NOT overlap
    try std.testing.expect(!rangesOverlap(1, 3, 4, 3)); // [1,3] and [4,6]
    try std.testing.expect(!rangesOverlap(10, 5, 15, 5)); // [10,14] vs [15,19]

    // Non-overlapping ranges
    try std.testing.expect(!rangesOverlap(1, 3, 5, 3)); // [1,3] and [5,7]
    try std.testing.expect(!rangesOverlap(5, 3, 1, 3)); // symmetric
    try std.testing.expect(!rangesOverlap(10, 5, 20, 5)); // [10,14] vs [20,24]

    // Contained range
    try std.testing.expect(rangesOverlap(10, 10, 12, 3)); // [10,19] vs [12,14]

    // Same range
    try std.testing.expect(rangesOverlap(10, 5, 10, 5));

    // Single-line ranges
    try std.testing.expect(rangesOverlap(10, 1, 10, 1));
    try std.testing.expect(!rangesOverlap(10, 1, 11, 1));
}

test "rangesOverlap zero count (pure insertion/deletion)" {
    // count=0 is treated as spanning 1 line at start
    try std.testing.expect(rangesOverlap(5, 0, 5, 1)); // [5,5] ∩ [5,5]
    try std.testing.expect(rangesOverlap(10, 0, 10, 5)); // insertion at 10 vs [10,14]
    try std.testing.expect(rangesOverlap(10, 5, 10, 0)); // symmetric
    try std.testing.expect(!rangesOverlap(5, 0, 6, 1)); // [5,5] and [6,6]
    try std.testing.expect(!rangesOverlap(10, 0, 11, 5)); // insertion at 10 vs [11,15]
}

test "LineSpec.containsLine single range" {
    const ranges = [_]LineRange{.{ .start = 3, .end = 7 }};
    const spec = LineSpec{ .ranges = &ranges };
    try std.testing.expect(!spec.containsLine(2));
    try std.testing.expect(spec.containsLine(3));
    try std.testing.expect(spec.containsLine(5));
    try std.testing.expect(spec.containsLine(7));
    try std.testing.expect(!spec.containsLine(8));
}

test "LineSpec.containsLine multiple ranges" {
    const ranges = [_]LineRange{
        .{ .start = 1, .end = 3 },
        .{ .start = 7, .end = 7 },
    };
    const spec = LineSpec{ .ranges = &ranges };
    try std.testing.expect(spec.containsLine(1));
    try std.testing.expect(spec.containsLine(3));
    try std.testing.expect(!spec.containsLine(4));
    try std.testing.expect(spec.containsLine(7));
    try std.testing.expect(!spec.containsLine(8));
}
