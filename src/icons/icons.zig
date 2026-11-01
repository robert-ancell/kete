//! Kete's icons: Material Icons (Apache License 2.0), drawn from a font.
//! The bundled icon font has only the icons named in `IconName` (see names.zig
//! and tools/subset_icons.zig), so it is a few kilobytes.
//!
//!     const glyph = icons.codepoint(.folder);
//!     const f = try font.Font.init(icons.font_data);
//!
//! In the toolkit, `ui.Icon` draws one.

const std = @import("std");
const names = @import("icon_names");
const generated = @import("icon_codepoints");

pub const IconName = names.IconName;

/// The icon font: Material Icons with only Kete's icons. Its glyphs fill
/// the em square, with the baseline at the bottom: an icon of size `s` is
/// drawn at font size `s`, with its baseline `s` below its top.
pub const font_data = @embedFile("MaterialIcons.ttf");

/// The character an icon is in the font.
pub fn codepoint(icon: IconName) u21 {
    return generated.codepoints[@backingInt(icon)];
}

/// The icon as UTF-8 text in the icon font.
pub fn text(icon: IconName, buf: *[4]u8) []const u8 {
    const len = std.unicode.utf8Encode(codepoint(icon), buf) catch unreachable;
    return buf[0..len];
}

const testing = std.testing;
const font = @import("font");

test "every icon is in the font" {
    const f = try font.Font.init(font_data);
    for (std.enums.values(IconName)) |icon| {
        const g = f.glyphIndex(codepoint(icon));
        try testing.expect(g != 0);
        try testing.expect(f.boundingBox(g) != null);
    }
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("\u{e2c7}", text(.folder, &buf));
    try testing.expectEqual(@as(?IconName, .folder), IconName.fromName("folder\n"));
    try testing.expectEqual(@as(?IconName, .pets), IconName.fromName("pets"));
    try testing.expectEqual(@as(?IconName, .remove), IconName.fromName("remove"));
    try testing.expectEqual(@as(?IconName, null), IconName.fromName("not_an_icon"));
}
