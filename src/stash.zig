//! `stash` push machinery: build the stash commit from selected hunks without
//! touching the index, store it, then remove the stashed changes from the
//! worktree. `cmdStash` itself stays in commands.zig with the other subcommand
//! entry points; this module is the machinery it drives.

const std = @import("std");
const types = @import("types.zig");
const git = @import("git.zig");
const patch_mod = @import("patch.zig");
const format = @import("format.zig");

const Allocator = std.mem.Allocator;
const MatchedHunk = types.MatchedHunk;
const Verbosity = types.Verbosity;
const StashOptions = types.StashOptions;

const defaultIo = types.getIo;

/// What a stash says about the commit it is built on. All slices are gpa-owned.
pub const HeadInfo = struct {
    sha: []u8,
    /// Null when HEAD is detached.
    branch: ?[]u8,
    /// Abbreviated id and subject, as `git stash` quotes them.
    summary: []u8,

    pub fn deinit(self: *HeadInfo, allocator: Allocator) void {
        allocator.free(self.sha);
        if (self.branch) |b| allocator.free(b);
        allocator.free(self.summary);
    }

    fn branchName(self: HeadInfo) []const u8 {
        return self.branch orelse "(no branch)";
    }
};

/// Caller must call `deinit` on the returned struct.
pub fn gatherHeadInfo(allocator: Allocator) !HeadInfo {
    const sha = try git.runGitRevParse(allocator, "HEAD");
    errdefer allocator.free(sha);
    const branch = try git.runGitHeadBranch(allocator);
    errdefer if (branch) |b| allocator.free(b);
    const summary = try git.runGitHeadSummary(allocator);
    return .{ .sha = sha, .branch = branch, .summary = summary };
}

/// Exit if a selected hunk is in an intent-to-add entry, the new side of a
/// rename included. The entry has no content in the index, so the stash's
/// index commit could not record it and taking the change back out of the
/// worktree would leave the entry naming a missing file. `git stash` refuses
/// these too.
pub fn refuseIntentToAdd(arena: Allocator, matched: []const MatchedHunk) !void {
    const names_z = try git.runGitIntentToAddNames(arena);
    var refused = false;
    var names = std.mem.splitScalar(u8, names_z, 0);
    while (names.next()) |name| {
        if (name.len == 0) continue;
        for (matched) |m| {
            if (m.hunk.section.is_untracked or !std.mem.eql(u8, m.hunk.file_path, name)) continue;
            std.debug.print("error: cannot stash intent-to-add entry '{s}'\n", .{name});
            refused = true;
            break;
        }
    }
    if (!refused) return;
    std.debug.print("hint: stage it with 'git add', or make it untracked again with 'git rm --cached', then stash\n", .{});
    std.process.exit(1);
}

/// The trees of a stash entry, shaped like `git stash push --keep-index`'s:
/// the index as it stands, and the index with the stashed changes on top.
pub const StashTrees = struct {
    /// Allocator-owned.
    index: []const u8,
    /// Allocator-owned.
    stash: []const u8,
    /// Arena-owned patches that take the stashed text hunks back out of the
    /// worktree, in the order they must be applied. Empty without text hunks.
    cleanup_patches: []const []const u8,

    pub fn deinit(self: StashTrees, allocator: Allocator) void {
        allocator.free(self.index);
        allocator.free(self.stash);
    }
};

/// The selected hunks are index-to-worktree changes, so applying them to the
/// index tree gives exactly the worktree state being stashed, whatever else is
/// staged in the same files.
pub fn buildStashTrees(arena: Allocator, allocator: Allocator, partition: patch_mod.HunkPartition) !StashTrees {
    // An index with conflicts has no tree to record, and git stash refuses it too.
    if (try git.indexHasUnmergedPaths(allocator)) types.fatal("cannot stash while the index has unmerged paths", .{});

    const index_tree = try git.runGitWriteTree(allocator, null);
    errdefer allocator.free(index_tree);

    var tmp = try git.createTempIndex(allocator, "");
    defer tmp.deinit();
    try git.runGitReadTree(allocator, index_tree, &tmp.env_map);

    var cleanup_patches: []const []const u8 = &.{};
    if (partition.tracked_text.len > 0) {
        const forward = try arena.dupe(MatchedHunk, partition.tracked_text);
        const patches = try patch_mod.sortAndBuildPatches(arena, forward, .forward);
        _ = try git.applyPatches(allocator, patches, .{ .target = .index, .env_map = &tmp.env_map });
        const reverse = try arena.dupe(MatchedHunk, partition.tracked_text);
        cleanup_patches = try patch_mod.sortAndBuildPatches(arena, reverse, .reverse);
    }
    if (partition.tracked_binary_paths.len > 0) {
        try git.runGitAddFilesLenient(allocator, partition.tracked_binary_paths, &tmp.env_map);
    }

    const stash_tree = try git.runGitWriteTree(allocator, &tmp.env_map);
    return .{ .index = index_tree, .stash = stash_tree, .cleanup_patches = cleanup_patches };
}

/// The message `git stash push` would give the entry: `On <branch>: <msg>`
/// with `-m`, `WIP on <branch>: <commit>` without.
pub fn buildStashMessage(arena: Allocator, opts: StashOptions, head: HeadInfo) ![]const u8 {
    if (opts.message) |m| return std.fmt.allocPrint(arena, "On {s}: {s}", .{ head.branchName(), m });
    return std.fmt.allocPrint(arena, "WIP on {s}: {s}", .{ head.branchName(), head.summary });
}

/// Assemble the commit `git stash store` expects: the stash tree on top of
/// HEAD, with the index commit as second parent and, when untracked files were
/// selected, an untracked-files commit as third. Returns the allocator-owned
/// commit SHA.
pub fn createStashCommit(
    arena: Allocator,
    allocator: Allocator,
    head: HeadInfo,
    trees: StashTrees,
    untracked_matched: []const MatchedHunk,
    message: []const u8,
) ![]const u8 {
    const idx_msg = try std.fmt.allocPrint(arena, "index on {s}: {s}", .{ head.branchName(), head.summary });
    const idx_commit = try git.runGitCommitTree(allocator, trees.index, &.{head.sha}, idx_msg);
    defer allocator.free(idx_commit);

    if (untracked_matched.len == 0) {
        return git.runGitCommitTree(allocator, trees.stash, &.{ head.sha, idx_commit }, message);
    }
    const untracked_commit = try buildUntrackedCommit(arena, allocator, head, untracked_matched);
    defer allocator.free(untracked_commit);
    return git.runGitCommitTree(allocator, trees.stash, &.{ head.sha, idx_commit, untracked_commit }, message);
}

/// Build a git commit containing only the untracked files.
/// Returns an allocator-owned commit SHA — caller must free.
fn buildUntrackedCommit(
    arena: Allocator,
    allocator: Allocator,
    head: HeadInfo,
    untracked_matched: []const MatchedHunk,
) ![]const u8 {
    var tmp = try git.createTempIndex(allocator, "ut-");
    defer tmp.deinit();

    // Hash each untracked file and add to temp index
    const io = defaultIo();
    const cwd_dir = std.Io.Dir.cwd();
    for (untracked_matched) |m| {
        var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const symlink_n = cwd_dir.readLink(io, m.hunk.file_path, &link_buf) catch null;
        const symlink_target: ?[]const u8 = if (symlink_n) |n| link_buf[0..n] else null;

        const blob_sha = if (symlink_target) |target|
            try git.runGitHashObjectStdin(allocator, target)
        else
            try git.runGitHashObject(allocator, m.hunk.file_path);
        defer allocator.free(blob_sha);

        const mode: []const u8 = if (symlink_target != null)
            "120000"
        else blk: {
            const stat = cwd_dir.statFile(io, m.hunk.file_path, .{}) catch break :blk "100644";
            break :blk if (stat.permissions.toMode() & std.posix.S.IXUSR != 0) "100755" else "100644";
        };
        try git.runGitUpdateIndexCacheinfo(allocator, mode, blob_sha, m.hunk.file_path, &tmp.env_map);
    }

    const untracked_tree = try git.runGitWriteTree(allocator, &tmp.env_map);
    defer allocator.free(untracked_tree);

    const ut_msg = try std.fmt.allocPrint(arena, "untracked files on {s}: {s}", .{ head.branchName(), head.summary });
    return git.runGitCommitTree(allocator, untracked_tree, &.{head.sha}, ut_msg);
}

/// Take the stashed changes out of the worktree: check tracked binaries out
/// of the index, reverse-apply the text patches, delete untracked files. The
/// entry is already stored, so one failure does not stop the rest. Returns
/// false if any change could not be removed.
pub fn cleanupWorktree(
    allocator: Allocator,
    tracked_binary_paths: []const []const u8,
    cleanup_patches: []const []const u8,
    untracked_matched: []const MatchedHunk,
) bool {
    var removed_all = true;
    if (tracked_binary_paths.len > 0) {
        git.runGitCheckoutFilesLenient(allocator, tracked_binary_paths) catch {
            removed_all = false;
        };
    }
    for (cleanup_patches) |patch| {
        _ = git.runGitApply(allocator, patch, .{ .reverse = true, .target = .worktree, .explain_failure = false }) catch {
            removed_all = false;
            break;
        };
    }
    const io = defaultIo();
    for (untracked_matched) |m| {
        std.Io.Dir.cwd().deleteFile(io, m.hunk.file_path) catch {
            std.debug.print("error: cannot delete '{s}'\n", .{m.hunk.file_path});
            removed_all = false;
        };
    }
    return removed_all;
}

/// The stash entry exists but the worktree still has changes it holds.
/// `git stash` stops here too ("Cannot remove worktree changes"), leaving
/// the entry in place.
pub fn exitCleanupFailed() noreturn {
    std.debug.print("error: cannot remove the stashed changes from the worktree\n", .{});
    std.debug.print("hint: the changes are saved in stash@{{0}} and are still in the worktree\n", .{});
    std.debug.print("hint: run 'git stash drop' to keep working on them here, or remove them from the worktree to finish the stash\n", .{});
    std.process.exit(1);
}

/// Print per-hunk stash results and summary to stdout/stderr.
pub fn reportStashResults(stdout: *std.Io.Writer, opts: StashOptions, matched: []const MatchedHunk) !void {
    try format.printMatchedHunks(stdout, matched, "stashed", "stashed", opts.common);
    format.printHunkCountSummary(opts.common, matched.len, "stashed");
    if (opts.common.verbosity == .verbose and opts.common.output == .human) {
        std.debug.print("hint: use 'git stash list' to see stashed entries, 'git hunk stash pop' to restore\n", .{});
    }
}
