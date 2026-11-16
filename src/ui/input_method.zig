//! kete's own input methods, for text typed into its text fields and
//! areas (what has `text_input`): typed keys become text composed (shown
//! in the field as its preedit, underlined) and candidates for it (in a
//! popup by the cursor), until one is chosen and put in the text.
//!
//! * Emoji, everywhere: `:` (at the start, or after a space) then a name,
//!   as chat apps have it: ":smi" offers 😄 🙂 😊 and others. Up and Down
//!   choose, Enter, Tab or a closing `:` put the emoji in; Escape, a space
//!   or anything else puts in what was typed.
//! * Pinyin, for Chinese (`Language.pinyin`): lower-case letters are
//!   composed, and the candidates are the characters of the first
//!   syllable ("nihao": 你, 泥, 拟, …), most used first. Space puts in the
//!   chosen one (and goes on with the rest, "hao"), a digit the one
//!   numbered; Up and Down choose (a page at a time past the ends); Enter
//!   puts in the letters as they are, Escape drops them, Backspace takes
//!   the last back. Punctuation is Chinese (，。？！).
//!   Shift, pressed and let go alone, switches between Chinese and
//!   English.
//!
//! Never in a password field. `WindowUi` gives it the keys first (see
//! `WindowUi.key`), and sends what it composes and puts in to the field
//! with the focus as an input method's (`text_preedit`, `text_commit`).

const std = @import("std");
const widget = @import("widget.zig");
const emoji = @import("emoji.zig");
const pinyin_table = @import("pinyin_table.zig");

const Key = widget.Event.Key;

/// An input method for a language, as well as emoji.
pub const Language = enum {
    /// Letters type as they are.
    none,
    /// Chinese, by pinyin (Simplified characters).
    pinyin,
};

/// What is composed.
pub const Kind = enum { emoji, pinyin };

/// A candidate: what is put in, and what the popup shows of it.
pub const Candidate = struct {
    text: []const u8,
    label: []const u8 = "",
};

/// How many candidates show (and digits choose, for pinyin).
pub const page_size = 9;

pub const InputMethod = struct {
    /// Emoji offered after `:` (unless the app turns them off).
    emoji: bool = true,
    language: Language = .none,
    /// For `pinyin`: letters type Chinese (Shift, tapped alone, switches).
    chinese: bool = true,
    /// Shift is down, and no other key has been since.
    shift_alone: bool = false,

    /// What is being composed, if anything, and its text.
    composing: ?Kind = null,
    buf: [64]u8 = undefined,
    len: usize = 0,
    /// The candidates shown, from `first` in all of them, and the one
    /// chosen.
    candidates: [page_size]Candidate = undefined,
    count: usize = 0,
    first: usize = 0,
    selected: usize = 0,
    /// Pinyin: the syllable the candidates are for (its length in `buf`),
    /// and all its characters.
    syllable_len: usize = 0,
    chars: []const u8 = "",
    /// What the last key put in the text (`Outcome.commit`).
    commit_buf: [128]u8 = undefined,

    /// What a key did.
    pub const Outcome = struct {
        /// The key was the input method's: not for the field.
        taken: bool = false,
        /// Text to put in the field (before the key, if it was not taken).
        commit: ?[]const u8 = null,
        /// The composed text changed (to `composed()`).
        preedit: bool = false,
    };

    pub fn composed(im: *const InputMethod) []const u8 {
        return im.buf[0..im.len];
    }

    /// Whether candidates show.
    pub fn showing(im: *const InputMethod) bool {
        return im.composing != null and im.count > 0;
    }

    /// Offers `k` to the input method, in a field whose text before the
    /// cursor is `before` (for knowing a `:` starts an emoji's name).
    pub fn key(im: *InputMethod, k: Key, before: []const u8) Outcome {
        // Shift, tapped alone: Chinese, or English.
        if (k.key == .left_shift or k.key == .right_shift) {
            if (k.pressed) {
                im.shift_alone = true;
                return .{};
            }
            if (!im.shift_alone or im.language != .pinyin) return .{};
            im.shift_alone = false;
            im.chinese = !im.chinese;
            // What was being composed goes in as it is.
            return im.commitRaw(true);
        }
        if (k.pressed) im.shift_alone = false;
        if (!k.pressed or k.ctrl) return .{};
        if (im.composing) |kind| return switch (kind) {
            .emoji => im.emojiKey(k),
            .pinyin => im.pinyinKey(k),
        };
        const c = k.char orelse return .{};
        // An emoji's name starts.
        if (im.emoji and c == ':' and startsWord(before)) {
            im.start(.emoji, ":");
            return .{ .taken = true, .preedit = true };
        }
        if (im.language == .pinyin and im.chinese) {
            if (c >= 'a' and c <= 'z') {
                im.start(.pinyin, &.{@intCast(c)});
                im.findPinyin();
                return .{ .taken = true, .preedit = true };
            }
            if (chinesePunctuation(c)) |p| return .{ .taken = true, .commit = p };
        }
        return .{};
    }

    fn emojiKey(im: *InputMethod, k: Key) Outcome {
        switch (k.key) {
            .escape => return im.commitRaw(true),
            .enter, .keypad_enter, .tab => return if (im.count > 0) im.commitChosen() else im.commitRaw(true),
            .backspace => {
                im.len -= 1;
                if (im.len == 0) {
                    im.reset();
                    return .{ .taken = true, .preedit = true };
                }
                im.findEmoji();
                return .{ .taken = true, .preedit = true };
            },
            .up, .down => {
                im.move(k.key == .down);
                return .{ .taken = true };
            },
            else => {},
        }
        const c = k.char orelse return im.commitRaw(false);
        // ":smile:": the emoji.
        if (c == ':' and im.count > 0) return im.commitChosen();
        const name_char = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '+' or c == '-';
        if (!name_char or im.len == im.buf.len) return im.commitRaw(false);
        im.buf[im.len] = @intCast(c);
        im.len += 1;
        im.findEmoji();
        return .{ .taken = true, .preedit = true };
    }

    fn pinyinKey(im: *InputMethod, k: Key) Outcome {
        switch (k.key) {
            // Dropped.
            .escape => {
                im.reset();
                return .{ .taken = true, .preedit = true };
            },
            .enter, .keypad_enter => return im.commitRaw(true),
            .backspace => {
                im.len -= 1;
                if (im.len == 0) im.reset() else im.findPinyin();
                return .{ .taken = true, .preedit = true };
            },
            .up, .down, .page_up, .page_down => {
                im.move(k.key == .down or k.key == .page_down);
                return .{ .taken = true };
            },
            .space => return if (im.count > 0) im.commitChosen() else im.commitRaw(true),
            else => {},
        }
        const c = k.char orelse return .{ .taken = true };
        if (c >= '1' and c <= '9') {
            const i = c - '1';
            if (i < im.count) {
                im.selected = i;
                return im.commitChosen();
            }
            return .{ .taken = true };
        }
        if ((c >= 'a' and c <= 'z') or c == '\'') {
            if (im.len == im.buf.len) return .{ .taken = true };
            im.buf[im.len] = @intCast(c);
            im.len += 1;
            im.findPinyin();
            return .{ .taken = true, .preedit = true };
        }
        // Punctuation: the chosen character, then it.
        var out = if (im.count > 0) im.commitChosen() else im.commitRaw(true);
        if (chinesePunctuation(c)) |p| {
            const base = out.commit orelse "";
            const both = std.fmt.bufPrint(&im.commit_buf, "{s}{s}", .{ base, p }) catch base;
            // Composing goes on if letters are left: put them in first.
            if (im.composing != null) {
                const rest = std.fmt.bufPrint(im.commit_buf[both.len..], "{s}", .{im.composed()}) catch "";
                im.reset();
                out.preedit = true;
                out.commit = im.commit_buf[0 .. both.len + rest.len];
                return out;
            }
            out.commit = both;
        } else {
            out.taken = false;
            if (im.composing != null) {
                const base = out.commit orelse "";
                const all = std.fmt.bufPrint(im.commit_buf[base.len..], "{s}", .{im.composed()}) catch "";
                out.commit = im.commit_buf[0 .. base.len + all.len];
                im.reset();
                out.preedit = true;
            }
        }
        return out;
    }

    /// Chooses the candidate shown at `i` (clicked).
    pub fn choose(im: *InputMethod, i: usize) Outcome {
        if (i >= im.count) return .{};
        im.selected = i;
        return im.commitChosen();
    }

    /// Ends composing (the field lost the focus, say): what was composed
    /// goes in as it is.
    pub fn finish(im: *InputMethod) Outcome {
        if (im.composing == null) return .{};
        return im.commitRaw(true);
    }

    fn start(im: *InputMethod, kind: Kind, text: []const u8) void {
        im.composing = kind;
        @memcpy(im.buf[0..text.len], text);
        im.len = text.len;
        im.count = 0;
        im.first = 0;
        im.selected = 0;
    }

    fn reset(im: *InputMethod) void {
        im.composing = null;
        im.len = 0;
        im.count = 0;
        im.first = 0;
        im.selected = 0;
        im.chars = "";
        im.syllable_len = 0;
    }

    /// What was typed goes in as it is (and, if `taken`, the key is the
    /// input method's).
    fn commitRaw(im: *InputMethod, taken: bool) Outcome {
        if (im.composing == null) return .{ .taken = taken };
        const text = im.commit_buf[0..im.len];
        @memcpy(text, im.composed());
        im.reset();
        return .{ .taken = taken, .commit = text, .preedit = true };
    }

    /// The chosen candidate goes in: an emoji, ending composing; a
    /// character, for its syllable, composing going on with the rest.
    fn commitChosen(im: *InputMethod) Outcome {
        const cand = im.candidates[im.selected];
        const text = im.commit_buf[0..cand.text.len];
        @memcpy(text, cand.text);
        if (im.composing == .pinyin and im.syllable_len < im.len) {
            const rest = im.len - im.syllable_len;
            std.mem.copyForwards(u8, im.buf[0..rest], im.buf[im.syllable_len..im.len]);
            // A separator left at the front goes.
            var skip: usize = 0;
            while (skip < rest and im.buf[skip] == '\'') skip += 1;
            std.mem.copyForwards(u8, im.buf[0 .. rest - skip], im.buf[skip..rest]);
            im.len = rest - skip;
            if (im.len == 0) im.reset() else {
                im.first = 0;
                im.selected = 0;
                im.findPinyin();
            }
        } else im.reset();
        return .{ .taken = true, .commit = text, .preedit = true };
    }

    /// Down (or up) the candidates, a page on (or back) past the ends.
    fn move(im: *InputMethod, down: bool) void {
        if (im.count == 0) return;
        if (down) {
            if (im.selected + 1 < im.count) {
                im.selected += 1;
            } else if (im.composing == .pinyin and im.first + page_size < charCount(im.chars)) {
                im.first += page_size;
                im.fillPinyin();
            }
        } else if (im.selected > 0) {
            im.selected -= 1;
        } else if (im.composing == .pinyin and im.first >= page_size) {
            im.first -= page_size;
            im.fillPinyin();
            im.selected = im.count -| 1;
        }
    }

    fn findEmoji(im: *InputMethod) void {
        var found: [page_size]emoji.Emoji = undefined;
        // Two letters at least, after the colon.
        const n = if (im.len >= 3) emoji.search(im.composed()[1..], &found) else 0;
        for (found[0..n], im.candidates[0..n]) |e, *cand| cand.* = .{ .text = e.text, .label = e.name };
        im.count = n;
        im.selected = 0;
    }

    /// The candidates for the first syllable of what is composed: the
    /// longest that is one ("xian" rather than "xi"), or, if none is (the
    /// start of one: "zh"), the first characters of those it starts.
    fn findPinyin(im: *InputMethod) void {
        im.first = 0;
        im.selected = 0;
        const text = im.composed();
        var best: ?usize = null;
        var len: usize = @min(text.len, 6);
        while (len > 0) : (len -= 1) {
            if (syllableIndex(text[0..len])) |i| {
                best = i;
                break;
            }
        }
        if (best) |i| {
            im.syllable_len = len;
            im.chars = pinyin_table.syllables[i][1];
        } else {
            // The start of syllables: each one's first character.
            im.syllable_len = text.len;
            im.chars = "";
            im.count = 0;
            for (pinyin_table.syllables) |s| {
                if (im.count == page_size) break;
                if (!std.mem.startsWith(u8, s[0], text)) continue;
                const first_len = std.unicode.utf8ByteSequenceLength(s[1][0]) catch continue;
                im.candidates[im.count] = .{ .text = s[1][0..first_len], .label = s[0] };
                im.count += 1;
            }
            return;
        }
        im.fillPinyin();
    }

    /// The page of `chars` from `first`.
    fn fillPinyin(im: *InputMethod) void {
        im.count = 0;
        var it = (std.unicode.Utf8View.init(im.chars) catch return).iterator();
        var i: usize = 0;
        while (it.nextCodepointSlice()) |ch| : (i += 1) {
            if (i < im.first) continue;
            if (im.count == page_size) break;
            im.candidates[im.count] = .{ .text = ch };
            im.count += 1;
        }
        im.selected = @min(im.selected, im.count -| 1);
    }
};

fn syllableIndex(s: []const u8) ?usize {
    // Sorted by syllable.
    var lo: usize = 0;
    var hi: usize = pinyin_table.syllables.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, pinyin_table.syllables[mid][0], s)) {
            .eq => return mid,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

fn charCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch 0;
}

/// Whether `before` (the text before the cursor) ends where a word starts:
/// it is empty, or ends in a space.
fn startsWord(before: []const u8) bool {
    if (before.len == 0) return true;
    return switch (before[before.len - 1]) {
        ' ', '\t', '\n', '(', '[', '"' => true,
        else => false,
    };
}

/// Chinese punctuation for `c`, typed in Chinese.
fn chinesePunctuation(c: u21) ?[]const u8 {
    return switch (c) {
        ',' => "，",
        '.' => "。",
        '?' => "？",
        '!' => "！",
        ';' => "；",
        ':' => "：",
        '(' => "（",
        ')' => "）",
        else => null,
    };
}

const testing = std.testing;

fn press(im: *InputMethod, key: widget.KeyboardKey, c: ?u21) InputMethod.Outcome {
    return im.key(.{ .key = key, .pressed = true, .char = c }, "");
}

fn typeText(im: *InputMethod, text: []const u8) void {
    for (text) |c| _ = im.key(.{ .key = .a, .pressed = true, .char = c }, "");
}

test "an emoji by its name: ':' then the name, and Enter" {
    var im: InputMethod = .{};
    typeText(&im, ":tad");
    try testing.expectEqualStrings(":tad", im.composed());
    try testing.expect(im.showing());
    try testing.expectEqualStrings("🎉", im.candidates[0].text);
    const out = press(&im, .enter, null);
    try testing.expect(out.taken);
    try testing.expectEqualStrings("🎉", out.commit.?);
    try testing.expect(im.composing == null);
}

test "not an emoji: a space puts in what was typed, and ':' within a word starts nothing" {
    var im: InputMethod = .{};
    typeText(&im, ":x");
    const out = press(&im, .space, ' ');
    try testing.expect(!out.taken);
    try testing.expectEqualStrings(":x", out.commit.?);
    // "10:30": the colon is typed as it is.
    try testing.expect(!im.key(.{ .key = .a, .pressed = true, .char = ':' }, "10").taken);
    // Escape: what was typed, as it is.
    typeText(&im, ":smi");
    try testing.expectEqualStrings(":smi", press(&im, .escape, null).commit.?);
}

test "pinyin: the first syllable's characters, chosen with Space or a digit" {
    var im: InputMethod = .{ .language = .pinyin };
    typeText(&im, "nihao");
    try testing.expectEqualStrings("nihao", im.composed());
    try testing.expectEqualStrings("你", im.candidates[0].text);
    var out = press(&im, .space, ' ');
    try testing.expectEqualStrings("你", out.commit.?);
    // The rest goes on.
    try testing.expectEqualStrings("hao", im.composed());
    try testing.expectEqualStrings("好", im.candidates[0].text);
    out = press(&im, .digit_1, '1');
    try testing.expectEqualStrings("好", out.commit.?);
    try testing.expect(im.composing == null);
    // Chinese punctuation.
    try testing.expectEqualStrings("，", press(&im, .comma, ',').commit.?);
}

test "pinyin: Enter types the letters, Escape drops them, Shift switches to English" {
    var im: InputMethod = .{ .language = .pinyin };
    typeText(&im, "zhong");
    try testing.expectEqualStrings("zhong", press(&im, .enter, null).commit.?);
    typeText(&im, "zh");
    // The start of syllables: one each.
    try testing.expect(im.count > 1);
    _ = press(&im, .escape, null);
    try testing.expect(im.composing == null);
    // Shift alone: English letters.
    _ = im.key(.{ .key = .left_shift, .pressed = true }, "");
    _ = im.key(.{ .key = .left_shift, .pressed = false }, "");
    try testing.expect(!press(&im, .a, 'a').taken);
    // Shift with a letter (a capital) does not switch.
    _ = im.key(.{ .key = .left_shift, .pressed = true }, "");
    _ = press(&im, .a, 'A');
    _ = im.key(.{ .key = .left_shift, .pressed = false }, "");
    try testing.expect(!im.chinese);
}

test "pinyin: past the end of a page, the next" {
    var im: InputMethod = .{ .language = .pinyin };
    typeText(&im, "shi");
    try testing.expectEqual(@as(usize, page_size), im.count);
    for (0..page_size) |_| _ = press(&im, .down, null);
    try testing.expectEqual(@as(usize, page_size), im.first);
    try testing.expect(!std.mem.eql(u8, im.candidates[0].text, "是"));
}
