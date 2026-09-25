const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const DiffSource = types.DiffSource;

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

const CaptureOpts = struct {
    trim: bool = true,
};

/// Run a git command and return its stdout, trimmed unless `opts` says
/// otherwise. On a non-zero exit, show git's stderr and which command
/// failed, and return `error.GitFailed`, which main exits on without saying
/// more. For callers with a temp index or directory to remove on the way out.
fn runGitChecked(allocator: Allocator, argv: []const []const u8, run_opts: RunOpts, label: []const u8, opts: CaptureOpts) ![]u8 {
    const result = try runCommand(allocator, argv, run_opts);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        std.debug.print("error: {s} exited with code {d}\n", .{ label, result.exit_code });
        return error.GitFailed;
    }

    return if (opts.trim) trimAndShrink(allocator, result.stdout) else result.stdout;
}

/// `runGitChecked`, exiting on a non-zero exit.
fn runGitCapture(allocator: Allocator, argv: []const []const u8, run_opts: RunOpts, label: []const u8, opts: CaptureOpts) ![]u8 {
    return runGitChecked(allocator, argv, run_opts, label, opts) catch |err| switch (err) {
        error.GitFailed => std.process.exit(1),
        else => err,
    };
}

/// A throwaway git index in the temp directory, pre-populated by
/// GIT_INDEX_FILE in `env_map`.
/// Owns everything it frees; use as
/// `var tmp = try git.createTempIndex(...); defer tmp.deinit();`.
pub const TempIndex = struct {
    env_map: EnvMap,
    path_z: [:0]const u8,
    allocator: Allocator,

    pub fn deinit(self: *TempIndex) void {
        std.Io.Dir.cwd().deleteFile(types.getIo(), self.path_z) catch {};
        self.env_map.deinit();
        self.allocator.free(self.path_z);
    }
};

/// Build a temporary git index file path with a unique random suffix and
/// return an env map (cloned from the process environment) that points
/// GIT_INDEX_FILE at it. `prefix` becomes part of the filename for
/// human-readable diagnostics.
///
/// The directory is `TMPDIR` when set, `/tmp` otherwise — the same rule the
/// shell and mktemp use, so a caller that has isolated its temp directory
/// (a sandbox, a parallel test run) keeps that isolation.
pub fn createTempIndex(allocator: Allocator, prefix: []const u8) !TempIndex {
    const path_z = try tempPath(allocator, prefix, "idx");
    errdefer allocator.free(path_z);

    var env_map = try types.getEnvMap().clone(allocator);
    errdefer env_map.deinit();
    try env_map.put("GIT_INDEX_FILE", path_z);
    return .{ .env_map = env_map, .path_z = path_z, .allocator = allocator };
}

/// `<temp dir>/git-hunk-<prefix><kind>.<random>`, in the directory
/// `createTempIndex` describes.
fn tempPath(allocator: Allocator, prefix: []const u8, kind: []const u8) ![:0]u8 {
    var random_bytes: [8]u8 = undefined;
    std.Io.random(types.getIo(), &random_bytes);
    const random_val = std.mem.readInt(u64, &random_bytes, .little);
    const tmp_dir = std.mem.trimEnd(u8, types.getEnv("TMPDIR") orelse "/tmp", "/");
    return std.fmt.allocPrintSentinel(allocator, "{s}/git-hunk-{s}{s}.{x:0>16}", .{ tmp_dir, prefix, kind, random_val }, 0);
}

/// A throwaway directory beside the temp indexes, removed with everything
/// in it by `deinit`.
pub const TempDir = struct {
    path: [:0]const u8,
    allocator: Allocator,

    pub fn deinit(self: *TempDir) void {
        std.Io.Dir.cwd().deleteTree(types.getIo(), self.path) catch {};
        self.allocator.free(self.path);
    }
};

pub fn createTempDir(allocator: Allocator, prefix: []const u8) !TempDir {
    const path = try tempPath(allocator, prefix, "dir");
    errdefer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(types.getIo(), path);
    return .{ .path = path, .allocator = allocator };
}

const CaptureErrOpts = struct {
    /// Echo git's stderr on failure. Off for best-effort/cleanup callers
    /// where git noise would only confuse (their failures are swallowed).
    echo_stderr: bool = false,
    trim: bool = true,
};

/// Error-returning counterpart to runGitCapture: same capture-and-check
/// contract, but a non-zero exit returns `fail_err` (optionally echoing
/// git's stderr first) instead of exiting the process. Every lenient
/// helper is a one-liner over this.
fn runGitCaptureErr(allocator: Allocator, argv: []const []const u8, run_opts: RunOpts, fail_err: anyerror, opts: CaptureErrOpts) ![]u8 {
    const result = try runCommand(allocator, argv, run_opts);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        if (opts.echo_stderr and result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        return fail_err;
    }
    return if (opts.trim) trimAndShrink(allocator, result.stdout) else result.stdout;
}

/// Flags that pin git's diff output to the machine-readable form this tool
/// parses, regardless of the user's config or environment.
///
/// `--no-ext-diff` defeats `diff.external` and `GIT_EXTERNAL_DIFF`, which
/// otherwise hand the diff to a third-party program and leave git's stdout
/// **empty with exit 0** — indistinguishable from a clean tree.
/// `--no-textconv` defeats a `diff.<driver>.textconv` filter, which emits a
/// human-readable rendering of the blob that cannot be applied back to it.
/// `--src-prefix`/`--dst-prefix` pin the path prefixes against
/// `diff.noprefix` and `diff.mnemonicPrefix`; `--no-relative` pins paths to
/// the repo root against `diff.relative`; `--no-color` against `color.ui` /
/// `color.diff`; `--full-index` keeps blob ids intact for `--3way`.
const diff_hygiene_flags: []const []const u8 = &.{
    "--no-ext-diff",   "--no-textconv",
    "--no-color",      "--no-relative",
    "--src-prefix=a/", "--dst-prefix=b/",
};

/// The subset of `diff_hygiene_flags` that applies to name-only listings,
/// where prefixes and blob ids are not emitted at all.
const name_only_hygiene_flags: []const []const u8 = &.{ "--no-ext-diff", "--no-textconv", "--no-color", "--no-relative" };

/// `git diff` for `source`, scoped to specific file paths via
/// `-- file1 file2 ...`. Pass an empty slice for no file filter. The `--` is
/// always there: without it a file named like a revision (`main`, `HEAD`)
/// makes git refuse the revision as ambiguous.
pub fn runGitDiffFiles(allocator: Allocator, source: DiffSource, context: ?u32, file_paths: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "diff" });
    try source.appendDiffArgs(allocator, &argv);
    var context_buf: [16]u8 = undefined;
    if (context) |ctx| {
        try argv.append(allocator, std.fmt.bufPrint(&context_buf, "-U{d}", .{ctx}) catch "-U0");
    }
    try argv.appendSlice(allocator, diff_hygiene_flags);
    try argv.append(allocator, "--full-index");
    try argv.append(allocator, "--");
    try argv.appendSlice(allocator, file_paths);

    return runGitCapture(allocator, argv.items, .{ .max_bytes = 10 * 1024 * 1024 }, "git diff", .{ .trim = false });
}

const ApplyTarget = enum { index, worktree };

const ApplyOptions = struct {
    reverse: bool = false,
    target: ApplyTarget = .index,
    check_only: bool = false,
    /// Fall back to a 3-way merge when the patch context doesn't apply
    /// cleanly. Useful for cherry-picking or reverting hunks from far enough
    /// back that surrounding lines have drifted.
    ///
    /// With `target = .index` (add/commit), conflicts produce **unmerged index
    /// entries** — the user must `git add` the resolved file or use
    /// `git checkout --merge` to materialise the conflict in the worktree.
    ///
    /// With `target = .worktree` (restore), the index is left alone: a patch
    /// that applies is applied to the worktree only, so a hunk of the current
    /// diff (which always reverse-applies) makes this a no-op, as
    /// `git restore --merge` is on a path with nothing to merge. Only a merge
    /// that conflicts touches the index, recording the conflict there as
    /// `git apply --3way` and `git stash apply` do: `<<<<<<<` markers in the
    /// file and unmerged entries for it. As with those, a file merged this
    /// way must match the index first.
    ///
    /// `git apply` rejects `--3way` together with `--check`, so dry-run paths
    /// must drop this flag.
    three_way: bool = false,
    /// The `--ref` in effect as the user typed it, for the failure message (so
    /// the user knows which historical diff conflicted). Null means "current diff".
    ref: ?[]const u8 = null,
    /// Optional child environment (e.g. GIT_INDEX_FILE pointing at a temp
    /// index). Null inherits the parent environment.
    env_map: ?*const EnvMap = null,
    /// Follow git's own complaint with ours. Off for a caller whose failure
    /// means something other than a stale or drifted hunk, which says so itself.
    explain_failure: bool = true,
};

const ApplyResult = enum { applied_clean, applied_with_conflicts };

/// Apply `patches` one after another under the same options, stopping at the
/// first that fails. Reports conflicts if any patch landed with them.
pub fn applyPatches(allocator: Allocator, patches: []const []const u8, opts: ApplyOptions) !ApplyResult {
    if (patches.len == 0) return .applied_clean;
    // `--check` never writes, so checking patches one at a time tests each
    // against the untouched target, and a typechange's create half fails on
    // the path its delete half would have freed. One invocation checks them
    // as a sequence instead. `--reverse` reverses that sequence itself, so it
    // is handed the forward order the patches were built in.
    if (opts.check_only) {
        const ordered = try allocator.dupe([]const u8, patches);
        defer allocator.free(ordered);
        if (opts.reverse) std.mem.reverse([]const u8, ordered);
        const combined = try std.mem.concat(allocator, u8, ordered);
        defer allocator.free(combined);
        return runGitApply(allocator, combined, opts);
    }
    var result: ApplyResult = .applied_clean;
    for (patches) |patch| {
        if (try runGitApply(allocator, patch, opts) == .applied_with_conflicts) result = .applied_with_conflicts;
    }
    return result;
}

pub fn runGitApply(allocator: Allocator, patch: []const u8, opts: ApplyOptions) !ApplyResult {
    if (opts.three_way and opts.target == .worktree and !opts.check_only) return mergeIntoWorktree(allocator, patch, opts);
    return execGitApply(allocator, patch, opts, .report);
}

/// `git apply --3way` implies `--index`: it would stage every path it
/// restores. So the patch is applied to the worktree alone when it can be,
/// and only merged when it cannot, against a copy of the index; the real
/// index then gains just the conflicts, where git keeps them for the user
/// to resolve.
fn mergeIntoWorktree(allocator: Allocator, patch: []const u8, opts: ApplyOptions) !ApplyResult {
    var direct = opts;
    direct.three_way = false;
    if (execGitApply(allocator, patch, direct, .silent)) |result| {
        return result;
    } else |err| if (err != error.PatchFailed) return err;

    var tmp = try createTempIndex(allocator, "merge-");
    defer tmp.deinit();
    try copyIndexTo(allocator, tmp.path_z);
    var merge = opts;
    merge.env_map = &tmp.env_map;
    const result = try execGitApply(allocator, patch, merge, .report);
    if (result == .applied_with_conflicts) try recordConflicts(allocator, &tmp.env_map);
    return result;
}

/// Seed `dest` with the index as it stands. A repository that has never had
/// an index has nothing to copy, and git reads a missing one as empty.
pub fn copyIndexTo(allocator: Allocator, dest: []const u8) !void {
    const index_path = try runGitChecked(allocator, &.{ "git", "rev-parse", "--git-path", "index" }, .{}, "git rev-parse --git-path", .{});
    defer allocator.free(index_path);
    const cwd = std.Io.Dir.cwd();
    std.Io.Dir.copyFile(cwd, index_path, cwd, dest, types.getIo(), .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Copy the unmerged entries from the index `merged_env` names into the real
/// index, each replacing that path's stage 0 entry.
fn recordConflicts(allocator: Allocator, merged_env: *const EnvMap) !void {
    const unmerged = try runGitChecked(allocator, &.{ "git", "ls-files", "-u", "-z" }, .{ .env_map = merged_env }, "git ls-files -u", .{ .trim = false });
    defer allocator.free(unmerged);

    var index_info: std.ArrayList(u8) = .empty;
    defer index_info.deinit(allocator);
    var previous_path: []const u8 = "";
    var entries = std.mem.splitScalar(u8, unmerged, 0);
    while (entries.next()) |entry| {
        // "<mode> <id> <stage>\t<path>", which --index-info reads back as is.
        const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse continue;
        const path = entry[tab + 1 ..];
        var fields = std.mem.splitScalar(u8, entry[0..tab], ' ');
        _ = fields.next();
        const id = fields.next() orelse continue;
        if (!std.mem.eql(u8, path, previous_path)) {
            // Mode 0 drops the path's entries so the stages can take its place.
            try index_info.appendSlice(allocator, "0 ");
            try index_info.appendNTimes(allocator, '0', id.len);
            try index_info.print(allocator, "\t{s}\x00", .{path});
            previous_path = path;
        }
        try index_info.appendSlice(allocator, entry);
        try index_info.append(allocator, 0);
    }
    if (index_info.items.len == 0) return;
    const out = try runGitChecked(allocator, &.{ "git", "update-index", "-z", "--index-info" }, .{ .stdin_data = index_info.items }, "git update-index --index-info", .{ .trim = false });
    allocator.free(out);
}

/// Whether a failed apply prints git's complaint and ours.
const FailureReport = enum { report, silent };

fn execGitApply(allocator: Allocator, patch: []const u8, opts: ApplyOptions, failure_report: FailureReport) !ApplyResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "apply" });
    if (opts.target == .index) try argv.append(allocator, "--cached");
    if (opts.reverse) try argv.append(allocator, "--reverse");
    try argv.append(allocator, "--unidiff-zero");
    // The patch moves content that is already in the repository, as `git add`
    // does, so `apply.whitespace` must neither reject it nor rewrite it.
    try argv.append(allocator, "--whitespace=nowarn");
    if (opts.check_only) try argv.append(allocator, "--check");
    if (opts.three_way) try argv.append(allocator, "--3way");

    const result = runCommand(allocator, argv.items, .{ .stdin_data = patch, .env_map = opts.env_map }) catch |err| {
        if (err == error.AbnormalTermination) {
            std.debug.print("error: git apply terminated abnormally\n", .{});
            return error.PatchFailed;
        }
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // `git apply --3way` returns a non-zero exit code even when it successfully
    // applies the patch with conflict markers (worktree) or unmerged index
    // entries. Detect that path via the "Applied patch ... with conflicts"
    // marker in stderr and treat it as a soft success — the patch state was
    // committed; the user must resolve.
    const three_way_with_conflicts = opts.three_way and result.exit_code != 0 and
        std.mem.indexOf(u8, result.stderr, "Applied patch") != null and
        std.mem.indexOf(u8, result.stderr, "with conflicts") != null;
    if (three_way_with_conflicts) {
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        std.debug.print("warning: --3way applied patch with conflicts — resolve before continuing\n", .{});
        return .applied_with_conflicts;
    }
    if (result.exit_code != 0) {
        if (failure_report == .silent) return error.PatchFailed;
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        if (!opts.explain_failure) return error.PatchFailed;
        const try_3way: []const u8 = if (opts.three_way) "" else " (try --3way)";
        if (opts.ref) |r| {
            const target: []const u8 = switch (opts.target) {
                .index => "the index",
                .worktree => "the worktree",
            };
            std.debug.print("error: changes from '{s}' do not apply cleanly to {s}{s}\n", .{ r, target, try_3way });
        } else if (opts.check_only) {
            std.debug.print("error: patch would not apply cleanly — hashes may be stale\n", .{});
        } else {
            std.debug.print("error: patch did not apply cleanly — re-run 'list' and try again\n", .{});
        }
        return error.PatchFailed;
    }
    return .applied_clean;
}

/// Build argv as `prefix... -- file_paths...`. Caller frees the returned
/// slice (not the strings it points at).
fn pathspecArgv(allocator: Allocator, prefix: []const []const u8, file_paths: []const []const u8) ![]const []const u8 {
    return std.mem.concat(allocator, []const u8, &.{ prefix, &.{"--"}, file_paths });
}

/// Run `prefix... -- file_paths...`, discarding stdout. Fatal on non-zero exit.
fn runGitFileCmd(allocator: Allocator, prefix: []const []const u8, file_paths: []const []const u8, label: []const u8) !void {
    const argv = try pathspecArgv(allocator, prefix, file_paths);
    defer allocator.free(argv);
    const out = try runGitCapture(allocator, argv, .{}, label, .{ .trim = false });
    allocator.free(out);
}

/// Stage files by path: `git add -- path1 path2 ...`
pub fn runGitAddFiles(allocator: Allocator, file_paths: []const []const u8) !void {
    return runGitFileCmd(allocator, &.{ "git", "add" }, file_paths, "git add");
}

/// Unstage files: `git reset HEAD -- path1 path2 ...`
pub fn runGitResetFiles(allocator: Allocator, file_paths: []const []const u8) !void {
    return runGitFileCmd(allocator, &.{ "git", "reset", "HEAD" }, file_paths, "git reset");
}

/// Restore files from index: `git checkout -- path1 path2 ...`
pub fn runGitCheckoutFiles(allocator: Allocator, file_paths: []const []const u8) !void {
    return runGitFileCmd(allocator, &.{ "git", "checkout" }, file_paths, "git checkout");
}

/// Paths changed by HEAD relative to its first parent (NUL-separated, so
/// non-ASCII names arrive raw rather than C-quoted; --root covers parentless
/// commits). Returns an error instead of fatal.
pub fn runGitDiffTreeNames(allocator: Allocator) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "diff-tree", "-r", "--name-only", "-z", "--no-commit-id" });
    try argv.appendSlice(allocator, name_only_hygiene_flags);
    try argv.appendSlice(allocator, &.{ "--root", "HEAD", "--" });
    return runGitCaptureErr(allocator, argv.items, .{}, error.DiffTreeFailed, .{ .trim = false });
}

/// Paths with staged changes (`git diff --cached --name-only -z`),
/// NUL-separated. Returns an error instead of fatal.
pub fn runGitDiffCachedNames(allocator: Allocator) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "diff", "--cached", "--name-only", "-z" });
    try argv.appendSlice(allocator, name_only_hygiene_flags);
    return runGitCaptureErr(allocator, argv.items, .{}, error.DiffFailed, .{ .trim = false });
}

/// Reset index entries to HEAD for the given paths, returning an error on
/// git failure instead of exiting. For best-effort cleanup passes.
pub fn runGitResetFilesLenient(allocator: Allocator, file_paths: []const []const u8) !void {
    const argv = try pathspecArgv(allocator, &.{ "git", "reset", "-q", "HEAD" }, file_paths);
    defer allocator.free(argv);
    const out = try runGitCaptureErr(allocator, argv, .{}, error.ResetFailed, .{ .trim = false });
    allocator.free(out);
}

/// Check files out of the index, returning an error on git failure instead
/// of exiting, for a caller that must go on to report what is left.
pub fn runGitCheckoutFilesLenient(allocator: Allocator, file_paths: []const []const u8) !void {
    const argv = try pathspecArgv(allocator, &.{ "git", "checkout" }, file_paths);
    defer allocator.free(argv);
    const out = try runGitCaptureErr(allocator, argv, .{}, error.CheckoutFailed, .{ .echo_stderr = true, .trim = false });
    allocator.free(out);
}

/// Stage files by path, returning an error on git failure instead of
/// exiting the process. For post-commit index resync, where a failure
/// must downgrade to a warning (the commit already succeeded).
pub fn runGitAddFilesLenient(allocator: Allocator, file_paths: []const []const u8, env_map: ?*const EnvMap) !void {
    const argv = try pathspecArgv(allocator, &.{ "git", "add" }, file_paths);
    defer allocator.free(argv);
    const out = try runGitCaptureErr(allocator, argv, .{ .env_map = env_map }, error.AddFailed, .{ .echo_stderr = true, .trim = false });
    allocator.free(out);
}

/// Generate diff output for untracked files using `git diff --no-index`.
/// The output matches the standard `git diff` format expected by parseDiff.
/// Only files matching `file_filter` are included (empty slice = all untracked files).
/// Allocates the result with `allocator`; caller must free the returned slice.
pub fn diffUntrackedFiles(allocator: Allocator, file_filter: []const []const u8) ![]u8 {
    // NUL-separated, so a name git would C-quote arrives as the name itself.
    // The filter is passed on as a pathspec so git lists only what can match
    // it, rather than every untracked file in the repository.
    const ls_argv = try pathspecArgv(allocator, &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" }, file_filter);
    defer allocator.free(ls_argv);

    const ls_result = try runCommand(allocator, ls_argv, .{});
    defer allocator.free(ls_result.stdout);
    defer allocator.free(ls_result.stderr);
    if (ls_result.exit_code != 0) return try allocator.alloc(u8, 0);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var iter = std.mem.splitScalar(u8, ls_result.stdout, 0);
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
/// `--full-index` as for tracked diffs: a binary's hash is taken over its
/// blob ids, which would otherwise be abbreviated to `core.abbrev`.
fn diffSingleUntrackedFile(allocator: Allocator, file_path: []const u8) ![]u8 {
    if (try diffSingleUntrackedSymlink(allocator, file_path)) |diff| {
        return diff;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "diff", "--no-index" });
    try argv.appendSlice(allocator, diff_hygiene_flags);
    try argv.appendSlice(allocator, &.{ "--full-index", "--", "/dev/null", file_path });

    const result = runCommand(allocator, argv.items, .{ .max_bytes = 10 * 1024 * 1024 }) catch |err| {
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

/// Build the Git diff form for an untracked symlink. `git diff --no-index
/// /dev/null <path>` works for symlinks to files, but treats symlinks to
/// directories as directories and looks for `<path>/null`.
fn diffSingleUntrackedSymlink(allocator: Allocator, file_path: []const u8) !?[]u8 {
    var target_buf: [4096]u8 = undefined;
    const target_len = std.Io.Dir.cwd().readLink(defaultIo(), file_path, &target_buf) catch |err| switch (err) {
        error.NotLink => return null,
        else => return err,
    };
    const target = target_buf[0..target_len];

    const blob_sha = try runGitCapture(allocator, &.{ "git", "hash-object", "--stdin" }, .{ .stdin_data = target }, "git hash-object --stdin", .{});
    defer allocator.free(blob_sha);
    // Full ids, as git writes them under --full-index; the zero id matches the
    // object format's length.
    const zero_id = try allocator.alloc(u8, blob_sha.len);
    defer allocator.free(zero_id);
    @memset(zero_id, '0');
    const quote_high_bytes = quotesHighBytes(allocator);
    const old_name = try diffHeaderName(allocator, "a/", file_path, quote_high_bytes);
    defer allocator.free(old_name);
    const new_name = try diffHeaderName(allocator, "b/", file_path, quote_high_bytes);
    defer allocator.free(new_name);
    // git ends a `+++` name containing a space with a TAB.
    const name_end: []const u8 = if (std.mem.indexOfScalar(u8, file_path, ' ') != null) "\t" else "";
    return try std.fmt.allocPrint(
        allocator,
        "diff --git {s} {s}\n" ++
            "new file mode 120000\n" ++
            "index {s}..{s}\n" ++
            "--- /dev/null\n" ++
            "+++ {s}{s}\n" ++
            "@@ -0,0 +1 @@\n" ++
            "+{s}\n" ++
            "\\ No newline at end of file\n",
        .{ old_name, new_name, zero_id, blob_sha, new_name, name_end, target },
    );
}

/// Whether git C-quotes bytes above 0x7f in the paths it prints: the
/// `core.quotePath` setting, on unless set otherwise.
fn quotesHighBytes(allocator: Allocator) bool {
    const out = runGitCaptureErr(allocator, &.{ "git", "config", "--type=bool", "--get", "core.quotePath" }, .{}, error.ConfigUnset, .{}) catch return true;
    defer allocator.free(out);
    return !std.mem.eql(u8, out, "false");
}

/// `prefix` and `path` as a diff header names them: C-quoted, with the prefix
/// inside the quotes, when the path has a byte git escapes, as is otherwise.
fn diffHeaderName(allocator: Allocator, prefix: []const u8, path: []const u8, quote_high_bytes: bool) ![]u8 {
    for (path) |c| {
        if (mustQuote(c, quote_high_bytes)) break;
    } else return std.mem.concat(allocator, u8, &.{ prefix, path });

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    try out.appendSlice(allocator, prefix);
    for (path) |c| {
        if (!mustQuote(c, quote_high_bytes)) {
            try out.append(allocator, c);
            continue;
        }
        const letter: ?u8 = switch (c) {
            0x07 => 'a',
            0x08 => 'b',
            '\t' => 't',
            '\n' => 'n',
            0x0b => 'v',
            0x0c => 'f',
            '\r' => 'r',
            '"', '\\' => c,
            else => null,
        };
        if (letter) |l| {
            try out.print(allocator, "\\{c}", .{l});
        } else {
            try out.print(allocator, "\\{o:0>3}", .{c});
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

/// The bytes git's C-style quoting escapes.
fn mustQuote(c: u8, quote_high_bytes: bool) bool {
    return c < 0x20 or c == '"' or c == '\\' or c == 0x7f or (c >= 0x80 and quote_high_bytes);
}

// ─── Stash plumbing helpers ───────────────────────────────────────────

/// Run `git rev-parse <ref>` and return the trimmed SHA.
pub fn runGitRevParse(allocator: Allocator, ref: []const u8) ![]u8 {
    return runGitCapture(allocator, &.{ "git", "rev-parse", ref }, .{}, "git rev-parse", .{});
}

/// True if `rev` names something git can diff: a commit, or a tree.
pub fn revisionExists(allocator: Allocator, rev: []const u8) bool {
    const probe = std.fmt.allocPrint(allocator, "{s}^{{tree}}", .{rev}) catch return false;
    defer allocator.free(probe);
    const out = runGitCaptureErr(allocator, &.{ "git", "rev-parse", "--verify", "--quiet", probe }, .{}, error.BadRevision, .{ .trim = false }) catch return false;
    allocator.free(out);
    return true;
}

/// True if `<ref>^` resolves, i.e. the ref has a parent commit. Soft-fails to
/// false on any error so callers can use the empty-tree fallback.
pub fn refHasParent(allocator: Allocator, ref: []const u8) bool {
    const probe = std.fmt.allocPrint(allocator, "{s}^", .{ref}) catch return false;
    defer allocator.free(probe);
    const out = runGitCaptureErr(allocator, &.{ "git", "rev-parse", "--verify", "--quiet", probe }, .{}, error.NoParent, .{ .trim = false }) catch return false;
    allocator.free(out);
    return true;
}

/// The branch HEAD is on, as `git stash` names it: the ref with `refs/heads/`
/// taken off, or null when HEAD is detached or points outside `refs/heads/`.
pub fn runGitHeadBranch(allocator: Allocator) !?[]u8 {
    const ref = runGitCaptureErr(allocator, &.{ "git", "symbolic-ref", "-q", "HEAD" }, .{}, error.NoSymbolicRef, .{}) catch |err| switch (err) {
        error.NoSymbolicRef => return null,
        else => return err,
    };
    defer allocator.free(ref);
    const prefix = "refs/heads/";
    if (!std.mem.startsWith(u8, ref, prefix)) return null;
    return try allocator.dupe(u8, ref[prefix.len..]);
}

/// HEAD's abbreviated id and subject, the way `git stash` quotes the commit
/// a stash is built on.
pub fn runGitHeadSummary(allocator: Allocator) ![]u8 {
    return runGitCapture(allocator, &.{ "git", "log", "-1", "--no-decorate", "--no-show-signature", "--no-color", "--format=%h %s", "HEAD", "--" }, .{}, "git log", .{});
}

/// True if the index holds an unresolved merge conflict.
pub fn indexHasUnmergedPaths(allocator: Allocator) !bool {
    const out = try runGitCapture(allocator, &.{ "git", "ls-files", "--unmerged" }, .{}, "git ls-files", .{ .trim = false });
    defer allocator.free(out);
    return out.len > 0;
}

/// Run `git write-tree` (against `env_map`'s index when given) and return
/// the trimmed tree SHA.
pub fn runGitWriteTree(allocator: Allocator, env_map: ?*const EnvMap) ![]u8 {
    return runGitChecked(allocator, &.{ "git", "write-tree" }, .{ .env_map = env_map }, "git write-tree", .{});
}

/// Run `git commit-tree -p <p1> [-p <p2>] -m <msg> <tree>` and return the trimmed commit SHA.
pub fn runGitCommitTree(allocator: Allocator, tree_sha: []const u8, parents: []const []const u8, message: []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "commit-tree" });
    for (parents) |p| try argv.appendSlice(allocator, &.{ "-p", p });
    try argv.appendSlice(allocator, &.{ "-m", message, tree_sha });
    return runGitChecked(allocator, argv.items, .{}, "git commit-tree", .{});
}

/// Run `git stash store -m <msg> <sha>`.
pub fn runGitStashStore(allocator: Allocator, message: []const u8, commit_sha: []const u8) !void {
    const out = try runGitCapture(allocator, &.{ "git", "stash", "store", "-m", message, commit_sha }, .{}, "git stash store", .{});
    allocator.free(out);
}

/// Run `git stash pop`. On failure, show what git said and exit 1: its
/// errors, then its report, which names any conflict and says the entry
/// was kept.
pub fn runGitStashPop(allocator: Allocator) !void {
    const result = try runCommand(allocator, &.{ "git", "stash", "pop" }, .{});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        std.debug.print("{s}{s}", .{ result.stderr, result.stdout });
        std.process.exit(1);
    }
}

/// The commit `refs/stash` names, or null when there are no stash entries.
pub fn resolveStash(allocator: Allocator) !?[]u8 {
    return runGitCaptureErr(allocator, &.{ "git", "rev-parse", "-q", "--verify", "refs/stash" }, .{}, error.NoStash, .{}) catch |err| switch (err) {
        error.NoStash => null,
        else => err,
    };
}

/// `git diff-tree -r -z` between two trees in raw form: for each changed
/// path, `:<old mode> <new mode> <old id> <new id> <status>` then the path,
/// each NUL-terminated.
pub fn runGitDiffTreeRaw(allocator: Allocator, from: []const u8, to: []const u8) ![]u8 {
    return runGitCaptureErr(allocator, &.{ "git", "diff-tree", "-r", "-z", "--no-renames", from, to, "--" }, .{}, error.DiffTreeFailed, .{ .echo_stderr = true, .trim = false });
}

/// Paths that differ between two trees, NUL-separated.
pub fn runGitDiffTreeNamesBetween(allocator: Allocator, from: []const u8, to: []const u8) ![]u8 {
    return runGitCaptureErr(allocator, &.{ "git", "diff-tree", "-r", "-z", "--name-only", "--no-renames", from, to, "--" }, .{}, error.DiffTreeFailed, .{ .echo_stderr = true, .trim = false });
}

/// Paths whose index entry differs from `tree`, NUL-separated.
pub fn runGitDiffIndexCachedNames(allocator: Allocator, tree: []const u8) ![]u8 {
    return runGitCaptureErr(allocator, &.{ "git", "diff-index", "--cached", "-z", "--name-only", "--no-renames", tree, "--" }, .{}, error.DiffIndexFailed, .{ .echo_stderr = true, .trim = false });
}

/// Intent-to-add entries (`git add -N`), NUL-separated. Only such an entry
/// can make a file show as added between the index and the worktree.
pub fn runGitIntentToAddNames(allocator: Allocator) ![]u8 {
    return runGitCaptureErr(allocator, &.{ "git", "diff-files", "-z", "--name-only", "--no-renames", "--diff-filter=A" }, .{}, error.DiffFilesFailed, .{ .echo_stderr = true, .trim = false });
}

/// Paths with unstaged changes (`git diff --name-only -z`), NUL-separated.
pub fn runGitDiffUnstagedNames(allocator: Allocator) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "diff", "--name-only", "-z" });
    try argv.appendSlice(allocator, name_only_hygiene_flags);
    return runGitCaptureErr(allocator, argv.items, .{}, error.DiffFailed, .{ .echo_stderr = true, .trim = false });
}

/// Every path in `treeish`, NUL-separated.
pub fn runGitLsTreeNames(allocator: Allocator, treeish: []const u8) ![]u8 {
    return runGitCaptureErr(allocator, &.{ "git", "ls-tree", "-r", "-z", "--name-only", treeish, "--" }, .{}, error.LsTreeFailed, .{ .echo_stderr = true, .trim = false });
}

/// Every entry of the index `env_map` names (the real one when null) as
/// `<mode> <id> <stage>\t<path>`, NUL-terminated.
pub fn runGitLsFilesStaged(allocator: Allocator, env_map: ?*const EnvMap) ![]u8 {
    return runGitCaptureErr(allocator, &.{ "git", "ls-files", "-s", "-z" }, .{ .env_map = env_map }, error.LsFilesFailed, .{ .echo_stderr = true, .trim = false });
}

/// Record each worktree path in `paths_z` (NUL-terminated) in the index
/// `env_map` names as git would stage it, dropping those that are gone.
pub fn runGitUpdateIndexFromWorktree(allocator: Allocator, paths_z: []const u8, env_map: ?*const EnvMap) !void {
    const out = try runGitCaptureErr(allocator, &.{ "git", "update-index", "--add", "--remove", "-z", "--stdin" }, .{ .stdin_data = paths_z, .env_map = env_map }, error.UpdateIndexFailed, .{ .echo_stderr = true, .trim = false });
    allocator.free(out);
}

/// Set index entries from `--index-info` lines (NUL-terminated) in the index
/// `env_map` names (the real one when null).
pub fn runGitUpdateIndexInfo(allocator: Allocator, index_info: []const u8, env_map: ?*const EnvMap) !void {
    const out = try runGitCaptureErr(allocator, &.{ "git", "update-index", "-z", "--index-info" }, .{ .stdin_data = index_info, .env_map = env_map }, error.UpdateIndexFailed, .{ .echo_stderr = true, .trim = false });
    allocator.free(out);
}

/// Write the entries for `paths_z` (NUL-terminated) out of the index
/// `env_map` names, over whatever is there, under `prefix` when given (a
/// directory path ending in '/') and into the worktree otherwise.
pub fn runGitCheckoutIndexPaths(allocator: Allocator, prefix: ?[]const u8, paths_z: []const u8, env_map: *const EnvMap) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "checkout-index", "-f", "-z", "--stdin" });
    const prefix_arg = if (prefix) |p| try std.fmt.allocPrint(allocator, "--prefix={s}", .{p}) else null;
    defer if (prefix_arg) |a| allocator.free(a);
    if (prefix_arg) |a| try argv.append(allocator, a);
    const out = try runGitCaptureErr(allocator, argv.items, .{ .stdin_data = paths_z, .env_map = env_map }, error.CheckoutIndexFailed, .{ .echo_stderr = true, .trim = false });
    allocator.free(out);
}

/// Write every entry of the index `env_map` names into the worktree,
/// refusing to overwrite a file that is already there.
pub fn runGitCheckoutIndexAll(allocator: Allocator, env_map: *const EnvMap) !void {
    const out = try runGitCaptureErr(allocator, &.{ "git", "checkout-index", "--all" }, .{ .env_map = env_map }, error.CheckoutIndexFailed, .{ .echo_stderr = true, .trim = false });
    allocator.free(out);
}

pub const MergeFileResult = enum { clean, conflicts, binary };

/// `git merge-file` of `base`→`other` into `current` in place, with the
/// labels `git stash` gives its sides.
pub fn runGitMergeFile(allocator: Allocator, current: []const u8, base: []const u8, other: []const u8) !MergeFileResult {
    const result = try runCommand(allocator, &.{ "git", "merge-file", "-L", "Updated upstream", "-L", "Stash base", "-L", "Stashed changes", current, base, other }, .{});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    // The exit code counts the conflicts; a negative one (255) is an error,
    // which for readable files means one of them is binary.
    return switch (result.exit_code) {
        0 => .clean,
        255 => .binary,
        else => .conflicts,
    };
}

/// Run `git hash-object -w --path=<path> <file>`: `file`'s content as git
/// would store it at `path`. Returns the trimmed blob id.
pub fn runGitHashObjectAs(allocator: Allocator, file: []const u8, path: []const u8) ![]u8 {
    const path_arg = try std.fmt.allocPrint(allocator, "--path={s}", .{path});
    defer allocator.free(path_arg);
    return runGitCaptureErr(allocator, &.{ "git", "hash-object", "-w", path_arg, "--", file }, .{}, error.HashObjectFailed, .{ .echo_stderr = true });
}

/// Run `git stash drop -q`.
pub fn runGitStashDrop(allocator: Allocator) !void {
    const out = try runGitCaptureErr(allocator, &.{ "git", "stash", "drop", "-q" }, .{}, error.StashDropFailed, .{ .echo_stderr = true, .trim = false });
    allocator.free(out);
}

/// Run `git hash-object -w <file_path>` and return the trimmed blob SHA.
pub fn runGitHashObject(allocator: Allocator, file_path: []const u8) ![]u8 {
    return runGitChecked(allocator, &.{ "git", "hash-object", "-w", file_path }, .{}, "git hash-object", .{});
}

/// Run `git hash-object -w --stdin` with the given content piped in. Returns the trimmed blob SHA.
pub fn runGitHashObjectStdin(allocator: Allocator, content: []const u8) ![]u8 {
    return runGitChecked(allocator, &.{ "git", "hash-object", "-w", "--stdin" }, .{ .stdin_data = content }, "git hash-object --stdin", .{});
}

/// Return the empty tree's object ID in this repository's object format.
/// `git diff <empty-tree>..<commit>` shows the full content of `<commit>` as
/// additions, which is how a parentless commit gets a diff at all. Asked of
/// git rather than hardcoded because the ID differs between SHA-1 and SHA-256.
pub fn runGitEmptyTree(allocator: Allocator) ![]u8 {
    return runGitChecked(allocator, &.{ "git", "hash-object", "-t", "tree", "--stdin" }, .{ .stdin_data = "" }, "git hash-object -t tree", .{});
}

/// Run `git update-index --add --cacheinfo <mode>,<blob_hash>,<file_path>` with custom GIT_INDEX_FILE env.
pub fn runGitUpdateIndexCacheinfo(allocator: Allocator, mode: []const u8, blob_hash: []const u8, file_path: []const u8, env_map: *const EnvMap) !void {
    const cacheinfo_arg = try std.fmt.allocPrint(allocator, "{s},{s},{s}", .{ mode, blob_hash, file_path });
    defer allocator.free(cacheinfo_arg);
    const out = try runGitChecked(allocator, &.{ "git", "update-index", "--add", "--cacheinfo", cacheinfo_arg }, .{ .env_map = env_map }, "git update-index", .{});
    allocator.free(out);
}

/// Run `git rev-parse --show-toplevel` and return the trimmed repo root path.
pub fn runGitToplevel(allocator: Allocator) ![]u8 {
    return runGitCaptureErr(allocator, &.{ "git", "rev-parse", "--show-toplevel" }, .{}, error.NotAGitRepo, .{});
}

// ─── Commit plumbing helpers ──────────────────────────────────────────

/// Run `git rev-parse --git-dir` and return the trimmed git directory path.
pub fn runGitRevParseGitDir(allocator: Allocator) ![]u8 {
    return runGitCapture(allocator, &.{ "git", "rev-parse", "--git-dir" }, .{}, "git rev-parse --git-dir", .{});
}

/// Run `git read-tree <treeish>`, optionally against a custom environment
/// (GIT_INDEX_FILE temp index). Returns an error on failure instead of
/// calling fatal, so callers can clean up.
pub fn runGitReadTree(allocator: Allocator, treeish: []const u8, env_map: ?*const EnvMap) !void {
    const out = try runGitCaptureErr(allocator, &.{ "git", "read-tree", treeish }, .{ .env_map = env_map }, error.ReadTreeFailed, .{ .echo_stderr = true, .trim = false });
    allocator.free(out);
}

/// Run `git commit -m <message> [--amend]` and return the commit output.
/// Returns `error.CommitFailed` on non-zero exit instead of calling fatal.
pub fn runGitCommit(allocator: Allocator, args: struct { message: []const u8, amend: bool, env_map: ?*const EnvMap = null }) ![]u8 {
    const argv: []const []const u8 = if (args.amend)
        &.{ "git", "commit", "-m", args.message, "--amend" }
    else
        &.{ "git", "commit", "-m", args.message };

    const result = try runCommand(allocator, argv, .{ .env_map = args.env_map });
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

test "diffHeaderName quotes as git does" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { path: []const u8, quote_high_bytes: bool, want: []const u8 }{
        .{ .path = "plain.txt", .quote_high_bytes = true, .want = "b/plain.txt" },
        .{ .path = "sp ace", .quote_high_bytes = true, .want = "b/sp ace" },
        .{ .path = "l\xc3\xafnk", .quote_high_bytes = true, .want = "\"b/l\\303\\257nk\"" },
        .{ .path = "l\xc3\xafnk", .quote_high_bytes = false, .want = "b/l\xc3\xafnk" },
        .{ .path = "q\"uote", .quote_high_bytes = false, .want = "\"b/q\\\"uote\"" },
        .{ .path = "t\tab\\", .quote_high_bytes = false, .want = "\"b/t\\tab\\\\\"" },
        .{ .path = "del\x7f\x01", .quote_high_bytes = false, .want = "\"b/del\\177\\001\"" },
    };
    for (cases) |case| {
        const got = try diffHeaderName(allocator, "b/", case.path, case.quote_high_bytes);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}
