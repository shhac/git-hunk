//! Single source of truth for CLI documentation facts: commands, flags,
//! arguments, examples, and man-page prose. Rendered at comptime into
//! `--help` text (help.zig, main.zig). `zig build docs` additionally
//! regenerates the man page's COMMANDS and GLOBAL OPTIONS sections from it,
//! and verifies flag coverage in skills/git-hunk/references/commands.md and
//! the shell completions (tools/gen_docs.zig).
//!
//! Prose specific to one surface (man DESCRIPTION, README narrative, skill
//! Behavior sections, completion plumbing) stays authored in that surface.
//! Only facts live here.

const std = @import("std");

pub const Flag = struct {
    long: []const u8,
    short: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    /// Accepted but useless flags (count's no-ops) are documented in help but
    /// excluded from shell completion suggestions.
    completion_hide: bool = false,
    /// Terse lines for `--help` (col-20 continuation).
    help_desc: []const []const u8,

    /// "-U, --unified <n>" style display string.
    pub fn display(comptime f: Flag) []const u8 {
        comptime {
            var s: []const u8 = if (f.short) |sh| sh ++ ", " ++ f.long else f.long;
            if (f.placeholder) |p| s = s ++ " " ++ p;
            return s;
        }
    }

    pub fn withHelp(comptime f: Flag, comptime desc: []const []const u8) Flag {
        var out = f;
        out.help_desc = desc;
        return out;
    }

    pub fn hidden(comptime f: Flag) Flag {
        var out = f;
        out.completion_hide = true;
        return out;
    }
};

/// Positional argument or subcommand row (label + col-20 description lines).
pub const Item = struct {
    label: []const u8,
    desc: []const []const u8,
};

pub const Example = struct {
    cmd: []const u8,
    /// Empty = no description column (commit's examples).
    desc: []const u8 = "",
};

/// Extra help section. Titled sections render a flush-left header;
/// title-less ones render as an indented note paragraph.
pub const Section = struct {
    title: ?[]const u8 = null,
    lines: []const []const u8,
};

pub const CommandSpec = struct {
    name: []const u8,
    /// Title line of `<cmd> --help` and default top-level summary.
    summary: []const u8,
    /// Top-level help summary when it differs from `summary`.
    top_summary: ?[]const u8 = null,
    /// Verbatim roff body lines for the man page COMMANDS entry.
    man_desc: []const []const u8,
    usage: []const []const u8,
    subcommands: []const Item = &.{},
    args: []const Item = &.{},
    /// Sections rendered before OPTIONS (count's OUTPUT).
    pre_options: []const Section = &.{},
    options_title: []const u8 = "OPTIONS",
    flags: []const Flag,
    /// Sections and notes rendered between OPTIONS and EXAMPLES.
    post_options: []const Section = &.{},
    examples: []const Example,

    pub fn topSummary(comptime c: CommandSpec) []const u8 {
        return c.top_summary orelse c.summary;
    }
};

// ============================================================================
// Shared flag bases
// ============================================================================

const ref_desc_base: []const []const u8 = &.{
    "Compare against a git ref instead of the default.",
    "Single ref (e.g. HEAD~1, abc123) is shorthand for `<ref>^..<ref>`,",
    "i.e. that commit's diff. Use a range (e.g. main..HEAD) to diff between two refs.",
};
// Only commands that accept --staged may claim to combine with it.
const ref_desc_with_staged: []const []const u8 = ref_desc_base ++
    [_][]const u8{"Combines with --staged for ref vs index comparison."};

pub const f_staged: Flag = .{
    .long = "--staged",
    .help_desc = &.{"List hunks from the staged (index) diff instead of worktree"},
};

pub const f_ref: Flag = .{
    .long = "--ref",
    .placeholder = "<refspec>",
    .help_desc = ref_desc_with_staged,
};

/// Variant for commands that reject --staged (add, reset, restore, commit).
pub const f_ref_no_staged: Flag = f_ref.withHelp(ref_desc_base);

pub const f_file: Flag = .{
    .long = "--file",
    .placeholder = "<path>",
    .help_desc = &.{"Restrict to hunks in the given file (repeatable)"},
};

pub const f_porcelain: Flag = .{
    .long = "--porcelain",
    .help_desc = &.{"Machine-readable output"},
};

pub const f_no_color: Flag = .{
    .long = "--no-color",
    .help_desc = &.{"Disable colored output"},
};

pub const f_oneline: Flag = .{
    .long = "--oneline",
    .help_desc = &.{"One hunk per line: hash, file, and line range"},
};

pub const f_tracked_only: Flag = .{
    .long = "--tracked-only",
    .help_desc = &.{"Only include hunks from tracked files"},
};

pub const f_untracked_only: Flag = .{
    .long = "--untracked-only",
    .help_desc = &.{"Only include hunks from untracked files"},
};

pub const f_unified: Flag = .{
    .long = "--unified",
    .short = "-U",
    .placeholder = "<n>",
    .help_desc = &.{"Lines of diff context (default: git's diff.context or 3)"},
};

pub const f_verbose: Flag = .{
    .long = "--verbose",
    .short = "-v",
    .help_desc = &.{"Show summary counts"},
};

pub const f_quiet: Flag = .{
    .long = "--quiet",
    .short = "-q",
    .help_desc = &.{"Suppress output"},
};

pub const f_help: Flag = .{
    .long = "--help",
    .short = "-h",
    .help_desc = &.{"Show this help"},
};

pub const f_all: Flag = .{
    .long = "--all",
    .help_desc = &.{"Stage all unstaged hunks"},
};

pub const f_3way: Flag = .{
    .long = "--3way",
    .help_desc = &.{"On context drift, fall back to a 3-way merge instead of failing."},
};

// ============================================================================
// Commands
// ============================================================================

pub const commands = [_]CommandSpec{
    .{
        .name = "list",
        .summary = "List diff hunks with content hashes",
        .man_desc = &.{
            "List diff hunks with content hashes. Shows unstaged hunks by default;",
            "use \\fB\\-\\-staged\\fR to show staged hunks.",
        },
        .usage = &.{"git-hunk list [options]"},
        .flags = &.{
            f_staged,
            f_ref,
            f_file.withHelp(&.{
                "Restrict output to hunks in the given file",
                "(repeatable: pass multiple --file flags to match any of them)",
            }),
            f_porcelain.withHelp(&.{"Machine-readable output (tab-separated fields)"}),
            f_oneline,
            f_no_color,
            f_tracked_only.withHelp(&.{"Only show hunks from tracked files"}),
            f_untracked_only.withHelp(&.{"Only show hunks from untracked files"}),
            f_unified,
            f_verbose,
            f_quiet,
            f_help,
        },
        .examples = &.{
            .{ .cmd = "git-hunk list", .desc = "List all unstaged hunks" },
            .{ .cmd = "git-hunk list --oneline", .desc = "Compact one-line-per-hunk output" },
            .{ .cmd = "git-hunk list --staged", .desc = "List hunks in the staging area" },
            .{ .cmd = "git-hunk list --file src/main.zig", .desc = "List hunks for a specific file" },
            .{ .cmd = "git-hunk list --porcelain --oneline", .desc = "Machine-readable compact output" },
            .{ .cmd = "git-hunk list --unified 0", .desc = "List hunks with no surrounding context" },
            .{ .cmd = "git-hunk list --ref HEAD~1", .desc = "List hunks from the last commit" },
            .{ .cmd = "git-hunk list --ref main..HEAD", .desc = "List all changes vs main" },
        },
    },
    .{
        .name = "diff",
        .summary = "Show diff content of specific hunks",
        .man_desc = &.{"Show the diff content of specific hunks identified by hash."},
        .usage = &.{"git-hunk diff [options] <sha[:lines]>..."},
        .args = &.{.{
            .label = "<sha[:lines]>...",
            .desc = &.{
                "One or more hunk hashes (prefix match, min 4 hex chars).",
                "Append :lines to select specific lines (e.g. a3f7:3-5,8).",
            },
        }},
        .flags = &.{
            f_staged.withHelp(&.{"Show hunks from the staged diff instead of worktree"}),
            f_ref,
            f_file,
            f_porcelain,
            f_no_color,
            f_tracked_only.withHelp(&.{"Only show hunks from tracked files"}),
            f_untracked_only.withHelp(&.{"Only show hunks from untracked files"}),
            f_unified,
            f_verbose,
            f_quiet,
            f_help,
        },
        .examples = &.{
            .{ .cmd = "git-hunk diff a3f7c21", .desc = "Show a hunk by full hash" },
            .{ .cmd = "git-hunk diff a3f7 b82e", .desc = "Show multiple hunks by prefix" },
            .{ .cmd = "git-hunk diff a3f7c21 --staged", .desc = "Show a staged hunk" },
            .{ .cmd = "git-hunk diff a3f7:3-5,8", .desc = "Show specific lines of a hunk" },
            .{ .cmd = "git-hunk diff --ref HEAD~1 a3f7", .desc = "Show a hunk from the last commit" },
        },
    },
    .{
        .name = "add",
        .summary = "Stage hunks (or selected lines) by hash",
        .man_desc = &.{
            "Stage hunks (or selected lines within a hunk) by hash.",
            "Use \\fB\\-\\-all\\fR to stage all hunks.",
        },
        .usage = &.{"git-hunk add [options] [<sha[:lines]>...]"},
        .args = &.{.{
            .label = "<sha[:lines]>...",
            .desc = &.{
                "Hunk hashes to stage (prefix match, min 4 hex chars).",
                "Append :lines to stage specific lines (e.g. a3f7:3-5,8).",
                "Optional when --all or --file is used.",
            },
        }},
        .flags = &.{
            f_ref_no_staged,
            f_all,
            f_3way.withHelp(&.{
                "On context drift, fall back to a 3-way merge instead of failing",
                "(passes --3way to git apply; useful with --ref <past-commit>).",
            }),
            f_file.withHelp(&.{"Stage all hunks in the given file (repeatable)"}),
            f_porcelain,
            f_no_color,
            f_tracked_only,
            f_untracked_only,
            f_unified,
            f_verbose,
            f_quiet,
            f_help,
        },
        .examples = &.{
            .{ .cmd = "git-hunk add a3f7c21", .desc = "Stage a single hunk" },
            .{ .cmd = "git-hunk add a3f7 b82e", .desc = "Stage multiple hunks by prefix" },
            .{ .cmd = "git-hunk add --all", .desc = "Stage all unstaged hunks" },
            .{ .cmd = "git-hunk add --file src/main.zig", .desc = "Stage all hunks in a file" },
            .{ .cmd = "git-hunk add a3f7:3-5,8", .desc = "Stage specific lines from a hunk" },
        },
    },
    .{
        .name = "reset",
        .summary = "Unstage hunks (or selected lines) by hash",
        .man_desc = &.{
            "Unstage hunks (or selected lines within a hunk) by hash.",
            "Use \\fB\\-\\-all\\fR to unstage all staged hunks.",
        },
        .usage = &.{"git-hunk reset [options] [<sha[:lines]>...]"},
        .args = &.{.{
            .label = "<sha[:lines]>...",
            .desc = &.{
                "Staged hunk hashes to unstage (use `list --staged` to find).",
                "Prefix match, min 4 hex chars. Append :lines for specific lines.",
                "Optional when --all or --file is used.",
            },
        }},
        .flags = &.{
            f_ref_no_staged,
            f_all.withHelp(&.{"Unstage all staged hunks"}),
            f_3way,
            f_file.withHelp(&.{"Unstage all hunks in the given file (repeatable)"}),
            f_porcelain,
            f_no_color,
            f_tracked_only,
            f_untracked_only,
            f_unified,
            f_verbose,
            f_quiet,
            f_help,
        },
        .examples = &.{
            .{ .cmd = "git-hunk reset a3f7c21", .desc = "Unstage a single hunk" },
            .{ .cmd = "git-hunk reset --all", .desc = "Unstage all staged hunks" },
            .{ .cmd = "git-hunk reset --file src/main.zig", .desc = "Unstage all hunks in a file" },
        },
    },
    .{
        .name = "restore",
        .summary = "Restore unstaged worktree changes by hash",
        .man_desc = &.{
            "Restore unstaged worktree changes by hash.",
            "Use \\fB\\-\\-all\\fR to restore all unstaged changes.",
            "Use \\fB\\-\\-force\\fR to restore untracked files (deletes them permanently).",
        },
        .usage = &.{"git-hunk restore [options] [<sha[:lines]>...]"},
        .args = &.{.{
            .label = "<sha[:lines]>...",
            .desc = &.{
                "Hunk hashes to restore (prefix match, min 4 hex chars).",
                "Append :lines for specific lines. Optional when --all or --file is used.",
            },
        }},
        .flags = &.{
            f_ref_no_staged,
            f_all.withHelp(&.{"Restore all unstaged hunks (DESTRUCTIVE)"}),
            f_3way.withHelp(&.{
                "On context drift, fall back to a 3-way merge instead of failing",
                "(useful for \"undo this hunk from history\" when surrounding lines drifted).",
            }),
            f_file.withHelp(&.{"Restore all hunks in the given file (repeatable)"}),
            .{
                .long = "--force",
                .help_desc = &.{"Required to restore untracked files (deletes them permanently)"},
            },
            .{
                .long = "--dry-run",
                .help_desc = &.{"Show what would be restored without making changes"},
            },
            f_porcelain,
            f_no_color,
            f_tracked_only,
            f_untracked_only,
            f_unified,
            f_verbose,
            f_quiet,
            f_help,
        },
        .post_options = &.{.{
            .lines = &.{
                "WARNING: This command is DESTRUCTIVE. Restored changes cannot be recovered.",
                "Untracked files require --force to restore (they will be deleted entirely).",
                "Use --dry-run to preview before restoring.",
            },
        }},
        .examples = &.{
            .{ .cmd = "git-hunk restore a3f7c21", .desc = "Restore a single hunk" },
            .{ .cmd = "git-hunk restore --all", .desc = "Restore all unstaged changes" },
            .{ .cmd = "git-hunk restore --dry-run a3f7c21", .desc = "Preview what would be restored" },
            .{ .cmd = "git-hunk restore a3f7:3-5", .desc = "Restore specific lines from a hunk" },
            .{ .cmd = "git-hunk restore --force a3f7c21", .desc = "Restore an untracked file (deletes it)" },
        },
    },
    .{
        .name = "count",
        .summary = "Count diff hunks",
        .top_summary = "Count diff hunks (bare integer output)",
        .man_desc = &.{"Count diff hunks. Outputs a bare integer for scripting."},
        .usage = &.{"git-hunk count [options]"},
        .pre_options = &.{.{
            .title = "OUTPUT",
            .lines = &.{"Prints a single integer (the number of hunks) and always exits 0."},
        }},
        .flags = &.{
            f_staged.withHelp(&.{"Count staged hunks instead of unstaged"}),
            f_ref,
            f_file.withHelp(&.{"Count hunks in the given file only (repeatable)"}),
            f_porcelain.withHelp(&.{"No effect (output is already machine-readable)"}).hidden(),
            f_no_color.withHelp(&.{"No effect (output is never colored)"}).hidden(),
            f_tracked_only.withHelp(&.{"Only count hunks from tracked files"}),
            f_untracked_only.withHelp(&.{"Only count hunks from untracked files"}),
            f_unified,
            f_verbose.withHelp(&.{"No effect (accepted for interface consistency)"}).hidden(),
            f_quiet,
            f_help,
        },
        .examples = &.{
            .{ .cmd = "git-hunk count", .desc = "Count all unstaged hunks" },
            .{ .cmd = "git-hunk count --staged", .desc = "Count staged hunks" },
            .{ .cmd = "git-hunk count --file src/main.zig", .desc = "Count hunks in a specific file" },
        },
    },
    .{
        .name = "check",
        .summary = "Validate hunk hashes exist in current diff",
        .man_desc = &.{
            "Validate that hunk hashes exist in the current diff.",
            "Exits 0 if all hashes are valid, non\\-zero otherwise.",
        },
        .usage = &.{"git-hunk check [options] <sha>..."},
        .args = &.{.{
            .label = "<sha>...",
            .desc = &.{"One or more hunk hashes to validate (no line specs allowed)."},
        }},
        .flags = &.{
            f_staged.withHelp(&.{"Check against staged diff instead of worktree"}),
            f_ref,
            .{
                .long = "--exclusive",
                .help_desc = &.{"Assert these are the ONLY hunks in the diff (exits 1 otherwise)"},
            },
            .{
                .long = "--allow-empty",
                .help_desc = &.{"Allow zero SHA arguments (useful with --exclusive to assert no hunks)"},
            },
            f_file.withHelp(&.{"Restrict check to hunks in the given file (repeatable)"}),
            f_porcelain,
            f_no_color,
            f_tracked_only.withHelp(&.{"Only check hunks from tracked files"}),
            f_untracked_only.withHelp(&.{"Only check hunks from untracked files"}),
            f_unified,
            f_verbose,
            f_quiet,
            f_help,
        },
        .post_options = &.{.{
            .title = "EXIT STATUS",
            .lines = &.{
                "0  All specified hashes exist (and are exclusive, if --exclusive)",
                "1  One or more hashes not found, or extra hunks exist with --exclusive",
            },
        }},
        .examples = &.{
            .{ .cmd = "git-hunk check a3f7c21", .desc = "Verify a hash exists" },
            .{ .cmd = "git-hunk check a3f7 b82e", .desc = "Verify multiple hashes" },
            .{ .cmd = "git-hunk check --exclusive a3f7 b82e", .desc = "Assert these are the only hunks" },
            .{ .cmd = "git-hunk check --exclusive --allow-empty --staged", .desc = "Assert no staged hunks exist" },
        },
    },
    .{
        .name = "stash",
        .summary = "Stash hunks into git stash, remove from worktree",
        .man_desc = &.{
            "Stash hunks into git stash, removing them from the worktree.",
            "Use \\fBstash push\\fR (implicit default) to save hunks and \\fBstash pop\\fR to restore.",
            "Use \\fB\\-\\-include\\-untracked\\fR / \\fB\\-u\\fR to include untracked files with \\fB\\-\\-all\\fR.",
        },
        .usage = &.{
            "git-hunk stash [push] [options] [<sha>...]",
            "git-hunk stash pop",
        },
        .subcommands = &.{
            .{ .label = "push", .desc = &.{"Stash hunks (default when omitted)"} },
            .{ .label = "pop", .desc = &.{"Restore the most recent git-hunk stash"} },
        },
        .args = &.{.{
            .label = "<sha>...",
            .desc = &.{
                "Hunk hashes to stash (no line specs). Optional when --all",
                "or --file is used.",
            },
        }},
        .options_title = "OPTIONS (push only)",
        .flags = &.{
            f_all.withHelp(&.{"Stash all unstaged tracked hunks"}),
            .{
                .long = "--include-untracked",
                .short = "-u",
                .help_desc = &.{"Include untracked files (use with --all)"},
            },
            f_file.withHelp(&.{"Stash all hunks in the given file (repeatable)"}),
            .{
                .long = "--message",
                .short = "-m",
                .placeholder = "<msg>",
                .help_desc = &.{"Set the stash message"},
            },
            f_porcelain,
            f_no_color,
            f_tracked_only,
            f_untracked_only,
            f_unified,
            f_verbose,
            f_quiet,
            f_help,
        },
        .post_options = &.{.{
            .lines = &.{
                "Note: --all without -u stashes only tracked changes (like git stash push).",
                "Explicit hashes always stash the specified hunks regardless of -u.",
            },
        }},
        .examples = &.{
            .{ .cmd = "git-hunk stash a3f7c21", .desc = "Stash a single hunk" },
            .{ .cmd = "git-hunk stash --all", .desc = "Stash all tracked unstaged hunks" },
            .{ .cmd = "git-hunk stash --all -u", .desc = "Stash all hunks including untracked" },
            .{ .cmd = "git-hunk stash push -m \"wip\"", .desc = "Stash with a message" },
            .{ .cmd = "git-hunk stash pop", .desc = "Restore the most recent stash" },
        },
    },
    .{
        .name = "commit",
        .summary = "Commit specific hunks directly, bypassing manual staging",
        .man_desc = &.{
            "Commit specific hunks directly, bypassing manual staging.",
            "Existing staged changes are preserved and restored afterwards.",
            "Accepts hashes, line selections, \\fB\\-\\-all\\fR, or \\fB\\-\\-file\\fR to choose what to commit.",
            "Use \\fB\\-m\\fR to set the commit message and \\fB\\-\\-amend\\fR to amend the previous commit.",
            "Use \\fB\\-\\-dry\\-run\\fR to preview what would be committed.",
        },
        .usage = &.{"git-hunk commit [options] [<sha[:lines]>...]"},
        .args = &.{.{
            .label = "<sha[:lines]>...",
            .desc = &.{
                "Hunk hashes to commit (prefix match, min 4 hex chars).",
                "Append :lines to commit specific lines (e.g. a3f7:3-5,8).",
                "Optional when --all or --file is used.",
            },
        }},
        .flags = &.{
            .{
                .long = "--message",
                .short = "-m",
                .placeholder = "<msg>",
                .help_desc = &.{"Commit message (required unless --dry-run)"},
            },
            .{
                .long = "--amend",
                .help_desc = &.{"Amend the previous commit"},
            },
            .{
                .long = "--dry-run",
                .help_desc = &.{"Show what would be committed without committing"},
            },
            f_all.withHelp(&.{"Commit all unstaged hunks"}),
            f_3way,
            f_file.withHelp(&.{"Commit all hunks in a file (repeatable)"}),
            f_ref_no_staged,
            f_unified,
            f_tracked_only,
            f_untracked_only,
            f_no_color,
            f_porcelain,
            f_verbose,
            f_quiet,
            f_help,
        },
        .post_options = &.{.{
            .lines = &.{"Note: --staged is not supported. Use 'git commit' directly for staged changes."},
        }},
        .examples = &.{
            .{ .cmd = "git-hunk commit a3f7 b82e -m \"feat: add validation\"" },
            .{ .cmd = "git-hunk commit --all -m \"feat: everything\"" },
            .{ .cmd = "git-hunk commit --file src/foo.zig -m \"refactor: cleanup\"" },
            .{ .cmd = "git-hunk commit a3f7:3-5 -m \"fix: specific lines\"" },
            .{ .cmd = "git-hunk commit a3f7 --amend -m \"fix: forgotten change\"" },
            .{ .cmd = "git-hunk commit --dry-run a3f7 -m \"check first\"" },
        },
    },
};

pub fn get(comptime name: []const u8) CommandSpec {
    comptime {
        for (&commands) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c.*;
        }
        @compileError("unknown command: " ++ name);
    }
}

// ============================================================================
// Top-level help (printUsage)
// ============================================================================

/// Common options shown in top-level help. Descriptions are the cross-command
/// summaries, not any single command's wording.
pub const top_common_options = [_]Flag{
    f_unified.withHelp(&.{"Lines of diff context (default: git's diff.context or 3)"}),
    f_file.withHelp(&.{"Restrict to hunks in a specific file"}),
    f_tracked_only.withHelp(&.{"Only include hunks from tracked files"}),
    f_untracked_only.withHelp(&.{"Only include hunks from untracked files"}),
    f_porcelain.withHelp(&.{"Machine-readable tab-separated output"}),
    f_no_color.withHelp(&.{"Disable colored output"}),
    f_verbose.withHelp(&.{"Show summary counts and hints"}),
    f_quiet.withHelp(&.{"Suppress all output except errors"}),
    .{ .long = "--version", .short = "-V", .help_desc = &.{"Show version"} },
    f_help.withHelp(&.{"Show help for a command"}),
};

pub const top_examples = [_]Example{
    .{ .cmd = "git-hunk list", .desc = "List unstaged hunks" },
    .{ .cmd = "git-hunk add a3f7c21", .desc = "Stage a hunk by hash" },
    .{ .cmd = "git-hunk add a3f7:3-5,8", .desc = "Stage specific lines from a hunk" },
    .{ .cmd = "git-hunk add --all", .desc = "Stage all unstaged hunks" },
    .{ .cmd = "git-hunk list --staged --oneline", .desc = "Verify what's staged" },
};

pub const top_footer: []const []const u8 = &.{
    "Run 'git-hunk <command> --help' for detailed usage of each command.",
    "",
    "note: 'git hunk --help' opens the man page. Use 'git hunk help [command]'",
    "for inline help when using the git subcommand form.",
};

// ============================================================================
// Man page GLOBAL OPTIONS (verbatim roff; man-specific wording/aggregation)
// ============================================================================

pub const ManOption = struct {
    /// The roff header line following .TP (e.g. ".BR \-h \", \" \-\-help").
    header: []const u8,
    lines: []const []const u8,
};

pub const man_global_options = [_]ManOption{
    .{ .header = ".BR \\-h \", \" \\-\\-help", .lines = &.{
        "Show help. Use \\fBgit\\-hunk \\fI<command>\\fR \\fB\\-\\-help\\fR for command\\-specific details.",
    } },
    .{ .header = ".BR \\-V \", \" \\-\\-version", .lines = &.{
        "Show version.",
    } },
    .{ .header = ".BR \\-U \", \" \\-\\-unified \" \" \\fIn\\fR", .lines = &.{
        "Lines of diff context (default: git's \\fBdiff.context\\fR or 3).",
    } },
    .{ .header = ".BI \\-\\-file \" path\"", .lines = &.{
        "Restrict to hunks in a specific file. May be repeated to match any of several files.",
    } },
    .{ .header = ".B \\-\\-porcelain", .lines = &.{
        "Machine\\-readable tab\\-separated output.",
    } },
    .{ .header = ".BR \\-v \", \" \\-\\-verbose", .lines = &.{
        "Show summary counts and hints.",
    } },
    .{ .header = ".BR \\-q \", \" \\-\\-quiet", .lines = &.{
        "Suppress all output (exit code only).",
    } },
    .{ .header = ".B \\-\\-no\\-color", .lines = &.{
        "Disable colored output.",
    } },
    .{ .header = ".B \\-\\-tracked\\-only", .lines = &.{
        "Only include hunks from tracked files (exclude untracked files).",
    } },
    .{ .header = ".B \\-\\-untracked\\-only", .lines = &.{
        "Only include hunks from untracked files (exclude tracked file changes).",
    } },
    .{ .header = ".BI \\-\\-ref \" refspec\"", .lines = &.{
        "Compare against a git ref instead of the default.",
        "A single ref (e.g. \\fBHEAD~1\\fR, \\fBabc123\\fR) is shorthand for",
        "\\fI<ref>\\fB^..\\fI<ref>\\fR, i.e. that commit's diff.",
        "Use a range (e.g. \\fBmain..HEAD\\fR) to diff between two refs.",
        "With \\fBlist\\fR, \\fBdiff\\fR, \\fBcount\\fR, or \\fBcheck\\fR, combines with \\fB\\-\\-staged\\fR for ref vs index comparison.",
        "With \\fBadd\\fR, \\fBreset\\fR, \\fBrestore\\fR, or \\fBcommit\\fR, this enables",
        "cherry\\-picking or reverting individual hunks from past commits.",
    } },
    .{ .header = ".B \\-\\-3way", .lines = &.{
        "On context drift, fall back to a 3\\-way merge instead of failing",
        "(passes \\fB\\-\\-3way\\fR to \\fBgit apply\\fR).",
        "Applies to \\fBadd\\fR, \\fBreset\\fR, \\fBrestore\\fR, and \\fBcommit\\fR;",
        "useful with \\fB\\-\\-ref\\fR \\fI<past\\-commit>\\fR.",
    } },
};
