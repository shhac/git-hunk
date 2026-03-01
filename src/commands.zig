const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");
const diff_mod = @import("diff.zig");
const git = @import("git.zig");
const patch_mod = @import("patch.zig");
const format = @import("format.zig");

const stash_mod = @import("stash.zig");

const Allocator = std.mem.Allocator;
const Hunk = types.Hunk;
const LineRange = types.LineRange;
const MatchedHunk = types.MatchedHunk;
const DiffMode = types.DiffMode;
const DiffFilter = types.DiffFilter;
const ListOptions = types.ListOptions;
const AddResetOptions = types.AddResetOptions;
const ShowOptions = types.ShowOptions;
const CountOptions = types.CountOptions;
const CheckOptions = types.CheckOptions;
const DiscardOptions = types.DiscardOptions;
const StashOptions = types.StashOptions;
const rangesOverlap = types.rangesOverlap;

/// Get diff output including untracked files (unstaged mode only).
/// Returns the tracked diff output and, separately, the untracked diff output.
/// Both must remain alive while hunks reference them (hunks contain sub-slices).
/// Hunks from untracked files have `is_untracked = true`.
fn getDiffWithUntracked(
    allocator: Allocator,
    arena: Allocator,
    mode: DiffMode,
    context: ?u32,
    file_filter: ?[]const u8,
    diff_filter: DiffFilter,
    hunks: *std.ArrayList(Hunk),
) !struct { tracked: []u8, untracked: []u8 } {
    // Skip tracked diffs when only untracked files are requested
    const diff_output = if (diff_filter == .untracked_only)
        try allocator.alloc(u8, 0)
    else
        try git.runGitDiff(allocator, mode, context);
    errdefer allocator.free(diff_output);

    if (diff_output.len > 0) {
        try diff_mod.parseDiff(arena, diff_output, mode, hunks);
    }

    // Untracked files only appear in unstaged mode and when not filtered out
    if (mode == .unstaged and diff_filter != .tracked_only) {
        const untracked_diff = try git.diffUntrackedFiles(allocator, file_filter);
        errdefer allocator.free(untracked_diff);

        if (untracked_diff.len > 0) {
            const before_count = hunks.items.len;
            try diff_mod.parseDiff(arena, untracked_diff, .unstaged, hunks);
            // Mark newly-added hunks as untracked
            for (hunks.items[before_count..]) |*h| {
                h.is_untracked = true;
            }
        }

        return .{ .tracked = diff_output, .untracked = untracked_diff };
    }

    return .{ .tracked = diff_output, .untracked = try allocator.alloc(u8, 0) };
}

pub fn cmdList(allocator: Allocator, stdout: *std.Io.Writer, opts: ListOptions) !void {
    // Use arena for all hunk-related allocations
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, opts.mode, opts.context, opts.file_filter, opts.diff_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    if (hunks.items.len == 0) return;

    // Compute display parameters for human mode
    const use_color = format.shouldUseColor(opts.output, opts.no_color);
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

}

pub fn cmdCount(allocator: Allocator, stdout: *std.Io.Writer, opts: CountOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, opts.mode, opts.context, opts.file_filter, opts.diff_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    var count: usize = 0;
    for (hunks.items) |h| {
        if (opts.file_filter) |filter| {
            if (!std.mem.eql(u8, h.file_path, filter)) continue;
        }
        count += 1;
    }

    try stdout.print("{d}\n", .{count});
}

pub fn cmdCheck(allocator: Allocator, stdout: *std.Io.Writer, opts: CheckOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, opts.mode, opts.context, opts.file_filter, opts.diff_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    const use_color = format.shouldUseColor(opts.output, opts.no_color);

    // Deduplicate input SHA prefixes
    var unique_prefixes: std.ArrayList([]const u8) = .empty;
    for (opts.sha_args.items) |sha_arg| {
        var already = false;
        for (unique_prefixes.items) |p| {
            if (std.mem.eql(u8, p, sha_arg.prefix)) {
                already = true;
                break;
            }
        }
        if (!already) try unique_prefixes.append(arena, sha_arg.prefix);
    }

    // Check each prefix
    const Status = enum { ok, stale, ambiguous };
    const CheckResult = struct {
        prefix: []const u8,
        status: Status,
        resolved_sha7: []const u8,
        file_path: []const u8,
    };

    var results: std.ArrayList(CheckResult) = .empty;
    var matched_sha_hexes: std.ArrayList(*const [40]u8) = .empty;
    var has_failure = false;

    for (unique_prefixes.items) |prefix| {
        if (patch_mod.findHunkByShaPrefix(hunks.items, prefix, opts.file_filter)) |hunk| {
            try results.append(arena, .{
                .prefix = prefix,
                .status = .ok,
                .resolved_sha7 = hunk.sha_hex[0..7],
                .file_path = hunk.file_path,
            });
            try matched_sha_hexes.append(arena, &hunk.sha_hex);
        } else |err| {
            const status: Status = switch (err) {
                error.NotFound => .stale,
                error.AmbiguousPrefix => .ambiguous,
            };
            try results.append(arena, .{
                .prefix = prefix,
                .status = status,
                .resolved_sha7 = "",
                .file_path = "",
            });
            has_failure = true;
        }
    }

    // Exclusive check: find hunks NOT matched by any provided hash
    var unexpected_hunks: std.ArrayList(*const Hunk) = .empty;
    if (opts.exclusive) {
        for (hunks.items) |*h| {
            if (opts.file_filter) |filter| {
                if (!std.mem.eql(u8, h.file_path, filter)) continue;
            }
            var was_matched = false;
            for (matched_sha_hexes.items) |sha_ptr| {
                if (std.mem.eql(u8, &h.sha_hex, sha_ptr)) {
                    was_matched = true;
                    break;
                }
            }
            if (!was_matched) {
                try unexpected_hunks.append(arena, h);
                has_failure = true;
            }
        }
    }

    // Output
    if (opts.output == .porcelain) {
        // Porcelain: report ALL entries
        for (results.items) |r| {
            switch (r.status) {
                .ok => try stdout.print("ok\t{s}\t{s}\t{s}\n", .{ r.prefix, r.resolved_sha7, r.file_path }),
                .stale => try stdout.print("stale\t{s}\n", .{r.prefix}),
                .ambiguous => try stdout.print("ambiguous\t{s}\n", .{r.prefix}),
            }
        }
        for (unexpected_hunks.items) |h| {
            try stdout.print("unexpected\t{s}\t{s}\n", .{ h.sha_hex[0..7], h.file_path });
        }
    } else if (has_failure) {
        // Human mode: output only on failure. Stale/ambiguous first, then unexpected.
        for (results.items) |r| {
            switch (r.status) {
                .ok => {},
                .stale => {
                    if (use_color) {
                        try stdout.print("stale {s}{s}{s}\n", .{ format.COLOR_YELLOW, r.prefix, format.COLOR_RESET });
                    } else {
                        try stdout.print("stale {s}\n", .{r.prefix});
                    }
                },
                .ambiguous => {
                    if (use_color) {
                        try stdout.print("ambiguous {s}{s}{s}\n", .{ format.COLOR_YELLOW, r.prefix, format.COLOR_RESET });
                    } else {
                        try stdout.print("ambiguous {s}\n", .{r.prefix});
                    }
                },
            }
        }
        for (unexpected_hunks.items) |h| {
            if (use_color) {
                try stdout.print("unexpected {s}{s}{s}  {s}\n", .{ format.COLOR_YELLOW, h.sha_hex[0..7], format.COLOR_RESET, h.file_path });
            } else {
                try stdout.print("unexpected {s}  {s}\n", .{ h.sha_hex[0..7], h.file_path });
            }
        }

        // stderr summary (human mode only)
        var fail_count: usize = 0;
        for (results.items) |r| {
            if (r.status != .ok) fail_count += 1;
        }
        if (fail_count > 0 and unexpected_hunks.items.len > 0) {
            std.debug.print("{d} of {d} hashes failed, {d} unexpected hunk{s}\n", .{
                fail_count,
                results.items.len,
                unexpected_hunks.items.len,
                @as([]const u8, if (unexpected_hunks.items.len == 1) "" else "s"),
            });
        } else if (fail_count > 0) {
            std.debug.print("{d} of {d} hashes failed\n", .{ fail_count, results.items.len });
        } else if (unexpected_hunks.items.len > 0) {
            std.debug.print("exclusive check failed: {d} unexpected hunk{s}\n", .{
                unexpected_hunks.items.len,
                @as([]const u8, if (unexpected_hunks.items.len == 1) "" else "s"),
            });
        }
    }

    if (has_failure) {
        try stdout.flush();
        std.process.exit(1);
    }
}

pub fn cmdAdd(allocator: Allocator, stdout: *std.Io.Writer, opts: AddResetOptions) !void {
    try cmdApplyHunks(allocator, stdout, opts, .stage);
}

pub fn cmdReset(allocator: Allocator, stdout: *std.Io.Writer, opts: AddResetOptions) !void {
    try cmdApplyHunks(allocator, stdout, opts, .unstage);
}

const ApplyAction = enum { stage, unstage };

/// An applied input hunk (what the user asked to stage/unstage).
const AppliedInput = struct {
    sha7: []const u8,
    line_spec: ?types.LineSpec,
};

/// A result group represents one output line: the set of applied + consumed
/// input hunks that combined into one (or more) result hunks on the target side.
const ResultGroup = struct {
    /// 7-char result hash(es) on the target side. Usually length 1.
    /// Multiple when a line-spec operation splits into several output hunks.
    /// Empty if no result could be resolved.
    result_shas: []const []const u8,
    /// Input hunks the user asked to stage/unstage.
    applied: []const AppliedInput,
    /// 7-char hashes of pre-existing target-side hunks absorbed into the result.
    consumed: []const []const u8,
    /// File path.
    file_path: []const u8,
};

/// Build result groups by comparing old vs new target-side hunks and matching
/// applied/consumed inputs to created results.
///
/// Algorithm:
///   1. Consumed = old target hunks whose sha is absent from new target
///   2. Created  = new target hunks whose sha is absent from old target
///   3. For each created hunk, find contributing applied hunks (by content
///      match, then new-side line overlap) and consumed hunks (by old-side
///      line overlap)
///   4. Unmatched applied hunks get their own group with no result hash
fn buildResultGroups(
    arena: Allocator,
    matched: []const MatchedHunk,
    old_target: []const Hunk,
    new_target: []const Hunk,
) ![]const ResultGroup {
    // Step 1: Consumed = old target hunks not surviving in new target
    var consumed_list: std.ArrayList(*const Hunk) = .empty;
    for (old_target) |*oh| {
        var survived = false;
        for (new_target) |*nh| {
            if (std.mem.eql(u8, &oh.sha_hex, &nh.sha_hex)) {
                survived = true;
                break;
            }
        }
        if (!survived) try consumed_list.append(arena, oh);
    }

    // Step 2: Created = new target hunks that didn't exist before
    var created_list: std.ArrayList(*const Hunk) = .empty;
    for (new_target) |*nh| {
        var existed = false;
        for (old_target) |*oh| {
            if (std.mem.eql(u8, &nh.sha_hex, &oh.sha_hex)) {
                existed = true;
                break;
            }
        }
        if (!existed) try created_list.append(arena, nh);
    }

    // Step 3: Match applied and consumed hunks to created results
    const applied_used = try arena.alloc(bool, matched.len);
    @memset(applied_used, false);
    const consumed_used = try arena.alloc(bool, consumed_list.items.len);
    @memset(consumed_used, false);

    var groups: std.ArrayList(ResultGroup) = .empty;

    for (created_list.items) |created| {
        var app_buf: std.ArrayList(AppliedInput) = .empty;
        var con_buf: std.ArrayList([]const u8) = .empty;

        // Match applied hunks: content match first (simple case), then new-side line overlap
        for (matched, 0..) |m, i| {
            if (applied_used[i]) continue;
            if (!std.mem.eql(u8, m.hunk.file_path, created.file_path)) continue;

            const content_match = m.line_spec == null and
                std.mem.eql(u8, m.hunk.diff_lines, created.diff_lines);
            const line_match = !content_match and rangesOverlap(
                m.hunk.new_start, m.hunk.new_count,
                created.new_start, created.new_count,
            );

            if (content_match or line_match) {
                try app_buf.append(arena, .{
                    .sha7 = m.hunk.sha_hex[0..7],
                    .line_spec = m.line_spec,
                });
                applied_used[i] = true;
            }
        }

        // Match consumed hunks by file + old-side (HEAD/stable) line overlap
        for (consumed_list.items, 0..) |con, i| {
            if (consumed_used[i]) continue;
            if (!std.mem.eql(u8, con.file_path, created.file_path)) continue;

            if (rangesOverlap(
                con.old_start, con.old_count,
                created.old_start, created.old_count,
            )) {
                try con_buf.append(arena, con.sha_hex[0..7]);
                consumed_used[i] = true;
            }
        }

        const result_sha = try arena.alloc([]const u8, 1);
        result_sha[0] = created.sha_hex[0..7];

        try groups.append(arena, .{
            .result_shas = result_sha,
            .applied = try app_buf.toOwnedSlice(arena),
            .consumed = try con_buf.toOwnedSlice(arena),
            .file_path = created.file_path,
        });
    }

    // Step 4: Unmatched applied hunks get their own group (no result hash)
    for (matched, 0..) |m, i| {
        if (applied_used[i]) continue;
        const app = try arena.alloc(AppliedInput, 1);
        app[0] = .{ .sha7 = m.hunk.sha_hex[0..7], .line_spec = m.line_spec };
        try groups.append(arena, .{
            .result_shas = &.{},
            .applied = app,
            .consumed = &.{},
            .file_path = m.hunk.file_path,
        });
    }

    // Step 5: Merge orphan groups into sibling groups for the same file.
    // A line-spec operation (e.g. `aaaa:1,10`) can produce multiple result
    // hunks. The applied hunk matches the first created hunk exclusively
    // (applied_used is set), so subsequent created hunks get empty `applied`.
    // Merge these orphans back: append their result_shas and consumed to the
    // sibling group that holds the applied input for the same file.
    var final_groups: std.ArrayList(ResultGroup) = .empty;
    for (groups.items) |rg| {
        if (rg.applied.len > 0) {
            try final_groups.append(arena, rg);
        }
    }
    for (groups.items) |orphan| {
        if (orphan.applied.len > 0) continue;
        if (orphan.result_shas.len == 0) continue;

        var merged = false;
        for (final_groups.items) |*target| {
            if (!std.mem.eql(u8, target.file_path, orphan.file_path)) continue;

            // Append orphan's result_shas to the sibling group
            const combined_res = try arena.alloc([]const u8, target.result_shas.len + orphan.result_shas.len);
            @memcpy(combined_res[0..target.result_shas.len], target.result_shas);
            @memcpy(combined_res[target.result_shas.len..], orphan.result_shas);
            target.result_shas = combined_res;

            // Append orphan's consumed hashes if any
            if (orphan.consumed.len > 0) {
                const combined_con = try arena.alloc([]const u8, target.consumed.len + orphan.consumed.len);
                @memcpy(combined_con[0..target.consumed.len], target.consumed);
                @memcpy(combined_con[target.consumed.len..], orphan.consumed);
                target.consumed = combined_con;
            }

            merged = true;
            break;
        }
        if (!merged) {
            // No sibling found — keep as standalone group (shouldn't happen normally)
            try final_groups.append(arena, orphan);
        }
    }

    return try final_groups.toOwnedSlice(arena);
}

/// Format a line spec as `start-end` or `start` (comma-separated for multiple ranges).
fn writeLineSpec(stdout: *std.Io.Writer, ls: types.LineSpec) !void {
    for (ls.ranges, 0..) |r, i| {
        if (i > 0) try stdout.print(",", .{});
        if (r.start == r.end) {
            try stdout.print("{d}", .{r.start});
        } else {
            try stdout.print("{d}-{d}", .{ r.start, r.end });
        }
    }
}

/// Print one result group in human-readable format:
///   {verb} {applied...} [+{consumed}...] → {result[,result...]}  {file}
fn printResultGroupHuman(stdout: *std.Io.Writer, verb: []const u8, rg: ResultGroup, use_color: bool) !void {
    // Verb
    try stdout.print("{s} ", .{verb});

    // Applied hashes (yellow), space-separated, with optional :line_spec
    for (rg.applied, 0..) |ai, i| {
        if (i > 0) try stdout.print(" ", .{});
        if (use_color) try stdout.print("{s}", .{format.COLOR_YELLOW});
        try stdout.print("{s}", .{ai.sha7});
        if (ai.line_spec) |ls| {
            try stdout.print(":", .{});
            try writeLineSpec(stdout, ls);
        }
        if (use_color) try stdout.print("{s}", .{format.COLOR_RESET});
    }

    // Consumed hashes (dim), space-separated, +-prefixed
    for (rg.consumed) |con| {
        if (use_color) {
            try stdout.print(" {s}+{s}{s}", .{ format.COLOR_DIM, con, format.COLOR_RESET });
        } else {
            try stdout.print(" +{s}", .{con});
        }
    }

    // Arrow (always present)
    try stdout.print(" \xe2\x86\x92 ", .{});

    // Result hashes (green), comma-separated
    if (rg.result_shas.len > 0) {
        for (rg.result_shas, 0..) |rs, i| {
            if (i > 0) try stdout.print(",", .{});
            if (use_color) try stdout.print("{s}", .{format.COLOR_GREEN});
            try stdout.print("{s}", .{rs});
            if (use_color) try stdout.print("{s}", .{format.COLOR_RESET});
        }
    } else {
        try stdout.print("?", .{});
    }

    // File path (two spaces before file)
    try stdout.print("  {s}\n", .{rg.file_path});
}

/// Print one result group in porcelain (tab-separated) format:
///   {verb}\t{applied}\t{result}\t{file}[\t{consumed}]
fn printResultGroupPorcelain(stdout: *std.Io.Writer, verb: []const u8, rg: ResultGroup) !void {
    // verb
    try stdout.print("{s}\t", .{verb});

    // applied: space-separated with optional :line_spec
    for (rg.applied, 0..) |ai, i| {
        if (i > 0) try stdout.print(" ", .{});
        try stdout.print("{s}", .{ai.sha7});
        if (ai.line_spec) |ls| {
            try stdout.print(":", .{});
            try writeLineSpec(stdout, ls);
        }
    }

    // result: comma-separated
    try stdout.print("\t", .{});
    for (rg.result_shas, 0..) |rs, i| {
        if (i > 0) try stdout.print(",", .{});
        try stdout.print("{s}", .{rs});
    }

    // file
    try stdout.print("\t{s}", .{rg.file_path});

    // consumed: comma-separated (optional field, only if non-empty)
    if (rg.consumed.len > 0) {
        try stdout.print("\t", .{});
        for (rg.consumed, 0..) |con, i| {
            if (i > 0) try stdout.print(",", .{});
            try stdout.print("{s}", .{con});
        }
    }

    try stdout.print("\n", .{});
}

fn cmdApplyHunks(allocator: Allocator, stdout: *std.Io.Writer, opts: AddResetOptions, action: ApplyAction) !void {
    // For staging: diff unstaged hunks (index vs worktree)
    // For unstaging: diff staged hunks (HEAD vs index)
    const diff_mode: DiffMode = switch (action) {
        .stage => .unstaged,
        .unstage => .staged,
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, diff_mode, opts.context, opts.file_filter, opts.diff_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    if (hunks.items.len == 0) {
        const msg = switch (action) {
            .stage => "no unstaged changes\n",
            .unstage => "no staged changes\n",
        };
        std.debug.print("{s}", .{msg});
        std.process.exit(1);
    }

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

    // Collect unique file paths from matched hunks for scoped diff queries
    var file_paths: std.ArrayList([]const u8) = .empty;
    defer file_paths.deinit(arena);
    for (matched.items) |m| {
        var already_present = false;
        for (file_paths.items) |fp| {
            if (std.mem.eql(u8, fp, m.hunk.file_path)) {
                already_present = true;
                break;
            }
        }
        if (!already_present) {
            try file_paths.append(arena, m.hunk.file_path);
        }
    }

    // Capture target-side hunks BEFORE applying, so we can detect merges.
    // For add (stage): target is staged (HEAD vs index) → parse git diff --cached
    // For remove (unstage): target is unstaged (index vs worktree) → parse git diff
    const target_mode: DiffMode = switch (action) {
        .stage => .staged,
        .unstage => .unstaged,
    };
    var old_target_hunks: std.ArrayList(Hunk) = .empty;
    defer old_target_hunks.deinit(arena);
    if (git.runGitDiffFiles(arena, target_mode, opts.context, file_paths.items)) |target_diff| {
        if (target_diff.len > 0) {
            diff_mod.parseDiff(arena, target_diff, target_mode, &old_target_hunks) catch {};
        }
    } else |_| {}

    try git.runGitApply(allocator, patch, reverse, .index, false);

    // Resolve new hashes: after staging/unstaging, the hunk appears in the
    // opposite diff with a different hash (stable line references change).
    // Re-parse that diff to show the user the hash mapping.
    var new_hunks: std.ArrayList(Hunk) = .empty;
    defer new_hunks.deinit(arena);
    if (git.runGitDiffFiles(arena, target_mode, opts.context, file_paths.items)) |new_diff| {
        if (new_diff.len > 0) {
            diff_mod.parseDiff(arena, new_diff, target_mode, &new_hunks) catch {};
        }
    } else |_| {}

    // Build result groups: match applied + consumed inputs to created results
    const result_groups = try buildResultGroups(arena, matched.items, old_target_hunks.items, new_hunks.items);

    // Report what was applied
    const use_color = format.shouldUseColor(opts.output, opts.no_color);
    const verb: []const u8 = switch (action) {
        .stage => "staged",
        .unstage => "unstaged",
    };
    var count: usize = 0;
    var merged_count: usize = 0;
    for (result_groups) |rg| {
        count += rg.applied.len;
        merged_count += rg.consumed.len;
        switch (opts.output) {
            .human => try printResultGroupHuman(stdout, verb, rg, use_color),
            .porcelain => try printResultGroupPorcelain(stdout, verb, rg),
        }
    }
    // Summary count on stderr (human mode only)
    if (opts.output == .human) {
        if (count == 1 and merged_count == 0) {
            std.debug.print("1 hunk {s}\n", .{verb});
        } else if (count == 1 and merged_count > 0) {
            std.debug.print("1 hunk {s} ({d} merged)\n", .{ verb, merged_count });
        } else if (merged_count == 0) {
            std.debug.print("{d} hunks {s}\n", .{ count, verb });
        } else {
            std.debug.print("{d} hunks {s} ({d} merged)\n", .{ count, verb, merged_count });
        }
    }

    // Hint about hash changes when staging (only with --verbose)
    if (action == .stage and opts.verbose and opts.output == .human and std.fs.File.stdout().isTty()) {
        std.debug.print("hint: staged hashes differ from unstaged -- use 'git hunk list --staged' to see them\n", .{});
    }
}

pub fn cmdDiscard(allocator: Allocator, stdout: *std.Io.Writer, opts: DiscardOptions) !void {
    // Discard always operates on unstaged hunks (worktree vs index)
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, .unstaged, opts.context, opts.file_filter, opts.diff_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    if (hunks.items.len == 0) {
        std.debug.print("no unstaged changes\n", .{});
        std.process.exit(1);
    }

    // Resolve hunks: bulk mode (--all or bare --file) or SHA prefix matching
    var matched: std.ArrayList(MatchedHunk) = .empty;
    defer matched.deinit(arena);

    if (opts.sha_args.items.len == 0) {
        for (hunks.items) |*h| {
            if (opts.file_filter) |filter| {
                if (!std.mem.eql(u8, h.file_path, filter)) continue;
            }
            try matched.append(arena, .{ .hunk = h, .line_spec = null });
        }
    } else {
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
            // Deduplicate: merge line specs for same hunk
            var found_existing = false;
            for (matched.items) |*existing| {
                if (std.mem.eql(u8, &existing.hunk.sha_hex, &hunk.sha_hex)) {
                    if (existing.line_spec == null or sha_arg.line_spec == null) {
                        existing.line_spec = null;
                    } else {
                        const old_ranges = existing.line_spec.?.ranges;
                        const new_ranges = sha_arg.line_spec.?.ranges;
                        const merged = try arena.alloc(types.LineRange, old_ranges.len + new_ranges.len);
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

    if (matched.items.len == 0) {
        if (opts.file_filter) |filter| {
            std.debug.print("no hunks matching file '{s}'\n", .{filter});
        } else {
            std.debug.print("no unstaged changes\n", .{});
        }
        std.process.exit(1);
    }

    // Gate: untracked files require --force (discarding deletes them permanently)
    // Dry-run bypasses the gate — safe to preview without --force
    if (!opts.force and !opts.dry_run) {
        for (matched.items) |m| {
            if (m.hunk.is_untracked) {
                std.debug.print("error: {s} ({s}) is an untracked file -- use --force to delete\n", .{ m.hunk.sha_hex[0..7], m.hunk.file_path });
                std.process.exit(1);
            }
        }
    }

    // Sort hunks for valid combined patch
    std.mem.sort(MatchedHunk, matched.items, {}, patch_mod.matchedHunkPatchOrder);

    // Build combined patch and apply (reverse, to worktree, not cached)
    const patch = try patch_mod.buildCombinedPatch(arena, matched.items);
    try git.runGitApply(allocator, patch, true, .worktree, opts.dry_run);

    // Output
    const use_color = format.shouldUseColor(opts.output, opts.no_color);

    const verb: []const u8 = if (opts.dry_run) "would discard" else "discarded";
    const porcelain_verb: []const u8 = if (opts.dry_run) "would-discard" else "discarded";

    var count: usize = 0;
    for (matched.items) |m| {
        count += 1;
        switch (opts.output) {
            .human => {
                try stdout.print("{s} ", .{verb});
                if (use_color) try stdout.print("{s}", .{format.COLOR_YELLOW});
                try stdout.print("{s}", .{m.hunk.sha_hex[0..7]});
                if (m.line_spec) |ls| {
                    try stdout.print(":", .{});
                    try writeLineSpec(stdout, ls);
                }
                if (use_color) try stdout.print("{s}", .{format.COLOR_RESET});
                try stdout.print("  {s}\n", .{m.hunk.file_path});
            },
            .porcelain => {
                try stdout.print("{s}\t{s}", .{ porcelain_verb, m.hunk.sha_hex[0..7] });
                if (m.line_spec) |ls| {
                    try stdout.print(":", .{});
                    try writeLineSpec(stdout, ls);
                }
                try stdout.print("\t{s}\n", .{m.hunk.file_path});
            },
        }
    }

    // Summary on stderr (human mode only)
    if (opts.output == .human) {
        if (opts.dry_run) {
            if (count == 1) {
                std.debug.print("1 hunk would be discarded\n", .{});
            } else {
                std.debug.print("{d} hunks would be discarded\n", .{count});
            }
        } else {
            if (count == 1) {
                std.debug.print("1 hunk discarded\n", .{});
            } else {
                std.debug.print("{d} hunks discarded\n", .{count});
            }
        }
    }
}

pub fn cmdShow(allocator: Allocator, stdout: *std.Io.Writer, opts: ShowOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, opts.mode, opts.context, opts.file_filter, opts.diff_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    if (hunks.items.len == 0) {
        const msg: []const u8 = switch (opts.mode) {
            .unstaged => "no unstaged changes\n",
            .staged => "no staged changes\n",
        };
        std.debug.print("{s}", .{msg});
        std.process.exit(1);
    }

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

    const use_color = format.shouldUseColor(opts.output, opts.no_color);

    // Print each matched hunk
    for (matched.items) |m| {
        switch (opts.output) {
            .human => {
                try stdout.writeAll(m.hunk.patch_header);
                if (m.hunk.raw_lines.len == 0) {
                    if (m.line_spec != null) {
                        std.debug.print("(empty file — no lines to select)\n", .{});
                    }
                } else if (m.line_spec) |ls| {
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

pub fn cmdStash(allocator: Allocator, stdout: *std.Io.Writer, opts: StashOptions) !void {
    // Pop path: just run git stash pop and return
    if (opts.pop) {
        try git.runGitStashPop(allocator);
        std.debug.print("popped stash@{{0}}\n", .{});
        return;
    }

    // Push path: stash selected hunks
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    // When --all is used without --include-untracked, default to tracked-only
    // (matching git stash behavior). Explicit hashes bypass this.
    const effective_filter = if (opts.select_all and !opts.include_untracked and opts.diff_filter == .all)
        DiffFilter.tracked_only
    else
        opts.diff_filter;

    const diffs = try getDiffWithUntracked(allocator, arena, .unstaged, opts.context, opts.file_filter, effective_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    if (hunks.items.len == 0) {
        std.debug.print("no unstaged changes\n", .{});
        std.process.exit(1);
    }

    // Resolve hunks: bulk mode (--all or bare --file) or SHA prefix matching
    var matched: std.ArrayList(MatchedHunk) = .empty;
    defer matched.deinit(arena);

    if (opts.sha_args.items.len == 0) {
        for (hunks.items) |*h| {
            if (opts.file_filter) |filter| {
                if (!std.mem.eql(u8, h.file_path, filter)) continue;
            }
            try matched.append(arena, .{ .hunk = h, .line_spec = null });
        }
    } else {
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
            // Deduplicate: merge line specs for same hunk
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
    }

    if (matched.items.len == 0) {
        if (opts.file_filter) |filter| {
            std.debug.print("no hunks matching file '{s}'\n", .{filter});
        } else {
            std.debug.print("no unstaged changes\n", .{});
        }
        std.process.exit(1);
    }

    // Split matched hunks into tracked and untracked
    var tracked_matched: std.ArrayList(MatchedHunk) = .empty;
    var untracked_matched: std.ArrayList(MatchedHunk) = .empty;
    for (matched.items) |m| {
        if (m.hunk.is_untracked) {
            try untracked_matched.append(arena, m);
        } else {
            try tracked_matched.append(arena, m);
        }
    }
    const has_tracked = tracked_matched.items.len > 0;
    const has_untracked = untracked_matched.items.len > 0;

    // Common: get HEAD info needed by both pipelines
    const head_tree = try git.runGitRevParseTree(allocator);
    defer allocator.free(head_tree);

    const head_sha = try git.runGitRevParse(allocator, "HEAD");
    defer allocator.free(head_sha);

    const branch = try git.runGitSymbolicRef(allocator);
    defer if (branch) |b| allocator.free(b);
    const branch_name = branch orelse "HEAD";

    const head_msg = try git.runGitLogOneline(allocator);
    defer allocator.free(head_msg);

    // --- Tracked hunks pipeline ---
    var index_patch: []const u8 = "";
    var stash_tree: []const u8 = head_tree;
    var owns_stash_tree = false;

    if (has_tracked) {
        // Sort and build INDEX_PATCH (index-relative, for worktree reverse-apply)
        std.mem.sort(MatchedHunk, tracked_matched.items, {}, patch_mod.matchedHunkPatchOrder);
        index_patch = try patch_mod.buildCombinedPatch(arena, tracked_matched.items);

        // Collect unique file paths from tracked hunks for HEAD diff
        var tracked_file_paths: std.ArrayList([]const u8) = .empty;
        for (tracked_matched.items) |m| {
            var already_present = false;
            for (tracked_file_paths.items) |fp| {
                if (std.mem.eql(u8, fp, m.hunk.file_path)) {
                    already_present = true;
                    break;
                }
            }
            if (!already_present) {
                try tracked_file_paths.append(arena, m.hunk.file_path);
            }
        }

        // Run HEAD-relative diff + parse
        const head_diff_output = try git.runGitDiffHead(allocator, opts.context, tracked_file_paths.items);
        defer allocator.free(head_diff_output);

        var head_hunks: std.ArrayList(Hunk) = .empty;
        if (head_diff_output.len > 0) {
            try diff_mod.parseDiff(arena, head_diff_output, .unstaged, &head_hunks);
        }

        // Build pointers to selected index hunks for the matcher
        const selected_ptrs = try arena.alloc(*const Hunk, tracked_matched.items.len);
        for (tracked_matched.items, 0..) |m, i| {
            selected_ptrs[i] = m.hunk;
        }

        // Match index hunks to HEAD hunks
        const head_matched = try stash_mod.matchIndexToHead(arena, selected_ptrs, head_hunks.items);

        if (head_matched.len == 0) {
            std.debug.print("error: could not match selected hunks to HEAD-relative diff\n", .{});
            std.process.exit(1);
        }

        // Sort and build HEAD_PATCH (for temp index apply)
        const head_matched_sorted = try arena.alloc(MatchedHunk, head_matched.len);
        @memcpy(head_matched_sorted, head_matched);
        std.mem.sort(MatchedHunk, head_matched_sorted, {}, patch_mod.matchedHunkPatchOrder);
        const head_patch = try patch_mod.buildCombinedPatch(arena, head_matched_sorted);

        // Temp index pipeline
        var random_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        const random_val = std.mem.readInt(u64, &random_bytes, .little);
        var tmp_path_buf: [64]u8 = undefined;
        const tmp_idx_path = std.fmt.bufPrint(&tmp_path_buf, "/tmp/git-hunk-idx.{x:0>16}", .{random_val}) catch unreachable;
        const tmp_idx_z = try arena.dupeZ(u8, tmp_idx_path);

        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();
        try env_map.put("GIT_INDEX_FILE", tmp_idx_z);

        defer std.posix.unlink(tmp_idx_z) catch {};

        try git.runGitReadTreeWithEnv(allocator, head_tree, &env_map);
        try git.runGitApplyWithEnv(allocator, head_patch, &env_map);

        stash_tree = try git.runGitWriteTreeWithEnv(allocator, &env_map);
        owns_stash_tree = true;
    }
    defer if (owns_stash_tree) allocator.free(stash_tree);

    // Index commit (parent 2): captures tracked changes tree
    const idx_msg = try std.fmt.allocPrint(arena, "index on {s}: {s}", .{ branch_name, head_msg });
    const idx_commit = try git.runGitCommitTree(allocator, stash_tree, &.{head_sha}, idx_msg);
    defer allocator.free(idx_commit);

    // --- Untracked hunks pipeline (parent 3) ---
    var untracked_commit: ?[]const u8 = null;

    if (has_untracked) {
        // Create temp index for untracked files
        var ut_random: [8]u8 = undefined;
        std.crypto.random.bytes(&ut_random);
        const ut_random_val = std.mem.readInt(u64, &ut_random, .little);
        var ut_path_buf: [80]u8 = undefined;
        const ut_path = std.fmt.bufPrint(&ut_path_buf, "/tmp/git-hunk-ut-idx.{x:0>16}", .{ut_random_val}) catch unreachable;
        const ut_path_z = try arena.dupeZ(u8, ut_path);

        var ut_env = try std.process.getEnvMap(allocator);
        defer ut_env.deinit();
        try ut_env.put("GIT_INDEX_FILE", ut_path_z);

        defer std.posix.unlink(ut_path_z) catch {};

        // Hash each untracked file and add to temp index
        for (untracked_matched.items) |m| {
            const blob_sha = try git.runGitHashObject(allocator, m.hunk.file_path);
            defer allocator.free(blob_sha);

            const mode = blk: {
                const stat = std.fs.cwd().statFile(m.hunk.file_path) catch break :blk "100644";
                break :blk if (stat.mode & std.posix.S.IXUSR != 0) "100755" else "100644";
            };
            try git.runGitUpdateIndexCacheinfo(allocator, mode, blob_sha, m.hunk.file_path, &ut_env);
        }

        const untracked_tree = try git.runGitWriteTreeWithEnv(allocator, &ut_env);
        defer allocator.free(untracked_tree);

        const ut_msg = try std.fmt.allocPrint(arena, "untracked files on {s}: {s}", .{ branch_name, head_msg });
        untracked_commit = try git.runGitCommitTree(allocator, untracked_tree, &.{head_sha}, ut_msg);
    }
    defer if (untracked_commit) |uc| allocator.free(uc);

    // Collect ALL file paths for stash message
    var all_file_paths: std.ArrayList([]const u8) = .empty;
    for (matched.items) |m| {
        var already_present = false;
        for (all_file_paths.items) |fp| {
            if (std.mem.eql(u8, fp, m.hunk.file_path)) {
                already_present = true;
                break;
            }
        }
        if (!already_present) {
            try all_file_paths.append(arena, m.hunk.file_path);
        }
    }

    // Build stash message
    const stash_msg = if (opts.message) |m| m else blk: {
        var msg_buf: std.ArrayList(u8) = .empty;
        try msg_buf.appendSlice(arena, "git-hunk stash: ");
        for (all_file_paths.items, 0..) |fp, i| {
            if (i > 0) try msg_buf.appendSlice(arena, ", ");
            try msg_buf.appendSlice(arena, fp);
        }
        break :blk msg_buf.items;
    };

    // Create WIP commit with correct number of parents
    const wip_commit = if (untracked_commit) |uc|
        try git.runGitCommitTree(allocator, stash_tree, &.{ head_sha, idx_commit, uc }, stash_msg)
    else
        try git.runGitCommitTree(allocator, stash_tree, &.{ head_sha, idx_commit }, stash_msg);
    defer allocator.free(wip_commit);

    try git.runGitStashStore(allocator, stash_msg, wip_commit);

    // Worktree cleanup
    if (has_tracked) {
        git.runGitApply(allocator, index_patch, true, .worktree, false) catch {
            std.debug.print("warning: stash created but worktree changes could not be removed\n", .{});
            std.debug.print("hint: use 'git stash pop' to undo or manually resolve\n", .{});
        };
    }
    if (has_untracked) {
        for (untracked_matched.items) |m| {
            std.fs.cwd().deleteFile(m.hunk.file_path) catch {
                std.debug.print("warning: could not delete untracked file '{s}'\n", .{m.hunk.file_path});
            };
        }
    }

    // Output per-hunk results
    const use_color = format.shouldUseColor(opts.output, opts.no_color);

    var count: usize = 0;
    for (matched.items) |m| {
        count += 1;
        switch (opts.output) {
            .human => {
                try stdout.print("stashed ", .{});
                if (use_color) try stdout.print("{s}", .{format.COLOR_YELLOW});
                try stdout.print("{s}", .{m.hunk.sha_hex[0..7]});
                if (m.line_spec) |ls| {
                    try stdout.print(":", .{});
                    try writeLineSpec(stdout, ls);
                }
                if (use_color) try stdout.print("{s}", .{format.COLOR_RESET});
                try stdout.print("  {s}\n", .{m.hunk.file_path});
            },
            .porcelain => {
                try stdout.print("stashed\t{s}", .{m.hunk.sha_hex[0..7]});
                if (m.line_spec) |ls| {
                    try stdout.print(":", .{});
                    try writeLineSpec(stdout, ls);
                }
                try stdout.print("\t{s}\n", .{m.hunk.file_path});
            },
        }
    }

    // Summary on stderr (human mode only)
    if (opts.output == .human) {
        if (count == 1) {
            std.debug.print("1 hunk stashed\n", .{});
        } else {
            std.debug.print("{d} hunks stashed\n", .{count});
        }
        // Hint on stderr (only with --verbose)
        if (opts.verbose and std.fs.File.stdout().isTty()) {
            std.debug.print("hint: use 'git stash list' to see stashed entries, 'git hunk stash pop' to restore\n", .{});
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "buildResultGroups simple 1-to-1 mapping" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Applied hunk (from unstaged diff)
    var applied_hunk = types.testMakeHunk("src/main.zig", 10, 3, 10, 5);
    applied_hunk.diff_lines = "+new line\n-old line";
    applied_hunk.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "aaaaaaa");
        @memset(h[7..], '0');
        break :blk h;
    };

    // Result hunk (from staged diff after apply) — same content, different hash
    var result_hunk = types.testMakeHunk("src/main.zig", 10, 3, 10, 5);
    result_hunk.diff_lines = "+new line\n-old line";
    result_hunk.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "yyyyyyy");
        @memset(h[7..], '0');
        break :blk h;
    };

    const matched = [_]MatchedHunk{.{ .hunk = &applied_hunk, .line_spec = null }};
    const old_target = [_]Hunk{}; // no pre-existing staged hunks
    const new_target = [_]Hunk{result_hunk};

    const groups = try buildResultGroups(arena, &matched, &old_target, &new_target);

    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].applied.len);
    try std.testing.expectEqual(@as(usize, 0), groups[0].consumed.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].result_shas.len);
    try std.testing.expectEqualStrings("aaaaaaa", groups[0].applied[0].sha7);
    try std.testing.expectEqualStrings("yyyyyyy", groups[0].result_shas[0]);
    try std.testing.expectEqualStrings("src/main.zig", groups[0].file_path);
}

test "buildResultGroups merge with existing staged hunk" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Applied hunk: unstaged change at lines 10-12 in worktree
    var applied_hunk = types.testMakeHunk("src/main.zig", 10, 2, 10, 3);
    applied_hunk.diff_lines = "+applied line";
    applied_hunk.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "aaaaaaa");
        @memset(h[7..], '0');
        break :blk h;
    };

    // Pre-existing staged hunk: HEAD lines 8-15
    var old_staged = types.testMakeHunk("src/main.zig", 8, 8, 8, 10);
    old_staged.diff_lines = "+old staged line";
    old_staged.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "xxxxxxx");
        @memset(h[7..], '0');
        break :blk h;
    };

    // Combined result: HEAD lines 8-15 (overlaps with old_staged on HEAD side)
    var result_hunk = types.testMakeHunk("src/main.zig", 8, 8, 8, 12);
    result_hunk.diff_lines = "+combined result";
    result_hunk.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "zzzzzzz");
        @memset(h[7..], '0');
        break :blk h;
    };

    const matched = [_]MatchedHunk{.{ .hunk = &applied_hunk, .line_spec = null }};
    const old_target = [_]Hunk{old_staged};
    const new_target = [_]Hunk{result_hunk}; // old_staged is gone, result_hunk is new

    const groups = try buildResultGroups(arena, &matched, &old_target, &new_target);

    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].applied.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].consumed.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].result_shas.len);
    try std.testing.expectEqualStrings("aaaaaaa", groups[0].applied[0].sha7);
    try std.testing.expectEqualStrings("xxxxxxx", groups[0].consumed[0]);
    try std.testing.expectEqualStrings("zzzzzzz", groups[0].result_shas[0]);
}

test "buildResultGroups batch no interaction produces separate groups" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two applied hunks in different files
    var hunk_a = types.testMakeHunk("a.zig", 1, 3, 1, 5);
    hunk_a.diff_lines = "+aaa";
    hunk_a.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "aaaaaaa");
        @memset(h[7..], '0');
        break :blk h;
    };
    var hunk_b = types.testMakeHunk("b.zig", 1, 3, 1, 5);
    hunk_b.diff_lines = "+bbb";
    hunk_b.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "bbbbbbb");
        @memset(h[7..], '0');
        break :blk h;
    };

    // Results: one per file, matching content
    var res_a = types.testMakeHunk("a.zig", 1, 3, 1, 5);
    res_a.diff_lines = "+aaa";
    res_a.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "xxxxxxx");
        @memset(h[7..], '0');
        break :blk h;
    };
    var res_b = types.testMakeHunk("b.zig", 1, 3, 1, 5);
    res_b.diff_lines = "+bbb";
    res_b.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "yyyyyyy");
        @memset(h[7..], '0');
        break :blk h;
    };

    const matched = [_]MatchedHunk{
        .{ .hunk = &hunk_a, .line_spec = null },
        .{ .hunk = &hunk_b, .line_spec = null },
    };
    const old_target = [_]Hunk{};
    const new_target = [_]Hunk{ res_a, res_b };

    const groups = try buildResultGroups(arena, &matched, &old_target, &new_target);

    try std.testing.expectEqual(@as(usize, 2), groups.len);
    // Each group has 1 applied, 0 consumed, 1 result
    try std.testing.expectEqual(@as(usize, 1), groups[0].applied.len);
    try std.testing.expectEqual(@as(usize, 0), groups[0].consumed.len);
    try std.testing.expectEqual(@as(usize, 1), groups[1].applied.len);
    try std.testing.expectEqual(@as(usize, 0), groups[1].consumed.len);
}

test "buildResultGroups line-spec multi-output merges into one group" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Applied hunk with a line_spec, covering a wide range (lines 1-20 in worktree)
    var applied_hunk = types.testMakeHunk("src/main.zig", 1, 15, 1, 20);
    applied_hunk.diff_lines = "+big change spanning many lines";
    applied_hunk.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "aaaaaaa");
        @memset(h[7..], '0');
        break :blk h;
    };

    // Line spec selects non-contiguous lines (1 and 10), producing two result hunks
    const ranges = [_]types.LineRange{
        .{ .start = 1, .end = 1 },
        .{ .start = 10, .end = 10 },
    };
    const line_spec = types.LineSpec{ .ranges = &ranges };

    // Two created result hunks at different positions in the same file
    var result_1 = types.testMakeHunk("src/main.zig", 1, 1, 1, 2);
    result_1.diff_lines = "+line at top";
    result_1.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "yyyyyyy");
        @memset(h[7..], '0');
        break :blk h;
    };
    var result_2 = types.testMakeHunk("src/main.zig", 10, 1, 10, 2);
    result_2.diff_lines = "+line at bottom";
    result_2.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "zzzzzzz");
        @memset(h[7..], '0');
        break :blk h;
    };

    const matched = [_]MatchedHunk{.{ .hunk = &applied_hunk, .line_spec = line_spec }};
    const old_target = [_]Hunk{};
    const new_target = [_]Hunk{ result_1, result_2 };

    const groups = try buildResultGroups(arena, &matched, &old_target, &new_target);

    // Should be merged into 1 group with 2 result hashes
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].applied.len);
    try std.testing.expectEqual(@as(usize, 2), groups[0].result_shas.len);
    try std.testing.expectEqual(@as(usize, 0), groups[0].consumed.len);
    try std.testing.expectEqualStrings("aaaaaaa", groups[0].applied[0].sha7);
    try std.testing.expectEqualStrings("yyyyyyy", groups[0].result_shas[0]);
    try std.testing.expectEqualStrings("zzzzzzz", groups[0].result_shas[1]);
    try std.testing.expect(groups[0].applied[0].line_spec != null);
}
