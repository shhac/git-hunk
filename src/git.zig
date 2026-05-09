const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const DiffMode = types.DiffMode;
const fatal = types.fatal;

const defaultIo = types.getIo;

/// Trim a trailing newline from `owned` (allocated by `allocator`) and shrink
/// the allocation if needed. Takes ownership: caller must not free `owned`.
fn trimAndShrink(allocator: Allocator, owned: []u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, owned, "\n");
    if (trimmed.len == owned.len) return owned;
    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return duped;
}

const RunOpts = struct {
    stdin_data: ?[]const u8 = null,
    env_map: ?*const EnvMap = null,
    max_bytes: usize = 1 * 1024 * 1024,
};

const RunResult = struct {
    stdout: []u8,
    exit_code: u8,
    stderr: []u8,
};

/// Core subprocess runner. Spawns a git command, optionally writes stdin,
/// collects stdout/stderr, and returns the result. Caller owns stdout/stderr.
fn runCommand(allocator: Allocator, argv: []const []const u8, opts: RunOpts) !RunResult {
    const io = defaultIo();
    if (opts.stdin_data == null) {
        const result = std.process.run(allocator, io, .{
            .argv = argv,
            .environ_map = opts.env_map,
            .stdout_limit = .limited(opts.max_bytes),
            .stderr_limit = .limited(opts.max_bytes),
        }) catch |err| {
            if (err == error.StreamTooLong) {
                std.debug.print("error: output exceeds {d} MB -- use --file to narrow scope\n", .{opts.max_bytes / (1024 * 1024)});
                std.process.exit(1);
            }
            return err;
        };
        const exit_code: u8 = switch (result.term) {
            .exited => |code| code,
            else => {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
                return error.AbnormalTermination;
            },
        };
        return .{ .stdout = result.stdout, .exit_code = exit_code, .stderr = result.stderr };
    }

    // stdin path: spawn manually so we can pipe in stdin_data, then drain stdout/stderr.
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = opts.env_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    child.stdin.?.writeStreamingAll(io, opts.stdin_data.?) catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(allocator, io, multi_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();

    while (multi.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi.toOwnedSlice(1);
    errdefer allocator.free(stderr_slice);

    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        else => {
            allocator.free(stdout_slice);
            allocator.free(stderr_slice);
            return error.AbnormalTermination;
        },
    };

    return .{ .stdout = stdout_slice, .exit_code = exit_code, .stderr = stderr_slice };
}

/// Run a git command that returns trimmed stdout. Fatal on non-zero exit.
fn runGitCapture(allocator: Allocator, argv: []const []const u8, opts: RunOpts, label: []const u8) ![]u8 {
    const result = try runCommand(allocator, argv, opts);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        fatal("{s} exited with code {d}", .{ label, result.exit_code });
    }

    return trimAndShrink(allocator, result.stdout);
}

pub fn runGitDiff(allocator: Allocator, mode: DiffMode, ref: ?[]const u8, context: ?u32) ![]u8 {
    return runGitDiffFiles(allocator, mode, ref, context, &.{});
}

/// Like runGitDiff but scoped to specific file paths via `-- file1 file2 ...`.
/// Pass an empty slice for no file filter (equivalent to runGitDiff).
pub fn runGitDiffFiles(allocator: Allocator, mode: DiffMode, ref: ?[]const u8, context: ?u32, file_paths: []const []const u8) ![]u8 {
    // Base args: git diff [--cached] [ref..] [-U<n>] --src-prefix=a/ --dst-prefix=b/ --no-color [-- file1 ...]
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "diff" });
    if (mode == .staged) try argv.append(allocator, "--cached");
    if (ref) |r| {
        // Pass the ref through verbatim. Git diff understands single refs, two-dot
        // ranges (A..B), and three-dot symmetric difference (A...B); the previous
        // implementation hand-split on `..` and corrupted A...B and A.. forms.
        try argv.append(allocator, r);
    }
    var context_buf: [16]u8 = undefined;
    if (context) |ctx| {
        try argv.append(allocator, std.fmt.bufPrint(&context_buf, "-U{d}", .{ctx}) catch "-U0");
    }
    try argv.appendSlice(allocator, &.{ "--src-prefix=a/", "--dst-prefix=b/", "--no-color", "--full-index" });
    if (file_paths.len > 0) {
        try argv.append(allocator, "--");
        try argv.appendSlice(allocator, file_paths);
    }

    const result = try runCommand(allocator, argv.items, .{ .max_bytes = 10 * 1024 * 1024 });
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        fatal("git diff exited with code {d}", .{result.exit_code});
    }
    return result.stdout;
}

pub const ApplyTarget = enum { index, worktree };

pub const ApplyOptions = struct {
    reverse: bool = false,
    target: ApplyTarget = .index,
    check_only: bool = false,
    /// Pass `--3way` to git apply: fall back to a 3-way merge (with conflict
    /// markers in the worktree) when the patch context doesn't apply cleanly.
    /// Useful for cherry-picking or reverting hunks from far enough back that
    /// surrounding lines have drifted. Implies `target=.worktree` semantics for
    /// conflict markers; git apply will refuse `--3way` with `--cached` only.
    three_way: bool = false,
    /// User-supplied `--ref` value for the failure message (so the user knows
    /// which historical diff conflicted). Null means "current diff".
    ref: ?[]const u8 = null,
};

pub fn runGitApply(allocator: Allocator, patch: []const u8, opts: ApplyOptions) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "apply" });
    if (opts.target == .index) try argv.append(allocator, "--cached");
    if (opts.reverse) try argv.append(allocator, "--reverse");
    try argv.append(allocator, "--unidiff-zero");
    if (opts.check_only) try argv.append(allocator, "--check");
    if (opts.three_way) try argv.append(allocator, "--3way");

    const result = runCommand(allocator, argv.items, .{ .stdin_data = patch }) catch |err| {
        if (err == error.AbnormalTermination) {
            std.debug.print("error: git apply terminated abnormally\n", .{});
            return error.PatchFailed;
        }
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        if (opts.ref) |r| {
            std.debug.print("error: patch did not apply cleanly — the diff from '{s}' may conflict with the current state (try --3way)\n", .{r});
        } else if (opts.check_only) {
            std.debug.print("error: patch would not apply cleanly — hashes may be stale\n", .{});
        } else {
            std.debug.print("error: patch did not apply cleanly — re-run 'list' and try again\n", .{});
        }
        return error.PatchFailed;
    }
}

/// Stage files by path: `git add -- path1 path2 ...`
pub fn runGitAddFiles(allocator: Allocator, file_paths: []const []const u8) !void {
    const out = try runGitFileCmd(allocator, &.{ "git", "add" }, file_paths, .{}, "git add");
    allocator.free(out);
}

/// Unstage files: `git reset HEAD -- path1 path2 ...`
pub fn runGitResetFiles(allocator: Allocator, file_paths: []const []const u8) !void {
    const out = try runGitFileCmd(allocator, &.{ "git", "reset", "HEAD" }, file_paths, .{}, "git reset");
    allocator.free(out);
}

/// Restore files from index: `git checkout -- path1 path2 ...`
pub fn runGitCheckoutFiles(allocator: Allocator, file_paths: []const []const u8) !void {
    const out = try runGitFileCmd(allocator, &.{ "git", "checkout" }, file_paths, .{}, "git checkout");
    allocator.free(out);
}

/// Stage files by path with a custom environment (for temp index).
pub fn runGitAddFilesWithEnv(allocator: Allocator, file_paths: []const []const u8, env_map: *const EnvMap) !void {
    const out = try runGitFileCmd(allocator, &.{ "git", "add" }, file_paths, .{ .env_map = env_map }, "git add");
    allocator.free(out);
}

/// Build argv as `prefix... -- file_paths...` and run via runGitCapture.
fn runGitFileCmd(allocator: Allocator, prefix: []const []const u8, file_paths: []const []const u8, opts: RunOpts, label: []const u8) ![]u8 {
    const argv_buf = try allocator.alloc([]const u8, prefix.len + 1 + file_paths.len);
    defer allocator.free(argv_buf);
    @memcpy(argv_buf[0..prefix.len], prefix);
    argv_buf[prefix.len] = "--";
    @memcpy(argv_buf[prefix.len + 1 ..], file_paths);
    return runGitCapture(allocator, argv_buf, opts, label);
}

/// Generate diff output for untracked files using `git diff --no-index`.
/// The output matches the standard `git diff` format expected by parseDiff.
/// Only files matching `file_filter` are included (empty slice = all untracked files).
/// Allocates the result with `allocator`; caller must free the returned slice.
pub fn diffUntrackedFiles(allocator: Allocator, file_filter: []const []const u8) ![]u8 {
    // Get list of untracked file paths
    const ls_argv: []const []const u8 = &.{ "git", "ls-files", "--others", "--exclude-standard" };

    const ls_result = try runCommand(allocator, ls_argv, .{});
    defer allocator.free(ls_result.stdout);
    defer allocator.free(ls_result.stderr);
    if (ls_result.exit_code != 0) return try allocator.alloc(u8, 0);

    const ls_output = std.mem.trimEnd(u8, ls_result.stdout, "\n");
    if (ls_output.len == 0) return try allocator.alloc(u8, 0);

    // Collect diffs for each untracked file
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var iter = std.mem.splitScalar(u8, ls_output, '\n');
    while (iter.next()) |file_path| {
        if (file_path.len == 0) continue;

        // Apply file filter
        if (!types.matchesFileFilter(file_path, file_filter)) continue;

        const diff = diffSingleUntrackedFile(allocator, file_path) catch continue;
        defer allocator.free(diff);

        if (diff.len > 0) {
            try result.appendSlice(allocator, diff);
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Run `git diff --no-index --src-prefix=a/ --dst-prefix=b/ --no-color -- /dev/null <file>`
/// for a single untracked file. Exit code 1 is expected (differences found).
fn diffSingleUntrackedFile(allocator: Allocator, file_path: []const u8) ![]u8 {
    const argv: []const []const u8 = &.{
        "git",             "diff",            "--no-index",
        "--src-prefix=a/", "--dst-prefix=b/", "--no-color",
        "--",              "/dev/null",       file_path,
    };

    const result = runCommand(allocator, argv, .{ .max_bytes = 10 * 1024 * 1024 }) catch |err| {
        if (err == error.AbnormalTermination) return try allocator.alloc(u8, 0);
        return err;
    };
    defer allocator.free(result.stderr);
    // Exit code 1 means "differences found" — this is expected for --no-index
    if (result.exit_code != 0 and result.exit_code != 1) {
        allocator.free(result.stdout);
        return try allocator.alloc(u8, 0);
    }
    return result.stdout;
}

// ─── Stash plumbing helpers ───────────────────────────────────────────

/// Run `git rev-parse HEAD^{tree}` and return the trimmed tree SHA.
pub fn runGitRevParseTree(allocator: Allocator) ![]u8 {
    return runGitCapture(allocator, &.{ "git", "rev-parse", "HEAD^{tree}" }, .{}, "git rev-parse");
}

/// Run `git rev-parse <ref>` and return the trimmed SHA.
pub fn runGitRevParse(allocator: Allocator, ref: []const u8) ![]u8 {
    return runGitCapture(allocator, &.{ "git", "rev-parse", ref }, .{}, "git rev-parse");
}

/// Run `git symbolic-ref --short HEAD` and return the branch name,
/// or null if HEAD is detached (non-zero exit).
pub fn runGitSymbolicRef(allocator: Allocator) !?[]u8 {
    const result = try runCommand(allocator, &.{ "git", "symbolic-ref", "--short", "HEAD" }, .{});
    allocator.free(result.stderr);
    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        return null;
    }
    return try trimAndShrink(allocator, result.stdout);
}

/// Run `git log --oneline -1 HEAD` and return the trimmed output.
pub fn runGitLogOneline(allocator: Allocator) ![]u8 {
    return runGitCapture(allocator, &.{ "git", "log", "--oneline", "-1", "HEAD" }, .{}, "git log");
}

/// Run `git read-tree <sha>` with a custom environment map.
pub fn runGitReadTreeWithEnv(allocator: Allocator, sha: []const u8, env_map: *const EnvMap) !void {
    const out = try runGitCapture(allocator, &.{ "git", "read-tree", sha }, .{ .env_map = env_map }, "git read-tree");
    allocator.free(out);
}

/// Run `git apply --cached --unidiff-zero` with patch on stdin and custom env.
pub fn runGitApplyWithEnv(allocator: Allocator, patch: []const u8, env_map: *const EnvMap) !void {
    const out = try runGitCapture(allocator, &.{ "git", "apply", "--cached", "--unidiff-zero" }, .{ .stdin_data = patch, .env_map = env_map }, "git apply");
    allocator.free(out);
}

/// Run `git write-tree` with a custom environment map, return the trimmed tree SHA.
pub fn runGitWriteTreeWithEnv(allocator: Allocator, env_map: *const EnvMap) ![]u8 {
    return runGitCapture(allocator, &.{ "git", "write-tree" }, .{ .env_map = env_map }, "git write-tree");
}

/// Run `git commit-tree -p <p1> [-p <p2>] -m <msg> <tree>` and return the trimmed commit SHA.
pub fn runGitCommitTree(allocator: Allocator, tree_sha: []const u8, parents: []const []const u8, message: []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "commit-tree" });
    for (parents) |p| try argv.appendSlice(allocator, &.{ "-p", p });
    try argv.appendSlice(allocator, &.{ "-m", message, tree_sha });
    return runGitCapture(allocator, argv.items, .{}, "git commit-tree");
}

/// Run `git stash store -m <msg> <sha>`.
pub fn runGitStashStore(allocator: Allocator, message: []const u8, commit_sha: []const u8) !void {
    const out = try runGitCapture(allocator, &.{ "git", "stash", "store", "-m", message, commit_sha }, .{}, "git stash store");
    allocator.free(out);
}

/// Run `git stash pop`. On conflict (non-zero exit), print stderr and exit 1.
pub fn runGitStashPop(allocator: Allocator) !void {
    const result = try runCommand(allocator, &.{ "git", "stash", "pop" }, .{});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        std.process.exit(1);
    }
}

/// Run `git hash-object -w <file_path>` and return the trimmed blob SHA.
pub fn runGitHashObject(allocator: Allocator, file_path: []const u8) ![]u8 {
    return runGitCapture(allocator, &.{ "git", "hash-object", "-w", file_path }, .{}, "git hash-object");
}

/// Run `git hash-object -w --stdin` with the given content piped in. Returns the trimmed blob SHA.
pub fn runGitHashObjectStdin(allocator: Allocator, content: []const u8) ![]u8 {
    return runGitCapture(allocator, &.{ "git", "hash-object", "-w", "--stdin" }, .{ .stdin_data = content }, "git hash-object --stdin");
}

/// Run `git update-index --add --cacheinfo <mode>,<blob_hash>,<file_path>` with custom GIT_INDEX_FILE env.
pub fn runGitUpdateIndexCacheinfo(allocator: Allocator, mode: []const u8, blob_hash: []const u8, file_path: []const u8, env_map: *const EnvMap) !void {
    const cacheinfo_arg = try std.fmt.allocPrint(allocator, "{s},{s},{s}", .{ mode, blob_hash, file_path });
    defer allocator.free(cacheinfo_arg);
    const out = try runGitCapture(allocator, &.{ "git", "update-index", "--add", "--cacheinfo", cacheinfo_arg }, .{ .env_map = env_map }, "git update-index");
    allocator.free(out);
}

/// Run `git rev-parse --show-toplevel` and return the trimmed repo root path.
pub fn runGitToplevel(allocator: Allocator) ![]u8 {
    const result = try runCommand(allocator, &.{ "git", "rev-parse", "--show-toplevel" }, .{});
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        return error.NotAGitRepo;
    }
    return trimAndShrink(allocator, result.stdout);
}

// ─── Commit plumbing helpers ──────────────────────────────────────────

/// Run `git rev-parse --git-dir` and return the trimmed git directory path.
pub fn runGitRevParseGitDir(allocator: Allocator) ![]u8 {
    return runGitCapture(allocator, &.{ "git", "rev-parse", "--git-dir" }, .{}, "git rev-parse --git-dir");
}

/// Run `git read-tree <treeish>` on the real index (no custom env).
/// Returns an error on failure instead of calling fatal, so callers can clean up.
pub fn runGitReadTree(allocator: Allocator, treeish: []const u8) !void {
    const result = try runCommand(allocator, &.{ "git", "read-tree", treeish }, .{});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        return error.ReadTreeFailed;
    }
}

/// Run `git commit -m <message> [--amend]` and return the commit output.
/// Returns `error.CommitFailed` on non-zero exit instead of calling fatal.
pub fn runGitCommit(allocator: Allocator, args: struct { message: []const u8, amend: bool }) ![]u8 {
    const argv: []const []const u8 = if (args.amend)
        &.{ "git", "commit", "-m", args.message, "--amend" }
    else
        &.{ "git", "commit", "-m", args.message };

    const result = try runCommand(allocator, argv, .{});
    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        allocator.free(result.stderr);
        return error.CommitFailed;
    }

    // git writes the commit summary to stderr; return that if stdout is empty
    if (result.stderr.len > 0) {
        allocator.free(result.stdout);
        return trimAndShrink(allocator, result.stderr);
    }
    allocator.free(result.stderr);
    return trimAndShrink(allocator, result.stdout);
}

// ============================================================================
// Tests
// ============================================================================

test "trimAndShrink no trailing newline returns input pointer" {
    const allocator = std.testing.allocator;
    const buf = try allocator.dupe(u8, "hello");
    const out = try trimAndShrink(allocator, buf);
    defer allocator.free(out);
    try std.testing.expectEqual(buf.ptr, out.ptr);
    try std.testing.expectEqualStrings("hello", out);
}

test "trimAndShrink strips trailing newline (re-allocates)" {
    const allocator = std.testing.allocator;
    const buf = try allocator.dupe(u8, "hello\n");
    const out = try trimAndShrink(allocator, buf);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "trimAndShrink strips multiple trailing newlines" {
    const allocator = std.testing.allocator;
    const buf = try allocator.dupe(u8, "abc\n\n\n");
    const out = try trimAndShrink(allocator, buf);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "trimAndShrink empty string is a no-op" {
    const allocator = std.testing.allocator;
    const buf = try allocator.dupe(u8, "");
    const out = try trimAndShrink(allocator, buf);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}
