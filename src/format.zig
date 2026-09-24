const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");

const Hunk = types.Hunk;
const Anchor = types.Anchor;
const LineSpec = types.LineSpec;

const defaultIo = types.getIo;
const getEnv = types.getEnv;

/// Write the file path with a trailing '@' suffix for symlinks (like ls -F).
pub fn writeFilePath(stdout: *std.Io.Writer, file_path: []const u8, is_symlink: bool) !void {
    try stdout.writeAll(file_path);
    if (is_symlink) try stdout.writeByte('@');
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
const COLOR_RESET = "\x1b[0m";
pub const COLOR_YELLOW = "\x1b[33m"; // SHA hash
pub const COLOR_GREEN = "\x1b[32m"; // added lines (+), result hashes
const COLOR_RED = "\x1b[31m"; // removed lines (-)
pub const COLOR_DIM = "\x1b[2m"; // consumed/merged hashes
const COLOR_CYAN = "\x1b[36m"; // @@ headers of numbered hunks
const COLOR_BOLD = "\x1b[1m"; // selection markers of numbered hunks

/// The escape codes that wrap text in a colour: empty when colour is off or
/// there is no colour to apply, so the text prints bare.
const Paint = struct { on: []const u8, off: []const u8 };

pub fn paint(use_color: bool, color: []const u8) Paint {
    if (!use_color or color.len == 0) return .{ .on = "", .off = "" };
    return .{ .on = color, .off = COLOR_RESET };
}

fn diffLineColor(kind: types.BodyLine.Kind) []const u8 {
    return switch (kind) {
        .addition => COLOR_GREEN,
        .removal => COLOR_RED,
        .context, .no_newline, .other => "",
    };
}

/// Columns `printHunkHuman` spends outside the path column before the
/// summary: sha(7) + 2 + [path] + 2 + range(8) + 2.
const list_prefix_overhead = 21;
/// Summary columns the path column must leave free on a narrow terminal.
const list_min_summary = 4;
const list_min_path_column = 20;

/// Width of `list`'s path column: wide enough for the longest path, but
/// never crowding the summary off a narrow terminal.
pub fn listColumnWidth(max_path_len: usize, term_width: u16) usize {
    const reserved = list_prefix_overhead + list_min_summary;
    const max_col: usize = if (term_width > reserved) term_width - reserved else list_min_path_column;
    return @min(@max(max_path_len, list_min_path_column), max_col);
}

/// Cut `summary` to `available` columns, reporting whether an ellipsis should
/// follow. The ellipsis takes the last column when there is room for it.
fn truncateSummary(summary: []const u8, available: usize) struct { text: []const u8, ellipsis: bool } {
    if (summary.len <= available) return .{ .text = summary, .ellipsis = false };
    if (available <= 1) return .{ .text = summary[0..available], .ellipsis = false };
    return .{ .text = summary[0 .. available - 1], .ellipsis = true };
}

pub fn printHunkHuman(stdout: *std.Io.Writer, h: Hunk, anchor: Anchor, col_width: usize, term_width: u16, use_color: bool) !void {
    const short_sha = h.sha_hex[0..7];
    var summary_buf: [256]u8 = undefined;
    const summary = hunkSummaryWithFallback(&summary_buf, h);

    var range_buf: [24]u8 = undefined;
    const range = formatLineRange(&range_buf, h, anchor);

    const sha = paint(use_color, COLOR_YELLOW);
    try stdout.print("{s}{s}{s}  ", .{ sha.on, short_sha, sha.off });

    try writeFilePath(stdout, h.file_path, h.section.is_symlink);
    const path_len = h.file_path.len + @as(usize, if (h.section.is_symlink) 1 else 0);
    try stdout.splatByteAll(' ', col_width + 2 -| path_len);

    try stdout.print("{s:<8}  ", .{range});

    // The last terminal column stays empty so the line never wraps.
    const available = @as(usize, term_width) -| (col_width + list_prefix_overhead + 1);
    const fitted = truncateSummary(summary, available);
    try stdout.writeAll(fitted.text);
    if (fitted.ellipsis) try stdout.writeAll("\xe2\x80\xa6"); // U+2026 HORIZONTAL ELLIPSIS
    try stdout.writeByte('\n');
}

pub fn printHunkPorcelain(stdout: *std.Io.Writer, h: Hunk, anchor: Anchor) !void {
    const short_sha = h.sha_hex[0..7];
    var summary_buf: [64]u8 = undefined;
    const summary = hunkSummaryWithFallback(&summary_buf, h);

    const start_line = stableStartLine(h, anchor);
    const end_line = stableEndLine(h, anchor);

    try stdout.print("{s}\t", .{short_sha});
    try writeFilePath(stdout, h.file_path, h.section.is_symlink);
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
        const color = paint(use_color, diffLineColor(.of(line)));
        try stdout.print("{s}{s}{s}{s}\n", .{ indent, color.on, line, color.off });
    }
}

pub fn printDiffHuman(stdout: *std.Io.Writer, h: Hunk, use_color: bool) !void {
    if (h.section.is_binary) {
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

    const num_width = digitWidth(countBodyLines(raw_lines));

    var lines = types.BodyLineIterator.init(raw_lines);
    const header = paint(use_color, COLOR_CYAN);
    try stdout.print("{s}{s}{s}\n", .{ header.on, lines.header, header.off });

    while (lines.next()) |line| {
        if (line.number) |number| {
            try printNumberedBodyLine(stdout, line, number, num_width, line_spec.containsLine(number), use_color);
            continue;
        }
        // Pad the "\ No newline" marker to align with the numbered lines.
        if (line.kind == .no_newline) try stdout.splatByteAll(' ', num_width + 2);
        try stdout.print("{s}\n", .{line.text});
    }
}

/// Count the numbered body lines (context, +, -) in a raw hunk.
fn countBodyLines(raw_lines: []const u8) u32 {
    var total: u32 = 0;
    var lines = types.BodyLineIterator.init(raw_lines);
    while (lines.next()) |line| {
        if (line.number != null) total += 1;
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
/// One reset closes both the bold prefix and the line colour.
fn printNumberedBodyLine(stdout: *std.Io.Writer, line: types.BodyLine, number: u32, num_width: usize, selected: bool, use_color: bool) !void {
    const line_color: []const u8 = if (use_color) diffLineColor(line.kind) else "";
    const prefix_color: []const u8 = if (use_color and selected) COLOR_BOLD else "";
    try stdout.print("{[prefix]s}{[marker]c}{[number]d:>[width]}:{[color]s}{[text]s}{[reset]s}\n", .{
        .prefix = prefix_color,
        .marker = @as(u8, if (selected) '>' else ' '),
        .number = number,
        .width = num_width,
        .color = line_color,
        .text = line.text,
        .reset = @as([]const u8, if (line_color.len > 0 or prefix_color.len > 0) COLOR_RESET else ""),
    });
}

pub fn printDiffPorcelain(stdout: *std.Io.Writer, h: Hunk) !void {
    if (h.section.is_binary) {
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

/// Write a hunk address as the user types it: `sha7` or `sha7:spec`.
pub fn writeShaSpec(stdout: *std.Io.Writer, sha7: []const u8, line_spec: ?LineSpec) !void {
    try stdout.writeAll(sha7);
    const ls = line_spec orelse return;
    try stdout.writeByte(':');
    try writeLineSpec(stdout, ls);
}

/// Write a line spec as `start-end` or `start` (comma-separated for multiple ranges).
fn writeLineSpec(stdout: *std.Io.Writer, ls: LineSpec) !void {
    for (ls.ranges, 0..) |r, i| {
        if (i > 0) try stdout.print(",", .{});
        if (r.start == r.end) {
            try stdout.print("{d}", .{r.start});
        } else {
            try stdout.print("{d}-{d}", .{ r.start, r.end });
        }
    }
}

/// Print one line per matched hunk via `printMatchedHunkLine` unless quiet,
/// in the output mode and colour `common` asks for. Used by cmdRestore,
/// cmdStash, and cmdCommit (post-commit and dry-run output).
pub fn printMatchedHunks(
    stdout: *std.Io.Writer,
    matched: []const MatchedHunk,
    verb: []const u8,
    porcelain_verb: []const u8,
    common: types.Common,
) !void {
    if (common.verbosity == .quiet) return;
    const use_color = shouldUseColor(common.output, common.no_color);
    for (matched) |m| {
        try printMatchedHunkLine(stdout, verb, porcelain_verb, m, use_color, common.output);
    }
}

/// Print a verbose-mode summary line of the form "1 hunk {verb}" or
/// "{N} hunks {verb}". No-op for quiet/porcelain modes. Used by every
/// hunk-applying command.
pub fn printHunkCountSummary(common: types.Common, count: usize, verb: []const u8) void {
    if (common.verbosity != .verbose or common.output != .human) return;
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
            const sha = paint(use_color, COLOR_YELLOW);
            try stdout.print("{s} {s}", .{ verb, sha.on });
            try writeShaSpec(stdout, m.hunk.sha_hex[0..7], m.line_spec);
            try stdout.print("{s}  ", .{sha.off});
            try writeFilePath(stdout, m.hunk.file_path, m.hunk.section.is_symlink);
            try stdout.writeByte('\n');
        },
        .porcelain => {
            try stdout.print("{s}\t", .{porcelain_verb});
            try writeShaSpec(stdout, m.hunk.sha_hex[0..7], m.line_spec);
            try stdout.writeByte('\t');
            try writeFilePath(stdout, m.hunk.file_path, m.hunk.section.is_symlink);
            try stdout.writeByte('\n');
        },
    }
}

fn stableStartLine(h: Hunk, anchor: Anchor) u32 {
    return switch (anchor) {
        .new => h.new_start,
        .old => h.old_start,
    };
}

fn stableEndLine(h: Hunk, anchor: Anchor) u32 {
    return switch (anchor) {
        .new => if (h.new_count > 0) h.new_start + h.new_count - 1 else h.new_start,
        .old => if (h.old_count > 0) h.old_start + h.old_count - 1 else h.old_start,
    };
}

fn hunkSummaryWithFallback(buf: []u8, h: Hunk) []const u8 {
    const section = h.section;
    if (section.is_binary and section.is_new_file) return "new binary file";
    if (section.is_binary and section.is_deleted_file) return "binary deleted";
    if (section.is_binary) return "binary";
    if (section.is_new_file) return "new file";
    if (section.is_deleted_file) return "deleted";
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

fn formatLineRange(buf: []u8, h: Hunk, anchor: Anchor) []const u8 {
    if (h.section.is_binary) return "(binary)";
    const start = stableStartLine(h, anchor);
    const end = stableEndLine(h, anchor);
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

fn testBodyLine(text: []const u8) types.BodyLine {
    return .{ .kind = .of(text), .text = text, .number = 1 };
}

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
    const section: types.FileSection = .{ .is_binary = true };
    h.section = &section;
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
    const section: types.FileSection = .{ .is_symlink = true };
    h.section = &section;
    const m = MatchedHunk{ .hunk = &h, .line_spec = null };
    try printMatchedHunkLine(&w, "staged", "staged", m, false, .human);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "link@\n"));
}

test "printMatchedHunks empty input writes nothing" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printMatchedHunks(&w, &.{}, "v", "v", .{ .no_color = true });
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "printMatchedHunks prints one line per hunk" {
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
    try printMatchedHunks(&w, &matched, "v", "v", .{ .no_color = true });
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
    try printNumberedBodyLine(&w, testBodyLine("+added"), 3, 1, false, false);
    try std.testing.expectEqualStrings(" 3:+added\n", w.buffered());
}

test "printNumberedBodyLine selected gets > marker" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNumberedBodyLine(&w, testBodyLine(" context"), 5, 1, true, false);
    try std.testing.expectEqualStrings(">5: context\n", w.buffered());
}

test "printNumberedBodyLine color: + line gets green" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNumberedBodyLine(&w, testBodyLine("+added"), 1, 1, false, true);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_GREEN) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_RED) == null);
}

test "printNumberedBodyLine empty line + selected + color: bold marker, no line-color" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNumberedBodyLine(&w, testBodyLine(""), 1, 1, true, true);
    const out = w.buffered();
    // Empty line is treated as context (no +/-): no green/red, but bold prefix.
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_BOLD) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_GREEN) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, COLOR_RED) == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\n"));
}

test "printNumberedBodyLine color + selected: bold + green" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try printNumberedBodyLine(&w, testBodyLine("+added"), 1, 1, true, true);
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

test "printMatchedHunks quiet verbosity prints nothing" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var h = testMakeHunk("a.txt", 1, 1, 1, 1);
    const matched = [_]MatchedHunk{.{ .hunk = &h, .line_spec = null }};
    try printMatchedHunks(&w, &matched, "v", "v", .{ .no_color = true, .verbosity = .quiet });
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
    const section: types.FileSection = .{ .is_new_file = true };
    h.section = &section;
    try std.testing.expectEqualStrings("new file", hunkSummaryWithFallback(&buf, h));
}

test "hunkSummaryWithFallback deleted" {
    var buf: [64]u8 = undefined;
    var h = testMakeHunk("f.txt", 1, 1, 1, 1);
    const section: types.FileSection = .{ .is_deleted_file = true };
    h.section = &section;
    try std.testing.expectEqualStrings("deleted", hunkSummaryWithFallback(&buf, h));
}

test "hunkSummaryWithFallback first changed line" {
    var buf: [64]u8 = undefined;
    var h = testMakeHunk("f.txt", 1, 1, 1, 1);
    h.diff_lines = "+hello world";
    try std.testing.expectEqualStrings("hello world", hunkSummaryWithFallback(&buf, h));
}

test "stableStartLine new anchor" {
    const h = testMakeHunk("f.txt", 5, 3, 10, 4);
    try std.testing.expectEqual(@as(u32, 10), stableStartLine(h, .new));
}

test "stableStartLine old anchor" {
    const h = testMakeHunk("f.txt", 5, 3, 10, 4);
    try std.testing.expectEqual(@as(u32, 5), stableStartLine(h, .old));
}

test "stableEndLine new anchor normal" {
    const h = testMakeHunk("f.txt", 5, 3, 10, 4);
    try std.testing.expectEqual(@as(u32, 13), stableEndLine(h, .new)); // 10+4-1=13
}

test "stableEndLine new anchor zero count" {
    const h = testMakeHunk("f.txt", 5, 3, 10, 0);
    try std.testing.expectEqual(@as(u32, 10), stableEndLine(h, .new)); // count=0 → start
}

test "stableEndLine old anchor normal" {
    const h = testMakeHunk("f.txt", 5, 3, 10, 4);
    try std.testing.expectEqual(@as(u32, 7), stableEndLine(h, .old)); // 5+3-1=7
}

test "stableEndLine old anchor zero count" {
    const h = testMakeHunk("f.txt", 5, 0, 10, 4);
    try std.testing.expectEqual(@as(u32, 5), stableEndLine(h, .old)); // count=0 → start
}

test "printHunkPorcelain format" {
    const allocator = std.testing.allocator;
    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();

    const sha = types.computeHunkSha("a.zig", 1, "+hello");
    var h = testMakeHunk("a.zig", 1, 1, 1, 1);
    h.sha_hex = sha;
    h.diff_lines = "+hello";

    try printHunkPorcelain(&w.writer, h, .new);

    const output = w.writer.buffer[0..w.writer.end];
    // Format: "{sha7}\t{path}\t{start}\t{end}\t{summary}\n"
    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}\ta.zig\t1\t1\thello\n", .{sha[0..7]});
    try std.testing.expectEqualStrings(expected, output);
}

test "paint wraps only when colour is on and there is a colour" {
    const on = paint(true, COLOR_GREEN);
    try std.testing.expectEqualStrings(COLOR_GREEN, on.on);
    try std.testing.expectEqualStrings(COLOR_RESET, on.off);
    const off = paint(false, COLOR_GREEN);
    try std.testing.expectEqualStrings("", off.on);
    try std.testing.expectEqualStrings("", off.off);
    const none = paint(true, "");
    try std.testing.expectEqualStrings("", none.on);
    try std.testing.expectEqualStrings("", none.off);
}

test "writeShaSpec appends the line spec after a colon" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ranges = [_]types.LineRange{ .{ .start = 2, .end = 2 }, .{ .start = 4, .end = 6 } };
    try writeShaSpec(&w, "abcdef0", .{ .ranges = &ranges });
    try w.writeByte(' ');
    try writeShaSpec(&w, "1234567", null);
    try std.testing.expectEqualStrings("abcdef0:2,4-6 1234567", w.buffered());
}

test "listColumnWidth fits the longest path between a floor and the terminal" {
    try std.testing.expectEqual(@as(usize, 20), listColumnWidth(5, 80));
    try std.testing.expectEqual(@as(usize, 30), listColumnWidth(30, 80));
    // 80 columns leave 55 for the path once the prefix and 4 summary columns are reserved.
    try std.testing.expectEqual(@as(usize, 55), listColumnWidth(70, 80));
    try std.testing.expectEqual(@as(usize, 15), listColumnWidth(70, 40));
    try std.testing.expectEqual(@as(usize, 20), listColumnWidth(70, 25));
}

test "truncateSummary keeps what fits and marks a cut with an ellipsis" {
    const whole = truncateSummary("hello", 5);
    try std.testing.expectEqualStrings("hello", whole.text);
    try std.testing.expect(!whole.ellipsis);

    const cut = truncateSummary("hello world", 5);
    try std.testing.expectEqualStrings("hell", cut.text);
    try std.testing.expect(cut.ellipsis);

    // One column has no room for an ellipsis as well as text.
    const one = truncateSummary("hello", 1);
    try std.testing.expectEqualStrings("h", one.text);
    try std.testing.expect(!one.ellipsis);

    const none = truncateSummary("hello", 0);
    try std.testing.expectEqualStrings("", none.text);
    try std.testing.expect(!none.ellipsis);
}

test "printRawLinesWithLineNumbers right-aligns numbers to the widest" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ranges = [_]types.LineRange{.{ .start = 10, .end = 10 }};
    try printRawLinesWithLineNumbers(&w, "@@ -1,10 +1,10 @@\n a\n b\n c\n d\n e\n f\n g\n h\n i\n+j\n\\ No newline at end of file", .{ .ranges = &ranges }, false);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\n  1: a\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\n>10:+j\n    \\ No newline") != null);
}
