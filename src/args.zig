const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const LineRange = types.LineRange;
const LineSpec = types.LineSpec;
const ShaArg = types.ShaArg;
const DiffMode = types.DiffMode;
const OutputMode = types.OutputMode;
const ListOptions = types.ListOptions;
const AddRemoveOptions = types.AddRemoveOptions;
const ShowOptions = types.ShowOptions;
const CountOptions = types.CountOptions;
const CheckOptions = types.CheckOptions;
const DiscardOptions = types.DiscardOptions;
const StashOptions = types.StashOptions;

pub fn parseListArgs(args: []const [:0]u8) !ListOptions {
    var opts: ListOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--porcelain")) {
            opts.output = .porcelain;
        } else if (std.mem.eql(u8, arg, "--oneline")) {
            opts.oneline = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.file_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--context")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.context = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArgument;
        } else {
            return error.UnknownFlag;
        }
    }
    return opts;
}

pub fn parseAddRemoveArgs(allocator: Allocator, args: []const [:0]u8) !AddRemoveOptions {
    var opts: AddRemoveOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.file_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.eql(u8, arg, "--porcelain")) {
            opts.output = .porcelain;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, arg, "--context")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.context = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
            try opts.sha_args.append(allocator, sha_arg);
        }
    }

    if (opts.sha_args.items.len == 0 and !opts.select_all and opts.file_filter == null) {
        std.debug.print("error: at least one <sha> argument required (or use --all or --file <path>)\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

pub fn parseShowArgs(allocator: Allocator, args: []const [:0]u8) !ShowOptions {
    var opts: ShowOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.file_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--porcelain")) {
            opts.output = .porcelain;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, arg, "--context")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.context = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
            try opts.sha_args.append(allocator, sha_arg);
        }
    }

    if (opts.sha_args.items.len == 0) {
        std.debug.print("error: at least one <sha> argument required\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

pub fn parseCountArgs(args: []const [:0]u8) !CountOptions {
    var opts: CountOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--porcelain") or std.mem.eql(u8, arg, "--no-color")) {
            // Accepted for consistency, no effect
        } else if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.file_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--context")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.context = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArgument;
        } else {
            if (std.mem.startsWith(u8, arg, "-")) {
                return error.UnknownFlag;
            }
            std.debug.print("error: count does not accept arguments\n", .{});
            return error.InvalidArgument;
        }
    }
    return opts;
}

pub fn parseCheckArgs(allocator: Allocator, args: []const [:0]u8) !CheckOptions {
    var opts: CheckOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--staged")) {
            opts.mode = .staged;
        } else if (std.mem.eql(u8, arg, "--exclusive")) {
            opts.exclusive = true;
        } else if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.file_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--porcelain")) {
            opts.output = .porcelain;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, arg, "--context")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.context = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
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

    if (opts.sha_args.items.len == 0) {
        std.debug.print("error: at least one <sha> argument required\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

pub fn parseDiscardArgs(allocator: Allocator, args: []const [:0]u8) !DiscardOptions {
    var opts: DiscardOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.file_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "--porcelain")) {
            opts.output = .porcelain;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, arg, "--context")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.context = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            const sha_arg = parseShaArg(allocator, arg) catch return error.InvalidArgument;
            try opts.sha_args.append(allocator, sha_arg);
        }
    }

    if (opts.sha_args.items.len == 0 and !opts.select_all and opts.file_filter == null) {
        std.debug.print("error: at least one <sha> argument required (or use --all or --file <path>)\n", .{});
        return error.MissingArgument;
    }

    return opts;
}

pub fn parseStashArgs(allocator: Allocator, args: []const [:0]u8) !StashOptions {
    var opts: StashOptions = .{
        .sha_args = .empty,
    };
    errdefer deinitShaArgs(allocator, &opts.sha_args);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.file_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--all")) {
            opts.select_all = true;
        } else if (std.mem.eql(u8, arg, "--pop")) {
            opts.pop = true;
        } else if (std.mem.eql(u8, arg, "--message") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.message = args[i];
        } else if (std.mem.eql(u8, arg, "--porcelain")) {
            opts.output = .porcelain;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, arg, "--context")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.context = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
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

    if (opts.pop) {
        if (opts.sha_args.items.len > 0) {
            std.debug.print("error: --pop cannot be combined with sha arguments\n", .{});
            return error.InvalidArgument;
        }
        if (opts.select_all) {
            std.debug.print("error: --pop cannot be combined with --all\n", .{});
            return error.InvalidArgument;
        }
        if (opts.file_filter != null) {
            std.debug.print("error: --pop cannot be combined with --file\n", .{});
            return error.InvalidArgument;
        }
        if (opts.message != null) {
            std.debug.print("error: --pop cannot be combined with --message\n", .{});
            return error.InvalidArgument;
        }
    }

    if (!opts.pop and opts.sha_args.items.len == 0 and !opts.select_all and opts.file_filter == null) {
        std.debug.print("error: at least one <sha> argument required (or use --all, --file <path>, or --pop)\n", .{});
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
    const opts = try parseListArgs(&.{});
    try std.testing.expectEqual(DiffMode.unstaged, opts.mode);
    try std.testing.expectEqual(OutputMode.human, opts.output);
    try std.testing.expect(!opts.oneline);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.file_filter);
}

test "parseListArgs staged" {
    const args_arr = [_][:0]u8{@constCast("--staged")};
    const opts = try parseListArgs(&args_arr);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseListArgs porcelain" {
    const args_arr = [_][:0]u8{@constCast("--porcelain")};
    const opts = try parseListArgs(&args_arr);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
}

test "parseListArgs oneline" {
    const args_arr = [_][:0]u8{@constCast("--oneline")};
    const opts = try parseListArgs(&args_arr);
    try std.testing.expect(opts.oneline);
}

test "parseListArgs no-color" {
    const args_arr = [_][:0]u8{@constCast("--no-color")};
    const opts = try parseListArgs(&args_arr);
    try std.testing.expect(opts.no_color);
}

test "parseListArgs file filter" {
    const args_arr = [_][:0]u8{ @constCast("--file"), @constCast("src/main.zig") };
    const opts = try parseListArgs(&args_arr);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter.?);
}

test "parseListArgs file missing arg" {
    const args_arr = [_][:0]u8{@constCast("--file")};
    try std.testing.expectError(error.MissingArgument, parseListArgs(&args_arr));
}

test "parseListArgs unknown flag" {
    const args_arr = [_][:0]u8{@constCast("--unknown")};
    try std.testing.expectError(error.UnknownFlag, parseListArgs(&args_arr));
}

test "parseListArgs all flags combined" {
    const args_arr = [_][:0]u8{
        @constCast("--staged"),
        @constCast("--porcelain"),
        @constCast("--oneline"),
        @constCast("--no-color"),
        @constCast("--file"),
        @constCast("foo.txt"),
    };
    const opts = try parseListArgs(&args_arr);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
    try std.testing.expect(opts.oneline);
    try std.testing.expect(opts.no_color);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter.?);
}

test "parseListArgs context" {
    const args_arr = [_][:0]u8{ @constCast("--context"), @constCast("0") };
    const opts = try parseListArgs(&args_arr);
    try std.testing.expectEqual(@as(?u32, 0), opts.context);
}

test "parseListArgs context value" {
    const args_arr = [_][:0]u8{ @constCast("--context"), @constCast("5") };
    const opts = try parseListArgs(&args_arr);
    try std.testing.expectEqual(@as(?u32, 5), opts.context);
}

test "parseListArgs context missing arg" {
    const args_arr = [_][:0]u8{@constCast("--context")};
    try std.testing.expectError(error.MissingArgument, parseListArgs(&args_arr));
}

test "parseListArgs context invalid" {
    const args_arr = [_][:0]u8{ @constCast("--context"), @constCast("abc") };
    try std.testing.expectError(error.InvalidArgument, parseListArgs(&args_arr));
}

test "parseListArgs context default null" {
    const opts = try parseListArgs(&.{});
    try std.testing.expectEqual(@as(?u32, null), opts.context);
}

test "parseAddRemoveArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("abcd1234")};
    var opts = try parseAddRemoveArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expectEqualStrings("abcd1234", opts.sha_args.items[0].prefix);
    try std.testing.expectEqual(@as(?LineSpec, null), opts.sha_args.items[0].line_spec);
}

test "parseAddRemoveArgs too short sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("abc")};
    try std.testing.expectError(error.InvalidArgument, parseAddRemoveArgs(allocator, &args_arr));
}

test "parseAddRemoveArgs non-hex sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("xyzw1234")};
    try std.testing.expectError(error.InvalidArgument, parseAddRemoveArgs(allocator, &args_arr));
}

test "parseAddRemoveArgs missing sha" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parseAddRemoveArgs(allocator, &.{}));
}

test "parseAddRemoveArgs select all" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("--all")};
    var opts = try parseAddRemoveArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.select_all);
}

test "parseAddRemoveArgs no-color" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--no-color") };
    var opts = try parseAddRemoveArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.no_color);
}

test "parseAddRemoveArgs with file flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{
        @constCast("abcd1234"),
        @constCast("--file"),
        @constCast("src/main.zig"),
    };
    var opts = try parseAddRemoveArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter.?);
}

test "parseAddRemoveArgs multiple shas" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{
        @constCast("abcd1234"),
        @constCast("ef567890"),
    };
    var opts = try parseAddRemoveArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 2), opts.sha_args.items.len);
}

test "parseAddRemoveArgs context" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--context"), @constCast("1") };
    var opts = try parseAddRemoveArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(?u32, 1), opts.context);
}

test "parseAddRemoveArgs context missing arg" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--context") };
    try std.testing.expectError(error.MissingArgument, parseAddRemoveArgs(allocator, &args_arr));
}

test "parseShowArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("abcd1234")};
    var opts = try parseShowArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
}

test "parseShowArgs staged flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--staged") };
    var opts = try parseShowArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseShowArgs porcelain flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--porcelain") };
    var opts = try parseShowArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
}

test "parseShowArgs no-color flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--no-color") };
    var opts = try parseShowArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.no_color);
}

test "parseShowArgs unknown flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--unknown") };
    try std.testing.expectError(error.UnknownFlag, parseShowArgs(allocator, &args_arr));
}

test "parseShowArgs missing sha" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parseShowArgs(allocator, &.{}));
}

test "parseShowArgs context" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--context"), @constCast("2") };
    var opts = try parseShowArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(?u32, 2), opts.context);
}

test "parseShowArgs context missing arg" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--context") };
    try std.testing.expectError(error.MissingArgument, parseShowArgs(allocator, &args_arr));
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

test "parseAddRemoveArgs sha with line spec" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("abcd1234:3-5")};
    var opts = try parseAddRemoveArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expectEqualStrings("abcd1234", opts.sha_args.items[0].prefix);
    try std.testing.expect(opts.sha_args.items[0].line_spec != null);
    try std.testing.expectEqual(@as(u32, 3), opts.sha_args.items[0].line_spec.?.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 5), opts.sha_args.items[0].line_spec.?.ranges[0].end);
}

test "parseShowArgs sha with line spec" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("abcd1234:1-3,7")};
    var opts = try parseShowArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expect(opts.sha_args.items[0].line_spec != null);
    try std.testing.expectEqual(@as(usize, 2), opts.sha_args.items[0].line_spec.?.ranges.len);
}

test "parseCountArgs defaults" {
    const opts = try parseCountArgs(&.{});
    try std.testing.expectEqual(DiffMode.unstaged, opts.mode);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.file_filter);
    try std.testing.expectEqual(@as(?u32, null), opts.context);
}

test "parseCountArgs staged" {
    const args_arr = [_][:0]u8{@constCast("--staged")};
    const opts = try parseCountArgs(&args_arr);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseCountArgs file filter" {
    const args_arr = [_][:0]u8{ @constCast("--file"), @constCast("src/main.zig") };
    const opts = try parseCountArgs(&args_arr);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter.?);
}

test "parseCountArgs context" {
    const args_arr = [_][:0]u8{ @constCast("--context"), @constCast("5") };
    const opts = try parseCountArgs(&args_arr);
    try std.testing.expectEqual(@as(?u32, 5), opts.context);
}

test "parseCountArgs porcelain accepted silently" {
    const opts = try parseCountArgs(&[_][:0]u8{@constCast("--porcelain")});
    try std.testing.expectEqual(DiffMode.unstaged, opts.mode);
}

test "parseCountArgs no-color accepted silently" {
    const opts = try parseCountArgs(&[_][:0]u8{@constCast("--no-color")});
    try std.testing.expectEqual(DiffMode.unstaged, opts.mode);
}

test "parseCountArgs rejects positional args" {
    const args_arr = [_][:0]u8{@constCast("abcd1234")};
    try std.testing.expectError(error.InvalidArgument, parseCountArgs(&args_arr));
}

test "parseCountArgs rejects unknown flags" {
    const args_arr = [_][:0]u8{@constCast("--unknown")};
    try std.testing.expectError(error.UnknownFlag, parseCountArgs(&args_arr));
}

test "parseCountArgs file missing arg" {
    const args_arr = [_][:0]u8{@constCast("--file")};
    try std.testing.expectError(error.MissingArgument, parseCountArgs(&args_arr));
}

test "parseCountArgs context missing arg" {
    const args_arr = [_][:0]u8{@constCast("--context")};
    try std.testing.expectError(error.MissingArgument, parseCountArgs(&args_arr));
}

test "parseCountArgs all flags combined" {
    const args_arr = [_][:0]u8{
        @constCast("--staged"),
        @constCast("--file"),
        @constCast("foo.txt"),
        @constCast("--context"),
        @constCast("3"),
        @constCast("--porcelain"),
        @constCast("--no-color"),
    };
    const opts = try parseCountArgs(&args_arr);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter.?);
    try std.testing.expectEqual(@as(?u32, 3), opts.context);
}

test "parseCheckArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("abcd1234")};
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expectEqualStrings("abcd1234", opts.sha_args.items[0].prefix);
    try std.testing.expectEqual(@as(?types.LineSpec, null), opts.sha_args.items[0].line_spec);
}

test "parseCheckArgs staged flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--staged") };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
}

test "parseCheckArgs exclusive flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--exclusive") };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.exclusive);
}

test "parseCheckArgs porcelain flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--porcelain") };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
}

test "parseCheckArgs no-color flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--no-color") };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.no_color);
}

test "parseCheckArgs file filter" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--file"), @constCast("src/main.zig") };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter.?);
}

test "parseCheckArgs context" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--context"), @constCast("2") };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(?u32, 2), opts.context);
}

test "parseCheckArgs multiple shas" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("ef567890") };
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
    const args_arr = [_][:0]u8{@constCast("abcd1234:3-5")};
    try std.testing.expectError(error.InvalidArgument, parseCheckArgs(allocator, &args_arr));
}

test "parseCheckArgs rejects unknown flags" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--unknown") };
    try std.testing.expectError(error.UnknownFlag, parseCheckArgs(allocator, &args_arr));
}

test "parseCheckArgs all flags combined" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{
        @constCast("abcd1234"),
        @constCast("--staged"),
        @constCast("--exclusive"),
        @constCast("--file"),
        @constCast("foo.txt"),
        @constCast("--porcelain"),
        @constCast("--no-color"),
        @constCast("--context"),
        @constCast("1"),
    };
    var opts = try parseCheckArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(DiffMode.staged, opts.mode);
    try std.testing.expect(opts.exclusive);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter.?);
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

test "parseDiscardArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("abcd1234")};
    var opts = try parseDiscardArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(usize, 1), opts.sha_args.items.len);
    try std.testing.expectEqualStrings("abcd1234", opts.sha_args.items[0].prefix);
    try std.testing.expect(!opts.dry_run);
}

test "parseDiscardArgs missing sha" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parseDiscardArgs(allocator, &.{}));
}

test "parseDiscardArgs select all" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("--all")};
    var opts = try parseDiscardArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.select_all);
}

test "parseDiscardArgs dry-run" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--dry-run") };
    var opts = try parseDiscardArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.dry_run);
}

test "parseDiscardArgs file filter" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--file"), @constCast("src/main.zig") };
    var opts = try parseDiscardArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter.?);
}

test "parseDiscardArgs porcelain" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--porcelain") };
    var opts = try parseDiscardArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
}

test "parseDiscardArgs no-color" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--no-color") };
    var opts = try parseDiscardArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.no_color);
}

test "parseDiscardArgs context" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--context"), @constCast("2") };
    var opts = try parseDiscardArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(?u32, 2), opts.context);
}

test "parseDiscardArgs rejects unknown flags" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--staged") };
    try std.testing.expectError(error.UnknownFlag, parseDiscardArgs(allocator, &args_arr));
}

test "parseDiscardArgs all flags combined" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{
        @constCast("abcd1234"),
        @constCast("--all"),
        @constCast("--dry-run"),
        @constCast("--file"),
        @constCast("foo.txt"),
        @constCast("--porcelain"),
        @constCast("--no-color"),
        @constCast("--context"),
        @constCast("1"),
    };
    var opts = try parseDiscardArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.select_all);
    try std.testing.expect(opts.dry_run);
    try std.testing.expectEqualStrings("foo.txt", opts.file_filter.?);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
    try std.testing.expect(opts.no_color);
    try std.testing.expectEqual(@as(?u32, 1), opts.context);
}

test "parseDiscardArgs bare file flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--file"), @constCast("src/main.zig") };
    var opts = try parseDiscardArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter.?);
    try std.testing.expectEqual(@as(usize, 0), opts.sha_args.items.len);
}

test "parseStashArgs valid sha" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("abcd1234")};
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
    const args_arr = [_][:0]u8{@constCast("--all")};
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.select_all);
}

test "parseStashArgs pop flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("--pop")};
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.pop);
}

test "parseStashArgs message long flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--message"), @constCast("my stash") };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("my stash", opts.message.?);
}

test "parseStashArgs message short flag" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("-m"), @constCast("my stash") };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("my stash", opts.message.?);
}

test "parseStashArgs message missing value" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--message") };
    try std.testing.expectError(error.MissingArgument, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs file filter" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--file"), @constCast("src/main.zig") };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqualStrings("src/main.zig", opts.file_filter.?);
}

test "parseStashArgs porcelain" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--porcelain") };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(OutputMode.porcelain, opts.output);
}

test "parseStashArgs no-color" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--no-color") };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expect(opts.no_color);
}

test "parseStashArgs context" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--all"), @constCast("--context"), @constCast("2") };
    var opts = try parseStashArgs(allocator, &args_arr);
    defer deinitShaArgs(allocator, &opts.sha_args);
    try std.testing.expectEqual(@as(?u32, 2), opts.context);
}

test "parseStashArgs rejects unknown flags" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("abcd1234"), @constCast("--staged") };
    try std.testing.expectError(error.UnknownFlag, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs rejects line specs" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{@constCast("abcd1234:3-5")};
    try std.testing.expectError(error.InvalidArgument, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs pop rejects sha args" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--pop"), @constCast("abcd1234") };
    try std.testing.expectError(error.InvalidArgument, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs pop rejects --all" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--pop"), @constCast("--all") };
    try std.testing.expectError(error.InvalidArgument, parseStashArgs(allocator, &args_arr));
}

test "parseStashArgs pop rejects --message" {
    const allocator = std.testing.allocator;
    const args_arr = [_][:0]u8{ @constCast("--pop"), @constCast("-m"), @constCast("msg") };
    try std.testing.expectError(error.InvalidArgument, parseStashArgs(allocator, &args_arr));
}
