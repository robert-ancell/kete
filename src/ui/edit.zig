//! Shared character-class helpers for text editing widgets.
//!
//! Used by `TextField` and `TextArea` for double-click word selection
//! and Ctrl+arrow word movement.

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
