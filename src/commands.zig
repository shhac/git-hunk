const std = @import("std");
const types = @import("types.zig");
const diff_mod = @import("diff.zig");
const git = @import("git.zig");
const patch_mod = @import("patch.zig");
const format = @import("format.zig");

const stash_mod = @import("stash.zig");
const result_groups_mod = @import("result_groups.zig");
const commit_mod = @import("commit.zig");

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
const defaultIo = types.getIo;
const ResultGroup = result_groups_mod.ResultGroup;
const buildResultGroups = result_groups_mod.buildResultGroups;
const printResultGroupHuman = result_groups_mod.printResultGroupHuman;
const printResultGroupPorcelain = result_groups_mod.printResultGroupPorcelain;
const legacyRecoverIndexBackup = commit_mod.legacyRecoverIndexBackup;
const runTempIndexCommit = commit_mod.runTempIndexCommit;
const printCommitResults = commit_mod.printCommitResults;

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

/// Print a note naming changed paths that produced no hunk, so a tree git
/// considers dirty is never reported as having nothing to stage. Verbose only:
/// these paths have no hash, so there is nothing an ordinary listing could say
/// about them, and `git add <path>` is the answer for all of them.
fn reportSkippedPaths(arena: Allocator, tracked_diff: []const u8, hunks: []const Hunk, file_filter: []const []const u8) !void {
    if (tracked_diff.len == 0) return;

    var skipped: std.ArrayList(diff_mod.SkippedPath) = .empty;
    try diff_mod.collectSkippedPaths(arena, tracked_diff, hunks, &skipped);

    for (skipped.items) |sk| {
        if (!types.matchesFileFilter(sk.file_path, file_filter)) continue;
        std.debug.print(
            "note: {s}: {s} has no hunk — use 'git add {s}'\n",
            .{ sk.file_path, sk.reason.describe(), sk.file_path },
        );
    }
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

    if (opts.verbosity == .verbose) {
        try reportSkippedPaths(arena, diffs.tracked, hunks.items, opts.file_filter);
    }

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

    if (opts.verbosity == .verbose) {
        try reportSkippedPaths(arena, diffs.tracked, hunks.items, opts.file_filter);
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
                // A --file filter scopes hash lookup as well as bulk selection,
                // so a live hash in an unlisted file reports as "no hunk
                // matching" — which reads as a stale hash and sends people
                // hunting for the wrong problem. Re-resolve without the filter
                // to say which it actually was.
                if (file_filter.len > 0) {
                    if (patch_mod.findHunkByShaPrefix(hunks, sha_arg.prefix, &.{})) |outside| {
                        std.debug.print(
                            "error: no hunk matching '{s}' in the --file selection (it is in '{s}')\n" ++
                                "hint: --file also scopes which hunks a hash can match; stage the files and the hashes in two commands\n",
                            .{ sha_arg.prefix, outside.file_path },
                        );
                        std.process.exit(1);
                    } else |_| {}
                }
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
        const reverse = action == .unstage;
        const patches = try patch_mod.sortAndBuildPatches(arena, text_matched, if (reverse) .reverse else .forward);
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
    had_conflicts: bool,
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

    // Suppress the success summary and the "hashes differ" hint when --3way
    // landed unmerged entries: the caller will print an error + exit non-zero.
    // Mixing "N hunks staged" with that error would be self-contradictory.
    if (had_conflicts) return;

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

/// Validate what `add`/`reset` would do and report it, leaving the index and
/// worktree untouched. `git apply --check` rejects `--3way`, so 3-way fallback
/// is not simulated — a dry run that would only succeed via 3-way still reports
/// failure here, same as `restore --dry-run` and `commit --dry-run`.
fn dryRunApplyHunks(
    allocator: Allocator,
    arena: Allocator,
    stdout: *std.Io.Writer,
    opts: AddResetOptions,
    action: ApplyAction,
    text_matched: []MatchedHunk,
    matched: []const MatchedHunk,
) !void {
    const reverse = action == .unstage;
    if (text_matched.len > 0) {
        const patches = try patch_mod.sortAndBuildPatches(arena, text_matched, if (reverse) .reverse else .forward);
        var i: usize = patches.len;
        while (i > 0) {
            i -= 1;
            _ = try git.runGitApply(allocator, patches[i], .{
                .reverse = reverse,
                .target = .index,
                .check_only = true,
                .ref = opts.ref,
            });
        }
    }

    const verbs: struct { human: []const u8, porcelain: []const u8 } = switch (action) {
        .stage => .{ .human = "would stage", .porcelain = "would-stage" },
        .unstage => .{ .human = "would unstage", .porcelain = "would-unstage" },
    };
    const use_color = format.shouldUseColor(opts.output, opts.no_color);
    _ = try format.printMatchedHunks(stdout, matched, verbs.human, verbs.porcelain, use_color, opts.output, opts.verbosity);
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

    // Dry-run: validate the patch against the target without writing to it.
    // Reports the INPUT hunks, not result hashes: a result hash only exists
    // once the patch has been applied and the target re-diffed, which is
    // exactly what a dry run must not do. Matches restore --dry-run.
    if (opts.dry_run) {
        try dryRunApplyHunks(allocator, arena, stdout, opts, action, text_matched, matched.items);
        return;
    }

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
    try renderApplyResults(stdout, opts, action, result_groups, binary_matched, had_conflicts);

    if (had_conflicts) {
        // Mirror `git apply --3way --cached` semantics: leave unmerged index entries
        // and exit non-zero so scripts (and the user) know to resolve before committing.
        // Flush buffered stdout (per-hunk lines) before writing to stderr so the
        // user sees them in source order on a TTY.
        try stdout.flush();
        const resolution_hint: []const u8 = switch (action) {
            .stage => "use `git status` to inspect, then `git add` once resolved",
            .unstage => "use `git status` to inspect, then resolve with `git checkout --` or re-stage the resolved version",
        };
        std.debug.print("error: --3way landed unmerged index entries — {s}\n", .{resolution_hint});
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
        const patches = try patch_mod.sortAndBuildPatches(arena, text_matched, .reverse);
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
    // Skip the "N hunks restored" summary when --3way left conflict markers:
    // the caller will exit non-zero with a clear error, and "N hunks restored"
    // would contradict that. The per-hunk lines above still show what was touched.
    if (!any_restore_conflicts) {
        format.printHunkCountSummary(opts.verbosity, opts.output, count, summary_verb);
    }

    if (any_restore_conflicts) {
        // Flush buffered stdout first so per-hunk lines appear before the stderr error.
        try stdout.flush();
        std.debug.print("error: --3way left conflict markers in the worktree — resolve before continuing\n", .{});
        std.process.exit(1);
    }
}

/// A selects-nothing LineSpec when `on`, else null. Lets `-n` reuse the
/// line-spec renderer so the two can never number lines differently.
fn emptyLineSpecIf(on: bool) ?types.LineSpec {
    return if (on) .{ .ranges = &.{} } else null;
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
                    } else if (m.line_spec orelse emptyLineSpecIf(opts.number)) |ls| {
                        // -n and a line spec share this renderer; an empty spec
                        // selects nothing, so -n alone numbers without markers.
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
        const new_tree = try stash_mod.addBinaryFilesToTree(allocator, tree, partition.tracked_binary_paths, env_map);
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

pub fn cmdCommit(allocator: Allocator, stdout: *std.Io.Writer, opts: CommitOptions, env_map: *const std.process.Environ.Map) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Don't run recovery during --dry-run: recovery rewrites the user's index
    // from a backup, which is a real mutation. A user expecting a read-only
    // preview would be surprised to find their index changed.
    if (!opts.dry_run) try legacyRecoverIndexBackup(allocator);

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

    const patches = try patch_mod.sortAndBuildPatches(arena, text_matched, .forward);
    if (patches.len == 0 and binary_paths.len == 0) {
        std.debug.print("error: no hunks to commit\n", .{});
        std.process.exit(1);
    }

    // Dry-run: validate patches against the index (without modifying it) and show what would be committed.
    // Checked before the message requirement — a preview has nothing to write a message onto.
    if (opts.dry_run) {
        for (patches) |p| {
            // git apply rejects --3way + --check; we pass plain --check for dry-run.
            _ = try git.runGitApply(allocator, p, .{ .target = .index, .check_only = true, .ref = opts.ref });
        }
        const use_color = format.shouldUseColor(opts.output, opts.no_color);
        _ = try format.printMatchedHunks(stdout, matched.items, "would commit", "would-commit", use_color, opts.output, opts.verbosity);
        return;
    }

    const message = opts.message orelse {
        std.debug.print("error: -m <message> is required\n", .{});
        std.process.exit(1);
    };

    const commit_output = runTempIndexCommit(.{
        .allocator = allocator,
        .patches = patches,
        .binary_paths = binary_paths,
        .message = message,
        .amend = opts.amend,
        .three_way = opts.three_way,
        .ref = opts.ref,
        .env_map = env_map,
    }) catch |err| switch (err) {
        // git's own stderr has already been shown; exit without extra noise.
        error.ReadTreeFailed, error.CommitFailed, error.AddFailed => std.process.exit(1),
        else => return err,
    };
    defer allocator.free(commit_output);

    try printCommitResults(stdout, opts, matched.items, commit_output);
}

// ============================================================================
// Tests
// ============================================================================

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
