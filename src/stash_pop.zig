//! `stash pop`: put the newest stash entry back. Where `git stash pop` can,
//! it does the work, so the result is git's own. Where git would refuse
//! because a file the entry changes has other unstaged changes, the entry's
//! worktree changes are merged into that file instead, as git merges them
//! into a clean one: the index is left as it is, a conflict is recorded the
//! way git records one, and the entry is dropped only when everything went
//! back cleanly.

const std = @import("std");
const types = @import("types.zig");
const git = @import("git.zig");

const Allocator = std.mem.Allocator;
const Verbosity = types.Verbosity;
const defaultIo = types.getIo;

pub fn stashPop(allocator: Allocator, verbosity: Verbosity) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // With no entry, git says so itself.
    const stash = try git.resolveStash(arena) orelse return popNatively(allocator, verbosity);
    const untracked = try std.fmt.allocPrint(arena, "{s}^3", .{stash});
    const has_untracked = git.revisionExists(arena, untracked);
    // Git finds these only after merging the tracked changes, and stops
    // there with the merge done; checking first leaves nothing half-popped.
    if (has_untracked) try refuseUntrackedOverwrite(arena, untracked);

    const changes = try readStashedChanges(arena, stash);
    if (!try shouldMerge(arena, stash, changes)) return popNatively(allocator, verbosity);

    const conflicted = try mergeChanges(arena, changes);
    if (has_untracked) try restoreUntracked(arena, untracked);
    if (conflicted) {
        std.debug.print("The stash entry is kept in case you need it again.\n", .{});
        return error.PopConflicts;
    }
    try git.runGitStashDrop(arena);
    if (verbosity != .quiet) std.debug.print("popped stash@{{0}}\n", .{});
}

fn popNatively(allocator: Allocator, verbosity: Verbosity) !void {
    try git.runGitStashPop(allocator);
    if (verbosity != .quiet) std.debug.print("popped stash@{{0}}\n", .{});
}

/// One side of a path: its mode and blob id. A side without the path is null.
const Entry = struct {
    mode: []const u8,
    id: []const u8,

    fn same(a: ?Entry, b: ?Entry) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return std.mem.eql(u8, x.mode, y.mode) and std.mem.eql(u8, x.id, y.id);
    }

    fn isRegularFile(self: Entry) bool {
        return std.mem.startsWith(u8, self.mode, "100");
    }

    fn isGitlink(entry: ?Entry) bool {
        const e = entry orelse return false;
        return std.mem.eql(u8, e.mode, "160000");
    }
};

/// A path the entry's worktree changes touch: what the index held when the
/// stash was made (`stash^2`), and what the stash holds.
const Change = struct {
    path: []const u8,
    base: ?Entry,
    stashed: ?Entry,
};

fn readStashedChanges(arena: Allocator, stash: []const u8) ![]const Change {
    const index_commit = try std.fmt.allocPrint(arena, "{s}^2", .{stash});
    return parseRawDiff(arena, try git.runGitDiffTreeRaw(arena, index_commit, stash));
}

/// Parse `git diff-tree -r -z` raw output: a `:<old mode> <new mode> <old id>
/// <new id> <status>` field, then the path. Slices point into `raw`.
fn parseRawDiff(arena: Allocator, raw: []const u8) ![]const Change {
    var changes: std.ArrayList(Change) = .empty;
    var fields = std.mem.splitScalar(u8, raw, 0);
    while (fields.next()) |header| {
        if (header.len == 0) continue;
        const path = fields.next() orelse break;
        var parts = std.mem.splitScalar(u8, std.mem.trimStart(u8, header, ":"), ' ');
        const old_mode = parts.next() orelse continue;
        const new_mode = parts.next() orelse continue;
        const old_id = parts.next() orelse continue;
        const new_id = parts.next() orelse continue;
        try changes.append(arena, .{
            .path = path,
            .base = entryOf(old_mode, old_id),
            .stashed = entryOf(new_mode, new_id),
        });
    }
    return changes.items;
}

fn entryOf(mode: []const u8, id: []const u8) ?Entry {
    if (std.mem.eql(u8, mode, "000000")) return null;
    return .{ .mode = mode, .id = id };
}

/// Git pops an entry into files without unstaged changes, and refuses the
/// rest; merging is for what it refuses. Some of that it refuses for good
/// reason: an index that is mid-merge, a submodule, and an entry whose
/// staged changes to a file are no longer staged. An entry `git stash push`
/// made without `--keep-index` took those out of the worktree too, and
/// merging only its worktree changes would lose them.
fn shouldMerge(arena: Allocator, stash: []const u8, changes: []const Change) !bool {
    if (changes.len == 0) return false;
    const unstaged = try nameSet(arena, try git.runGitDiffUnstagedNames(arena));
    for (changes) |c| {
        if (unstaged.contains(c.path)) break;
    } else return false;

    for (changes) |c| {
        if (Entry.isGitlink(c.base) or Entry.isGitlink(c.stashed)) return false;
    }
    if (try git.indexHasUnmergedPaths(arena)) return false;

    const index_commit = try std.fmt.allocPrint(arena, "{s}^2", .{stash});
    const head_then = try std.fmt.allocPrint(arena, "{s}^1", .{stash});
    const staged_then = try nameSet(arena, try git.runGitDiffTreeNamesBetween(arena, head_then, index_commit));
    const index_moved = try nameSet(arena, try git.runGitDiffIndexCachedNames(arena, index_commit));
    for (changes) |c| {
        if (staged_then.contains(c.path) and index_moved.contains(c.path)) return false;
    }
    return true;
}

fn nameSet(arena: Allocator, names_z: []const u8) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    var it = std.mem.splitScalar(u8, names_z, 0);
    while (it.next()) |name| {
        if (name.len > 0) try set.put(arena, name, {});
    }
    return set;
}

/// Why a path could not go back cleanly, as git's merge names it.
const Conflict = enum { content, add_add, binary, deleted_in_stash, deleted_in_worktree };

/// What becomes of one path: `result` is what the worktree holds afterwards
/// (null for nothing), and a conflict is recorded in the index.
const Resolution = struct {
    result: ?Entry,
    conflict: ?Conflict = null,
};

/// Resolve a path by comparing whole sides, or return null when it takes a
/// line-by-line merge. `ours` is the path in the worktree now.
fn resolveWholeFile(change: Change, ours: ?Entry) ?Resolution {
    if (Entry.same(ours, change.stashed)) return .{ .result = ours };
    if (Entry.same(ours, change.base)) return .{ .result = change.stashed };
    // A deletion on one side against a change on the other keeps the
    // changed file, as git's modify/delete conflict does.
    const current = ours orelse return .{ .result = change.stashed, .conflict = .deleted_in_worktree };
    const stashed = change.stashed orelse return .{ .result = current, .conflict = .deleted_in_stash };
    const base_is_file = if (change.base) |b| b.isRegularFile() else true;
    if (current.isRegularFile() and stashed.isRegularFile() and base_is_file) return null;
    return .{ .result = current, .conflict = .content };
}

/// The mode a merged file keeps: the stash's, unless the worktree changed it.
fn mergedMode(base: ?Entry, ours: Entry, stashed: Entry) []const u8 {
    const b = base orelse return ours.mode;
    return if (std.mem.eql(u8, ours.mode, b.mode)) stashed.mode else ours.mode;
}

/// One path on its way back: the entry's change, the worktree's side, and
/// what becomes of it, null until decided.
const PathMerge = struct {
    change: Change,
    ours: ?Entry,
    resolution: ?Resolution,
};

/// Merge every change into the worktree. Returns true if any conflicted.
fn mergeChanges(arena: Allocator, changes: []const Change) !bool {
    var ours_index = try git.createTempIndex(arena, "pop-ours-");
    defer ours_index.deinit();
    const ours = try readWorktreeEntries(arena, changes, &ours_index);

    var scratch = try git.createTempIndex(arena, "pop-");
    defer scratch.deinit();
    var dir = try git.createTempDir(arena, "pop-");
    defer dir.deinit();

    const paths = try arena.alloc(PathMerge, changes.len);
    for (changes, ours, paths) |c, o, *p| p.* = .{ .change = c, .ours = o, .resolution = resolveWholeFile(c, o) };
    try mergeLines(arena, paths, &ours_index, &scratch, dir.path);

    try writeResults(arena, paths, &scratch);
    return recordConflicts(arena, paths);
}

/// Each changed path as git would stage it from the worktree now, read
/// through a copy of the index so git's own rules decide its mode and
/// content (core.fileMode, core.symlinks, clean filters).
fn readWorktreeEntries(arena: Allocator, changes: []const Change, ours_index: *git.TempIndex) ![]const ?Entry {
    var paths: std.ArrayList(u8) = .empty;
    for (changes) |c| try paths.print(arena, "{s}\x00", .{c.path});
    try git.copyIndexTo(arena, ours_index.path_z);
    try git.runGitUpdateIndexFromWorktree(arena, paths.items, &ours_index.env_map);
    const listing = try git.runGitLsFilesStaged(arena, &ours_index.env_map);

    var by_path: std.StringHashMapUnmanaged(Entry) = .empty;
    var it = std.mem.splitScalar(u8, listing, 0);
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        var fields = std.mem.splitScalar(u8, line[0..tab], ' ');
        const mode = fields.next() orelse continue;
        const id = fields.next() orelse continue;
        try by_path.put(arena, line[tab + 1 ..], .{ .mode = mode, .id = id });
    }
    const entries = try arena.alloc(?Entry, changes.len);
    for (changes, entries) |c, *e| e.* = by_path.get(c.path);
    return entries;
}

/// Merge the files still undecided with `git merge-file`, working on copies
/// of all three sides as the worktree would hold them, so line endings and
/// filters agree.
fn mergeLines(arena: Allocator, paths: []PathMerge, ours_index: *git.TempIndex, scratch: *git.TempIndex, dir: []const u8) !void {
    var names: std.ArrayList(u8) = .empty;
    var base_names: std.ArrayList(u8) = .empty;
    var base_info: std.ArrayList(u8) = .empty;
    var stashed_info: std.ArrayList(u8) = .empty;
    for (paths) |p| {
        if (p.resolution != null) continue;
        const c = p.change;
        try names.print(arena, "{s}\x00", .{c.path});
        if (c.base) |b| {
            try base_names.print(arena, "{s}\x00", .{c.path});
            try appendIndexInfo(arena, &base_info, b, 0, c.path);
        }
        try appendIndexInfo(arena, &stashed_info, c.stashed.?, 0, c.path);
    }
    if (names.items.len == 0) return;

    const ours_dir = try std.fmt.allocPrint(arena, "{s}/ours/", .{dir});
    const base_dir = try std.fmt.allocPrint(arena, "{s}/base/", .{dir});
    const stashed_dir = try std.fmt.allocPrint(arena, "{s}/stashed/", .{dir});
    try git.runGitCheckoutIndexPaths(arena, ours_dir, names.items, &ours_index.env_map);
    if (base_names.items.len > 0) {
        try git.runGitUpdateIndexInfo(arena, base_info.items, &scratch.env_map);
        try git.runGitCheckoutIndexPaths(arena, base_dir, base_names.items, &scratch.env_map);
    }
    try git.runGitUpdateIndexInfo(arena, stashed_info.items, &scratch.env_map);
    try git.runGitCheckoutIndexPaths(arena, stashed_dir, names.items, &scratch.env_map);

    for (paths) |*p| {
        if (p.resolution != null) continue;
        const c = p.change;
        const current = p.ours.?;
        const merged_file = try std.mem.concat(arena, u8, &.{ ours_dir, c.path });
        const base_file = if (c.base != null) try std.mem.concat(arena, u8, &.{ base_dir, c.path }) else "/dev/null";
        const stashed_file = try std.mem.concat(arena, u8, &.{ stashed_dir, c.path });
        const outcome = try git.runGitMergeFile(arena, merged_file, base_file, stashed_file);
        if (outcome == .binary) {
            p.resolution = .{ .result = current, .conflict = .binary };
            continue;
        }
        const id = try git.runGitHashObjectAs(arena, merged_file, c.path);
        const conflict: ?Conflict = if (outcome == .clean) null else if (c.base == null) .add_add else .content;
        p.resolution = .{ .result = .{ .mode = mergedMode(c.base, current, c.stashed.?), .id = id }, .conflict = conflict };
    }
}

/// One `git update-index --index-info` line, NUL-terminated.
fn appendIndexInfo(arena: Allocator, out: *std.ArrayList(u8), entry: Entry, stage: u2, path: []const u8) !void {
    try out.print(arena, "{s} {s} {d}\t{s}\x00", .{ entry.mode, entry.id, stage, path });
}

/// Put each path whose result differs from the worktree into the worktree:
/// checked out through `scratch`, so git writes it as it would any file it
/// checks out, or deleted.
fn writeResults(arena: Allocator, paths: []const PathMerge, scratch: *git.TempIndex) !void {
    var info: std.ArrayList(u8) = .empty;
    var names: std.ArrayList(u8) = .empty;
    for (paths) |p| {
        const r = p.resolution.?;
        if (Entry.same(p.ours, r.result)) continue;
        const result = r.result orelse {
            try deleteWorktreeFile(p.change.path);
            continue;
        };
        try appendIndexInfo(arena, &info, result, 0, p.change.path);
        try names.print(arena, "{s}\x00", .{p.change.path});
    }
    if (names.items.len == 0) return;
    try git.runGitUpdateIndexInfo(arena, info.items, &scratch.env_map);
    try git.runGitCheckoutIndexPaths(arena, null, names.items, &scratch.env_map);
}

/// Delete a file, and the directories it leaves empty, as git does.
fn deleteWorktreeFile(path: []const u8) !void {
    const io = defaultIo();
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteFile(io, path);
    var parent = std.fs.path.dirname(path);
    while (parent) |dir| : (parent = std.fs.path.dirname(dir)) {
        cwd.deleteDir(io, dir) catch return;
    }
}

/// Record each conflict in the index as git's merge does: the stage 0 entry
/// replaced by the base (stage 1), the worktree's side (2) and the stash's
/// (3), where each has the path. Prints git's report of each. Returns true
/// if there were any.
fn recordConflicts(arena: Allocator, paths: []const PathMerge) !bool {
    var info: std.ArrayList(u8) = .empty;
    for (paths) |p| {
        const conflict = p.resolution.?.conflict orelse continue;
        const c = p.change;
        reportConflict(conflict, c.path);
        const id_len = if (c.base) |b| b.id.len else if (c.stashed) |st| st.id.len else p.ours.?.id.len;
        // Mode 0 drops the path's entries so the stages can take its place.
        try info.appendSlice(arena, "0 ");
        try info.appendNTimes(arena, '0', id_len);
        try info.print(arena, "\t{s}\x00", .{c.path});
        if (c.base) |b| try appendIndexInfo(arena, &info, b, 1, c.path);
        if (p.ours) |current| try appendIndexInfo(arena, &info, current, 2, c.path);
        if (c.stashed) |st| try appendIndexInfo(arena, &info, st, 3, c.path);
    }
    if (info.items.len == 0) return false;
    try git.runGitUpdateIndexInfo(arena, info.items, null);
    return true;
}

/// git's words for each conflict, with the worktree as "Updated upstream"
/// and the entry as "Stashed changes", the names `git stash` gives them.
fn reportConflict(conflict: Conflict, path: []const u8) void {
    switch (conflict) {
        .content => std.debug.print("CONFLICT (content): Merge conflict in {s}\n", .{path}),
        .add_add => std.debug.print("CONFLICT (add/add): Merge conflict in {s}\n", .{path}),
        .binary => std.debug.print(
            "warning: Cannot merge binary files: {s} (Updated upstream vs. Stashed changes)\n" ++
                "CONFLICT (content): Merge conflict in {s}\n",
            .{ path, path },
        ),
        .deleted_in_stash => std.debug.print(
            "CONFLICT (modify/delete): {s} deleted in Stashed changes and modified in Updated upstream.  Version Updated upstream of {s} left in tree.\n",
            .{ path, path },
        ),
        .deleted_in_worktree => std.debug.print(
            "CONFLICT (modify/delete): {s} deleted in Updated upstream and modified in Stashed changes.  Version Stashed changes of {s} left in tree.\n",
            .{ path, path },
        ),
    }
}

/// Git will not write an untracked file from the entry over one that is
/// there, and says so per file.
fn refuseUntrackedOverwrite(arena: Allocator, untracked: []const u8) !void {
    const names = try git.runGitLsTreeNames(arena, untracked);
    const io = defaultIo();
    var refused = false;
    var it = std.mem.splitScalar(u8, names, 0);
    while (it.next()) |path| {
        if (path.len == 0) continue;
        _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch continue;
        std.debug.print("{s} already exists, no checkout\n", .{path});
        refused = true;
    }
    if (!refused) return;
    std.debug.print("error: could not restore untracked files from stash\n", .{});
    std.debug.print("The stash entry is kept in case you need it again.\n", .{});
    return error.PopRefused;
}

fn restoreUntracked(arena: Allocator, untracked: []const u8) !void {
    var tmp = try git.createTempIndex(arena, "pop-ut-");
    defer tmp.deinit();
    try git.runGitReadTree(arena, untracked, &tmp.env_map);
    try git.runGitCheckoutIndexAll(arena, &tmp.env_map);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseRawDiff: modes and ids per path, a missing side as null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const raw = ":100644 100755 aaaa bbbb M\x00a b.txt\x00" ++
        ":100644 000000 cccc 0000 D\x00gone\x00" ++
        ":000000 120000 0000 dddd A\x00link\x00";
    const changes = try parseRawDiff(arena_state.allocator(), raw);
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expectEqualStrings("a b.txt", changes[0].path);
    try testing.expectEqualStrings("100644", changes[0].base.?.mode);
    try testing.expectEqualStrings("bbbb", changes[0].stashed.?.id);
    try testing.expect(changes[1].stashed == null);
    try testing.expect(changes[2].base == null);
    try testing.expectEqualStrings("120000", changes[2].stashed.?.mode);
}

const e_base: Entry = .{ .mode = "100644", .id = "b" };
const e_ours: Entry = .{ .mode = "100644", .id = "o" };
const e_stashed: Entry = .{ .mode = "100644", .id = "s" };
const e_link: Entry = .{ .mode = "120000", .id = "l" };

test "resolveWholeFile: a side that matches settles the path" {
    const change: Change = .{ .path = "p", .base = e_base, .stashed = e_stashed };
    try testing.expect(Entry.same(resolveWholeFile(change, e_stashed).?.result, e_stashed));
    const untouched = resolveWholeFile(change, e_base).?;
    try testing.expect(Entry.same(untouched.result, e_stashed) and untouched.conflict == null);
    const deletion: Change = .{ .path = "p", .base = e_base, .stashed = null };
    try testing.expect(resolveWholeFile(deletion, e_base).?.result == null);
}

test "resolveWholeFile: two changed files take a line merge" {
    const change: Change = .{ .path = "p", .base = e_base, .stashed = e_stashed };
    try testing.expect(resolveWholeFile(change, e_ours) == null);
    const added: Change = .{ .path = "p", .base = null, .stashed = e_stashed };
    try testing.expect(resolveWholeFile(added, e_ours) == null);
}

test "resolveWholeFile: deletions and non-files conflict, keeping the changed side" {
    const change: Change = .{ .path = "p", .base = e_base, .stashed = e_stashed };
    const gone = resolveWholeFile(change, null).?;
    try testing.expectEqual(Conflict.deleted_in_worktree, gone.conflict.?);
    try testing.expect(Entry.same(gone.result, e_stashed));

    const deletion: Change = .{ .path = "p", .base = e_base, .stashed = null };
    const kept = resolveWholeFile(deletion, e_ours).?;
    try testing.expectEqual(Conflict.deleted_in_stash, kept.conflict.?);
    try testing.expect(Entry.same(kept.result, e_ours));

    const linked = resolveWholeFile(change, e_link).?;
    try testing.expectEqual(Conflict.content, linked.conflict.?);
    try testing.expect(Entry.same(linked.result, e_link));
}

test "mergedMode: the stash's mode unless the worktree changed it" {
    const exec_stashed: Entry = .{ .mode = "100755", .id = "s" };
    try testing.expectEqualStrings("100755", mergedMode(e_base, e_ours, exec_stashed));
    const exec_ours: Entry = .{ .mode = "100755", .id = "o" };
    try testing.expectEqualStrings("100755", mergedMode(e_base, exec_ours, e_stashed));
    try testing.expectEqualStrings("100644", mergedMode(null, e_ours, exec_stashed));
}
