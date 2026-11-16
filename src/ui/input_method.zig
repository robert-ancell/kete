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
//! * Romaji, for Japanese (`Language.romaji`): lower-case letters are
//!   composed, and show as the hiragana they read as ("nihon": にほん).
//!   The candidates are the hiragana, the words and kanji read so (日本),
//!   the katakana (ニホン), and the words and kanji of the start of it (二,
//!   日); Space and Down go down them, Enter puts in the chosen one (the
//!   hiragana, unless another is chosen), a digit the one numbered. A
//!   kanji for the start leaves the rest composing. Backspace takes the
//!   last kana back, Escape drops them all. Punctuation is Japanese (、。
//!   「」), and Shift tapped alone switches to English. The kanji are
//!   Unihan's, for each reading (kana_table.zig), with a few hundred
//!   common words (japanese_words.zig): there is no dictionary of
//!   phrases, as a full input method would have.
//!
//! Never in a password field. `WindowUi` gives it the keys first (see
//! `WindowUi.key`), and sends what it composes and puts in to the field
//! with the focus as an input method's (`text_preedit`, `text_commit`).

const std = @import("std");
const widget = @import("widget.zig");
const emoji = @import("emoji.zig");
const pinyin_table = @import("pinyin_table.zig");
const kana_table = @import("kana_table.zig");
const japanese_words = @import("japanese_words.zig");

const Key = widget.Event.Key;

/// An input method for a language, as well as emoji.
pub const Language = enum {
    /// Letters type as they are.
    none,
    /// Chinese, by pinyin (Simplified characters).
    pinyin,
    /// Japanese, by romaji (kana and kanji).
    romaji,
};

/// What is composed.
pub const Kind = enum { emoji, pinyin, kana };

/// A candidate: what is put in, and what the popup shows of it.
pub const Candidate = struct {
    text: []const u8,
    label: []const u8 = "",
    /// Kana: how much of what was typed it is for (0: all of it).
    consumes: usize = 0,
};

/// How many candidates show (and digits choose, for pinyin and kana).
pub const page_size = 9;

/// How many candidates kana can have (seven pages).
const pool_size = 7 * page_size;

pub const InputMethod = struct {
    /// Emoji offered after `:` (unless the app turns them off).
    emoji: bool = true,
    language: Language = .none,
    /// For `pinyin` and `romaji`: letters type Chinese or Japanese (Shift,
    /// tapped alone, switches).
    native: bool = true,
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
    /// Kana: what is typed so far reads as (the preedit), all the
    /// candidates, and the hiragana and katakana they start with.
    shown_buf: [256]u8 = undefined,
    shown_len: usize = 0,
    pool: [pool_size]Candidate = undefined,
    pool_len: usize = 0,
    hira_buf: [256]u8 = undefined,
    kata_buf: [256]u8 = undefined,
    /// What the last key put in the text (`Outcome.commit`).
    commit_buf: [512]u8 = undefined,

    /// What a key did.
    pub const Outcome = struct {
        /// The key was the input method's: not for the field.
        taken: bool = false,
        /// Text to put in the field (before the key, if it was not taken).
        commit: ?[]const u8 = null,
        /// The composed text changed (to `composed()`).
        preedit: bool = false,
    };

    /// What is composed, as it shows: as typed, or (kana) as it reads.
    pub fn composed(im: *const InputMethod) []const u8 {
        if (im.composing == .kana) return im.shown_buf[0..im.shown_len];
        return im.buf[0..im.len];
    }

    /// Whether candidates show.
    pub fn showing(im: *const InputMethod) bool {
        return im.composing != null and im.count > 0;
    }

    /// Offers `k` to the input method, in a field whose text before the
    /// cursor is `before` (for knowing a `:` starts an emoji's name).
    pub fn key(im: *InputMethod, k: Key, before: []const u8) Outcome {
        // Shift, tapped alone: Chinese (or Japanese), or English.
        if (k.key == .left_shift or k.key == .right_shift) {
            if (k.pressed) {
                im.shift_alone = true;
                return .{};
            }
            if (!im.shift_alone or im.language == .none) return .{};
            im.shift_alone = false;
            im.native = !im.native;
            // What was being composed goes in as it is.
            return im.commitRaw(true);
        }
        if (k.pressed) im.shift_alone = false;
        if (!k.pressed or k.ctrl) return .{};
        if (im.composing) |kind| return switch (kind) {
            .emoji => im.emojiKey(k),
            .pinyin => im.pinyinKey(k),
            .kana => im.kanaKey(k),
        };
        const c = k.char orelse return .{};
        // An emoji's name starts.
        if (im.emoji and c == ':' and startsWord(before)) {
            im.start(.emoji, ":");
            return .{ .taken = true, .preedit = true };
        }
        if (im.language == .romaji and im.native) {
            if (c >= 'a' and c <= 'z') {
                im.start(.kana, &.{@intCast(c)});
                im.findKana();
                return .{ .taken = true, .preedit = true };
            }
            if (japanesePunctuation(c)) |p| return .{ .taken = true, .commit = p };
        }
        if (im.language == .pinyin and im.native) {
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

    fn kanaKey(im: *InputMethod, k: Key) Outcome {
        switch (k.key) {
            // Dropped.
            .escape => {
                im.reset();
                return .{ .taken = true, .preedit = true };
            },
            .enter, .keypad_enter => return im.commitChosen(),
            .backspace => {
                im.len = backspaceRomaji(im.buf[0..im.len]);
                if (im.len == 0) im.reset() else im.findKana();
                return .{ .taken = true, .preedit = true };
            },
            .up, .down, .page_up, .page_down => {
                im.move(k.key == .down or k.key == .page_down);
                return .{ .taken = true };
            },
            // The next candidate, round to the first after the last.
            .space => {
                if (im.first + im.selected + 1 >= im.pool_len) {
                    im.first = 0;
                    im.selected = 0;
                    im.fillKana();
                } else im.move(true);
                return .{ .taken = true };
            },
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
        if ((c >= 'a' and c <= 'z') or c == '\'' or c == '-' or kanaPunctuation(@intCast(c)) != null) {
            if (im.len == im.buf.len) return .{ .taken = true };
            im.buf[im.len] = @intCast(c);
            im.len += 1;
            im.findKana();
            return .{ .taken = true, .preedit = true };
        }
        // Anything else: the chosen candidate (and the hiragana of what is
        // left) goes in, then the key as it is.
        var out = im.commitChosen();
        out.taken = false;
        if (im.composing != null) {
            const base = out.commit orelse "";
            const rest = im.pool[0].text;
            const n = @min(rest.len, im.commit_buf.len - base.len);
            @memcpy(im.commit_buf[base.len..][0..n], rest[0..n]);
            out.commit = im.commit_buf[0 .. base.len + n];
            im.reset();
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
        im.shown_len = 0;
        im.pool_len = 0;
    }

    /// What was typed goes in as it is (and, if `taken`, the key is the
    /// input method's).
    fn commitRaw(im: *InputMethod, taken: bool) Outcome {
        if (im.composing == null) return .{ .taken = taken };
        // Kana: its hiragana (with a last "n" as ん).
        const src = if (im.composing == .kana and im.pool_len > 0) im.pool[0].text else im.composed();
        const text = im.commit_buf[0..src.len];
        @memcpy(text, src);
        im.reset();
        return .{ .taken = taken, .commit = text, .preedit = true };
    }

    /// The chosen candidate goes in: an emoji, ending composing; a
    /// character, for its syllable (or kanji, for the start of the kana),
    /// composing going on with the rest.
    fn commitChosen(im: *InputMethod) Outcome {
        if (im.count == 0) return im.commitRaw(true);
        const cand = im.candidates[im.selected];
        const text = im.commit_buf[0..cand.text.len];
        @memcpy(text, cand.text);
        const used = switch (im.composing.?) {
            .pinyin => im.syllable_len,
            .kana => if (cand.consumes > 0) cand.consumes else im.len,
            .emoji => im.len,
        };
        if (used < im.len) {
            const rest = im.len - used;
            std.mem.copyForwards(u8, im.buf[0..rest], im.buf[used..im.len]);
            // A separator left at the front goes.
            var skip: usize = 0;
            while (skip < rest and im.buf[skip] == '\'') skip += 1;
            std.mem.copyForwards(u8, im.buf[0 .. rest - skip], im.buf[skip..rest]);
            im.len = rest - skip;
            if (im.len == 0) im.reset() else {
                im.first = 0;
                im.selected = 0;
                if (im.composing == .kana) im.findKana() else im.findPinyin();
            }
        } else im.reset();
        return .{ .taken = true, .commit = text, .preedit = true };
    }

    /// Down (or up) the candidates, a page on (or back) past the ends.
    fn move(im: *InputMethod, down: bool) void {
        if (im.count == 0) return;
        const total = switch (im.composing.?) {
            .pinyin => charCount(im.chars),
            .kana => im.pool_len,
            .emoji => im.count,
        };
        if (down) {
            if (im.selected + 1 < im.count) {
                im.selected += 1;
            } else if (im.first + page_size < total) {
                im.first += page_size;
                im.selected = 0;
                im.fillPage();
            }
        } else if (im.selected > 0) {
            im.selected -= 1;
        } else if (im.first >= page_size) {
            im.first -= page_size;
            im.fillPage();
            im.selected = im.count -| 1;
        }
    }

    fn fillPage(im: *InputMethod) void {
        if (im.composing == .kana) im.fillKana() else im.fillPinyin();
    }

    /// The kana what is composed reads as, and the candidates for it.
    fn findKana(im: *InputMethod) void {
        im.first = 0;
        im.selected = 0;
        const r = im.buf[0..im.len];
        im.shown_len = romajiToKana(r, false, &im.shown_buf, null).len;
        // As it reads when done (a last "n" as ん), and where its kana
        // end, in it and in what was typed.
        var ends: [64]KanaEnd = undefined;
        const read = romajiToKana(r, true, &im.hira_buf, &ends);
        const hira = im.hira_buf[0..read.len];
        const kata = toKatakana(hira, &im.kata_buf);
        im.pool_len = 0;
        im.addCandidate(.{ .text = hira });
        im.addWords(hira, 0);
        im.addCandidate(.{ .text = kata });
        im.addReadings(hira, 0);
        // The start of it: the longest first.
        var p = read.ends;
        while (p > 1) {
            p -= 1;
            const e = ends[p - 1];
            im.addWords(hira[0..e.kana], e.romaji);
            im.addReadings(hira[0..e.kana], e.romaji);
        }
        im.fillKana();
    }

    fn addCandidate(im: *InputMethod, c: Candidate) void {
        if (im.pool_len == pool_size or c.text.len == 0) return;
        for (im.pool[0..im.pool_len]) |had| if (std.mem.eql(u8, had.text, c.text)) return;
        im.pool[im.pool_len] = c;
        im.pool_len += 1;
    }

    /// The common words read as `reading`, and Unihan's kanji with their
    /// okurigana.
    fn addWords(im: *InputMethod, reading: []const u8, consumes: usize) void {
        for (japanese_words.all) |w| if (std.mem.eql(u8, w[0], reading)) im.addCandidate(.{ .text = w[1], .consumes = consumes });
        var i = lowerBound(&kana_table.words, reading);
        while (i < kana_table.words.len and std.mem.eql(u8, kana_table.words[i][0], reading)) : (i += 1)
            im.addCandidate(.{ .text = kana_table.words[i][1], .consumes = consumes });
    }

    /// The kanji read as `reading`, each.
    fn addReadings(im: *InputMethod, reading: []const u8, consumes: usize) void {
        const i = lowerBound(&kana_table.kanji, reading);
        if (i == kana_table.kanji.len or !std.mem.eql(u8, kana_table.kanji[i][0], reading)) return;
        var it = (std.unicode.Utf8View.init(kana_table.kanji[i][1]) catch return).iterator();
        while (it.nextCodepointSlice()) |ch| im.addCandidate(.{ .text = ch, .consumes = consumes });
    }

    /// The page of the kana candidates from `first`.
    fn fillKana(im: *InputMethod) void {
        im.count = @min(page_size, im.pool_len -| im.first);
        @memcpy(im.candidates[0..im.count], im.pool[im.first..][0..im.count]);
        im.selected = @min(im.selected, im.count -| 1);
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

/// The first of a sorted table's rows whose key is not less than `key`.
fn lowerBound(table: []const struct { []const u8, []const u8 }, key: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (std.mem.order(u8, table[mid][0], key) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Japanese punctuation for `c`, typed in Japanese (not composing).
fn japanesePunctuation(c: u21) ?[]const u8 {
    if (c > 0x7f) return null;
    return kanaPunctuation(@intCast(c));
}

/// Punctuation as Japanese has it, for what is typed composing kana.
fn kanaPunctuation(c: u8) ?[]const u8 {
    return switch (c) {
        ',' => "、",
        '.' => "。",
        '?' => "？",
        '!' => "！",
        '[' => "「",
        ']' => "」",
        else => null,
    };
}

/// Romaji (as typed, Hepburn or as Japanese keyboards type it: "shi" or
/// "si", "tsu" or "tu") and the kana each is.
const romaji_table = [_]struct { []const u8, []const u8 }{
    .{ "a", "あ" },    .{ "i", "い" },    .{ "u", "う" },    .{ "e", "え" },    .{ "o", "お" },
    .{ "ka", "か" },   .{ "ki", "き" },   .{ "ku", "く" },   .{ "ke", "け" },   .{ "ko", "こ" },
    .{ "kya", "きゃ" }, .{ "kyu", "きゅ" }, .{ "kyo", "きょ" }, .{ "kye", "きぇ" }, .{ "kyi", "きぃ" },
    .{ "ga", "が" },   .{ "gi", "ぎ" },   .{ "gu", "ぐ" },   .{ "ge", "げ" },   .{ "go", "ご" },
    .{ "gya", "ぎゃ" }, .{ "gyu", "ぎゅ" }, .{ "gyo", "ぎょ" },
    .{ "sa", "さ" },   .{ "si", "し" },   .{ "shi", "し" },  .{ "su", "す" },   .{ "se", "せ" },
    .{ "so", "そ" },   .{ "sha", "しゃ" }, .{ "shu", "しゅ" }, .{ "she", "しぇ" }, .{ "sho", "しょ" },
    .{ "sya", "しゃ" }, .{ "syu", "しゅ" }, .{ "syo", "しょ" },
    .{ "za", "ざ" },   .{ "zi", "じ" },   .{ "zu", "ず" },   .{ "ze", "ぜ" },   .{ "zo", "ぞ" },
    .{ "ja", "じゃ" },  .{ "ji", "じ" },   .{ "ju", "じゅ" },  .{ "je", "じぇ" },  .{ "jo", "じょ" },
    .{ "jya", "じゃ" }, .{ "jyu", "じゅ" }, .{ "jyo", "じょ" }, .{ "zya", "じゃ" }, .{ "zyu", "じゅ" },
    .{ "zyo", "じょ" },
    .{ "ta", "た" },   .{ "ti", "ち" },   .{ "chi", "ち" },  .{ "tu", "つ" },   .{ "tsu", "つ" },
    .{ "te", "て" },   .{ "to", "と" },   .{ "cha", "ちゃ" }, .{ "chu", "ちゅ" }, .{ "che", "ちぇ" },
    .{ "cho", "ちょ" }, .{ "tya", "ちゃ" }, .{ "tyu", "ちゅ" }, .{ "tyo", "ちょ" }, .{ "thi", "てぃ" },
    .{ "twu", "とぅ" },
    .{ "da", "だ" },   .{ "di", "ぢ" },   .{ "du", "づ" },   .{ "de", "で" },   .{ "do", "ど" },
    .{ "dya", "ぢゃ" }, .{ "dyu", "ぢゅ" }, .{ "dyo", "ぢょ" }, .{ "dhi", "でぃ" }, .{ "dwu", "どぅ" },
    .{ "na", "な" },   .{ "ni", "に" },   .{ "nu", "ぬ" },   .{ "ne", "ね" },   .{ "no", "の" },
    .{ "nya", "にゃ" }, .{ "nyu", "にゅ" }, .{ "nyo", "にょ" },
    .{ "ha", "は" },   .{ "hi", "ひ" },   .{ "hu", "ふ" },   .{ "fu", "ふ" },   .{ "he", "へ" },
    .{ "ho", "ほ" },   .{ "hya", "ひゃ" }, .{ "hyu", "ひゅ" }, .{ "hyo", "ひょ" }, .{ "fa", "ふぁ" },
    .{ "fi", "ふぃ" },  .{ "fe", "ふぇ" },  .{ "fo", "ふぉ" },  .{ "fyu", "ふゅ" },
    .{ "ba", "ば" },   .{ "bi", "び" },   .{ "bu", "ぶ" },   .{ "be", "べ" },   .{ "bo", "ぼ" },
    .{ "bya", "びゃ" }, .{ "byu", "びゅ" }, .{ "byo", "びょ" },
    .{ "pa", "ぱ" },   .{ "pi", "ぴ" },   .{ "pu", "ぷ" },   .{ "pe", "ぺ" },   .{ "po", "ぽ" },
    .{ "pya", "ぴゃ" }, .{ "pyu", "ぴゅ" }, .{ "pyo", "ぴょ" },
    .{ "ma", "ま" },   .{ "mi", "み" },   .{ "mu", "む" },   .{ "me", "め" },   .{ "mo", "も" },
    .{ "mya", "みゃ" }, .{ "myu", "みゅ" }, .{ "myo", "みょ" },
    .{ "ya", "や" },   .{ "yu", "ゆ" },   .{ "yo", "よ" },   .{ "ye", "いぇ" },
    .{ "ra", "ら" },   .{ "ri", "り" },   .{ "ru", "る" },   .{ "re", "れ" },   .{ "ro", "ろ" },
    .{ "rya", "りゃ" }, .{ "ryu", "りゅ" }, .{ "ryo", "りょ" },
    .{ "wa", "わ" },   .{ "wo", "を" },   .{ "wi", "うぃ" },  .{ "we", "うぇ" },
    .{ "va", "ゔぁ" },  .{ "vi", "ゔぃ" },  .{ "vu", "ゔ" },   .{ "ve", "ゔぇ" },  .{ "vo", "ゔぉ" },
    .{ "xa", "ぁ" },   .{ "xi", "ぃ" },   .{ "xu", "ぅ" },   .{ "xe", "ぇ" },   .{ "xo", "ぉ" },
    .{ "la", "ぁ" },   .{ "li", "ぃ" },   .{ "lu", "ぅ" },   .{ "le", "ぇ" },   .{ "lo", "ぉ" },
    .{ "xtu", "っ" },  .{ "ltu", "っ" },  .{ "xtsu", "っ" }, .{ "ltsu", "っ" }, .{ "xya", "ゃ" },
    .{ "xyu", "ゅ" },  .{ "xyo", "ょ" },  .{ "lya", "ゃ" },  .{ "lyu", "ゅ" },  .{ "lyo", "ょ" },
    .{ "xwa", "ゎ" },  .{ "lwa", "ゎ" },
};

fn romajiKana(r: []const u8) ?[]const u8 {
    for (romaji_table) |e| if (std.mem.eql(u8, e[0], r)) return e[1];
    return null;
}

/// Whether more typed after `r` could make it a kana.
fn startsRomaji(r: []const u8) bool {
    for (romaji_table) |e| if (e[0].len > r.len and std.mem.startsWith(u8, e[0], r)) return true;
    return false;
}

fn isVowel(c: u8) bool {
    return switch (c) {
        'a', 'i', 'u', 'e', 'o' => true,
        else => false,
    };
}

/// The kana romaji starting `r` is, and how much of it; null if it may yet
/// be one (at the end of what is typed, unless `final`).
fn romajiStep(r: []const u8, final: bool) ?struct { kana: []const u8, used: usize } {
    const c = r[0];
    if (kanaPunctuation(c)) |p| return .{ .kana = p, .used = 1 };
    if (c == '-') return .{ .kana = "ー", .used = 1 };
    // A separator ("n'a": んあ), which is nothing itself.
    if (c == '\'') return .{ .kana = "", .used = 1 };
    if (c < 'a' or c > 'z') return .{ .kana = r[0..1], .used = 1 };
    if (c == 'n') {
        if (r.len == 1) return if (final) .{ .kana = "ん", .used = 1 } else null;
        const next = r[1];
        if (next == '\'') return .{ .kana = "ん", .used = 2 };
        // "nn" is ん, but "nna" is ん then な ("konna": こんな).
        if (next == 'n') return .{ .kana = "ん", .used = if (r.len > 2 and (isVowel(r[2]) or r[2] == 'y')) 1 else 2 };
        if (!isVowel(next) and next != 'y') return .{ .kana = "ん", .used = 1 };
    }
    // A doubled consonant ("kk", "tch") is a small っ before it.
    if (r.len >= 2 and !isVowel(c) and (r[1] == c or (c == 't' and r[1] == 'c'))) return .{ .kana = "っ", .used = 1 };
    var len: usize = @min(r.len, 4);
    while (len > 0) : (len -= 1) {
        if (romajiKana(r[0..len])) |k| return .{ .kana = k, .used = len };
    }
    if (!final and startsRomaji(r)) return null;
    // Nothing: the letter as it is.
    return .{ .kana = r[0..1], .used = 1 };
}

/// Where a kana (or letter) ends: in the kana, and in the romaji.
const KanaEnd = struct { kana: usize, romaji: usize };

/// Romaji `r` as kana, into `out`: as far as it reads, then the letters
/// that do not yet (unless `final`, when they are as they are, and a last
/// "n" is ん). Where each kana ends goes in `ends`, if given.
fn romajiToKana(r: []const u8, final: bool, out: []u8, ends: ?[]KanaEnd) struct { len: usize, ends: usize } {
    var len: usize = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < r.len) {
        const step = romajiStep(r[i..], final) orelse break;
        if (len + step.kana.len > out.len) break;
        @memcpy(out[len..][0..step.kana.len], step.kana);
        len += step.kana.len;
        i += step.used;
        if (ends) |e| if (n < e.len and step.kana.len > 0) {
            e[n] = .{ .kana = len, .romaji = i };
            n += 1;
        };
    }
    // The letters that do not read yet.
    const tail = r[i..];
    const t = @min(tail.len, out.len - len);
    @memcpy(out[len..][0..t], tail[0..t]);
    return .{ .len = len + t, .ends = n };
}

/// What is left of romaji `r` with its last kana taken back (or its last
/// letter, if it does not read yet).
fn backspaceRomaji(r: []const u8) usize {
    var i: usize = 0;
    var last: usize = 0;
    while (i < r.len) {
        const step = romajiStep(r[i..], false) orelse return r.len - 1;
        last = i;
        i += step.used;
    }
    return last;
}

/// Hiragana as katakana, into `out`.
fn toKatakana(h: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    var it = (std.unicode.Utf8View.init(h) catch return "").iterator();
    while (it.nextCodepoint()) |c| {
        const k: u21 = if (c >= 0x3041 and c <= 0x3096) c + 0x60 else c;
        const n = std.unicode.utf8CodepointSequenceLength(k) catch continue;
        if (len + n > out.len) break;
        _ = std.unicode.utf8Encode(k, out[len..][0..n]) catch continue;
        len += n;
    }
    return out[0..len];
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
    try testing.expect(!im.native);
}

test "pinyin: past the end of a page, the next" {
    var im: InputMethod = .{ .language = .pinyin };
    typeText(&im, "shi");
    try testing.expectEqual(@as(usize, page_size), im.count);
    for (0..page_size) |_| _ = press(&im, .down, null);
    try testing.expectEqual(@as(usize, page_size), im.first);
    try testing.expect(!std.mem.eql(u8, im.candidates[0].text, "是"));
}

test "romaji: kana as typed, and Enter puts in the hiragana" {
    var im: InputMethod = .{ .language = .romaji };
    typeText(&im, "nihon");
    // A last "n" may yet be "na".
    try testing.expectEqualStrings("にほn", im.composed());
    try testing.expectEqualStrings("にほん", im.candidates[0].text);
    // The word, then the katakana.
    try testing.expectEqualStrings("日本", im.candidates[1].text);
    try testing.expectEqualStrings("ニホン", im.candidates[2].text);
    try testing.expectEqualStrings("にほん", press(&im, .enter, null).commit.?);
    try testing.expect(im.composing == null);
}

test "romaji: Space goes to the next candidate, Enter puts it in" {
    var im: InputMethod = .{ .language = .romaji };
    typeText(&im, "taberu");
    try testing.expectEqualStrings("たべる", im.composed());
    _ = press(&im, .space, ' ');
    try testing.expectEqualStrings("食べる", press(&im, .enter, null).commit.?);
}

test "romaji: a kanji for the start, and the rest goes on" {
    var im: InputMethod = .{ .language = .romaji };
    typeText(&im, "watashiha");
    // The first that is for the start: 私, for わたし.
    var i: usize = 0;
    while (i < im.count and im.candidates[i].consumes == 0) i += 1;
    try testing.expectEqualStrings("私", im.candidates[i].text);
    const out = im.choose(i);
    try testing.expectEqualStrings("私", out.commit.?);
    try testing.expectEqualStrings("は", im.composed());
}

test "romaji: small tsu, n, long vowels, punctuation and Backspace" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("がっこう", out[0..romajiToKana("gakkou", true, &out, null).len]);
    try testing.expectEqualStrings("こんにちは", out[0..romajiToKana("konnnichiha", true, &out, null).len]);
    try testing.expectEqualStrings("こんな", out[0..romajiToKana("konna", true, &out, null).len]);
    try testing.expectEqualStrings("まっちゃ", out[0..romajiToKana("matcha", true, &out, null).len]);
    try testing.expectEqualStrings("コーヒー", toKatakana(out[0..romajiToKana("ko-hi-", true, &out, null).len], out[32..]));
    try testing.expectEqualStrings("しんよう", out[0..romajiToKana("shin'you", true, &out, null).len]);
    try testing.expectEqualStrings("きょ", out[0..romajiToKana("kyo", true, &out, null).len]);
    try testing.expectEqualStrings("ky", out[0..romajiToKana("ky", false, &out, null).len]);
    // Backspace: the last kana, or letter.
    try testing.expectEqual(@as(usize, 2), backspaceRomaji("kaki"));
    try testing.expectEqual(@as(usize, 3), backspaceRomaji("kaky"));
    var im: InputMethod = .{ .language = .romaji };
    typeText(&im, "sushi");
    _ = press(&im, .backspace, null);
    try testing.expectEqualStrings("す", im.composed());
    // Punctuation: Japanese.
    _ = press(&im, .escape, null);
    try testing.expectEqualStrings("。", press(&im, .period, '.').commit.?);
}
