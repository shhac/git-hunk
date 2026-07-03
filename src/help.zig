//! Renders `--help` text at comptime from the documentation spec (spec.zig).
//! Layout: item descriptions at column 20 (flags/args/subcommands) or 41
//! (examples); items wider than the column break onto their own line.

const std = @import("std");
const spec = @import("spec.zig");

pub const Command = enum {
    list,
    diff,
    add,
    reset,
    restore,
    count,
    check,
    stash,
    commit,
};

pub fn commandFromString(s: []const u8) ?Command {
    const map = std.StaticStringMap(Command).initComptime(.{
        .{ "list", .list },
        .{ "diff", .diff },
        .{ "add", .add },
        .{ "reset", .reset },
        .{ "restore", .restore },
        .{ "count", .count },
        .{ "check", .check },
        .{ "stash", .stash },
        .{ "commit", .commit },
    });
    return map.get(s);
}

pub fn printCommandHelp(stdout: *std.Io.Writer, cmd: Command) !void {
    switch (cmd) {
        inline else => |c| try stdout.writeAll(comptime renderCommandHelp(spec.get(@tagName(c)))),
    }
}

const item_col = 20;
const example_col = 41;

fn spaces(comptime n: usize) []const u8 {
    return " " ** n;
}

/// "  <label><pad><desc line>" with continuation lines indented to `col`.
/// Labels too wide for the column (min gap 1) go on their own line.
fn renderItem(comptime label: []const u8, comptime desc: []const []const u8, comptime col: usize) []const u8 {
    comptime {
        if (desc.len == 0) return "  " ++ label ++ "\n";
        var out: []const u8 = "";
        var first: []const u8 = undefined;
        if (2 + label.len + 1 > col) {
            out = out ++ "  " ++ label ++ "\n";
            first = spaces(col);
        } else {
            first = "  " ++ label ++ spaces(col - 2 - label.len);
        }
        for (desc, 0..) |line, i| {
            out = out ++ (if (i == 0) first else spaces(col)) ++ line ++ "\n";
        }
        return out;
    }
}

fn renderSection(comptime s: spec.Section) []const u8 {
    comptime {
        var out: []const u8 = "\n";
        if (s.title) |t| out = out ++ t ++ "\n";
        for (s.lines) |line| out = out ++ "  " ++ line ++ "\n";
        return out;
    }
}

fn renderExamples(comptime examples: []const spec.Example) []const u8 {
    comptime {
        var out: []const u8 = "\nEXAMPLES\n";
        for (examples) |ex| {
            const desc: []const []const u8 = if (ex.desc.len == 0) &.{} else &.{ex.desc};
            out = out ++ renderItem(ex.cmd, desc, example_col);
        }
        return out;
    }
}

fn renderCommandHelp(comptime c: spec.CommandSpec) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const u8 = "git-hunk " ++ c.name ++ " - " ++ c.summary ++ "\n";

        out = out ++ "\nUSAGE\n";
        for (c.usage) |u| out = out ++ "  " ++ u ++ "\n";

        if (c.subcommands.len > 0) {
            out = out ++ "\nSUBCOMMANDS\n";
            for (c.subcommands) |s| out = out ++ renderItem(s.label, s.desc, item_col);
        }

        if (c.args.len > 0) {
            out = out ++ "\nARGUMENTS\n";
            for (c.args) |a| out = out ++ renderItem(a.label, a.desc, item_col);
        }

        for (c.pre_options) |s| out = out ++ renderSection(s);

        out = out ++ "\n" ++ c.options_title ++ "\n";
        for (c.flags) |f| out = out ++ renderItem(f.display(), f.help_desc, item_col);

        for (c.post_options) |s| out = out ++ renderSection(s);

        out = out ++ renderExamples(c.examples);
        return out;
    }
}

/// Top-level help body (everything after the runtime version line).
pub const top_help: []const u8 = renderTopHelp();

fn renderTopHelp() []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const u8 = "\nusage: git-hunk <command> [options] [args]\n";

        out = out ++ "\ncommands:\n";
        for (spec.commands) |c| out = out ++ renderItem(c.name, &.{c.topSummary()}, 12);

        out = out ++ "\ncommon options:\n";
        for (spec.top_common_options) |f| out = out ++ renderItem(f.display(), f.help_desc, item_col);

        out = out ++ "\nexamples:\n";
        for (spec.top_examples) |ex| out = out ++ renderItem(ex.cmd, &.{ex.desc}, 38);

        out = out ++ "\n";
        for (spec.top_footer) |line| out = out ++ line ++ "\n";
        return out;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "renderItem pads to column with min gap" {
    try std.testing.expectEqualStrings("  --staged          Desc\n", comptime renderItem("--staged", &.{"Desc"}, 20));
    // 17-char label leaves exactly one space.
    try std.testing.expectEqualStrings("  -U, --unified <n> Desc\n", comptime renderItem("-U, --unified <n>", &.{"Desc"}, 20));
}

test "renderItem breaks wide labels onto their own line" {
    try std.testing.expectEqualStrings(
        "  -u, --include-untracked\n                    Desc\n",
        comptime renderItem("-u, --include-untracked", &.{"Desc"}, 20),
    );
}

test "renderItem without description emits bare label" {
    try std.testing.expectEqualStrings("  git-hunk commit --all -m \"x\"\n", comptime renderItem("git-hunk commit --all -m \"x\"", &.{}, 41));
}

test "every command renders with required sections" {
    inline for (spec.commands) |c| {
        const text = comptime renderCommandHelp(c);
        try std.testing.expect(std.mem.indexOf(u8, text, "USAGE") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "EXAMPLES") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "git-hunk " ++ c.name) != null);
    }
}

test "top help contains commands block terminated by blank line" {
    // test_help.sh 605 parses: /^commands:/,/^$/ with space-indented name-first lines.
    const idx = std.mem.indexOf(u8, top_help, "\ncommands:\n").?;
    const after = top_help[idx + "\ncommands:\n".len ..];
    const end = std.mem.indexOf(u8, after, "\n\n").?;
    var it = std.mem.splitScalar(u8, after[0..end], '\n');
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) {
        try std.testing.expect(std.mem.startsWith(u8, line, "  "));
    }
    try std.testing.expectEqual(spec.commands.len, n);
}
