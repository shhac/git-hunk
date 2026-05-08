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
const DiffOptions = types.DiffOptions;
const CountOptions = types.CountOptions;
const CheckOptions = types.CheckOptions;
const RestoreOptions = types.RestoreOptions;
const StashOptions = types.StashOptions;
const CommitOptions = types.CommitOptions;
const rangesOverlap = types.rangesOverlap;
const Verbosity = types.Verbosity;
const defaultIo = types.getIo;

/// Get diff output including untracked files (unstaged mode only).
/// Returns the tracked diff output and, separately, the untracked diff output.
/// Both must remain alive while hunks reference them (hunks contain sub-slices).
/// Hunks from untracked files have `is_untracked = true`.
fn getDiffWithUntracked(
    allocator: Allocator,
    arena: Allocator,
    mode: DiffMode,
    ref: ?[]const u8,
    context: ?u32,
    file_filter: []const []const u8,
    diff_filter: DiffFilter,
    hunks: *std.ArrayList(Hunk),
) !struct { tracked: []u8, untracked: []u8 } {
    // Skip tracked diffs when only untracked files are requested
    const diff_output = if (diff_filter == .untracked_only)
        try allocator.alloc(u8, 0)
    else
        try git.runGitDiff(allocator, mode, ref, context);
    errdefer allocator.free(diff_output);

    if (diff_output.len > 0) {
        try diff_mod.parseDiff(arena, diff_output, mode, hunks);
    }

    // Untracked files appear only when the worktree is the right-side endpoint:
    // - No ref, unstaged: worktree is right side → include
    // - Single ref, unstaged: worktree is right side → include
    // - Staged (with or without ref): index is right side → exclude
    // - Range (contains ".."): no worktree involved → exclude
    const is_range = if (ref) |r| std.mem.indexOf(u8, r, "..") != null else false;
    if (mode == .unstaged and !is_range and diff_filter != .tracked_only) {
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

    const diffs = try getDiffWithUntracked(allocator, arena, opts.mode, opts.ref, opts.context, opts.file_filter, opts.diff_filter, &hunks);
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
            if (!types.matchesFileFilter(h.file_path, opts.file_filter)) continue;
            max_path_len = @max(max_path_len, h.file_path.len + @as(usize, if (h.is_symlink) 1 else 0));
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
        if (!types.matchesFileFilter(h.file_path, opts.file_filter)) continue;
        if (!std.mem.eql(u8, h.file_path, last_file)) {
            file_count += 1;
            last_file = h.file_path;
        }
        hunk_count += 1;
        if (opts.verbosity != .quiet) {
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
    }

    // Count summary (verbose + human output only, when there are hunks)
    if (opts.verbosity == .verbose and opts.output == .human and hunk_count > 0) {
        std.debug.print("{d} hunks across {d} files\n", .{ hunk_count, file_count });
    }

}

pub fn cmdCount(allocator: Allocator, stdout: *std.Io.Writer, opts: CountOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, opts.mode, opts.ref, opts.context, opts.file_filter, opts.diff_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    var count: usize = 0;
    for (hunks.items) |h| {
        if (!types.matchesFileFilter(h.file_path, opts.file_filter)) continue;
        count += 1;
    }

    if (opts.verbosity != .quiet) {
        try stdout.print("{d}\n", .{count});
    }
}

const CheckStatus = enum { ok, stale, ambiguous };

const CheckResult = struct {
    prefix: []const u8,
    status: CheckStatus,
    resolved_sha7: []const u8,
    file_path: []const u8,
};

const CheckSummary = struct {
    results: []const CheckResult,
    unexpected: []const *const Hunk,
    has_failure: bool,
};

/// Resolve each unique SHA prefix against `hunks` and (if `exclusive`) collect
/// hunks that no provided prefix matched. Returns a pure data summary.
fn runChecks(
    arena: Allocator,
    hunks: []const Hunk,
    sha_args: []const types.ShaArg,
    file_filter: []const []const u8,
    exclusive: bool,
) !CheckSummary {
    var unique_prefixes: std.ArrayList([]const u8) = .empty;
    for (sha_args) |sha_arg| {
        var already = false;
        for (unique_prefixes.items) |p| {
            if (std.mem.eql(u8, p, sha_arg.prefix)) {
                already = true;
                break;
            }
        }
        if (!already) try unique_prefixes.append(arena, sha_arg.prefix);
    }

    var results: std.ArrayList(CheckResult) = .empty;
    var matched_sha_hexes: std.ArrayList(*const [40]u8) = .empty;
    var has_failure = false;

    for (unique_prefixes.items) |prefix| {
        if (patch_mod.findHunkByShaPrefix(hunks, prefix, file_filter)) |hunk| {
            try results.append(arena, .{
                .prefix = prefix,
                .status = .ok,
                .resolved_sha7 = hunk.sha_hex[0..7],
                .file_path = hunk.file_path,
            });
            try matched_sha_hexes.append(arena, &hunk.sha_hex);
        } else |err| {
            const status: CheckStatus = switch (err) {
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

    var unexpected: std.ArrayList(*const Hunk) = .empty;
    if (exclusive) {
        for (hunks) |*h| {
            if (!types.matchesFileFilter(h.file_path, file_filter)) continue;
            var was_matched = false;
            for (matched_sha_hexes.items) |sha_ptr| {
                if (std.mem.eql(u8, &h.sha_hex, sha_ptr)) {
                    was_matched = true;
                    break;
                }
            }
            if (!was_matched) {
                try unexpected.append(arena, h);
                has_failure = true;
            }
        }
    }

    return .{ .results = results.items, .unexpected = unexpected.items, .has_failure = has_failure };
}

/// Render a check summary in tab-separated porcelain form (every entry, success or failure).
fn renderCheckPorcelain(stdout: *std.Io.Writer, summary: CheckSummary) !void {
    for (summary.results) |r| {
        switch (r.status) {
            .ok => try stdout.print("ok\t{s}\t{s}\t{s}\n", .{ r.prefix, r.resolved_sha7, r.file_path }),
            .stale => try stdout.print("stale\t{s}\n", .{r.prefix}),
            .ambiguous => try stdout.print("ambiguous\t{s}\n", .{r.prefix}),
        }
    }
    for (summary.unexpected) |h| {
        try stdout.print("unexpected\t{s}\t", .{h.sha_hex[0..7]});
        try format.writeFilePath(stdout, h.*);
        try stdout.writeByte('\n');
    }
}

/// Render a check summary in human form (failures only, with stderr summary line).
fn renderCheckHuman(stdout: *std.Io.Writer, summary: CheckSummary, use_color: bool) !void {
    if (!summary.has_failure) return;
    for (summary.results) |r| {
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
    for (summary.unexpected) |h| {
        if (use_color) {
            try stdout.print("unexpected {s}{s}{s}  ", .{ format.COLOR_YELLOW, h.sha_hex[0..7], format.COLOR_RESET });
        } else {
            try stdout.print("unexpected {s}  ", .{h.sha_hex[0..7]});
        }
        try format.writeFilePath(stdout, h.*);
        try stdout.writeByte('\n');
    }

    var fail_count: usize = 0;
    for (summary.results) |r| {
        if (r.status != .ok) fail_count += 1;
    }
    const unexpected_count = summary.unexpected.len;
    if (fail_count > 0 and unexpected_count > 0) {
        std.debug.print("{d} of {d} hashes failed, {d} unexpected hunk{s}\n", .{
            fail_count,
            summary.results.len,
            unexpected_count,
            @as([]const u8, if (unexpected_count == 1) "" else "s"),
        });
    } else if (fail_count > 0) {
        std.debug.print("{d} of {d} hashes failed\n", .{ fail_count, summary.results.len });
    } else if (unexpected_count > 0) {
        std.debug.print("exclusive check failed: {d} unexpected hunk{s}\n", .{
            unexpected_count,
            @as([]const u8, if (unexpected_count == 1) "" else "s"),
        });
    }
}

pub fn cmdCheck(allocator: Allocator, stdout: *std.Io.Writer, opts: CheckOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, opts.mode, opts.ref, opts.context, opts.file_filter, opts.diff_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    const summary = try runChecks(arena, hunks.items, opts.sha_args.items, opts.file_filter, opts.exclusive);

    // --allow-empty with no SHAs: skip rendering "ok" entries (there are none) — only
    // unexpected hunks can fail. If there are none, exit successfully.
    if (opts.allow_empty and opts.sha_args.items.len == 0 and !summary.has_failure) return;

    if (opts.verbosity != .quiet) {
        if (opts.output == .porcelain) {
            try renderCheckPorcelain(stdout, summary);
        } else {
            const use_color = format.shouldUseColor(opts.output, opts.no_color);
            try renderCheckHuman(stdout, summary, use_color);
        }
    }

    if (summary.has_failure) {
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
    /// Whether this file is a symlink (mode 120000).
    is_symlink: bool,
};

/// Pre-existing target-side hunks absorbed into the result (sha not in new_target).
fn findConsumed(arena: Allocator, old_target: []const Hunk, new_target: []const Hunk) ![]*const Hunk {
    var list: std.ArrayList(*const Hunk) = .empty;
    for (old_target) |*oh| {
        var survived = false;
        for (new_target) |*nh| {
            if (std.mem.eql(u8, &oh.sha_hex, &nh.sha_hex)) {
                survived = true;
                break;
            }
        }
        if (!survived) try list.append(arena, oh);
    }
    return list.items;
}

/// New target-side hunks that didn't exist before (sha not in old_target).
fn findCreated(arena: Allocator, old_target: []const Hunk, new_target: []const Hunk) ![]*const Hunk {
    var list: std.ArrayList(*const Hunk) = .empty;
    for (new_target) |*nh| {
        var existed = false;
        for (old_target) |*oh| {
            if (std.mem.eql(u8, &nh.sha_hex, &oh.sha_hex)) {
                existed = true;
                break;
            }
        }
        if (!existed) try list.append(arena, nh);
    }
    return list.items;
}

/// For each created hunk, attribute contributing applied inputs (by content or
/// new-side line overlap) and consumed hunks (by old-side line overlap). Marks
/// `applied_used` / `consumed_used` flags as it goes.
fn assignAppliedAndConsumed(
    arena: Allocator,
    matched: []const MatchedHunk,
    consumed: []const *const Hunk,
    created: []const *const Hunk,
    applied_used: []bool,
    consumed_used: []bool,
) ![]ResultGroup {
    var groups: std.ArrayList(ResultGroup) = .empty;

    for (created) |c| {
        var app_buf: std.ArrayList(AppliedInput) = .empty;
        var con_buf: std.ArrayList([]const u8) = .empty;

        for (matched, 0..) |m, i| {
            if (applied_used[i]) continue;
            if (!std.mem.eql(u8, m.hunk.file_path, c.file_path)) continue;

            const content_match = m.line_spec == null and
                std.mem.eql(u8, m.hunk.diff_lines, c.diff_lines);
            const line_match = !content_match and rangesOverlap(
                m.hunk.new_start, m.hunk.new_count,
                c.new_start, c.new_count,
            );

            if (content_match or line_match) {
                try app_buf.append(arena, .{
                    .sha7 = m.hunk.sha_hex[0..7],
                    .line_spec = m.line_spec,
                });
                applied_used[i] = true;
            }
        }

        for (consumed, 0..) |con, i| {
            if (consumed_used[i]) continue;
            if (!std.mem.eql(u8, con.file_path, c.file_path)) continue;

            if (rangesOverlap(con.old_start, con.old_count, c.old_start, c.old_count)) {
                try con_buf.append(arena, con.sha_hex[0..7]);
                consumed_used[i] = true;
            }
        }

        const result_sha = try arena.alloc([]const u8, 1);
        result_sha[0] = c.sha_hex[0..7];

        try groups.append(arena, .{
            .result_shas = result_sha,
            .applied = try app_buf.toOwnedSlice(arena),
            .consumed = try con_buf.toOwnedSlice(arena),
            .file_path = c.file_path,
            .is_symlink = c.is_symlink,
        });
    }
    return groups.items;
}

/// Append unmatched applied hunks as standalone groups with no result_shas.
fn appendOrphanedApplied(
    arena: Allocator,
    groups: *std.ArrayList(ResultGroup),
    matched: []const MatchedHunk,
    applied_used: []const bool,
) !void {
    for (matched, 0..) |m, i| {
        if (applied_used[i]) continue;
        const app = try arena.alloc(AppliedInput, 1);
        app[0] = .{ .sha7 = m.hunk.sha_hex[0..7], .line_spec = m.line_spec };
        try groups.append(arena, .{
            .result_shas = &.{},
            .applied = app,
            .consumed = &.{},
            .file_path = m.hunk.file_path,
            .is_symlink = m.hunk.is_symlink,
        });
    }
}

/// A line-spec operation (e.g. `aaaa:1,10`) can produce multiple result hunks.
/// The applied input matches the first created hunk exclusively, so later
/// created hunks have empty `applied`. Merge these orphans into the sibling
/// group that holds the applied input for the same file.
fn mergeOrphansIntoSiblings(arena: Allocator, groups: []ResultGroup) ![]const ResultGroup {
    var final_groups: std.ArrayList(ResultGroup) = .empty;
    for (groups) |rg| {
        if (rg.applied.len > 0) try final_groups.append(arena, rg);
    }
    for (groups) |orphan| {
        if (orphan.applied.len > 0) continue;
        if (orphan.result_shas.len == 0) continue;

        var merged = false;
        for (final_groups.items) |*target| {
            if (!std.mem.eql(u8, target.file_path, orphan.file_path)) continue;

            const combined_res = try arena.alloc([]const u8, target.result_shas.len + orphan.result_shas.len);
            @memcpy(combined_res[0..target.result_shas.len], target.result_shas);
            @memcpy(combined_res[target.result_shas.len..], orphan.result_shas);
            target.result_shas = combined_res;

            if (orphan.consumed.len > 0) {
                const combined_con = try arena.alloc([]const u8, target.consumed.len + orphan.consumed.len);
                @memcpy(combined_con[0..target.consumed.len], target.consumed);
                @memcpy(combined_con[target.consumed.len..], orphan.consumed);
                target.consumed = combined_con;
            }
            merged = true;
            break;
        }
        // No sibling found — keep as standalone group (shouldn't happen in practice).
        if (!merged) try final_groups.append(arena, orphan);
    }
    return final_groups.items;
}

/// Build result groups by comparing old vs new target-side hunks and matching
/// applied/consumed inputs to created results.
///
/// Algorithm:
///   1. Consumed = old target hunks whose sha is absent from new target
///   2. Created  = new target hunks whose sha is absent from old target
///   3. For each created hunk, attribute contributing applied + consumed
///   4. Unmatched applied hunks get their own group with no result hash
///   5. Merge orphan result-only groups (from line-spec splits) into sibling
///      groups that share a file with an applied input
fn buildResultGroups(
    arena: Allocator,
    matched: []const MatchedHunk,
    old_target: []const Hunk,
    new_target: []const Hunk,
) ![]const ResultGroup {
    const consumed = try findConsumed(arena, old_target, new_target);
    const created = try findCreated(arena, old_target, new_target);

    const applied_used = try arena.alloc(bool, matched.len);
    @memset(applied_used, false);
    const consumed_used = try arena.alloc(bool, consumed.len);
    @memset(consumed_used, false);

    var groups: std.ArrayList(ResultGroup) = .empty;
    const initial = try assignAppliedAndConsumed(arena, matched, consumed, created, applied_used, consumed_used);
    try groups.appendSlice(arena, initial);
    try appendOrphanedApplied(arena, &groups, matched, applied_used);

    return try mergeOrphansIntoSiblings(arena, groups.items);
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
            try format.writeLineSpec(stdout, ls);
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
    try stdout.writeAll("  ");
    try stdout.writeAll(rg.file_path);
    if (rg.is_symlink) try stdout.writeByte('@');
    try stdout.writeByte('\n');
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
            try format.writeLineSpec(stdout, ls);
        }
    }

    // result: comma-separated
    try stdout.print("\t", .{});
    for (rg.result_shas, 0..) |rs, i| {
        if (i > 0) try stdout.print(",", .{});
        try stdout.print("{s}", .{rs});
    }

    // file
    try stdout.writeByte('\t');
    try stdout.writeAll(rg.file_path);
    if (rg.is_symlink) try stdout.writeByte('@');

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

/// Resolve SHA prefix args to matched hunks, deduplicating by full SHA and merging
/// line specs. Appends results to `matched`. Exits on NotFound/AmbiguousPrefix errors.
fn resolveMatchedHunks(
    arena: Allocator,
    hunks: []const Hunk,
    sha_args: []const types.ShaArg,
    file_filter: []const []const u8,
    matched: *std.ArrayList(MatchedHunk),
) !void {
    for (sha_args) |sha_arg| {
        const hunk = patch_mod.findHunkByShaPrefix(hunks, sha_arg.prefix, file_filter) catch |err| switch (err) {
            error.NotFound => {
                std.debug.print("error: no hunk matching '{s}'\n", .{sha_arg.prefix});
                std.process.exit(1);
            },
            error.AmbiguousPrefix => {
                std.debug.print("error: ambiguous prefix '{s}' — matches multiple hunks\n", .{sha_arg.prefix});
                std.process.exit(1);
            },
        };
        // Reject line-spec on binary hunks
        if (hunk.is_binary and sha_arg.line_spec != null) {
            std.debug.print("error: line selection not supported for binary file '{s}'\n", .{hunk.file_path});
            std.process.exit(1);
        }
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

/// Resolve hunks: bulk mode (match all, optionally filtered by file) or SHA prefix matching.
fn resolveHunksFromOpts(
    arena: Allocator,
    hunks: []const Hunk,
    sha_args: []const types.ShaArg,
    file_filter: []const []const u8,
    matched: *std.ArrayList(MatchedHunk),
) !void {
    if (sha_args.len == 0) {
        for (hunks) |*h| {
            if (!types.matchesFileFilter(h.file_path, file_filter)) continue;
            try matched.append(arena, .{ .hunk = h, .line_spec = null });
        }
    } else {
        try resolveMatchedHunks(arena, hunks, sha_args, file_filter, matched);
    }
}

/// Exit with an error message if no hunks were matched.
fn exitIfNoMatches(matched_len: usize, file_filter: []const []const u8) void {
    if (matched_len > 0) return;
    if (file_filter.len == 1) {
        std.debug.print("no hunks matching file '{s}'\n", .{file_filter[0]});
    } else if (file_filter.len > 1) {
        std.debug.print("no hunks matching files: ", .{});
        for (file_filter, 0..) |f, idx| {
            if (idx > 0) std.debug.print(", ", .{});
            std.debug.print("'{s}'", .{f});
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("no unstaged changes\n", .{});
    }
    std.process.exit(1);
}

/// Diff against `target_mode` scoped to `file_paths` and parse into `hunks`.
/// Soft-fails: any error leaves `hunks` empty.
fn captureTargetHunks(
    arena: Allocator,
    target_mode: DiffMode,
    context: ?u32,
    file_paths: []const []const u8,
    hunks: *std.ArrayList(Hunk),
) !void {
    if (file_paths.len == 0) return;
    const diff = git.runGitDiffFiles(arena, target_mode, null, context, file_paths) catch return;
    if (diff.len > 0) {
        diff_mod.parseDiff(arena, diff, target_mode, hunks) catch {};
    }
}

/// Apply text patches in order (forward) or reverse order (unstage), then run
/// git add/reset on `binary_paths`.
fn applyTextAndBinary(
    allocator: Allocator,
    arena: Allocator,
    action: ApplyAction,
    text_matched: []MatchedHunk,
    binary_paths: []const []const u8,
    ref: ?[]const u8,
) !void {
    if (text_matched.len > 0) {
        std.mem.sort(MatchedHunk, text_matched, {}, patch_mod.matchedHunkPatchOrder);
        const patches = try patch_mod.buildCombinedPatches(arena, text_matched);
        const reverse = action == .unstage;
        if (reverse) {
            var i: usize = patches.len;
            while (i > 0) {
                i -= 1;
                try git.runGitApply(allocator, patches[i], reverse, .index, false, ref);
            }
        } else {
            for (patches) |patch| {
                try git.runGitApply(allocator, patch, reverse, .index, false, ref);
            }
        }
    }
    if (binary_paths.len > 0) {
        switch (action) {
            .stage => try git.runGitAddFiles(allocator, binary_paths),
            .unstage => try git.runGitResetFiles(allocator, binary_paths),
        }
    }
}

/// Print result groups for text hunks (with merge tracking) and per-hunk lines
/// for binary hunks (no merge tracking). Returns the totals for the summary.
fn renderApplyResults(
    stdout: *std.Io.Writer,
    opts: AddResetOptions,
    action: ApplyAction,
    result_groups: []const ResultGroup,
    binary_matched: []const MatchedHunk,
) !struct { count: usize, merged_count: usize } {
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
        if (opts.verbosity != .quiet) {
            switch (opts.output) {
                .human => try printResultGroupHuman(stdout, verb, rg, use_color),
                .porcelain => try printResultGroupPorcelain(stdout, verb, rg),
            }
        }
    }
    for (binary_matched) |m| {
        count += 1;
        if (opts.verbosity != .quiet) {
            try format.printMatchedHunkLine(stdout, verb, verb, m, use_color, opts.output);
        }
    }

    if (opts.verbosity == .verbose and opts.output == .human) {
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
    if (action == .stage and opts.verbosity == .verbose and opts.output == .human) {
        std.debug.print("hint: staged hashes differ from unstaged -- use 'git hunk list --staged' to see them\n", .{});
    }
    return .{ .count = count, .merged_count = merged_count };
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

    const diffs = try getDiffWithUntracked(allocator, arena, diff_mode, opts.ref, opts.context, opts.file_filter, opts.diff_filter, &hunks);
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

    var matched: std.ArrayList(MatchedHunk) = .empty;
    defer matched.deinit(arena);
    try resolveHunksFromOpts(arena, hunks.items, opts.sha_args.items, opts.file_filter, &matched);

    const partition = try patch_mod.partitionByKind(arena, matched.items);
    const text_matched = blk: {
        var combined: std.ArrayList(MatchedHunk) = .empty;
        try combined.appendSlice(arena, partition.tracked_text);
        try combined.appendSlice(arena, partition.untracked_text);
        break :blk combined.items;
    };
    const binary_paths = partition.binary_paths;
    const binary_matched = blk: {
        var combined: std.ArrayList(MatchedHunk) = .empty;
        try combined.appendSlice(arena, partition.tracked_binary);
        try combined.appendSlice(arena, partition.untracked_binary);
        break :blk combined.items;
    };

    // Capture target-side hunks BEFORE and AFTER applying so buildResultGroups
    // can detect merges and map applied hunks to their post-apply hashes.
    const file_paths = try patch_mod.collectUniqueFilePaths(arena, matched.items);
    const target_mode: DiffMode = switch (action) {
        .stage => .staged,
        .unstage => .unstaged,
    };
    var old_target_hunks: std.ArrayList(Hunk) = .empty;
    defer old_target_hunks.deinit(arena);
    if (text_matched.len > 0) try captureTargetHunks(arena, target_mode, opts.context, file_paths, &old_target_hunks);

    try applyTextAndBinary(allocator, arena, action, text_matched, binary_paths, opts.ref);

    var new_hunks: std.ArrayList(Hunk) = .empty;
    defer new_hunks.deinit(arena);
    if (text_matched.len > 0) try captureTargetHunks(arena, target_mode, opts.context, file_paths, &new_hunks);

    const result_groups = try buildResultGroups(arena, text_matched, old_target_hunks.items, new_hunks.items);
    _ = try renderApplyResults(stdout, opts, action, result_groups, binary_matched);
}

pub fn cmdRestore(allocator: Allocator, stdout: *std.Io.Writer, opts: RestoreOptions) !void {
    // Restore always operates on unstaged hunks (worktree vs index)
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, .unstaged, opts.ref, opts.context, opts.file_filter, opts.diff_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    if (hunks.items.len == 0) {
        std.debug.print("no unstaged changes\n", .{});
        std.process.exit(1);
    }

    var matched: std.ArrayList(MatchedHunk) = .empty;
    defer matched.deinit(arena);
    try resolveHunksFromOpts(arena, hunks.items, opts.sha_args.items, opts.file_filter, &matched);
    exitIfNoMatches(matched.items.len, opts.file_filter);

    // Gate: untracked files require --force (restoring deletes them permanently)
    // Dry-run bypasses the gate — safe to preview without --force
    if (!opts.force and !opts.dry_run) {
        for (matched.items) |m| {
            if (m.hunk.is_untracked) {
                std.debug.print("error: {s} ({s}) is an untracked file -- use --force to delete\n", .{ m.hunk.sha_hex[0..7], m.hunk.file_path });
                std.process.exit(1);
            }
        }
    }

    const partition = try patch_mod.partitionByKind(arena, matched.items);
    var text_matched: std.ArrayList(MatchedHunk) = .empty;
    try text_matched.appendSlice(arena, partition.tracked_text);
    try text_matched.appendSlice(arena, partition.untracked_text);

    // Text hunks: reverse-apply patches to worktree
    if (text_matched.items.len > 0) {
        std.mem.sort(MatchedHunk, text_matched.items, {}, patch_mod.matchedHunkPatchOrder);
        const patches = try patch_mod.buildCombinedPatches(arena, text_matched.items);
        var i: usize = patches.len;
        while (i > 0) {
            i -= 1;
            try git.runGitApply(allocator, patches[i], true, .worktree, opts.dry_run, opts.ref);
        }
    }

    // Binary tracked hunks: restore from index
    if (partition.tracked_binary_paths.len > 0 and !opts.dry_run) {
        try git.runGitCheckoutFiles(allocator, partition.tracked_binary_paths);
    }

    // Binary untracked hunks: delete files
    if (partition.untracked_binary_paths.len > 0 and !opts.dry_run) {
        const io = defaultIo();
        for (partition.untracked_binary_paths) |fp| {
            std.Io.Dir.cwd().deleteFile(io, fp) catch {
                std.debug.print("warning: could not delete untracked binary file '{s}'\n", .{fp});
            };
        }
    }

    // Output
    const use_color = format.shouldUseColor(opts.output, opts.no_color);

    const verb: []const u8 = if (opts.dry_run) "would restore" else "restored";
    const porcelain_verb: []const u8 = if (opts.dry_run) "would-restore" else "restored";

    var count: usize = 0;
    for (matched.items) |m| {
        count += 1;
        if (opts.verbosity != .quiet) {
            try format.printMatchedHunkLine(stdout, verb, porcelain_verb, m, use_color, opts.output);
        }
    }

    // Summary on stderr (verbose + human mode only)
    if (opts.verbosity == .verbose and opts.output == .human) {
        if (opts.dry_run) {
            if (count == 1) {
                std.debug.print("1 hunk would be restored\n", .{});
            } else {
                std.debug.print("{d} hunks would be restored\n", .{count});
            }
        } else {
            if (count == 1) {
                std.debug.print("1 hunk restored\n", .{});
            } else {
                std.debug.print("{d} hunks restored\n", .{count});
            }
        }
    }
}

pub fn cmdDiff(allocator: Allocator, stdout: *std.Io.Writer, opts: DiffOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, opts.mode, opts.ref, opts.context, opts.file_filter, opts.diff_filter, &hunks);
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

    try resolveMatchedHunks(arena, hunks.items, opts.sha_args.items, opts.file_filter, &matched);

    const use_color = format.shouldUseColor(opts.output, opts.no_color);

    // Print each matched hunk
    if (opts.verbosity != .quiet) {
        for (matched.items) |m| {
            switch (opts.output) {
                .human => {
                    try stdout.writeAll(m.hunk.patch_header);
                    if (m.hunk.is_binary) {
                        try stdout.writeAll("Binary file changed\n\n");
                    } else if (m.hunk.raw_lines.len == 0) {
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
}

/// Bundles HEAD-side metadata used by cmdStash. All slices are gpa-owned.
const HeadInfo = struct {
    tree: []u8,
    sha: []u8,
    branch: ?[]u8,
    msg: []u8,
    branch_name: []const u8,

    fn deinit(self: *HeadInfo, allocator: Allocator) void {
        allocator.free(self.tree);
        allocator.free(self.sha);
        if (self.branch) |b| allocator.free(b);
        allocator.free(self.msg);
    }
};

/// Look up HEAD tree, HEAD sha, branch name, and HEAD commit summary in one
/// place. Caller must call `deinit` on the returned struct.
fn gatherHeadInfo(allocator: Allocator) !HeadInfo {
    const tree = try git.runGitRevParseTree(allocator);
    errdefer allocator.free(tree);
    const sha = try git.runGitRevParse(allocator, "HEAD");
    errdefer allocator.free(sha);
    const branch = try git.runGitSymbolicRef(allocator);
    errdefer if (branch) |b| allocator.free(b);
    const msg = try git.runGitLogOneline(allocator);
    return .{ .tree = tree, .sha = sha, .branch = branch, .msg = msg, .branch_name = branch orelse "HEAD" };
}

/// Result of running both the tracked-text and tracked-binary tree pipelines.
const StashTreeBuild = struct {
    tree: []const u8,
    /// Patches reverse-applied to worktree at cleanup. Empty if no tracked text hunks.
    index_patches: []const []const u8,
    /// True iff `tree` was allocated by stash_mod and must be freed by the caller.
    owns_tree: bool,
};

/// Construct the stash tree by layering tracked-binary blobs onto a tree built
/// from tracked-text patches. Falls back to `head_tree` when there are neither.
fn buildStashTree(
    arena: Allocator,
    allocator: Allocator,
    partition: patch_mod.HunkPartition,
    head_tree: []const u8,
    context: ?u32,
    env_map: *const std.process.Environ.Map,
) !StashTreeBuild {
    var tree: []const u8 = head_tree;
    var index_patches: []const []const u8 = &.{};
    var owns = false;
    errdefer if (owns) allocator.free(tree);

    if (partition.tracked_text.len > 0) {
        const tracked_mut = try arena.dupe(MatchedHunk, partition.tracked_text);
        const result = try stash_mod.buildTrackedStashTree(arena, allocator, tracked_mut, head_tree, context, env_map);
        index_patches = result.index_patches;
        tree = result.stash_tree;
        owns = true;
    }
    if (partition.tracked_binary_paths.len > 0) {
        const new_tree = try stash_mod.addBinaryFilesToTree(arena, allocator, tree, partition.tracked_binary_paths, env_map);
        if (owns) allocator.free(tree);
        tree = new_tree;
        owns = true;
    }
    return .{ .tree = tree, .index_patches = index_patches, .owns_tree = owns };
}

/// Build the stash message: user-provided `-m <msg>` or auto-generated from
/// the file paths involved.
fn buildStashMessage(arena: Allocator, opts: StashOptions, matched: []const MatchedHunk) ![]const u8 {
    if (opts.message) |m| return m;
    const all_file_paths = try patch_mod.collectUniqueFilePaths(arena, matched);
    var msg_buf: std.ArrayList(u8) = .empty;
    try msg_buf.appendSlice(arena, "git-hunk stash: ");
    for (all_file_paths, 0..) |fp, i| {
        if (i > 0) try msg_buf.appendSlice(arena, ", ");
        try msg_buf.appendSlice(arena, fp);
    }
    return msg_buf.items;
}

pub fn cmdStash(allocator: Allocator, stdout: *std.Io.Writer, opts: StashOptions, env_map: *const std.process.Environ.Map) !void {
    if (opts.pop) {
        try stash_mod.stashPop(allocator, opts.verbosity);
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

    const diffs = try getDiffWithUntracked(allocator, arena, .unstaged, opts.ref, opts.context, opts.file_filter, effective_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    if (hunks.items.len == 0) {
        std.debug.print("no unstaged changes\n", .{});
        std.process.exit(1);
    }

    var matched: std.ArrayList(MatchedHunk) = .empty;
    defer matched.deinit(arena);
    try resolveHunksFromOpts(arena, hunks.items, opts.sha_args.items, opts.file_filter, &matched);
    exitIfNoMatches(matched.items.len, opts.file_filter);

    const partition = try patch_mod.partitionByKind(arena, matched.items);
    var untracked_matched: std.ArrayList(MatchedHunk) = .empty;
    try untracked_matched.appendSlice(arena, partition.untracked_text);
    try untracked_matched.appendSlice(arena, partition.untracked_binary);
    const has_tracked = partition.tracked_text.len > 0;
    const has_binary_tracked = partition.tracked_binary.len > 0;
    const has_untracked = untracked_matched.items.len > 0;

    var head = try gatherHeadInfo(allocator);
    defer head.deinit(allocator);

    const stash_build = try buildStashTree(arena, allocator, partition, head.tree, opts.context, env_map);
    defer if (stash_build.owns_tree) allocator.free(stash_build.tree);

    // Index commit (parent 2): captures tracked changes tree
    const idx_msg = try std.fmt.allocPrint(arena, "index on {s}: {s}", .{ head.branch_name, head.msg });
    const idx_commit = try git.runGitCommitTree(allocator, stash_build.tree, &.{head.sha}, idx_msg);
    defer allocator.free(idx_commit);

    // Untracked hunks pipeline (parent 3)
    var untracked_commit: ?[]const u8 = null;
    if (has_untracked) {
        untracked_commit = try stash_mod.buildUntrackedCommit(arena, allocator, head.sha, head.branch_name, head.msg, untracked_matched.items, env_map);
    }
    defer if (untracked_commit) |uc| allocator.free(uc);

    const stash_msg = try buildStashMessage(arena, opts, matched.items);

    const wip_commit = if (untracked_commit) |uc|
        try git.runGitCommitTree(allocator, stash_build.tree, &.{ head.sha, idx_commit, uc }, stash_msg)
    else
        try git.runGitCommitTree(allocator, stash_build.tree, &.{ head.sha, idx_commit }, stash_msg);
    defer allocator.free(wip_commit);

    try git.runGitStashStore(allocator, stash_msg, wip_commit);

    // Cleanup: restore binary tracked files from index, reverse-apply text patches,
    // delete untracked files.
    if (has_binary_tracked) {
        git.runGitCheckoutFiles(allocator, partition.tracked_binary_paths) catch {
            std.debug.print("warning: stash created but could not restore binary files from index\n", .{});
        };
    }
    stash_mod.cleanupWorktree(allocator, has_tracked, has_untracked, stash_build.index_patches, untracked_matched.items);

    try stash_mod.reportStashResults(stdout, opts, matched.items);
}

/// Restore the index from the backup (best-effort) and exit. Used when the
/// transactional commit hits a fatal mid-transaction error.
fn abortCommitAndExit(cwd: std.Io.Dir, io: std.Io, backup_path: []const u8, index_path: []const u8) noreturn {
    std.Io.Dir.copyFile(cwd, backup_path, cwd, index_path, io, .{}) catch {};
    cwd.deleteFile(io, backup_path) catch {};
    std.process.exit(1);
}

/// If a stale `index.hunk-backup` exists from a previously-interrupted commit,
/// restore it over `index` and remove it. Exits on restore failure.
fn recoverStaleIndexBackup(cwd: std.Io.Dir, io: std.Io, backup_path: []const u8, index_path: []const u8) void {
    _ = cwd.statFile(io, backup_path, .{}) catch return;
    std.debug.print("warning: stale index backup found from interrupted commit -- restoring original index\n", .{});
    std.Io.Dir.copyFile(cwd, backup_path, cwd, index_path, io, .{}) catch {
        std.debug.print("error: failed to restore index backup\n", .{});
        std.process.exit(1);
    };
    cwd.deleteFile(io, backup_path) catch {};
}

const CommitContext = struct {
    allocator: Allocator,
    patches: []const []const u8,
    binary_paths: []const []const u8,
    message: []const u8,
    amend: bool,
    ref: ?[]const u8,
    cwd: std.Io.Dir,
    io: std.Io,
    backup_path: []const u8,
    index_path: []const u8,
};

/// Run the 7-step transactional commit (backup → reset → apply → commit →
/// restore → resync → cleanup) and return the captured commit output. Aborts
/// the process on a fatal mid-transaction error after restoring the backup.
fn runTransactionalCommit(ctx: CommitContext) ![]const u8 {
    // 1. Save index
    std.Io.Dir.copyFile(ctx.cwd, ctx.index_path, ctx.cwd, ctx.backup_path, ctx.io, .{}) catch {
        std.debug.print("error: failed to backup index file\n", .{});
        std.process.exit(1);
    };

    // 2. Reset index to HEAD (or HEAD~1 for amend)
    const read_tree_ref: []const u8 = if (ctx.amend) "HEAD~1" else "HEAD";
    git.runGitReadTree(ctx.allocator, read_tree_ref) catch abortCommitAndExit(ctx.cwd, ctx.io, ctx.backup_path, ctx.index_path);

    // 3. Stage target hunks (text via patch, binary via git add)
    for (ctx.patches) |p| {
        git.runGitApply(ctx.allocator, p, false, .index, false, ctx.ref) catch abortCommitAndExit(ctx.cwd, ctx.io, ctx.backup_path, ctx.index_path);
    }
    if (ctx.binary_paths.len > 0) {
        git.runGitAddFiles(ctx.allocator, ctx.binary_paths) catch abortCommitAndExit(ctx.cwd, ctx.io, ctx.backup_path, ctx.index_path);
    }

    // 4. Commit
    const commit_output = git.runGitCommit(ctx.allocator, .{ .message = ctx.message, .amend = ctx.amend }) catch
        abortCommitAndExit(ctx.cwd, ctx.io, ctx.backup_path, ctx.index_path);
    errdefer ctx.allocator.free(commit_output);

    // 5. Restore original index
    std.Io.Dir.copyFile(ctx.cwd, ctx.backup_path, ctx.cwd, ctx.index_path, ctx.io, .{}) catch {
        std.debug.print("warning: commit succeeded but failed to restore original index -- backup at {s}\n", .{ctx.backup_path});
    };

    // 6. Sync index with new HEAD (text via patch, binary via git add)
    for (ctx.patches) |p| {
        git.runGitApply(ctx.allocator, p, false, .index, false, ctx.ref) catch {
            std.debug.print("warning: commit succeeded but index sync failed -- run 'git hunk add' to re-sync\n", .{});
            break;
        };
    }
    if (ctx.binary_paths.len > 0) {
        git.runGitAddFiles(ctx.allocator, ctx.binary_paths) catch {
            std.debug.print("warning: commit succeeded but binary file index sync failed -- run 'git add' to re-sync\n", .{});
        };
    }

    // 7. Cleanup
    ctx.cwd.deleteFile(ctx.io, ctx.backup_path) catch {};

    return commit_output;
}

fn printCommitResults(stdout: *std.Io.Writer, opts: CommitOptions, matched: []const MatchedHunk, commit_output: []const u8) !void {
    const use_color = format.shouldUseColor(opts.output, opts.no_color);
    var count: usize = 0;
    for (matched) |m| {
        count += 1;
        if (opts.verbosity != .quiet) {
            try format.printMatchedHunkLine(stdout, "committed", "committed", m, use_color, opts.output);
        }
    }

    if (opts.verbosity != .quiet and commit_output.len > 0) {
        std.debug.print("{s}\n", .{commit_output});
    }

    if (opts.verbosity == .verbose and opts.output == .human) {
        if (count == 1) {
            std.debug.print("1 hunk committed\n", .{});
        } else {
            std.debug.print("{d} hunks committed\n", .{count});
        }
    }
}

pub fn cmdCommit(allocator: Allocator, stdout: *std.Io.Writer, opts: CommitOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Locate git dir and construct backup paths.
    const git_dir = try git.runGitRevParseGitDir(allocator);
    defer allocator.free(git_dir);
    const index_path = try std.fmt.allocPrint(arena, "{s}/index", .{git_dir});
    const backup_path = try std.fmt.allocPrint(arena, "{s}/index.hunk-backup", .{git_dir});
    const io = defaultIo();
    const cwd = std.Io.Dir.cwd();

    recoverStaleIndexBackup(cwd, io, backup_path, index_path);

    // Resolve hunks (same pattern as cmdApplyHunks/cmdRestore).
    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(arena);

    const diffs = try getDiffWithUntracked(allocator, arena, .unstaged, opts.ref, opts.context, opts.file_filter, opts.diff_filter, &hunks);
    defer allocator.free(diffs.tracked);
    defer allocator.free(diffs.untracked);

    if (hunks.items.len == 0) {
        std.debug.print("no unstaged changes\n", .{});
        std.process.exit(1);
    }

    var matched: std.ArrayList(MatchedHunk) = .empty;
    defer matched.deinit(arena);

    try resolveHunksFromOpts(arena, hunks.items, opts.sha_args.items, opts.file_filter, &matched);
    exitIfNoMatches(matched.items.len, opts.file_filter);

    const partition = try patch_mod.partitionByKind(arena, matched.items);
    const text_matched = blk: {
        var combined: std.ArrayList(MatchedHunk) = .empty;
        try combined.appendSlice(arena, partition.tracked_text);
        try combined.appendSlice(arena, partition.untracked_text);
        break :blk combined.items;
    };
    const binary_paths = partition.binary_paths;

    std.mem.sort(MatchedHunk, text_matched, {}, patch_mod.matchedHunkPatchOrder);

    const patches = try patch_mod.buildCombinedPatches(arena, text_matched);
    if (patches.len == 0 and binary_paths.len == 0) {
        std.debug.print("error: no hunks to commit\n", .{});
        std.process.exit(1);
    }

    const message = opts.message orelse {
        std.debug.print("error: -m <message> is required\n", .{});
        std.process.exit(1);
    };

    // Dry-run: validate patches against the index (without modifying it) and show what would be committed.
    if (opts.dry_run) {
        for (patches) |p| {
            try git.runGitApply(allocator, p, false, .index, true, opts.ref);
        }
        const use_color = format.shouldUseColor(opts.output, opts.no_color);
        for (matched.items) |m| {
            if (opts.verbosity != .quiet) {
                try format.printMatchedHunkLine(stdout, "would commit", "would-commit", m, use_color, opts.output);
            }
        }
        return;
    }

    const commit_output = try runTransactionalCommit(.{
        .allocator = allocator,
        .patches = patches,
        .binary_paths = binary_paths,
        .message = message,
        .amend = opts.amend,
        .ref = opts.ref,
        .cwd = cwd,
        .io = io,
        .backup_path = backup_path,
        .index_path = index_path,
    });
    defer allocator.free(commit_output);

    try printCommitResults(stdout, opts, matched.items, commit_output);
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

test "buildResultGroups orphan with no sibling becomes standalone" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No applied hunks — simulates a scenario where a result exists with no matching applied input
    const matched = [_]MatchedHunk{};
    const old_target = [_]Hunk{};

    // One result hunk with no applied hunk to match
    var orphan_result = types.testMakeHunk("orphan.zig", 1, 1, 1, 2);
    orphan_result.diff_lines = "+orphaned";
    orphan_result.sha_hex = comptime blk: {
        var h: [40]u8 = undefined;
        @memcpy(h[0..7], "ooooooo");
        @memset(h[7..], '0');
        break :blk h;
    };
    const new_target = [_]Hunk{orphan_result};

    const groups = try buildResultGroups(arena, &matched, &old_target, &new_target);

    // Orphan with no sibling file becomes a standalone group
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 0), groups[0].applied.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].result_shas.len);
    try std.testing.expectEqualStrings("ooooooo", groups[0].result_shas[0]);
}
