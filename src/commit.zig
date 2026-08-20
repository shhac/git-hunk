//! The `commit` transaction: build the commit in a throwaway index, then put
//! the user's real index back in step with the new HEAD.
//!
//! `git hunk commit` must land a subset of the working tree as a commit without
//! disturbing whatever the user already had staged. It does that by assembling
//! the commit in a temp index (GIT_INDEX_FILE) seeded from HEAD, so a crash at
//! any point leaves the real index untouched. Everything after the commit --
//! resyncing the real index, and adopting paths a pre-commit hook added -- is
//! best-effort cleanup that must never fail the commit that already landed.
//!
//! `cmdCommit` itself stays in commands.zig with the other subcommand entry
//! points; this module is the machinery it drives.

const std = @import("std");
const types = @import("types.zig");
const git = @import("git.zig");
const format = @import("format.zig");

const Allocator = std.mem.Allocator;
const MatchedHunk = types.MatchedHunk;
const CommitOptions = types.CommitOptions;
const defaultIo = types.getIo;

/// Extract the first file path from a patch's leading `diff --git a/<path> b/<path>`
/// line, for warning-message diagnostics. Returns null if the patch doesn't start
/// with the expected header.
fn firstPatchPath(patch: []const u8) ?[]const u8 {
    const prefix = "diff --git a/";
    if (!std.mem.startsWith(u8, patch, prefix)) return null;
    const line_end = std.mem.indexOfScalar(u8, patch, '\n') orelse patch.len;
    const after = patch[prefix.len..line_end];
    // Our patches always name the same path on both sides, so the header is
    // exactly `<path> b/<path>` -- split symmetrically. This survives spaces
    // (git does not quote them), unlike splitting on the first space.
    if (after.len >= 3 and (after.len - 3) % 2 == 0) {
        const plen = (after.len - 3) / 2;
        if (std.mem.eql(u8, after[plen .. plen + 3], " b/") and
            std.mem.eql(u8, after[0..plen], after[plen + 3 ..]))
        {
            return after[0..plen];
        }
    }
    // Fallback for asymmetric headers (renames): first space.
    const sp = std.mem.indexOf(u8, after, " ") orelse return null;
    return after[0..sp];
}

/// If a stale `index.hunk-backup` exists from a commit interrupted under a
/// pre-temp-index version of git-hunk, restore it over `index` and remove
/// it. Exits on restore failure. Current versions never write this backup;
/// this heals crashes from upgrades only.
pub fn legacyRecoverIndexBackup(allocator: Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git_dir = try git.runGitRevParseGitDir(allocator);
    defer allocator.free(git_dir);
    const index_path = try std.fmt.allocPrint(arena, "{s}/index", .{git_dir});
    const backup_path = try std.fmt.allocPrint(arena, "{s}/index.hunk-backup", .{git_dir});
    const io = defaultIo();
    const cwd = std.Io.Dir.cwd();

    _ = cwd.statFile(io, backup_path, .{}) catch return;
    std.debug.print("warning: stale index backup found from interrupted commit -- restoring original index\n", .{});
    std.Io.Dir.copyFile(cwd, backup_path, cwd, index_path, io, .{}) catch {
        std.debug.print("error: failed to restore index backup\n", .{});
        std.process.exit(1);
    };
    cwd.deleteFile(io, backup_path) catch {};
}

pub const CommitContext = struct {
    allocator: Allocator,
    patches: []const []const u8,
    binary_paths: []const []const u8,
    message: []const u8,
    amend: bool,
    three_way: bool,
    ref: ?[]const u8,
    env_map: *const std.process.Environ.Map,
};

/// Commit the target hunks through a throwaway GIT_INDEX_FILE index: build
/// HEAD (or HEAD~1 for --amend) in a temp index, stage only the target
/// hunks there, and run `git commit` against it. The user's real index is
/// never rewritten, so an abort at any point leaves their staged work
/// untouched (at worst a stray temp file in /tmp). Hooks run normally and
/// see exactly the content being committed via the inherited
/// GIT_INDEX_FILE. After a successful commit the real index is re-synced
/// with the new HEAD for the committed paths; failures there downgrade to
/// warnings because the commit already stands.
pub fn runTempIndexCommit(ctx: CommitContext) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1. Temp index seeded from HEAD (or HEAD~1 for amend).
    var tmp = try git.createTempIndex(ctx.allocator, ctx.env_map, "commit-");
    defer tmp.deinit();
    const read_tree_ref: []const u8 = if (ctx.amend) "HEAD~1" else "HEAD";
    try git.runGitReadTree(ctx.allocator, read_tree_ref, &tmp.env_map);

    // 2. Stage target hunks into the temp index (text via patch, binary via
    // git add). A --3way conflict would leave unmerged temp-index entries
    // that `git commit` refuses; abort early with a clear instruction.
    for (ctx.patches) |p| {
        const result = try git.runGitApply(ctx.allocator, p, .{ .target = .index, .three_way = ctx.three_way, .ref = ctx.ref, .env_map = &tmp.env_map });
        if (result == .applied_with_conflicts) {
            std.debug.print("error: --3way produced conflicts; cannot commit. Use `git hunk restore --ref <X> --3way <sha>` then resolve and `git commit` normally.\n", .{});
            return error.PatchFailed;
        }
    }
    if (ctx.binary_paths.len > 0) {
        try git.runGitAddFilesLenient(ctx.allocator, ctx.binary_paths, &tmp.env_map);
    }

    // Snapshot the user's staged paths before HEAD moves: the hook-path
    // cleanup below must never touch anything the user had staged.
    const user_staged_raw: ?[]u8 = git.runGitDiffCachedNames(ctx.allocator) catch null;
    defer if (user_staged_raw) |raw| ctx.allocator.free(raw);

    // 3. Commit from the temp index.
    const commit_output = try git.runGitCommit(ctx.allocator, .{ .message = ctx.message, .amend = ctx.amend, .env_map = &tmp.env_map });

    // 4. Sync the real index with the new HEAD; warning-only, the commit
    // already succeeded.
    syncRealIndex(ctx);

    // 5. Hook-created paths: files changed by the new commit that we didn't
    // target and the user hadn't staged (i.e. a pre-commit hook `git add`ed
    // them into the temp index). Without this they linger as phantom staged
    // deletions, since the real index never learned about them. Point their
    // index entries at the new HEAD. Best-effort cosmetic cleanup: any git
    // failure here just skips it.
    syncHookCreatedPaths(arena, ctx, user_staged_raw) catch {};

    return commit_output;
}

/// Re-apply the committed patches (and re-add committed binaries) to the
/// user's real index so it matches the new HEAD. Mirrors the --3way mode
/// used to land the patches so the synced content matches the merged
/// result. Continues past failures with a per-patch summary -- the commit
/// already stands, so everything here downgrades to warnings.
fn syncRealIndex(ctx: CommitContext) void {
    var failed_paths: std.ArrayList([]const u8) = .empty;
    defer failed_paths.deinit(ctx.allocator);
    for (ctx.patches) |p| {
        const r = git.runGitApply(ctx.allocator, p, .{ .target = .index, .three_way = ctx.three_way, .ref = ctx.ref }) catch {
            failed_paths.append(ctx.allocator, firstPatchPath(p) orelse "<unknown>") catch {};
            continue;
        };
        if (r == .applied_with_conflicts) {
            // 3-way left unmerged entries in the user's index. Capture the
            // path so the user knows what to resolve.
            failed_paths.append(ctx.allocator, firstPatchPath(p) orelse "<unknown>") catch {};
        }
    }
    if (failed_paths.items.len > 0) {
        std.debug.print("warning: commit succeeded but index sync failed for {d} patch(es) -- run 'git hunk add' to re-sync. First failure: {s}\n", .{ failed_paths.items.len, failed_paths.items[0] });
    }
    if (ctx.binary_paths.len > 0) {
        git.runGitAddFilesLenient(ctx.allocator, ctx.binary_paths, null) catch {
            std.debug.print("warning: commit succeeded but binary file index sync failed -- run 'git add' to re-sync\n", .{});
        };
    }
}

fn syncHookCreatedPaths(arena: Allocator, ctx: CommitContext, user_staged_raw: ?[]const u8) !void {
    const changed_raw = try git.runGitDiffTreeNames(ctx.allocator);
    defer ctx.allocator.free(changed_raw);
    const candidates = try computeHookCreatedPaths(arena, changed_raw, ctx.patches, ctx.binary_paths, user_staged_raw);
    if (candidates.len > 0) {
        try git.runGitResetFilesLenient(ctx.allocator, candidates);
    }
}

/// True if `path` was a commit target (text patch or binary) or was staged
/// by the user before the commit — i.e. anything that is NOT hook-created.
fn isTargetOrUserStaged(path: []const u8, patches: []const []const u8, binary_paths: []const []const u8, user_staged_raw: ?[]const u8) bool {
    for (patches) |p| {
        const target = firstPatchPath(p) orelse continue;
        if (std.mem.eql(u8, target, path)) return true;
    }
    for (binary_paths) |bp| {
        if (std.mem.eql(u8, bp, path)) return true;
    }
    if (user_staged_raw) |raw| {
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |staged| {
            if (staged.len > 0 and std.mem.eql(u8, staged, path)) return true;
        }
    }
    return false;
}

/// Pure core of the hook-created-path cleanup: from the newline list of
/// paths changed by the new commit, keep only those that were neither
/// commit targets nor user-staged. Results are arena-owned.
fn computeHookCreatedPaths(
    arena: Allocator,
    changed_raw: []const u8,
    patches: []const []const u8,
    binary_paths: []const []const u8,
    user_staged_raw: ?[]const u8,
) ![]const []const u8 {
    var candidates: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, changed_raw, '\n');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        if (isTargetOrUserStaged(path, patches, binary_paths, user_staged_raw)) continue;
        try candidates.append(arena, try arena.dupe(u8, path));
    }
    return candidates.toOwnedSlice(arena);
}

pub fn printCommitResults(stdout: *std.Io.Writer, opts: CommitOptions, matched: []const MatchedHunk, commit_output: []const u8) !void {
    const use_color = format.shouldUseColor(opts.output, opts.no_color);
    const count = try format.printMatchedHunks(stdout, matched, "committed", "committed", use_color, opts.output, opts.verbosity);
    if (opts.verbosity != .quiet and commit_output.len > 0) {
        std.debug.print("{s}\n", .{commit_output});
    }
    format.printHunkCountSummary(opts.verbosity, opts.output, count, "committed");
}

// ============================================================================
// Tests
// ============================================================================

test "firstPatchPath plain path" {
    const patch = "diff --git a/src/main.zig b/src/main.zig\n--- a/src/main.zig\n";
    try std.testing.expectEqualStrings("src/main.zig", firstPatchPath(patch).?);
}

test "firstPatchPath path with spaces" {
    const patch = "diff --git a/my file.txt b/my file.txt\n--- a/my file.txt\n";
    try std.testing.expectEqualStrings("my file.txt", firstPatchPath(patch).?);
}

test "firstPatchPath path containing ' b/' splits symmetrically" {
    const patch = "diff --git a/a b/c.txt b/a b/c.txt\n";
    try std.testing.expectEqualStrings("a b/c.txt", firstPatchPath(patch).?);
}

test "firstPatchPath non-header returns null" {
    try std.testing.expect(firstPatchPath("not a patch") == null);
}

test "computeHookCreatedPaths: hook-added path is a candidate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try computeHookCreatedPaths(arena, "hookfix.txt\n", &.{}, &.{}, null);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("hookfix.txt", out[0]);
}

test "computeHookCreatedPaths: text patch target is excluded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const patch = "diff --git a/target.txt b/target.txt\n--- a/target.txt\n+++ b/target.txt\n";
    const out = try computeHookCreatedPaths(arena, "target.txt\nhookfix.txt\n", &.{patch}, &.{}, null);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("hookfix.txt", out[0]);
}

test "computeHookCreatedPaths: binary target is excluded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try computeHookCreatedPaths(arena, "img.png\n", &.{}, &.{"img.png"}, null);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "computeHookCreatedPaths: user-staged path is excluded (incl. staged deletion)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try computeHookCreatedPaths(arena, "keep.txt\nhookfix.txt\n", &.{}, &.{}, "keep.txt\nother.txt\n");
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("hookfix.txt", out[0]);
}

test "computeHookCreatedPaths: empty input yields no candidates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try computeHookCreatedPaths(arena, "", &.{}, &.{}, null);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
