//! Arabic letters joined: each takes the form (isolated, final, initial or
//! medial) its neighbours call for, as Unicode's Arabic Presentation
//! Forms-B have them (which fonts such as Noto Sans Arabic map), and lam
//! with alef makes their ligature. This is what a shaper's `init`,
//! `medi`, `fina` and `rlig` features do, for the letters Arabic itself
//! has (not those of Persian or Urdu, and without the font's own
//! contextual forms). Marks (harakat) between letters are passed over.

const std = @import("std");

const Joining = enum { none, right, dual, causing, transparent };

/// Each letter from U+0621 to U+064A: its first presentation form (its
/// isolated one; then final, initial and medial for those that join on
/// both sides), or 0.
const forms = [_]u16{
    0xFE80, 0xFE81, 0xFE83, 0xFE85, 0xFE87, 0xFE89, 0xFE8D, 0xFE8F, 0xFE93, 0xFE95, // ء آ أ ؤ إ ئ ا ب ة ت
    0xFE99, 0xFE9D, 0xFEA1, 0xFEA5, 0xFEA9, 0xFEAB, 0xFEAD, 0xFEAF, 0xFEB1, 0xFEB5, // ث ج ح خ د ذ ر ز س ش
    0xFEB9, 0xFEBD, 0xFEC1, 0xFEC5, 0xFEC9, 0xFECD, 0, 0, 0, 0, //      ص ض ط ظ ع غ
    0, 0, 0xFED1, 0xFED5, 0xFED9, 0xFEDD, 0xFEE1, 0xFEE5, 0xFEE9, 0xFEED, // ـ ف ق ك ل م ن ه و
    0xFEEF, 0xFEF1, // ى ي
};

fn joining(c: u21) Joining {
    return switch (c) {
        0x0621 => .none,
        0x0622...0x0625, 0x0627, 0x0629, 0x062F...0x0632, 0x0648, 0x0649 => .right,
        0x0626, 0x0628, 0x062A...0x062E, 0x0633...0x063A, 0x0641...0x0647, 0x064A => .dual,
        // Tatweel, which only stretches the joins.
        0x0640 => .causing,
        0x064B...0x065F, 0x0670 => .transparent,
        else => .none,
    };
}

/// Whether `c` is a letter this joins.
pub fn joins(c: u21) bool {
    return c >= 0x0621 and c <= 0x064A and forms[c - 0x0621] != 0;
}

/// The form of the letter at `start` in `text` (ending at `end`), and
/// where the text after it starts (after alef too, for lam-alef).
pub fn shape(text: []const u8, start: usize, end: usize) struct { cp: u21, end: usize } {
    const c = decode(text, start) orelse return .{ .cp = 0xfffd, .end = end };
    const after_prev = joinsBefore(text, start);
    // Lam then alef: their ligature.
    if (c == 0x0644) if (decode(text, end)) |a| {
        const lig: ?u21 = switch (a) {
            0x0622 => 0xFEF5,
            0x0623 => 0xFEF7,
            0x0625 => 0xFEF9,
            0x0627 => 0xFEFB,
            else => null,
        };
        if (lig) |l| return .{ .cp = l + @intFromBool(after_prev), .end = end + (std.unicode.utf8CodepointSequenceLength(a) catch 2) };
    };
    const base: u21 = forms[c - 0x0621];
    const t = joining(c);
    const prev = after_prev and (t == .right or t == .dual);
    const next = t == .dual and joinsAfter(text, end);
    const form: u21 = if (prev and next) 3 else if (next) 2 else if (prev) 1 else 0;
    return .{ .cp = base + form, .end = end };
}

/// Whether the letter before `at` (marks passed over) joins on to the next.
fn joinsBefore(text: []const u8, at: usize) bool {
    var i = at;
    while (i > 0) {
        i -= 1;
        while (i > 0 and text[i] & 0xc0 == 0x80) i -= 1;
        const c = decode(text, i) orelse return false;
        switch (joining(c)) {
            .transparent => continue,
            .dual, .causing => return true,
            else => return false,
        }
    }
    return false;
}

/// Whether the letter at `at` (marks passed over) joins on to the one
/// before it.
fn joinsAfter(text: []const u8, at: usize) bool {
    var i = at;
    while (i < text.len) {
        const c = decode(text, i) orelse return false;
        switch (joining(c)) {
            .transparent => i += std.unicode.utf8CodepointSequenceLength(c) catch return false,
            .dual, .right, .causing => return true,
            .none => return false,
        }
    }
    return false;
}

fn decode(text: []const u8, at: usize) ?u21 {
    if (at >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[at]) catch return null;
    if (at + len > text.len) return null;
    return std.unicode.utf8Decode(text[at..][0..len]) catch null;
}

const testing = std.testing;

fn shapeAll(text: []const u8, out: []u21) []u21 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch unreachable;
        const c = decode(text, i).?;
        if (joins(c)) {
            const s = shape(text, i, i + len);
            out[n] = s.cp;
            i = s.end;
        } else {
            out[n] = c;
            i += len;
        }
        n += 1;
    }
    return out[0..n];
}

test "letters take the forms their neighbours call for" {
    var buf: [16]u21 = undefined;
    // "بيت": initial ba, medial ya, final ta.
    try testing.expectEqualSlices(u21, &.{ 0xFE91, 0xFEF4, 0xFE96 }, shapeAll("بيت", &buf));
    // "دار": dal and alef join nothing after them: all isolated.
    try testing.expectEqualSlices(u21, &.{ 0xFEA9, 0xFE8D, 0xFEAD }, shapeAll("دار", &buf));
    // "باب": ba joins alef (final), which leaves the next ba isolated.
    try testing.expectEqualSlices(u21, &.{ 0xFE91, 0xFE8E, 0xFE8F }, shapeAll("باب", &buf));
    // Alone, and across a space: isolated.
    try testing.expectEqualSlices(u21, &.{ 0xFE8F, ' ', 0xFE8F }, shapeAll("ب ب", &buf));
    // Lam-alef: "سلام" is initial sin, final lam-alef, isolated mim.
    try testing.expectEqualSlices(u21, &.{ 0xFEB3, 0xFEFC, 0xFEE1 }, shapeAll("سلام", &buf));
    // Marks are passed over: "بَت" joins.
    try testing.expectEqualSlices(u21, &.{ 0xFE91, 0x064E, 0xFE96 }, shapeAll("بَت", &buf));
}
