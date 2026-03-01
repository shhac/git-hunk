const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Hunk = types.Hunk;
const DiffMode = types.DiffMode;

const DiffCursor = struct {
    buf: []const u8,
    pos: usize,

    fn init(buf: []const u8) DiffCursor {
        return .{ .buf = buf, .pos = 0 };
    }

    /// Returns the current line without consuming it.
    fn peek(self: *const DiffCursor) ?[]const u8 {
        if (self.pos >= self.buf.len) return null;
        const end = std.mem.indexOfScalarPos(u8, self.buf, self.pos, '\n') orelse self.buf.len;
        return self.buf[self.pos..end];
    }

    /// Returns the line after the current line, without consuming either.
    fn peekNext(self: *const DiffCursor) ?[]const u8 {
        if (self.pos >= self.buf.len) return null;
        const cur_end = std.mem.indexOfScalarPos(u8, self.buf, self.pos, '\n') orelse return null;
        const next_start = cur_end + 1;
        if (next_start >= self.buf.len) return null;
        const next_end = std.mem.indexOfScalarPos(u8, self.buf, next_start, '\n') orelse self.buf.len;
        return self.buf[next_start..next_end];
    }

    /// Advances past the current line and its newline.
    fn advance(self: *DiffCursor) void {
        if (self.pos >= self.buf.len) return;
        const end = std.mem.indexOfScalarPos(u8, self.buf, self.pos, '\n') orelse self.buf.len;
        self.pos = if (end < self.buf.len) end + 1 else self.buf.len;
    }
};

pub fn parseDiff(arena: Allocator, diff: []const u8, mode: DiffMode, hunks: *std.ArrayList(Hunk)) !void {
    var cursor = DiffCursor.init(diff);

    while (cursor.peek() != null) {
        // Look for "diff --git" to start a new file section
        const outer_line = cursor.peek().?;
        cursor.advance();
        if (!std.mem.startsWith(u8, outer_line, "diff --git ")) continue;

        const diff_git_line = outer_line;

        // Parse extended headers
        var is_new_file = false;
        var is_deleted_file = false;
        var is_binary = false;
        var is_submodule = false;
        var file_mode: []const u8 = "100644";
        var rename_from: ?[]const u8 = null;
        var rename_to: ?[]const u8 = null;

        while (cursor.peek()) |line| {
            if (std.mem.startsWith(u8, line, "new file mode ")) {
                is_new_file = true;
                file_mode = line["new file mode ".len..];
            } else if (std.mem.startsWith(u8, line, "deleted file mode ")) {
                is_deleted_file = true;
                file_mode = line["deleted file mode ".len..];
            } else if (std.mem.startsWith(u8, line, "Binary files ")) {
                is_binary = true;
            } else if (std.mem.startsWith(u8, line, "rename from ")) {
                rename_from = line["rename from ".len..];
            } else if (std.mem.startsWith(u8, line, "rename to ")) {
                rename_to = line["rename to ".len..];
            } else if (std.mem.startsWith(u8, line, "index ")) {
                // Detect submodule mode (160000)
                if (std.mem.endsWith(u8, line, " 160000")) {
                    is_submodule = true;
                }
            } else if (std.mem.startsWith(u8, line, "old mode ") or
                std.mem.startsWith(u8, line, "new mode ") or
                std.mem.startsWith(u8, line, "similarity index ") or
                std.mem.startsWith(u8, line, "copy from ") or
                std.mem.startsWith(u8, line, "copy to "))
            {
                // Extended header, continue
            } else {
                break; // Not an extended header
            }
            cursor.advance();
        }

        if (is_binary or is_submodule) continue;

        // Check for empty files: new/deleted files without ---/+++ lines
        const peeked = cursor.peek();
        const has_minus_plus = peeked != null and std.mem.startsWith(u8, peeked.?, "--- ");
        if (!has_minus_plus and (is_new_file or is_deleted_file)) {
            // Empty file: no ---/+++ lines, no @@ hunks.
            // Extract path from diff --git line and synthesize a hunk.
            const file_path = (try extractPathFromDiffGitLine(arena, diff_git_line)) orelse continue;

            // Build patch header with synthesized ---/+++ lines
            var ph: std.ArrayList(u8) = .empty;
            try ph.appendSlice(arena, diff_git_line);
            try ph.append(arena, '\n');
            if (is_new_file) {
                try ph.appendSlice(arena, "new file mode ");
            } else {
                try ph.appendSlice(arena, "deleted file mode ");
            }
            try ph.appendSlice(arena, file_mode);
            try ph.append(arena, '\n');
            if (is_deleted_file) {
                try ph.appendSlice(arena, "--- a/");
                try ph.appendSlice(arena, file_path);
                try ph.append(arena, '\n');
                try ph.appendSlice(arena, "+++ /dev/null\n");
            } else {
                try ph.appendSlice(arena, "--- /dev/null\n+++ b/");
                try ph.appendSlice(arena, file_path);
                try ph.append(arena, '\n');
            }

            const sha = computeHunkSha(file_path, 0, "");
            try hunks.append(arena, .{
                .file_path = file_path,
                .old_start = 0,
                .old_count = 0,
                .new_start = 0,
                .new_count = 0,
                .context = "",
                .raw_lines = "",
                .diff_lines = "",
                .sha_hex = sha,
                .is_new_file = is_new_file,
                .is_deleted_file = is_deleted_file,
                .is_untracked = false,
                .patch_header = ph.items,
            });
            continue;
        }

        // Expect ---/+++ lines
        const minus_line = cursor.peek() orelse continue;
        if (!std.mem.startsWith(u8, minus_line, "--- ")) continue;
        cursor.advance();

        const plus_line = cursor.peek() orelse continue;
        if (!std.mem.startsWith(u8, plus_line, "+++ ")) continue;
        cursor.advance();

        // Extract file path (handles both normal and C-quoted paths)
        const file_path = if (is_deleted_file)
            (try extractDiffPath(arena, minus_line, .old)) orelse continue
        else
            (try extractDiffPath(arena, plus_line, .new)) orelse continue;

        // Build patch header
        var patch_header: []const u8 = undefined;
        if (is_new_file or is_deleted_file) {
            // Need full diff --git header for new/deleted files
            var ph: std.ArrayList(u8) = .empty;
            try ph.appendSlice(arena, diff_git_line);
            try ph.append(arena, '\n');
            if (is_new_file) {
                try ph.appendSlice(arena, "new file mode ");
            } else {
                try ph.appendSlice(arena, "deleted file mode ");
            }
            try ph.appendSlice(arena, file_mode);
            try ph.append(arena, '\n');
            try ph.appendSlice(arena, minus_line);
            try ph.append(arena, '\n');
            try ph.appendSlice(arena, plus_line);
            try ph.append(arena, '\n');
            patch_header = ph.items;
        } else if (rename_from != null and rename_to != null) {
            // Renames need diff --git header + rename metadata
            var ph: std.ArrayList(u8) = .empty;
            try ph.appendSlice(arena, diff_git_line);
            try ph.append(arena, '\n');
            try ph.appendSlice(arena, "rename from ");
            try ph.appendSlice(arena, rename_from.?);
            try ph.append(arena, '\n');
            try ph.appendSlice(arena, "rename to ");
            try ph.appendSlice(arena, rename_to.?);
            try ph.append(arena, '\n');
            try ph.appendSlice(arena, minus_line);
            try ph.append(arena, '\n');
            try ph.appendSlice(arena, plus_line);
            try ph.append(arena, '\n');
            patch_header = ph.items;
        } else {
            var ph: std.ArrayList(u8) = .empty;
            try ph.appendSlice(arena, minus_line);
            try ph.append(arena, '\n');
            try ph.appendSlice(arena, plus_line);
            try ph.append(arena, '\n');
            patch_header = ph.items;
        }

        // Empty new/deleted file: ---/+++ present but no @@ hunk (Linux git behavior)
        const next_peek = cursor.peek();
        const has_at_hunk = next_peek != null and std.mem.startsWith(u8, next_peek.?, "@@ ");
        if (!has_at_hunk and (is_new_file or is_deleted_file)) {
            const sha = computeHunkSha(file_path, 0, "");
            try hunks.append(arena, .{
                .file_path = file_path,
                .old_start = 0,
                .old_count = 0,
                .new_start = 0,
                .new_count = 0,
                .context = "",
                .raw_lines = "",
                .diff_lines = "",
                .sha_hex = sha,
                .is_new_file = is_new_file,
                .is_deleted_file = is_deleted_file,
                .is_untracked = false,
                .patch_header = patch_header,
            });
            continue;
        }

        // Parse hunks for this file
        while (cursor.peek()) |hdr| {
            if (!std.mem.startsWith(u8, hdr, "@@ ")) break;
            cursor.advance();
            const hunk_header_line = hdr;
            const header = parseHunkHeader(hunk_header_line) orelse continue;

            // Collect body lines and diff_lines.
            // last_line_end tracks sliceEnd of the last consumed line; initialized to the
            // @@ line itself so raw_end is correct when no body lines are consumed.
            var diff_lines_buf: std.ArrayList(u8) = .empty;
            var last_line_end = sliceEnd(diff, hunk_header_line);

            while (cursor.peek()) |bline| {
                if (bline.len == 0) {
                    // Could be empty context line (space prefix stripped?) or end of diff.
                    // Check next line to decide.
                    const next_line = cursor.peekNext();
                    const is_body = if (next_line) |nl|
                        std.mem.startsWith(u8, nl, " ") or
                        std.mem.startsWith(u8, nl, "+") or
                        std.mem.startsWith(u8, nl, "-") or
                        std.mem.startsWith(u8, nl, "\\")
                    else
                        false;
                    if (is_body) {
                        last_line_end = sliceEnd(diff, bline);
                        cursor.advance();
                        continue;
                    }
                    break;
                }

                const first = bline[0];
                if (first == ' ' or first == '+' or first == '-') {
                    if (first == '+' or first == '-') {
                        if (diff_lines_buf.items.len > 0) {
                            try diff_lines_buf.append(arena, '\n');
                        }
                        try diff_lines_buf.appendSlice(arena, bline);
                    }
                    last_line_end = sliceEnd(diff, bline);
                    cursor.advance();
                    continue;
                }

                if (bline[0] == '\\' and std.mem.startsWith(u8, bline, "\\ No newline")) {
                    if (diff_lines_buf.items.len > 0) {
                        try diff_lines_buf.append(arena, '\n');
                    }
                    try diff_lines_buf.appendSlice(arena, bline);
                    last_line_end = sliceEnd(diff, bline);
                    cursor.advance();
                    continue;
                }

                // Not a hunk body line
                break;
            }

            // Skip hunks with no actual changes (shouldn't happen, but defensive)
            if (diff_lines_buf.items.len == 0) continue;

            // Compute raw_lines (from @@ line through end of body)
            const raw_start = sliceStart(diff, hunk_header_line);
            const raw_lines = diff[raw_start..last_line_end];

            const sha = computeHunkSha(file_path, header.stable_line(mode), diff_lines_buf.items);

            try hunks.append(arena, .{
                .file_path = file_path,
                .old_start = header.old_start,
                .old_count = header.old_count,
                .new_start = header.new_start,
                .new_count = header.new_count,
                .context = header.func_context,
                .raw_lines = raw_lines,
                .diff_lines = diff_lines_buf.items,
                .sha_hex = sha,
                .is_new_file = is_new_file,
                .is_deleted_file = is_deleted_file,
                .is_untracked = false,
                .patch_header = patch_header,
            });
        }
    }
}

/// Given a slice that points into `haystack`, return its start offset.
fn sliceStart(haystack: []const u8, slice: []const u8) usize {
    std.debug.assert(@intFromPtr(slice.ptr) >= @intFromPtr(haystack.ptr));
    const offset = @intFromPtr(slice.ptr) - @intFromPtr(haystack.ptr);
    std.debug.assert(offset <= haystack.len);
    return offset;
}

/// Given a slice that points into `haystack`, return the end offset (past last byte).
fn sliceEnd(haystack: []const u8, slice: []const u8) usize {
    const end = sliceStart(haystack, slice) + slice.len;
    std.debug.assert(end <= haystack.len);
    return end;
}

const HunkHeader = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    func_context: []const u8,

    fn stable_line(self: HunkHeader, mode: DiffMode) u32 {
        return switch (mode) {
            .unstaged => self.new_start, // + side is stable (worktree doesn't change)
            .staged => self.old_start, // - side is stable (HEAD doesn't change)
        };
    }
};

fn parseHunkHeader(line: []const u8) ?HunkHeader {
    // @@ -OLD_START[,OLD_COUNT] +NEW_START[,NEW_COUNT] @@ [context]
    if (!std.mem.startsWith(u8, line, "@@ -")) return null;

    var rest = line["@@ -".len..];

    const old_start = parseU32(&rest) orelse return null;
    var old_count: u32 = 1;
    if (rest.len > 0 and rest[0] == ',') {
        rest = rest[1..];
        old_count = parseU32(&rest) orelse return null;
    }

    if (rest.len == 0 or rest[0] != ' ') return null;
    rest = rest[1..];
    if (rest.len == 0 or rest[0] != '+') return null;
    rest = rest[1..];

    const new_start = parseU32(&rest) orelse return null;
    var new_count: u32 = 1;
    if (rest.len > 0 and rest[0] == ',') {
        rest = rest[1..];
        new_count = parseU32(&rest) orelse return null;
    }

    // Skip " @@"
    if (rest.len < 3 or !std.mem.startsWith(u8, rest, " @@")) return null;
    rest = rest[3..];

    // Optional function context after " @@"
    var func_context: []const u8 = "";
    if (rest.len > 1 and rest[0] == ' ') {
        func_context = rest[1..];
    }

    return .{
        .old_start = old_start,
        .old_count = old_count,
        .new_start = new_start,
        .new_count = new_count,
        .func_context = func_context,
    };
}

fn parseU32(s: *[]const u8) ?u32 {
    var val: u32 = 0;
    var consumed: usize = 0;
    for (s.*) |c| {
        if (c < '0' or c > '9') break;
        const digit: u32 = c - '0';
        const mul = @mulWithOverflow(val, @as(u32, 10));
        if (mul[1] != 0) return null;
        const add = @addWithOverflow(mul[0], digit);
        if (add[1] != 0) return null;
        val = add[0];
        consumed += 1;
    }
    if (consumed == 0) return null;
    s.* = s.*[consumed..];
    return val;
}

pub fn computeHunkSha(file_path: []const u8, stable_line: u32, diff_lines: []const u8) [40]u8 {
    // SHA1(file_path || '\x00' || stable_start_line_decimal || '\x00' || diff_lines)
    var hasher = std.crypto.hash.Sha1.init(.{});

    hasher.update(file_path);
    hasher.update(&[_]u8{0});

    var line_buf: [20]u8 = undefined;
    const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{stable_line}) catch "0";
    hasher.update(line_str);
    hasher.update(&[_]u8{0});

    hasher.update(diff_lines);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);

    return std.fmt.bytesToHex(digest, .lower);
}

/// C-unescape a git quoted path (handles \t, \n, \\, \", and \ooo octal).
/// Returns the input unchanged if no backslashes are present.
fn cUnescape(arena: Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '\\') == null) return input;

    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            switch (input[i]) {
                'n' => try result.append(arena, '\n'),
                't' => try result.append(arena, '\t'),
                '\\' => try result.append(arena, '\\'),
                '"' => try result.append(arena, '"'),
                'a' => try result.append(arena, 0x07),
                'b' => try result.append(arena, 0x08),
                'f' => try result.append(arena, 0x0c),
                'r' => try result.append(arena, '\r'),
                'v' => try result.append(arena, 0x0b),
                '0'...'3' => {
                    // Octal escape: up to 3 digits (max \377)
                    var val: u8 = input[i] - '0';
                    if (i + 1 < input.len and input[i + 1] >= '0' and input[i + 1] <= '7') {
                        i += 1;
                        val = val * 8 + (input[i] - '0');
                        if (i + 1 < input.len and input[i + 1] >= '0' and input[i + 1] <= '7') {
                            i += 1;
                            val = val * 8 + (input[i] - '0');
                        }
                    }
                    try result.append(arena, val);
                },
                else => {
                    try result.append(arena, '\\');
                    try result.append(arena, input[i]);
                },
            }
        } else {
            try result.append(arena, input[i]);
        }
        i += 1;
    }
    return result.items;
}

/// Extract file path from a "diff --git a/PATH b/PATH" line.
/// For non-renames, both paths are identical, so we split at the midpoint.
/// Handles both unquoted and C-quoted paths.
/// Returns null if the format is unrecognized.
fn extractPathFromDiffGitLine(arena: Allocator, line: []const u8) !?[]const u8 {
    const prefix = "diff --git ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];

    // Quoted paths: "a/PATH" "b/PATH"
    if (rest.len > 0 and rest[0] == '"') {
        // Find closing quote of first path, skipping escaped quotes
        var close_idx: ?usize = null;
        {
            var i: usize = 1;
            while (i < rest.len) : (i += 1) {
                if (rest[i] == '"' and (i == 0 or rest[i - 1] != '\\')) {
                    close_idx = i;
                    break;
                }
            }
        }
        const close1 = close_idx orelse return null;
        // Expect ' "b/' after first quoted path
        if (close1 + 1 >= rest.len or rest[close1 + 1] != ' ') return null;
        // Extract from second quoted path: "b/..."
        if (close1 + 2 >= rest.len or rest[close1 + 2] != '"') return null;
        const second_start = close1 + 3; // skip '"b' → start after 'b'
        if (second_start >= rest.len or rest[second_start] != 'b') return null;
        if (second_start + 1 >= rest.len or rest[second_start + 1] != '/') return null;
        const path_start = second_start + 2; // skip 'b/'
        var path_end = rest.len;
        if (path_end > 0 and rest[path_end - 1] == '"') path_end -= 1;
        if (path_start > path_end) return null;
        return try cUnescape(arena, rest[path_start..path_end]);
    }

    // Unquoted paths: a/PATH b/PATH
    // Both paths are identical (non-rename), so total is "a/" + PATH + " b/" + PATH
    // Length: 2 + len + 3 + len = 5 + 2*len → len = (rest.len - 5) / 2
    if (rest.len < 5) return null;
    if ((rest.len - 5) % 2 != 0) return null; // must be odd total for symmetric split
    const path_len = (rest.len - 5) / 2;
    // Verify structure: starts with "a/", has " b/" at midpoint
    if (!std.mem.startsWith(u8, rest, "a/")) return null;
    const mid = 2 + path_len; // position of space before "b/"
    if (rest[mid] != ' ' or rest[mid + 1] != 'b' or rest[mid + 2] != '/') return null;
    return rest[2..mid];
}

/// Extract file path from a ---/+++ diff line, handling both normal and C-quoted paths.
/// Returns null for /dev/null lines or unrecognized formats.
fn extractDiffPath(arena: Allocator, line: []const u8, comptime side: enum { old, new }) !?[]const u8 {
    const normal_prefix = if (side == .old) "--- a/" else "+++ b/";
    const quoted_prefix = if (side == .old) "--- \"a/" else "+++ \"b/";

    if (std.mem.startsWith(u8, line, normal_prefix)) {
        return line[normal_prefix.len..];
    }

    if (std.mem.startsWith(u8, line, quoted_prefix)) {
        var path = line[quoted_prefix.len..];
        // Remove trailing quote
        if (path.len > 0 and path[path.len - 1] == '"') {
            path = path[0 .. path.len - 1];
        }
        return try cUnescape(arena, path);
    }

    return null; // /dev/null or unrecognized
}

// ============================================================================
// Tests
// ============================================================================

test "parseHunkHeader basic" {
    const h = parseHunkHeader("@@ -1,5 +1,7 @@ fn main()").?;
    try std.testing.expectEqual(@as(u32, 1), h.old_start);
    try std.testing.expectEqual(@as(u32, 5), h.old_count);
    try std.testing.expectEqual(@as(u32, 1), h.new_start);
    try std.testing.expectEqual(@as(u32, 7), h.new_count);
    try std.testing.expectEqualStrings("fn main()", h.func_context);
}

test "parseHunkHeader no count" {
    const h = parseHunkHeader("@@ -1 +1 @@").?;
    try std.testing.expectEqual(@as(u32, 1), h.old_start);
    try std.testing.expectEqual(@as(u32, 1), h.old_count);
    try std.testing.expectEqual(@as(u32, 1), h.new_start);
    try std.testing.expectEqual(@as(u32, 1), h.new_count);
    try std.testing.expectEqualStrings("", h.func_context);
}

test "parseHunkHeader new file" {
    const h = parseHunkHeader("@@ -0,0 +1,42 @@").?;
    try std.testing.expectEqual(@as(u32, 0), h.old_start);
    try std.testing.expectEqual(@as(u32, 0), h.old_count);
    try std.testing.expectEqual(@as(u32, 1), h.new_start);
    try std.testing.expectEqual(@as(u32, 42), h.new_count);
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

test "stable_line unstaged uses new_start" {
    const h = HunkHeader{ .old_start = 5, .old_count = 3, .new_start = 10, .new_count = 4, .func_context = "" };
    try std.testing.expectEqual(@as(u32, 10), h.stable_line(.unstaged));
}

test "stable_line staged uses old_start" {
    const h = HunkHeader{ .old_start = 5, .old_count = 3, .new_start = 10, .new_count = 4, .func_context = "" };
    try std.testing.expectEqual(@as(u32, 5), h.stable_line(.staged));
}

test "parseDiff multi-hunk single file" {
    const diff =
        \\diff --git a/hello.txt b/hello.txt
        \\index abc1234..def5678 100644
        \\--- a/hello.txt
        \\+++ b/hello.txt
        \\@@ -1,5 +1,6 @@
        \\ line 1
        \\-line 2
        \\+line 2 modified
        \\ line 3
        \\ line 4
        \\ line 5
        \\@@ -17,4 +18,4 @@ line 16
        \\ line 17
        \\ line 18
        \\ line 19
        \\-line 20
        \\+line 20 changed
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);

    try std.testing.expectEqual(@as(usize, 2), hunks.items.len);

    // First hunk
    try std.testing.expectEqualStrings("hello.txt", hunks.items[0].file_path);
    try std.testing.expectEqual(@as(u32, 1), hunks.items[0].new_start);
    try std.testing.expectEqual(@as(u32, 6), hunks.items[0].new_count);

    // Second hunk
    try std.testing.expectEqualStrings("hello.txt", hunks.items[1].file_path);
    try std.testing.expectEqual(@as(u32, 18), hunks.items[1].new_start);
    try std.testing.expectEqual(@as(u32, 4), hunks.items[1].new_count);
    try std.testing.expectEqualStrings("line 16", hunks.items[1].context);
}

test "parseDiff multi-file" {
    const diff =
        \\diff --git a/a.txt b/a.txt
        \\index 1234567..abcdefg 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,4 @@
        \\ line 1
        \\+new line
        \\ line 2
        \\ line 3
        \\diff --git a/b.txt b/b.txt
        \\index 2345678..bcdefga 100644
        \\--- a/b.txt
        \\+++ b/b.txt
        \\@@ -1,2 +1,2 @@
        \\-old
        \\+new
        \\ kept
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);

    try std.testing.expectEqual(@as(usize, 2), hunks.items.len);
    try std.testing.expectEqualStrings("a.txt", hunks.items[0].file_path);
    try std.testing.expectEqualStrings("b.txt", hunks.items[1].file_path);
}

test "parseDiff new file" {
    const diff =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\index 0000000..abcdefg
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1,2 @@
        \\+line 1
        \\+line 2
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("new.txt", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].is_new_file);
}

test "parseU32 basic" {
    var s: []const u8 = "42rest";
    const v = parseU32(&s).?;
    try std.testing.expectEqual(@as(u32, 42), v);
    try std.testing.expectEqualStrings("rest", s);
}

test "parseU32 empty returns null" {
    var s: []const u8 = "";
    try std.testing.expectEqual(@as(?u32, null), parseU32(&s));
}

test "parseU32 non-digit returns null" {
    var s: []const u8 = "abc";
    try std.testing.expectEqual(@as(?u32, null), parseU32(&s));
}

test "parseU32 overflow returns null" {
    var s: []const u8 = "9999999999";
    try std.testing.expectEqual(@as(?u32, null), parseU32(&s));
}

test "cUnescape no escapes passthrough" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try cUnescape(arena.allocator(), "simple/path.txt");
    try std.testing.expectEqualStrings("simple/path.txt", result);
}

test "cUnescape tab" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try cUnescape(arena.allocator(), "a\\tb");
    try std.testing.expectEqualStrings("a\tb", result);
}

test "cUnescape newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try cUnescape(arena.allocator(), "a\\nb");
    try std.testing.expectEqualStrings("a\nb", result);
}

test "cUnescape backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try cUnescape(arena.allocator(), "a\\\\b");
    try std.testing.expectEqualStrings("a\\b", result);
}

test "cUnescape quote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try cUnescape(arena.allocator(), "a\\\"b");
    try std.testing.expectEqualStrings("a\"b", result);
}

test "cUnescape octal basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // \101 = octal 65 = 'A'
    const result = try cUnescape(arena.allocator(), "\\101");
    try std.testing.expectEqualStrings("A", result);
}

test "cUnescape octal utf8 path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // git encodes non-ASCII: \303\234 = UTF-8 bytes 0xC3 0x9C (Ü)
    const result = try cUnescape(arena.allocator(), "\\303\\234berstand");
    try std.testing.expectEqualStrings("\xc3\x9cberstand", result);
}

test "extractDiffPath new side normal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractDiffPath(arena.allocator(), "+++ b/src/main.zig", .new);
    try std.testing.expectEqualStrings("src/main.zig", result.?);
}

test "extractDiffPath old side normal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractDiffPath(arena.allocator(), "--- a/src/main.zig", .old);
    try std.testing.expectEqualStrings("src/main.zig", result.?);
}

test "extractDiffPath dev null returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractDiffPath(arena.allocator(), "--- /dev/null", .old);
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "extractDiffPath quoted path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractDiffPath(arena.allocator(), "+++ \"b/path with spaces.txt\"", .new);
    try std.testing.expectEqualStrings("path with spaces.txt", result.?);
}

test "extractDiffPath quoted path with escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // +++ "b/dir\twith\ttabs.txt" — backslash-t in the input → tab in output
    const result = try extractDiffPath(arena.allocator(), "+++ \"b/dir\\twith\\ttabs.txt\"", .new);
    try std.testing.expectEqualStrings("dir\twith\ttabs.txt", result.?);
}

test "parseDiff deleted file" {
    const diff =
        \\diff --git a/old.txt b/old.txt
        \\deleted file mode 100644
        \\index abcdefg..0000000
        \\--- a/old.txt
        \\+++ /dev/null
        \\@@ -1,2 +0,0 @@
        \\-line 1
        \\-line 2
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("old.txt", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].is_deleted_file);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].patch_header, "deleted file mode") != null);
}

test "parseDiff binary file skipped" {
    const diff =
        \\diff --git a/img.png b/img.png
        \\index 1234567..abcdefg 100644
        \\Binary files a/img.png and b/img.png differ
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);
    try std.testing.expectEqual(@as(usize, 0), hunks.items.len);
}

test "parseDiff submodule skipped" {
    const diff =
        \\diff --git a/libs/sub b/libs/sub
        \\index abc1234..def5678 160000
        \\--- a/libs/sub
        \\+++ b/libs/sub
        \\@@ -1 +1 @@
        \\-Subproject commit abc1234
        \\+Subproject commit def5678
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);
    try std.testing.expectEqual(@as(usize, 0), hunks.items.len);
}

test "parseDiff no newline at end of file" {
    const diff =
        \\diff --git a/f.txt b/f.txt
        \\index 1234567..abcdefg 100644
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\\ No newline at end of file
        \\+new
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].diff_lines, "\\ No newline") != null);
}

test "parseDiff rename with content" {
    const diff =
        \\diff --git a/old.txt b/new.txt
        \\similarity index 80%
        \\rename from old.txt
        \\rename to new.txt
        \\index 1234567..abcdefg 100644
        \\--- a/old.txt
        \\+++ b/new.txt
        \\@@ -1,3 +1,3 @@
        \\ context line
        \\-old content
        \\+new content
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("new.txt", hunks.items[0].file_path);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].patch_header, "rename from") != null);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].patch_header, "rename to") != null);
}

test "parseDiff c-quoted path" {
    const diff =
        \\diff --git "a/path with spaces.txt" "b/path with spaces.txt"
        \\index 1234567..abcdefg 100644
        \\--- "a/path with spaces.txt"
        \\+++ "b/path with spaces.txt"
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("path with spaces.txt", hunks.items[0].file_path);
}

test "parseDiff empty input" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, "", .unstaged, &hunks);
    try std.testing.expectEqual(@as(usize, 0), hunks.items.len);
}

test "parseDiff mode-only change" {
    const diff =
        \\diff --git a/f.sh b/f.sh
        \\old mode 100644
        \\new mode 100755
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);
    try std.testing.expectEqual(@as(usize, 0), hunks.items.len);
}

test "parseDiff staged mode produces different sha" {
    const diff =
        \\diff --git a/hello.txt b/hello.txt
        \\index abc1234..def5678 100644
        \\--- a/hello.txt
        \\+++ b/hello.txt
        \\@@ -5,3 +10,3 @@
        \\ line 1
        \\-old
        \\+new
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks_unstaged: std.ArrayList(Hunk) = .empty;
    var hunks_staged: std.ArrayList(Hunk) = .empty;
    defer hunks_unstaged.deinit(arena);
    defer hunks_staged.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks_unstaged);
    try parseDiff(arena, diff, .staged, &hunks_staged);

    // Staged uses old_start=5, unstaged uses new_start=10 → different SHAs
    try std.testing.expect(!std.mem.eql(
        u8,
        &hunks_unstaged.items[0].sha_hex,
        &hunks_staged.items[0].sha_hex,
    ));
}

test "parseDiff empty new file" {
    const diff =
        \\diff --git a/empty.txt b/empty.txt
        \\new file mode 100644
        \\index 0000000..e69de29
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("empty.txt", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].is_new_file);
    try std.testing.expectEqualStrings("", hunks.items[0].raw_lines);
    try std.testing.expectEqualStrings("", hunks.items[0].diff_lines);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].patch_header, "new file mode 100644") != null);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].patch_header, "--- /dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].patch_header, "+++ b/empty.txt") != null);
}

test "parseDiff empty deleted file" {
    const diff =
        \\diff --git a/empty.txt b/empty.txt
        \\deleted file mode 100644
        \\index e69de29..0000000
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .staged, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("empty.txt", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].is_deleted_file);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].patch_header, "deleted file mode 100644") != null);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].patch_header, "--- a/empty.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].patch_header, "+++ /dev/null") != null);
}

test "parseDiff empty file among non-empty files" {
    const diff =
        \\diff --git a/a.txt b/a.txt
        \\index 1234567..abcdefg 100644
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1,3 +1,4 @@
        \\ line 1
        \\+new line
        \\ line 2
        \\ line 3
        \\diff --git a/empty.txt b/empty.txt
        \\new file mode 100644
        \\index 0000000..e69de29
        \\diff --git a/b.txt b/b.txt
        \\index 2345678..bcdefga 100644
        \\--- a/b.txt
        \\+++ b/b.txt
        \\@@ -1,2 +1,2 @@
        \\-old
        \\+new
        \\ kept
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .unstaged, &hunks);

    try std.testing.expectEqual(@as(usize, 3), hunks.items.len);
    try std.testing.expectEqualStrings("a.txt", hunks.items[0].file_path);
    try std.testing.expectEqualStrings("empty.txt", hunks.items[1].file_path);
    try std.testing.expect(hunks.items[1].is_new_file);
    try std.testing.expectEqualStrings("b.txt", hunks.items[2].file_path);
}

test "extractPathFromDiffGitLine unquoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractPathFromDiffGitLine(arena.allocator(), "diff --git a/foo.txt b/foo.txt");
    try std.testing.expectEqualStrings("foo.txt", result.?);
}

test "extractPathFromDiffGitLine nested path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractPathFromDiffGitLine(arena.allocator(), "diff --git a/src/main.zig b/src/main.zig");
    try std.testing.expectEqualStrings("src/main.zig", result.?);
}

test "extractPathFromDiffGitLine quoted path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractPathFromDiffGitLine(arena.allocator(), "diff --git \"a/path with spaces.txt\" \"b/path with spaces.txt\"");
    try std.testing.expectEqualStrings("path with spaces.txt", result.?);
}

test "extractPathFromDiffGitLine missing prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractPathFromDiffGitLine(arena.allocator(), "not a diff line");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "extractPathFromDiffGitLine asymmetric unquoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Different-length paths make odd total length fail the symmetric split
    const result = try extractPathFromDiffGitLine(arena.allocator(), "diff --git a/foo.txt b/barbaz.txt");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "extractPathFromDiffGitLine empty rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractPathFromDiffGitLine(arena.allocator(), "diff --git ");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "extractPathFromDiffGitLine escaped quote in path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Filename contains a literal quote: file"name.txt
    // Git C-quotes it as: "a/file\"name.txt" "b/file\"name.txt"
    const result = try extractPathFromDiffGitLine(arena.allocator(), "diff --git \"a/file\\\"name.txt\" \"b/file\\\"name.txt\"");
    try std.testing.expectEqualStrings("file\"name.txt", result.?);
}
