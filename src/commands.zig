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

/// Returns pointers to hunks in `minuend` whose `sha_hex` is absent from
/// `subtrahend`. Used to compute "consumed" (old\new) and "created" (new\old).
fn shaSetDifference(arena: Allocator, minuend: []const Hunk, subtrahend: []const Hunk) ![]*const Hunk {
    var list: std.ArrayList(*const Hunk) = .empty;
    outer: for (minuend) |*m| {
        for (subtrahend) |*s| {
            if (std.mem.eql(u8, &m.sha_hex, &s.sha_hex)) continue :outer;
        }
        try list.append(arena, m);
    }
    return list.items;
}

/// Pre-existing target-side hunks absorbed into the result (sha not in new_target).
fn findConsumed(arena: Allocator, old_target: []const Hunk, new_target: []const Hunk) ![]*const Hunk {
    return shaSetDifference(arena, old_target, new_target);
}

/// New target-side hunks that didn't exist before (sha not in old_target).
fn findCreated(arena: Allocator, old_target: []const Hunk, new_target: []const Hunk) ![]*const Hunk {
    return shaSetDifference(arena, new_target, old_target);
}

/// For each created hunk, attribute contributing applied inputs (by content or
/// new-side line overlap) and consumed hunks (by old-side line overlap). Marks
/// `applied_used` / `consumed_used` flags as it goes.
/// Find applied inputs that contributed to `created`. Match by content
/// (line_spec=null + identical diff_lines) first, otherwise by new-side line
/// overlap. Marks `applied_used[i]=true` for each match so a single applied
/// hunk maps to at most one created hunk.
fn collectAppliedFor(
    arena: Allocator,
    matched: []const MatchedHunk,
    applied_used: []bool,
    created: *const Hunk,
) ![]AppliedInput {
    var app_buf: std.ArrayList(AppliedInput) = .empty;
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
            try app_buf.append(arena, .{ .sha7 = m.hunk.sha_hex[0..7], .line_spec = m.line_spec });
            applied_used[i] = true;
        }
    }
    return app_buf.items;
}

/// Find consumed hunks whose old-side range overlaps `created`'s old-side
/// range and same file. Marks `consumed_used[i]=true` per match.
fn collectConsumedFor(
    arena: Allocator,
    consumed: []const *const Hunk,
    consumed_used: []bool,
    created: *const Hunk,
) ![][]const u8 {
    var con_buf: std.ArrayList([]const u8) = .empty;
    for (consumed, 0..) |con, i| {
        if (consumed_used[i]) continue;
        if (!std.mem.eql(u8, con.file_path, created.file_path)) continue;
        if (rangesOverlap(con.old_start, con.old_count, created.old_start, created.old_count)) {
            try con_buf.append(arena, con.sha_hex[0..7]);
            consumed_used[i] = true;
        }
    }
    return con_buf.items;
}

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
        const applied = try collectAppliedFor(arena, matched, applied_used, c);
        const con_paths = try collectConsumedFor(arena, consumed, consumed_used, c);
        const result_sha = try arena.alloc([]const u8, 1);
        result_sha[0] = c.sha_hex[0..7];
        try groups.append(arena, .{
            .result_shas = result_sha,
            .applied = applied,
            .consumed = con_paths,
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
/// Print "no [un]staged changes\n" and exit(1). Centralises the message so it
/// can't drift across commands.
fn exitNoChanges(mode: DiffMode) noreturn {
    const msg = switch (mode) {
        .unstaged => "no unstaged changes\n",
        .staged => "no staged changes\n",
    };
    std.debug.print("{s}", .{msg});
    std.process.exit(1);
}

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
/// Returns true if any of the patches landed with `--3way` conflicts.
fn applyTextAndBinary(
    allocator: Allocator,
    arena: Allocator,
    action: ApplyAction,
    text_matched: []MatchedHunk,
    binary_paths: []const []const u8,
    ref: ?[]const u8,
    three_way: bool,
) !bool {
    var any_conflicts = false;
    if (text_matched.len > 0) {
        std.mem.sort(MatchedHunk, text_matched, {}, patch_mod.matchedHunkPatchOrder);
        const patches = try patch_mod.buildCombinedPatches(arena, text_matched);
        const reverse = action == .unstage;
        const apply_opts = git.ApplyOptions{ .reverse = reverse, .target = .index, .three_way = three_way, .ref = ref };
        if (reverse) {
            var i: usize = patches.len;
            while (i > 0) {
                i -= 1;
                if (try git.runGitApply(allocator, patches[i], apply_opts) == .applied_with_conflicts) any_conflicts = true;
            }
        } else {
            for (patches) |patch| {
                if (try git.runGitApply(allocator, patch, apply_opts) == .applied_with_conflicts) any_conflicts = true;
            }
        }
    }
    if (binary_paths.len > 0) {
        switch (action) {
            .stage => try git.runGitAddFiles(allocator, binary_paths),
            .unstage => try git.runGitResetFiles(allocator, binary_paths),
        }
    }
    return any_conflicts;
}

/// Print result groups for text hunks (with merge tracking) and per-hunk lines
/// for binary hunks (no merge tracking). Returns the totals for the summary.
fn renderApplyResults(
    stdout: *std.Io.Writer,
    opts: AddResetOptions,
    action: ApplyAction,
    result_groups: []const ResultGroup,
    binary_matched: []const MatchedHunk,
) !void {
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

    if (hunks.items.len == 0) exitNoChanges(diff_mode);

    var matched: std.ArrayList(MatchedHunk) = .empty;
    defer matched.deinit(arena);
    try resolveHunksFromOpts(arena, hunks.items, opts.sha_args.items, opts.file_filter, &matched);

    const partition = try patch_mod.partitionByKind(arena, matched.items);
    const text_matched = try partition.combinedText(arena);
    const binary_paths = try partition.allBinaryPaths(arena);
    const binary_matched = try partition.combinedBinary(arena);

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

    const had_conflicts = try applyTextAndBinary(allocator, arena, action, text_matched, binary_paths, opts.ref, opts.three_way);

    var new_hunks: std.ArrayList(Hunk) = .empty;
    defer new_hunks.deinit(arena);
    if (text_matched.len > 0) try captureTargetHunks(arena, target_mode, opts.context, file_paths, &new_hunks);

    const result_groups = try buildResultGroups(arena, text_matched, old_target_hunks.items, new_hunks.items);
    try renderApplyResults(stdout, opts, action, result_groups, binary_matched);

    if (had_conflicts) {
        // Mirror `git apply --3way --cached` semantics: leave unmerged index entries
        // and exit non-zero so scripts (and the user) know to resolve before committing.
        std.debug.print("error: --3way landed unmerged index entries — use `git status` to inspect, then `git add` once resolved\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }
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

    if (hunks.items.len == 0) exitNoChanges(.unstaged);

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
    const text_matched = try partition.combinedText(arena);

    // Text hunks: reverse-apply patches to worktree
    var any_restore_conflicts = false;
    if (text_matched.len > 0) {
        std.mem.sort(MatchedHunk, text_matched, {}, patch_mod.matchedHunkPatchOrder);
        const patches = try patch_mod.buildCombinedPatches(arena, text_matched);
        var i: usize = patches.len;
        while (i > 0) {
            i -= 1;
            // git apply rejects --3way + --check; for dry-run we drop --3way.
            const result = try git.runGitApply(allocator, patches[i], .{
                .reverse = true,
                .target = .worktree,
                .check_only = opts.dry_run,
                .three_way = opts.three_way and !opts.dry_run,
                .ref = opts.ref,
            });
            if (result == .applied_with_conflicts) any_restore_conflicts = true;
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
    const summary_verb: []const u8 = if (opts.dry_run) "would be restored" else "restored";

    const count = try format.printMatchedHunks(stdout, matched.items, verb, porcelain_verb, use_color, opts.output, opts.verbosity);
    format.printHunkCountSummary(opts.verbosity, opts.output, count, summary_verb);

    if (any_restore_conflicts) {
        std.debug.print("error: --3way left conflict markers in the worktree — resolve before continuing\n", .{});
        try stdout.flush();
        std.process.exit(1);
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

    if (hunks.items.len == 0) exitNoChanges(opts.mode);

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

    if (hunks.items.len == 0) exitNoChanges(.unstaged);

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
/// transactional commit hits a fatal mid-transaction error. If `msg` is given,
/// it's printed to stderr before exit.
fn abortCommitAndExit(cwd: std.Io.Dir, io: std.Io, backup_path: []const u8, index_path: []const u8, msg: ?[]const u8) noreturn {
    std.Io.Dir.copyFile(cwd, backup_path, cwd, index_path, io, .{}) catch {};
    cwd.deleteFile(io, backup_path) catch {};
    if (msg) |m| std.debug.print("{s}", .{m});
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
    three_way: bool,
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
    git.runGitReadTree(ctx.allocator, read_tree_ref) catch abortCommitAndExit(ctx.cwd, ctx.io, ctx.backup_path, ctx.index_path, null);

    // 3. Stage target hunks (text via patch, binary via git add).
    // If --3way produces unmerged index entries, the subsequent `git commit`
    // would refuse and we'd roll back, leaving the user with no way to resolve.
    // Detect and abort early with a clear instruction.
    for (ctx.patches) |p| {
        const result = git.runGitApply(ctx.allocator, p, .{ .target = .index, .three_way = ctx.three_way, .ref = ctx.ref }) catch
            abortCommitAndExit(ctx.cwd, ctx.io, ctx.backup_path, ctx.index_path, null);
        if (result == .applied_with_conflicts) {
            abortCommitAndExit(ctx.cwd, ctx.io, ctx.backup_path, ctx.index_path,
                "error: --3way produced conflicts; cannot commit. Use `git hunk restore --ref <X> --3way <sha>` then resolve and `git commit` normally.\n");
        }
    }
    if (ctx.binary_paths.len > 0) {
        git.runGitAddFiles(ctx.allocator, ctx.binary_paths) catch abortCommitAndExit(ctx.cwd, ctx.io, ctx.backup_path, ctx.index_path, null);
    }

    // 4. Commit
    const commit_output = git.runGitCommit(ctx.allocator, .{ .message = ctx.message, .amend = ctx.amend }) catch
        abortCommitAndExit(ctx.cwd, ctx.io, ctx.backup_path, ctx.index_path, null);
    errdefer ctx.allocator.free(commit_output);

    // 5. Restore original index
    std.Io.Dir.copyFile(ctx.cwd, ctx.backup_path, ctx.cwd, ctx.index_path, ctx.io, .{}) catch {
        std.debug.print("warning: commit succeeded but failed to restore original index -- backup at {s}\n", .{ctx.backup_path});
    };

    // 6. Sync index with new HEAD (text via patch, binary via git add).
    // Don't pass --3way here: the patch already landed in step 3, and re-applying
    // with 3-way against the post-commit index would risk producing conflict
    // markers in the real index.
    for (ctx.patches) |p| {
        _ = git.runGitApply(ctx.allocator, p, .{ .target = .index, .ref = ctx.ref }) catch {
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
    const count = try format.printMatchedHunks(stdout, matched, "committed", "committed", use_color, opts.output, opts.verbosity);
    if (opts.verbosity != .quiet and commit_output.len > 0) {
        std.debug.print("{s}\n", .{commit_output});
    }
    format.printHunkCountSummary(opts.verbosity, opts.output, count, "committed");
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

    if (hunks.items.len == 0) exitNoChanges(.unstaged);

    var matched: std.ArrayList(MatchedHunk) = .empty;
    defer matched.deinit(arena);

    try resolveHunksFromOpts(arena, hunks.items, opts.sha_args.items, opts.file_filter, &matched);
    exitIfNoMatches(matched.items.len, opts.file_filter);

    const partition = try patch_mod.partitionByKind(arena, matched.items);
    const text_matched = try partition.combinedText(arena);
    const binary_paths = try partition.allBinaryPaths(arena);

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
            // git apply rejects --3way + --check; we pass plain --check for dry-run.
            _ = try git.runGitApply(allocator, p, .{ .target = .index, .check_only = true, .ref = opts.ref });
        }
        const use_color = format.shouldUseColor(opts.output, opts.no_color);
        _ = try format.printMatchedHunks(stdout, matched.items, "would commit", "would-commit", use_color, opts.output, opts.verbosity);
        return;
    }

    const commit_output = try runTransactionalCommit(.{
        .allocator = allocator,
        .patches = patches,
        .binary_paths = binary_paths,
        .message = message,
        .amend = opts.amend,
        .three_way = opts.three_way,
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

test "findConsumed returns hunks whose sha is absent from new_target" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h_old1 = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    h_old1.sha_hex = comptime [_]u8{'a'} ** 40;
    var h_old2 = types.testMakeHunk("a.txt", 5, 1, 5, 1);
    h_old2.sha_hex = comptime [_]u8{'b'} ** 40;
    var h_new = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    h_new.sha_hex = comptime [_]u8{'a'} ** 40; // h_old1 survives, h_old2 consumed

    const consumed = try findConsumed(arena, &.{ h_old1, h_old2 }, &.{h_new});
    try std.testing.expectEqual(@as(usize, 1), consumed.len);
    try std.testing.expectEqualSlices(u8, &h_old2.sha_hex, &consumed[0].sha_hex);
}

test "findConsumed returns empty when all hunks survive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    h.sha_hex = comptime [_]u8{'a'} ** 40;
    const consumed = try findConsumed(arena, &.{h}, &.{h});
    try std.testing.expectEqual(@as(usize, 0), consumed.len);
}

test "findCreated returns hunks whose sha is absent from old_target" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h_old = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    h_old.sha_hex = comptime [_]u8{'a'} ** 40;
    var h_new1 = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    h_new1.sha_hex = comptime [_]u8{'a'} ** 40; // already existed
    var h_new2 = types.testMakeHunk("a.txt", 5, 1, 5, 1);
    h_new2.sha_hex = comptime [_]u8{'c'} ** 40; // genuinely new

    const created = try findCreated(arena, &.{h_old}, &.{ h_new1, h_new2 });
    try std.testing.expectEqual(@as(usize, 1), created.len);
    try std.testing.expectEqualSlices(u8, &h_new2.sha_hex, &created[0].sha_hex);
}

test "runChecks: ok status for matching SHA" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h.sha_hex[0..7], "1234567");
    @memset(h.sha_hex[7..], '0');

    const sha_args = [_]types.ShaArg{.{ .prefix = "1234567", .line_spec = null }};
    const summary = try runChecks(arena, &.{h}, &sha_args, &.{}, false);
    try std.testing.expectEqual(@as(usize, 1), summary.results.len);
    try std.testing.expectEqual(CheckStatus.ok, summary.results[0].status);
    try std.testing.expect(!summary.has_failure);
}

test "runChecks: stale status for missing SHA" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sha_args = [_]types.ShaArg{.{ .prefix = "deadbeef", .line_spec = null }};
    const summary = try runChecks(arena, &.{}, &sha_args, &.{}, false);
    try std.testing.expectEqual(@as(usize, 1), summary.results.len);
    try std.testing.expectEqual(CheckStatus.stale, summary.results[0].status);
    try std.testing.expect(summary.has_failure);
}

test "runChecks: ambiguous status for prefix matching multiple hunks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h1 = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h1.sha_hex[0..7], "1234567");
    @memset(h1.sha_hex[7..], '0');
    var h2 = types.testMakeHunk("b.txt", 1, 1, 1, 1);
    @memcpy(h2.sha_hex[0..7], "1234567"); // same prefix
    @memset(h2.sha_hex[7..], '1');

    const sha_args = [_]types.ShaArg{.{ .prefix = "1234567", .line_spec = null }};
    const summary = try runChecks(arena, &.{ h1, h2 }, &sha_args, &.{}, false);
    try std.testing.expectEqual(CheckStatus.ambiguous, summary.results[0].status);
    try std.testing.expect(summary.has_failure);
}

test "runChecks: deduplicates repeated prefixes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h.sha_hex[0..7], "1234567");
    @memset(h.sha_hex[7..], '0');

    const sha_args = [_]types.ShaArg{
        .{ .prefix = "1234567", .line_spec = null },
        .{ .prefix = "1234567", .line_spec = null },
    };
    const summary = try runChecks(arena, &.{h}, &sha_args, &.{}, false);
    try std.testing.expectEqual(@as(usize, 1), summary.results.len);
}

test "runChecks: --exclusive populates unexpected for unmatched hunks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h1 = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h1.sha_hex[0..7], "1234567");
    @memset(h1.sha_hex[7..], '0');
    var h2 = types.testMakeHunk("a.txt", 5, 1, 5, 1);
    @memcpy(h2.sha_hex[0..7], "abcdefg");
    @memset(h2.sha_hex[7..], '0');

    const sha_args = [_]types.ShaArg{.{ .prefix = "1234567", .line_spec = null }};
    const summary = try runChecks(arena, &.{ h1, h2 }, &sha_args, &.{}, true);
    try std.testing.expectEqual(@as(usize, 1), summary.unexpected.len);
    try std.testing.expectEqualSlices(u8, &h2.sha_hex, &summary.unexpected[0].sha_hex);
    try std.testing.expect(summary.has_failure);
}

test "runChecks: file_filter scopes both prefix lookup and unexpected scan" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h_a = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h_a.sha_hex[0..7], "1234567");
    @memset(h_a.sha_hex[7..], '0');
    var h_b = types.testMakeHunk("b.txt", 1, 1, 1, 1);
    @memcpy(h_b.sha_hex[0..7], "abcdefg");
    @memset(h_b.sha_hex[7..], '0');

    const filter = [_][]const u8{"a.txt"};
    const summary = try runChecks(arena, &.{ h_a, h_b }, &.{}, &filter, true);
    try std.testing.expectEqual(@as(usize, 1), summary.unexpected.len);
    try std.testing.expectEqualStrings("a.txt", summary.unexpected[0].file_path);
}

test "collectAppliedFor: content match takes precedence over line match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    m_hunk.diff_lines = "+identical";
    const matched = [_]MatchedHunk{.{ .hunk = &m_hunk, .line_spec = null }};

    var c_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    c_hunk.diff_lines = "+identical";

    var applied_used = [_]bool{false};
    const applied = try collectAppliedFor(arena, &matched, &applied_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 1), applied.len);
    try std.testing.expect(applied_used[0]);
}

test "collectAppliedFor: line overlap matches when content differs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m_hunk = types.testMakeHunk("a.txt", 5, 3, 5, 3);
    m_hunk.diff_lines = "+different";
    const matched = [_]MatchedHunk{.{ .hunk = &m_hunk, .line_spec = null }};

    var c_hunk = types.testMakeHunk("a.txt", 5, 3, 6, 3);
    c_hunk.diff_lines = "+merged";

    var applied_used = [_]bool{false};
    const applied = try collectAppliedFor(arena, &matched, &applied_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 1), applied.len);
    try std.testing.expect(applied_used[0]);
}

test "collectAppliedFor: applied_used flag prevents double-attribution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    const matched = [_]MatchedHunk{.{ .hunk = &m_hunk, .line_spec = null }};

    var c_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);

    var applied_used = [_]bool{true}; // already attributed
    const applied = try collectAppliedFor(arena, &matched, &applied_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 0), applied.len);
}

test "collectAppliedFor: different file path skips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    const matched = [_]MatchedHunk{.{ .hunk = &m_hunk, .line_spec = null }};

    var c_hunk = types.testMakeHunk("b.txt", 1, 1, 1, 1);

    var applied_used = [_]bool{false};
    const applied = try collectAppliedFor(arena, &matched, &applied_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 0), applied.len);
    try std.testing.expect(!applied_used[0]);
}

test "collectConsumedFor: range overlap on same file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var con_hunk = types.testMakeHunk("a.txt", 5, 3, 5, 3);
    @memcpy(con_hunk.sha_hex[0..7], "deadbef");
    @memset(con_hunk.sha_hex[7..], '0');
    const consumed = [_]*const Hunk{&con_hunk};

    var c_hunk = types.testMakeHunk("a.txt", 5, 3, 5, 3);

    var consumed_used = [_]bool{false};
    const con_paths = try collectConsumedFor(arena, &consumed, &consumed_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 1), con_paths.len);
    try std.testing.expectEqualStrings("deadbef", con_paths[0]);
    try std.testing.expect(consumed_used[0]);
}

test "collectConsumedFor: no overlap returns empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var con_hunk = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    const consumed = [_]*const Hunk{&con_hunk};

    var c_hunk = types.testMakeHunk("a.txt", 100, 1, 100, 1);

    var consumed_used = [_]bool{false};
    const con_paths = try collectConsumedFor(arena, &consumed, &consumed_used, &c_hunk);
    try std.testing.expectEqual(@as(usize, 0), con_paths.len);
}

test "appendOrphanedApplied: unmatched applied hunks become standalone groups" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h1 = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    @memcpy(h1.sha_hex[0..7], "abcdef0");
    @memset(h1.sha_hex[7..], '0');
    var h2 = types.testMakeHunk("b.txt", 1, 1, 1, 1);
    @memcpy(h2.sha_hex[0..7], "1234567");
    @memset(h2.sha_hex[7..], '0');
    const matched = [_]MatchedHunk{
        .{ .hunk = &h1, .line_spec = null },
        .{ .hunk = &h2, .line_spec = null },
    };

    var groups: std.ArrayList(ResultGroup) = .empty;
    const applied_used = [_]bool{ false, true }; // h1 unmatched, h2 already used
    try appendOrphanedApplied(arena, &groups, &matched, &applied_used);

    try std.testing.expectEqual(@as(usize, 1), groups.items.len);
    try std.testing.expectEqualStrings("a.txt", groups.items[0].file_path);
    try std.testing.expectEqual(@as(usize, 0), groups.items[0].result_shas.len);
    try std.testing.expectEqual(@as(usize, 1), groups.items[0].applied.len);
}

test "mergeOrphansIntoSiblings: orphan with sibling for same file gets merged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sibling_apps = try arena.alloc(AppliedInput, 1);
    sibling_apps[0] = .{ .sha7 = "abcdef0", .line_spec = null };
    const sibling_shas = try arena.alloc([]const u8, 1);
    sibling_shas[0] = "result1";

    const orphan_shas = try arena.alloc([]const u8, 1);
    orphan_shas[0] = "result2";

    var groups = [_]ResultGroup{
        .{ .result_shas = sibling_shas, .applied = sibling_apps, .consumed = &.{}, .file_path = "a.txt", .is_symlink = false },
        .{ .result_shas = orphan_shas, .applied = &.{}, .consumed = &.{}, .file_path = "a.txt", .is_symlink = false },
    };

    const final = try mergeOrphansIntoSiblings(arena, &groups);
    try std.testing.expectEqual(@as(usize, 1), final.len);
    try std.testing.expectEqual(@as(usize, 2), final[0].result_shas.len);
}

test "mergeOrphansIntoSiblings: orphan without sibling kept as-is (fallback path)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const orphan_shas = try arena.alloc([]const u8, 1);
    orphan_shas[0] = "stranger";

    var groups = [_]ResultGroup{
        .{ .result_shas = orphan_shas, .applied = &.{}, .consumed = &.{}, .file_path = "lonely.txt", .is_symlink = false },
    };

    const final = try mergeOrphansIntoSiblings(arena, &groups);
    try std.testing.expectEqual(@as(usize, 1), final.len);
    try std.testing.expectEqualStrings("lonely.txt", final[0].file_path);
}

test "printResultGroupHuman: simple 1->1 case (no consumed, no line_spec)" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupHuman(&w, "staged", rg, false);
    try std.testing.expectEqualStrings("staged abcdef0 \xe2\x86\x92 1234567  foo.txt\n", w.buffered());
}

test "printResultGroupHuman: with consumed shows + prefix and `?` when no result" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const consumed = [_][]const u8{"deadbef"};
    const rg = ResultGroup{
        .result_shas = &.{},
        .applied = &applied,
        .consumed = &consumed,
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupHuman(&w, "staged", rg, false);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "+deadbef") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "?") != null);
}

test "printResultGroupHuman: symlink suffix" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "link",
        .is_symlink = true,
    };
    try printResultGroupHuman(&w, "staged", rg, false);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "link@\n"));
}

test "printResultGroupHuman: line_spec on applied input" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ranges = [_]types.LineRange{.{ .start = 3, .end = 5 }};
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = .{ .ranges = &ranges } }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupHuman(&w, "staged", rg, false);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "abcdef0:3-5") != null);
}

test "printResultGroupHuman: multi-applied + multi-result joined correctly" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{
        .{ .sha7 = "aaaa000", .line_spec = null },
        .{ .sha7 = "bbbb000", .line_spec = null },
    };
    const result_shas = [_][]const u8{ "rrrr000", "ssss000" };
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupHuman(&w, "staged", rg, false);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "aaaa000 bbbb000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rrrr000,ssss000") != null);
}

test "printResultGroupPorcelain: tab-separated layout" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupPorcelain(&w, "staged", rg);
    try std.testing.expectEqualStrings("staged\tabcdef0\t1234567\tfoo.txt\n", w.buffered());
}

test "printResultGroupPorcelain: omits consumed field when empty" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupPorcelain(&w, "staged", rg);
    // Only 4 fields when consumed is empty: verb, applied, result, file.
    var tab_count: usize = 0;
    for (w.buffered()) |c| if (c == '\t') {
        tab_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), tab_count);
}

test "printResultGroupPorcelain: appends consumed field when present" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const consumed = [_][]const u8{ "deadbef", "feedabc" };
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &consumed,
        .file_path = "foo.txt",
        .is_symlink = false,
    };
    try printResultGroupPorcelain(&w, "staged", rg);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\tdeadbef,feedabc\n"));
}

test "printResultGroupPorcelain: symlink @ suffix on file path" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const applied = [_]AppliedInput{.{ .sha7 = "abcdef0", .line_spec = null }};
    const result_shas = [_][]const u8{"1234567"};
    const rg = ResultGroup{
        .result_shas = &result_shas,
        .applied = &applied,
        .consumed = &.{},
        .file_path = "link",
        .is_symlink = true,
    };
    try printResultGroupPorcelain(&w, "staged", rg);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\tlink@\n"));
}
