//! Unresolved merge conflicts. A conflicted path has an index entry per side
//! of the merge and no staged version, so it has no hunks: git diff writes it
//! as a combined diff git-hunk does not read, and `git add -p` skips it as
//! "needs merge". Without these messages it would simply be missing, and a
//! command that left it out would look as if there were nothing to do.
//!
//! Unlike the verbose-only notes for paths with no hunk, these are shown by
//! default: a conflict blocks the merge, rebase or cherry-pick the user is in
//! the middle of, so it is never something they can safely not hear about.

const std = @import("std");
const types = @import("types.zig");
const git = @import("git.zig");
const path_mod = @import("path.zig");

const Allocator = std.mem.Allocator;
const MatchedHunk = types.MatchedHunk;

/// What a command does to hunks, for saying what it did not do to a
/// conflicted path. Each tag is the verb itself.
pub const Action = enum {
    list,
    count,
    check,
    show,
    stage,
    unstage,
    restore,
    commit,
    stash,

    fn pastTense(self: Action) []const u8 {
        return switch (self) {
            .list => "listed",
            .count => "counted",
            .check => "checked",
            .show => "shown",
            .stage => "staged",
            .unstage => "unstaged",
            .restore => "restored",
            .commit => "committed",
            .stash => "stashed",
        };
    }

    fn hint(self: Action) Hint {
        return if (self == .restore) .discard else .resolve;
    }
};

/// The way past a conflicted path: finish resolving it, or, for a command
/// that discards changes, start the file over.
const Hint = enum { resolve, discard };

/// Notes past this many are summed up in one line: a large merge can stop
/// with hundreds of conflicts, and every listing would repeat them all.
const max_notes = 10;

/// Of the index's conflicted paths, those a command reading `common` passes
/// over: all of them, or none for a source that never reads the index.
pub fn passedOver(common: types.Common, unmerged: []const []const u8) []const []const u8 {
    return if (readsIndex(common)) unmerged else &.{};
}

/// `passedOver` for a command that has not read the conflicted paths itself,
/// without asking git when it could not pass over any.
pub fn loadPassedOver(arena: Allocator, common: types.Common) ![]const []const u8 {
    if (!readsIndex(common)) return &.{};
    return git.runGitUnmergedPaths(arena);
}

/// History sources compare commits, never the index, and a conflicted path
/// is tracked, so --untracked-only never meets one either.
fn readsIndex(common: types.Common) bool {
    if (common.diff_filter == .untracked_only) return false;
    return switch (common.source) {
        .worktree, .index, .index_against => true,
        .rev, .range => false,
    };
}

/// Note each conflicted path in the --file scope as left out of `action`,
/// then say how to resolve them. Prints nothing when none are in scope.
pub fn noteLeftOut(arena: Allocator, paths: []const []const u8, file_filter: []const []const u8, action: Action) !void {
    var in_scope: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        if (types.matchesFileFilter(p, file_filter)) try in_scope.append(arena, p);
    }
    if (in_scope.items.len == 0) return;
    printNotes(in_scope.items, action);
    try printResolveHint(arena, action.hint(), onlyPath(in_scope.items));
}

/// A note per path, capped, each saying what `left_out` did not do to it.
fn printNotes(paths: []const []const u8, left_out: ?Action) void {
    for (paths[0..@min(paths.len, max_notes)]) |p| {
        std.debug.print("note: {s}: unresolved merge conflict", .{p});
        if (left_out) |action| std.debug.print(" — not {s}", .{action.pastTense()});
        std.debug.print("\n", .{});
    }
    if (paths.len <= max_notes) return;
    std.debug.print("note: {d} more unresolved merge conflicts ('git diff --name-only --diff-filter=U' lists them all)\n", .{paths.len - max_notes});
}

fn onlyPath(paths: []const []const u8) ?[]const u8 {
    return if (paths.len == 1) paths[0] else null;
}

/// Exit if --file names a conflicted path: the user asked for that file, and
/// leaving it out with only a note would read as done.
pub fn exitIfNamed(arena: Allocator, paths: []const []const u8, file_filter: []const []const u8, action: Action) !void {
    for (paths) |p| {
        for (file_filter) |f| {
            if (std.mem.eql(u8, f, p)) try refuseTouched(arena, p, action);
        }
    }
}

/// Exit if a selected hunk writes a conflicted path, which a hunk from
/// `--ref` can. git's own hunk-level commands refuse one as "needs merge".
pub fn exitIfWritten(arena: Allocator, paths: []const []const u8, matched: []const MatchedHunk, action: Action) !void {
    for (paths) |p| {
        for (matched) |m| {
            if (writes(m, p)) try refuseTouched(arena, p, action);
        }
    }
}

/// Whether applying `m` changes `path`: its own path, or the one a rename
/// takes it from. A copy leaves its source as it was.
fn writes(m: MatchedHunk, path: []const u8) bool {
    if (std.mem.eql(u8, m.hunk.file_path, path)) return true;
    const from = m.hunk.section.renamed_from_path orelse return false;
    return std.mem.eql(u8, from, path);
}

fn refuseTouched(arena: Allocator, path: []const u8, action: Action) !noreturn {
    std.debug.print("error: cannot {s} '{s}' while it has an unresolved merge conflict\n", .{ @tagName(action), path });
    try printResolveHint(arena, action.hint(), path);
    std.process.exit(1);
}

/// Exit if any path is conflicted: `what` ("stash", "pop a stash") needs the
/// whole index resolved, as git's own command does.
pub fn refuseAny(arena: Allocator, paths: []const []const u8, what: []const u8) !void {
    if (paths.len == 0) return;
    if (paths.len == 1) {
        std.debug.print("error: cannot {s} while '{s}' has an unresolved merge conflict\n", .{ what, paths[0] });
    } else {
        std.debug.print("error: cannot {s} while {d} files have unresolved merge conflicts\n", .{ what, paths.len });
        printNotes(paths, null);
    }
    try printResolveHint(arena, .resolve, onlyPath(paths));
    std.process.exit(1);
}

/// A merge, cherry-pick or revert waiting for its commit, which must record
/// the whole resolution.
const Sequence = struct {
    head: []const u8,
    name: []const u8,
    conclude: []const u8,
    abort: []const u8,
};

const sequences = [_]Sequence{
    .{ .head = "MERGE_HEAD", .name = "merge", .conclude = "git commit", .abort = "git merge --abort" },
    .{ .head = "CHERRY_PICK_HEAD", .name = "cherry-pick", .conclude = "git cherry-pick --continue", .abort = "git cherry-pick --abort" },
    .{ .head = "REVERT_HEAD", .name = "revert", .conclude = "git revert --continue", .abort = "git revert --abort" },
};

/// Exit if a merge, cherry-pick or revert is waiting for its commit: one of
/// some hunks would conclude it with only those hunks in it. git refuses this
/// too ("cannot do a partial commit during a merge"); for a revert it lets the
/// commit through and loses the revert, which is refused here as well.
pub fn refusePartialCommit(arena: Allocator, paths: []const []const u8) !void {
    const seq = pendingSequence(arena) orelse return;
    std.debug.print("error: cannot commit selected hunks during a {s}; its commit must record the whole resolution\n", .{seq.name});
    if (paths.len == 0) {
        std.debug.print("hint: run '{s}' to conclude the {s} (or '{s}' to abandon it), then commit hunks\n", .{ seq.conclude, seq.name, seq.abort });
        std.process.exit(1);
    }
    printNotes(paths, null);
    const p = try shellArgOrPlaceholder(arena, onlyPath(paths));
    std.debug.print("hint: resolve the conflicts and mark each resolved with 'git add {s}' (or 'git rm {s}'), then run '{s}' to conclude the {s} (or '{s}' to abandon it)\n", .{ p, p, seq.conclude, seq.name, seq.abort });
    std.process.exit(1);
}

fn pendingSequence(arena: Allocator) ?Sequence {
    for (sequences) |seq| {
        if (git.revisionExists(arena, seq.head)) return seq;
    }
    return null;
}

/// How to get past a conflicted path, naming it when there is one.
/// Discarding means giving up the resolution in progress, which git does by
/// path.
fn printResolveHint(arena: Allocator, hint: Hint, path: ?[]const u8) !void {
    const p = try shellArgOrPlaceholder(arena, path);
    if (hint == .discard) {
        std.debug.print("hint: a conflicted file has no hunks; 'git checkout --merge -- {s}' recreates its conflict markers, or 'git checkout --ours -- {s}' (or --theirs) takes one side\n", .{ p, p });
        return;
    }
    std.debug.print("hint: a conflicted file has no hunks; resolve the conflict, then mark it resolved with 'git add {s}' (or 'git rm {s}' to delete it)\n", .{ p, p });
}

fn shellArgOrPlaceholder(arena: Allocator, path: ?[]const u8) ![]const u8 {
    const rel = path orelse return "<path>";
    return path_mod.shellArgFromCwd(arena, types.getRepoPrefix(), rel);
}

// ============================================================================
// Tests
// ============================================================================

test "writes: a hunk writes its own path and a rename's source, not a copy's" {
    const plain = types.testMakeHunk("a.txt", 1, 1, 1, 1);
    try std.testing.expect(writes(.{ .hunk = &plain, .line_spec = null }, "a.txt"));
    try std.testing.expect(!writes(.{ .hunk = &plain, .line_spec = null }, "b.txt"));

    const renamed_section: types.FileSection = .{ .renamed_from_path = "old.txt" };
    var renamed = types.testMakeHunk("new.txt", 1, 1, 1, 1);
    renamed.section = &renamed_section;
    try std.testing.expect(writes(.{ .hunk = &renamed, .line_spec = null }, "old.txt"));
    try std.testing.expect(writes(.{ .hunk = &renamed, .line_spec = null }, "new.txt"));

    const copied_section: types.FileSection = .{ .copied_from_path = "src.txt" };
    var copied = types.testMakeHunk("copy.txt", 1, 1, 1, 1);
    copied.section = &copied_section;
    try std.testing.expect(!writes(.{ .hunk = &copied, .line_spec = null }, "src.txt"));
}

test "passedOver: only sources that read the index pass over a conflict" {
    const unmerged = [_][]const u8{"f.txt"};
    const reading = [_]types.Common{
        .{ .source = .worktree },
        .{ .source = .index },
        .{ .source = .{ .index_against = .{ .text = "X" } } },
        .{ .source = .worktree, .diff_filter = .tracked_only },
    };
    for (reading) |common| try std.testing.expectEqual(@as(usize, 1), passedOver(common, &unmerged).len);
    const not_reading = [_]types.Common{
        .{ .source = .{ .rev = .{ .ref = .{ .text = "X" }, .base = "X^" } } },
        .{ .source = .{ .range = .{ .text = "A..B", .from = "A", .to = "B" } } },
        .{ .source = .worktree, .diff_filter = .untracked_only },
    };
    for (not_reading) |common| try std.testing.expectEqual(@as(usize, 0), passedOver(common, &unmerged).len);
}
