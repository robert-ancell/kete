//! Emoji found by name, for typing them (`:` then the name: see
//! input_method.zig): Unicode's names ("grinning face", "thumbs up",
//! "flag: Japan"), and a few short names people type in chat apps
//! (":smile", ":tada", ":+1").

const std = @import("std");
const names = @import("emoji_names.zig");

pub const Emoji = names.Emoji;

/// The short names chat apps have, which are not (the start of) Unicode's.
const aliases = [_]struct { []const u8, []const u8 }{
    .{ "smile", "😄" },
    .{ "smiley", "😃" },
    .{ "joy", "😂" },
    .{ "laughing", "😆" },
    .{ "lol", "😂" },
    .{ "rofl", "🤣" },
    .{ "blush", "😊" },
    .{ "wink", "😉" },
    .{ "heart_eyes", "😍" },
    .{ "kiss", "😘" },
    .{ "cry", "😢" },
    .{ "sob", "😭" },
    .{ "angry", "😠" },
    .{ "cool", "😎" },
    .{ "sunglasses", "😎" },
    .{ "thinking", "🤔" },
    .{ "shrug", "🤷" },
    .{ "party", "🥳" },
    .{ "tada", "🎉" },
    .{ "+1", "👍" },
    .{ "thumbsup", "👍" },
    .{ "-1", "👎" },
    .{ "thumbsdown", "👎" },
    .{ "ok", "👌" },
    .{ "wave", "👋" },
    .{ "clap", "👏" },
    .{ "pray", "🙏" },
    .{ "muscle", "💪" },
    .{ "heart", "❤️" },
    .{ "100", "💯" },
    .{ "fire", "🔥" },
    .{ "star", "⭐" },
    .{ "sparkles", "✨" },
    .{ "eyes", "👀" },
    .{ "rocket", "🚀" },
    .{ "check", "✅" },
    .{ "x", "❌" },
    .{ "poop", "💩" },
};

/// Up to `out.len` emoji for `query` (what was typed after `:`, as
/// "thumbs_up" or "smi"; `_` is a space), best first: a short name it is,
/// then a name it is, a name starting with it, a word of a name starting
/// with it, and (for three letters or more) a name with it in; each in
/// Unicode's order. Returns how many.
pub fn search(query: []const u8, out: []Emoji) usize {
    var qbuf: [64]u8 = undefined;
    if (query.len == 0 or query.len > qbuf.len) return 0;
    for (query, 0..) |c, i| qbuf[i] = if (c == '_') ' ' else std.ascii.toLower(c);
    const q = qbuf[0..query.len];
    var n: usize = 0;
    // The short names it is, then those it starts.
    inline for (.{ true, false }) |exact| for (aliases) |a| {
        const match = if (exact) std.mem.eql(u8, a[0], query) else a[0].len > query.len and std.mem.startsWith(u8, a[0], query);
        if (!match or already(out[0..n], a[1])) continue;
        if (n == out.len) return n;
        out[n] = .{ .name = nameOf(a[1]) orelse a[0], .text = a[1] };
        n += 1;
    };
    inline for (.{ Tier.exact, Tier.starts, Tier.word, Tier.within }) |tier| {
        if (tier == .within and q.len < 3) return n;
        for (names.all) |e| {
            if (n == out.len) return n;
            if (tierOf(e.name, q) != tier) continue;
            if (already(out[0..n], e.text)) continue;
            out[n] = e;
            n += 1;
        }
    }
    return n;
}

/// The name of the emoji `text`, if it has one.
pub fn nameOf(text: []const u8) ?[]const u8 {
    for (names.all) |e| if (std.mem.eql(u8, e.text, text)) return e.name;
    return null;
}

const Tier = enum { exact, starts, word, within, none };

fn tierOf(full_name: []const u8, q: []const u8) Tier {
    // "flag: Japan" as "flag Japan", for "flag_japan".
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    for (full_name) |c| {
        if (c == ':' or len == buf.len) continue;
        buf[len] = c;
        len += 1;
    }
    const name = buf[0..len];
    if (name.len < q.len) return .none;
    if (name.len == q.len and std.ascii.eqlIgnoreCase(name, q)) return .exact;
    if (std.ascii.startsWithIgnoreCase(name, q)) return .starts;
    var i: usize = 1;
    while (i + q.len <= name.len) : (i += 1) {
        const boundary = switch (name[i - 1]) {
            ' ', ':', '-' => true,
            else => false,
        };
        if (std.ascii.eqlIgnoreCase(name[i..][0..q.len], q)) return if (boundary) .word else .within;
    }
    return .none;
}

fn already(found: []const Emoji, text: []const u8) bool {
    for (found) |e| if (std.mem.eql(u8, e.text, text)) return true;
    return false;
}

const testing = std.testing;

test "emoji by name, best first" {
    var out: [8]Emoji = undefined;
    // A short name.
    try testing.expect(search("tada", &out) >= 1);
    try testing.expectEqualStrings("🎉", out[0].text);
    try testing.expectEqualStrings("party popper", out[0].name);
    // Unicode's name, with underscores for spaces.
    try testing.expectEqualStrings("👍", out[0..search("thumbs_up", &out)][0].text);
    // "smil": the short names it starts (smile, smiley), then the faces
    // with a word starting so ("smiling").
    const n = search("smil", &out);
    try testing.expect(n == out.len);
    try testing.expectEqualStrings("😄", out[0].text);
    for (out[2..n]) |e| try testing.expect(tierOf(e.name, "smil") != .none);
    // Flags, by their names (without the colon).
    try testing.expectEqualStrings("🇯🇵", out[0..search("flag_japan", &out)][0].text);
    // The start of a short name.
    try testing.expectEqualStrings("🎉", out[0..search("tad", &out)][0].text);
    // Nothing.
    try testing.expectEqual(@as(usize, 0), search("zzzqqq", &out));
}
