const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Hunk = types.Hunk;
const FileSection = types.FileSection;
const BodyLine = types.BodyLine;
const Anchor = types.Anchor;

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

/// State accumulated by `parseExtendedHeaders` for the per-file header block
/// between `diff --git` and the body. All slices are sub-slices of the input.
const FileHeaderState = struct {
    is_new_file: bool = false,
    is_deleted_file: bool = false,
    is_binary: bool = false,
    is_submodule: bool = false,
    is_symlink: bool = false,
    /// An `old mode`/`new mode` pair was present. The mode change itself is
    /// never representable as a hunk, whether or not the file also has
    /// content changes.
    has_mode_change: bool = false,
    file_mode: []const u8 = "100644",
    rename_from: ?[]const u8 = null,
    rename_to: ?[]const u8 = null,
    copy_from: ?[]const u8 = null,
    copy_to: ?[]const u8 = null,
    /// Verbatim "index <oldsha>..<newsha> [mode]" line, when present. Preserved
    /// so reconstructed patches retain blob ids — required for `git apply --3way`.
    index_line: ?[]const u8 = null,
};

/// Consume extended-header lines (new/deleted file mode, Binary, rename, index,
/// old/new mode, similarity, copy) until a non-header line is reached. Stops
/// without consuming the first non-header line.
fn parseExtendedHeaders(cursor: *DiffCursor) FileHeaderState {
    var state: FileHeaderState = .{};
    while (cursor.peek()) |line| {
        if (std.mem.startsWith(u8, line, "new file mode ")) {
            state.is_new_file = true;
            state.file_mode = line["new file mode ".len..];
            if (std.mem.eql(u8, state.file_mode, "120000")) state.is_symlink = true;
        } else if (std.mem.startsWith(u8, line, "deleted file mode ")) {
            state.is_deleted_file = true;
            state.file_mode = line["deleted file mode ".len..];
            if (std.mem.eql(u8, state.file_mode, "120000")) state.is_symlink = true;
        } else if (std.mem.startsWith(u8, line, "Binary files ")) {
            state.is_binary = true;
        } else if (std.mem.startsWith(u8, line, "rename from ")) {
            state.rename_from = line["rename from ".len..];
        } else if (std.mem.startsWith(u8, line, "rename to ")) {
            state.rename_to = line["rename to ".len..];
        } else if (std.mem.startsWith(u8, line, "copy from ")) {
            state.copy_from = line["copy from ".len..];
        } else if (std.mem.startsWith(u8, line, "copy to ")) {
            state.copy_to = line["copy to ".len..];
        } else if (std.mem.startsWith(u8, line, "index ")) {
            state.index_line = line;
            if (std.mem.endsWith(u8, line, " 160000")) {
                state.is_submodule = true;
            } else if (std.mem.endsWith(u8, line, " 120000")) {
                state.is_symlink = true;
            }
        } else if (std.mem.startsWith(u8, line, "old mode ") or
            std.mem.startsWith(u8, line, "new mode "))
        {
            state.has_mode_change = true;
        } else if (std.mem.startsWith(u8, line, "similarity index ")) {
            // Extended header, continue.
        } else {
            break;
        }
        cursor.advance();
    }
    return state;
}

/// The shared record of one file section. Allocated on its own so hunks can
/// point at it while the hunk list grows.
fn newSection(
    arena: Allocator,
    header: FileHeader,
    minus_line: ?[]const u8,
    plus_line: ?[]const u8,
    is_untracked: bool,
) !*FileSection {
    const state = header.state;
    const section = try arena.create(FileSection);
    section.* = .{
        .diff_git_line = header.diff_git_line,
        .is_new_file = state.is_new_file,
        .is_deleted_file = state.is_deleted_file,
        .file_mode = state.file_mode,
        .rename_from = state.rename_from,
        .rename_to = state.rename_to,
        .renamed_from_path = if (state.rename_from) |from| try unquotePath(arena, from) else null,
        .copy_from = state.copy_from,
        .copy_to = state.copy_to,
        .copied_from_path = if (state.copy_from) |from| try unquotePath(arena, from) else null,
        .index_line = state.index_line,
        .minus_line = minus_line,
        .plus_line = plus_line,
        .is_binary = state.is_binary,
        .is_symlink = state.is_symlink,
        .is_untracked = is_untracked,
    };
    return section;
}

/// Build a synthetic whole-file hunk (no line-level content) for the binary,
/// empty-file, or empty-after-headers cases. `sha_payload` is hashed alongside
/// the file path / line 0 to disambiguate between cases.
fn synthesizeWholeFileHunk(file_path: []const u8, section: *const FileSection, sha_payload: []const u8) Hunk {
    return .{
        .file_path = file_path,
        .old_start = 0,
        .old_count = 0,
        .new_start = 0,
        .new_count = 0,
        .context = "",
        .raw_lines = "",
        .diff_lines = "",
        .sha_hex = computeHunkSha(file_path, 0, sha_payload),
        .section = section,
    };
}

/// A binary change has no lines to hash, so its blob ids stand in for them:
/// without them every change to one binary path would share a hash, and a
/// hash taken before the file changed again would still match.
fn binaryShaPayload(arena: Allocator, index_line: ?[]const u8) ![]const u8 {
    const line = index_line orelse return "binary";
    const ids = line["index ".len..];
    const end = std.mem.indexOfScalar(u8, ids, ' ') orelse ids.len;
    return std.mem.concat(arena, u8, &.{ "binary ", ids[0..end] });
}

const HunkBody = struct {
    diff_lines: []const u8,
    raw_lines: []const u8,
};

/// An empty line is a blank context line (git strips its leading space under
/// some configurations) only when more body follows; otherwise it ends the diff.
fn continuesBody(next_line: ?[]const u8) bool {
    const line = next_line orelse return false;
    return line.len > 0 and BodyLine.Kind.of(line) != .other;
}

/// Parse the body of a single `@@` hunk. Consumes context, +, -, and "\ No newline"
/// lines until a non-body line is reached. Returns null if the body is empty.
fn parseHunkBody(arena: Allocator, cursor: *DiffCursor, diff: []const u8, hunk_header_line: []const u8) !?HunkBody {
    var diff_lines_buf: std.ArrayList(u8) = .empty;
    // last_line_end tracks the end-of-line of the last consumed line; initialized
    // to the @@ line itself so raw_lines is correct even if no body lines are consumed.
    var last_line_end = sliceEnd(diff, hunk_header_line);

    while (cursor.peek()) |bline| {
        const kind = BodyLine.Kind.of(bline);
        const in_body = switch (kind) {
            .context => bline.len > 0 or continuesBody(cursor.peekNext()),
            .removal, .addition => true,
            .no_newline => std.mem.startsWith(u8, bline, "\\ No newline"),
            .other => false,
        };
        if (!in_body) break;

        if (kind != .context) {
            if (diff_lines_buf.items.len > 0) try diff_lines_buf.append(arena, '\n');
            try diff_lines_buf.appendSlice(arena, bline);
        }
        last_line_end = sliceEnd(diff, bline);
        cursor.advance();
    }

    if (diff_lines_buf.items.len == 0) return null;
    return .{
        .diff_lines = diff_lines_buf.items,
        .raw_lines = diff[sliceStart(diff, hunk_header_line)..last_line_end],
    };
}

/// Why a changed path produced no hunk. Each corresponds to a documented
/// skip in `parseDiff`.
const SkipReason = enum {
    submodule,
    mode_only,
    rename_only,
    copy_only,
    other,

    /// Subject of the note: what about this path has no hunk.
    pub fn describe(self: SkipReason) []const u8 {
        return switch (self) {
            .submodule => "submodule pointer change",
            .mode_only => "mode change",
            .rename_only => "rename with no content change",
            .copy_only => "copy with no content change",
            .other => "change",
        };
    }
};

pub const SkippedPath = struct {
    file_path: []const u8,
    reason: SkipReason,
};

/// Paths that `diff` reports as changed but that `parseDiff` produces no hunk
/// for. git considers these files dirty; git-hunk has no hash to address them
/// by, so without this they read as a clean tree.
///
/// Derived from the same text `parseDiff` consumed rather than from a parallel
/// set of skip rules, so a new skip cannot go unreported.
pub fn collectSkippedPaths(
    arena: Allocator,
    diff: []const u8,
    hunks: []const Hunk,
    out: *std.ArrayList(SkippedPath),
) !void {
    var cursor = DiffCursor.init(diff);
    while (nextFileHeader(&cursor)) |header| {
        const state = header.state;
        const file_path = (try sectionFilePath(arena, header.diff_git_line, state)) orelse continue;

        var has_hunk = false;
        for (hunks) |h| {
            if (std.mem.eql(u8, h.file_path, file_path)) {
                has_hunk = true;
                break;
            }
        }

        // A mode change is unrepresentable even when the same file also has
        // content hunks, so it is reported either way.
        if (has_hunk and !state.has_mode_change) continue;

        const reason: SkipReason = if (state.has_mode_change)
            .mode_only
        else if (state.is_submodule)
            .submodule
        else if (state.rename_from != null)
            .rename_only
        else if (state.copy_from != null)
            .copy_only
        else
            .other;
        try out.append(arena, .{ .file_path = file_path, .reason = reason });
    }
}

/// Parse `diff` into `hunks`, hashing each by its start line on the `anchor` side.
pub fn parseDiff(arena: Allocator, diff: []const u8, anchor: Anchor, hunks: *std.ArrayList(Hunk)) !void {
    try parseSections(arena, diff, anchor, false, hunks);
}

/// Parse `git diff --no-index` output for untracked files, marking every
/// section untracked.
pub fn parseUntrackedDiff(arena: Allocator, diff: []const u8, hunks: *std.ArrayList(Hunk)) !void {
    try parseSections(arena, diff, .new, true, hunks);
}

fn parseSections(arena: Allocator, diff: []const u8, anchor: Anchor, is_untracked: bool, hunks: *std.ArrayList(Hunk)) !void {
    var cursor = DiffCursor.init(diff);
    var previous: ?*FileSection = null;
    while (nextFileHeader(&cursor)) |header| {
        const section = try parseFileSection(arena, &cursor, diff, header, anchor, is_untracked, hunks);
        if (section != null and previous != null) linkTypechange(previous.?, section.?);
        previous = section;
    }
}

/// git writes a typechange as two sections for one path, the deletion first.
fn linkTypechange(deleted: *FileSection, created: *FileSection) void {
    if (!deleted.is_deleted_file or !created.is_new_file) return;
    if (!std.mem.eql(u8, deleted.diff_git_line, created.diff_git_line)) return;
    deleted.is_typechange = true;
    created.is_typechange = true;
}

/// The opening of one file's section: its `diff --git` line and the extended
/// headers after it.
const FileHeader = struct {
    diff_git_line: []const u8,
    state: FileHeaderState,
};

/// Skip to the next `diff --git` line and consume it with its extended
/// headers. Null once the input runs out.
fn nextFileHeader(cursor: *DiffCursor) ?FileHeader {
    while (cursor.peek()) |line| {
        cursor.advance();
        if (!std.mem.startsWith(u8, line, "diff --git ")) continue;
        return .{ .diff_git_line = line, .state = parseExtendedHeaders(cursor) };
    }
    return null;
}

/// Parse what follows one file header into `hunks`: a synthesized whole-file
/// hunk for binaries and empty new/deleted files, else one hunk per `@@`.
/// Sections with nothing representable (submodules, mode or rename only)
/// add nothing. Returns the section parsed, or null for one skipped.
fn parseFileSection(
    arena: Allocator,
    cursor: *DiffCursor,
    diff: []const u8,
    header: FileHeader,
    anchor: Anchor,
    is_untracked: bool,
    hunks: *std.ArrayList(Hunk),
) !?*FileSection {
    const state = header.state;
    if (state.is_submodule) return null;
    const is_whole_file = state.is_new_file or state.is_deleted_file;

    if (state.is_binary) {
        const file_path = (try sectionFilePath(arena, header.diff_git_line, state)) orelse return null;
        const section = try newSection(arena, header, null, null, is_untracked);
        try hunks.append(arena, synthesizeWholeFileHunk(file_path, section, try binaryShaPayload(arena, state.index_line)));
        return section;
    }

    const minus_line = cursor.peek() orelse "";
    if (!std.mem.startsWith(u8, minus_line, "--- ")) {
        // An empty new/deleted file has no ---/+++ at all.
        if (!is_whole_file) return null;
        const file_path = (try sectionFilePath(arena, header.diff_git_line, state)) orelse return null;
        const section = try newSection(arena, header, null, null, is_untracked);
        try hunks.append(arena, synthesizeWholeFileHunk(file_path, section, ""));
        return section;
    }
    cursor.advance();
    const plus_line = cursor.peek() orelse return null;
    if (!std.mem.startsWith(u8, plus_line, "+++ ")) return null;
    cursor.advance();

    const file_path = if (state.is_deleted_file)
        (try extractDiffPath(arena, minus_line, .old)) orelse return null
    else
        (try extractDiffPath(arena, plus_line, .new)) orelse return null;

    const section = try newSection(arena, header, minus_line, plus_line, is_untracked);

    // Some Linux git versions give an empty new/deleted file ---/+++ but no @@.
    const at_follows = if (cursor.peek()) |line| std.mem.startsWith(u8, line, "@@ ") else false;
    if (!at_follows and is_whole_file) {
        try hunks.append(arena, synthesizeWholeFileHunk(file_path, section, ""));
        return section;
    }

    while (cursor.peek()) |hdr| {
        if (!std.mem.startsWith(u8, hdr, "@@ ")) break;
        cursor.advance();
        const hunk_header = parseHunkHeader(hdr) orelse continue;
        const body = (try parseHunkBody(arena, cursor, diff, hdr)) orelse continue;
        try hunks.append(arena, .{
            .file_path = file_path,
            .old_start = hunk_header.old_start,
            .old_count = hunk_header.old_count,
            .new_start = hunk_header.new_start,
            .new_count = hunk_header.new_count,
            .context = hunk_header.func_context,
            .raw_lines = body.raw_lines,
            .diff_lines = body.diff_lines,
            .sha_hex = computeHunkSha(file_path, hunk_header.anchorLine(anchor), body.diff_lines),
            .section = section,
        });
    }
    return section;
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

    fn anchorLine(self: HunkHeader, anchor: Anchor) u32 {
        return switch (anchor) {
            .new => self.new_start,
            .old => self.old_start,
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

const computeHunkSha = types.computeHunkSha;

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

/// The path a file section's hunks belong to. A rename or copy names its new
/// path in `rename to`/`copy to`, which is unambiguous where the `diff --git`
/// line is not.
fn sectionFilePath(arena: Allocator, diff_git_line: []const u8, state: FileHeaderState) !?[]const u8 {
    const to = state.rename_to orelse state.copy_to orelse return extractPathFromDiffGitLine(arena, diff_git_line);
    return try unquotePath(arena, to);
}

/// A path as git writes it in `rename from`/`rename to` and `copy from`/
/// `copy to`, C-quoted when it has to be.
fn unquotePath(arena: Allocator, path: []const u8) ![]const u8 {
    if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') return try cUnescape(arena, path[1 .. path.len - 1]);
    return path;
}

/// Extract file path from a "diff --git a/PATH b/PATH" line.
/// For non-renames, both paths are identical, so we split at the midpoint.
/// Handles both unquoted and C-quoted paths.
/// Returns null if the format is unrecognized, or if the two unquoted halves
/// differ (a rename, whose path comes from `rename to` instead).
fn extractPathFromDiffGitLine(arena: Allocator, line: []const u8) !?[]const u8 {
    const prefix = "diff --git ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];

    // Quoted paths: "a/PATH" "b/PATH"
    if (rest.len > 0 and rest[0] == '"') {
        const close1 = findClosingQuote(rest) orelse return null;
        const second = rest[close1 + 1 ..];
        if (!std.mem.startsWith(u8, second, " \"b/")) return null;
        const quoted = second[" \"b/".len..];
        if (!std.mem.endsWith(u8, quoted, "\"")) return null;
        return try cUnescape(arena, quoted[0 .. quoted.len - 1]);
    }

    // Unquoted paths: a/PATH b/PATH
    // Both paths are identical (non-rename), so total is "a/" + PATH + " b/" + PATH
    // Length: 2 + len + 3 + len = 5 + 2*len → len = (rest.len - 5) / 2
    if (rest.len < 5) return null;
    if ((rest.len - 5) % 2 != 0) return null; // must be odd total for symmetric split
    const path_len = (rest.len - 5) / 2;
    if (!std.mem.startsWith(u8, rest, "a/")) return null;
    const mid = 2 + path_len; // position of space before "b/"
    if (!std.mem.eql(u8, rest[mid..][0..3], " b/")) return null;
    const a_path = rest[2..mid];
    if (!std.mem.eql(u8, a_path, rest[mid + 3 ..])) return null;
    return a_path;
}

/// Index of the quote closing the C-quoted string that `s` opens with. A
/// backslash escapes the byte after it, so `\\"` closes where `\"` does not.
fn findClosingQuote(s: []const u8) ?usize {
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => i += 1,
            '"' => return i,
            else => {},
        }
    }
    return null;
}

/// Extract file path from a ---/+++ diff line, handling both normal and C-quoted paths.
/// Returns null for /dev/null lines or unrecognized formats.
fn extractDiffPath(arena: Allocator, raw_line: []const u8, comptime side: enum { old, new }) !?[]const u8 {
    const normal_prefix = if (side == .old) "--- a/" else "+++ b/";
    const quoted_prefix = if (side == .old) "--- \"a/" else "+++ \"b/";
    const line = withoutNameTerminator(raw_line);

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

/// git ends a `---`/`+++` name that contains a space with a TAB, so the end
/// of the name stays visible. A name that really ends in a TAB is always
/// C-quoted, so only this terminator can be a raw trailing TAB.
fn withoutNameTerminator(line: []const u8) []const u8 {
    if (!std.mem.endsWith(u8, line, "\t")) return line;
    const trimmed = line[0 .. line.len - 1];
    if (trimmed.len <= "--- ".len) return line;
    if (std.mem.indexOfScalar(u8, trimmed["--- ".len..], ' ') == null) return line;
    return trimmed;
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

test "anchorLine new uses new_start" {
    const h = HunkHeader{ .old_start = 5, .old_count = 3, .new_start = 10, .new_count = 4, .func_context = "" };
    try std.testing.expectEqual(@as(u32, 10), h.anchorLine(.new));
}

test "anchorLine old uses old_start" {
    const h = HunkHeader{ .old_start = 5, .old_count = 3, .new_start = 10, .new_count = 4, .func_context = "" };
    try std.testing.expectEqual(@as(u32, 5), h.anchorLine(.old));
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

    try parseDiff(arena, diff, .new, &hunks);

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

    // Both hunks share one section, which keeps the `index <oldsha>..<newsha>`
    // line verbatim — required for `git apply --3way` to find the original blob.
    try std.testing.expect(hunks.items[0].section == hunks.items[1].section);
    try std.testing.expectEqualStrings("index abc1234..def5678 100644", hunks.items[0].section.index_line.?);
    try std.testing.expectEqualStrings("diff --git a/hello.txt b/hello.txt", hunks.items[0].section.diff_git_line);
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

    try parseDiff(arena, diff, .new, &hunks);

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

    try parseDiff(arena, diff, .new, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("new.txt", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].section.is_new_file);
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

test "extractDiffPath drops the tab git ends a spaced name with" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a b.txt", (try extractDiffPath(a, "+++ b/a b.txt\t", .new)).?);
    try std.testing.expectEqualStrings("a b.txt", (try extractDiffPath(a, "--- a/a b.txt\t", .old)).?);
    try std.testing.expectEqualStrings("\xc3\xbc b.txt", (try extractDiffPath(a, "+++ \"b/\\303\\274 b.txt\"\t", .new)).?);
    try std.testing.expectEqualStrings("trailing space ", (try extractDiffPath(a, "+++ b/trailing space \t", .new)).?);
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

    try parseDiff(arena, diff, .new, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("old.txt", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].section.is_deleted_file);
    try std.testing.expectEqualStrings("100644", hunks.items[0].section.file_mode);
}

test "parseDiff binary file produces hunk" {
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

    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("img.png", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].section.is_binary);
    try std.testing.expect(!hunks.items[0].section.is_new_file);
    try std.testing.expect(!hunks.items[0].section.is_deleted_file);
    try std.testing.expectEqualStrings("", hunks.items[0].raw_lines);
    try std.testing.expectEqualStrings("", hunks.items[0].diff_lines);
    // The blob ids stand in for the lines a text hunk would hash.
    const expected_sha = computeHunkSha("img.png", 0, "binary 1234567..abcdefg");
    try std.testing.expectEqualStrings(&expected_sha, &hunks.items[0].sha_hex);
}

test "parseDiff hashes two changes to one binary path differently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var hunks: std.ArrayList(Hunk) = .empty;
    try parseDiff(arena.allocator(), "diff --git a/b b/b\nindex 1111111..2222222 100644\nBinary files a/b and b/b differ\n", .new, &hunks);
    try parseDiff(arena.allocator(), "diff --git a/b b/b\nindex 1111111..3333333 100644\nBinary files a/b and b/b differ\n", .new, &hunks);
    try std.testing.expectEqual(@as(usize, 2), hunks.items.len);
    try std.testing.expect(!std.mem.eql(u8, &hunks.items[0].sha_hex, &hunks.items[1].sha_hex));
}

test "parseDiff new binary file" {
    const diff =
        \\diff --git a/data.db b/data.db
        \\new file mode 100644
        \\index 0000000..abcdefg
        \\Binary files /dev/null and b/data.db differ
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("data.db", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].section.is_binary);
    try std.testing.expect(hunks.items[0].section.is_new_file);
}

test "parseDiff deleted binary file" {
    const diff =
        \\diff --git a/old.bin b/old.bin
        \\deleted file mode 100644
        \\index abcdefg..0000000
        \\Binary files a/old.bin and /dev/null differ
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("old.bin", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].section.is_binary);
    try std.testing.expect(hunks.items[0].section.is_deleted_file);
}

test "parseDiff binary and text files together" {
    const diff =
        \\diff --git a/img.png b/img.png
        \\index 1234567..abcdefg 100644
        \\Binary files a/img.png and b/img.png differ
        \\diff --git a/readme.txt b/readme.txt
        \\index 1111111..2222222 100644
        \\--- a/readme.txt
        \\+++ b/readme.txt
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

    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 2), hunks.items.len);
    try std.testing.expectEqualStrings("img.png", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].section.is_binary);
    try std.testing.expectEqualStrings("readme.txt", hunks.items[1].file_path);
    try std.testing.expect(!hunks.items[1].section.is_binary);
}

test "parseDiff symlink detected via index line mode" {
    const diff =
        \\diff --git a/link.txt b/link.txt
        \\index 1234567..abcdefg 120000
        \\--- a/link.txt
        \\+++ b/link.txt
        \\@@ -1 +1 @@
        \\-old-target
        \\+new-target
    ;

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("link.txt", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].section.is_symlink);
    try std.testing.expect(!hunks.items[0].section.is_binary);
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

    try parseDiff(arena, diff, .new, &hunks);
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

    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expect(std.mem.indexOf(u8, hunks.items[0].diff_lines, "\\ No newline") != null);
}

test "parseDiff copy keeps its copy lines and takes the copy's path" {
    const diff =
        \\diff --git a/src.txt b/dst.txt
        \\similarity index 92%
        \\copy from src.txt
        \\copy to dst.txt
        \\index 1234567..abcdefg 100644
        \\--- a/src.txt
        \\+++ b/dst.txt
        \\@@ -1,2 +1,3 @@
        \\ one
        \\ two
        \\+extra
        \\diff --git a/src.txt b/pure.txt
        \\similarity index 100%
        \\copy from src.txt
        \\copy to pure.txt
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var hunks: std.ArrayList(Hunk) = .empty;
    try parseDiff(arena, diff, .new, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    const section = hunks.items[0].section;
    try std.testing.expectEqualStrings("dst.txt", hunks.items[0].file_path);
    try std.testing.expectEqualStrings("src.txt", section.copy_from.?);
    try std.testing.expectEqualStrings("dst.txt", section.copy_to.?);
    try std.testing.expectEqualStrings("src.txt", section.copied_from_path.?);
    try std.testing.expectEqual(@as(?[]const u8, null), section.renamed_from_path);

    var skipped: std.ArrayList(SkippedPath) = .empty;
    try collectSkippedPaths(arena, diff, hunks.items, &skipped);
    try std.testing.expectEqual(@as(usize, 1), skipped.items.len);
    try std.testing.expectEqualStrings("pure.txt", skipped.items[0].file_path);
    try std.testing.expectEqual(SkipReason.copy_only, skipped.items[0].reason);
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

    try parseDiff(arena, diff, .new, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("new.txt", hunks.items[0].file_path);
    try std.testing.expectEqualStrings("old.txt", hunks.items[0].section.rename_from.?);
    try std.testing.expectEqualStrings("new.txt", hunks.items[0].section.rename_to.?);
    try std.testing.expectEqualStrings("old.txt", hunks.items[0].section.renamed_from_path.?);
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

    try parseDiff(arena, diff, .new, &hunks);

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

    try parseDiff(arena, "", .new, &hunks);
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

    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 0), hunks.items.len);
}

test "parseDiff old anchor produces different sha" {
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

    try parseDiff(arena, diff, .new, &hunks_unstaged);
    try parseDiff(arena, diff, .old, &hunks_staged);

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

    try parseDiff(arena, diff, .new, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("empty.txt", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].section.is_new_file);
    try std.testing.expectEqualStrings("", hunks.items[0].raw_lines);
    try std.testing.expectEqualStrings("", hunks.items[0].diff_lines);
    try std.testing.expectEqualStrings("100644", hunks.items[0].section.file_mode);
    try std.testing.expect(hunks.items[0].section.minus_line == null);
    try std.testing.expect(hunks.items[0].section.plus_line == null);
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

    try parseDiff(arena, diff, .old, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("empty.txt", hunks.items[0].file_path);
    try std.testing.expect(hunks.items[0].section.is_deleted_file);
    try std.testing.expectEqualStrings("100644", hunks.items[0].section.file_mode);
    try std.testing.expect(hunks.items[0].section.minus_line == null);
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

    try parseDiff(arena, diff, .new, &hunks);

    try std.testing.expectEqual(@as(usize, 3), hunks.items.len);
    try std.testing.expectEqualStrings("a.txt", hunks.items[0].file_path);
    try std.testing.expectEqualStrings("empty.txt", hunks.items[1].file_path);
    try std.testing.expect(hunks.items[1].section.is_new_file);
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

test "extractPathFromDiffGitLine same-length rename is not split" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractPathFromDiffGitLine(arena.allocator(), "diff --git a/a.bin b/b.bin");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "extractPathFromDiffGitLine quoted path ending in backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Filename `dir\` quotes to "a/dir\\": the backslash before the closing
    // quote is itself escaped, so that quote does close the string.
    const result = try extractPathFromDiffGitLine(arena.allocator(), "diff --git \"a/dir\\\\\" \"b/dir\\\\\"");
    try std.testing.expectEqualStrings("dir\\", result.?);
}

test "extractPathFromDiffGitLine quoted path ending in escaped quote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extractPathFromDiffGitLine(arena.allocator(), "diff --git \"a/q\\\"\" \"b/q\\\"\"");
    try std.testing.expectEqualStrings("q\"", result.?);
}

test "parseDiff links the two halves of a typechange" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const diff =
        \\diff --git a/tc b/tc
        \\deleted file mode 100644
        \\index 1234567..0000000
        \\--- a/tc
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-text
        \\diff --git a/tc b/tc
        \\new file mode 120000
        \\index 0000000..89abcde
        \\--- /dev/null
        \\+++ b/tc
        \\@@ -0,0 +1 @@
        \\+target
        \\\ No newline at end of file
        \\diff --git a/u b/u
        \\new file mode 100644
        \\index 0000000..89abcde
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+u
        \\
    ;
    var hunks: std.ArrayList(Hunk) = .empty;
    try parseDiff(arena.allocator(), diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 3), hunks.items.len);
    try std.testing.expect(hunks.items[0].section.is_typechange);
    try std.testing.expect(hunks.items[1].section.is_typechange);
    try std.testing.expect(!hunks.items[2].section.is_typechange);
}

test "parseDiff binary rename takes the new path from rename to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const diff =
        \\diff --git a/a.bin b/b.bin
        \\similarity index 60%
        \\rename from a.bin
        \\rename to b.bin
        \\index abcdefg..1234567 100644
        \\Binary files a/a.bin and b/b.bin differ
        \\
    ;
    var hunks: std.ArrayList(Hunk) = .empty;
    try parseDiff(arena.allocator(), diff, .old, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("b.bin", hunks.items[0].file_path);
}

test "parseDiff unquotes the path a rename came from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const diff =
        \\diff --git "a/h\303\251llo.txt" b/hello.txt
        \\similarity index 80%
        \\rename from "h\303\251llo.txt"
        \\rename to hello.txt
        \\index 1234567..abcdefg 100644
        \\--- "a/h\303\251llo.txt"
        \\+++ b/hello.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    var hunks: std.ArrayList(Hunk) = .empty;
    try parseDiff(arena.allocator(), diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("h\xc3\xa9llo.txt", hunks.items[0].section.renamed_from_path.?);
    try std.testing.expectEqualStrings("\"h\\303\\251llo.txt\"", hunks.items[0].section.rename_from.?);
}

test "collectSkippedPaths reports a pure rename under its new path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const diff =
        \\diff --git a/short b/much-longer-name
        \\similarity index 100%
        \\rename from short
        \\rename to much-longer-name
        \\
    ;
    var skipped: std.ArrayList(SkippedPath) = .empty;
    try collectSkippedPaths(arena.allocator(), diff, &.{}, &skipped);
    try std.testing.expectEqual(@as(usize, 1), skipped.items.len);
    try std.testing.expectEqualStrings("much-longer-name", skipped.items[0].file_path);
    try std.testing.expectEqual(SkipReason.rename_only, skipped.items[0].reason);
}

test "extractPathFromDiffGitLine escaped quote in path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Filename contains a literal quote: file"name.txt
    // Git C-quotes it as: "a/file\"name.txt" "b/file\"name.txt"
    const result = try extractPathFromDiffGitLine(arena.allocator(), "diff --git \"a/file\\\"name.txt\" \"b/file\\\"name.txt\"");
    try std.testing.expectEqualStrings("file\"name.txt", result.?);
}

test "parseExtendedHeaders: new file mode 100644" {
    const lines = "new file mode 100644\nindex 0000000..abc1234\n--- /dev/null";
    var cursor = DiffCursor.init(lines);
    const state = parseExtendedHeaders(&cursor);
    try std.testing.expect(state.is_new_file);
    try std.testing.expect(!state.is_deleted_file);
    try std.testing.expect(!state.is_symlink);
    try std.testing.expectEqualStrings("100644", state.file_mode);
    // Stops at the --- line without consuming it.
    try std.testing.expect(std.mem.startsWith(u8, cursor.peek().?, "--- "));
}

test "parseExtendedHeaders: new file mode 120000 sets is_symlink" {
    const lines = "new file mode 120000\nindex 0000000..abc1234";
    var cursor = DiffCursor.init(lines);
    const state = parseExtendedHeaders(&cursor);
    try std.testing.expect(state.is_new_file);
    try std.testing.expect(state.is_symlink);
}

test "parseExtendedHeaders: deleted file mode 100644" {
    const lines = "deleted file mode 100644\nindex abc1234..0000000";
    var cursor = DiffCursor.init(lines);
    const state = parseExtendedHeaders(&cursor);
    try std.testing.expect(state.is_deleted_file);
    try std.testing.expect(!state.is_new_file);
}

test "parseExtendedHeaders: deleted file mode 120000 sets is_symlink" {
    const lines = "deleted file mode 120000";
    var cursor = DiffCursor.init(lines);
    const state = parseExtendedHeaders(&cursor);
    try std.testing.expect(state.is_deleted_file);
    try std.testing.expect(state.is_symlink);
}

test "collectSkippedPaths: submodule pointer bump" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\diff --git a/sub b/sub
        \\index df697a8..1eeb846 160000
        \\--- a/sub
        \\+++ b/sub
        \\@@ -1 +1 @@
        \\-Subproject commit df697a83ef08ce65e9182be309f7766d72fddadf
        \\+Subproject commit 1eeb8464791fd87c90a3a5b5b7801ab7c43347c4
        \\
    ;
    var hunks: std.ArrayList(Hunk) = .empty;
    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 0), hunks.items.len);

    var skipped: std.ArrayList(SkippedPath) = .empty;
    try collectSkippedPaths(arena, diff, hunks.items, &skipped);
    try std.testing.expectEqual(@as(usize, 1), skipped.items.len);
    try std.testing.expectEqualStrings("sub", skipped.items[0].file_path);
    try std.testing.expectEqual(SkipReason.submodule, skipped.items[0].reason);
}

test "collectSkippedPaths: mode-only change" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\diff --git a/run.sh b/run.sh
        \\old mode 100644
        \\new mode 100755
        \\
    ;
    var hunks: std.ArrayList(Hunk) = .empty;
    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 0), hunks.items.len);

    var skipped: std.ArrayList(SkippedPath) = .empty;
    try collectSkippedPaths(arena, diff, hunks.items, &skipped);
    try std.testing.expectEqual(@as(usize, 1), skipped.items.len);
    try std.testing.expectEqualStrings("run.sh", skipped.items[0].file_path);
    try std.testing.expectEqual(SkipReason.mode_only, skipped.items[0].reason);
}

test "collectSkippedPaths: mode change alongside content still reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\diff --git a/run.sh b/run.sh
        \\old mode 100644
        \\new mode 100755
        \\index f0f2307..7c30781
        \\--- a/run.sh
        \\+++ b/run.sh
        \\@@ -1,3 +1,3 @@
        \\ l1
        \\-l2
        \\+CHANGED
        \\ l3
        \\
    ;
    var hunks: std.ArrayList(Hunk) = .empty;
    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);

    var skipped: std.ArrayList(SkippedPath) = .empty;
    try collectSkippedPaths(arena, diff, hunks.items, &skipped);
    try std.testing.expectEqual(@as(usize, 1), skipped.items.len);
    try std.testing.expectEqual(SkipReason.mode_only, skipped.items[0].reason);
}

test "collectSkippedPaths: an ordinary edit is not reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\diff --git a/f.txt b/f.txt
        \\index f0f2307..7c30781 100644
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,3 +1,3 @@
        \\ l1
        \\-l2
        \\+CHANGED
        \\ l3
        \\
    ;
    var hunks: std.ArrayList(Hunk) = .empty;
    try parseDiff(arena, diff, .new, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);

    var skipped: std.ArrayList(SkippedPath) = .empty;
    try collectSkippedPaths(arena, diff, hunks.items, &skipped);
    try std.testing.expectEqual(@as(usize, 0), skipped.items.len);
}

test "parseExtendedHeaders: index ... 160000 sets is_submodule" {
    const lines = "index abc1234..def5678 160000";
    var cursor = DiffCursor.init(lines);
    const state = parseExtendedHeaders(&cursor);
    try std.testing.expect(state.is_submodule);
}

test "parseExtendedHeaders: index ... 120000 sets is_symlink" {
    const lines = "index abc1234..def5678 120000";
    var cursor = DiffCursor.init(lines);
    const state = parseExtendedHeaders(&cursor);
    try std.testing.expect(state.is_symlink);
    try std.testing.expect(!state.is_submodule);
}

test "parseExtendedHeaders: Binary files marker sets is_binary" {
    const lines = "Binary files a/img.png and b/img.png differ";
    var cursor = DiffCursor.init(lines);
    const state = parseExtendedHeaders(&cursor);
    try std.testing.expect(state.is_binary);
}

test "parseExtendedHeaders: rename from/to captures both" {
    const lines = "rename from old.txt\nrename to new.txt\n--- a/old.txt";
    var cursor = DiffCursor.init(lines);
    const state = parseExtendedHeaders(&cursor);
    try std.testing.expectEqualStrings("old.txt", state.rename_from.?);
    try std.testing.expectEqualStrings("new.txt", state.rename_to.?);
}

test "parseExtendedHeaders: stops at first non-header line" {
    const lines = "@@ -1 +1 @@\nbody";
    var cursor = DiffCursor.init(lines);
    const state = parseExtendedHeaders(&cursor);
    try std.testing.expect(!state.is_new_file);
    try std.testing.expect(!state.is_binary);
    // @@ line was not consumed.
    try std.testing.expect(std.mem.startsWith(u8, cursor.peek().?, "@@ "));
}

test "parseExtendedHeaders: noop arms (old mode/new mode/similarity/copy)" {
    const lines = "old mode 100644\nnew mode 100755\nsimilarity index 95%\ncopy from x\ncopy to y\n--- /dev/null";
    var cursor = DiffCursor.init(lines);
    const state = parseExtendedHeaders(&cursor);
    // None of these affect state (just keep the loop going)
    try std.testing.expect(!state.is_new_file);
    try std.testing.expect(!state.is_deleted_file);
    try std.testing.expect(state.rename_from == null);
    // Stops at the --- line.
    try std.testing.expect(std.mem.startsWith(u8, cursor.peek().?, "--- "));
}

// ============================================================================
// Fuzzing
// ============================================================================

/// Fuzz entry: parseDiff must never panic or return an error on arbitrary
/// input, and every hunk it produces must be hashable. Under `zig build test`
/// (no --fuzz) this replays the seed corpus as deterministic regression inputs.
fn fuzzParseDiff(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [1 << 16]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x9e3779b9);
    const input = buf[0..len];

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for ([_]Anchor{ .new, .old }) |anchor| {
        var hunks: std.ArrayList(Hunk) = .empty;
        try parseDiff(arena, input, anchor, &hunks);
        for (hunks.items) |h| {
            for (h.sha_hex) |c| try std.testing.expect(std.ascii.isHex(c));
        }
    }
}

/// Smith slice draws consume a 4-byte little-endian length prefix from corpus
/// input; wrap readable seed diffs so they replay as the intended bytes.
fn fuzzCorpusEntry(comptime s: []const u8) []const u8 {
    comptime {
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, s.len, .little);
        const arr = len_bytes ++ s[0..s.len].*;
        const final = arr;
        return &final;
    }
}

const fuzz_corpus: []const []const u8 = &.{
    fuzzCorpusEntry("diff --git a/f.txt b/f.txt\nindex 1234567..89abcde 100644\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,3 @@ fn ctx()\n line\n-old\n+new\n+added\n"),
    fuzzCorpusEntry("diff --git a/new.txt b/new.txt\nnew file mode 100644\nindex 0000000..e69de29\n"),
    fuzzCorpusEntry("diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\nindex e69de29..0000000\n"),
    fuzzCorpusEntry("diff --git a/img.png b/img.png\nindex 1234567..89abcde 100644\nGIT binary patch\nliteral 5\nMc$`b\n\nliteral 0\nHc$@<O00001\n"),
    fuzzCorpusEntry("diff --git a/link b/link\nnew file mode 120000\nindex 0000000..1de5659\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+target\n\\ No newline at end of file\n"),
    fuzzCorpusEntry("diff --git a/sub b/sub\nindex 1234567..89abcde 160000\n--- a/sub\n+++ b/sub\n@@ -1 +1 @@\n-Subproject commit aaaa\n+Subproject commit bbbb\n"),
    fuzzCorpusEntry("diff --git a/r.txt b/s.txt\nsimilarity index 90%\nrename from r.txt\nrename to s.txt\nindex 1234567..89abcde 100644\n--- a/r.txt\n+++ b/s.txt\n@@ -1 +1 @@\n-a\n+b\n"),
    fuzzCorpusEntry("diff --git a/x b/x\n@@ -1 +1 @@\n"),
    fuzzCorpusEntry(""),
};

test "fuzz parseDiff" {
    try std.testing.fuzz({}, fuzzParseDiff, .{ .corpus = fuzz_corpus });
}
