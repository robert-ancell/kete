//! Shared character-class and word-navigation helpers for text editing widgets.
//!
//! Used by `TextField` and `TextArea` for double-click word selection,
//! Ctrl+arrow word movement, and Ctrl+Backspace / Ctrl+Delete word deletion.

const std = @import("std");

/// Coarse character kind for word-boundary detection.
pub const CharClass = enum { word, space, punct };

/// Returns the character class of Unicode codepoint `cp`.
///
///  `.word`  — letter (any script), decimal digit, or `_`
///  `.space` — Unicode whitespace (including non-breaking spaces)
///  `.punct` — punctuation, symbols, and everything that is not a letter,
///             digit, or whitespace
pub fn charClass(cp: u21) CharClass {
    if (cp < 0x80) {
        if (std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_') return .word;
        if (std.ascii.isWhitespace(@intCast(cp))) return .space;
        return .punct;
    }
    return switch (cp) {
        // ── Unicode whitespace (Zs category + separator codepoints) ─────────
        0x00A0, // NO-BREAK SPACE
        0x1680, // OGHAM SPACE MARK
        0x2000...0x200A, // EN QUAD … HAIR SPACE
        0x2028, // LINE SEPARATOR
        0x2029, // PARAGRAPH SEPARATOR
        0x202F, // NARROW NO-BREAK SPACE
        0x205F, // MEDIUM MATHEMATICAL SPACE
        0x3000, // IDEOGRAPHIC SPACE
        => .space,

        // ── Unicode punctuation and symbols ──────────────────────────────────

        // Latin-1 Supplement: ¡¢£¤¥¦§¨©«¬®¯°±´¶·»¼½¾¿
        // (letters start at U+00C0; U+00AA/B5/BA are technical letter chars
        // but treating this whole block as punct is standard for word movement)
        0x00A1...0x00BF,

        // General Punctuation: ‐–—…‧  (U+2000–200A are spaces, handled above)
        0x2010...0x2027,

        // Bidi direction marks / overrides (invisible format characters)
        0x202A...0x202E,

        // General Punctuation continued: ‰′″‴⁀⁄⁅⁆⁇⁈⁉
        0x2030...0x205E,

        // Invisible operators: word joiner, function application, etc.
        0x2060...0x206F,

        // Arrows
        0x2190...0x21FF,

        // Mathematical Operators
        0x2200...0x22FF,

        // Miscellaneous Technical
        0x2300...0x23FF,

        // Box Drawing, Block Elements, Geometric Shapes, Miscellaneous Symbols,
        // Dingbats
        0x2500...0x27FF,

        // Supplemental Punctuation
        0x2E00...0x2E7F,

        // CJK Symbols and Punctuation: 、。「」〈〉《》【】…
        0x3001...0x303F,

        // Vertical Forms
        0xFE10...0xFE1F,

        // CJK Compatibility Forms + Small Form Variants
        0xFE30...0xFE6F,

        // Fullwidth versions of ASCII punctuation
        // (fullwidth digits FF10–FF19 and letters FF21–FF3A / FF41–FF5A are
        // intentionally left out so they classify as `.word`)
        0xFF01...0xFF0F, // ！＂＃＄％＆＇（）＊＋，－．／
        0xFF1A...0xFF20, // ：；＜＝＞？＠
        0xFF3B...0xFF40, // ［＼］＾＿｀
        0xFF5B...0xFF65, // ｛｜｝～｟｠ + halfwidth CJK punctuation ｡｢｣､･

        // Halfwidth and Fullwidth Forms — symbols (¢£¥₩ etc.), not letters
        0xFFE0...0xFFEF,
        => .punct,

        // Everything else is a word character: letters in any script, decimal
        // digits, CJK ideographs, combining marks, emoji, etc.
        else => .word,
    };
}

/// The character boundary before byte `pos` in `text` (0 at the start).
pub fn before(text: []const u8, pos: usize) usize {
    var j = @min(pos, text.len) -| 1;
    while (j > 0 and text[j] & 0xc0 == 0x80) j -= 1;
    return j;
}

/// The character boundary after byte `pos` in `text` (`text.len` at the end).
pub fn after(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    var j = pos + 1;
    while (j < text.len and text[j] & 0xc0 == 0x80) j += 1;
    return j;
}

/// The character class of the UTF-8 character starting at byte `i` in `text`.
fn charClassOf(text: []const u8, i: usize) CharClass {
    if (text[i] < 0x80) return charClass(text[i]);
    const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .word;
    if (i + seq_len > text.len) return .word;
    const cp = std.unicode.utf8Decode(text[i..][0..seq_len]) catch return .word;
    return charClass(cp);
}

/// The byte index of the start of the word to the left of `pos` in `text`.
///
/// Steps left past punctuation and spaces, then left through the preceding
/// word (letters, digits, `_`).  Returns 0 when already at the start.
///
/// Examples:
/// - `"hello world"`, pos=11 → 6  (`"hello |world"`)
/// - `"hello world"`, pos=6  → 0  (`"|hello world"`)
/// - `"hello, world"`, pos=7 → 0  (comma+space are separators, skipping "hello")
pub fn wordBefore(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    // Step back one character.
    var i = before(text, pos);
    // Skip non-word characters (spaces, punctuation) going left.
    while (i > 0 and charClassOf(text, i) != .word) i = before(text, i);
    // Skip word characters going left to reach the start of the word.
    if (charClassOf(text, i) == .word) {
        while (i > 0) {
            const p = before(text, i);
            if (charClassOf(text, p) != .word) break;
            i = p;
        }
    }
    return i;
}

/// The byte index to move the cursor to after pressing Ctrl+Right at `pos`.
///
/// Steps right through any current word characters, then right past any
/// following non-word characters, stopping at the start of the next word
/// (or `text.len` if there is none).
///
/// Examples:
/// - `"hello world"`, pos=0  → 6  (`"hello |world"`)
/// - `"hello world"`, pos=5  → 6  (`"hello |world"`, cursor was on the space)
/// - `"hello world"`, pos=6  → 11 (`"hello world|"`)
pub fn wordAfter(text: []const u8, pos: usize) usize {
    const len = text.len;
    if (pos >= len) return len;
    var i = pos;
    // Skip current word characters (if cursor is inside or at the start of a word).
    while (i < len and charClassOf(text, i) == .word) i = after(text, i);
    // Skip non-word characters to land at the start of the next word.
    while (i < len and charClassOf(text, i) != .word) i = after(text, i);
    return i;
}

test "ASCII classification" {
    try std.testing.expect(charClass('a') == .word);
    try std.testing.expect(charClass('Z') == .word);
    try std.testing.expect(charClass('7') == .word);
    try std.testing.expect(charClass('_') == .word);
    try std.testing.expect(charClass(' ') == .space);
    try std.testing.expect(charClass('\t') == .space);
    try std.testing.expect(charClass('\n') == .space);
    try std.testing.expect(charClass('.') == .punct);
    try std.testing.expect(charClass(',') == .punct);
    try std.testing.expect(charClass('!') == .punct);
    try std.testing.expect(charClass('-') == .punct);
}

test "non-breaking space is space" {
    try std.testing.expect(charClass(0x00A0) == .space); // NO-BREAK SPACE
    try std.testing.expect(charClass(0x202F) == .space); // NARROW NO-BREAK SPACE
    try std.testing.expect(charClass(0x3000) == .space); // IDEOGRAPHIC SPACE
}

test "Unicode punctuation is punct" {
    try std.testing.expect(charClass(0x2014) == .punct); // EM DASH —
    try std.testing.expect(charClass(0x2026) == .punct); // HORIZONTAL ELLIPSIS …
    try std.testing.expect(charClass(0x00AB) == .punct); // LEFT-POINTING DOUBLE ANGLE QUOTATION «
    try std.testing.expect(charClass(0x00BB) == .punct); // RIGHT-POINTING DOUBLE ANGLE QUOTATION »
    try std.testing.expect(charClass(0x3001) == .punct); // IDEOGRAPHIC COMMA 、
    try std.testing.expect(charClass(0x3002) == .punct); // IDEOGRAPHIC FULL STOP 。
    try std.testing.expect(charClass(0x300C) == .punct); // LEFT CORNER BRACKET 「
}

test "Unicode letters and CJK are word" {
    try std.testing.expect(charClass(0x00E9) == .word); // é (LATIN SMALL LETTER E WITH ACUTE)
    try std.testing.expect(charClass(0x03B1) == .word); // α (GREEK SMALL LETTER ALPHA)
    try std.testing.expect(charClass(0x0430) == .word); // а (CYRILLIC SMALL LETTER A)
    try std.testing.expect(charClass(0x4E2D) == .word); // 中 (CJK UNIFIED IDEOGRAPH)
    try std.testing.expect(charClass(0x1F600) == .word); // 😀 (emoji — word for movement)
}

test "wordBefore: Ctrl+Left word navigation" {
    // Already at start — stays there.
    try std.testing.expectEqual(@as(usize, 0), wordBefore("hello", 0));
    // End of a single word → its start.
    try std.testing.expectEqual(@as(usize, 0), wordBefore("hello", 5));
    // Middle of a word → its start.
    try std.testing.expectEqual(@as(usize, 0), wordBefore("hello", 3));
    // After a space, before the second word → start of the first word.
    try std.testing.expectEqual(@as(usize, 0), wordBefore("hello world", 6));
    // End of the second word → its start.
    try std.testing.expectEqual(@as(usize, 6), wordBefore("hello world", 11));
    // Comma + space are separators; skips them and the preceding word.
    try std.testing.expectEqual(@as(usize, 0), wordBefore("hello, world", 7));
    // Multibyte: "héllo" (é = 0xC3 0xA9, so len=6).
    try std.testing.expectEqual(@as(usize, 0), wordBefore("héllo", 6));
}

test "wordAfter: Ctrl+Right word navigation" {
    // Already at end — stays there.
    try std.testing.expectEqual(@as(usize, 5), wordAfter("hello", 5));
    // Start of a single word → its end (then no more non-word chars → stops at end).
    try std.testing.expectEqual(@as(usize, 5), wordAfter("hello", 0));
    // Cursor on the space between two words → start of next word.
    try std.testing.expectEqual(@as(usize, 6), wordAfter("hello world", 5));
    // Start of the first word → start of the second word.
    try std.testing.expectEqual(@as(usize, 6), wordAfter("hello world", 0));
    // Start of the second word → end of string.
    try std.testing.expectEqual(@as(usize, 11), wordAfter("hello world", 6));
    // Comma + space: lands at start of next word.
    try std.testing.expectEqual(@as(usize, 7), wordAfter("hello, world", 0));
    // Multibyte: "héllo" → end of string.
    try std.testing.expectEqual(@as(usize, 6), wordAfter("héllo", 0));
}
