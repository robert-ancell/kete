//! Text that runs right to left (Arabic, Hebrew) put in the order it shows
//! in: a simplified Unicode Bidirectional Algorithm (UAX #9) for a line of
//! glyphs laid out in the order they are written. The line's direction is
//! that of its first strong letter. Letters are left-to-right or
//! right-to-left; digits run left to right, within right-to-left text
//! too, with the separators and signs between and around them (W4, W5);
//! other characters (spaces, punctuation) go with the letters each side
//! when they agree, and with the line when not (N1, N2). Runs are then
//! reversed (L2), and brackets in right-to-left text mirrored (L4). Not
//! done: explicit embeddings and isolates (U+202A to U+2069), and
//! trailing spaces (L1).

const std = @import("std");

pub const Class = enum { l, r, en, cs, et, n };

pub fn classOf(c: u21) Class {
    return switch (c) {
        '0'...'9', 0x0660...0x0669, 0x06F0...0x06F9 => .en,
        ',', '.', ':', '/', 0x060C => .cs,
        '%', '+', '-', '$', '#', 0x00B0, 0x066A, 0x2030, 0x20AC, 0x00A3 => .et,
        0x0590...0x05FF, 0x0600...0x060B, 0x060D...0x065F, 0x066B...0x06EF, 0x06FA...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF => .r,
        else => if (strongLeft(c)) .l else .n,
    };
}

fn strongLeft(c: u21) bool {
    if (c < 0x80) return std.ascii.isAlphabetic(@intCast(c));
    // Letters of other scripts (Latin, Greek, Cyrillic, Chinese, Japanese
    // and more), not the punctuation and symbols between them.
    return switch (c) {
        0x00AA, 0x00B5, 0x00BA, 0x00C0...0x00D6, 0x00D8...0x00F6, 0x00F8...0x058F => true,
        0x0900...0x1FFF, 0x2C00...0x2DFF, 0x2E80...0x2FFF, 0x3040...0xD7FF, 0xF900...0xFB1C, 0xFF21...0xFF3A, 0xFF41...0xFF5A, 0xFF66...0xFFDC => true,
        0x10000...0x1F000, 0x20000...0x3FFFF => true,
        else => false,
    };
}

/// Whether `text` has anything that runs right to left.
pub fn hasRightToLeft(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        // U+0590 to U+08FF; U+FB1D to U+FEFF.
        if ((b >= 0xd6 and b <= 0xe0) or (b == 0xef and i + 1 < text.len and text[i + 1] >= 0xac and text[i + 1] <= 0xbb)) {
            const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (i + len <= text.len) if (std.unicode.utf8Decode(text[i..][0..len])) |c| {
                if (classOf(c) == .r) return true;
            } else |_| {};
        }
        i += 1;
    }
    return false;
}

/// Whether the first strong letter of `text` runs right to left.
pub fn rightToLeft(text: []const u8) bool {
    var it = (std.unicode.Utf8View.init(text) catch return false).iterator();
    while (it.nextCodepoint()) |c| switch (classOf(c)) {
        .r => return true,
        .l => return false,
        else => {},
    };
    return false;
}

/// The mirror image of a bracket, for right-to-left text.
pub fn mirror(c: u21) ?u21 {
    return switch (c) {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        '<' => '>',
        '>' => '<',
        0x00AB => 0x00BB,
        0x00BB => 0x00AB,
        0x2039 => 0x203A,
        0x203A => 0x2039,
        else => null,
    };
}

/// Embedding levels (even: left to right; odd: right to left) for
/// characters of `classes`, in a line running right to left if `rtl`.
pub fn levels(classes: []Class, rtl: bool, out: []u8) void {
    const base: u8 = @intFromBool(rtl);
    // W4: a separator between digits is one; W5: signs by digits are.
    for (classes, 0..) |*c, i| if (c.* == .cs and i > 0 and i + 1 < classes.len and classes[i - 1] == .en and classes[i + 1] == .en) {
        c.* = .en;
    };
    for (classes, 0..) |c, i| if (c == .et) {
        var j = i;
        while (j < classes.len and classes[j] == .et) j += 1;
        const by_digit = (i > 0 and classes[i - 1] == .en) or (j < classes.len and classes[j] == .en);
        if (by_digit) for (classes[i..j]) |*e| {
            e.* = .en;
        };
    };
    // Strong directions, digits taking that of the letters before them (W2,
    // W7): right to left after right-to-left letters, as numbers in Arabic
    // are; and resolved: true for right to left.
    var last_strong_r = rtl;
    for (classes, out) |c, *lv| switch (c) {
        .l => {
            last_strong_r = false;
            lv.* = if (rtl) 2 else 0;
        },
        .r => {
            last_strong_r = true;
            lv.* = 1;
        },
        .en => lv.* = if (last_strong_r) 2 else base,
        else => lv.* = 255,
    };
    // Neutrals: as the strong characters each side, if they agree (digits
    // counting as right to left in right-to-left text), else as the line.
    var i: usize = 0;
    while (i < classes.len) {
        if (out[i] != 255) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < classes.len and out[j] == 255) j += 1;
        const before = if (i == 0) rtl else sideIsRtl(classes[i - 1], out[i - 1]);
        const after = if (j == classes.len) rtl else sideIsRtl(classes[j], out[j]);
        const lv: u8 = if (before == after) (if (before) 1 else if (rtl) 2 else 0) else base;
        @memset(out[i..j], lv);
        i = j;
    }
}

fn sideIsRtl(c: Class, level: u8) bool {
    return switch (c) {
        .r => true,
        .en => level == 2,
        else => level % 2 == 1,
    };
}

/// The order of characters at `lvls` as they show, left to right (L2).
pub fn visualOrder(lvls: []const u8, order: []usize) void {
    for (order, 0..) |*o, i| o.* = i;
    var max: u8 = 0;
    var min_odd: u8 = 255;
    for (lvls) |lv| {
        max = @max(max, lv);
        if (lv % 2 == 1) min_odd = @min(min_odd, lv);
    }
    if (min_odd == 255) return;
    var level = max;
    while (level >= min_odd) : (level -= 1) {
        var i: usize = 0;
        while (i < lvls.len) {
            if (lvls[order[i]] < level) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < lvls.len and lvls[order[j]] >= level) j += 1;
            std.mem.reverse(usize, order[i..j]);
            i = j;
        }
        if (level == 0) break;
    }
}

const testing = std.testing;

fn visual(comptime text: []const u8) ![]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    var cps: [64]u21 = undefined;
    var classes: [64]Class = undefined;
    var n: usize = 0;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |c| : (n += 1) {
        cps[n] = c;
        classes[n] = classOf(c);
    }
    var lv: [64]u8 = undefined;
    levels(classes[0..n], rightToLeft(text), lv[0..n]);
    var order: [64]usize = undefined;
    visualOrder(lv[0..n], order[0..n]);
    var len: usize = 0;
    for (order[0..n]) |o| {
        const c = if (lv[o] % 2 == 1) mirror(cps[o]) orelse cps[o] else cps[o];
        len += try std.unicode.utf8Encode(c, S.buf[len..]);
    }
    return S.buf[0..len];
}

test "right-to-left text, with numbers and words in it" {
    // Arabic: reversed.
    try testing.expectEqualStrings("ﺏﺍ", try visual("ﺍﺏ"));
    // Its numbers still run left to right, with what separates them.
    try testing.expectEqualStrings("10:30 ﺏﺍ", try visual("ﺍﺏ 10:30"));
    // A word in it, left to right, the spaces either side as the line.
    try testing.expectEqualStrings("ﺩ Wi-Fi ﺏﺍ", try visual("ﺍﺏ Wi-Fi ﺩ"));
    // Brackets mirrored.
    try testing.expectEqualStrings("(ﺏ) ﺍ", try visual("ﺍ (ﺏ)"));
    // Left-to-right text with an Arabic word: just the word reversed.
    try testing.expectEqualStrings("in ﺏﺍ now", try visual("in ﺍﺏ now"));
    // Percentages.
    try testing.expectEqualStrings("50% ﺏﺍ", try visual("ﺍﺏ 50%"));
    try testing.expect(hasRightToLeft("hi ﺍﺏ") and hasRightToLeft("سلام") and !hasRightToLeft("héllo 你好"));
}
