//! Makes src/ui/kana_table.zig from the Unicode Han database (Unihan): for
//! each reading (in hiragana), the kanji read so, for the Japanese input
//! method (see input_method.zig). The kanji are the Jōyō (common use) ones
//! (kJoyoKanji: not the Jinmeiyō, for names, which would double the table
//! for little), with their readings (kJapanese: on in katakana, kun in
//! hiragana).
//!
//! Unihan does not say where a kun reading's okurigana (the kana written
//! after the kanji) starts, so it is guessed, for readings that look like
//! verbs and adjectives ("たべる", "たかい"): the last kana, or the last two
//! for "-eru", "-iru" and "-shii" ("た|べる", "たか|い", "あたら|しい"). The
//! kanji is given for the stem ("た": 食), and with its okurigana for the
//! whole ("たべる": 食べる). The guesses are sometimes wrong ("か|える" for
//! 帰る, which is "かえ|る"); input_method.zig has the common words right.
//!
//! The kanji read the same are ordered by their readings first, then their
//! stems, each by the school grade
//! China teaches them in (kGradeLevel) and how often Chinese uses them
//! (kHanyuPinlu), which Unihan has and which follow Japanese use well
//! enough, then by code point. Unihan comes compressed; unpack it first:
//!
//!     bzcat /usr/share/unicode/Unihan_Readings.txt.bz2 > /tmp/Unihan_Readings.txt
//!     bzcat /usr/share/unicode/Unihan_DictionaryLikeData.txt.bz2 > /tmp/Unihan_DictionaryLikeData.txt
//!     bzcat /usr/share/unicode/Unihan_OtherMappings.txt.bz2 > /tmp/Unihan_OtherMappings.txt
//!     zig run tools/gen_kana.zig -- /tmp/Unihan_Readings.txt /tmp/Unihan_DictionaryLikeData.txt /tmp/Unihan_OtherMappings.txt src/ui/kana_table.zig

const std = @import("std");

const Kanji = struct {
    cp: u21,
    grade: u8,
    count: u32,

    fn before(a: Kanji, b: Kanji) bool {
        if (a.grade != b.grade) return a.grade < b.grade;
        if (a.count != b.count) return a.count > b.count;
        return a.cp < b.cp;
    }
};

const Entry = struct {
    reading: []const u8,
    kanji: Kanji,
    /// For a whole kun reading: the okurigana after the kanji.
    okurigana: ?[]const u8 = null,
    /// A kun reading's stem (guessed), not a reading.
    stem: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.debug.print("usage: gen_kana <Unihan_Readings.txt> <Unihan_DictionaryLikeData.txt> <Unihan_OtherMappings.txt> <out.zig>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const readings_text = try cwd.readFileAlloc(init.io, args[1], arena, .limited(64 << 20));
    const like_text = try cwd.readFileAlloc(init.io, args[2], arena, .limited(64 << 20));
    const other_text = try cwd.readFileAlloc(init.io, args[3], arena, .limited(64 << 20));

    var kanji: std.AutoHashMapUnmanaged(u21, Kanji) = .empty;
    var lines = std.mem.tokenizeAny(u8, other_text, "\r\n");
    while (lines.next()) |line| {
        const cp, const field, _ = splitLine(line) orelse continue;
        if (!std.mem.eql(u8, field, "kJoyoKanji")) continue;
        try kanji.put(arena, cp, .{ .cp = cp, .grade = 9, .count = 0 });
    }
    lines = std.mem.tokenizeAny(u8, like_text, "\r\n");
    while (lines.next()) |line| {
        const cp, const field, const value = splitLine(line) orelse continue;
        if (!std.mem.eql(u8, field, "kGradeLevel")) continue;
        if (kanji.getPtr(cp)) |k| k.grade = std.fmt.parseInt(u8, value, 10) catch 9;
    }
    lines = std.mem.tokenizeAny(u8, readings_text, "\r\n");
    while (lines.next()) |line| {
        const cp, const field, const value = splitLine(line) orelse continue;
        if (!std.mem.eql(u8, field, "kHanyuPinlu")) continue;
        const k = kanji.getPtr(cp) orelse continue;
        var it = std.mem.tokenizeScalar(u8, value, ' ');
        while (it.next()) |item| {
            const open = std.mem.indexOfScalar(u8, item, '(') orelse continue;
            k.count += std.fmt.parseInt(u32, item[open + 1 .. item.len - 1], 10) catch 0;
        }
    }

    var entries: std.ArrayList(Entry) = .empty;
    lines = std.mem.tokenizeAny(u8, readings_text, "\r\n");
    while (lines.next()) |line| {
        const cp, const field, const value = splitLine(line) orelse continue;
        if (!std.mem.eql(u8, field, "kJapanese")) continue;
        const k = kanji.get(cp) orelse continue;
        var it = std.mem.tokenizeScalar(u8, value, ' ');
        while (it.next()) |item| {
            const kun, const r = try hiragana(arena, item) orelse continue;
            try entries.append(arena, .{ .reading = r, .kanji = k });
            if (!kun) continue;
            const stem = stemLength(r) orelse continue;
            try entries.append(arena, .{ .reading = r[0..stem], .kanji = k, .stem = true });
            try entries.append(arena, .{ .reading = r, .kanji = k, .okurigana = r[stem..] });
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            const o = std.mem.order(u8, a.reading, b.reading);
            if (o != .eq) return o == .lt;
            if (a.stem != b.stem) return !a.stem;
            return a.kanji.before(b.kanji);
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\//! Made by tools/gen_kana.zig from the Unicode Han database: each
        \\//! reading (in hiragana) and the Jōyō kanji read so, most
        \\//! common first; and kun readings with the kanji and its okurigana
        \\//! (guessed: see the tool). Sorted by reading.
        \\
        \\/// Each reading, and its kanji.
        \\pub const kanji = [_]struct { []const u8, []const u8 }{
        \\
    );
    var n_readings: usize = 0;
    var i: usize = 0;
    while (i < entries.items.len) {
        const r = entries.items[i].reading;
        try out.print(arena, "    .{{ \"{s}\", \"", .{r});
        var last: u21 = 0;
        while (i < entries.items.len and std.mem.eql(u8, entries.items[i].reading, r)) : (i += 1) {
            const e = entries.items[i];
            if (e.okurigana != null or e.kanji.cp == last) continue;
            last = e.kanji.cp;
            try appendCp(arena, &out, e.kanji.cp);
        }
        try out.appendSlice(arena, "\" },\n");
        n_readings += 1;
    }
    try out.appendSlice(arena,
        \\};
        \\
        \\/// Whole kun readings, and their kanji with its okurigana.
        \\pub const words = [_]struct { []const u8, []const u8 }{
        \\
    );
    var n_words: usize = 0;
    for (entries.items) |e| {
        const oku = e.okurigana orelse continue;
        try out.print(arena, "    .{{ \"{s}\", \"", .{e.reading});
        try appendCp(arena, &out, e.kanji.cp);
        try out.print(arena, "{s}\" }},\n", .{oku});
        n_words += 1;
    }
    try out.appendSlice(arena, "};\n");
    // Duplicates (a kanji with the same reading as on and kun) dropped.
    const text = try dedupe(arena, out.items);
    const file = try cwd.createFile(init.io, args[4], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, text);
    std.debug.print("{d} kanji, {d} readings, {d} words\n", .{ kanji.count(), n_readings, n_words });
}

/// Each reading's kanji once, in order.
fn dedupe(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (out.items.len > 0) try out.append(a, '\n');
        const q = std.mem.indexOf(u8, line, "\", \"") orelse {
            try out.appendSlice(a, line);
            continue;
        };
        const start = q + 4;
        const end = std.mem.lastIndexOfScalar(u8, line, '"') orelse start;
        try out.appendSlice(a, line[0..start]);
        var seen: std.AutoHashMapUnmanaged(u21, void) = .empty;
        var it = (std.unicode.Utf8View.init(line[start..end]) catch {
            try out.appendSlice(a, line[start..]);
            continue;
        }).iterator();
        // Only the kanji lists: words have kana in, and stay as they are.
        const is_list = blk: {
            var check = (std.unicode.Utf8View.init(line[start..end]) catch unreachable).iterator();
            while (check.nextCodepoint()) |c| if (c >= 0x3040 and c < 0x3100) break :blk false;
            break :blk true;
        };
        while (it.nextCodepointSlice()) |s| {
            const c = std.unicode.utf8Decode(s) catch continue;
            if (is_list) {
                if (seen.contains(c)) continue;
                try seen.put(a, c, {});
            }
            try out.appendSlice(a, s);
        }
        try out.appendSlice(a, line[end..]);
    }
    return out.items;
}

fn appendCp(a: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &buf);
    try out.appendSlice(a, buf[0..len]);
}

/// A reading in hiragana, and whether it was kun (in hiragana already):
/// katakana (on readings) made hiragana; marks ("-", ".") taken out. Null
/// if it has anything else.
fn hiragana(a: std.mem.Allocator, reading: []const u8) !?struct { bool, []const u8 } {
    var out: std.ArrayList(u8) = .empty;
    var kun = false;
    var it = (std.unicode.Utf8View.init(reading) catch return null).iterator();
    while (it.nextCodepoint()) |c| {
        const h: u21 = switch (c) {
            '-', '.' => continue,
            0x3041...0x3096 => blk: {
                kun = true;
                break :blk c;
            },
            0x30a1...0x30f6 => c - 0x60,
            'ー' => c,
            else => return null,
        };
        try appendCp(a, &out, h);
    }
    if (out.items.len == 0) return null;
    return .{ kun, out.items };
}

/// How much of a kun reading (in bytes) is the kanji's, if it looks like
/// a verb or adjective: all but its last kana, or its last two for "-eru",
/// "-iru" and "-shii".
fn stemLength(r: []const u8) ?usize {
    // Kana are three bytes each.
    const n = r.len / 3;
    if (n < 2) return null;
    const last = std.unicode.utf8Decode(r[r.len - 3 ..]) catch return null;
    const prev = std.unicode.utf8Decode(r[r.len - 6 .. r.len - 3]) catch return null;
    const two = n > 2 and switch (last) {
        'る' => switch (prev) {
            'い', 'き', 'ぎ', 'し', 'じ', 'ち', 'ぢ', 'に', 'ひ', 'び', 'ぴ', 'み', 'り' => true,
            'え', 'け', 'げ', 'せ', 'ぜ', 'て', 'で', 'ね', 'へ', 'べ', 'ぺ', 'め', 'れ' => true,
            else => false,
        },
        'い' => prev == 'し',
        else => false,
    };
    const inflects = switch (last) {
        'う', 'く', 'ぐ', 'す', 'つ', 'ぬ', 'ぶ', 'む', 'る' => true,
        'い' => n >= 3,
        else => false,
    };
    if (!inflects) return null;
    return r.len - (if (two) @as(usize, 6) else 3);
}

/// "U+4F60\tkJapanese\tジ ニ": the character, the field and its value.
fn splitLine(line: []const u8) ?struct { u21, []const u8, []const u8 } {
    if (!std.mem.startsWith(u8, line, "U+")) return null;
    var it = std.mem.splitScalar(u8, line, '\t');
    const cp_text = it.next() orelse return null;
    const field = it.next() orelse return null;
    const value = it.next() orelse return null;
    const cp = std.fmt.parseInt(u21, cp_text[2..], 16) catch return null;
    return .{ cp, field, value };
}
