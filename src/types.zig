const std = @import("std");
const source_mod = @import("source.zig");

var g_io: ?std.Io = null;
var g_env_map: ?*const std.process.Environ.Map = null;

/// Set the process-wide Io implementation. Must be called once at startup
/// before any subprocess or filesystem call. Callable across all modules
/// to avoid threading `io: Io` through every helper signature.
pub fn setIo(io: std.Io) void {
    g_io = io;
}

/// Returns the process-wide Io implementation set by `setIo`.
pub fn getIo() std.Io {
    return g_io.?;
}

pub fn getIoOrNull() ?std.Io {
    return g_io;
}

var g_repo_prefix: []const u8 = "";

/// Record where the user invoked us from, as a repo-root-relative prefix
/// ("" at the root). Set once at startup, right after the chdir to the repo
/// root, so later code can still interpret paths the user typed as
/// cwd-relative even though the process has since moved.
pub fn setRepoPrefix(prefix: []const u8) void {
    g_repo_prefix = prefix;
}

pub fn getRepoPrefix() []const u8 {
    return g_repo_prefix;
}

/// Set the process-wide environment map. Must be called once at startup.
pub fn setEnvMap(env: *const std.process.Environ.Map) void {
    g_env_map = env;
}

/// Returns the process-wide environment map set by `setEnvMap`.
pub fn getEnvMap() *const std.process.Environ.Map {
    return g_env_map.?;
}

/// Look up an environment variable through the process-wide env map. Returns
/// null if the variable is unset or if `setEnvMap` was never called.
pub fn getEnv(name: []const u8) ?[]const u8 {
    const m = g_env_map orelse return null;
    return m.get(name);
}

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
    /// The file section this hunk was parsed from, shared with its siblings.
    section: *const FileSection,

    pub fn bodyLines(self: *const Hunk) BodyLineIterator {
        return .init(self.raw_lines);
    }
};

/// What a diff says about one file as a whole, shared by every hunk parsed
/// from its section. Patch headers are rendered from it when a patch is built,
/// so they can describe the patch actually applied rather than the diff read.
pub const FileSection = struct {
    /// Verbatim `diff --git` line.
    diff_git_line: []const u8 = "diff --git a/f b/f",
    /// The old side is absent: the section creates the file.
    is_new_file: bool = false,
    /// The new side is absent: the section deletes the file.
    is_deleted_file: bool = false,
    /// Mode from the `new file mode`/`deleted file mode` line.
    file_mode: []const u8 = "100644",
    /// Verbatim values of the `rename from`/`rename to` lines.
    rename_from: ?[]const u8 = null,
    rename_to: ?[]const u8 = null,
    /// The path a rename moved the file from, unquoted. The section's hunks
    /// carry the path it moved to.
    renamed_from_path: ?[]const u8 = null,
    /// Verbatim `index` line, kept rather than re-rendered: `git apply --3way`
    /// needs its blob ids exactly as git wrote them.
    index_line: ?[]const u8 = null,
    /// Verbatim `---`/`+++` lines; null where git printed none (a binary or
    /// empty file).
    minus_line: ?[]const u8 = null,
    plus_line: ?[]const u8 = null,
    is_binary: bool = false,
    is_symlink: bool = false,
    /// One half of a typechange: git lists the path twice, deleted as one
    /// type and created as the other.
    is_typechange: bool = false,
    /// From `git diff --no-index` against an untracked file.
    is_untracked: bool = false,
};

/// One line of a hunk body, numbered the way line specs address it.
pub const BodyLine = struct {
    kind: Kind,
    text: []const u8,
    /// 1-based position among the context/removal/addition lines; null for
    /// lines a line spec cannot select.
    number: ?u32,

    pub const Kind = enum {
        /// Includes an empty line: git strips the leading space from blank
        /// context lines under some configurations.
        context,
        removal,
        addition,
        /// "\ No newline at end of file", which qualifies the line before it.
        no_newline,
        other,

        pub fn of(text: []const u8) Kind {
            if (text.len == 0) return .context;
            return switch (text[0]) {
                ' ' => .context,
                '-' => .removal,
                '+' => .addition,
                '\\' => .no_newline,
                else => .other,
            };
        }
    };
};

/// Walks the body of a hunk's `raw_lines`, numbering lines the way every
/// line-spec consumer must: `diff -n` shows these numbers, and selection,
/// patch filtering and HEAD matching all interpret a line spec through them.
pub const BodyLineIterator = struct {
    /// The `@@` line, without its newline.
    header: []const u8,
    rest: []const u8,
    next_number: u32 = 1,

    pub fn init(raw_lines: []const u8) BodyLineIterator {
        const nl = std.mem.indexOfScalar(u8, raw_lines, '\n') orelse
            return .{ .header = raw_lines, .rest = "" };
        return .{ .header = raw_lines[0..nl], .rest = raw_lines[nl + 1 ..] };
    }

    /// A trailing newline ends the last line rather than starting an empty one.
    pub fn next(self: *BodyLineIterator) ?BodyLine {
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
        const text = self.rest[0..end];
        self.rest = if (end < self.rest.len) self.rest[end + 1 ..] else "";

        const kind = BodyLine.Kind.of(text);
        const number: ?u32 = switch (kind) {
            .context, .removal, .addition => self.next_number,
            .no_newline, .other => null,
        };
        if (number != null) self.next_number += 1;
        return .{ .kind = kind, .text = text, .number = number };
    }
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

pub const DiffSource = source_mod.DiffSource;
pub const Anchor = source_mod.Anchor;

pub const DiffFilter = enum { all, tracked_only, untracked_only };

pub const OutputMode = enum { human, porcelain };

pub const Verbosity = enum { quiet, normal, verbose };

/// Flags every subcommand parses through the same code path. A command that
/// has no use for one (count's output mode, stash's ref) still accepts it
/// here and decides for itself whether to ignore or reject it.
pub const Common = struct {
    diff_filter: DiffFilter = .all,
    /// Owned, repo-relative paths. Owned rather than borrowed from argv because
    /// `--files-from` synthesises paths from file contents, which do not
    /// outlive the read buffer.
    file_filter: std.ArrayList([]const u8) = .empty,
    /// Chosen by the parser from --staged, --ref and the command's default.
    source: DiffSource = .worktree,
    output: OutputMode = .human,
    no_color: bool = false,
    context: ?u32 = null,
    verbosity: Verbosity = .normal,
    /// Pass `--3way` to git apply: fall back to a 3-way merge if context drifted.
    /// Only commands that apply patches accept it; the rest reject it at parse time.
    three_way: bool = false,
};

pub const ListOptions = struct {
    common: Common = .{},
    oneline: bool = false,
};

pub const AddResetOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    common: Common = .{},
    select_all: bool = false,
    /// Validate the patch against the index and report what would happen,
    /// touching neither the index nor the worktree.
    dry_run: bool = false,
};

pub const DiffOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    common: Common = .{},
    /// Number hunk body lines in human output. A line spec already implies the
    /// numbered gutter; this requests it without one.
    number: bool = false,
};

pub const CountOptions = struct {
    common: Common = .{},
};

pub const CheckOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    common: Common = .{},
    exclusive: bool = false,
    allow_empty: bool = false,
};

pub const RestoreOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    common: Common = .{},
    select_all: bool = false,
    dry_run: bool = false,
    force: bool = false,
};

pub const StashOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    common: Common = .{},
    select_all: bool = false,
    pop: bool = false,
    include_untracked: bool = false,
    message: ?[]const u8 = null,
};

pub const CommitOptions = struct {
    sha_args: std.ArrayList(ShaArg),
    common: Common = .{},
    message: ?[]const u8 = null,
    amend: bool = false,
    dry_run: bool = false,
    select_all: bool = false,
};

/// Compute the stable SHA1 fingerprint of a hunk: SHA1(file_path || \x00 ||
/// anchor_line_decimal || \x00 || diff_lines). Returns 40-char lowercase hex.
pub fn computeHunkSha(file_path: []const u8, anchor_line: u32, diff_lines: []const u8) [40]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(file_path);
    hasher.update(&[_]u8{0});

    var line_buf: [20]u8 = undefined;
    const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{anchor_line}) catch "0";
    hasher.update(line_str);
    hasher.update(&[_]u8{0});

    hasher.update(diff_lines);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);

    return std.fmt.bytesToHex(digest, .lower);
}

/// Returns true if `file_path` matches the `--file` filter set.
/// Empty filter slice means "no filter, match everything".
pub fn matchesFileFilter(file_path: []const u8, filter: []const []const u8) bool {
    if (filter.len == 0) return true;
    for (filter) |f| {
        if (std.mem.eql(u8, file_path, f)) return true;
    }
    return false;
}

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
        .section = &test_section,
    };
}

const test_section: FileSection = .{};

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

test "computeHunkSha deterministic" {
    const sha1 = computeHunkSha("src/main.zig", 10, "+added line\n-removed line");
    const sha2 = computeHunkSha("src/main.zig", 10, "+added line\n-removed line");
    try std.testing.expectEqualStrings(&sha1, &sha2);
}

test "computeHunkSha different path" {
    const sha1 = computeHunkSha("a.zig", 10, "+line");
    const sha2 = computeHunkSha("b.zig", 10, "+line");
    try std.testing.expect(!std.mem.eql(u8, &sha1, &sha2));
}

test "computeHunkSha different line" {
    const sha1 = computeHunkSha("a.zig", 10, "+line");
    const sha2 = computeHunkSha("a.zig", 11, "+line");
    try std.testing.expect(!std.mem.eql(u8, &sha1, &sha2));
}

test "matchesFileFilter empty filter matches everything" {
    try std.testing.expect(matchesFileFilter("anything.txt", &.{}));
    try std.testing.expect(matchesFileFilter("", &.{}));
}

test "matchesFileFilter exact match" {
    const filter = [_][]const u8{"foo.zig"};
    try std.testing.expect(matchesFileFilter("foo.zig", &filter));
    try std.testing.expect(!matchesFileFilter("bar.zig", &filter));
}

test "matchesFileFilter any-of with multiple entries" {
    const filter = [_][]const u8{ "a.zig", "b.zig", "c.zig" };
    try std.testing.expect(matchesFileFilter("a.zig", &filter));
    try std.testing.expect(matchesFileFilter("b.zig", &filter));
    try std.testing.expect(matchesFileFilter("c.zig", &filter));
    try std.testing.expect(!matchesFileFilter("d.zig", &filter));
}

test "matchesFileFilter requires exact equality (no prefix match)" {
    const filter = [_][]const u8{"a.txt"};
    try std.testing.expect(!matchesFileFilter("a.txt.bak", &filter));
    try std.testing.expect(!matchesFileFilter("dir/a.txt", &filter));
}

test "BodyLineIterator numbers body lines, skipping no-newline markers" {
    var lines = BodyLineIterator.init("@@ -1,2 +1,3 @@ fn f()\n ctx\n-old\n+new\n\\ No newline at end of file\n+more");
    try std.testing.expectEqualStrings("@@ -1,2 +1,3 @@ fn f()", lines.header);

    const expected = [_]BodyLine{
        .{ .kind = .context, .text = " ctx", .number = 1 },
        .{ .kind = .removal, .text = "-old", .number = 2 },
        .{ .kind = .addition, .text = "+new", .number = 3 },
        .{ .kind = .no_newline, .text = "\\ No newline at end of file", .number = null },
        .{ .kind = .addition, .text = "+more", .number = 4 },
    };
    for (expected) |want| {
        const got = lines.next().?;
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqualStrings(want.text, got.text);
        try std.testing.expectEqual(want.number, got.number);
    }
    try std.testing.expect(lines.next() == null);
}

test "BodyLineIterator treats an empty line as numbered context" {
    var lines = BodyLineIterator.init("@@ -1,3 +1,3 @@\n a\n\n b\n");
    try std.testing.expectEqual(@as(?u32, 1), lines.next().?.number);
    const blank = lines.next().?;
    try std.testing.expectEqual(BodyLine.Kind.context, blank.kind);
    try std.testing.expectEqualStrings("", blank.text);
    try std.testing.expectEqual(@as(?u32, 2), blank.number);
    try std.testing.expectEqual(@as(?u32, 3), lines.next().?.number);
    // The trailing newline ends " b"; it does not start a fourth line.
    try std.testing.expect(lines.next() == null);
}

test "BodyLineIterator leaves unrecognised lines unnumbered" {
    var lines = BodyLineIterator.init("@@ -1 +1 @@\n+a\n?junk\n+b");
    try std.testing.expectEqual(@as(?u32, 1), lines.next().?.number);
    const junk = lines.next().?;
    try std.testing.expectEqual(BodyLine.Kind.other, junk.kind);
    try std.testing.expectEqual(@as(?u32, null), junk.number);
    try std.testing.expectEqual(@as(?u32, 2), lines.next().?.number);
}

test "BodyLineIterator header-only input has no body" {
    var lines = BodyLineIterator.init("@@ -1 +1 @@");
    try std.testing.expectEqualStrings("@@ -1 +1 @@", lines.header);
    try std.testing.expect(lines.next() == null);
}
