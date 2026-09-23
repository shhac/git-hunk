const std = @import("std");
const types = @import("types.zig");
const path_mod = @import("path.zig");
const cli_spec = @import("spec.zig");

const Allocator = std.mem.Allocator;
const LineRange = types.LineRange;
const LineSpec = types.LineSpec;
const ShaArg = types.ShaArg;
const DiffMode = types.DiffMode;
const OutputMode = types.OutputMode;
const ListOptions = types.ListOptions;
const AddResetOptions = types.AddResetOptions;
const DiffOptions = types.DiffOptions;
const CountOptions = types.CountOptions;
const CheckOptions = types.CheckOptions;
const RestoreOptions = types.RestoreOptions;
const StashOptions = types.StashOptions;
const CommitOptions = types.CommitOptions;
const Common = types.Common;

/// Free every owned path in a file filter, then the list itself.
fn deinitFileFilter(allocator: Allocator, file_filter: *std.ArrayList([]const u8)) void {
    for (file_filter.items) |p| allocator.free(p);
    file_filter.deinit(allocator);
}

/// Free everything a `parse*Args` result owns.
pub fn deinitOptions(allocator: Allocator, opts: anytype) void {
    if (comptime @hasField(@TypeOf(opts.*), "sha_args")) deinitShaArgs(allocator, &opts.sha_args);
    deinitFileFilter(allocator, &opts.common.file_filter);
}

/// Try to parse arg as a common flag shared across all parsers.
/// Returns true if the arg was consumed (for value-taking flags like --file,
/// also increments i.* so the loop's `: (i += 1)` advances past the value).
/// Returns false if arg is not a common flag (caller handles it).
/// Returns error on parse failure or HelpRequested.
fn parseCommonFlag(allocator: Allocator, arg: []const u8, i: *usize, args: []const [:0]const u8, c: *Common) !bool {
    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
        return error.HelpRequested;
    } else if (std.mem.eql(u8, arg, "--file")) {
        try appendRepoRelative(allocator, &c.file_filter, try takeValue(args, i));
        return true;
    } else if (std.mem.eql(u8, arg, "--files-from")) {
        try appendPathsFromFile(allocator, try takeValue(args, i), &c.file_filter);
        return true;
    } else if (std.mem.eql(u8, arg, "--ref")) {
        c.ref = try takeValue(args, i);
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
    } else if (std.mem.eql(u8, arg, "--unified") or std.mem.eql(u8, arg, "-U")) {
        c.context = try parseContext(try takeValue(args, i));
        return true;
    } else if (std.mem.startsWith(u8, arg, "--unified=")) {
        c.context = try parseContext(arg["--unified=".len..]);
        return true;
    } else if (std.mem.startsWith(u8, arg, "-U")) {
        c.context = try parseContext(arg["-U".len..]);
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

/// Advance past a value-taking flag and return its value.
fn takeValue(args: []const [:0]const u8, i: *usize) error{MissingArgument}![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.MissingArgument;
    return args[i.*];
}

fn parseContext(val: []const u8) error{InvalidArgument}!u32 {
    return std.fmt.parseInt(u32, val, 10) catch error.InvalidArgument;
}

/// Parse a positional hunk hash (with optional `:lines` spec) and append it.
fn appendShaArg(allocator: Allocator, sha_args: *std.ArrayList(ShaArg), arg: []const u8) !void {
    const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
    errdefer if (sha_arg.line_spec) |ls| allocator.free(ls.ranges);
    try sha_args.append(allocator, sha_arg);
}

/// Like `appendShaArg`, for commands that act on whole hunks only: a `:lines`
/// spec is an error rather than silently widened to the whole hunk.
fn appendWholeHunkShaArg(comptime cmd: []const u8, allocator: Allocator, sha_args: *std.ArrayList(ShaArg), arg: []const u8) !void {
    const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
    if (sha_arg.line_spec) |ls| {
        allocator.free(ls.ranges);
        std.debug.print("error: line specs not supported for " ++ cmd ++ "\n", .{});
        return error.InvalidArgument;
    }
    try sha_args.append(allocator, sha_arg);
}

/// Commands that act on a selection need something to select.
fn requireSelection(opts: anytype) error{MissingArgument}!void {
    if (opts.sha_args.items.len > 0 or opts.select_all or opts.common.file_filter.items.len > 0) return;
    std.debug.print("error: at least one <sha> argument required (or use --all or --file <path>)\n", .{});
    return error.MissingArgument;
}

fn accepts3way(comptime cmd: []const u8) bool {
    return comptime for (cli_spec.get(cmd).flags) |f| {
        if (std.mem.eql(u8, f.long, cli_spec.f_3way.long)) break true;
    } else false;
}

/// --3way is only meaningful for commands that pass patches through
/// `git apply`, which the spec's flag table records. Silently swallowing it
/// elsewhere would mislead users into thinking it had an effect. Checked after
/// the whole argument loop so an unknown flag is still reported first.
fn rejectUnsupported3way(comptime cmd: []const u8, common: Common) error{UnknownFlag}!void {
    if (comptime accepts3way(cmd)) return;
    if (!common.three_way) return;
    std.debug.print("error: --3way is not supported for this subcommand (only add, reset, restore, commit)\n", .{});
    return error.UnknownFlag;
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
    errdefer deinitOptions(allocator, &opts);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &opts.common)) continue;
        if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--oneline")) {
            opts.oneline = true;
        } else {
            return unknownFlag(arg);
        }
    }
    try rejectUnsupported3way("list", opts.common);

    try validateRefStagedCombo(opts.common.ref, opts.mode);

    return opts;
}

pub fn parseAddResetArgs(allocator: Allocator, args: []const [:0]const u8) !AddResetOptions {
    var opts: AddResetOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitOptions(allocator, &opts);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &opts.common)) continue;
        if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            try appendShaArg(allocator, &opts.sha_args, arg);
        }
    }
    try rejectUnsupported3way("add", opts.common);
    try rejectUnsupported3way("reset", opts.common);

    try requireSelection(opts);

    return opts;
}

pub fn parseDiffArgs(allocator: Allocator, args: []const [:0]const u8) !DiffOptions {
    var opts: DiffOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitOptions(allocator, &opts);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &opts.common)) continue;
        if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--number") or std.mem.eql(u8, arg, "-n")) {
            opts.number = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            try appendShaArg(allocator, &opts.sha_args, arg);
        }
    }
    try rejectUnsupported3way("diff", opts.common);

    try validateRefStagedCombo(opts.common.ref, opts.mode);

    if (opts.sha_args.items.len == 0) {
        std.debug.print("error: at least one <sha> argument required\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

/// `--porcelain` and `--no-color` are accepted but have no effect: count's
/// output is a bare number either way.
pub fn parseCountArgs(allocator: Allocator, args: []const [:0]const u8) !CountOptions {
    var opts: CountOptions = .{};
    errdefer deinitOptions(allocator, &opts);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &opts.common)) continue;
        if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else {
            if (std.mem.startsWith(u8, arg, "-")) return unknownFlag(arg);
            std.debug.print("error: count does not accept arguments\n", .{});
            return error.InvalidArgument;
        }
    }
    try rejectUnsupported3way("count", opts.common);

    try validateRefStagedCombo(opts.common.ref, opts.mode);

    return opts;
}

pub fn parseCheckArgs(allocator: Allocator, args: []const [:0]const u8) !CheckOptions {
    var opts: CheckOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitOptions(allocator, &opts);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &opts.common)) continue;
        if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--exclusive")) {
            opts.exclusive = true;
        } else if (std.mem.eql(u8, arg, "--allow-empty")) {
            opts.allow_empty = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            try appendWholeHunkShaArg("check", allocator, &opts.sha_args, arg);
        }
    }
    try rejectUnsupported3way("check", opts.common);

    try validateRefStagedCombo(opts.common.ref, opts.mode);

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
    errdefer deinitOptions(allocator, &opts);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &opts.common)) continue;
        if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            try appendShaArg(allocator, &opts.sha_args, arg);
        }
    }
    try rejectUnsupported3way("restore", opts.common);

    try requireSelection(opts);

    return opts;
}

pub fn parseStashArgs(allocator: Allocator, args: []const [:0]const u8) !StashOptions {
    var opts: StashOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitOptions(allocator, &opts);

    const first: []const u8 = if (args.len > 0) args[0] else "";
    if (std.mem.eql(u8, first, "pop")) {
        if (args.len > 1) {
            const extra = args[1];
            if (std.mem.eql(u8, extra, "--help") or std.mem.eql(u8, extra, "-h")) return error.HelpRequested;
            std.debug.print("error: pop does not accept arguments or flags\n", .{});
            return error.InvalidArgument;
        }
        opts.pop = true;
        return opts;
    }

    // `push` is optional: without it, the first argument is already a flag or hash.
    var i: usize = if (std.mem.eql(u8, first, "push")) 1 else 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try parseCommonFlag(allocator, arg, &i, args, &opts.common)) continue;
        if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.eql(u8, arg, "--include-untracked") or std.mem.eql(u8, arg, "-u")) {
            opts.include_untracked = true;
        } else if (std.mem.eql(u8, arg, "--message") or std.mem.eql(u8, arg, "-m")) {
            opts.message = try takeValue(args, &i);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            try appendWholeHunkShaArg("stash", allocator, &opts.sha_args, arg);
        }
    }
    try rejectUnsupported3way("stash", opts.common);

    if (opts.common.ref != null) {
        std.debug.print("error: --ref is not supported for stash\n", .{});
        return error.InvalidArgument;
    }

    // --include-untracked conflicts with --tracked-only
    if (opts.include_untracked and opts.common.diff_filter == .tracked_only) {
        std.debug.print("error: --include-untracked cannot be combined with --tracked-only\n", .{});
        return error.InvalidArgument;
    }

    try requireSelection(opts);

    return opts;
}

pub fn parseCommitArgs(allocator: Allocator, args: []const [:0]const u8) !CommitOptions {
    var opts: CommitOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitOptions(allocator, &opts);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--staged")) {
            std.debug.print("error: --staged is not supported by commit -- use 'git commit' directly\n", .{});
            return error.UnknownFlag;
        }
        if (try parseCommonFlag(allocator, arg, &i, args, &opts.common)) continue;
        if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.eql(u8, arg, "--message") or std.mem.eql(u8, arg, "-m")) {
            opts.message = try takeValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--amend")) {
            opts.amend = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownFlag(arg);
        } else {
            try appendShaArg(allocator, &opts.sha_args, arg);
        }
    }
    try rejectUnsupported3way("commit", opts.common);

    try requireSelection(opts);

    if (opts.message == null and !opts.dry_run) {
        std.debug.print("error: -m <message> is required\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

/// Lowercase only, as Git 3.0 requires of object IDs. Hunk hashes are printed
/// lowercase, so an uppercase prefix could never match anything.
fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

fn deinitShaArgs(allocator: Allocator, sha_args: *std.ArrayList(ShaArg)) void {
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

    if (!isValidShaPrefix(sha_part)) return invalidShaPrefix(sha_part);

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

/// Explain why `sha_part` failed `isValidShaPrefix`, most helpful reason first.
fn invalidShaPrefix(sha_part: []const u8) error{InvalidArgument} {
    if (looksLikePathArg(sha_part) or pathExists(sha_part)) {
        std.debug.print("error: '{s}' looks like a path, not a hunk hash\n", .{sha_part});
        std.debug.print("hint: run 'git hunk list --oneline' to find hashes; use '--file <path>' to narrow by path\n", .{});
        return error.InvalidArgument;
    }
    if (sha_part.len < 4) {
        std.debug.print("error: sha prefix too short (minimum 4 chars): '{s}'\n", .{sha_part});
        return error.InvalidArgument;
    }
    const first_bad = for (sha_part) |c| {
        if (!isHexDigit(c)) break c;
    } else 0;
    if (std.ascii.isHex(first_bad)) {
        std.debug.print("error: hunk hashes are lowercase hex: '{s}'\n", .{sha_part});
        return error.InvalidArgument;
    }
    std.debug.print("error: invalid hex in sha prefix: '{s}'\n", .{sha_part});
    return error.InvalidArgument;
}

fn isValidShaPrefix(arg: []const u8) bool {
    if (arg.len < 4) return false;
    for (arg) |c| {
        if (!isHexDigit(c)) return false;
    }
    return true;
}

/// Upper bound on a `--files-from` list. Generous for real repos while keeping
/// a malformed/binary file from being slurped whole.
const max_files_from_bytes: usize = 16 * 1024 * 1024;

/// Read newline- or NUL-separated paths from `source` ("-" means stdin) and
/// append owned, repo-relative copies to `list`.
///
/// The separator is detected rather than flagged: NUL is not a legal byte in a
/// path, so its presence unambiguously means the producer used `-z`
/// (`git ls-files -z`, `find -print0`). That keeps paths containing newlines
/// safe without a second flag, and a newline-separated list is unaffected.
fn appendPathsFromFile(allocator: Allocator, source: []const u8, list: *std.ArrayList([]const u8)) !void {
    const io = types.getIo();
    const limit: std.Io.Limit = .limited(max_files_from_bytes);
    const content = blk: {
        if (std.mem.eql(u8, source, "-")) {
            var buf: [4096]u8 = undefined;
            var r = std.Io.File.stdin().readerStreaming(io, &buf);
            break :blk r.interface.allocRemaining(allocator, limit) catch {
                std.debug.print("error: could not read paths from stdin\n", .{});
                return error.InvalidArgument;
            };
        }
        // The process has already chdir'd to the repo root, but the user typed
        // this path from their own directory — resolve it the same way --file
        // values are resolved. Absolute paths are used as given.
        const prefix = types.getRepoPrefix();
        const resolved = if (prefix.len == 0 or std.fs.path.isAbsolute(source))
            source
        else
            try path_mod.resolveToRepoRelative(allocator, prefix, source);
        defer if (resolved.ptr != source.ptr) allocator.free(resolved);

        break :blk std.Io.Dir.cwd().readFileAlloc(io, resolved, allocator, limit) catch {
            std.debug.print("error: could not read --files-from file '{s}'\n", .{source});
            return error.InvalidArgument;
        };
    };
    defer allocator.free(content);

    const sep: u8 = if (std.mem.indexOfScalar(u8, content, 0) != null) 0 else '\n';
    var it = std.mem.splitScalar(u8, content, sep);
    while (it.next()) |raw| {
        // Tolerate CRLF and stray trailing whitespace from hand-written lists.
        const path = std.mem.trim(u8, raw, " \t\r\n");
        if (path.len == 0) continue;
        try appendRepoRelative(allocator, list, path);
    }
}

/// Append an owned, repo-relative copy of a path the user typed from their
/// own directory: the process has already chdir'd to the repo root.
fn appendRepoRelative(allocator: Allocator, list: *std.ArrayList([]const u8), path: []const u8) !void {
    const owned = try path_mod.resolveToRepoRelative(allocator, types.getRepoPrefix(), path);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn looksLikePathArg(arg: []const u8) bool {
    return std.mem.indexOfAny(u8, arg, "/\\.") != null;
}

fn pathExists(arg: []const u8) bool {
    const io = types.getIoOrNull() orelse return false;
    _ = std.Io.Dir.cwd().access(io, arg, .{}) catch return false;
    return true;
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
    try std.testing.expectEqual(OutputMode.human, opts.common.output);
    try std.testing.expect(!opts.oneline);
    try std.testing.expectEqual(@as(usize, 0), opts.common.file_filter.items.len);
}

test "parseListArgs staged" {
    const args_arr = [_][:0]const u8{"--staged"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseListArgs oneline" {
    const args_arr = [_][:0]const u8{"--oneline"};
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expect(opts.oneline);
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
    var opts = try parseListArgs(std.testing.allocator, &args_arr);
    defer deinitFileFilter(std.testing.allocator, &opts.common.file_filter);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
    try std.testing.expectEqual(OutputMode.porcelain, opts.common.output);
    try std.testing.expect(opts.oneline);
    try std.testing.expect(opts.common.no_color);
    try std.testing.expectEqualStrings("foo.txt", opts.common.file_filter.items[0]);
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

test "parseAddResetArgs path-shaped argument" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"src/main.zig"};
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

test "parseDiffArgs number flag short and long" {
    const allocator = std.testing.allocator;
    for ([_][:0]const u8{ "-n", "--number" }) |flag| {
        const args_arr = [_][:0]const u8{ "abcd1234", flag };
        var opts = try parseDiffArgs(allocator, &args_arr);
        defer deinitShaArgs(allocator, &opts.sha_args);
        try std.testing.expect(opts.number);
    }
}

test "parseDiffArgs number defaults off" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234"};
    var opts = try parseDiffArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(!opts.number);
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

test "parseShaArg uppercase hex" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, parseShaArg(allocator, "ABCD1234"));
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
    try std.testing.expectEqual(@as(usize, 0), opts.common.file_filter.items.len);
    try std.testing.expectEqual(@as(?u32, null), opts.common.context);
}

test "parseCountArgs staged" {
    const args_arr = [_][:0]const u8{"--staged"};
    const opts = try parseCountArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseCountArgs rejects positional args" {
    const args_arr = [_][:0]const u8{"abcd1234"};
    try std.testing.expectError(error.InvalidArgument, parseCountArgs(std.testing.allocator, &args_arr));
}

test "parseCountArgs rejects unknown flags" {
    const args_arr = [_][:0]const u8{"--unknown"};
    try std.testing.expectError(error.UnknownFlag, parseCountArgs(std.testing.allocator, &args_arr));
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
    var opts = try parseCountArgs(std.testing.allocator, &args_arr);
    defer deinitFileFilter(std.testing.allocator, &opts.common.file_filter);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
    try std.testing.expectEqualStrings("foo.txt", opts.common.file_filter.items[0]);
    try std.testing.expectEqual(@as(?u32, 3), opts.common.context);
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
    defer deinitFileFilter(allocator, &opts.common.file_filter);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
    try std.testing.expect(opts.exclusive);
    try std.testing.expectEqualStrings("foo.txt", opts.common.file_filter.items[0]);
    try std.testing.expectEqual(OutputMode.porcelain, opts.common.output);
    try std.testing.expect(opts.common.no_color);
    try std.testing.expectEqual(@as(?u32, 1), opts.common.context);
}

test "isHexDigit digits" {
    for ("0123456789") |c| try std.testing.expect(isHexDigit(c));
}

test "isHexDigit lower hex" {
    for ("abcdef") |c| try std.testing.expect(isHexDigit(c));
}

test "isHexDigit rejects upper hex" {
    for ("ABCDEF") |c| try std.testing.expect(!isHexDigit(c));
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
    defer deinitFileFilter(allocator, &opts.common.file_filter);
    try std.testing.expect(opts.select_all);
    try std.testing.expect(opts.dry_run);
    try std.testing.expectEqualStrings("foo.txt", opts.common.file_filter.items[0]);
    try std.testing.expectEqual(OutputMode.porcelain, opts.common.output);
    try std.testing.expect(opts.common.no_color);
    try std.testing.expectEqual(@as(?u32, 1), opts.common.context);
}

test "parseRestoreArgs bare file flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--file", "src/main.zig" };
    var opts = try parseRestoreArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, &opts.common.file_filter);
    try std.testing.expectEqualStrings("src/main.zig", opts.common.file_filter.items[0]);
    try std.testing.expectEqual(@as(usize, 0), opts.sha_args.items.len);
}

test "parseStashArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{"abcd1234"};
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expect(std.mem.startsWith(u8, opts.sha_args.items[0].prefix, "abcd1234"));
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

test "parseStashArgs bare file flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--file", "src/main.zig" };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, &opts.common.file_filter);
    try std.testing.expectEqualStrings("src/main.zig", opts.common.file_filter.items[0]);
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

test "parseListArgs --ref with --staged allowed for single ref" {
    const args_arr = [_][:0]const u8{ "--ref", "HEAD", "--staged" };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqualStrings("HEAD", opts.common.ref.?);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseListArgs --ref range with --staged rejected" {
    const args_arr = [_][:0]const u8{ "--ref", "main..HEAD", "--staged" };
    try std.testing.expectError(error.InvalidArgument, parseListArgs(std.testing.allocator, &args_arr));
}

test "parseListArgs --ref range without --staged allowed" {
    const args_arr = [_][:0]const u8{ "--ref", "main..HEAD" };
    const opts = try parseListArgs(std.testing.allocator, &args_arr);
    try std.testing.expectEqualStrings("main..HEAD", opts.common.ref.?);
    try std.testing.expectEqual(DiffMode.unstaged, opts.mode);
}

test "parseStashArgs --ref rejected" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--all", "--ref", "main" };
    try std.testing.expectError(error.InvalidArgument, parseStashArgs(allocator, &args_arr));
}

test "parseDiffArgs --ref range with --staged rejected" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "abcd1234", "--ref", "main..HEAD", "--staged" };
    try std.testing.expectError(error.InvalidArgument, parseDiffArgs(allocator, &args_arr));
}

test "parseCountArgs --ref range with --staged rejected" {
    const args_arr = [_][:0]const u8{ "--ref", "main..HEAD", "--staged" };
    try std.testing.expectError(error.InvalidArgument, parseCountArgs(std.testing.allocator, &args_arr));
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
    defer deinitFileFilter(allocator, &opts.common.file_filter);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expect(opts.select_all);
    try std.testing.expect(opts.amend);
    try std.testing.expect(opts.dry_run);
    try std.testing.expectEqualStrings("foo.txt", opts.common.file_filter.items[0]);
    try std.testing.expectEqual(OutputMode.porcelain, opts.common.output);
    try std.testing.expect(opts.common.no_color);
    try std.testing.expectEqual(@as(?u32, 1), opts.common.context);
    try std.testing.expectEqualStrings("feat: everything", opts.message.?);
}

test "parseCommitArgs --file without sha allowed" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]const u8{ "--file", "src/main.zig", "-m", "msg" };
    var opts = try parseCommitArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    defer deinitFileFilter(allocator, &opts.common.file_filter);
    try std.testing.expectEqualStrings("src/main.zig", opts.common.file_filter.items[0]);
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

test "deinitFileFilter no-op on empty list" {
    var list: std.ArrayList([]const u8) = .empty;
    deinitFileFilter(std.testing.allocator, &list);
}

test "deinitFileFilter frees owned entries and the list" {
    const allocator = std.testing.allocator;
    // Entries must be owned copies: deinitFileFilter frees each one, and
    // freeing a string literal aborts.
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(allocator, try allocator.dupe(u8, "a.txt"));
    try list.append(allocator, try allocator.dupe(u8, "b.txt"));
    deinitFileFilter(allocator, &list);
}

test "parseListArgs leaks no memory when --file then --staged with range ref" {
    // The argument loop succeeds; validateRefStagedCombo fails after it.
    const args_arr = [_][:0]const u8{ "--file", "a.txt", "--ref", "main..HEAD", "--staged" };
    try std.testing.expectError(error.InvalidArgument, parseListArgs(std.testing.allocator, &args_arr));
}

// ============================================================================
// Common-flag tests: every parser shares parseCommonFlag, so each common flag
// is asserted once per parser from this table instead of copied per parser.
// ============================================================================

/// `base` is the least a parser needs to succeed, so each case can append the
/// flag under test. `ref` and `three_way` record whether the parser keeps the
/// flag or rejects it after parsing.
const common_flag_cases = .{
    .{ .name = "list", .parse = parseListArgs, .base = [_][:0]const u8{}, .ref = true, .three_way = false },
    .{ .name = "add/reset", .parse = parseAddResetArgs, .base = [_][:0]const u8{"--all"}, .ref = true, .three_way = true },
    .{ .name = "diff", .parse = parseDiffArgs, .base = [_][:0]const u8{"abcd1234"}, .ref = true, .three_way = false },
    .{ .name = "count", .parse = parseCountArgs, .base = [_][:0]const u8{}, .ref = true, .three_way = false },
    .{ .name = "check", .parse = parseCheckArgs, .base = [_][:0]const u8{"abcd1234"}, .ref = true, .three_way = false },
    .{ .name = "restore", .parse = parseRestoreArgs, .base = [_][:0]const u8{"--all"}, .ref = true, .three_way = true },
    .{ .name = "stash", .parse = parseStashArgs, .base = [_][:0]const u8{"--all"}, .ref = false, .three_way = false },
    .{ .name = "commit", .parse = parseCommitArgs, .base = [_][:0]const u8{ "--all", "-m", "msg" }, .ref = true, .three_way = true },
};

fn ParseResult(comptime case: anytype) type {
    return @typeInfo(@TypeOf(case.parse)).@"fn".return_type.?;
}

fn parseCase(comptime case: anytype, comptime extra: []const [:0]const u8) ParseResult(case) {
    const argv = case.base ++ extra[0..extra.len].*;
    return case.parse(std.testing.allocator, &argv);
}

fn expectCommonField(comptime case: anytype, comptime extra: []const [:0]const u8, comptime field: []const u8, expected: anytype) !void {
    var opts = try parseCase(case, extra);
    defer deinitOptions(std.testing.allocator, &opts);
    const actual = @field(opts.common, field);
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

fn expectCommonFlags(comptime case: anytype) !void {
    const t = std.testing;
    {
        var opts = try parseCase(case, &.{});
        defer deinitOptions(t.allocator, &opts);
        try t.expectEqual(OutputMode.human, opts.common.output);
        try t.expect(!opts.common.no_color);
        try t.expectEqual(@as(usize, 0), opts.common.file_filter.items.len);
        try t.expectEqual(@as(?[]const u8, null), opts.common.ref);
        try t.expectEqual(types.DiffFilter.all, opts.common.diff_filter);
        try t.expectEqual(@as(?u32, null), opts.common.context);
        try t.expectEqual(types.Verbosity.normal, opts.common.verbosity);
        try t.expect(!opts.common.three_way);
    }

    try t.expectError(error.HelpRequested, parseCase(case, &.{"--help"}));
    try t.expectError(error.HelpRequested, parseCase(case, &.{"-h"}));

    try expectCommonField(case, &.{"--porcelain"}, "output", .porcelain);
    try expectCommonField(case, &.{"--no-color"}, "no_color", true);

    try expectCommonField(case, &.{ "--unified", "5" }, "context", 5);
    try expectCommonField(case, &.{ "--unified", "0" }, "context", 0);
    try expectCommonField(case, &.{"--unified=5"}, "context", 5);
    try expectCommonField(case, &.{ "-U", "3" }, "context", 3);
    try expectCommonField(case, &.{"-U3"}, "context", 3);
    try expectCommonField(case, &.{"-U0"}, "context", 0);
    try t.expectError(error.MissingArgument, parseCase(case, &.{"--unified"}));
    try t.expectError(error.MissingArgument, parseCase(case, &.{"-U"}));
    try t.expectError(error.InvalidArgument, parseCase(case, &.{ "--unified", "abc" }));
    try t.expectError(error.InvalidArgument, parseCase(case, &.{"--unified=abc"}));
    try t.expectError(error.InvalidArgument, parseCase(case, &.{"-Uabc"}));

    try expectCommonField(case, &.{"--quiet"}, "verbosity", .quiet);
    try expectCommonField(case, &.{"-q"}, "verbosity", .quiet);
    try expectCommonField(case, &.{"--verbose"}, "verbosity", .verbose);
    try expectCommonField(case, &.{"-v"}, "verbosity", .verbose);
    try t.expectError(error.ConflictingVerbosity, parseCase(case, &.{ "--quiet", "--verbose" }));
    try t.expectError(error.ConflictingVerbosity, parseCase(case, &.{ "--verbose", "--quiet" }));

    try expectCommonField(case, &.{"--tracked-only"}, "diff_filter", .tracked_only);
    try expectCommonField(case, &.{"--untracked-only"}, "diff_filter", .untracked_only);
    try t.expectError(error.ConflictingFilter, parseCase(case, &.{ "--tracked-only", "--untracked-only" }));

    {
        var opts = try parseCase(case, &.{ "--file", "src/main.zig" });
        defer deinitOptions(t.allocator, &opts);
        try t.expectEqual(@as(usize, 1), opts.common.file_filter.items.len);
        try t.expectEqualStrings("src/main.zig", opts.common.file_filter.items[0]);
    }
    {
        var opts = try parseCase(case, &.{ "--file", "foo.txt", "--file", "bar.txt" });
        defer deinitOptions(t.allocator, &opts);
        try t.expectEqual(@as(usize, 2), opts.common.file_filter.items.len);
        try t.expectEqualStrings("foo.txt", opts.common.file_filter.items[0]);
        try t.expectEqualStrings("bar.txt", opts.common.file_filter.items[1]);
    }
    try t.expectError(error.MissingArgument, parseCase(case, &.{"--file"}));
    // std.testing.allocator fails the test if the accumulated paths leak
    // when a later argument errors.
    try t.expectError(error.UnknownFlag, parseCase(case, &.{ "--file", "a.txt", "--file", "b.txt", "--unknown" }));

    try t.expectError(error.MissingArgument, parseCase(case, &.{"--ref"}));
    if (case.ref) {
        var opts = try parseCase(case, &.{ "--ref", "main" });
        defer deinitOptions(t.allocator, &opts);
        try t.expectEqualStrings("main", opts.common.ref.?);
    } else {
        try t.expectError(error.InvalidArgument, parseCase(case, &.{ "--ref", "main" }));
    }

    if (case.three_way) {
        try expectCommonField(case, &.{"--3way"}, "three_way", true);
    } else {
        try t.expectError(error.UnknownFlag, parseCase(case, &.{"--3way"}));
    }
}

test "common flags parse identically for every command" {
    inline for (common_flag_cases) |case| {
        errdefer std.debug.print("common-flag case failed for: {s}\n", .{case.name});
        try expectCommonFlags(case);
    }
}
