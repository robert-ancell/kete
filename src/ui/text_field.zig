//! TextField: one line of text to type, in an outlined box.
//! Clicking it gives it the keyboard; typing, Backspace, Delete, the arrow
//! keys, Home and End edit it; Enter submits. With `obscure` (for
//! passwords) it shows dots.
//!
//! Text is selected by dragging over it, or with Shift and the arrow keys,
//! Home or End (Ctrl+A: all of it). Ctrl+X cuts the selection, Ctrl+C
//! copies it and Ctrl+V pastes over it, when the text comes (through the
//! UI's clipboard: see `WindowUi.copyText` and `WindowUi.pasteText`); the right button, or holding the left down, shows a
//! menu with the same (`WindowUi.openMenu`). An obscured field's text cannot be
//! cut or copied.

const a11y = @import("accessibility.zig");
const std = @import("std");
const edit = @import("edit.zig");
const gfx = @import("gfx");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const Column = @import("flex.zig").Column;
const menu = @import("menu.zig");
const Padding = @import("padding.zig").Padding;

const Node = widget.WidgetNode;
const Event = widget.Event;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

/// A text field: one line of text to edit, with a placeholder, a
/// selection, copy and paste.
///
/// ![The TextField example](images/TextField.png)
///
/// ```zig
/// return cx.make(kete.Column{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
///     kete.TextField{ .placeholder = "Search", .on_changed = .of(state, State.setText) },
///     kete.TextField{ .initial = "Ada Lovelace", .on_changed = .of(state, State.setText) },
/// }) });
/// ```
pub const TextField = struct {
    /// Shown, dimmed, while it is empty.
    placeholder: []const u8 = "",
    /// What it holds when it first appears (give it a new key to start
    /// again with another).
    initial: []const u8 = "",
    /// Dots instead of the characters (for passwords).
    obscure: bool = false,
    /// The most bytes it holds.
    max_len: usize = 63,
    /// Its width, in pixels.
    width: f32 = 240,
    /// Text size; the theme's body size if null.
    size: ?f32 = null,
    /// Called with the text each time it changes.
    on_changed: ?widget.ValueCallback([]const u8) = null,
    /// Enter was pressed.
    on_submit: ?widget.Callback = null,
    /// Take the keyboard when it first appears (as a field to fill in that
    /// has just been asked for does).
    autofocus: bool = false,
    /// Whether it can be used: if not, it is dimmed and takes no input.
    enabled: bool = true,

    pub const capacity = 128;

    /// The state it starts with: holding `initial`.
    pub fn initState(self: *const TextField) State {
        var st: State = .{};
        _ = st.insert(self.initial, self.max_len);
        return st;
    }

    pub const State = struct {
        buf: [capacity]u8 = undefined,
        len: usize = 0,
        /// Where typing goes: a byte index.
        cursor: usize = 0,
        /// The other end of the selection (the cursor is one end), if
        /// there is one.
        anchor: ?usize = null,
        focused: bool = false,
        /// It has taken the keyboard by itself (`autofocus`), once.
        autofocused: bool = false,
        hovered: bool = false,
        /// Selecting by dragging.
        dragging: bool = false,
        /// What the menu's actions (and pasting) need, from the widget as
        /// last seen.
        ui: ?*@import("runtime.zig").WindowUi = null,
        node: ?*Node = null,
        max_len: usize = capacity,
        obscure: bool = false,
        /// Whether an `obscure` password field has been toggled visible.
        revealed: bool = false,
        toggle_hovered: bool = false,
        toggle_pressed: bool = false,
        on_changed: ?widget.ValueCallback([]const u8) = null,
        /// Horizontal scroll offset in pixels.
        scroll: f32 = 0,
        preedit_buf: [capacity]u8 = undefined,
        preedit_len: usize = 0,
        preedit_cursor_begin: i32 = 0,
        preedit_cursor_end: i32 = 0,
        last_change_other: bool = false,

        pub fn text(s: *const State) []const u8 {
            return s.buf[0..s.len];
        }

        pub fn preedit(s: *const State) []const u8 {
            return s.preedit_buf[0..s.preedit_len];
        }

        /// The selected bytes' start and end, if any are.
        pub fn selection(s: *const State) ?[2]usize {
            const a = s.anchor orelse return null;
            if (a == s.cursor) return null;
            return .{ @min(a, s.cursor), @max(a, s.cursor) };
        }

        /// Removes the selection's text. Returns whether there was any.
        fn deleteSelection(s: *State) bool {
            const sel = s.selection() orelse return false;
            std.mem.copyForwards(u8, s.buf[sel[0] .. s.len - (sel[1] - sel[0])], s.buf[sel[1]..s.len]);
            s.len -= sel[1] - sel[0];
            s.cursor = sel[0];
            s.anchor = null;
            return true;
        }

        /// Deletes `before_len` bytes before the cursor and `after_len` bytes
        /// after it (`zwp_text_input_v3.delete_surrounding_text`).
        pub fn deleteSurrounding(s: *State, before_len: u32, after_len: u32) bool {
            _ = s.deleteSelection();
            const from = s.snap(s.cursor -| @min(@as(usize, before_len), s.cursor));
            const to = s.snap(@min(s.len, s.cursor + @as(usize, after_len)));
            if (to <= from) return false;
            s.remove(from, to);
            s.cursor = from;
            return true;
        }

        /// Puts `t` (UTF-8) at the cursor, over the selection: its
        /// printable characters (line breaks and tabs as spaces), as many
        /// as fit (`max` bytes in all). Returns whether the text changed.
        fn insert(s: *State, t: []const u8, max: usize) bool {
            var changed = s.deleteSelection();
            var at: usize = 0;
            while (at < t.len) {
                const n = std.unicode.utf8ByteSequenceLength(t[at]) catch {
                    at += 1;
                    continue;
                };
                if (at + n > t.len) break;
                const c0 = std.unicode.utf8Decode(t[at..][0..n]) catch {
                    at += 1;
                    continue;
                };
                at += n;
                const c: u21 = if (c0 == '\n' or c0 == '\t' or c0 == '\r') ' ' else c0;
                if (c < 0x20 or (c >= 0x7f and c < 0xa0)) continue;
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &enc) catch continue;
                if (s.len + len > @min(max, capacity)) break;
                std.mem.copyBackwards(u8, s.buf[s.cursor + len .. s.len + len], s.buf[s.cursor..s.len]);
                @memcpy(s.buf[s.cursor..][0..len], enc[0..len]);
                s.len += len;
                s.cursor += len;
                changed = true;
            }
            return changed;
        }

        /// Removes the bytes from `from` to `to`.
        fn remove(s: *State, from: usize, to: usize) void {
            std.mem.copyForwards(u8, s.buf[from .. s.len - (to - from)], s.buf[to..s.len]);
            s.len -= to - from;
        }

        /// The character boundary at or before byte `i`.
        pub fn snap(s: *const State, i: usize) usize {
            if (i >= s.len) return s.len;
            var j = i;
            while (j > 0 and s.buf[j] & 0xc0 == 0x80) j -= 1;
            return j;
        }

        /// The character boundary before byte `i` (0 at the start).
        fn before(s: *const State, i: usize) usize {
            var j = @min(i, s.len) -| 1;
            while (j > 0 and s.buf[j] & 0xc0 == 0x80) j -= 1;
            return j;
        }

        /// The character boundary after byte `i` (the end at the end).
        fn after(s: *const State, i: usize) usize {
            if (i >= s.len) return s.len;
            var j = i + 1;
            while (j < s.len and s.buf[j] & 0xc0 == 0x80) j += 1;
            return j;
        }

        /// Moves the cursor, extending the selection (from where the cursor
        /// was) or dropping it.
        fn moveTo(s: *State, to: usize, extend: bool) void {
            if (extend) {
                if (s.anchor == null) s.anchor = s.cursor;
            } else s.anchor = null;
            s.cursor = s.snap(to);
        }

        pub fn selectAll(s: *State) void {
            s.anchor = 0;
            s.cursor = s.len;
        }

        /// Selects the word (or contiguous run of whitespace/punctuation)
        /// at byte `index`.
        pub fn selectWordAt(s: *State, index: usize) void {
            if (s.len == 0) {
                s.anchor = null;
                s.cursor = 0;
                return;
            }
            if (s.isObscured()) {
                s.selectAll();
                return;
            }
            const text_slice = s.buf[0..s.len];
            var pivot = s.snap(@min(index, s.len));
            if (pivot == s.len) {
                pivot = s.before(s.len);
            } else if (pivot > 0 and charClassAt(text_slice, pivot) != .word) {
                const prev = s.before(pivot);
                if (charClassAt(text_slice, prev) == .word) pivot = prev;
            }
            const cls = charClassAt(text_slice, pivot);
            var start = pivot;
            while (start > 0) {
                const prev = s.before(start);
                if (charClassAt(text_slice, prev) != cls) break;
                start = prev;
            }
            var end = s.after(pivot);
            while (end < s.len) {
                if (charClassAt(text_slice, end) != cls) break;
                end = s.after(end);
            }
            s.anchor = start;
            s.cursor = end;
        }

        pub fn isObscured(s: *const State) bool {
            return s.obscure and !s.revealed;
        }

        /// Copies the selection (not from an obscured field).
        pub fn copy(s: *State) void {
            const sel = s.selection() orelse return;
            if (s.isObscured()) return;
            if (s.ui) |u| u.copyText(s.buf[sel[0]..sel[1]]);
        }

        pub fn cut(s: *State) void {
            if (s.isObscured() or s.selection() == null) return;
            s.copy();
            if (s.deleteSelection()) s.notifyChanged();
        }

        /// Pastes the clipboard's text over the selection, when it comes.
        pub fn paste(s: *State) void {
            const u = s.ui orelse return;
            u.pasteText(s.node orelse return, .of(s, State.pasted));
        }

        fn pasted(s: *State, t: []const u8) void {
            s.last_change_other = true;
            if (s.insert(t, s.max_len)) s.notifyChanged();
        }

        fn notifyChanged(s: *State) void {
            if (s.on_changed) |f| f.call(s.text());
            if (s.ui) |u| u.needs_frame = true;
        }

        /// Edits for a key; returns whether the text changed.
        fn key(s: *State, k: Event.Key, max: usize) bool {
            if (k.ctrl) {
                switch (k.key) {
                    .a => s.selectAll(),
                    .c => s.copy(),
                    .x => if (!s.isObscured() and s.selection() != null) {
                        s.copy();
                        return s.deleteSelection();
                    },
                    // The text comes later (see `pasted`).
                    .v => s.paste(),
                    else => {},
                }
                return false;
            }
            switch (k.key) {
                .backspace => {
                    if (s.deleteSelection()) return true;
                    if (s.cursor == 0) return false;
                    const from = s.before(s.cursor);
                    s.remove(from, s.cursor);
                    s.cursor = from;
                    return true;
                },
                .delete => {
                    if (s.deleteSelection()) return true;
                    if (s.cursor == s.len) return false;
                    s.remove(s.cursor, s.after(s.cursor));
                    return true;
                },
                // Without Shift, a selection collapses to its start or end.
                .left => if (!k.shift and s.selection() != null) s.moveTo(s.selection().?[0], false) else s.moveTo(s.before(s.cursor), k.shift),
                .right => if (!k.shift and s.selection() != null) s.moveTo(s.selection().?[1], false) else s.moveTo(s.after(s.cursor), k.shift),
                .home => s.moveTo(0, k.shift),
                .end => s.moveTo(s.len, k.shift),
                else => if (k.char) |c| {
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c, &enc) catch return false;
                    return s.insert(enc[0..n], max);
                },
            }
            return false;
        }
    };

    const height = 44;
    const pad = 14;
    const toggle_pad = 40;
    const toggle_radius = 16;
    const toggle_icon_size = 20;
    const dot = "•";

    fn fontStyle(self: *const TextField, n: *const Node) ?font.Style {
        const f = n.ui.font orelse return null;
        return .{ .font = f, .size = self.size orelse n.theme().body_size };
    }

    /// Notes what the state's actions (the menu's, which come later) need.
    fn remember(self: *const TextField, n: *Node) *State {
        const st = n.state(State);
        st.ui = n.ui;
        st.node = n;
        st.max_len = self.max_len;
        st.obscure = self.obscure;
        if (!self.obscure) {
            st.revealed = false;
            st.toggle_hovered = false;
            st.toggle_pressed = false;
        }
        st.on_changed = self.on_changed;
        return st;
    }

    pub fn focusable(self: *const TextField, _: *Node) bool {
        return self.enabled;
    }

    pub fn accessible(self: *const TextField, n: *Node) ?a11y.Info {
        const st = n.state(State);
        const value = if (self.isObscured(st)) "" else st.text();
        return .{
            .role = .textbox,
            // With no label, named by its placeholder (as browsers do).
            .label = self.placeholder,
            .placeholder = self.placeholder,
            // A password field: ARIA has no role of its own for one.
            .roledescription = if (self.obscure) "password" else "",
            .text = value,
            .caret = std.unicode.utf8CountCodepoints(st.text()[0..@min(st.cursor, st.text().len)]) catch null,
            .disabled = !self.enabled,
        };
    }

    pub fn layout(self: *const TextField, n: *Node, c: Constraints) Size {
        const s = self.fontStyle(n);
        const h: f32 = if (s) |st| @max(height, @ceil(st.lineHeight() + 20)) else height;
        const st = self.remember(n);
        if (!self.enabled) {
            st.toggle_hovered = false;
            st.toggle_pressed = false;
            if (st.focused) {
                st.focused = false;
                if (n.ui.focused == n) n.ui.focused = null;
            }
        } else if (self.autofocus and !st.autofocused) {
            st.autofocused = true;
            n.ui.focus(n);
        }
        return c.constrain(.{ .w = self.width, .h = h });
    }

    pub fn minSize(self: *const TextField, n: *Node, c: Constraints) Size {
        const s = self.fontStyle(n);
        const h: f32 = if (s) |st| @max(height, @ceil(st.lineHeight() + 20)) else height;
        return c.constrain(.{ .w = self.width, .h = h });
    }

    /// Whether the field is currently hiding its characters as dots.
    pub fn isObscured(self: *const TextField, st: *const State) bool {
        return self.obscure and !st.revealed;
    }

    /// Whether `pos` (relative to the widget) is over the right-hand
    /// visibility toggle button.
    fn inToggle(self: *const TextField, n: *const Node, pos: geometry.Point) bool {
        if (!self.obscure or n.size.w < toggle_pad) return false;
        return pos[0] >= n.size.w - toggle_pad and pos[0] < n.size.w and pos[1] >= 0 and pos[1] < n.size.h;
    }

    pub fn cursor(self: *const TextField, n: *Node, pos: geometry.Point) ?widget.PointerCursor {
        if (!self.enabled) return null;
        if (self.inToggle(n, pos)) return .pointer;
        return .text;
    }

    /// What the input method is told of it while it has the keyboard: the text
    /// around the cursor and where the cursor is.
    pub fn textInput(self: *const TextField, n: *Node) ?widget.TextInputInfo {
        if (!self.enabled) return null;
        const st = n.state(State);
        var cx_px: i32 = pad;
        var cy_px: i32 = 8;
        var ch_px: i32 = @max(1, @as(i32, @intFromFloat(@round(n.size.h))) - 16);
        if (self.fontStyle(n)) |style| {
            const cursor_x = self.xOf(style, st, st.cursor);
            const scroll = self.updateScroll(n, style, st);
            const baseline = @round((n.size.h - style.lineHeight()) / 2 + style.ascent());
            cx_px = @intFromFloat(@round(pad - scroll + cursor_x));
            cy_px = @intFromFloat(@round(baseline - style.ascent()));
            ch_px = @max(1, @as(i32, @intFromFloat(@round(style.lineHeight()))));
        }
        const surr = if (self.isObscured(st)) "" else st.text();
        const cur: u32 = if (self.isObscured(st)) 0 else @intCast(st.cursor);
        const anc: u32 = if (self.isObscured(st)) 0 else @intCast(st.anchor orelse st.cursor);
        return .{
            .surrounding_text = surr,
            .cursor = cur,
            .anchor = anc,
            .cursor_rect = .{ cx_px, cy_px, 2, ch_px },
            .password = self.obscure,
            .multiline = false,
            .change_cause_other = st.last_change_other,
        };
    }

    /// What is shown for `text`: it, or a dot for each character.
    fn shown(self: *const TextField, st: *const State, buf: []u8, text: []const u8) []const u8 {
        if (!self.isObscured(st)) return text;
        const count = @min(std.unicode.utf8CountCodepoints(text) catch text.len, buf.len / dot.len);
        for (0..count) |i| @memcpy(buf[i * dot.len ..][0..dot.len], dot);
        return buf[0 .. count * dot.len];
    }

    /// How far into the text (as shown) byte `i` is.
    fn xOf(self: *const TextField, style: font.Style, st: *const State, i: usize) f32 {
        var buf: [capacity * dot.len]u8 = undefined;
        return font.measure(style, self.shown(st, &buf, st.text()[0..i]));
    }

    /// Updates and returns `st.scroll` so the cursor stays within the visible
    /// text area without jumping when clicking or selecting inside the field.
    fn updateScroll(self: *const TextField, n: *const Node, style: font.Style, st: *State) f32 {
        const right_pad: f32 = if (self.obscure) toggle_pad else pad;
        const room = @max(n.size.w - pad - right_pad, 0);
        const cursor_x = self.xOf(style, st, st.cursor);
        const total_w = self.xOf(style, st, st.len);
        if (cursor_x < st.scroll) {
            st.scroll = cursor_x;
        } else if (cursor_x > st.scroll + room) {
            st.scroll = cursor_x - room;
        }
        st.scroll = std.math.clamp(st.scroll, 0, @max(total_w - room, 0));
        return st.scroll;
    }

    pub fn paint(self: *const TextField, n: *Node, p: *Painter) void {
        const t = n.theme();
        const st = n.state(State);
        const c = p.canvas();
        const r: gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };
        if (!self.enabled) {
            c.strokeRoundedRect(r.outset(-0.5), .all(4), 1, t.on_surface.withAlpha(0.12));
        } else if (st.focused) {
            c.strokeRoundedRect(r.outset(-1), .all(4), 2, t.primary);
        } else {
            c.strokeRoundedRect(r.outset(-0.5), .all(4), 1, if (st.hovered) t.on_surface else t.outline);
        }
        if (self.obscure and n.size.w >= toggle_pad) {
            const cx_btn = n.size.w - toggle_pad / 2;
            const cy_btn = n.size.h / 2;
            if (self.enabled and (st.toggle_hovered or st.toggle_pressed)) {
                c.fillCircle(.{ cx_btn, cy_btn }, toggle_radius, t.on_surface.withAlpha(if (st.toggle_pressed) 0.16 else 0.08));
            }
            const ic: @import("icons").IconName = if (st.revealed) .visibility_off else .visibility;
            const ic_color = if (self.enabled) t.on_surface_variant else t.on_surface.withAlpha(0.38);
            p.icon(ic, @round(cx_btn - toggle_icon_size / 2), @round(cy_btn - toggle_icon_size / 2), toggle_icon_size, ic_color);
        }
        const style = self.fontStyle(n) orelse return;
        const baseline = @round((n.size.h - style.lineHeight()) / 2 + style.ascent());
        var buf: [capacity * dot.len]u8 = undefined;
        const text = self.shown(st, &buf, st.text());
        const cursor_x = self.xOf(style, st, st.cursor);
        // Long text scrolls to keep the cursor in view.
        const right_pad: f32 = if (self.obscure) toggle_pad else pad;
        const room = @max(n.size.w - pad - right_pad, 0);
        const scroll = self.updateScroll(n, style, st);
        const old = p.clipTo(.{ .x = pad - 2, .y = 0, .w = room + 4, .h = n.size.h });
        defer p.restoreClip(old);
        if (!self.enabled) {
            const shown_text = if (st.len == 0) self.placeholder else text;
            _ = p.text(style.size, if (st.len == 0) pad else pad - scroll, baseline, shown_text, t.on_surface.withAlpha(0.38));
            return;
        }
        // The selection behind its text.
        if (st.selection()) |sel| {
            const x0 = self.xOf(style, st, sel[0]);
            const x1 = self.xOf(style, st, sel[1]);
            const sx0 = @max(@round(pad - scroll + x0), pad - 2);
            const sx1 = @min(@round(pad - scroll + x1), pad + room + 2);
            if (sx1 > sx0) {
                c.fillRect(.{ .x = sx0, .y = baseline - style.ascent(), .w = sx1 - sx0, .h = style.lineHeight() }, t.primary.withAlpha(if (st.focused) 0.35 else 0.15));
            }
        }
        if (st.len == 0 and st.preedit_len == 0 and !st.focused) {
            _ = p.text(style.size, pad, baseline, self.placeholder, t.on_surface_variant);
        } else {
            _ = p.text(style.size, pad - scroll, baseline, text, t.on_surface);
        }
        if (st.focused and st.preedit_len > 0 and !self.isObscured(st)) {
            const pre = st.preedit();
            const pre_w = font.measure(style, pre);
            const px = @round(pad - scroll + cursor_x);
            c.fillRect(.{ .x = px, .y = baseline + 1, .w = pre_w, .h = 1 }, t.primary);
            _ = p.text(style.size, px, baseline, pre, t.primary);
        } else if (st.focused and st.selection() == null) {
            const x = @round(pad - scroll + cursor_x);
            c.fillRect(.{ .x = x, .y = baseline - style.ascent(), .w = 2, .h = style.lineHeight() }, t.primary);
        }
    }

    pub fn event(self: *const TextField, n: *Node, e: Event) bool {
        const st = self.remember(n);
        if (!self.enabled) {
            st.hovered = false;
            st.dragging = false;
            st.toggle_hovered = false;
            st.toggle_pressed = false;
            return false;
        }
        switch (e) {
            .enter => st.hovered = true,
            .leave => {
                st.hovered = false;
                if (st.toggle_hovered) {
                    st.toggle_hovered = false;
                    n.ui.needs_frame = true;
                }
            },
            .press => |pr| {
                if (pr.button != .left) return false;
                if (self.inToggle(n, pr.pos)) {
                    st.toggle_pressed = true;
                    st.toggle_hovered = true;
                    n.ui.needs_frame = true;
                    return true;
                }
                n.ui.focus(n);
                // A click places the cursor, a double click selects a word,
                // and a triple click everything; a fourth starts over.
                switch ((@max(pr.clicks, 1) - 1) % 3 + 1) {
                    1 => {
                        // Dragging selects from where it went down.
                        st.moveTo(self.cursorAt(n, pr.pos[0]), false);
                        st.anchor = st.cursor;
                        st.dragging = true;
                    },
                    2 => {
                        st.selectWordAt(self.cursorAt(n, pr.pos[0]));
                        st.dragging = false;
                    },
                    else => {
                        st.selectAll();
                        st.dragging = false;
                    },
                }
                st.last_change_other = true;
                n.ui.needs_frame = true;
                return true;
            },
            .motion => |pos| {
                const over_toggle = self.inToggle(n, pos);
                if (over_toggle != st.toggle_hovered) {
                    st.toggle_hovered = over_toggle;
                    n.ui.needs_frame = true;
                }
                if (st.dragging) {
                    st.cursor = self.cursorAt(n, pos[0]);
                    st.last_change_other = true;
                    n.ui.needs_frame = true;
                }
            },
            .release => |rel| {
                if (st.toggle_pressed) {
                    st.toggle_pressed = false;
                    const over_toggle = rel.inside and self.inToggle(n, rel.pos);
                    st.toggle_hovered = over_toggle;
                    if (over_toggle) st.revealed = !st.revealed;
                    n.ui.needs_frame = true;
                    return true;
                }
                st.dragging = false;
                if (st.selection() == null) st.anchor = null;
                return true;
            },
            .focus => st.focused = true,
            .blur => {
                st.focused = false;
                st.preedit_len = 0;
            },
            .key => |k| {
                if (!k.pressed) return true;
                if (k.key == .enter or k.key == .keypad_enter) {
                    if (self.on_submit) |f| f.call();
                    return true;
                }
                st.last_change_other = true;
                if (st.key(k, self.max_len)) if (self.on_changed) |f| f.call(st.text());
                return true;
            },
            .text_commit => |t| {
                st.preedit_len = 0;
                st.last_change_other = false;
                if (st.insert(t, self.max_len)) if (self.on_changed) |f| f.call(st.text());
                n.ui.needs_frame = true;
                return true;
            },
            .text_delete_surrounding => |del| {
                st.last_change_other = false;
                if (st.deleteSurrounding(del.before_length, del.after_length)) if (self.on_changed) |f| f.call(st.text());
                n.ui.needs_frame = true;
                return true;
            },
            .text_preedit => |pre| {
                const len = @min(pre.text.len, st.preedit_buf.len);
                @memcpy(st.preedit_buf[0..len], pre.text[0..len]);
                st.preedit_len = len;
                st.preedit_cursor_begin = pre.cursor_begin;
                st.preedit_cursor_end = pre.cursor_end;
                n.ui.needs_frame = true;
                return true;
            },
            .context => |pos| {
                if (self.inToggle(n, pos)) return false;
                n.ui.focus(n);
                st.dragging = false;
                // Outside the selection, the cursor goes where it was asked.
                const at = self.cursorAt(n, pos[0]);
                const inside = if (st.selection()) |sel| at >= sel[0] and at <= sel[1] else false;
                if (!inside) st.moveTo(at, false);
                const can_copy = st.selection() != null and !self.isObscured(st);
                const origin = n.position();
                n.ui.openMenu(n, .{ origin[0] + pos[0], origin[1] + pos[1] }, &.{
                    .{ .label = "Cut", .shortcut = "Ctrl+X", .enabled = can_copy, .on_press = .of(st, State.cut) },
                    .{ .label = "Copy", .shortcut = "Ctrl+C", .enabled = can_copy, .on_press = .of(st, State.copy) },
                    .{ .label = "Paste", .shortcut = "Ctrl+V", .on_press = .of(st, State.paste) },
                    .{ .label = "Select all", .shortcut = "Ctrl+A", .enabled = st.len > 0, .on_press = .of(st, State.selectAll) },
                });
                return true;
            },
            .scroll => {},
        }
        return false;
    }

    /// The character boundary nearest `x` (in the widget).
    /// Uses a single forward Layout pass accumulating advance widths (O(N)).
    fn cursorAt(self: *const TextField, n: *const Node, x: f32) usize {
        const st = n.state(State);
        const style = self.fontStyle(n) orelse return st.len;
        const scroll = self.updateScroll(n, style, st);
        var buf: [capacity * dot.len]u8 = undefined;
        const display = self.shown(st, &buf, st.text());
        // `origin` is the pixel x of the start of the text in the widget.
        const origin: f32 = pad - scroll;
        // Check the left edge (byte 0) first.
        var best: usize = 0;
        var best_d = @abs(origin - x);
        var display_at: usize = 0; // byte offset into `display`
        var doc_at: usize = 0; // corresponding byte offset into st.buf
        var lay = font.Layout.init(style, display, 0);
        while (lay.next()) |_| {
            // lay.at is the byte boundary in `display` just after this glyph.
            // Advance doc_at by the same number of codepoints (they correspond
            // 1-to-1; for an obscured field each dot maps to one source char).
            if (self.isObscured(st)) {
                // Each dot.len bytes in display == one codepoint in the source.
                const dots_consumed = (lay.at - display_at) / dot.len;
                for (0..dots_consumed) |_| {
                    doc_at += std.unicode.utf8ByteSequenceLength(st.buf[doc_at]) catch 1;
                }
            } else {
                doc_at = lay.at;
            }
            display_at = lay.at;
            const d = @abs(origin + lay.x - x);
            if (d < best_d) {
                best = doc_at;
                best_d = d;
            }
        }
        return best;
    }
};

const CharClass = edit.CharClass;

fn charClassAt(text: []const u8, i: usize) CharClass {
    if (text[i] < 0x80) return edit.charClass(text[i]);
    // Decode the full codepoint; `i` should always be a sequence-start byte
    // because callers use snap/before/after, but handle malformed UTF-8 safely.
    const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .word;
    if (i + seq_len > text.len) return .word;
    const cp = std.unicode.utf8Decode(text[i..][0..seq_len]) catch return .word;
    return edit.charClass(cp);
}

const testing = std.testing;

test "typing into a text field" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    try u.loadKeymap(@import("window").xkb.testdata.us);
    const Sink = struct {
        text: [64]u8 = undefined,
        len: usize = 0,
        submitted: u32 = 0,
        fn changed(s: *@This(), t: []const u8) void {
            @memcpy(s.text[0..t.len], t);
            s.len = t.len;
        }
        fn submit(s: *@This()) void {
            s.submitted += 1;
        }
    };
    var sink: Sink = .{};
    const App = struct {
        sink: *Sink,
        obscure: bool,
        pub fn build(self: *const @This(), cx: *widget.BuildContext) widget.Widget {
            return cx.make(Padding{ .padding = .all(20), .child = cx.make(Column{ .cross_axis_alignment = .start, .children = cx.makeAll(.{
                TextField{ .placeholder = "Password", .obscure = self.obscure, .on_changed = .of(self.sink, Sink.changed), .on_submit = .of(self.sink, Sink.submit) },
            }) }) });
        }
    };
    u.frame(400, 200, 0, App{ .sink = &sink, .obscure = false });
    const at: geometry.Point = .{ 40, 40 };
    u.pointerMotion(at);
    u.pointerButton(at, .left, true);
    u.pointerButton(at, .left, false);
    try testing.expect(u.focused != null);
    // Shift-A, b, 1, then Backspace, Left, X: "AXb".
    u.keyEvent(.left_shift, true);
    for ([_]widget.KeyboardKey{ .a, .a }, [_]bool{ true, false }) |key, down| u.keyEvent(key, down);
    u.keyEvent(.left_shift, false);
    for ([_]widget.KeyboardKey{ .b, .digit_1, .backspace, .left }) |key| {
        u.keyEvent(key, true);
        u.keyEvent(key, false);
    }
    u.keyEvent(.left_shift, true);
    u.keyEvent(.x, true);
    u.keyEvent(.left_shift, false);
    try testing.expectEqualStrings("AXb", sink.text[0..sink.len]);
    u.keyEvent(.enter, true);
    try testing.expectEqual(@as(u32, 1), sink.submitted);
    // It keeps its text between frames, and paints (obscured) without
    // overflowing.
    u.frame(400, 200, 1, App{ .sink = &sink, .obscure = true });
    var n = u.root.?;
    while (n.children.items.len > 0) n = n.children.items[0];
    try testing.expectEqualStrings("AXb", n.state(TextField.State).text());
    // Clicking elsewhere takes the keyboard away: keys go nowhere.
    u.pointerMotion(.{ 300, 150 });
    u.pointerButton(.{ 300, 150 }, .left, true);
    u.pointerButton(.{ 300, 150 }, .left, false);
    try testing.expect(u.focused == null);
    u.keyEvent(.a, true);
    try testing.expectEqualStrings("AXb", sink.text[0..sink.len]);
}

test "selecting, copying, cutting and pasting, with keys and the menu" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    try u.loadKeymap(@import("window").xkb.testdata.us);
    // The system's clipboard, as the app gives it.
    const Board = struct {
        text: [64]u8 = undefined,
        len: usize = 0,
        /// Pastes hold until `deliver` (as text from another app would).
        sink: ?@import("runtime.zig").Clipboard.Sink = null,
        pub fn copy(b: *@This(), t: []const u8) void {
            @memcpy(b.text[0..t.len], t);
            b.len = t.len;
        }
        pub fn paste(b: *@This(), sink: @import("runtime.zig").Clipboard.Sink) void {
            b.sink = sink;
        }
        fn deliver(b: *@This()) void {
            const sink = b.sink orelse return;
            b.sink = null;
            sink.f(sink.ctx, if (b.len == 0) null else b.text[0..b.len]);
        }
    };
    var board: Board = .{};
    u.clipboard = .of(&board);
    const Sink = struct {
        text: [64]u8 = undefined,
        len: usize = 0,
        fn changed(s: *@This(), t: []const u8) void {
            @memcpy(s.text[0..t.len], t);
            s.len = t.len;
        }
    };
    var sinks: [3]Sink = @splat(.{});
    // Three fields, one under another: "hello world", empty, and a
    // password.
    const App = struct {
        sinks: *[3]Sink,
        pub fn build(self: *const @This(), cx: *widget.BuildContext) widget.Widget {
            return cx.make(Padding{ .padding = .all(20), .child = cx.make(Column{ .cross_axis_alignment = .start, .spacing = 10, .children = cx.makeAll(.{
                TextField{ .initial = "hello world", .on_changed = .of(&self.sinks[0], Sink.changed) },
                TextField{ .on_changed = .of(&self.sinks[1], Sink.changed) },
                TextField{ .initial = "secret", .obscure = true, .on_changed = .of(&self.sinks[2], Sink.changed) },
            }) }) });
        }
    };
    var now: u64 = 0;
    const T = struct {
        fn frame(uu: *WindowUi, s: *[3]Sink, n: *u64) void {
            n.* += 16 * std.time.ns_per_ms;
            uu.frame(500, 400, n.*, App{ .sinks = s });
        }
        fn click(uu: *WindowUi, at: geometry.Point, button: widget.PointerButton) void {
            uu.pointerMotion(at);
            uu.pointerButton(at, button, true);
            uu.pointerButton(at, button, false);
        }
        fn keys(uu: *WindowUi, ctrl: bool, shift: bool, codes: []const widget.KeyboardKey) void {
            if (ctrl) uu.keyEvent(.left_ctrl, true);
            if (shift) uu.keyEvent(.left_shift, true);
            for (codes) |c| {
                uu.keyEvent(c, true);
                uu.keyEvent(c, false);
            }
            if (shift) uu.keyEvent(.left_shift, false);
            if (ctrl) uu.keyEvent(.left_ctrl, false);
        }
        fn field(uu: *WindowUi, i: usize) *TextField.State {
            var n = uu.root.?;
            while (!n.widget.is(Column)) n = n.children.items[0];
            return n.children.items[i].state(TextField.State);
        }
        fn findText(n: *Node, text: []const u8) ?*Node {
            if (n.widget.as(@import("text.zig").Text)) |t| if (std.mem.eql(u8, t.text, text)) return n;
            for (n.children.items) |ch| if (findText(ch, text)) |x| return x;
            return null;
        }
        fn middle(n: *Node) geometry.Point {
            const at = n.position();
            return .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
        }
    };
    T.frame(u, &sinks, &now);
    const rows = [3]f32{ 42, 96, 150 };

    // All of the first copied, and pasted into the second.
    T.click(u, .{ 60, rows[0] }, .left);
    T.keys(u, true, false, &.{ .a, .c });
    try testing.expectEqualStrings("hello world", board.text[0..board.len]);
    T.click(u, .{ 60, rows[1] }, .left);
    T.keys(u, true, false, &.{.v});
    // The text comes later (from another app, say): then it is pasted.
    try testing.expectEqual(@as(usize, 0), T.field(u, 1).len);
    board.deliver();
    try testing.expect(u.needs_frame);
    try testing.expectEqualStrings("hello world", sinks[1].text[0..sinks[1].len]);
    // Shift and Left select the last five characters; Ctrl+X cuts them.
    T.keys(u, false, true, &.{ .left, .left, .left, .left, .left });
    try testing.expectEqual([2]usize{ 6, 11 }, T.field(u, 1).selection().?);
    T.frame(u, &sinks, &now);
    T.keys(u, true, false, &.{.x});
    try testing.expectEqualStrings("hello ", sinks[1].text[0..sinks[1].len]);
    try testing.expectEqualStrings("world", board.text[0..board.len]);
    // Typing replaces a selection.
    T.keys(u, false, true, &.{.home});
    T.keys(u, false, false, &.{.b});
    try testing.expectEqualStrings("b", sinks[1].text[0..sinks[1].len]);

    // A password cannot be copied out.
    T.click(u, .{ 60, rows[2] }, .left);
    T.keys(u, true, false, &.{ .a, .c, .x });
    try testing.expectEqualStrings("world", board.text[0..board.len]);
    try testing.expectEqualStrings("secret", T.field(u, 2).text());

    // Dragging over the first field selects what it goes over.
    T.frame(u, &sinks, &now);
    u.pointerMotion(.{ 34, rows[0] });
    u.pointerButton(.{ 34, rows[0] }, .left, true);
    u.pointerMotion(.{ 200, rows[0] });
    u.pointerButton(.{ 200, rows[0] }, .left, false);
    const sel = T.field(u, 0).selection().?;
    try testing.expectEqual(@as(usize, 0), sel[0]);
    try testing.expect(sel[1] > 5);

    // The right button on the second field: a menu, with Cut and Copy
    // dimmed (nothing is selected), over the window. Paste in it pastes.
    T.frame(u, &sinks, &now);
    T.click(u, .{ 60, rows[1] }, .right);
    T.frame(u, &sinks, &now);
    const m = u.menu_root.?;
    try testing.expect(T.findText(m, "Copy") != null and T.findText(m, "Ctrl+V") != null);
    try testing.expect(!m.overflow.any());
    T.click(u, T.middle(T.findText(m, "Paste").?), .left);
    board.deliver();
    try testing.expect(u.menu == null);
    T.frame(u, &sinks, &now);
    try testing.expect(u.menu_root == null);
    try testing.expectEqualStrings("bworld", sinks[1].text[0..sinks[1].len]);

    // A press outside the menu closes it, and does nothing else; so does
    // Escape.
    T.click(u, .{ 60, rows[1] }, .right);
    T.frame(u, &sinks, &now);
    T.click(u, .{ 480, 380 }, .left);
    try testing.expect(u.menu == null);
    try testing.expect(u.focused != null);
    T.click(u, .{ 60, rows[1] }, .right);
    u.keyEvent(.escape, true);
    try testing.expect(u.menu == null);

    // Holding the left button down does not show it (the right button
    // does)...
    u.pointerMotion(.{ 60, rows[0] });
    u.pointerButton(.{ 60, rows[0] }, .left, true);
    for (0..40) |_| T.frame(u, &sinks, &now);
    try testing.expect(u.menu == null);
    u.pointerButton(.{ 60, rows[0] }, .left, false);
    // ...but holding a touch does, once it has been held for a while; it
    // coming up is not a tap.
    u.touchDown(1, .{ 60, rows[0] });
    T.frame(u, &sinks, &now);
    try testing.expect(u.needs_frame);
    for (0..40) |_| T.frame(u, &sinks, &now);
    try testing.expect(u.menu != null);
    u.touchUp(1);
    T.frame(u, &sinks, &now);
    try testing.expect(u.menu_root != null);
    // Select all, tapped in the menu.
    const item = T.middle(T.findText(u.menu_root.?, "Select all").?);
    u.touchDown(2, item);
    u.touchUp(2);
    try testing.expect(u.menu == null);
    try testing.expectEqual([2]usize{ 0, 11 }, T.field(u, 0).selection().?);
    // A touch that moves (with nothing to scroll) drags: it selects, and
    // shows no menu.
    T.frame(u, &sinks, &now);
    u.touchDown(3, .{ 34, rows[0] });
    T.frame(u, &sinks, &now);
    u.touchMotion(3, .{ 120, rows[0] });
    for (0..40) |_| T.frame(u, &sinks, &now);
    try testing.expect(u.menu == null);
    u.touchUp(3);
    try testing.expectEqual(@as(usize, 0), T.field(u, 0).selection().?[0]);
    try testing.expect(T.field(u, 0).selection().?[1] > 2);
}

test "without the system's clipboard, text is copied within the app" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const u = try WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    const Got = struct {
        text: [8]u8 = undefined,
        len: ?usize = null,
        fn got(g: *@This(), t: []const u8) void {
            @memcpy(g.text[0..t.len], t);
            g.len = t.len;
        }
    };
    const App = struct {
        pub fn build(_: *const @This(), cx: *widget.BuildContext) widget.Widget {
            return cx.make(TextField{});
        }
    };
    u.frame(200, 100, 0, App{});
    var g: Got = .{};
    // Nothing copied: nothing comes.
    u.pasteText(u.root.?, .of(&g, Got.got));
    try testing.expect(g.len == null);
    u.copyText("abc");
    u.pasteText(u.root.?, .of(&g, Got.got));
    try testing.expectEqualStrings("abc", g.text[0..g.len.?]);
}

test "a paste for a widget that has gone goes nowhere" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const u = try WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    const Never = struct {
        sink: ?@import("runtime.zig").Clipboard.Sink = null,
        pub fn copy(_: *@This(), _: []const u8) void {}
        pub fn paste(n: *@This(), sink: @import("runtime.zig").Clipboard.Sink) void {
            n.sink = sink;
        }
    };
    var board: Never = .{};
    u.clipboard = .of(&board);
    const App = struct {
        field: bool,
        pub fn build(self: *const @This(), cx: *widget.BuildContext) widget.Widget {
            return if (self.field) cx.make(TextField{}) else cx.make(Padding{ .padding = .all(1) });
        }
    };
    u.frame(200, 100, 0, App{ .field = true });
    u.root.?.children.items[0].state(TextField.State).paste();
    u.frame(200, 100, 1, App{ .field = false });
    try testing.expect(u.paste == null);
    // The text comes after all: nothing is done with it.
    board.sink.?.f(board.sink.?.ctx, "late");
}

test "a field asked for takes the keyboard by itself, once" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    try u.loadKeymap(@import("window").xkb.testdata.us);
    var text: [64]u8 = undefined;
    var len: usize = 0;
    const Sink = struct {
        text: *[64]u8,
        len: *usize,
        fn changed(s: *const @This(), t: []const u8) void {
            @memcpy(s.text[0..t.len], t);
            s.len.* = t.len;
        }
    };
    const sink: Sink = .{ .text = &text, .len = &len };
    const App = struct {
        sink: *const Sink,
        pub fn build(self: *const @This(), cx: *widget.BuildContext) widget.Widget {
            return cx.make(Padding{ .padding = .all(20), .child = cx.make(TextField{ .autofocus = true, .on_changed = .of(self.sink, Sink.changed) }) });
        }
    };
    u.frame(400, 200, 0, App{ .sink = &sink });
    try testing.expect(u.focused != null);
    // Typing goes into it, without a click.
    u.keyEvent(.a, true);
    u.keyEvent(.a, false);
    try testing.expectEqualStrings("a", text[0..len]);
    // Given up, it does not take the keyboard back.
    u.focus(null);
    u.frame(400, 200, 1, App{ .sink = &sink });
    try testing.expect(u.focused == null);
}

test "a UK keyboard types £ and €, and characters are edited whole" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    try u.loadKeymap(@import("window").xkb.testdata.gb_ru);
    var text: [64]u8 = undefined;
    var len: usize = 0;
    const Sink = struct {
        text: *[64]u8,
        len: *usize,
        fn changed(s: *const @This(), t: []const u8) void {
            @memcpy(s.text[0..t.len], t);
            s.len.* = t.len;
        }
    };
    const sink: Sink = .{ .text = &text, .len = &len };
    const App = struct {
        sink: *const Sink,
        pub fn build(self: *const @This(), cx: *widget.BuildContext) widget.Widget {
            return cx.make(Padding{ .padding = .all(20), .child = cx.make(TextField{ .autofocus = true, .on_changed = .of(self.sink, Sink.changed) }) });
        }
    };
    u.frame(400, 200, 0, App{ .sink = &sink });
    const press = struct {
        fn key(uu: *WindowUi, k: widget.KeyboardKey) void {
            uu.keyEvent(k, true);
            uu.keyEvent(k, false);
        }
    }.key;
    // Shift+3, AltGr+4, Shift+', #.
    u.keyEvent(.left_shift, true);
    press(u, .digit_3);
    u.keyEvent(.left_shift, false);
    u.keyEvent(.right_alt, true);
    press(u, .digit_4);
    u.keyEvent(.right_alt, false);
    u.keyEvent(.left_shift, true);
    press(u, .apostrophe);
    u.keyEvent(.left_shift, false);
    press(u, .backslash);
    try testing.expectEqualStrings("£€@#", text[0..len]);
    // Left over #, @ and €, then Backspace takes the £ whole.
    press(u, .left);
    press(u, .left);
    press(u, .left);
    press(u, .backspace);
    try testing.expectEqualStrings("€@#", text[0..len]);
    // Delete takes the € whole.
    press(u, .delete);
    try testing.expectEqualStrings("@#", text[0..len]);
    // A US keyboard types what the US has there.
    try u.loadKeymap(@import("window").xkb.testdata.us);
    u.keyEvent(.left_shift, true);
    press(u, .digit_3);
    u.keyEvent(.left_shift, false);
    try testing.expectEqualStrings("#@#", text[0..len]);
}

test "a password field has a visibility toggle button on the right hand side" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const App = struct {
        pub fn build(_: *const @This(), cx: *widget.BuildContext) widget.Widget {
            return cx.make(Padding{ .padding = .all(20), .child = cx.make(TextField{
                .initial = "secret",
                .obscure = true,
            }) });
        }
    };
    u.frame(400, 200, 0, App{});
    var field_node = u.root.?;
    while (field_node.children.items.len > 0) field_node = field_node.children.items[0];
    const tf = field_node.widget.as(TextField).?;
    const st = field_node.state(TextField.State);
    var buf: [TextField.capacity * TextField.dot.len]u8 = undefined;

    // Hidden by default: shows dots.
    try testing.expect(!st.revealed);
    try testing.expect(tf.isObscured(st));
    try testing.expectEqualStrings("••••••", tf.shown(st, &buf, st.text()));

    // Clicking the toggle button on the right-hand side reveals the password.
    const pos = field_node.position();
    const toggle_at: geometry.Point = .{ pos[0] + field_node.size.w - 20, pos[1] + field_node.size.h / 2 };
    u.pointerMotion(toggle_at);
    try testing.expect(st.toggle_hovered);
    u.pointerButton(toggle_at, .left, true);
    try testing.expect(st.toggle_pressed);
    u.pointerButton(toggle_at, .left, false);
    try testing.expect(!st.toggle_pressed);
    try testing.expect(st.revealed);
    try testing.expect(!tf.isObscured(st));
    try testing.expectEqualStrings("secret", tf.shown(st, &buf, st.text()));
    u.frame(400, 200, 1, App{});

    // While revealed, selecting and copying works.
    st.selectAll();
    st.copy();
    try testing.expectEqualStrings("secret", u.shared.local_clipboard.items);

    // Clicking the toggle button again hides the password back to dots, blocking copy.
    u.shared.local_clipboard.clearRetainingCapacity();
    u.pointerButton(toggle_at, .left, true);
    u.pointerButton(toggle_at, .left, false);
    try testing.expect(!st.revealed);
    try testing.expect(tf.isObscured(st));
    try testing.expectEqualStrings("••••••", tf.shown(st, &buf, st.text()));
    st.selectAll();
    st.copy();
    try testing.expectEqual(@as(usize, 0), u.shared.local_clipboard.items.len);
}

test "initial text and max_len never split a multi-byte UTF-8 character" {
    // "café" is 5 bytes ('c','a','f', 0xc3, 0xa9); max_len = 4 only fits "caf".
    const tf: TextField = .{ .initial = "café", .max_len = 4 };
    var st = tf.initState();
    try testing.expectEqualStrings("caf", st.text());
    try testing.expectEqual(@as(usize, 3), st.cursor);

    // 2, 3, and 4-byte UTF-8 sequences in initial text, with control chars normalized.
    const tf2: TextField = .{ .initial = "hé\t€\n🌍", .max_len = 32 };
    st = tf2.initState();
    try testing.expectEqualStrings("hé € 🌍", st.text());
    // Snapping mid-character byte offsets with moveTo.
    st.moveTo(2, false); // inside 'é' (bytes 1..3)
    try testing.expectEqual(@as(usize, 1), st.cursor);
    st.moveTo(6, true); // inside '€' (bytes 4..7)
    try testing.expectEqual(@as(usize, 4), st.cursor);
}

test "double click selects current word, triple click selects all, and selection is clipped to field bounds" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    const App = struct {
        pub fn build(_: *const @This(), cx: *widget.BuildContext) widget.Widget {
            return cx.make(Padding{
                .padding = .all(40),
                .child = cx.make(Column{
                    .cross_axis_alignment = .start,
                    .children = cx.makeAll(.{
                        TextField{
                            .initial = "https://github.com/robert-ancell/kete",
                            .width = 160,
                        },
                    }),
                }),
            });
        }
    };

    u.frame(300, 140, 100 * std.time.ns_per_ms, App{});
    var field_node = u.root.?;
    while (field_node.children.items.len > 0) field_node = field_node.children.items[0];
    const st = field_node.state(TextField.State);
    // Move to the start so "https://github.com" is at the left edge of the field.
    st.moveTo(0, false);
    u.frame(300, 140, 110 * std.time.ns_per_ms, App{});

    const pos = field_node.position();
    const click_at: geometry.Point = .{ pos[0] + TextField.pad + 10, pos[1] + field_node.size.h / 2 };

    // Single click places cursor without selecting.
    const ms = std.time.ns_per_ms;
    u.pointerMotion(click_at);
    u.pointerButtonAt(click_at, .left, true, 200 * ms);
    u.pointerButtonAt(click_at, .left, false, 210 * ms);
    try testing.expect(st.selection() == null);

    // Second click within WindowUi.multi_click_ns selects the word ("https").
    u.pointerButtonAt(click_at, .left, true, 300 * ms);
    u.pointerButtonAt(click_at, .left, false, 310 * ms);
    try testing.expectEqual([2]usize{ 0, 5 }, st.selection().?);

    // Third click within WindowUi.multi_click_ns selects all text.
    u.pointerButtonAt(click_at, .left, true, 400 * ms);
    u.pointerButtonAt(click_at, .left, false, 410 * ms);
    try testing.expectEqual([2]usize{ 0, st.len }, st.selection().?);

    // A fourth starts over, placing the cursor.
    u.pointerButtonAt(click_at, .left, true, 500 * ms);
    u.pointerButtonAt(click_at, .left, false, 510 * ms);
    try testing.expect(st.selection() == null);

    // A click long after the last is a single click, however stale the
    // frame's time is. (Back at the start: selecting everything scrolled
    // the field to its end.)
    st.moveTo(0, false);
    u.frame(300, 140, 600 * ms, App{});
    u.pointerButtonAt(click_at, .left, true, 2000 * ms);
    u.pointerButtonAt(click_at, .left, false, 2010 * ms);
    try testing.expect(st.selection() == null);
    u.pointerButtonAt(click_at, .left, true, 2100 * ms);
    u.pointerButtonAt(click_at, .left, false, 2110 * ms);
    try testing.expectEqual([2]usize{ 0, 5 }, st.selection().?);
    u.pointerButtonAt(click_at, .left, true, 2200 * ms);
    u.pointerButtonAt(click_at, .left, false, 2210 * ms);
    try testing.expectEqual([2]usize{ 0, st.len }, st.selection().?);

    // Render frame with full selection on overflowing text and verify no pixels
    // are drawn outside the TextField's horizontal bounds [40, 200).
    u.frame(300, 140, 410 * std.time.ns_per_ms, App{});
    const pixels = try testing.allocator.alloc(u32, 300 * 140);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0xff000000);
    const img: gfx.software.Image = .{ .pixels = pixels, .width = 300, .height = 140 };
    try u.preview(img);

    const mid_y: u32 = @intFromFloat(@round(pos[1] + field_node.size.h / 2));
    for (0..38) |x| {
        try testing.expectEqual(@as(u32, 0xff000000), img.at(@intCast(x), mid_y));
    }
    for (202..300) |x| {
        try testing.expectEqual(@as(u32, 0xff000000), img.at(@intCast(x), mid_y));
    }
}
