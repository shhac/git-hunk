//! Brute-force fuzzer for the diff parser. `zig build fuzz -- [iterations] [seed]`.
//!
//! Mutates realistic git-diff seeds and asserts parseDiff never panics,
//! never returns an error, and only produces hex hunk shas. Exists because
//! `zig build test --fuzz` is broken in Zig 0.16.0 (stdlib test_runner fails
//! to compile in fuzz mode); revisit when the toolchain fuzzer works.

const std = @import("std");
const diff_mod = @import("diff.zig");
const types = @import("types.zig");

const seeds = [_][]const u8{
    "diff --git a/f.txt b/f.txt\nindex 1234567..89abcde 100644\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,3 @@ fn ctx()\n line\n-old\n+new\n+added\n",
    "diff --git a/new.txt b/new.txt\nnew file mode 100644\nindex 0000000..e69de29\n",
    "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\nindex e69de29..0000000\n",
    "diff --git a/img.png b/img.png\nindex 1234567..89abcde 100644\nGIT binary patch\nliteral 5\nMc$`b\n\nliteral 0\nHc$@<O00001\n",
    "diff --git a/link b/link\nnew file mode 120000\nindex 0000000..1de5659\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+target\n\\ No newline at end of file\n",
    "diff --git a/sub b/sub\nindex 1234567..89abcde 160000\n--- a/sub\n+++ b/sub\n@@ -1 +1 @@\n-Subproject commit aaaa\n+Subproject commit bbbb\n",
    "diff --git a/r.txt b/s.txt\nsimilarity index 90%\nrename from r.txt\nrename to s.txt\nindex 1234567..89abcde 100644\n--- a/r.txt\n+++ b/s.txt\n@@ -1 +1 @@\n-a\n+b\n",
    "diff --git a/\"sp ace\" b/\"sp ace\"\nindex 1234567..89abcde 100644\n--- a/\"sp ace\"\n+++ b/\"sp ace\"\n@@ -5,3 +5,4 @@\n ctx\n-x\n+y\n+z\n",
    "diff --git a/m.txt b/m.txt\nold mode 100644\nnew mode 100755\nindex 1234567..89abcde\n--- a/m.txt\n+++ b/m.txt\n@@ -1 +1 @@\n-a\n+b\n@@ -10,2 +11,2 @@ second hunk\n c\n-d\n+e\n",
    "diff --git a/x b/x\n@@ -1 +1 @@\n",
};

const number_bombs = [_][]const u8{ "4294967295", "4294967296", "0", "-1", "99999999999999999999" };

fn mutate(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), rand: std.Random) !void {
    if (buf.items.len == 0) {
        try buf.append(gpa, rand.int(u8));
        return;
    }
    const idx = rand.uintLessThan(usize, buf.items.len);
    switch (rand.uintLessThan(u8, 8)) {
        0 => buf.items[idx] ^= rand.int(u8),
        1 => try buf.insert(gpa, idx, rand.int(u8)),
        2 => {
            const len = @min(rand.uintLessThan(usize, 32) + 1, buf.items.len - idx);
            try buf.replaceRange(gpa, idx, len, &.{});
        },
        3 => {
            var tmp: [64]u8 = undefined;
            const len = @min(rand.uintLessThan(usize, tmp.len) + 1, buf.items.len - idx);
            @memcpy(tmp[0..len], buf.items[idx..][0..len]);
            try buf.insertSlice(gpa, rand.uintLessThan(usize, buf.items.len + 1), tmp[0..len]);
        },
        4 => buf.shrinkRetainingCapacity(idx),
        5 => {
            // Replace a digit run with an extreme number to attack @@ header parsing.
            const digit_start = std.mem.indexOfAnyPos(u8, buf.items, idx, "0123456789") orelse return;
            var digit_end = digit_start;
            while (digit_end < buf.items.len and std.ascii.isDigit(buf.items[digit_end])) digit_end += 1;
            const bomb = number_bombs[rand.uintLessThan(usize, number_bombs.len)];
            try buf.replaceRange(gpa, digit_start, digit_end - digit_start, bomb);
        },
        6 => try buf.insert(gpa, idx, '\n'),
        7 => {
            const other = seeds[rand.uintLessThan(usize, seeds.len)];
            const start = rand.uintLessThan(usize, other.len);
            const len = @min(rand.uintLessThan(usize, 48) + 1, other.len - start);
            try buf.insertSlice(gpa, idx, other[start..][0..len]);
        },
        else => unreachable,
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iterations: u64 = if (args.len > 1) try std.fmt.parseInt(u64, args[1], 10) else 500_000;
    const seed: u64 = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 0x67697468756e6b;

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, seeds[rand.uintLessThan(usize, seeds.len)]);
        const n_mut = rand.uintLessThan(u8, 8) + 1;
        for (0..n_mut) |_| try mutate(gpa, &buf, rand);

        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        inline for ([_]types.DiffMode{ .unstaged, .staged }) |mode| {
            var hunks: std.ArrayList(types.Hunk) = .empty;
            diff_mod.parseDiff(arena, buf.items, mode, &hunks) catch |err| {
                std.debug.print("parseDiff error {s} at iteration {d} (seed {d})\ninput:\n{s}\n", .{ @errorName(err), i, seed, buf.items });
                return err;
            };
            for (hunks.items) |h| for (h.sha_hex) |c| if (!std.ascii.isHex(c)) {
                std.debug.print("non-hex sha at iteration {d} (seed {d})\ninput:\n{s}\n", .{ i, seed, buf.items });
                @panic("non-hex sha_hex");
            };
        }
    }
    std.debug.print("OK: {d} iterations survived (seed {d})\n", .{ iterations, seed });
}
