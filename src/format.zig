const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");

const Hunk = types.Hunk;
const DiffMode = types.DiffMode;
const LineSpec = types.LineSpec;

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
    try stdout.writeAll(h.file_path);
    const path_pad = col_width + 2 -| h.file_path.len;
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

    try stdout.print("{s}\t{s}\t{d}\t{d}\t{s}\n", .{
        short_sha,
        h.file_path,
        start_line,
        end_line,
        summary,
    });
}

pub fn printDiffHuman(stdout: *std.Io.Writer, h: Hunk, use_color: bool) !void {
    if (h.raw_lines.len == 0) {
        try stdout.writeAll("\n");
        return;
    }
    var iter = std.mem.splitScalar(u8, h.raw_lines, '\n');
    while (iter.next()) |line| {
        if (use_color and line.len > 0) {
            const color: []const u8 = if (line[0] == '+') COLOR_GREEN else if (line[0] == '-') COLOR_RED else "";
            if (color.len > 0) {
                try stdout.print("    {s}{s}{s}\n", .{ color, line, COLOR_RESET });
                continue;
            }
        }
        try stdout.print("    {s}\n", .{line});
    }
    try stdout.writeAll("\n");
}

/// Print raw hunk lines (@@-header + body) with optional color for +/- lines.
/// Used by cmdShow human mode.
pub fn printRawLinesHuman(stdout: *std.Io.Writer, raw_lines: []const u8, use_color: bool) !void {
    if (raw_lines.len == 0) return;
    var iter = std.mem.splitScalar(u8, raw_lines, '\n');
    while (iter.next()) |line| {
        if (use_color and line.len > 0) {
            const color: []const u8 = if (line[0] == '+') COLOR_GREEN else if (line[0] == '-') COLOR_RED else "";
            if (color.len > 0) {
                try stdout.print("{s}{s}{s}\n", .{ color, line, COLOR_RESET });
                continue;
            }
        }
        try stdout.print("{s}\n", .{line});
    }
}

/// Print raw hunk lines with line numbers and selection markers.
/// Used by cmdShow when a line spec is present.
pub fn printRawLinesWithLineNumbers(stdout: *std.Io.Writer, raw_lines: []const u8, line_spec: LineSpec, use_color: bool) !void {
    if (raw_lines.len == 0) return;

    // First pass: count body lines to determine line number width
    var total_body_lines: u32 = 0;
    {
        var count_iter = std.mem.splitScalar(u8, raw_lines, '\n');
        _ = count_iter.next(); // skip @@ header
        while (count_iter.next()) |line| {
            if (line.len == 0) {
                total_body_lines += 1;
            } else if (line[0] == ' ' or line[0] == '+' or line[0] == '-') {
                total_body_lines += 1;
            }
        }
    }

    // Determine digit width for line numbers
    var num_width: usize = 1;
    {
        var n = total_body_lines;
        while (n >= 10) {
            num_width += 1;
            n /= 10;
        }
    }

    const COLOR_BOLD = "\x1b[1m";

    // Second pass: print with line numbers
    var iter = std.mem.splitScalar(u8, raw_lines, '\n');
    // Print the @@ header without line number
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
        if (line.len == 0) {
            // Empty context line
            const selected = line_spec.containsLine(line_num);
            const marker: u8 = if (selected) '>' else ' ';
            const num_str = formatNumPadded(&num_buf, line_num, num_width);
            try stdout.print("{c}{s}:\n", .{ marker, num_str });
            line_num += 1;
            continue;
        }

        const first = line[0];
        if (first == ' ' or first == '+' or first == '-') {
            const selected = line_spec.containsLine(line_num);
            const marker: u8 = if (selected) '>' else ' ';
            const num_str = formatNumPadded(&num_buf, line_num, num_width);
            if (use_color and (first == '+' or first == '-')) {
                const color: []const u8 = if (first == '+') COLOR_GREEN else COLOR_RED;
                if (selected) {
                    try stdout.print("{s}{c}{s}:{s}{s}{s}\n", .{ COLOR_BOLD, marker, num_str, color, line, COLOR_RESET });
                } else {
                    try stdout.print("{c}{s}:{s}{s}{s}\n", .{ marker, num_str, color, line, COLOR_RESET });
                }
            } else {
                if (selected and use_color) {
                    try stdout.print("{s}{c}{s}:{s}{s}\n", .{ COLOR_BOLD, marker, num_str, line, COLOR_RESET });
                } else {
                    try stdout.print("{c}{s}:{s}\n", .{ marker, num_str, line });
                }
            }
            line_num += 1;
        } else if (first == '\\') {
            // \ marker — no line number, print with padding
            const pad = num_width + 2; // marker + num_width + ':'
            var p: usize = 0;
            while (p < pad) : (p += 1) try stdout.writeByte(' ');
            try stdout.print("{s}\n", .{line});
        } else {
            try stdout.print("{s}\n", .{line});
        }
    }
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
    const start = stableStartLine(h, mode);
    const end = stableEndLine(h, mode);
    if (start == 0 and end == 0) return "empty";
    return std.fmt.bufPrint(buf, "{d}-{d}", .{ start, end }) catch "";
}

pub fn getTerminalWidth() u16 {
    const min_width: u16 = 40;

    const stdout_file = std.fs.File.stdout();
    if (stdout_file.isTty()) {
        var wsz: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const err = posix.system.ioctl(stdout_file.handle, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (posix.errno(err) == .SUCCESS and wsz.col > 0) return @max(wsz.col, min_width);
    }

    // Fallback: check COLUMNS env var (useful in CI/agent contexts where stdout isn't a TTY)
    if (posix.getenv("COLUMNS")) |cols_str| {
        if (std.fmt.parseInt(u16, cols_str, 10)) |cols| {
            if (cols > 0) return @max(cols, min_width);
        } else |_| {}
    }

    return 80;
}

// ============================================================================
// Tests
// ============================================================================

const diff_mod = @import("diff.zig");
const testMakeHunk = types.testMakeHunk;

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

    const sha = diff_mod.computeHunkSha("a.zig", 1, "+hello");
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
