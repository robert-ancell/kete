//! Makes src/ui/pinyin_table.zig from the Unicode Han database (Unihan):
//! for each pinyin syllable (without tones, ü as v), the Simplified
//! Chinese characters read so, most used first, for the pinyin input
//! method (see input_method.zig). The characters are those of the Table of
//! General Standard Chinese Characters (kTGHZ2013), with its readings;
//! they are ordered by how often each is read so in the Hanyu Pinlu
//! Cidian's count (kHanyuPinlu), then by the school grade it is taught in
//! (kGradeLevel), then by code point. Unihan comes compressed; unpack it
//! first:
//!
//!     bzcat /usr/share/unicode/Unihan_Readings.txt.bz2 > /tmp/Unihan_Readings.txt
//!     bzcat /usr/share/unicode/Unihan_DictionaryLikeData.txt.bz2 > /tmp/Unihan_DictionaryLikeData.txt
//!     zig run tools/gen_pinyin.zig -- /tmp/Unihan_Readings.txt /tmp/Unihan_DictionaryLikeData.txt src/ui/pinyin_table.zig

const std = @import("std");

const Reading = struct {
    syllable: []const u8,
    cp: u21,
    count: u32,
    grade: u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: gen_pinyin <Unihan_Readings.txt> <Unihan_DictionaryLikeData.txt> <out.zig>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const readings_text = try cwd.readFileAlloc(init.io, args[1], arena, .limited(64 << 20));
    const like_text = try cwd.readFileAlloc(init.io, args[2], arena, .limited(64 << 20));

    // School grade by character.
    var grades: std.AutoHashMapUnmanaged(u21, u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, like_text, "\r\n");
    while (lines.next()) |line| {
        const cp, const field, const value = splitLine(line) orelse continue;
        if (!std.mem.eql(u8, field, "kGradeLevel")) continue;
        try grades.put(arena, cp, std.fmt.parseInt(u8, value, 10) catch 9);
    }
    // Counts by character and reading (kHanyuPinlu: "hǎo(6060) hāo(142)").
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    lines = std.mem.tokenizeAny(u8, readings_text, "\r\n");
    while (lines.next()) |line| {
        const cp, const field, const value = splitLine(line) orelse continue;
        if (!std.mem.eql(u8, field, "kHanyuPinlu")) continue;
        var it = std.mem.tokenizeScalar(u8, value, ' ');
        while (it.next()) |item| {
            const open = std.mem.indexOfScalar(u8, item, '(') orelse continue;
            const n = std.fmt.parseInt(u32, item[open + 1 .. item.len - 1], 10) catch 0;
            const syl = try plain(arena, item[0..open]);
            // Its tones together ("hǎo", "hāo" and "hào" are all "hao").
            const gop = try counts.getOrPut(arena, try std.fmt.allocPrint(arena, "{d}:{s}", .{ cp, syl }));
            gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + n;
        }
    }
    // The standard characters and their readings ("132.140:hǎo 133.010:hào").
    var all: std.ArrayList(Reading) = .empty;
    lines = std.mem.tokenizeAny(u8, readings_text, "\r\n");
    while (lines.next()) |line| {
        const cp, const field, const value = splitLine(line) orelse continue;
        if (!std.mem.eql(u8, field, "kTGHZ2013")) continue;
        var it = std.mem.tokenizeScalar(u8, value, ' ');
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        while (it.next()) |item| {
            const colon = std.mem.indexOfScalar(u8, item, ':') orelse continue;
            const syl = try plain(arena, item[colon + 1 ..]);
            if (syl.len == 0 or seen.contains(syl)) continue;
            try seen.put(arena, syl, {});
            const key = try std.fmt.allocPrint(arena, "{d}:{s}", .{ cp, syl });
            try all.append(arena, .{ .syllable = syl, .cp = cp, .count = counts.get(key) orelse 0, .grade = grades.get(cp) orelse 9 });
        }
    }
    std.mem.sort(Reading, all.items, {}, struct {
        fn lessThan(_: void, a: Reading, b: Reading) bool {
            const o = std.mem.order(u8, a.syllable, b.syllable);
            if (o != .eq) return o == .lt;
            if (a.count != b.count) return a.count > b.count;
            if (a.grade != b.grade) return a.grade < b.grade;
            return a.cp < b.cp;
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\//! Made by tools/gen_pinyin.zig from the Unicode Han database: each
        \\//! pinyin syllable (without tones; ü as v), and the Simplified Chinese
        \\//! characters read so (of the Table of General Standard Chinese
        \\//! Characters), most used first. Sorted by syllable.
        \\
        \\pub const syllables = [_]struct { []const u8, []const u8 }{
        \\
    );
    var i: usize = 0;
    var n_syllables: usize = 0;
    while (i < all.items.len) {
        const syl = all.items[i].syllable;
        try out.print(arena, "    .{{ \"{s}\", \"", .{syl});
        while (i < all.items.len and std.mem.eql(u8, all.items[i].syllable, syl)) : (i += 1) {
            var buf: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(all.items[i].cp, &buf);
            try out.appendSlice(arena, buf[0..len]);
        }
        try out.appendSlice(arena, "\" },\n");
        n_syllables += 1;
    }
    try out.appendSlice(arena, "};\n");
    const file = try cwd.createFile(init.io, args[3], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, out.items);
    std.debug.print("{d} syllables, {d} readings\n", .{ n_syllables, all.items.len });
}

/// "U+4F60\tkMandarin\tnǐ": the character, the field and its value.
fn splitLine(line: []const u8) ?struct { u21, []const u8, []const u8 } {
    if (!std.mem.startsWith(u8, line, "U+")) return null;
    var it = std.mem.splitScalar(u8, line, '\t');
    const cp_text = it.next() orelse return null;
    const field = it.next() orelse return null;
    const value = it.next() orelse return null;
    const cp = std.fmt.parseInt(u21, cp_text[2..], 16) catch return null;
    return .{ cp, field, value };
}

/// A syllable with its tone marks taken off, and ü as v: "nǚ" is "nv".
fn plain(a: std.mem.Allocator, syl: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = (std.unicode.Utf8View.init(syl) catch return "").iterator();
    while (it.nextCodepoint()) |c| {
        const b: u8 = switch (c) {
            'ā', 'á', 'ǎ', 'à' => 'a',
            'ē', 'é', 'ě', 'è', 'ê' => 'e',
            'ī', 'í', 'ǐ', 'ì' => 'i',
            'ō', 'ó', 'ǒ', 'ò' => 'o',
            'ū', 'ú', 'ǔ', 'ù' => 'u',
            'ü', 'ǖ', 'ǘ', 'ǚ', 'ǜ' => 'v',
            'ń', 'ň', 'ǹ' => 'n',
            'ḿ' => 'm',
            else => if (c < 0x80 and std.ascii.isAlphabetic(@intCast(c))) std.ascii.toLower(@intCast(c)) else continue,
        };
        try out.append(a, b);
    }
    return out.items;
}
