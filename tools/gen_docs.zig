//! Documentation generator and drift gate. `zig build docs [-- --check]`.
//!
//! Generates (from src/spec.zig, between GENERATED markers):
//!   - doc/git-hunk.1 COMMANDS and GLOBAL OPTIONS sections
//! Verifies (always):
//!   - skills/git-hunk/references/commands.md documents every spec flag per
//!     command, and its Flags tables mention no unknown flags
//!   - completions/git-hunk.bash per-command opts exactly match the spec
//!   - completions/_git-hunk and completions/git-hunk.fish mention every
//!     completable flag
//!
//! With --check, the man page must already match its generated content
//! (CI drift gate); without it, the man page is rewritten in place.

const std = @import("std");
const spec = @import("spec");

const man_path = "doc/git-hunk.1";
const commands_md_path = "skills/git-hunk/references/commands.md";
const bash_path = "completions/git-hunk.bash";
const zsh_paths = [_][]const u8{ "completions/_git-hunk", "completions/_git_hunk" };
const fish_path = "completions/git-hunk.fish";

// ============================================================================
// Comptime-generated man sections
// ============================================================================

const man_commands_section: []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var out: []const u8 = "";
    for (spec.commands) |c| {
        out = out ++ ".TP\n.B " ++ c.name ++ "\n";
        for (c.man_desc) |line| out = out ++ line ++ "\n";
    }
    break :blk out;
};

const man_global_options_section: []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var out: []const u8 = "";
    for (spec.man_global_options) |opt| {
        out = out ++ ".TP\n" ++ opt.header ++ "\n";
        for (opt.lines) |line| out = out ++ line ++ "\n";
    }
    break :blk out;
};

// ============================================================================
// Marker splicing
// ============================================================================

fn beginMarker(comptime name: []const u8) []const u8 {
    return ".\\\" GENERATED-BEGIN " ++ name;
}
fn endMarker(comptime name: []const u8) []const u8 {
    return ".\\\" GENERATED-END " ++ name;
}

const Failure = struct {
    problems: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator,

    fn add(self: *Failure, comptime fmt: []const u8, args: anytype) !void {
        try self.problems.append(self.gpa, try std.fmt.allocPrint(self.gpa, fmt, args));
    }
};

fn spliceRegion(
    gpa: std.mem.Allocator,
    content: []const u8,
    comptime name: []const u8,
    generated: []const u8,
) ![]const u8 {
    const begin = beginMarker(name);
    const end = endMarker(name);
    const begin_at = std.mem.indexOf(u8, content, begin) orelse {
        std.debug.print("error: marker '{s}' not found in {s}\n", .{ begin, man_path });
        return error.MarkerNotFound;
    };
    const after_begin = std.mem.indexOfScalarPos(u8, content, begin_at, '\n') orelse return error.MarkerNotFound;
    const end_at = std.mem.indexOfPos(u8, content, after_begin, end) orelse {
        std.debug.print("error: marker '{s}' not found in {s}\n", .{ end, man_path });
        return error.MarkerNotFound;
    };
    return std.mem.concat(gpa, u8, &.{
        content[0 .. after_begin + 1],
        generated,
        content[end_at..],
    });
}

// ============================================================================
// commands.md coverage
// ============================================================================

fn sectionFor(md: []const u8, comptime name: []const u8) ?[]const u8 {
    const heading = "\n## git-hunk " ++ name ++ "\n";
    const at = std.mem.indexOf(u8, md, heading) orelse return null;
    const body_start = at + heading.len;
    const next = std.mem.indexOfPos(u8, md, body_start, "\n## ") orelse md.len;
    return md[body_start..next];
}

/// Extracts `--flag` tokens from the first cell of Flags-table rows.
fn checkFlagsTable(fail: *Failure, comptime c: spec.CommandSpec, section: []const u8) !void {
    const table_at = std.mem.indexOf(u8, section, "### Flags") orelse {
        try fail.add("commands.md: {s}: no '### Flags' table", .{c.name});
        return;
    };
    const table_end = std.mem.indexOfPos(u8, section, table_at + 1, "\n###") orelse section.len;
    var lines = std.mem.splitScalar(u8, section[table_at..table_end], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| `")) continue;
        // First cell only: up to the second unescaped '|'.
        const cell_end = std.mem.indexOfPos(u8, line, 1, "|") orelse continue;
        const cell = line[1..cell_end];
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, cell, i, "--")) |at| {
            var e = at + 2;
            while (e < cell.len and (std.ascii.isAlphanumeric(cell[e]) or cell[e] == '-')) e += 1;
            i = e;
            if (e == at + 2) continue; // bare "--" separator
            const token = cell[at..e];
            const known = inline for (c.flags) |f| {
                if (std.mem.eql(u8, f.long, token)) break true;
            } else false;
            if (!known) try fail.add("commands.md: {s}: Flags table documents unknown flag {s}", .{ c.name, token });
        }
        // Only rows until the table ends (blank line breaks the startsWith match anyway).
    }
}

fn checkCommandsMd(fail: *Failure, md: []const u8) !void {
    inline for (spec.commands) |c| {
        if (sectionFor(md, c.name)) |section| {
            inline for (c.flags) |f| {
                // --help is documented once, globally.
                if (comptime std.mem.eql(u8, f.long, "--help")) continue;
                if (std.mem.indexOf(u8, section, f.long) == null) {
                    try fail.add("commands.md: {s}: flag {s} is not documented", .{ c.name, f.long });
                }
            }
            try checkFlagsTable(fail, c, section);
        } else {
            try fail.add("commands.md: missing section '## git-hunk {s}'", .{c.name});
        }
    }
}

// ============================================================================
// Completions coverage
// ============================================================================

fn expectedBashOpts(comptime c: spec.CommandSpec) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        for (c.flags) |f| {
            if (f.completion_hide) continue;
            if (f.short) |s| out = out ++ [_][]const u8{s};
            out = out ++ [_][]const u8{f.long};
        }
        return out;
    }
}

fn checkBashCompletion(fail: *Failure, gpa: std.mem.Allocator, bash: []const u8) !void {
    inline for (spec.commands) |c| {
        try checkBashCommand(fail, gpa, bash, c);
    }
}

fn checkBashCommand(fail: *Failure, gpa: std.mem.Allocator, bash: []const u8, comptime c: spec.CommandSpec) !void {
    const case_label = "    " ++ c.name ++ ")";
    const case_at = std.mem.indexOf(u8, bash, case_label) orelse {
        try fail.add("bash completion: no case arm for '{s}'", .{c.name});
        return;
    };
    const opts_start = std.mem.indexOfPos(u8, bash, case_at, "opts=\"") orelse {
        try fail.add("bash completion: {s}: no opts= line", .{c.name});
        return;
    };
    const list_start = opts_start + "opts=\"".len;
    const list_end = std.mem.indexOfScalarPos(u8, bash, list_start, '"') orelse return;
    const actual_str = bash[list_start..list_end];

    var actual: std.ArrayList([]const u8) = .empty;
    defer actual.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, actual_str, ' ');
    while (it.next()) |tok| try actual.append(gpa, tok);

    const expected = comptime expectedBashOpts(c);
    inline for (expected) |e| {
        const present = for (actual.items) |tok| {
            if (std.mem.eql(u8, e, tok)) break true;
        } else false;
        if (!present) try fail.add("bash completion: {s}: missing {s}", .{ c.name, e });
    }
    for (actual.items) |tok| {
        const known = inline for (expected) |e| {
            if (std.mem.eql(u8, e, tok)) break true;
        } else false;
        if (!known) try fail.add("bash completion: {s}: extra flag {s} not in spec", .{ c.name, tok });
    }
}

/// fish declares long flags as `-l name` (no dashes); zsh embeds `--name`.
fn checkPresence(fail: *Failure, content: []const u8, file_label: []const u8, comptime fish_style: bool) !void {
    inline for (spec.commands) |c| {
        inline for (c.flags) |f| {
            if (f.completion_hide) continue;
            const needle = if (comptime fish_style) "-l " ++ f.long[2..] else f.long;
            if (std.mem.indexOf(u8, content, needle) == null) {
                try fail.add("{s}: flag {s} ({s}) never mentioned", .{ file_label, f.long, c.name });
            }
        }
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main(init: std.process.Init) !void {
    // Run-once tool: everything comes from the process arena, freed at exit.
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);

    if (args.len < 2) {
        std.debug.print("usage: gen-docs <repo-root> [--check]\n", .{});
        std.process.exit(2);
    }
    const root_path = args[1];
    const check_only = args.len > 2 and std.mem.eql(u8, args[2], "--check");

    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);

    const limit: std.Io.Limit = .limited(16 * 1024 * 1024);

    // --- Man page generation ---
    const man = try root.readFileAlloc(io, man_path, gpa, limit);
    const spliced1 = try spliceRegion(gpa, man, "commands", man_commands_section);
    const spliced2 = try spliceRegion(gpa, spliced1, "global-options", man_global_options_section);

    var fail = Failure{ .gpa = gpa };

    if (std.mem.eql(u8, man, spliced2)) {
        std.debug.print("{s}: up to date\n", .{man_path});
    } else if (check_only) {
        try fail.add("{s}: generated sections are stale -- run `zig build docs`", .{man_path});
    } else {
        try root.writeFile(io, .{ .sub_path = man_path, .data = spliced2 });
        std.debug.print("{s}: regenerated\n", .{man_path});
    }

    // --- Coverage checks ---
    const md = try root.readFileAlloc(io, commands_md_path, gpa, limit);
    try checkCommandsMd(&fail, md);

    const bash = try root.readFileAlloc(io, bash_path, gpa, limit);
    try checkBashCompletion(&fail, gpa, bash);

    var zsh_all: std.ArrayList(u8) = .empty;
    for (zsh_paths) |p| {
        const content = try root.readFileAlloc(io, p, gpa, limit);
        try zsh_all.appendSlice(gpa, content);
    }
    try checkPresence(&fail, zsh_all.items, "zsh completion", false);

    const fish = try root.readFileAlloc(io, fish_path, gpa, limit);
    try checkPresence(&fail, fish, "fish completion", true);

    if (fail.problems.items.len > 0) {
        for (fail.problems.items) |p| std.debug.print("FAIL: {s}\n", .{p});
        std.debug.print("{d} documentation drift problem(s) found\n", .{fail.problems.items.len});
        std.process.exit(1);
    }
    std.debug.print("docs: all coverage checks passed\n", .{});
}
