//! kete's own input method, for text typed into its text fields and areas
//! (what has `text_input`): emoji by name. `:` (at the start, or after a
//! space) then a name, as chat apps have it: ":smi" offers 😄 🙂 😊 and
//! others, in a popup by the cursor. Up and Down choose; Enter, Tab or a
//! closing `:` put the emoji in; Escape, a space or anything else puts in
//! what was typed. What is typed shows in the field as its preedit,
//! underlined.
//!
//! Languages that need an input method (Chinese, Japanese and others) are
//! the system's to provide, and arrive as an input method's text
//! (`text_preedit`, `text_commit`). So can emoji, where the system has an
//! input method that does them: then this is turned off (see
//! `SharedResources.own_input_method`).
//!
//! Never in a password field. `WindowUi` gives it the keys first (see
//! `WindowUi.key`), and sends what it composes and puts in to the field
//! with the focus as an input method's (`text_preedit`, `text_commit`).

const std = @import("std");
const widget = @import("widget.zig");
const emoji = @import("emoji.zig");

const Key = widget.Event.Key;

/// A candidate: the emoji put in, and its name, which the popup shows.
pub const Candidate = struct {
    text: []const u8,
    label: []const u8 = "",
};

/// How many candidates show.
pub const page_size = 9;

pub const InputMethod = struct {
    /// Emoji offered after `:` (unless the app turns them off).
    emoji: bool = true,
    /// An emoji's name is being typed: `:` and the name so far.
    composing: bool = false,
    buf: [64]u8 = undefined,
    len: usize = 0,
    /// The candidates shown, and the one chosen.
    candidates: [page_size]Candidate = undefined,
    count: usize = 0,
    selected: usize = 0,
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

    /// What is composed, as typed.
    pub fn composed(im: *const InputMethod) []const u8 {
        return im.buf[0..im.len];
    }

    /// Whether candidates show.
    pub fn showing(im: *const InputMethod) bool {
        return im.composing and im.count > 0;
    }

    /// Offers `k` to the input method, in a field whose text before the
    /// cursor is `before` (for knowing a `:` starts an emoji's name).
    pub fn key(im: *InputMethod, k: Key, before: []const u8) Outcome {
        if (!k.pressed or k.ctrl) return .{};
        if (im.composing) return im.emojiKey(k);
        const c = k.char orelse return .{};
        // An emoji's name starts.
        if (im.emoji and c == ':' and startsWord(before)) {
            im.buf[0] = ':';
            im.len = 1;
            im.composing = true;
            im.count = 0;
            im.selected = 0;
            return .{ .taken = true, .preedit = true };
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
                im.find();
                return .{ .taken = true, .preedit = true };
            },
            .up, .down => {
                if (im.count > 0) {
                    if (k.key == .down) im.selected = @min(im.selected + 1, im.count - 1) else im.selected -|= 1;
                }
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
        im.find();
        return .{ .taken = true, .preedit = true };
    }

    /// Chooses the candidate shown at `i` (clicked).
    pub fn choose(im: *InputMethod, i: usize) Outcome {
        if (i >= im.count) return .{};
        im.selected = i;
        return im.commitChosen();
    }

    /// Ends composing (the field lost the focus, say): what was typed goes
    /// in as it is.
    pub fn finish(im: *InputMethod) Outcome {
        if (!im.composing) return .{};
        return im.commitRaw(true);
    }

    fn reset(im: *InputMethod) void {
        im.composing = false;
        im.len = 0;
        im.count = 0;
        im.selected = 0;
    }

    /// What was typed goes in as it is (and, if `taken`, the key is the
    /// input method's).
    fn commitRaw(im: *InputMethod, taken: bool) Outcome {
        if (!im.composing) return .{ .taken = taken };
        const text = im.commit_buf[0..im.len];
        @memcpy(text, im.composed());
        im.reset();
        return .{ .taken = taken, .commit = text, .preedit = true };
    }

    /// The chosen emoji goes in.
    fn commitChosen(im: *InputMethod) Outcome {
        const cand = im.candidates[im.selected];
        const text = im.commit_buf[0..cand.text.len];
        @memcpy(text, cand.text);
        im.reset();
        return .{ .taken = true, .commit = text, .preedit = true };
    }

    fn find(im: *InputMethod) void {
        var found: [page_size]emoji.Emoji = undefined;
        // Two letters at least, after the colon.
        const n = if (im.len >= 3) emoji.search(im.composed()[1..], &found) else 0;
        for (found[0..n], im.candidates[0..n]) |e, *cand| cand.* = .{ .text = e.text, .label = e.name };
        im.count = n;
        im.selected = 0;
    }
};

/// Whether `before` (the text before the cursor) ends where a word starts:
/// it is empty, or ends in a space.
fn startsWord(before: []const u8) bool {
    if (before.len == 0) return true;
    return switch (before[before.len - 1]) {
        ' ', '\t', '\n', '(', '[', '"' => true,
        else => false,
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
    try testing.expect(!im.composing);
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

test "Down and Up choose, and a closing ':' puts the emoji in" {
    var im: InputMethod = .{};
    typeText(&im, ":smil");
    try testing.expect(im.count > 1);
    _ = press(&im, .down, null);
    try testing.expectEqual(@as(usize, 1), im.selected);
    _ = press(&im, .up, null);
    _ = press(&im, .up, null);
    try testing.expectEqual(@as(usize, 0), im.selected);
    try testing.expectEqualStrings(im.candidates[0].text, press(&im, .semicolon, ':').commit.?);
}
