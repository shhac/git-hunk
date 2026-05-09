const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");

const Hunk = types.Hunk;
const DiffMode = types.DiffMode;
const LineSpec = types.LineSpec;

const defaultIo = types.getIo;
const getEnv = types.getEnv;

/// Write the file path with a trailing '@' suffix for symlinks (like ls -F).
pub fn writeFilePath(stdout: *std.Io.Writer, h: anytype) !void {
    try stdout.writeAll(h.file_path);
    if (h.is_symlink) try stdout.writeByte('@');
}

/// Returns true if colored output should be used: human mode, no --no-color flag,
/// stdout is a TTY (or git pager is active), and NO_COLOR env var is unset.
pub fn shouldUseColor(output: types.OutputMode, no_color: bool) bool {
    if (output != .human or no_color) return false;
    if (getEnv("NO_COLOR") != null) return false;
    // When git pipes through a pager, stdout is not a TTY but colors are still wanted.
    // Git sets GIT_PAGER_IN_USE=true when the pager is active.
    const io = defaultIo();
    if (std.Io.File.stdout().isTty(io) catch false) return true;
    if (getEnv("GIT_PAGER_IN_USE") != null) return true;
    return false;
}

// ANSI color escape codes — only used in human mode when stdout is a TTY
pub const COLOR_RESET = "\x1b[0m";
pub const COLOR_YELLOW = "\x1b[33m"; // SHA hash
pub const COLOR_GREEN = "\x1b[32m"; // added lines (+), result hashes
pub const COLOR_RED = "\x1b[31m"; // removed lines (-)
pub const COLOR_DIM = "\x1b[2m"; // consumed/merged hashes

pub fn printHunkHuman(stdout: *std.Io.Writer, h: Hunk, mode: DiffMode, col_width: usize, term_width: u16, use_color: bool) !void {
    const short_sha = h.sha_hex[0..7];
    var summary_buf: [256]u8 = undefined;
    const summary = hunkSummaryWithFallback(&summary_buf, h);

    var range_buf: [24]u8 = undefined;
    const range = formatLineRange(&range_buf, h, mode);

    // SHA column (7 chars) + 2-space gap
    if (use_color) {
        try stdout.writeAll(COLOR_YELLOW);
        try stdout.writeAll(short_sha);
        try stdout.writeAll(COLOR_RESET);
    } else {
        try stdout.writeAll(short_sha);
    }
    try stdout.writeAll("  ");

    // File path column (dynamic width) + gap
    try writeFilePath(stdout, h);
    const path_len = h.file_path.len + @as(usize, if (h.is_symlink) 1 else 0);
    const path_pad = col_width + 2 -| path_len;
    var pad_i: usize = 0;
    while (pad_i < path_pad) : (pad_i += 1) try stdout.writeByte(' ');

    // Range column (8 chars padded) + 2-space gap
    try stdout.print("{s:<8}  ", .{range});

    // Summary column, truncated to fit terminal width
    // prefix_width = 7(sha) + 2 + col_width + 2 + 8(range) + 2 = col_width + 21
    const prefix_width: usize = col_width + 21;
    const available: usize = if (@as(usize, term_width) > prefix_width + 1)
        @as(usize, term_width) - prefix_width - 1
    else
        0;
    if (available == 0) {
        // No space for summary — skip to avoid overflow/wrapping
    } else if (summary.len > available) {
        const trunc = available -| 1; // leave 1 column for ellipsis if possible
        if (trunc > 0) {
            try stdout.writeAll(summary[0..trunc]);
            try stdout.writeAll("\xe2\x80\xa6"); // U+2026 HORIZONTAL ELLIPSIS
        } else {
            try stdout.writeAll(summary[0..available]);
        }
    } else {
        try stdout.writeAll(summary);
    }
    try stdout.writeByte('\n');
}

pub fn printHunkPorcelain(stdout: *std.Io.Writer, h: Hunk, mode: DiffMode) !void {
    const short_sha = h.sha_hex[0..7];
    var summary_buf: [64]u8 = undefined;
    const summary = hunkSummaryWithFallback(&summary_buf, h);

    const start_line = stableStartLine(h, mode);
    const end_line = stableEndLine(h, mode);

    try stdout.print("{s}\t", .{short_sha});
    try writeFilePath(stdout, h);
    try stdout.print("\t{d}\t{d}\t{s}\n", .{
        start_line,
        end_line,
        summary,
    });
}

/// Print raw hunk lines (`@@`-header + body) with optional color for +/- lines
/// and an optional indent prefix on every line. The shared core of the
/// printDiffHuman + printRawLinesHuman pair.
fn printRawLines(stdout: *std.Io.Writer, raw_lines: []const u8, indent: []const u8, use_color: bool) !void {
    var iter = std.mem.splitScalar(u8, raw_lines, '\n');
    while (iter.next()) |line| {
        const color: []const u8 = if (use_color and line.len > 0)
            (if (line[0] == '+') COLOR_GREEN else if (line[0] == '-') COLOR_RED else "")
        else
            "";
        if (color.len > 0) {
            try stdout.print("{s}{s}{s}{s}\n", .{ indent, color, line, COLOR_RESET });
        } else {
            try stdout.print("{s}{s}\n", .{ indent, line });
        }
    }
}

pub fn printDiffHuman(stdout: *std.Io.Writer, h: Hunk, use_color: bool) !void {
    if (h.is_binary) {
        try stdout.writeAll("    Binary file changed\n\n");
        return;
    }
    if (h.raw_lines.len == 0) {
        try stdout.writeAll("\n");
        return;
    }
    try printRawLines(stdout, h.raw_lines, "    ", use_color);
    try stdout.writeAll("\n");
}

/// Print raw hunk lines (@@-header + body) with optional color for +/- lines.
/// Used by cmdDiff human mode.
pub fn printRawLinesHuman(stdout: *std.Io.Writer, raw_lines: []const u8, use_color: bool) !void {
    if (raw_lines.len == 0) return;
    try printRawLines(stdout, raw_lines, "", use_color);
}

/// Print raw hunk lines with line numbers and selection markers.
/// Used by cmdDiff when a line spec is present.
pub fn printRawLinesWithLineNumbers(stdout: *std.Io.Writer, raw_lines: []const u8, line_spec: LineSpec, use_color: bool) !void {
    if (raw_lines.len == 0) return;

    const total_body_lines = countBodyLines(raw_lines);
    const num_width = digitWidth(total_body_lines);

    var iter = std.mem.splitScalar(u8, raw_lines, '\n');
    // Print the @@ header without line number.
    if (iter.next()) |header_line| {
        if (use_color) {
            try stdout.print("\x1b[36m{s}{s}\n", .{ header_line, COLOR_RESET });
        } else {
            try stdout.print("{s}\n", .{header_line});
        }
    }

    var num_buf: [16]u8 = undefined;
    var line_num: u32 = 1;
    while (iter.next()) |line| {
        const first: ?u8 = if (line.len == 0) ' ' else line[0];
        if (first) |f| {
            if (f == ' ' or f == '+' or f == '-') {
                const selected = line_spec.containsLine(line_num);
                const num_str = formatNumPadded(&num_buf, line_num, num_width);
                try printNumberedBodyLine(stdout, line, num_str, selected, use_color);
                line_num += 1;
                continue;
            }
        }

        if (line.len > 0 and line[0] == '\\') {
            // "\ No newline" marker — pad to align with line numbers.
            const pad = num_width + 2;
            var p: usize = 0;
            while (p < pad) : (p += 1) try stdout.writeByte(' ');
            try stdout.print("{s}\n", .{line});
        } else {
            try stdout.print("{s}\n", .{line});
        }
    }
}

const COLOR_BOLD = "\x1b[1m";

/// Count body lines (context, +, - lines after the @@ header) in a raw hunk.
fn countBodyLines(raw_lines: []const u8) u32 {
    var total: u32 = 0;
    var iter = std.mem.splitScalar(u8, raw_lines, '\n');
    _ = iter.next(); // skip @@ header
    while (iter.next()) |line| {
        if (line.len == 0) {
            total += 1;
        } else if (line[0] == ' ' or line[0] == '+' or line[0] == '-') {
            total += 1;
        }
    }
    return total;
}

/// Number of decimal digits needed to display `n`. Returns 1 for 0..=9.
fn digitWidth(n: u32) usize {
    var width: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) width += 1;
    return width;
}

/// Print a single numbered body line: `>num: line` (selected) or ` num: line`,
/// with +/- line content colored when `use_color` is true and the prefix made
/// bold when selected.
fn printNumberedBodyLine(stdout: *std.Io.Writer, line: []const u8, num_str: []const u8, selected: bool, use_color: bool) !void {
    const marker: u8 = if (selected) '>' else ' ';
    const first: u8 = if (line.len == 0) ' ' else line[0];
    const line_color: []const u8 = if (use_color and first == '+')
        COLOR_GREEN
    else if (use_color and first == '-')
        COLOR_RED
    else
        "";
    const prefix_color: []const u8 = if (use_color and selected) COLOR_BOLD else "";
    const reset: []const u8 = if (line_color.len > 0 or prefix_color.len > 0) COLOR_RESET else "";
    try stdout.print("{s}{c}{s}:{s}{s}{s}\n", .{ prefix_color, marker, num_str, line_color, line, reset });
}

/// Format a number right-aligned in a fixed-width field.
fn formatNumPadded(buf: []u8, num: u32, width: usize) []const u8 {
    // Format the number
    var tmp: [12]u8 = undefined;
    const num_str = std.fmt.bufPrint(&tmp, "{d}", .{num}) catch return "";
    const pad_len = if (width > num_str.len) width - num_str.len else 0;
    const total = pad_len + num_str.len;
    if (total > buf.len) return num_str;
    // Fill padding spaces
    @memset(buf[0..pad_len], ' ');
    @memcpy(buf[pad_len..total], num_str);
    return buf[0..total];
}

pub fn printDiffPorcelain(stdout: *std.Io.Writer, h: Hunk) !void {
    if (h.is_binary) {
        try stdout.writeAll("Binary file changed\n\n");
        return;
    }
    if (h.raw_lines.len == 0) {
        try stdout.writeAll("\n");
        return;
    }
    try stdout.writeAll(h.raw_lines);
    if (h.raw_lines[h.raw_lines.len - 1] != '\n') {
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("\n");
}

const MatchedHunk = types.MatchedHunk;
const OutputMode = types.OutputMode;

/// Write a line spec as `start-end` or `start` (comma-separated for multiple ranges).
pub fn writeLineSpec(stdout: *std.Io.Writer, ls: LineSpec) !void {
    for (ls.ranges, 0..) |r, i| {
        if (i > 0) try stdout.print(",", .{});
        if (r.start == r.end) {
            try stdout.print("{d}", .{r.start});
        } else {
            try stdout.print("{d}-{d}", .{ r.start, r.end });
        }
    }
}

/// Iterate `matched`, printing one line per hunk via `printMatchedHunkLine`
/// when verbosity is not quiet. Returns the count of hunks iterated. Used by
/// cmdRestore, cmdStash, and cmdCommit (post-commit and dry-run output).
pub fn printMatchedHunks(
    stdout: *std.Io.Writer,
    matched: []const MatchedHunk,
    verb: []const u8,
    porcelain_verb: []const u8,
    use_color: bool,
    output: OutputMode,
    verbosity: types.Verbosity,
) !usize {
    var count: usize = 0;
    for (matched) |m| {
        count += 1;
        if (verbosity != .quiet) {
            try printMatchedHunkLine(stdout, verb, porcelain_verb, m, use_color, output);
        }
    }
    return count;
}

/// Print a verbose-mode summary line of the form "1 hunk {verb}" or
/// "{N} hunks {verb}". No-op for quiet/porcelain modes. Used by every
/// hunk-applying command.
pub fn printHunkCountSummary(verbosity: types.Verbosity, output: OutputMode, count: usize, verb: []const u8) void {
    if (verbosity != .verbose or output != .human) return;
    if (count == 1) {
        std.debug.print("1 hunk {s}\n", .{verb});
    } else {
        std.debug.print("{d} hunks {s}\n", .{ count, verb });
    }
}

/// Print a single matched hunk line in human or porcelain format.
/// Used by restore, stash, commit (dry-run + post-commit), and binary add/reset output.
pub fn printMatchedHunkLine(stdout: *std.Io.Writer, verb: []const u8, porcelain_verb: []const u8, m: MatchedHunk, use_color: bool, output: OutputMode) !void {
    switch (output) {
        .human => {
            try stdout.print("{s} ", .{verb});
            if (use_color) try stdout.writeAll(COLOR_YELLOW);
            try stdout.writeAll(m.hunk.sha_hex[0..7]);
            if (m.line_spec) |ls| {
                try stdout.print(":", .{});
                try writeLineSpec(stdout, ls);
            }
            if (use_color) try stdout.writeAll(COLOR_RESET);
            try stdout.writeAll("  ");
            try writeFilePath(stdout, m.hunk);
            try stdout.writeByte('\n');
        },
        .porcelain => {
            try stdout.print("{s}\t{s}", .{ porcelain_verb, m.hunk.sha_hex[0..7] });
            if (m.line_spec) |ls| {
                try stdout.print(":", .{});
                try writeLineSpec(stdout, ls);
            }
            try stdout.writeByte('\t');
            try writeFilePath(stdout, m.hunk);
            try stdout.writeByte('\n');
        },
    }
}

fn stableStartLine(h: Hunk, mode: DiffMode) u32 {
    return switch (mode) {
        .unstaged => h.new_start,
        .staged => h.old_start,
    };
}

fn stableEndLine(h: Hunk, mode: DiffMode) u32 {
    return switch (mode) {
        .unstaged => if (h.new_count > 0) h.new_start + h.new_count - 1 else h.new_start,
        .staged => if (h.old_count > 0) h.old_start + h.old_count - 1 else h.old_start,
    };
}

fn hunkSummaryWithFallback(buf: []u8, h: Hunk) []const u8 {
    if (h.is_binary and h.is_new_file) return "new binary file";
    if (h.is_binary and h.is_deleted_file) return "binary deleted";
    if (h.is_binary) return "binary";
    if (h.is_new_file) return "new file";
    if (h.is_deleted_file) return "deleted";
    // Prefer first changed line — answers "what changed?" for quick scanning
    const changed = firstChangedLine(buf, h.diff_lines);
    if (changed.len > 0) return changed;
    // Fall back to function context from @@ header
    if (h.context.len > 0) return h.context;
    return "";
}

fn firstChangedLine(buf: []u8, diff_lines: []const u8) []const u8 {
    var iter = std.mem.splitScalar(u8, diff_lines, '\n');
    while (iter.next()) |line| {
        if (line.len > 1 and (line[0] == '+' or line[0] == '-')) {
            // Strip the +/- prefix and trim leading whitespace
            var content = line[1..];
            while (content.len > 0 and content[0] == ' ') {
                content = content[1..];
            }
            if (content.len == 0) continue;
            // Truncate to buffer size - keep room for nul safety
            const max_len = @min(content.len, buf.len);
            @memcpy(buf[0..max_len], content[0..max_len]);
            return buf[0..max_len];
        }
    }
    return "";
}

fn formatLineRange(buf: []u8, h: Hunk, mode: DiffMode) []const u8 {
    if (h.is_binary) return "(binary)";
    const start = stableStartLine(h, mode);
    const end = stableEndLine(h, mode);
    if (start == 0 and end == 0) return "empty";
    return std.fmt.bufPrint(buf, "{d}-{d}", .{ start, end }) catch "";
}

pub fn getTerminalWidth() u16 {
    const min_width: u16 = 40;

    const io = defaultIo();
    const stdout_file = std.Io.File.stdout();
    if (stdout_file.isTty(io) catch false) {
        var wsz: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const err = posix.system.ioctl(stdout_file.handle, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (posix.errno(err) == .SUCCESS and wsz.col > 0) return @max(wsz.col, min_width);
    }

    // Fallback: check COLUMNS env var (useful in CI/agent contexts where stdout isn't a TTY)
    if (getEnv("COLUMNS")) |cols_str| {
        if (std.fmt.parseInt(u16, cols_str, 10)) |cols| {
            if (cols > 0) return @max(cols, min_width);
        } else |_| {}
    }

    return 80;
}

// ============================================================================
// Tests
// ============================================================================

const testMakeHunk = types.testMakeHunk;

test "printRawLines plain context line, no color, no indent" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printRawLines(&w, "@@ -1 +1 @@\n+added", "", false);
    try std.testing.expectEqualStrings("@@ -1 +1 @@\n+added\n", w.buffered());
}

test "printRawLines colors +/- when use_color is true" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printRawLines(&w, "+plus\n-minus\n context", "", true);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_GREEN) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_RED) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_RESET) != null);
}

test "printRawLines applies indent prefix to every line" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printRawLines(&w, "a\nb\nc", "  >> ", false);
    try std.testing.expectEqualStrings("  >> a\n  >> b\n  >> c\n", w.buffered());
}

test "printDiffHuman binary file emits placeholder" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var h = testMakeHunk("img.png", 1, 1, 1, 1);
    h.is_binary = true;
    try printDiffHuman(&w, h, false);
    try std.testing.expectEqualStrings("    Binary file changed\n\n", w.buffered());
}

test "printDiffHuman empty raw_lines emits blank line" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const h = testMakeHunk("a.txt", 1, 0, 1, 0);
    try printDiffHuman(&w, h, false);
    try std.testing.expectEqualStrings("\n", w.buffered());
}

test "printRawLinesHuman empty input writes nothing" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printRawLinesHuman(&w, "", false);
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "printMatchedHunkLine human format includes verb and 7-char SHA" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var h = testMakeHunk("foo.txt", 1, 1, 1, 1);
    @memcpy(h.sha_hex[0..7], "abcdef0");
    @memset(h.sha_hex[7..], '0');
    const m = MatchedHunk{ .hunk = &h, .line_spec = null };
    try printMatchedHunkLine(&w, "staged", "staged", m, false, .human);
    try std.testing.expectEqualStrings("staged abcdef0  foo.txt\n", w.buffered());
}

test "printMatchedHunkLine porcelain format uses tabs" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var h = testMakeHunk("foo.txt", 1, 1, 1, 1);
    @memcpy(h.sha_hex[0..7], "abcdef0");
    @memset(h.sha_hex[7..], '0');
    const m = MatchedHunk{ .hunk = &h, .line_spec = null };
    try printMatchedHunkLine(&w, "staged", "staged", m, false, .porcelain);
    try std.testing.expectEqualStrings("staged\tabcdef0\tfoo.txt\n", w.buffered());
}

test "printMatchedHunkLine porcelain format includes line_spec" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var h = testMakeHunk("foo.txt", 1, 1, 1, 1);
    @memcpy(h.sha_hex[0..7], "abcdef0");
    @memset(h.sha_hex[7..], '0');
    const ranges = [_]types.LineRange{.{ .start = 3, .end = 5 }};
    const m = MatchedHunk{ .hunk = &h, .line_spec = .{ .ranges = &ranges } };
    try printMatchedHunkLine(&w, "staged", "staged", m, false, .porcelain);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "abcdef0:3-5") != null);
}

test "printMatchedHunkLine adds @ suffix for symlinks" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var h = testMakeHunk("link", 1, 1, 1, 1);
    @memcpy(h.sha_hex[0..7], "abcdef0");
    @memset(h.sha_hex[7..], '0');
    h.is_symlink = true;
    const m = MatchedHunk{ .hunk = &h, .line_spec = null };
    try printMatchedHunkLine(&w, "staged", "staged", m, false, .human);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "link@\n"));
}

test "printMatchedHunks empty input returns 0" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const count = try printMatchedHunks(&w, &.{}, "v", "v", false, .human, .normal);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "printMatchedHunks counts and prints one line per hunk" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var h1 = testMakeHunk("a.txt", 1, 1, 1, 1);
    @memset(h1.sha_hex[0..], '1');
    var h2 = testMakeHunk("b.txt", 1, 1, 1, 1);
    @memset(h2.sha_hex[0..], '2');
    const matched = [_]MatchedHunk{
        .{ .hunk = &h1, .line_spec = null },
        .{ .hunk = &h2, .line_spec = null },
    };
    const count = try printMatchedHunks(&w, &matched, "v", "v", false, .human, .normal);
    try std.testing.expectEqual(@as(usize, 2), count);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b.txt") != null);
}

test "countBodyLines counts context, +, - lines" {
    try std.testing.expectEqual(@as(u32, 0), countBodyLines("@@ -1 +1 @@"));
    try std.testing.expectEqual(@as(u32, 1), countBodyLines("@@ -1 +1 @@\n+a"));
    try std.testing.expectEqual(@as(u32, 3), countBodyLines("@@ -1 +1 @@\n a\n+b\n-c"));
    // Empty line counts as a body line (empty context).
    try std.testing.expectEqual(@as(u32, 2), countBodyLines("@@ -1 +1 @@\n\n a"));
    // Lines starting with `\` (no-newline marker) don't count.
    try std.testing.expectEqual(@as(u32, 1), countBodyLines("@@ -1 +1 @@\n+a\n\\ No newline"));
}

test "digitWidth basic cases" {
    try std.testing.expectEqual(@as(usize, 1), digitWidth(0));
    try std.testing.expectEqual(@as(usize, 1), digitWidth(9));
    try std.testing.expectEqual(@as(usize, 2), digitWidth(10));
    try std.testing.expectEqual(@as(usize, 2), digitWidth(99));
    try std.testing.expectEqual(@as(usize, 3), digitWidth(100));
    try std.testing.expectEqual(@as(usize, 4), digitWidth(9999));
}

test "printNumberedBodyLine non-selected non-color" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNumberedBodyLine(&w, "+added", "3", false, false);
    try std.testing.expectEqualStrings(" 3:+added\n", w.buffered());
}

test "printNumberedBodyLine selected gets > marker" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNumberedBodyLine(&w, " context", "5", true, false);
    try std.testing.expectEqualStrings(">5: context\n", w.buffered());
}

test "printNumberedBodyLine color: + line gets green" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNumberedBodyLine(&w, "+added", "1", false, true);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_GREEN) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_RED) == null);
}

test "printNumberedBodyLine color + selected: bold + green" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNumberedBodyLine(&w, "+added", "1", true, true);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_BOLD) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_GREEN) != null);
}

test "printRawLinesWithLineNumbers emits header + numbered body" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ranges = [_]types.LineRange{};
    const spec = types.LineSpec{ .ranges = &ranges };
    try printRawLinesWithLineNumbers(&w, "@@ -1 +1 @@\n+a\n b", spec, false);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "@@ -1 +1 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " 1:+a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " 2: b") != null);
}

test "printRawLinesWithLineNumbers selected lines get > marker" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ranges = [_]types.LineRange{.{ .start = 2, .end = 2 }};
    const spec = types.LineSpec{ .ranges = &ranges };
    try printRawLinesWithLineNumbers(&w, "@@ -1 +1 @@\n a\n+b\n c", spec, false);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, " 1: a") != null); // not selected
    try std.testing.expect(std.mem.indexOf(u8, out, ">2:+b") != null); // selected
    try std.testing.expect(std.mem.indexOf(u8, out, " 3: c") != null); // not selected
}

test "printRawLinesWithLineNumbers no-newline marker is padded" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ranges = [_]types.LineRange{};
    const spec = types.LineSpec{ .ranges = &ranges };
    try printRawLinesWithLineNumbers(&w, "@@ -1 +1 @@\n+a\n\\ No newline at end of file", spec, false);
    const out = w.buffered();
    // The "\\ No newline" line should be indented to align with line numbers (3 chars: " 1:")
    try std.testing.expect(std.mem.indexOf(u8, out, "   \\ No newline") != null);
}

test "printMatchedHunks quiet verbosity counts but prints nothing" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var h = testMakeHunk("a.txt", 1, 1, 1, 1);
    const matched = [_]MatchedHunk{.{ .hunk = &h, .line_spec = null }};
    const count = try printMatchedHunks(&w, &matched, "v", "v", false, .human, .quiet);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "firstChangedLine empty input" {
    var buf: [64]u8 = undefined;
    const result = firstChangedLine(&buf, "");
    try std.testing.expectEqualStrings("", result);
}

test "firstChangedLine whitespace-only changed line" {
    var buf: [64]u8 = undefined;
    // "+   " strips to empty content → skipped; "- " also empty → ""
    const result = firstChangedLine(&buf, "+   \n-   ");
    try std.testing.expectEqualStrings("", result);
}

test "firstChangedLine strips plus and leading spaces" {
    var buf: [64]u8 = undefined;
    const result = firstChangedLine(&buf, "+  hello world");
    try std.testing.expectEqualStrings("hello world", result);
}

test "firstChangedLine first change wins" {
    var buf: [64]u8 = undefined;
    // '-' line comes before '+' line
    const result = firstChangedLine(&buf, "-removed\n+added");
    try std.testing.expectEqualStrings("removed", result);
}

test "firstChangedLine truncates to buffer size" {
    var buf: [5]u8 = undefined;
    const result = firstChangedLine(&buf, "+hello world");
    try std.testing.expectEqualStrings("hello", result);
}

test "hunkSummaryWithFallback prefers changed line over context" {
    var buf: [64]u8 = undefined;
    var h = testMakeHunk("f.txt", 1, 1, 1, 1);
    h.context = "fn main()";
    h.diff_lines = "+hello world";
    try std.testing.expectEqualStrings("hello world", hunkSummaryWithFallback(&buf, h));
}

test "hunkSummaryWithFallback falls back to context" {
    var buf: [64]u8 = undefined;
    var h = testMakeHunk("f.txt", 1, 1, 1, 1);
    h.context = "fn main()";
    h.diff_lines = "";
    try std.testing.expectEqualStrings("fn main()", hunkSummaryWithFallback(&buf, h));
}

test "hunkSummaryWithFallback new file" {
    var buf: [64]u8 = undefined;
    var h = testMakeHunk("f.txt", 1, 1, 1, 1);
    h.is_new_file = true;
    try std.testing.expectEqualStrings("new file", hunkSummaryWithFallback(&buf, h));
}

test "hunkSummaryWithFallback deleted" {
    var buf: [64]u8 = undefined;
    var h = testMakeHunk("f.txt", 1, 1, 1, 1);
    h.is_deleted_file = true;
    try std.testing.expectEqualStrings("deleted", hunkSummaryWithFallback(&buf, h));
}

test "hunkSummaryWithFallback first changed line" {
    var buf: [64]u8 = undefined;
    var h = testMakeHunk("f.txt", 1, 1, 1, 1);
    h.diff_lines = "+hello world";
    try std.testing.expectEqualStrings("hello world", hunkSummaryWithFallback(&buf, h));
}

test "stableStartLine unstaged" {
    const h = testMakeHunk("f.txt", 5, 3, 10, 4);
    try std.testing.expectEqual(@as(u32, 10), stableStartLine(h, .unstaged));
}

test "stableStartLine staged" {
    const h = testMakeHunk("f.txt", 5, 3, 10, 4);
    try std.testing.expectEqual(@as(u32, 5), stableStartLine(h, .staged));
}

test "stableEndLine unstaged normal" {
    const h = testMakeHunk("f.txt", 5, 3, 10, 4);
    try std.testing.expectEqual(@as(u32, 13), stableEndLine(h, .unstaged)); // 10+4-1=13
}

test "stableEndLine unstaged zero count" {
    const h = testMakeHunk("f.txt", 5, 3, 10, 0);
    try std.testing.expectEqual(@as(u32, 10), stableEndLine(h, .unstaged)); // count=0 → start
}

test "stableEndLine staged normal" {
    const h = testMakeHunk("f.txt", 5, 3, 10, 4);
    try std.testing.expectEqual(@as(u32, 7), stableEndLine(h, .staged)); // 5+3-1=7
}

test "stableEndLine staged zero count" {
    const h = testMakeHunk("f.txt", 5, 0, 10, 4);
    try std.testing.expectEqual(@as(u32, 5), stableEndLine(h, .staged)); // count=0 → start
}

test "printHunkPorcelain format" {
    const allocator = std.testing.allocator;
    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();

    const sha = types.computeHunkSha("a.zig", 1, "+hello");
    var h = testMakeHunk("a.zig", 1, 1, 1, 1);
    h.sha_hex = sha;
    h.diff_lines = "+hello";

    try printHunkPorcelain(&w.writer, h, .unstaged);

    const output = w.writer.buffer[0..w.writer.end];
    // Format: "{sha7}\t{path}\t{start}\t{end}\t{summary}\n"
    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}\ta.zig\t1\t1\thello\n", .{sha[0..7]});
    try std.testing.expectEqualStrings(expected, output);
}
