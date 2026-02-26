const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");
const diff_mod = @import("diff.zig");
const git = @import("git.zig");
const patch_mod = @import("patch.zig");
const format = @import("format.zig");

const Allocator = std.mem.Allocator;
const Hunk = types.Hunk;
const LineRange = types.LineRange;
const MatchedHunk = types.MatchedHunk;
const DiffMode = types.DiffMode;
const ListOptions = types.ListOptions;
const AddRemoveOptions = types.AddRemoveOptions;
const ShowOptions = types.ShowOptions;

pub fn cmdList(allocator: Allocator, stdout: *std.Io.Writer, opts: ListOptions) !void {
    const diff_output = try git.runGitDiff(allocator, opts.mode, opts.context);
    defer allocator.free(diff_output);

    if (diff_output.len == 0) return;

    // Use arena for all hunk-related allocations
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    // Arena owns all hunk data; ArrayList itself also uses arena
    defer hunks.deinit(arena);

    try diff_mod.parseDiff(arena, diff_output, opts.mode, &hunks);

    // Compute display parameters for human mode
    const use_color = opts.output == .human and !opts.no_color and
        std.fs.File.stdout().isTty() and posix.getenv("NO_COLOR") == null;
    const term_width = if (use_color or opts.output == .human) format.getTerminalWidth() else 80;

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
    // Clamp col_width so prefix (col_width + 21) doesn't exceed terminal width
    const max_col: usize = if (@as(usize, term_width) > 25) @as(usize, term_width) - 25 else 20;
    const col_width = @min(@max(max_path_len, 20), max_col);

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
            .human => try format.printHunkHuman(stdout, h, opts.mode, col_width, term_width, use_color),
            .porcelain => try format.printHunkPorcelain(stdout, h, opts.mode),
        }
        if (!opts.oneline) {
            switch (opts.output) {
                .human => try format.printDiffHuman(stdout, h, use_color),
                .porcelain => try format.printDiffPorcelain(stdout, h),
            }
        }
    }

    // Count summary (human output only, when there are hunks)
    if (opts.output == .human and hunk_count > 0) {
        std.debug.print("{d} hunks across {d} files\n", .{ hunk_count, file_count });
    }

    // Hint about untracked files (human output, unstaged mode only)
    if (opts.output == .human and opts.mode == .unstaged) {
        const untracked = git.countUntrackedFiles(allocator) catch 0;
        if (untracked > 0) {
            std.debug.print("hint: {d} untracked file(s) not shown -- use 'git add -N <file>' to include\n", .{untracked});
        }
    }
}

pub fn cmdAdd(allocator: Allocator, stdout: *std.Io.Writer, opts: AddRemoveOptions) !void {
    try cmdApplyHunks(allocator, stdout, opts, .stage);
}

pub fn cmdRemove(allocator: Allocator, stdout: *std.Io.Writer, opts: AddRemoveOptions) !void {
    try cmdApplyHunks(allocator, stdout, opts, .unstage);
}

const ApplyAction = enum { stage, unstage };

/// Find the new hash for a hunk after staging/unstaging by matching on content.
/// Returns the 7-char truncated hash from the opposite diff, or null if no match.
fn findMatchingHash(new_hunks: []const Hunk, old_hunk: *const Hunk) ?[]const u8 {
    for (new_hunks) |*nh| {
        if (std.mem.eql(u8, nh.file_path, old_hunk.file_path) and
            std.mem.eql(u8, nh.diff_lines, old_hunk.diff_lines))
        {
            return nh.sha_hex[0..7];
        }
    }
    return null;
}

fn cmdApplyHunks(allocator: Allocator, stdout: *std.Io.Writer, opts: AddRemoveOptions, action: ApplyAction) !void {
    // For staging: diff unstaged hunks (index vs worktree)
    // For unstaging: diff staged hunks (HEAD vs index)
    const diff_mode: DiffMode = switch (action) {
        .stage => .unstaged,
        .unstage => .staged,
    };

    const diff_output = try git.runGitDiff(allocator, diff_mode, opts.context);
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
    try diff_mod.parseDiff(arena, diff_output, diff_mode, &hunks);

    // Resolve hunks to apply: bulk mode (--all or bare --file) or SHA prefix matching
    var matched: std.ArrayList(MatchedHunk) = .empty;
    defer matched.deinit(arena);

    if (opts.sha_args.items.len == 0) {
        // Bulk mode: match all hunks, optionally filtered by file
        for (hunks.items) |*h| {
            if (opts.file_filter) |filter| {
                if (!std.mem.eql(u8, h.file_path, filter)) continue;
            }
            try matched.append(arena, .{ .hunk = h, .line_spec = null });
        }
    } else {
        // SHA prefix matching mode
        for (opts.sha_args.items) |sha_arg| {
            const hunk = patch_mod.findHunkByShaPrefix(hunks.items, sha_arg.prefix, opts.file_filter) catch |err| switch (err) {
                error.NotFound => {
                    std.debug.print("error: no hunk matching '{s}'\n", .{sha_arg.prefix});
                    std.process.exit(1);
                },
                error.AmbiguousPrefix => {
                    std.debug.print("error: ambiguous prefix '{s}' — matches multiple hunks\n", .{sha_arg.prefix});
                    std.process.exit(1);
                },
                else => return err,
            };
            // Deduplicate: merge line specs for same hunk, or skip if already whole-hunk
            var found_existing = false;
            for (matched.items) |*existing| {
                if (std.mem.eql(u8, &existing.hunk.sha_hex, &hunk.sha_hex)) {
                    // Merge: if either has no line_spec, result is whole hunk
                    if (existing.line_spec == null or sha_arg.line_spec == null) {
                        existing.line_spec = null;
                    } else {
                        // Merge ranges by concatenation
                        const old_ranges = existing.line_spec.?.ranges;
                        const new_ranges = sha_arg.line_spec.?.ranges;
                        const merged = try arena.alloc(LineRange, old_ranges.len + new_ranges.len);
                        @memcpy(merged[0..old_ranges.len], old_ranges);
                        @memcpy(merged[old_ranges.len..], new_ranges);
                        existing.line_spec = .{ .ranges = merged };
                    }
                    found_existing = true;
                    break;
                }
            }
            if (!found_existing) {
                try matched.append(arena, .{ .hunk = hunk, .line_spec = sha_arg.line_spec });
            }
        }
    }

    // Sort hunks by file path and line order for a valid combined patch
    std.mem.sort(MatchedHunk, matched.items, {}, patch_mod.matchedHunkPatchOrder);

    // Build combined patch and apply
    const patch = try patch_mod.buildCombinedPatch(arena, matched.items);
    const reverse = action == .unstage;
    try git.runGitApply(allocator, patch, reverse);

    // Resolve new hashes: after staging/unstaging, the hunk appears in the
    // opposite diff with a different hash (stable line references change).
    // Re-parse that diff to show the user the hash mapping.
    const new_mode: DiffMode = switch (action) {
        .stage => .staged,
        .unstage => .unstaged,
    };
    var new_hunks: std.ArrayList(Hunk) = .empty;
    defer new_hunks.deinit(arena);
    if (git.runGitDiff(arena, new_mode, opts.context)) |new_diff| {
        if (new_diff.len > 0) {
            diff_mod.parseDiff(arena, new_diff, new_mode, &new_hunks) catch {};
        }
    } else |_| {}

    // Report what was applied
    const use_color = !opts.no_color and
        std.fs.File.stdout().isTty() and posix.getenv("NO_COLOR") == null;
    const verb: []const u8 = switch (action) {
        .stage => "staged",
        .unstage => "unstaged",
    };
    for (matched.items) |m| {
        const sha = m.hunk.sha_hex[0..7];
        const new_sha: ?[]const u8 = if (m.line_spec == null)
            findMatchingHash(new_hunks.items, m.hunk)
        else
            null;
        const suffix: []const u8 = if (m.line_spec != null) " (partial)" else "";
        if (new_sha) |ns| {
            if (use_color) {
                try stdout.print("{s} {s}{s}{s} \xe2\x86\x92 {s}{s}{s}  {s}{s}\n", .{ verb, format.COLOR_YELLOW, sha, format.COLOR_RESET, format.COLOR_YELLOW, ns, format.COLOR_RESET, m.hunk.file_path, suffix });
            } else {
                try stdout.print("{s} {s} \xe2\x86\x92 {s}  {s}{s}\n", .{ verb, sha, ns, m.hunk.file_path, suffix });
            }
        } else {
            if (use_color) {
                try stdout.print("{s} {s}{s}{s}  {s}{s}\n", .{ verb, format.COLOR_YELLOW, sha, format.COLOR_RESET, m.hunk.file_path, suffix });
            } else {
                try stdout.print("{s} {s}  {s}{s}\n", .{ verb, sha, m.hunk.file_path, suffix });
            }
        }
    }

    // Summary count on stderr (visible even when stdout is piped)
    const count = matched.items.len;
    if (count == 1) {
        std.debug.print("1 hunk {s}\n", .{verb});
    } else {
        std.debug.print("{d} hunks {s}\n", .{ count, verb });
    }

    // Hint about hash changes when staging (only in interactive TTY contexts)
    if (action == .stage and std.fs.File.stdout().isTty()) {
        std.debug.print("hint: staged hashes differ from unstaged -- use 'git hunk list --staged' to see them\n", .{});
    }
}

pub fn cmdShow(allocator: Allocator, stdout: *std.Io.Writer, opts: ShowOptions) !void {
    const diff_output = try git.runGitDiff(allocator, opts.mode, opts.context);
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
    try diff_mod.parseDiff(arena, diff_output, opts.mode, &hunks);

    // Resolve each SHA arg to a hunk, deduplicating by full SHA
    var matched: std.ArrayList(MatchedHunk) = .empty;
    defer matched.deinit(arena);

    for (opts.sha_args.items) |sha_arg| {
        const hunk = patch_mod.findHunkByShaPrefix(hunks.items, sha_arg.prefix, opts.file_filter) catch |err| switch (err) {
            error.NotFound => {
                std.debug.print("error: no hunk matching '{s}'\n", .{sha_arg.prefix});
                std.process.exit(1);
            },
            error.AmbiguousPrefix => {
                std.debug.print("error: ambiguous prefix '{s}' — matches multiple hunks\n", .{sha_arg.prefix});
                std.process.exit(1);
            },
            else => return err,
        };
        // Deduplicate with line spec merging
        var found_existing = false;
        for (matched.items) |*existing| {
            if (std.mem.eql(u8, &existing.hunk.sha_hex, &hunk.sha_hex)) {
                if (existing.line_spec == null or sha_arg.line_spec == null) {
                    existing.line_spec = null;
                } else {
                    const old_ranges = existing.line_spec.?.ranges;
                    const new_ranges = sha_arg.line_spec.?.ranges;
                    const merged = try arena.alloc(LineRange, old_ranges.len + new_ranges.len);
                    @memcpy(merged[0..old_ranges.len], old_ranges);
                    @memcpy(merged[old_ranges.len..], new_ranges);
                    existing.line_spec = .{ .ranges = merged };
                }
                found_existing = true;
                break;
            }
        }
        if (!found_existing) {
            try matched.append(arena, .{ .hunk = hunk, .line_spec = sha_arg.line_spec });
        }
    }

    const use_color = opts.output == .human and !opts.no_color and
        std.fs.File.stdout().isTty() and posix.getenv("NO_COLOR") == null;

    // Print each matched hunk
    for (matched.items) |m| {
        switch (opts.output) {
            .human => {
                try stdout.writeAll(m.hunk.patch_header);
                if (m.line_spec) |ls| {
                    try format.printRawLinesWithLineNumbers(stdout, m.hunk.raw_lines, ls, use_color);
                } else {
                    try format.printRawLinesHuman(stdout, m.hunk.raw_lines, use_color);
                }
                try stdout.writeAll("\n");
            },
            .porcelain => {
                try format.printHunkPorcelain(stdout, m.hunk.*, opts.mode);
                try format.printDiffPorcelain(stdout, m.hunk.*);
            },
        }
    }
}
