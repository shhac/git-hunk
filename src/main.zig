const std = @import("std");
const build_options = @import("build_options");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// ANSI color escape codes — only used in human mode when stdout is a TTY
const COLOR_RESET = "\x1b[0m";
const COLOR_YELLOW = "\x1b[33m"; // SHA hash
const COLOR_GREEN = "\x1b[32m"; // added lines (+)
const COLOR_RED = "\x1b[31m"; // removed lines (-)

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
    show_diff: bool = false,
    no_color: bool = false,
};

const AddRemoveOptions = struct {
    sha_prefixes: std.ArrayList([]const u8),
    file_filter: ?[]const u8 = null,
    select_all: bool = false,
};

const ShowOptions = struct {
    sha_prefixes: std.ArrayList([]const u8),
    file_filter: ?[]const u8 = null,
    mode: DiffMode = .unstaged,
    output: OutputMode = .human,
    no_color: bool = false,
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

    var stdout_buffer: [64 * 1024]u8 = undefined;
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
    } else if (std.mem.eql(u8, subcmd, "show")) {
        var opts = parseShowArgs(allocator, args[2..]) catch {
            try printUsage(stdout);
            try stdout.flush();
            std.process.exit(1);
        };
        defer opts.sha_prefixes.deinit(allocator);
        try cmdShow(allocator, stdout, opts);
    } else if (std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "-V")) {
        try stdout.print("git-hunk {s}\n", .{build_options.version});
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
    try stdout.print("git-hunk {s}\n", .{build_options.version});
    try stdout.print(
        \\
        \\usage: git-hunk <command> [<args>]
        \\
        \\commands:
        \\  list [--staged] [--file <path>] [--porcelain] [--diff] [--no-color]
        \\                                                List diff hunks
        \\  show <sha>... [--staged] [--file <path>] [--porcelain] [--no-color]
        \\                                                Show diff content of hunks
        \\  add [--all] [--file <path>] [<sha>...]          Stage hunks
        \\  remove [--all] [--file <path>] [<sha>...]       Unstage hunks
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
        } else if (std.mem.eql(u8, arg, "--diff")) {
            opts.show_diff = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
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
        } else if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
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

    if (opts.sha_prefixes.items.len == 0 and !opts.select_all and opts.file_filter == null) {
        std.debug.print("error: at least one <sha> argument required (or use --all or --file <path>)\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

fn parseShowArgs(allocator: Allocator, args: []const [:0]u8) !ShowOptions {
    var opts: ShowOptions = .{
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
        } else if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--porcelain")) {
            opts.output = .porcelain;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
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

/// Compare hunks for sorting: by file path, then by old_start (line order within file).
fn hunkPatchOrder(_: void, a: *const Hunk, b: *const Hunk) bool {
    const path_order = std.mem.order(u8, a.file_path, b.file_path);
    if (path_order != .eq) return path_order == .lt;
    return a.old_start < b.old_start;
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

    // Compute display parameters for human mode
    const use_color = opts.output == .human and !opts.no_color and
        std.fs.File.stdout().isTty() and posix.getenv("NO_COLOR") == null;
    const term_width = if (use_color or opts.output == .human) getTerminalWidth() else 80;

    // Pre-pass: find max file path length for dynamic column width (human mode only)
    var max_path_len: usize = 0;
    if (opts.output == .human) {
        for (hunks.items) |h| {
            if (opts.file_filter) |filter| {
                if (!std.mem.eql(u8, h.file_path, filter)) continue;
            }
            max_path_len = @max(max_path_len, h.file_path.len);
        }
    }
    const col_width = @max(max_path_len, 20);

    // Apply file filter, output, and count
    var hunk_count: usize = 0;
    var file_count: usize = 0;
    var last_file: []const u8 = "";

    for (hunks.items) |h| {
        if (opts.file_filter) |filter| {
            if (!std.mem.eql(u8, h.file_path, filter)) continue;
        }
        if (!std.mem.eql(u8, h.file_path, last_file)) {
            file_count += 1;
            last_file = h.file_path;
        }
        hunk_count += 1;
        switch (opts.output) {
            .human => try printHunkHuman(stdout, h, opts.mode, col_width, term_width, use_color),
            .porcelain => try printHunkPorcelain(stdout, h, opts.mode),
        }
        if (opts.show_diff) {
            switch (opts.output) {
                .human => try printDiffHuman(stdout, h, use_color),
                .porcelain => try printDiffPorcelain(stdout, h),
            }
        }
    }

    // Count summary (human output only, when there are hunks)
    if (opts.output == .human and hunk_count > 0) {
        std.debug.print("{d} hunks across {d} files\n", .{ hunk_count, file_count });
    }

    // Hint about untracked files (human output, unstaged mode only)
    if (opts.output == .human and opts.mode == .unstaged) {
        const untracked = countUntrackedFiles(allocator) catch 0;
        if (untracked > 0) {
            std.debug.print("hint: {d} untracked file(s) not shown -- use 'git add -N <file>' to include\n", .{untracked});
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

    // Resolve hunks to apply: bulk mode (--all or bare --file) or SHA prefix matching
    var matched: std.ArrayList(*const Hunk) = .empty;
    defer matched.deinit(arena);

    if (opts.sha_prefixes.items.len == 0) {
        // Bulk mode: match all hunks, optionally filtered by file
        for (hunks.items) |*h| {
            if (opts.file_filter) |filter| {
                if (!std.mem.eql(u8, h.file_path, filter)) continue;
            }
            try matched.append(arena, h);
        }
    } else {
        // SHA prefix matching mode
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
    }

    // Sort hunks by file path and line order for a valid combined patch
    std.mem.sort(*const Hunk, matched.items, {}, hunkPatchOrder);

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

// ============================================================================
// Show command
// ============================================================================

fn cmdShow(allocator: Allocator, stdout: *std.Io.Writer, opts: ShowOptions) !void {
    const diff_output = try runGitDiff(allocator, opts.mode);
    defer allocator.free(diff_output);

    if (diff_output.len == 0) {
        const msg: []const u8 = switch (opts.mode) {
            .unstaged => "no unstaged changes\n",
            .staged => "no staged changes\n",
        };
        std.debug.print("{s}", .{msg});
        std.process.exit(1);
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);
    try parseDiff(arena, diff_output, opts.mode, &hunks);

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

    const use_color = opts.output == .human and !opts.no_color and
        std.fs.File.stdout().isTty() and posix.getenv("NO_COLOR") == null;

    // Print each matched hunk
    for (matched.items) |h| {
        switch (opts.output) {
            .human => {
                try stdout.writeAll(h.patch_header);
                try printRawLinesHuman(stdout, h.raw_lines, use_color);
                try stdout.writeAll("\n");
            },
            .porcelain => {
                try printHunkPorcelain(stdout, h.*, opts.mode);
                try printDiffPorcelain(stdout, h.*);
            },
        }
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
    errdefer child_stdout.deinit(allocator);
    var child_stderr: std.ArrayList(u8) = .empty;
    defer child_stderr.deinit(allocator);

    const max_bytes = 10 * 1024 * 1024; // 10 MB
    child.collectOutput(allocator, &child_stdout, &child_stderr, max_bytes) catch |err| {
        if (err == error.StreamTooLong) {
            std.debug.print("error: diff output exceeds 10 MB -- use --file to narrow scope\n", .{});
            std.process.exit(1);
        }
        return err;
    };
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

    return try child_stdout.toOwnedSlice(allocator);
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

fn countUntrackedFiles(allocator: Allocator) !u32 {
    const argv: []const []const u8 = &.{ "git", "ls-files", "--others", "--exclude-standard" };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var child_stdout: std.ArrayList(u8) = .empty;
    defer child_stdout.deinit(allocator);
    var child_stderr: std.ArrayList(u8) = .empty;
    defer child_stderr.deinit(allocator);

    const max_bytes = 1 * 1024 * 1024; // 1 MB
    try child.collectOutput(allocator, &child_stdout, &child_stderr, max_bytes);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) return 0; // Best-effort: silently ignore errors
        },
        else => return 0,
    }

    const output = std.mem.trimRight(u8, child_stdout.items, "\n");
    if (output.len == 0) return 0;

    var count: u32 = 1;
    for (output) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

// ============================================================================
// Diff parser — index-based, two-pass approach
// ============================================================================

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

fn parseDiff(arena: Allocator, diff: []const u8, mode: DiffMode, hunks: *std.ArrayList(Hunk)) !void {
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

fn printHunkHuman(stdout: *std.Io.Writer, h: Hunk, mode: DiffMode, col_width: usize, term_width: u16, use_color: bool) !void {
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
    if (available > 1 and summary.len > available) {
        const trunc = available - 1; // leave 1 column for ellipsis
        try stdout.writeAll(summary[0..trunc]);
        try stdout.writeAll("\xe2\x80\xa6"); // U+2026 HORIZONTAL ELLIPSIS
    } else {
        try stdout.writeAll(summary);
    }
    try stdout.writeByte('\n');
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

fn printDiffHuman(stdout: *std.Io.Writer, h: Hunk, use_color: bool) !void {
    if (h.raw_lines.len == 0) return;
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
fn printRawLinesHuman(stdout: *std.Io.Writer, raw_lines: []const u8, use_color: bool) !void {
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

fn printDiffPorcelain(stdout: *std.Io.Writer, h: Hunk) !void {
    if (h.raw_lines.len == 0) return;
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

fn getTerminalWidth() u16 {
    const stdout_file = std.fs.File.stdout();
    if (!stdout_file.isTty()) return 80;
    var wsz: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = posix.system.ioctl(stdout_file.handle, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (posix.errno(err) == .SUCCESS and wsz.col > 0) return wsz.col;
    return 80;
}

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
