//! `stash` push machinery: build the stash commit from selected hunks without
//! touching the index, store it, then remove the stashed changes from the
//! worktree. `cmdStash` itself stays in commands.zig with the other subcommand
//! entry points; this module is the machinery it drives.

const std = @import("std");
const types = @import("types.zig");
const git = @import("git.zig");
const diff_mod = @import("diff.zig");
const patch_mod = @import("patch.zig");
const format = @import("format.zig");
const head_match = @import("head_match.zig");

const Allocator = std.mem.Allocator;
const Hunk = types.Hunk;
const MatchedHunk = types.MatchedHunk;
const Verbosity = types.Verbosity;
const StashOptions = types.StashOptions;

const defaultIo = types.getIo;

/// Bundles HEAD-side metadata used by cmdStash. All slices are gpa-owned.
pub const HeadInfo = struct {
    tree: []u8,
    sha: []u8,
    branch: ?[]u8,
    msg: []u8,
    branch_name: []const u8,

    pub fn deinit(self: *HeadInfo, allocator: Allocator) void {
        allocator.free(self.tree);
        allocator.free(self.sha);
        if (self.branch) |b| allocator.free(b);
        allocator.free(self.msg);
    }
};

/// Look up HEAD tree, HEAD sha, branch name, and HEAD commit summary in one
/// place. Caller must call `deinit` on the returned struct.
pub fn gatherHeadInfo(allocator: Allocator) !HeadInfo {
    const tree = try git.runGitRevParse(allocator, "HEAD^{tree}");
    errdefer allocator.free(tree);
    const sha = try git.runGitRevParse(allocator, "HEAD");
    errdefer allocator.free(sha);
    const branch = try git.runGitSymbolicRef(allocator);
    errdefer if (branch) |b| allocator.free(b);
    const msg = try git.runGitLogOneline(allocator);
    return .{ .tree = tree, .sha = sha, .branch = branch, .msg = msg, .branch_name = branch orelse "HEAD" };
}

/// Result of running both the tracked-text and tracked-binary tree pipelines.
pub const StashTreeBuild = struct {
    tree: []const u8,
    /// Patches reverse-applied to worktree at cleanup. Empty if no tracked text hunks.
    index_patches: []const []const u8,
    /// True iff `tree` was allocated here and must be freed by the caller.
    owns_tree: bool,
};

/// Construct the stash tree by layering tracked-binary blobs onto a tree built
/// from tracked-text patches. Falls back to `head_tree` when there are neither.
pub fn buildStashTree(
    arena: Allocator,
    allocator: Allocator,
    partition: patch_mod.HunkPartition,
    head_tree: []const u8,
    context: ?u32,
) !StashTreeBuild {
    var tree: []const u8 = head_tree;
    var index_patches: []const []const u8 = &.{};
    var owns = false;
    errdefer if (owns) allocator.free(tree);

    if (partition.tracked_text.len > 0) {
        const tracked_mut = try arena.dupe(MatchedHunk, partition.tracked_text);
        const result = try buildTrackedStashTree(arena, allocator, tracked_mut, head_tree, context);
        index_patches = result.index_patches;
        tree = result.stash_tree;
        owns = true;
    }
    if (partition.tracked_binary_paths.len > 0) {
        const new_tree = try addBinaryFilesToTree(allocator, tree, partition.tracked_binary_paths);
        if (owns) allocator.free(tree);
        tree = new_tree;
        owns = true;
    }
    return .{ .tree = tree, .index_patches = index_patches, .owns_tree = owns };
}

/// Build the stash message: user-provided `-m <msg>` or auto-generated from
/// the file paths involved.
pub fn buildStashMessage(arena: Allocator, opts: StashOptions, matched: []const MatchedHunk) ![]const u8 {
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

/// Assemble the commit `git stash store` expects: the stashed tree on top of
/// HEAD, with an index commit as second parent and, when untracked files were
/// selected, an untracked-files commit as third. Returns the allocator-owned
/// commit SHA.
pub fn createStashCommit(
    arena: Allocator,
    allocator: Allocator,
    head: HeadInfo,
    tree: []const u8,
    untracked_matched: []const MatchedHunk,
    message: []const u8,
) ![]const u8 {
    const idx_msg = try std.fmt.allocPrint(arena, "index on {s}: {s}", .{ head.branch_name, head.msg });
    const idx_commit = try git.runGitCommitTree(allocator, tree, &.{head.sha}, idx_msg);
    defer allocator.free(idx_commit);

    if (untracked_matched.len == 0) {
        return git.runGitCommitTree(allocator, tree, &.{ head.sha, idx_commit }, message);
    }
    const untracked_commit = try buildUntrackedCommit(arena, allocator, head.sha, head.branch_name, head.msg, untracked_matched);
    defer allocator.free(untracked_commit);
    return git.runGitCommitTree(allocator, tree, &.{ head.sha, idx_commit, untracked_commit }, message);
}

pub fn stashPop(allocator: Allocator, verbosity: Verbosity) !void {
    try git.runGitStashPop(allocator);
    if (verbosity != .quiet) {
        std.debug.print("popped stash@{{0}}\n", .{});
    }
}

const TrackedStashResult = struct {
    /// Arena-owned patches, in order, for reverse-apply to the worktree during
    /// cleanup. Multiple patches when typechanges are present.
    index_patches: []const []const u8,
    /// Allocator-owned stash tree SHA — caller must free.
    stash_tree: []const u8,
};

/// Build the stash tree for tracked hunks using a temporary git index.
/// Sorts `tracked_matched` in place. Returns index_patch (arena-owned) and
/// stash_tree (allocator-owned — caller must free).
fn buildTrackedStashTree(
    arena: Allocator,
    allocator: Allocator,
    tracked_matched: []MatchedHunk,
    head_tree: []const u8,
    context: ?u32,
) !TrackedStashResult {
    // Sort and build INDEX_PATCHES (index-relative, for worktree reverse-apply)
    const index_patches = try patch_mod.sortAndBuildPatches(arena, tracked_matched, .reverse);

    // Collect unique file paths from tracked hunks for HEAD diff
    const tracked_file_paths = try patch_mod.collectUniqueFilePaths(arena, tracked_matched);

    // Run HEAD-relative diff + parse
    const head_diff_output = try git.runGitDiffFiles(allocator, .unstaged, "HEAD", context, tracked_file_paths);
    defer allocator.free(head_diff_output);

    var head_hunks: std.ArrayList(Hunk) = .empty;
    if (head_diff_output.len > 0) {
        try diff_mod.parseDiff(arena, head_diff_output, .unstaged, &head_hunks);
    }

    // Build pointers to selected index hunks for the matcher
    const selected_ptrs = try arena.alloc(*const Hunk, tracked_matched.len);
    for (tracked_matched, 0..) |m, i| {
        selected_ptrs[i] = m.hunk;
    }

    // Match index hunks to HEAD hunks
    const head_matched = try head_match.matchIndexToHead(arena, selected_ptrs, head_hunks.items);

    if (head_matched.len == 0) {
        std.debug.print("error: could not match selected hunks to HEAD-relative diff\n", .{});
        std.process.exit(1);
    }

    // Sort and build HEAD_PATCH (for temp index apply)
    const head_matched_sorted = try arena.alloc(MatchedHunk, head_matched.len);
    @memcpy(head_matched_sorted, head_matched);
    const head_patches = try patch_mod.sortAndBuildPatches(arena, head_matched_sorted, .forward);

    var tmp = try git.createTempIndex(allocator, "");
    defer tmp.deinit();

    try git.runGitReadTree(allocator, head_tree, &tmp.env_map);
    _ = try git.applyPatches(allocator, head_patches, .{ .target = .index, .env_map = &tmp.env_map });

    const stash_tree = try git.runGitWriteTree(allocator, &tmp.env_map);
    return .{ .index_patches = index_patches, .stash_tree = stash_tree };
}

/// Build a git commit containing only the untracked files.
/// Returns an allocator-owned commit SHA — caller must free.
fn buildUntrackedCommit(
    arena: Allocator,
    allocator: Allocator,
    head_sha: []const u8,
    branch_name: []const u8,
    head_msg: []const u8,
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

    const ut_msg = try std.fmt.allocPrint(arena, "untracked files on {s}: {s}", .{ branch_name, head_msg });
    return git.runGitCommitTree(allocator, untracked_tree, &.{head_sha}, ut_msg);
}

/// Reverse-apply tracked patch and delete untracked files from the worktree.
/// Intentionally swallows errors to avoid aborting after a successful stash store.
pub fn cleanupWorktree(
    allocator: Allocator,
    has_tracked: bool,
    has_untracked: bool,
    index_patches: []const []const u8,
    untracked_matched: []const MatchedHunk,
) void {
    if (has_tracked) {
        for (index_patches) |patch| {
            _ = git.runGitApply(allocator, patch, .{ .reverse = true, .target = .worktree }) catch {
                std.debug.print("warning: stash created but worktree changes could not be removed\n", .{});
                std.debug.print("hint: use 'git stash pop' to undo or manually resolve\n", .{});
                break;
            };
        }
    }
    if (has_untracked) {
        const io = defaultIo();
        for (untracked_matched) |m| {
            std.Io.Dir.cwd().deleteFile(io, m.hunk.file_path) catch {
                std.debug.print("warning: could not delete untracked file '{s}'\n", .{m.hunk.file_path});
            };
        }
    }
}

/// Add binary files to a stash tree via a temporary git index.
/// Returns an allocator-owned tree SHA — caller must free.
fn addBinaryFilesToTree(
    allocator: Allocator,
    current_tree: []const u8,
    binary_paths: []const []const u8,
) ![]const u8 {
    var tmp = try git.createTempIndex(allocator, "bin-");
    defer tmp.deinit();

    try git.runGitReadTree(allocator, current_tree, &tmp.env_map);
    try git.runGitAddFilesLenient(allocator, binary_paths, &tmp.env_map);

    return git.runGitWriteTree(allocator, &tmp.env_map);
}

/// Print per-hunk stash results and summary to stdout/stderr.
pub fn reportStashResults(stdout: *std.Io.Writer, opts: StashOptions, matched: []const MatchedHunk) !void {
    const use_color = format.shouldUseColor(opts.common.output, opts.common.no_color);
    const count = try format.printMatchedHunks(stdout, matched, "stashed", "stashed", use_color, opts.common.output, opts.common.verbosity);
    format.printHunkCountSummary(opts.common.verbosity, opts.common.output, count, "stashed");
    if (opts.common.verbosity == .verbose and opts.common.output == .human) {
        std.debug.print("hint: use 'git stash list' to see stashed entries, 'git hunk stash pop' to restore\n", .{});
    }
}
