const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// ============================================================================
// Types
// ============================================================================

const Hunk = struct {
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

const DiffMode = enum { unstaged, staged };

const OutputMode = enum { human, porcelain };

const ListOptions = struct {
    mode: DiffMode = .unstaged,
    file_filter: ?[]const u8 = null,
    output: OutputMode = .human,
};

const AddRemoveOptions = struct {
    sha_prefixes: std.ArrayList([]const u8),
    file_filter: ?[]const u8 = null,
};

// ============================================================================
// Entry point
// ============================================================================

pub fn main() void {
    run() catch |err| {
        fatal("{s}", .{@errorName(err)});
    };
}

fn run() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(stdout);
        try stdout.flush();
        std.process.exit(1);
    }

    const subcmd = args[1];

    if (std.mem.eql(u8, subcmd, "list")) {
        const opts = parseListArgs(args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        try cmdList(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        var opts = parseAddRemoveArgs(allocator, args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        defer opts.sha_prefixes.deinit(allocator);
        try cmdAdd(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        var opts = parseAddRemoveArgs(allocator, args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        defer opts.sha_prefixes.deinit(allocator);
        try cmdRemove(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "help")) {
        try printUsage(stdout);
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{subcmd});
        try printUsage(stdout);
        try stdout.flush();
        std.process.exit(1);
    }
    try stdout.flush();
}

fn printUsage(stdout: *std.Io.Writer) !void {
    try stdout.print(
        \\usage: git-hunk <command> [<args>]
        \\
        \\commands:
        \\  list [--staged] [--file <path>] [--porcelain]   List diff hunks
        \\  add <sha>... [--file <path>]                    Stage hunks
        \\  remove <sha>... [--file <path>]                 Unstage hunks
        \\
    , .{});
}

fn parseListArgs(args: []const [:0]u8) !ListOptions {
    var opts: ListOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--porcelain")) {
            opts.output = .porcelain;
        } else if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.file_filter = args[i];
        } else {
            return error.UnknownFlag;
        }
    }
    return opts;
}

fn parseAddRemoveArgs(allocator: Allocator, args: []const [:0]u8) !AddRemoveOptions {
    var opts: AddRemoveOptions = .{
        .sha_prefixes = .empty,
    };
    errdefer opts.sha_prefixes.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.file_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            // SHA prefix — validate it's hex and at least 4 chars
            if (arg.len < 4) {
                std.debug.print("error: sha prefix too short (minimum 4 chars): '{s}'\n", .{arg});
                return error.InvalidArgument;
            }
            for (arg) |c| {
                if (!isHexDigit(c)) {
                    std.debug.print("error: invalid hex in sha prefix: '{s}'\n", .{arg});
                    return error.InvalidArgument;
                }
            }
            try opts.sha_prefixes.append(allocator, arg);
        }
    }

    if (opts.sha_prefixes.items.len == 0) {
        std.debug.print("error: at least one <sha> argument required\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// ============================================================================
// List command
// ============================================================================

fn cmdList(allocator: Allocator, stdout: *std.Io.Writer, opts: ListOptions) !void {
    const diff_output = try runGitDiff(allocator, opts.mode);
    defer allocator.free(diff_output);

    if (diff_output.len == 0) return;

    // Use arena for all hunk-related allocations
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    // Arena owns all hunk data; ArrayList itself also uses arena
    defer hunks.deinit(arena);

    try parseDiff(arena, diff_output, opts.mode, &hunks);

    // Apply file filter and output
    for (hunks.items) |h| {
        if (opts.file_filter) |filter| {
            if (!std.mem.eql(u8, h.file_path, filter)) continue;
        }
        switch (opts.output) {
            .human => try printHunkHuman(stdout, h, opts.mode),
            .porcelain => try printHunkPorcelain(stdout, h, opts.mode),
        }
    }
}

// ============================================================================
// Add / Remove commands
// ============================================================================

fn cmdAdd(allocator: Allocator, stdout: *std.Io.Writer, opts: AddRemoveOptions) !void {
    try cmdApplyHunks(allocator, stdout, opts, .stage);
}

fn cmdRemove(allocator: Allocator, stdout: *std.Io.Writer, opts: AddRemoveOptions) !void {
    try cmdApplyHunks(allocator, stdout, opts, .unstage);
}

const ApplyAction = enum { stage, unstage };

fn cmdApplyHunks(allocator: Allocator, stdout: *std.Io.Writer, opts: AddRemoveOptions, action: ApplyAction) !void {
    // For staging: diff unstaged hunks (index vs worktree)
    // For unstaging: diff staged hunks (HEAD vs index)
    const diff_mode: DiffMode = switch (action) {
        .stage => .unstaged,
        .unstage => .staged,
    };

    const diff_output = try runGitDiff(allocator, diff_mode);
    defer allocator.free(diff_output);

    if (diff_output.len == 0) {
        const msg = switch (action) {
            .stage => "no unstaged changes\n",
            .unstage => "no staged changes\n",
        };
        std.debug.print("{s}", .{msg});
        std.process.exit(1);
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);
    try parseDiff(arena, diff_output, diff_mode, &hunks);

    // Resolve each SHA prefix to a hunk, deduplicating by full SHA
    var matched: std.ArrayList(*const Hunk) = .empty;
    defer matched.deinit(arena);

    for (opts.sha_prefixes.items) |prefix| {
        const hunk = findHunkByShaPrefix(hunks.items, prefix, opts.file_filter) catch |err| switch (err) {
            error.NotFound => {
                std.debug.print("error: no hunk matching '{s}'\n", .{prefix});
                std.process.exit(1);
            },
            error.AmbiguousPrefix => {
                std.debug.print("error: ambiguous prefix '{s}' — matches multiple hunks\n", .{prefix});
                std.process.exit(1);
            },
            else => return err,
        };
        // Deduplicate: skip if this exact hunk (by full SHA) is already matched
        var already_matched = false;
        for (matched.items) |existing| {
            if (std.mem.eql(u8, &existing.sha_hex, &hunk.sha_hex)) {
                already_matched = true;
                break;
            }
        }
        if (!already_matched) {
            try matched.append(arena, hunk);
        }
    }

    // Build combined patch and apply
    const patch = try buildCombinedPatch(arena, matched.items);
    const reverse = action == .unstage;
    try runGitApply(allocator, patch, reverse);

    // Report what was applied
    const verb: []const u8 = switch (action) {
        .stage => "staged",
        .unstage => "unstaged",
    };
    for (matched.items) |h| {
        try stdout.print("{s} {s}  {s}\n", .{ verb, h.sha_hex[0..7], h.file_path });
    }
}

fn findHunkByShaPrefix(hunks: []const Hunk, prefix: []const u8, file_filter: ?[]const u8) !*const Hunk {
    var match: ?*const Hunk = null;
    for (hunks) |*h| {
        if (file_filter) |filter| {
            if (!std.mem.eql(u8, h.file_path, filter)) continue;
        }
        if (std.mem.startsWith(u8, &h.sha_hex, prefix)) {
            if (match != null) return error.AmbiguousPrefix;
            match = h;
        }
    }
    return match orelse error.NotFound;
}

fn buildCombinedPatch(arena: Allocator, hunks: []const *const Hunk) ![]const u8 {
    var patch: std.ArrayList(u8) = .empty;

    // Group hunks by patch_header to combine hunks from the same file
    // under a single header. We iterate in order and track the last header.
    var last_header: []const u8 = "";
    for (hunks) |h| {
        if (!std.mem.eql(u8, h.patch_header, last_header)) {
            try patch.appendSlice(arena, h.patch_header);
            last_header = h.patch_header;
        }
        try patch.appendSlice(arena, h.raw_lines);
        // Ensure trailing newline
        if (h.raw_lines.len > 0 and h.raw_lines[h.raw_lines.len - 1] != '\n') {
            try patch.append(arena, '\n');
        }
    }

    return patch.items;
}

// ============================================================================
// Git interaction
// ============================================================================

fn runGitDiff(allocator: Allocator, mode: DiffMode) ![]u8 {
    const argv: []const []const u8 = switch (mode) {
        .unstaged => &.{ "git", "diff", "--src-prefix=a/", "--dst-prefix=b/", "--no-color" },
        .staged => &.{ "git", "diff", "--cached", "--src-prefix=a/", "--dst-prefix=b/", "--no-color" },
    };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var child_stdout: std.ArrayList(u8) = .empty;
    defer child_stdout.deinit(allocator);
    var child_stderr: std.ArrayList(u8) = .empty;
    defer child_stderr.deinit(allocator);

    const max_bytes = 10 * 1024 * 1024; // 10 MB
    try child.collectOutput(allocator, &child_stdout, &child_stderr, max_bytes);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                if (child_stderr.items.len > 0) {
                    std.debug.print("{s}", .{child_stderr.items});
                }
                fatal("git diff exited with code {d}", .{code});
            }
        },
        else => fatal("git diff terminated abnormally", .{}),
    }

    const owned = try allocator.alloc(u8, child_stdout.items.len);
    @memcpy(owned, child_stdout.items);
    return owned;
}

fn runGitApply(allocator: Allocator, patch: []const u8, reverse: bool) !void {
    const argv: []const []const u8 = if (reverse)
        &.{ "git", "apply", "--cached", "--reverse" }
    else
        &.{ "git", "apply", "--cached" };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Write patch to stdin, then close
    const stdin_file = child.stdin.?;
    stdin_file.writeAll(patch) catch {};
    stdin_file.close();
    child.stdin = null;

    var child_stdout: std.ArrayList(u8) = .empty;
    defer child_stdout.deinit(allocator);
    var child_stderr: std.ArrayList(u8) = .empty;
    defer child_stderr.deinit(allocator);

    const max_bytes = 1 * 1024 * 1024;
    try child.collectOutput(allocator, &child_stdout, &child_stderr, max_bytes);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                if (child_stderr.items.len > 0) {
                    std.debug.print("{s}", .{child_stderr.items});
                }
                std.debug.print("error: patch did not apply cleanly — re-run 'list' and try again\n", .{});
                std.process.exit(1);
            }
        },
        else => fatal("git apply terminated abnormally", .{}),
    }
}

// ============================================================================
// Diff parser — index-based, two-pass approach
// ============================================================================

fn parseDiff(arena: Allocator, diff: []const u8, mode: DiffMode, hunks: *std.ArrayList(Hunk)) !void {
    // Split into lines (keeping slices into original buffer)
    var line_list: std.ArrayList([]const u8) = .empty;
    defer line_list.deinit(arena);

    var iter = std.mem.splitScalar(u8, diff, '\n');
    while (iter.next()) |line| {
        try line_list.append(arena, line);
    }
    const lines = line_list.items;

    var i: usize = 0;
    while (i < lines.len) {
        // Look for "diff --git" to start a new file section
        if (!std.mem.startsWith(u8, lines[i], "diff --git ")) {
            i += 1;
            continue;
        }

        const diff_git_line = lines[i];
        i += 1;

        // Parse extended headers
        var is_new_file = false;
        var is_deleted_file = false;
        var is_binary = false;

        while (i < lines.len) {
            const line = lines[i];
            if (std.mem.startsWith(u8, line, "new file mode ")) {
                is_new_file = true;
            } else if (std.mem.startsWith(u8, line, "deleted file mode ")) {
                is_deleted_file = true;
            } else if (std.mem.startsWith(u8, line, "Binary files ")) {
                is_binary = true;
            } else if (std.mem.startsWith(u8, line, "old mode ") or
                std.mem.startsWith(u8, line, "new mode ") or
                std.mem.startsWith(u8, line, "similarity index ") or
                std.mem.startsWith(u8, line, "rename from ") or
                std.mem.startsWith(u8, line, "rename to ") or
                std.mem.startsWith(u8, line, "copy from ") or
                std.mem.startsWith(u8, line, "copy to ") or
                std.mem.startsWith(u8, line, "index "))
            {
                // Extended header, continue
            } else {
                break; // Not an extended header
            }
            i += 1;
        }

        if (is_binary) continue;

        // Expect ---/+++ lines
        if (i >= lines.len or !std.mem.startsWith(u8, lines[i], "--- ")) continue;
        const minus_line = lines[i];
        i += 1;

        if (i >= lines.len or !std.mem.startsWith(u8, lines[i], "+++ ")) continue;
        const plus_line = lines[i];
        i += 1;

        // Extract file path
        var file_path: []const u8 = undefined;
        if (is_deleted_file) {
            // For deletions, use --- path
            if (std.mem.startsWith(u8, minus_line, "--- a/")) {
                file_path = minus_line["--- a/".len..];
            } else continue;
        } else {
            // For everything else, use +++ path
            if (std.mem.startsWith(u8, plus_line, "+++ b/")) {
                file_path = plus_line["+++ b/".len..];
            } else continue;
        }

        // Build patch header
        var patch_header: []const u8 = undefined;
        if (is_new_file or is_deleted_file) {
            // Need full diff --git header for new/deleted files
            var ph: std.ArrayList(u8) = .empty;
            try ph.appendSlice(arena, diff_git_line);
            try ph.append(arena, '\n');
            if (is_new_file) {
                try ph.appendSlice(arena, "new file mode 100644\n");
            } else {
                try ph.appendSlice(arena, "deleted file mode 100644\n");
            }
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

        // Parse hunks for this file
        while (i < lines.len and std.mem.startsWith(u8, lines[i], "@@ ")) {
            const hunk_header_line = lines[i];
            const header = parseHunkHeader(hunk_header_line) orelse {
                i += 1;
                continue;
            };
            i += 1;

            // Collect body lines and diff_lines
            const body_start = i;
            var diff_lines_buf: std.ArrayList(u8) = .empty;

            while (i < lines.len) {
                const bline = lines[i];
                if (bline.len == 0) {
                    // Could be empty context line (space prefix stripped?) or end of diff.
                    // Check next line to decide.
                    if (i + 1 < lines.len and
                        (std.mem.startsWith(u8, lines[i + 1], " ") or
                        std.mem.startsWith(u8, lines[i + 1], "+") or
                        std.mem.startsWith(u8, lines[i + 1], "-") or
                        std.mem.startsWith(u8, lines[i + 1], "\\")))
                    {
                        i += 1;
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
                    i += 1;
                    continue;
                }

                if (bline[0] == '\\' and std.mem.startsWith(u8, bline, "\\ No newline")) {
                    if (diff_lines_buf.items.len > 0) {
                        try diff_lines_buf.append(arena, '\n');
                    }
                    try diff_lines_buf.appendSlice(arena, bline);
                    i += 1;
                    continue;
                }

                // Not a hunk body line
                break;
            }

            // Skip hunks with no actual changes (shouldn't happen, but defensive)
            if (diff_lines_buf.items.len == 0) continue;

            // Compute raw_lines (from @@ line through end of body)
            const raw_start = sliceStart(diff, hunk_header_line);
            const raw_end = if (i > body_start) sliceEnd(diff, lines[i - 1]) else sliceEnd(diff, hunk_header_line);
            const raw_lines = diff[raw_start..raw_end];

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
                .patch_header = patch_header,
            });
        }
    }
}

/// Given a slice that points into `haystack`, return its start offset.
fn sliceStart(haystack: []const u8, slice: []const u8) usize {
    return @intFromPtr(slice.ptr) - @intFromPtr(haystack.ptr);
}

/// Given a slice that points into `haystack`, return the end offset (past last byte).
fn sliceEnd(haystack: []const u8, slice: []const u8) usize {
    return sliceStart(haystack, slice) + slice.len;
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
        val = val *% 10 +% (c - '0');
        consumed += 1;
    }
    if (consumed == 0) return null;
    s.* = s.*[consumed..];
    return val;
}

// ============================================================================
// Hashing
// ============================================================================

fn computeHunkSha(file_path: []const u8, stable_line: u32, diff_lines: []const u8) [40]u8 {
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

// ============================================================================
// Output formatting
// ============================================================================

fn printHunkHuman(stdout: *std.Io.Writer, h: Hunk, mode: DiffMode) !void {
    const short_sha = h.sha_hex[0..7];
    var summary_buf: [64]u8 = undefined;
    const summary = hunkSummaryWithFallback(&summary_buf, h);

    var range_buf: [24]u8 = undefined;
    const range = formatLineRange(&range_buf, h, mode);

    try stdout.print("{s}  {s:<40}  {s:<8}  {s}\n", .{ short_sha, h.file_path, range, summary });
}

fn printHunkPorcelain(stdout: *std.Io.Writer, h: Hunk, mode: DiffMode) !void {
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
    if (h.context.len > 0) return h.context;
    if (h.is_new_file) return "new file";
    if (h.is_deleted_file) return "deleted";
    // No function context — extract first changed line as summary
    return firstChangedLine(buf, h.diff_lines);
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
    return std.fmt.bufPrint(buf, "{d}-{d}", .{ start, end }) catch "";
}

// ============================================================================
// Utility
// ============================================================================

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", args);
    std.process.exit(1);
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
