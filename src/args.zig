const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const LineRange = types.LineRange;
const LineSpec = types.LineSpec;
const ShaArg = types.ShaArg;
const DiffMode = types.DiffMode;
const DiffFilter = types.DiffFilter;
const OutputMode = types.OutputMode;
const ListOptions = types.ListOptions;
const AddResetOptions = types.AddResetOptions;
const DiffOptions = types.DiffOptions;
const CountOptions = types.CountOptions;
const CheckOptions = types.CheckOptions;
const RestoreOptions = types.RestoreOptions;
const StashOptions = types.StashOptions;
const CommitOptions = types.CommitOptions;

const CommonFlags = struct {
    file_filter: std.ArrayList([]const u8) = .empty,
    ref: ?[]const u8 = null,
    diff_filter: DiffFilter = .all,
    no_color: bool = false,
    output: OutputMode = .human,
    context: ?u32 = null,
    verbosity: types.Verbosity = .normal,
    three_way: bool = false,
};

/// Copy common flags into an options struct, using comptime field detection
/// to handle structs that don't have all fields (e.g. CountOptions lacks no_color/output).
/// Transfers ownership of `common.file_filter` into `opts.file_filter` as an owned slice.
/// After this call, `common.file_filter` is empty regardless of success or error
/// (the only failure path is `toOwnedSlice` OOM; the list is freed before returning
/// the error). This makes the parser-side errdefer for `common` a no-op after the
/// call — only `opts.file_filter` needs further cleanup.
fn applyCommonFlags(allocator: Allocator, common: *CommonFlags, opts: anytype) !void {
    // --3way is only meaningful for commands that pass patches through
    // `git apply` (add, reset, restore, commit). Reject it on commands like
    // list/diff/count/check/stash that don't apply patches — silently
    // swallowing it would mislead users into thinking it had an effect.
    if (common.three_way and !comptime @hasField(@TypeOf(opts.*), "three_way")) {
        std.debug.print("error: --3way is not supported for this subcommand (only add, reset, restore, commit)\n", .{});
        return error.UnknownFlag;
    }
    const fields = .{ "ref", "diff_filter", "no_color", "output", "context", "verbosity", "three_way" };
    inline for (fields) |name| {
        if (comptime @hasField(@TypeOf(opts.*), name)) {
            @field(opts, name) = @field(common, name);
        }
    }
    if (comptime @hasField(@TypeOf(opts.*), "file_filter")) {
        opts.file_filter = common.file_filter.toOwnedSlice(allocator) catch |err| {
            common.file_filter.deinit(allocator);
            common.file_filter = .empty;
            return err;
        };
    } else {
        common.file_filter.deinit(allocator);
        common.file_filter = .empty;
    }
}

/// Free a file_filter slice if it was actually allocated (len > 0).
pub fn deinitFileFilter(allocator: Allocator, file_filter: []const []const u8) void {
    if (file_filter.len > 0) allocator.free(file_filter);
}

/// Try to parse arg as a common flag shared across all parsers.
/// Returns true if the arg was consumed (for value-taking flags like --file,
/// also increments i.* so the loop's `: (i += 1)` advances past the value).
/// Returns false if arg is not a common flag (caller handles it).
/// Returns error on parse failure or HelpRequested.
fn parseCommonFlag(allocator: Allocator, arg: []const u8, i: *usize, args: []const [:0]const u8, c: *CommonFlags) !bool {
    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
        return error.HelpRequested;
    } else if (std.mem.eql(u8, arg, "--file")) {
        i.* += 1;
        if (i.* >= args.len) return error.MissingArgument;
        try c.file_filter.append(allocator, args[i.*]);
        return true;
    } else if (std.mem.eql(u8, arg, "--ref")) {
        i.* += 1;
        if (i.* >= args.len) return error.MissingArgument;
        c.ref = args[i.*];
        return true;
    } else if (std.mem.eql(u8, arg, "--tracked-only")) {
        if (c.diff_filter == .untracked_only) return error.ConflictingFilter;
        c.diff_filter = .tracked_only;
        return true;
    } else if (std.mem.eql(u8, arg, "--untracked-only")) {
        if (c.diff_filter == .tracked_only) return error.ConflictingFilter;
        c.diff_filter = .untracked_only;
        return true;
    } else if (std.mem.eql(u8, arg, "--no-color")) {
        c.no_color = true;
        return true;
    } else if (std.mem.eql(u8, arg, "--porcelain")) {
        c.output = .porcelain;
        return true;
    } else if (std.mem.startsWith(u8, arg, "--unified=")) {
        const val = arg["--unified=".len..];
        c.context = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
        return true;
    } else if (std.mem.eql(u8, arg, "--unified")) {
        i.* += 1;
        if (i.* >= args.len) return error.MissingArgument;
        c.context = std.fmt.parseInt(u32, args[i.*], 10) catch return error.InvalidArgument;
        return true;
    } else if (std.mem.startsWith(u8, arg, "-U") and arg.len > 2) {
        const val = arg[2..];
        c.context = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
        return true;
    } else if (std.mem.eql(u8, arg, "-U")) {
        i.* += 1;
        if (i.* >= args.len) return error.MissingArgument;
        c.context = std.fmt.parseInt(u32, args[i.*], 10) catch return error.InvalidArgument;
        return true;
    } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
        if (c.verbosity == .verbose) return error.ConflictingVerbosity;
        c.verbosity = .quiet;
        return true;
    } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
        if (c.verbosity == .quiet) return error.ConflictingVerbosity;
        c.verbosity = .verbose;
        return true;
    } else if (std.mem.eql(u8, arg, "--3way")) {
        c.three_way = true;
        return true;
    }
    return false;
}

/// Print a "unknown flag" error and return error.UnknownFlag. Used by every parser.
fn unknownFlag(arg: []const u8) error{UnknownFlag} {
    std.debug.print("error: unknown flag '{s}'\n", .{arg});
    return error.UnknownFlag;
}

/// `--staged` is incompatible with a range ref (`A..B`). Returns InvalidArgument
/// (after printing) when both are present.
fn validateRefStagedCombo(ref: ?[]const u8, mode: DiffMode) error{InvalidArgument}!void {
    if (ref) |r| {
        if (std.mem.indexOf(u8, r, "..") != null and mode == .staged) {
            std.debug.print("error: --staged cannot be used with a range ref (contains '..')\n", .{});
            return error.InvalidArgument;
        }
    }
}

pub fn parseListArgs(allocator: Allocator, args: []const [:0]const u8) !ListOptions {
    var opts: ListOptions = .{};
    var common: CommonFlags = .{};
    errdefer common.file_filter.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &common)) continue;
        if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--oneline")) {
            opts.oneline = true;
        } else {
            return error.UnknownFlag;
        }
    }
    try applyCommonFlags(allocator, &common, &opts);
    errdefer deinitFileFilter(allocator, opts.file_filter);

    try validateRefStagedCombo(opts.ref, opts.mode);

    return opts;
}

pub fn parseAddResetArgs(allocator: Allocator, args: []const [:0]const u8) !AddResetOptions {
    var opts: AddResetOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var common: CommonFlags = .{};
    errdefer common.file_filter.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &common)) continue;
        if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
            try opts.sha_args.append(allocator, sha_arg);
        }
    }

    try applyCommonFlags(allocator, &common, &opts);
    errdefer deinitFileFilter(allocator, opts.file_filter);

    if (opts.sha_args.items.len == 0 and !opts.select_all and opts.file_filter.len == 0) {
        std.debug.print("error: at least one <sha> argument required (or use --all or --file <path>)\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

pub fn parseDiffArgs(allocator: Allocator, args: []const [:0]const u8) !DiffOptions {
    var opts: DiffOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var common: CommonFlags = .{};
    errdefer common.file_filter.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &common)) continue;
        if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
            try opts.sha_args.append(allocator, sha_arg);
        }
    }

    try applyCommonFlags(allocator, &common, &opts);
    errdefer deinitFileFilter(allocator, opts.file_filter);

    try validateRefStagedCombo(opts.ref, opts.mode);

    if (opts.sha_args.items.len == 0) {
        std.debug.print("error: at least one <sha> argument required\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

pub fn parseCountArgs(allocator: Allocator, args: []const [:0]const u8) !CountOptions {
    var opts: CountOptions = .{};
    var common: CommonFlags = .{};
    errdefer common.file_filter.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &common)) continue;
        if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else {
            if (std.mem.startsWith(u8, arg, "-")) return unknownFlag(arg);
            std.debug.print("error: count does not accept arguments\n", .{});
            return error.InvalidArgument;
        }
    }
    // Apply only the fields CountOptions has (no_color and output not present)
    try applyCommonFlags(allocator, &common, &opts);
    errdefer deinitFileFilter(allocator, opts.file_filter);

    try validateRefStagedCombo(opts.ref, opts.mode);

    return opts;
}

pub fn parseCheckArgs(allocator: Allocator, args: []const [:0]const u8) !CheckOptions {
    var opts: CheckOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var common: CommonFlags = .{};
    errdefer common.file_filter.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &common)) continue;
        if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--exclusive")) {
            opts.exclusive = true;
        } else if (std.mem.eql(u8, arg, "--allow-empty")) {
            opts.allow_empty = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
            if (sha_arg.line_spec) |ls| {
                allocator.free(ls.ranges);
                std.debug.print("error: line specs not supported for check\n", .{});
                return error.InvalidArgument;
            }
            try opts.sha_args.append(allocator, sha_arg);
        }
    }

    try applyCommonFlags(allocator, &common, &opts);
    errdefer deinitFileFilter(allocator, opts.file_filter);

    try validateRefStagedCombo(opts.ref, opts.mode);

    if (opts.sha_args.items.len == 0 and !opts.allow_empty) {
        std.debug.print("error: at least one <sha> argument required\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

pub fn parseRestoreArgs(allocator: Allocator, args: []const [:0]const u8) !RestoreOptions {
    var opts: RestoreOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var common: CommonFlags = .{};
    errdefer common.file_filter.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &common)) continue;
        if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
            try opts.sha_args.append(allocator, sha_arg);
        }
    }

    try applyCommonFlags(allocator, &common, &opts);
    errdefer deinitFileFilter(allocator, opts.file_filter);

    if (opts.sha_args.items.len == 0 and !opts.select_all and opts.file_filter.len == 0) {
        std.debug.print("error: at least one <sha> argument required (or use --all or --file <path>)\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

pub fn parseStashArgs(allocator: Allocator, args: []const [:0]const u8) !StashOptions {
    var opts: StashOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var i: usize = 0;

    // Check for subcommand: push or pop
    if (i < args.len) {
        const first = args[i];
        if (std.mem.eql(u8, first, "pop")) {
            // pop subcommand: reject all other flags/args
            i += 1;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    return error.HelpRequested;
                }
                std.debug.print("error: pop does not accept arguments or flags\n", .{});
                return error.InvalidArgument;
            }
            opts.pop = true;
            return opts;
        } else if (std.mem.eql(u8, first, "push")) {
            // Explicit push: skip keyword, parse rest as normal
            i += 1;
        }
        // Otherwise: not a subcommand keyword, treat as flags/hash (implicit push)
    }

    var common: CommonFlags = .{};
    errdefer common.file_filter.deinit(allocator);
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &common)) continue;
        if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.eql(u8, arg, "--include-untracked") or std.mem.eql(u8, arg, "-u")) {
            opts.include_untracked = true;
        } else if (std.mem.eql(u8, arg, "--message") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.message = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
            if (sha_arg.line_spec) |ls| {
                allocator.free(ls.ranges);
                std.debug.print("error: line specs not supported for stash\n", .{});
                return error.InvalidArgument;
            }
            try opts.sha_args.append(allocator, sha_arg);
        }
    }

    try applyCommonFlags(allocator, &common, &opts);
    errdefer deinitFileFilter(allocator, opts.file_filter);

    if (opts.ref != null) {
        std.debug.print("error: --ref is not supported for stash\n", .{});
        return error.InvalidArgument;
    }

    // --include-untracked conflicts with --tracked-only
    if (opts.include_untracked and opts.diff_filter == .tracked_only) {
        std.debug.print("error: --include-untracked cannot be combined with --tracked-only\n", .{});
        return error.InvalidArgument;
    }

    if (opts.sha_args.items.len == 0 and !opts.select_all and opts.file_filter.len == 0) {
        std.debug.print("error: at least one <sha> argument required (or use --all or --file <path>)\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

pub fn parseCommitArgs(allocator: Allocator, args: []const [:0]const u8) !CommitOptions {
    var opts: CommitOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var common: CommonFlags = .{};
    errdefer common.file_filter.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--staged")) {
            std.debug.print("error: --staged is not supported by commit -- use 'git commit' directly\n", .{});
            return error.UnknownFlag;
        }
        if (try parseCommonFlag(allocator, arg, &i, args, &common)) continue;
        if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.eql(u8, arg, "--message") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.message = args[i];
        } else if (std.mem.eql(u8, arg, "--amend")) {
            opts.amend = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
            try opts.sha_args.append(allocator, sha_arg);
        }
    }

    try applyCommonFlags(allocator, &common, &opts);
    errdefer deinitFileFilter(allocator, opts.file_filter);

    if (opts.sha_args.items.len == 0 and !opts.select_all and opts.file_filter.len == 0) {
        std.debug.print("error: at least one <sha> argument required (or use --all or --file <path>)\n", .{});
        return error.MissingArgument;
    }

    if (opts.message == null and !opts.dry_run) {
        std.debug.print("error: -m <message> is required\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

pub fn deinitShaArgs(allocator: Allocator, sha_args: *std.ArrayList(ShaArg)) void {
    for (sha_args.items) |arg| {
        if (arg.line_spec) |ls| {
            allocator.free(ls.ranges);
        }
    }
    sha_args.deinit(allocator);
}

/// Parse a SHA argument with optional line spec: "abc1234" or "abc1234:3-5,8"
fn parseShaArg(allocator: Allocator, arg: []const u8) !ShaArg {
    // Split on first ':'
    const colon_pos = std.mem.indexOfScalar(u8, arg, ':');
    const sha_part = if (colon_pos) |pos| arg[0..pos] else arg;
    const line_part: ?[]const u8 = if (colon_pos) |pos| arg[pos + 1 ..] else null;

    // Validate SHA prefix
    if (sha_part.len < 4) {
        std.debug.print("error: sha prefix too short (minimum 4 chars): '{s}'\n", .{sha_part});
        return error.InvalidArgument;
    }
    for (sha_part) |c| {
        if (!isHexDigit(c)) {
            std.debug.print("error: invalid hex in sha prefix: '{s}'\n", .{sha_part});
            return error.InvalidArgument;
        }
    }

    // Parse optional line spec
    const line_spec: ?LineSpec = if (line_part) |spec| blk: {
        if (spec.len == 0) {
            std.debug.print("error: empty line spec after ':' in '{s}'\n", .{arg});
            return error.InvalidArgument;
        }
        break :blk try parseLineSpec(allocator, spec);
    } else null;

    return .{ .prefix = sha_part, .line_spec = line_spec };
}

/// Parse a comma-separated line spec like "3-5,8,12-15"
fn parseLineSpec(allocator: Allocator, spec: []const u8) !LineSpec {
    var ranges: std.ArrayList(LineRange) = .empty;
    errdefer ranges.deinit(allocator);

    var iter = std.mem.splitScalar(u8, spec, ',');
    while (iter.next()) |part| {
        if (part.len == 0) {
            std.debug.print("error: empty range in line spec\n", .{});
            return error.InvalidArgument;
        }
        if (std.mem.indexOfScalar(u8, part, '-')) |dash_pos| {
            if (dash_pos == 0 or dash_pos == part.len - 1) {
                std.debug.print("error: invalid range '{s}' in line spec\n", .{part});
                return error.InvalidArgument;
            }
            const start = std.fmt.parseInt(u32, part[0..dash_pos], 10) catch {
                std.debug.print("error: invalid number in line spec range '{s}'\n", .{part});
                return error.InvalidArgument;
            };
            const end_val = std.fmt.parseInt(u32, part[dash_pos + 1 ..], 10) catch {
                std.debug.print("error: invalid number in line spec range '{s}'\n", .{part});
                return error.InvalidArgument;
            };
            if (start == 0 or end_val == 0) {
                std.debug.print("error: line numbers must be >= 1 in '{s}'\n", .{part});
                return error.InvalidArgument;
            }
            if (start > end_val) {
                std.debug.print("error: range start > end in '{s}'\n", .{part});
                return error.InvalidArgument;
            }
            try ranges.append(allocator, .{ .start = start, .end = end_val });
        } else {
            const val = std.fmt.parseInt(u32, part, 10) catch {
                std.debug.print("error: invalid number '{s}' in line spec\n", .{part});
                return error.InvalidArgument;
            };
            if (val == 0) {
                std.debug.print("error: line numbers must be >= 1\n", .{});
                return error.InvalidArgument;
            }
            try ranges.append(allocator, .{ .start = val, .end = val });
        }
    }

    if (ranges.items.len == 0) {
        std.debug.print("error: empty line spec\n", .{});
        return error.InvalidArgument;
    }

    return .{ .ranges = try ranges.toOwnedSlice(allocator) };
}

// ============================================================================
// Tests
// ============================================================================

test "parseListArgs defaults" {
    const opts = try parseListArgs(std.testing.allocator, &.{});
    try std.testing.expectEqual(DiffMode.unstaged, opts.mode);
    try std.testing.expectEqual(OutputMode.human, opts.output);
    try std.testing.expect(!opts.oneline);
    try std.testing.expectEqual(@as(usize, 0), opts.file_filter.len);
}

test "parseListArgs staged" {
    const args_arr = [_][:0]const u8{"--staged"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseListArgs porcelain" {
    const args_arr = [_][:0]const u8{"--porcelain"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
}

test "parseListArgs oneline" {
    const args_arr = [_][:0]const u8{"--oneline"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expect(opts.oneline);
}

test "parseListArgs no-color" {
    const args_arr = [_][:0]const u8{"--no-color"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expect(opts.no_color);
}

test "parseListArgs file filter" {
    const args_arr = [_][:0]const u8{ "--file", "src/main.zig" };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    defer deinitFileFilter(std.testing.allocator, opts.file_filter);
    try std.testing.expectEqual(@as(usize, 1), opts.file_filter.len);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter[0]);
}

test "parseListArgs file missing arg" {
    const args_arr = [_][:0]const u8{"--file"};
    try std.testing.expectError(error.MissingArgument, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs multiple --file accumulate" {
    const args_arr = [_][:0]const u8{
        "--file", "foo.txt",
        "--file", "bar.txt",
    };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    defer deinitFileFilter(std.testing.allocator, opts.file_filter);
    try std.testing.expectEqual(@as(usize, 2), opts.file_filter.len);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter[0]);
    try std.testing.expectEqualStrings("bar.txt", opts.file_filter[1]);
}

test "parseAddResetArgs multiple --file accumulate" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{
        "--file", "foo.txt",
        "--file", "bar.txt",
    };
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, opts.file_filter);
    try std.testing.expectEqual(@as(usize, 2), opts.file_filter.len);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter[0]);
    try std.testing.expectEqualStrings("bar.txt", opts.file_filter[1]);
}

test "parseListArgs unknown flag" {
    const args_arr = [_][:0]const u8{"--unknown"};
    try std.testing.expectError(error.UnknownFlag, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs all flags combined" {
    const args_arr = [_][:0]const u8{
        "--staged",
        "--porcelain",
        "--oneline",
        "--no-color",
        "--file",
        "foo.txt",
    };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    defer deinitFileFilter(std.testing.allocator, opts.file_filter);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
    try std.testing.expect(opts.oneline);
    try std.testing.expect(opts.no_color);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter[0]);
}

test "parseListArgs context" {
    const args_arr = [_][:0]const u8{ "--unified", "0" };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(@as(?u32, 0), opts.context);
}

test "parseListArgs context value" {
    const args_arr = [_][:0]const u8{ "--unified", "5" };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(@as(?u32, 5), opts.context);
}

test "parseListArgs context missing arg" {
    const args_arr = [_][:0]const u8{"--unified"};
    try std.testing.expectError(error.MissingArgument, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs context invalid" {
    const args_arr = [_][:0]const u8{ "--unified", "abc" };
    try std.testing.expectError(error.InvalidArgument, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs context default null" {
    const opts = try parseListArgs(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(?u32, null), opts.context);
}

test "parseListArgs context -U<n> form" {
    const args_arr = [_][:0]const u8{"-U3"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(@as(?u32, 3), opts.context);
}

test "parseListArgs context -U0 form" {
    const args_arr = [_][:0]const u8{"-U0"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(@as(?u32, 0), opts.context);
}

test "parseListArgs context --unified=<n> form" {
    const args_arr = [_][:0]const u8{"--unified=5"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(@as(?u32, 5), opts.context);
}

test "parseListArgs context -U alone gives error" {
    const args_arr = [_][:0]const u8{"-U"};
    try std.testing.expectError(error.MissingArgument, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs context -Uabc gives error" {
    const args_arr = [_][:0]const u8{"-Uabc"};
    try std.testing.expectError(error.InvalidArgument, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs context --unified=abc gives error" {
    const args_arr = [_][:0]const u8{"--unified=abc"};
    try std.testing.expectError(error.InvalidArgument, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs context -U <n> space form" {
    const args_arr = [_][:0]const u8{ "-U", "3" };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(@as(?u32, 3), opts.context);
}

test "parseListArgs verbosity default normal" {
    const opts = try parseListArgs(std.testing.allocator, &.{});
    try std.testing.expectEqual(types.Verbosity.normal, opts.verbosity);
}

test "parseListArgs verbosity --quiet" {
    const args_arr = [_][:0]const u8{"--quiet"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(types.Verbosity.quiet, opts.verbosity);
}

test "parseListArgs verbosity -q" {
    const args_arr = [_][:0]const u8{"-q"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(types.Verbosity.quiet, opts.verbosity);
}

test "parseListArgs verbosity --verbose" {
    const args_arr = [_][:0]const u8{"--verbose"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(types.Verbosity.verbose, opts.verbosity);
}

test "parseListArgs verbosity -v" {
    const args_arr = [_][:0]const u8{"-v"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(types.Verbosity.verbose, opts.verbosity);
}

test "parseListArgs verbosity --quiet --verbose conflict" {
    const args_arr = [_][:0]const u8{ "--quiet", "--verbose" };
    try std.testing.expectError(error.ConflictingVerbosity, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs verbosity --verbose --quiet conflict" {
    const args_arr = [_][:0]const u8{ "--verbose", "--quiet" };
    try std.testing.expectError(error.ConflictingVerbosity, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseAddResetArgs verbosity --verbose" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--verbose" };
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(types.Verbosity.verbose, opts.verbosity);
}

test "parseAddResetArgs verbosity --quiet" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--quiet" };
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(types.Verbosity.quiet, opts.verbosity);
}

test "parseStashArgs verbosity --verbose" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--verbose" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(types.Verbosity.verbose, opts.verbosity);
}

test "parseStashArgs verbosity --quiet" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--quiet" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(types.Verbosity.quiet, opts.verbosity);
}

test "parseCountArgs verbosity --verbose" {
    const args_arr = [_][:0]const u8{"--verbose"};
    const opts = try parseCountArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(types.Verbosity.verbose, opts.verbosity);
}

test "parseCountArgs verbosity --quiet" {
    const args_arr = [_][:0]const u8{"--quiet"};
    const opts = try parseCountArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(types.Verbosity.quiet, opts.verbosity);
}

test "parseAddResetArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234"};
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expectEqualStrings("abcd1234", opts.sha_args.items[0].prefix);
    try std.testing.expectEqual(@as(?LineSpec, null), opts.sha_args.items[0].line_spec);
}

test "parseAddResetArgs too short sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abc"};
    try std.testing.expectError(error.InvalidArgument, parseAddResetArgs(allocator, &args_arr));
}

test "parseAddResetArgs non-hex sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"xyzw1234"};
    try std.testing.expectError(error.InvalidArgument, parseAddResetArgs(allocator, &args_arr));
}

test "parseAddResetArgs missing sha" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parseAddResetArgs(allocator, &.{}));
}

test "parseAddResetArgs select all" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"--all"};
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.select_all);
}

test "parseAddResetArgs no-color" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--no-color" };
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.no_color);
}

test "parseAddResetArgs with file flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{
        "abcd1234",
        "--file",
        "src/main.zig",
    };
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, opts.file_filter);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter[0]);
}

test "parseAddResetArgs multiple shas" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{
        "abcd1234",
        "ef567890",
    };
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 2), opts.sha_args.items.len);
}

test "parseAddResetArgs context" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--unified", "1" };
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(?u32, 1), opts.context);
}

test "parseAddResetArgs context missing arg" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--unified" };
    try std.testing.expectError(error.MissingArgument, parseAddResetArgs(allocator, &args_arr));
}

test "parseDiffArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234"};
    var opts = try parseDiffArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
}

test "parseDiffArgs staged flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--staged" };
    var opts = try parseDiffArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseDiffArgs porcelain flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--porcelain" };
    var opts = try parseDiffArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
}

test "parseDiffArgs no-color flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--no-color" };
    var opts = try parseDiffArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.no_color);
}

test "parseDiffArgs unknown flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseDiffArgs(allocator, &args_arr));
}

test "parseDiffArgs missing sha" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parseDiffArgs(allocator, &.{}));
}

test "parseDiffArgs context" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--unified", "2" };
    var opts = try parseDiffArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(?u32, 2), opts.context);
}

test "parseDiffArgs context missing arg" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--unified" };
    try std.testing.expectError(error.MissingArgument, parseDiffArgs(allocator, &args_arr));
}

test "parseShaArg plain sha" {
    const allocator = std.testing.allocator;
    const arg = try parseShaArg(allocator, "abcd1234");
    try std.testing.expectEqualStrings("abcd1234", arg.prefix);
    try std.testing.expectEqual(@as(?LineSpec, null), arg.line_spec);
}

test "parseShaArg sha with single line" {
    const allocator = std.testing.allocator;
    const arg = try parseShaArg(allocator, "abcd1234:5");
    defer allocator.free(arg.line_spec.?.ranges);
    try std.testing.expectEqualStrings("abcd1234", arg.prefix);
    try std.testing.expectEqual(@as(usize, 1), arg.line_spec.?.ranges.len);
    try std.testing.expectEqual(@as(u32, 5), arg.line_spec.?.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 5), arg.line_spec.?.ranges[0].end);
}

test "parseShaArg sha with range" {
    const allocator = std.testing.allocator;
    const arg = try parseShaArg(allocator, "abcd1234:3-7");
    defer allocator.free(arg.line_spec.?.ranges);
    try std.testing.expectEqualStrings("abcd1234", arg.prefix);
    try std.testing.expectEqual(@as(u32, 3), arg.line_spec.?.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 7), arg.line_spec.?.ranges[0].end);
}

test "parseShaArg sha with multiple ranges" {
    const allocator = std.testing.allocator;
    const arg = try parseShaArg(allocator, "abcd1234:1-3,5,8-10");
    defer allocator.free(arg.line_spec.?.ranges);
    try std.testing.expectEqual(@as(usize, 3), arg.line_spec.?.ranges.len);
    try std.testing.expectEqual(@as(u32, 1), arg.line_spec.?.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 3), arg.line_spec.?.ranges[0].end);
    try std.testing.expectEqual(@as(u32, 5), arg.line_spec.?.ranges[1].start);
    try std.testing.expectEqual(@as(u32, 5), arg.line_spec.?.ranges[1].end);
    try std.testing.expectEqual(@as(u32, 8), arg.line_spec.?.ranges[2].start);
    try std.testing.expectEqual(@as(u32, 10), arg.line_spec.?.ranges[2].end);
}

test "parseShaArg sha too short with line spec" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, parseShaArg(allocator, "abc:1-3"));
}

test "parseShaArg empty line spec" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, parseShaArg(allocator, "abcd1234:"));
}

test "parseShaArg zero line number" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, parseShaArg(allocator, "abcd1234:0"));
}

test "parseShaArg range start > end" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, parseShaArg(allocator, "abcd1234:5-3"));
}

test "parseShaArg invalid number in line spec" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, parseShaArg(allocator, "abcd1234:abc"));
}

test "parseAddResetArgs sha with line spec" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234:3-5"};
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expectEqualStrings("abcd1234", opts.sha_args.items[0].prefix);
    try std.testing.expect(opts.sha_args.items[0].line_spec != null);
    try std.testing.expectEqual(@as(u32, 3), opts.sha_args.items[0].line_spec.?.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 5), opts.sha_args.items[0].line_spec.?.ranges[0].end);
}

test "parseDiffArgs sha with line spec" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234:1-3,7"};
    var opts = try parseDiffArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expect(opts.sha_args.items[0].line_spec != null);
    try std.testing.expectEqual(@as(usize, 2), opts.sha_args.items[0].line_spec.?.ranges.len);
}

test "parseCountArgs defaults" {
    const opts = try parseCountArgs(std.testing.allocator, &.{});
    try std.testing.expectEqual(DiffMode.unstaged, opts.mode);
    try std.testing.expectEqual(@as(usize, 0), opts.file_filter.len);
    try std.testing.expectEqual(@as(?u32, null), opts.context);
}

test "parseCountArgs staged" {
    const args_arr = [_][:0]const u8{"--staged"};
    const opts = try parseCountArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseCountArgs file filter" {
    const args_arr = [_][:0]const u8{ "--file", "src/main.zig" };
    const opts = try parseCountArgs(std.testing.allocator, &args_arr);
    defer deinitFileFilter(std.testing.allocator, opts.file_filter);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter[0]);
}

test "parseCountArgs context" {
    const args_arr = [_][:0]const u8{ "--unified", "5" };
    const opts = try parseCountArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(@as(?u32, 5), opts.context);
}

test "parseCountArgs porcelain accepted silently" {
    const opts = try parseCountArgs(std.testing.allocator, &[_][:0]const u8{"--porcelain"});
    try std.testing.expectEqual(DiffMode.unstaged, opts.mode);
}

test "parseCountArgs no-color accepted silently" {
    const opts = try parseCountArgs(std.testing.allocator, &[_][:0]const u8{"--no-color"});
    try std.testing.expectEqual(DiffMode.unstaged, opts.mode);
}

test "parseCountArgs rejects positional args" {
    const args_arr = [_][:0]const u8{"abcd1234"};
    try std.testing.expectError(error.InvalidArgument, parseCountArgs(std.testing.allocator, &args_arr));
}

test "parseCountArgs rejects unknown flags" {
    const args_arr = [_][:0]const u8{"--unknown"};
    try std.testing.expectError(error.UnknownFlag, parseCountArgs(std.testing.allocator, &args_arr));
}

test "parseCountArgs file missing arg" {
    const args_arr = [_][:0]const u8{"--file"};
    try std.testing.expectError(error.MissingArgument, parseCountArgs(std.testing.allocator, &args_arr));
}

test "parseCountArgs context missing arg" {
    const args_arr = [_][:0]const u8{"--unified"};
    try std.testing.expectError(error.MissingArgument, parseCountArgs(std.testing.allocator, &args_arr));
}

test "parseCountArgs all flags combined" {
    const args_arr = [_][:0]const u8{
        "--staged",
        "--file",
        "foo.txt",
        "--unified",
        "3",
        "--porcelain",
        "--no-color",
    };
    const opts = try parseCountArgs(std.testing.allocator, &args_arr);
    defer deinitFileFilter(std.testing.allocator, opts.file_filter);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter[0]);
    try std.testing.expectEqual(@as(?u32, 3), opts.context);
}

test "parseCheckArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234"};
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expectEqualStrings("abcd1234", opts.sha_args.items[0].prefix);
    try std.testing.expectEqual(@as(?types.LineSpec, null), opts.sha_args.items[0].line_spec);
}

test "parseCheckArgs staged flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--staged" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseCheckArgs exclusive flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--exclusive" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.exclusive);
}

test "parseCheckArgs porcelain flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--porcelain" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
}

test "parseCheckArgs no-color flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--no-color" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.no_color);
}

test "parseCheckArgs file filter" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--file", "src/main.zig" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, opts.file_filter);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter[0]);
}

test "parseCheckArgs context" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--unified", "2" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(?u32, 2), opts.context);
}

test "parseCheckArgs multiple shas" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "ef567890" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 2), opts.sha_args.items.len);
}

test "parseCheckArgs missing sha" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parseCheckArgs(allocator, &.{}));
}

test "parseCheckArgs rejects line specs" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234:3-5"};
    try std.testing.expectError(error.InvalidArgument, parseCheckArgs(allocator, &args_arr));
}

test "parseCheckArgs rejects unknown flags" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseCheckArgs(allocator, &args_arr));
}

test "parseCheckArgs all flags combined" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{
        "abcd1234",
        "--staged",
        "--exclusive",
        "--file",
        "foo.txt",
        "--porcelain",
        "--no-color",
        "--unified",
        "1",
    };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, opts.file_filter);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
    try std.testing.expect(opts.exclusive);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter[0]);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
    try std.testing.expect(opts.no_color);
    try std.testing.expectEqual(@as(?u32, 1), opts.context);
}

test "isHexDigit digits" {
    for ("0123456789") |c| try std.testing.expect(isHexDigit(c));
}

test "isHexDigit lower hex" {
    for ("abcdef") |c| try std.testing.expect(isHexDigit(c));
}

test "isHexDigit upper hex" {
    for ("ABCDEF") |c| try std.testing.expect(isHexDigit(c));
}

test "isHexDigit non-hex" {
    try std.testing.expect(!isHexDigit('g'));
    try std.testing.expect(!isHexDigit('G'));
    try std.testing.expect(!isHexDigit(' '));
    try std.testing.expect(!isHexDigit('-'));
}

test "parseRestoreArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234"};
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expectEqualStrings("abcd1234", opts.sha_args.items[0].prefix);
    try std.testing.expect(!opts.dry_run);
}

test "parseRestoreArgs missing sha" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parseRestoreArgs(allocator, &.{}));
}

test "parseRestoreArgs select all" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"--all"};
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.select_all);
}

test "parseRestoreArgs dry-run" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--dry-run" };
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.dry_run);
}

test "parseRestoreArgs file filter" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--file", "src/main.zig" };
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, opts.file_filter);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter[0]);
}

test "parseRestoreArgs porcelain" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--porcelain" };
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
}

test "parseRestoreArgs no-color" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--no-color" };
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.no_color);
}

test "parseRestoreArgs context" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--unified", "2" };
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(?u32, 2), opts.context);
}

test "parseRestoreArgs rejects unknown flags" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--staged" };
    try std.testing.expectError(error.UnknownFlag, parseRestoreArgs(allocator, &args_arr));
}

test "parseRestoreArgs all flags combined" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{
        "abcd1234",
        "--all",
        "--dry-run",
        "--file",
        "foo.txt",
        "--porcelain",
        "--no-color",
        "--unified",
        "1",
    };
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, opts.file_filter);
    try std.testing.expect(opts.select_all);
    try std.testing.expect(opts.dry_run);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter[0]);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
    try std.testing.expect(opts.no_color);
    try std.testing.expectEqual(@as(?u32, 1), opts.context);
}

test "parseRestoreArgs bare file flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--file", "src/main.zig" };
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, opts.file_filter);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter[0]);
    try std.testing.expectEqual(@as(usize, 0), opts.sha_args.items.len);
}

test "parseStashArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234"};
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expect(std.mem.startsWith(u8, &opts.sha_args.items[0].sha_hex, "abcd1234"));
    try std.testing.expect(!opts.pop);
}

test "parseStashArgs missing sha" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parseStashArgs(allocator, &.{}));
}

test "parseStashArgs select all" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"--all"};
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.select_all);
}

test "parseStashArgs pop subcommand" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"pop"};
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.pop);
}

test "parseStashArgs push subcommand explicit" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "push", "--all" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.select_all);
    try std.testing.expect(!opts.pop);
}

test "parseStashArgs include-untracked long flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--include-untracked" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.include_untracked);
}

test "parseStashArgs include-untracked short flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "-u" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.include_untracked);
}

test "parseStashArgs include-untracked conflicts with tracked-only" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--include-untracked", "--tracked-only" };
    try std.testing.expectError(error.InvalidArgument, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs message long flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--message", "my stash" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("my stash", opts.message.?);
}

test "parseStashArgs message short flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "-m", "my stash" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("my stash", opts.message.?);
}

test "parseStashArgs message missing value" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--message" };
    try std.testing.expectError(error.MissingArgument, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs file filter" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--file", "src/main.zig" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, opts.file_filter);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter[0]);
}

test "parseStashArgs porcelain" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--porcelain" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
}

test "parseStashArgs no-color" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--no-color" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.no_color);
}

test "parseStashArgs context" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--unified", "2" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(?u32, 2), opts.context);
}

test "parseStashArgs rejects unknown flags" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--staged" };
    try std.testing.expectError(error.UnknownFlag, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs rejects line specs" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234:3-5"};
    try std.testing.expectError(error.InvalidArgument, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs pop rejects extra args" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "pop", "abcd1234" };
    try std.testing.expectError(error.InvalidArgument, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs pop rejects flags" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "pop", "--all" };
    try std.testing.expectError(error.InvalidArgument, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs old --pop flag rejected as unknown" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--pop" };
    try std.testing.expectError(error.UnknownFlag, parseStashArgs(allocator, &args_arr));
}

// ============================================================================
// --ref flag tests
// ============================================================================

test "parseListArgs --ref sets ref field" {
    const args_arr = [_][:0]const u8{ "--ref", "main" };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqualStrings("main", opts.ref.?);
}

test "parseListArgs --ref default null" {
    const opts = try parseListArgs(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(?[]const u8, null), opts.ref);
}

test "parseListArgs --ref missing value" {
    const args_arr = [_][:0]const u8{"--ref"};
    try std.testing.expectError(error.MissingArgument, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs --ref with --staged allowed for single ref" {
    const args_arr = [_][:0]const u8{ "--ref", "HEAD", "--staged" };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqualStrings("HEAD", opts.ref.?);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseListArgs --ref range with --staged rejected" {
    const args_arr = [_][:0]const u8{ "--ref", "main..HEAD", "--staged" };
    try std.testing.expectError(error.InvalidArgument, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs --ref range without --staged allowed" {
    const args_arr = [_][:0]const u8{ "--ref", "main..HEAD" };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqualStrings("main..HEAD", opts.ref.?);
    try std.testing.expectEqual(DiffMode.unstaged, opts.mode);
}

test "parseStashArgs --ref rejected" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--ref", "main" };
    try std.testing.expectError(error.InvalidArgument, parseStashArgs(allocator, &args_arr));
}

test "parseDiffArgs --ref sets ref field" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--ref", "main" };
    var opts = try parseDiffArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("main", opts.ref.?);
}

test "parseDiffArgs --ref range with --staged rejected" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--ref", "main..HEAD", "--staged" };
    try std.testing.expectError(error.InvalidArgument, parseDiffArgs(allocator, &args_arr));
}

test "parseCountArgs --ref sets ref field" {
    const args_arr = [_][:0]const u8{ "--ref", "HEAD~1" };
    const opts = try parseCountArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqualStrings("HEAD~1", opts.ref.?);
}

test "parseCountArgs --ref range with --staged rejected" {
    const args_arr = [_][:0]const u8{ "--ref", "main..HEAD", "--staged" };
    try std.testing.expectError(error.InvalidArgument, parseCountArgs(std.testing.allocator, &args_arr));
}

test "parseCheckArgs --ref sets ref field" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--ref", "main" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("main", opts.ref.?);
}

test "parseCheckArgs --ref range with --staged rejected" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--ref", "main..HEAD", "--staged" };
    try std.testing.expectError(error.InvalidArgument, parseCheckArgs(allocator, &args_arr));
}

test "parseCheckArgs --allow-empty flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--allow-empty" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.allow_empty);
}

test "parseCheckArgs --allow-empty without exclusive no sha succeeds" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"--allow-empty"};
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.allow_empty);
    try std.testing.expectEqual(@as(usize, 0), opts.sha_args.items.len);
}

test "parseCheckArgs --allow-empty with exclusive no sha succeeds" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--exclusive", "--allow-empty" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.allow_empty);
    try std.testing.expect(opts.exclusive);
    try std.testing.expectEqual(@as(usize, 0), opts.sha_args.items.len);
}

test "parseCheckArgs no sha without allow-empty errors" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parseCheckArgs(allocator, &.{}));
}

test "parseCheckArgs --allow-empty with sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--allow-empty" };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.allow_empty);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
}

test "parseCheckArgs --allow-empty default false" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234"};
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(!opts.allow_empty);
}

test "parseAddResetArgs --ref sets ref field" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--ref", "main" };
    var opts = try parseAddResetArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("main", opts.ref.?);
}

test "parseRestoreArgs --ref sets ref field" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--ref", "HEAD~1" };
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("HEAD~1", opts.ref.?);
}

// ============================================================================
// parseCommitArgs tests
// ============================================================================

test "parseCommitArgs valid sha with message" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "-m", "feat: add thing" };
    var opts = try parseCommitArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expectEqualStrings("abcd1234", opts.sha_args.items[0].prefix);
    try std.testing.expectEqualStrings("feat: add thing", opts.message.?);
    try std.testing.expect(!opts.amend);
    try std.testing.expect(!opts.dry_run);
    try std.testing.expect(!opts.select_all);
}

test "parseCommitArgs --message long flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--message", "fix: bug" };
    var opts = try parseCommitArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("fix: bug", opts.message.?);
}

test "parseCommitArgs missing message without dry-run" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234"};
    try std.testing.expectError(error.MissingArgument, parseCommitArgs(allocator, &args_arr));
}

test "parseCommitArgs missing message value" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "-m" };
    try std.testing.expectError(error.MissingArgument, parseCommitArgs(allocator, &args_arr));
}

test "parseCommitArgs dry-run without message allowed" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--dry-run" };
    var opts = try parseCommitArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.dry_run);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.message);
}

test "parseCommitArgs --amend flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--amend", "-m", "fix" };
    var opts = try parseCommitArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.amend);
}

test "parseCommitArgs --all flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "-m", "feat: all" };
    var opts = try parseCommitArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.select_all);
}

test "parseCommitArgs missing sha without --all or --file" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "-m", "msg" };
    try std.testing.expectError(error.MissingArgument, parseCommitArgs(allocator, &args_arr));
}

test "parseCommitArgs --staged rejected" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--staged", "-m", "msg" };
    try std.testing.expectError(error.UnknownFlag, parseCommitArgs(allocator, &args_arr));
}

test "parseCommitArgs rejects unknown flags" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--unknown", "-m", "msg" };
    try std.testing.expectError(error.UnknownFlag, parseCommitArgs(allocator, &args_arr));
}

test "parseCommitArgs --ref sets ref field" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--ref", "main", "-m", "msg" };
    var opts = try parseCommitArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("main", opts.ref.?);
}

test "parseCommitArgs all flags combined" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{
        "abcd1234",
        "--all",
        "--amend",
        "--dry-run",
        "--file",
        "foo.txt",
        "--porcelain",
        "--no-color",
        "--unified",
        "1",
        "-m",
        "feat: everything",
    };
    var opts = try parseCommitArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, opts.file_filter);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expect(opts.select_all);
    try std.testing.expect(opts.amend);
    try std.testing.expect(opts.dry_run);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter[0]);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
    try std.testing.expect(opts.no_color);
    try std.testing.expectEqual(@as(?u32, 1), opts.context);
    try std.testing.expectEqualStrings("feat: everything", opts.message.?);
}

test "parseCommitArgs --file without sha allowed" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--file", "src/main.zig", "-m", "msg" };
    var opts = try parseCommitArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, opts.file_filter);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter[0]);
    try std.testing.expectEqual(@as(usize, 0), opts.sha_args.items.len);
}

test "validateRefStagedCombo rejects --staged with range ref" {
    try std.testing.expectError(error.InvalidArgument, validateRefStagedCombo("main..HEAD", .staged));
}

test "validateRefStagedCombo allows --staged with single ref" {
    try validateRefStagedCombo("HEAD", .staged);
    try validateRefStagedCombo("main", .staged);
}

test "validateRefStagedCombo allows range ref with unstaged" {
    try validateRefStagedCombo("main..HEAD", .unstaged);
}

test "validateRefStagedCombo allows null ref" {
    try validateRefStagedCombo(null, .staged);
    try validateRefStagedCombo(null, .unstaged);
}

test "deinitFileFilter no-op on empty slice" {
    deinitFileFilter(std.testing.allocator, &.{});
}

test "deinitFileFilter frees an allocated spine" {
    const allocator = std.testing.allocator;
    const spine = try allocator.alloc([]const u8, 2);
    spine[0] = "a.txt";
    spine[1] = "b.txt";
    deinitFileFilter(allocator, spine);
}

// Leak-detection tests: ensure parsers free file_filter when an error fires
// after `--file` has been accumulated. std.testing.allocator fails on leak.

test "parseListArgs leaks no memory when --file then --unknown" {
    const args_arr = [_][:0]const u8{ "--file", "a.txt", "--file", "b.txt", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseAddResetArgs leaks no memory when --file then --unknown" {
    const args_arr = [_][:0]const u8{ "--file", "a.txt", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseAddResetArgs(std.testing.allocator, &args_arr));
}

test "parseDiffArgs leaks no memory when --file then --unknown" {
    const args_arr = [_][:0]const u8{ "abcd1234", "--file", "a.txt", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseDiffArgs(std.testing.allocator, &args_arr));
}

test "parseCheckArgs leaks no memory when --file then --unknown" {
    const args_arr = [_][:0]const u8{ "abcd1234", "--file", "a.txt", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseCheckArgs(std.testing.allocator, &args_arr));
}

test "parseRestoreArgs leaks no memory when --file then --unknown" {
    const args_arr = [_][:0]const u8{ "--file", "a.txt", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseRestoreArgs(std.testing.allocator, &args_arr));
}

test "parseStashArgs leaks no memory when --file then --unknown" {
    const args_arr = [_][:0]const u8{ "--file", "a.txt", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseStashArgs(std.testing.allocator, &args_arr));
}

test "parseCommitArgs leaks no memory when --file then --unknown" {
    const args_arr = [_][:0]const u8{ "--file", "a.txt", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseCommitArgs(std.testing.allocator, &args_arr));
}

test "parseCountArgs leaks no memory when --file then --unknown" {
    const args_arr = [_][:0]const u8{ "--file", "a.txt", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, parseCountArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs leaks no memory when --file then --staged with range ref" {
    // applyCommonFlags succeeds; validateRefStagedCombo fails. Exercises
    // the post-applyCommonFlags errdefer path.
    const args_arr = [_][:0]const u8{ "--file", "a.txt", "--ref", "main..HEAD", "--staged" };
    try std.testing.expectError(error.InvalidArgument, parseListArgs(std.testing.allocator, &args_arr));
}
