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

pub const OutputMode = enum { human, porcelain };

pub const ListOptions = struct {
    mode: DiffMode = .unstaged,
    file_filter: ?[]const u8 = null,
    output: OutputMode = .human,
    oneline: bool = false,
    no_color: bool = false,
    context: ?u32 = null,
};

pub const AddRemoveOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    file_filter: ?[]const u8 = null,
    select_all: bool = false,
    context: ?u32 = null,
};

pub const ShowOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    file_filter: ?[]const u8 = null,
    mode: DiffMode = .unstaged,
    output: OutputMode = .human,
    no_color: bool = false,
    context: ?u32 = null,
};

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
        .patch_header = "",
    };
}

// ============================================================================
// Tests
// ============================================================================

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
