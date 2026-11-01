//! TextArea: many lines of text to edit, wrapped at the widget's width
//! (between words, or within a word too long for a line), scrolling with
//! the wheel or a finger and following the cursor. The text is the app's
//! (`Document`), so it can be any size and kept or saved as the app likes.
//!
//! Clicking puts the cursor there and dragging selects; the arrows, Home,
//! End, Page Up and Page Down move it (with Shift, selecting); Ctrl+Left
//! and Ctrl+Right move by word (with Shift, extending the selection), and
//! Ctrl+Backspace and Ctrl+Delete delete a word. Enter starts a line and
//! Tab types four spaces; Backspace and Delete take whole characters.
//! Ctrl+A selects everything, and Ctrl+X, Ctrl+C and Ctrl+V cut, copy and
//! paste (through the UI's clipboard), as the menu does (the right button,
//! or a touch held down).
//!
//! Code can be coloured: a `highlighter` says what each byte of the text
//! is (a keyword, a string, ...), and each is drawn in the theme's colour
//! for it.

const a11y = @import("accessibility.zig");
const std = @import("std");
const edit = @import("edit.zig");
const gfx = @import("gfx");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const menu = @import("menu.zig");
const SyntaxHighlight = @import("theme.zig").SyntaxHighlight;

const Node = widget.WidgetNode;
const Event = widget.Event;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;
const Point = geometry.Point;

/// The text being edited, with the cursor and selection: the app's, kept
/// as long as it is edited.
pub const Document = struct {
    /// What allocates its text.
    gpa: std.mem.Allocator,
    /// The text, as UTF-8.
    bytes: std.ArrayList(u8) = .empty,
    /// Where typing goes (a byte index).
    cursor: usize = 0,
    /// The other end of the selection (a byte index), if there is one.
    anchor: ?usize = null,
    /// Counts the changes to the text (the app saves when it changes).
    version: u64 = 0,

    /// A document holding a copy of `initial`, with the cursor at the start.
    pub fn init(gpa: std.mem.Allocator, initial: []const u8) !Document {
        var d: Document = .{ .gpa = gpa };
        try d.bytes.ensureTotalCapacity(gpa, initial.len);
        d.insert(initial);
        d.cursor = 0;
        d.version = 0;
        return d;
    }

    /// Frees its text.
    pub fn deinit(d: *Document) void {
        d.bytes.deinit(d.gpa);
    }

    /// The text.
    pub fn text(d: *const Document) []const u8 {
        return d.bytes.items;
    }

    /// The selected bytes' start and end, if any are.
    pub fn selection(d: *const Document) ?[2]usize {
        const a = d.anchor orelse return null;
        if (a == d.cursor) return null;
        return .{ @min(a, d.cursor), @max(a, d.cursor) };
    }

    /// Selects all of the text.
    pub fn selectAll(d: *Document) void {
        d.anchor = 0;
        d.cursor = d.bytes.items.len;
    }

    /// Selects the word around the byte at `index`.
    pub fn selectWordAt(d: *Document, index: usize) void {
        const t = d.bytes.items;
        if (t.len == 0) {
            d.anchor = null;
            d.cursor = 0;
            return;
        }
        var pivot = d.snap(@min(index, t.len));
        if (pivot == t.len) {
            pivot = d.before(t.len);
        } else if (pivot > 0 and charClassAt(t, pivot) != .word) {
            const prev = d.before(pivot);
            if (charClassAt(t, prev) == .word) pivot = prev;
        }
        const cls = charClassAt(t, pivot);
        var start = pivot;
        while (start > 0) {
            const prev = d.before(start);
            if (charClassAt(t, prev) != cls) break;
            start = prev;
        }
        var end = d.after(pivot);
        while (end < t.len) {
            if (charClassAt(t, end) != cls) break;
            end = d.after(end);
        }
        d.anchor = start;
        d.cursor = end;
    }

    /// Moves the cursor, extending the selection or dropping it.
    pub fn moveTo(d: *Document, to: usize, extend: bool) void {
        if (extend) {
            if (d.anchor == null) d.anchor = d.cursor;
        } else d.anchor = null;
        d.cursor = d.snap(to);
    }

    fn remove(d: *Document, from: usize, to: usize) void {
        if (to <= from) return;
        d.bytes.replaceRangeAssumeCapacity(from, to - from, &.{});
        d.version += 1;
    }

    /// Removes the selection's text. Returns whether there was any.
    pub fn deleteSelection(d: *Document) bool {
        const sel = d.selection() orelse return false;
        d.remove(sel[0], sel[1]);
        d.cursor = sel[0];
        d.anchor = null;
        return true;
    }

    /// Deletes `before_len` bytes before the cursor and `after_len` bytes
    /// after it (`zwp_text_input_v3.delete_surrounding_text`).
    pub fn deleteSurrounding(d: *Document, before_len: u32, after_len: u32) bool {
        _ = d.deleteSelection();
        const from = d.snap(d.cursor -| @min(@as(usize, before_len), d.cursor));
        const to = d.snap(@min(d.bytes.items.len, d.cursor + @as(usize, after_len)));
        if (to <= from) return false;
        d.remove(from, to);
        d.cursor = from;
        return true;
    }

    /// Puts `t` (UTF-8) at the cursor, over the selection: its characters
    /// but control ones (tabs as four spaces, "\r\n" as "\n").
    pub fn insert(d: *Document, t: []const u8) void {
        _ = d.deleteSelection();
        var at: usize = 0;
        while (at < t.len) {
            const n = std.unicode.utf8ByteSequenceLength(t[at]) catch {
                at += 1;
                continue;
            };
            if (at + n > t.len) break;
            const c = std.unicode.utf8Decode(t[at..][0..n]) catch {
                at += 1;
                continue;
            };
            const piece = t[at .. at + n];
            at += n;
            const out: []const u8 = switch (c) {
                '\n' => "\n",
                '\t' => "    ",
                0...0x08, 0x0a + 1...0x1f, 0x7f...0x9f => continue,
                else => piece,
            };
            d.bytes.insertSlice(d.gpa, d.cursor, out) catch return;
            d.cursor += out.len;
            d.version += 1;
        }
    }

    /// The character boundary at or before byte `i`.
    pub fn snap(d: *const Document, i: usize) usize {
        if (i >= d.bytes.items.len) return d.bytes.items.len;
        var j = i;
        while (j > 0 and d.bytes.items[j] & 0xc0 == 0x80) j -= 1;
        return j;
    }

    /// The character boundary before byte `i` (0 at the start).
    pub fn before(d: *const Document, i: usize) usize {
        var j = @min(i, d.bytes.items.len) -| 1;
        while (j > 0 and d.bytes.items[j] & 0xc0 == 0x80) j -= 1;
        return j;
    }

    /// The character boundary after byte `i` (the end at the end).
    pub fn after(d: *const Document, i: usize) usize {
        const t = d.bytes.items;
        if (i >= t.len) return t.len;
        var j = i + 1;
        while (j < t.len and t[j] & 0xc0 == 0x80) j += 1;
        return j;
    }
};

/// A line as shown: bytes `start` to `end` of the text (a wrapped line's
/// end is where the next starts; a line's newline is not in it).
const Line = struct { start: usize, end: usize };

/// Several lines of text to edit, wrapped to its width and scrolled, with a
/// selection, copy and paste and, optionally, colours (see `highlighter`).
///
/// ![The TextArea example](images/TextArea.png)
///
/// ```zig
/// return cx.make(kete.SizedBox{ .width = 320, .height = 96, .child = cx.make(kete.TextArea{ .doc = &document }) });
/// ```
pub const TextArea = struct {
    /// The text being edited (the app's: it is kept as long as it is edited).
    doc: *Document,
    /// Text size; the theme's body size if null.
    size: ?f32 = null,
    /// The text changed (by typing, cutting or pasting).
    on_changed: ?widget.Callback = null,
    /// Take the keyboard when it first appears.
    autofocus: bool = false,
    /// Says what each byte of the text is, for its colour (`out` is as long
    /// as the text, and all `plain` to start with).
    highlighter: ?Highlighter = null,

    /// What a part of the text is, for its colour: `keyword`, `string`,
    /// `comment` and so on, or `plain`.
    pub const Highlight = SyntaxHighlight;
    /// Says what each byte of `text` is, writing it to `out` (as long as `text`).
    pub const Highlighter = *const fn (text: []const u8, out: []Highlight) void;

    pub const pad = 12;

    pub const State = struct {
        gpa: ?std.mem.Allocator = null,
        /// How far down it is scrolled, in pixels.
        scroll: f32 = 0,
        focused: bool = false,
        autofocused: bool = false,
        dragging: bool = false,
        /// Bring the cursor into view at the next layout.
        reveal: bool = true,
        /// Where up and down aim for (from where they started).
        goal_x: ?f32 = null,
        /// The wrapped lines, for the text's version and the width.
        lines: std.ArrayList(Line) = .empty,
        lines_version: u64 = std.math.maxInt(u64),
        lines_width: f32 = -1,
        lines_doc: ?*Document = null,
        /// What each byte is, for the text's version (if highlighted).
        colours: std.ArrayList(SyntaxHighlight) = .empty,
        colours_version: u64 = std.math.maxInt(u64),
        colours_doc: ?*Document = null,
        colours_by: ?Highlighter = null,
        /// What the menu's actions need, from the widget as last seen.
        doc: ?*Document = null,
        node: ?*Node = null,
        on_changed: ?widget.Callback = null,
        preedit_buf: [128]u8 = undefined,
        preedit_len: usize = 0,
        last_change_other: bool = false,

        pub fn deinit(s: *State) void {
            if (s.gpa) |g| {
                s.lines.deinit(g);
                s.colours.deinit(g);
            }
        }

        fn changed(s: *State) void {
            s.reveal = true;
            if (s.on_changed) |f| f.call();
            if (s.node) |n| n.ui.needs_frame = true;
        }

        pub fn cut(s: *State) void {
            const d = s.doc orelse return;
            s.copy();
            if (d.deleteSelection()) s.changed();
        }

        pub fn copy(s: *State) void {
            const d = s.doc orelse return;
            const sel = d.selection() orelse return;
            if (s.node) |n| n.ui.copyText(d.text()[sel[0]..sel[1]]);
        }

        pub fn paste(s: *State) void {
            const n = s.node orelse return;
            n.ui.pasteText(n, .of(s, State.pasted));
        }

        fn pasted(s: *State, t: []const u8) void {
            const d = s.doc orelse return;
            s.last_change_other = true;
            d.insert(t);
            s.changed();
        }

        pub fn selectAll(s: *State) void {
            const d = s.doc orelse return;
            d.selectAll();
            if (s.node) |n| n.ui.needs_frame = true;
        }
    };

    fn style(self: *const TextArea, n: *const Node) ?font.Style {
        const f = n.ui.font orelse return null;
        return .{ .font = f, .size = self.size orelse n.theme().body_size };
    }

    fn remember(self: *const TextArea, n: *Node) *State {
        const st = n.state(State);
        st.gpa = n.ui.gpa;
        st.doc = self.doc;
        st.node = n;
        st.on_changed = self.on_changed;
        return st;
    }

    pub fn cursor(_: *const TextArea, _: *Node, _: Point) ?widget.PointerCursor {
        return .text;
    }

    /// What the input method is told of it while it has the keyboard: the text
    /// around the cursor and where the cursor is.
    pub fn textInput(self: *const TextArea, n: *Node) ?widget.TextInputInfo {
        const st = n.state(State);
        const d = self.doc;
        const t = d.text();
        var cx_px: i32 = pad;
        var cy_px: i32 = pad;
        var ch_px: i32 = 20;
        if (self.style(n)) |s| {
            const lh = s.lineHeight();
            ch_px = @max(1, @as(i32, @intFromFloat(@round(lh))));
            const lines = st.lines.items;
            const li = lineOf(lines, d.cursor);
            if (li < lines.len or lines.len == 0) {
                const l = if (lines.len == 0) Line{ .start = 0, .end = 0 } else lines[li];
                const x = pad + font.measure(s, t[l.start..@min(d.cursor, l.end)]);
                const top = pad + @as(f32, @floatFromInt(li)) * lh - st.scroll;
                cx_px = @intFromFloat(@round(x));
                cy_px = @intFromFloat(@round(top));
            }
        }
        const window_start = d.snap(d.cursor -| 128);
        const window_end = d.snap(@min(t.len, window_start + 256));
        const cur: u32 = @intCast(d.cursor - window_start);
        const anc_abs = d.anchor orelse d.cursor;
        const anc: u32 = @intCast(std.math.clamp(anc_abs, window_start, window_end) - window_start);
        return .{
            .surrounding_text = t[window_start..window_end],
            .cursor = cur,
            .anchor = anc,
            .cursor_rect = .{ cx_px, cy_px, 2, ch_px },
            .password = false,
            .multiline = true,
            .change_cause_other = st.last_change_other,
        };
    }

    /// Tab types a tab: Control and Tab moves the focus on.
    pub const takes_tab = true;

    pub fn focusable(_: *const TextArea, _: *Node) bool {
        return true;
    }

    pub fn accessible(self: *const TextArea, _: *Node) ?a11y.Info {
        const doc = self.doc.text();
        return .{
            .role = .textbox,
            .multiline = true,
            .text = doc,
            .caret = std.unicode.utf8CountCodepoints(doc[0..@min(self.doc.cursor, doc.len)]) catch null,
        };
    }

    pub fn layout(self: *const TextArea, n: *Node, c: Constraints) Size {
        const st = self.remember(n);
        if (self.autofocus and !st.autofocused) {
            st.autofocused = true;
            n.ui.focus(n);
        }
        const size = c.constrain(.{ .w = if (c.boundedWidth()) c.max_w else 480, .h = if (c.boundedHeight()) c.max_h else 320 });
        self.wrap(n, size.w);
        // Kept in range, and following the cursor.
        if (self.style(n)) |s| {
            const lh = s.lineHeight();
            const content = @as(f32, @floatFromInt(st.lines.items.len)) * lh + 2 * pad;
            if (st.reveal) {
                st.reveal = false;
                const y = @as(f32, @floatFromInt(lineOf(st.lines.items, self.doc.cursor))) * lh;
                if (y < st.scroll) st.scroll = y;
                if (y + lh + 2 * pad > st.scroll + size.h) st.scroll = y + lh + 2 * pad - size.h;
            }
            st.scroll = std.math.clamp(st.scroll, 0, @max(0, content - size.h));
        }
        return size;
    }

    pub fn minSize(self: *const TextArea, n: *Node, c: Constraints) Size {
        const lh = if (self.style(n)) |s| s.lineHeight() else 20;
        return c.constrain(.{ .w = 200, .h = @ceil(lh * 3 + 2 * pad) });
    }

    /// Wraps the text at `width` (again only if it or the text changed).
    fn wrap(self: *const TextArea, n: *Node, width: f32) void {
        const st = n.state(State);
        const d = self.doc;
        if (st.lines_doc == d and st.lines_version == d.version and st.lines_width == width) return;
        st.lines_doc = d;
        st.lines_version = d.version;
        st.lines_width = width;
        st.lines.clearRetainingCapacity();
        const s = self.style(n) orelse return;
        wrapText(n.ui.gpa, &st.lines, s, d.text(), width - 2 * pad);
    }

    /// What each byte of the text is (again only if it changed), or null
    /// if it is not highlighted.
    fn highlight(self: *const TextArea, n: *Node) ?[]const SyntaxHighlight {
        const h = self.highlighter orelse return null;
        const st = n.state(State);
        const d = self.doc;
        if (st.colours_doc != d or st.colours_version != d.version or st.colours_by != h) {
            st.colours_doc = d;
            st.colours_version = d.version;
            st.colours_by = h;
            st.colours.resize(n.ui.gpa, d.text().len) catch {
                st.colours_doc = null;
                return null;
            };
            @memset(st.colours.items, .plain);
            h(d.text(), st.colours.items);
        }
        return st.colours.items;
    }

    pub fn paint(self: *const TextArea, n: *Node, p: *Painter) void {
        const t = n.theme();
        const st = n.state(State);
        const c = p.canvas();
        const r: gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };
        if (st.focused) c.strokeRoundedRect(r.outset(-1), .all(4), 2, t.primary) else c.strokeRoundedRect(r.outset(-0.5), .all(4), 1, t.outline);
        const s = self.style(n) orelse return;
        const lh = s.lineHeight();
        const old = p.clipTo(.{ .x = 1, .y = 1, .w = n.size.w - 2, .h = n.size.h - 2 });
        defer p.restoreClip(old);
        const d = self.doc;
        const text = d.text();
        const lines = st.lines.items;
        const first: usize = @intFromFloat(@max(0, @floor((st.scroll - pad) / lh)));
        const sel = d.selection();
        const colours = self.highlight(n);
        var i = first;
        while (i < lines.len) : (i += 1) {
            const top = pad + @as(f32, @floatFromInt(i)) * lh - st.scroll;
            if (top > n.size.h) break;
            const l = lines[i];
            const baseline = top + s.ascent();
            if (sel) |range| if (range[0] <= l.end and range[1] >= l.start and range[0] != range[1]) {
                const a = @max(range[0], l.start);
                const b = @min(range[1], l.end);
                const x0 = font.measure(s, text[l.start..a]);
                // A selected newline shows as a little more.
                const x1 = font.measure(s, text[l.start..b]) + @as(f32, if (range[1] > l.end) s.size * 0.3 else 0);
                c.fillRect(.{ .x = pad + x0, .y = top, .w = x1 - x0, .h = lh }, t.primary.withAlpha(if (st.focused) 0.35 else 0.15));
            };
            const cs = colours orelse {
                _ = p.text(s.size, pad, baseline, text[l.start..l.end], t.on_surface);
                continue;
            };
            // In runs of one colour.
            var x: f32 = pad;
            var at = l.start;
            while (at < l.end) {
                var end = @min(d.after(at), l.end);
                while (end < l.end and cs[end] == cs[at]) end = @min(d.after(end), l.end);
                x = p.text(s.size, x, baseline, text[at..end], t.syntax.color(cs[at], t.on_surface));
                at = end;
            }
        }
        if (st.focused and sel == null) {
            const li = lineOf(lines, d.cursor);
            if (li < lines.len or lines.len == 0) {
                const l = if (lines.len == 0) Line{ .start = 0, .end = 0 } else lines[li];
                const x = pad + font.measure(s, text[l.start..@min(d.cursor, l.end)]);
                const top = pad + @as(f32, @floatFromInt(li)) * lh - st.scroll;
                if (st.preedit_len > 0) {
                    const pre = st.preedit_buf[0..st.preedit_len];
                    const pre_w = font.measure(s, pre);
                    const baseline = top + s.ascent();
                    c.fillRect(.{ .x = @round(x), .y = baseline + 1, .w = pre_w, .h = 1 }, t.primary);
                    _ = p.text(s.size, @round(x), baseline, pre, t.primary);
                } else {
                    c.fillRect(.{ .x = @round(x), .y = top, .w = 2, .h = lh }, t.primary);
                }
            }
        }
    }

    pub fn event(self: *const TextArea, n: *Node, e: Event) bool {
        const st = self.remember(n);
        const d = self.doc;
        switch (e) {
            .press => |pr| {
                if (pr.button != .left) return false;
                n.ui.focus(n);
                // A click places the cursor, a double click selects a word,
                // and a triple click everything; a fourth starts over.
                switch ((@max(pr.clicks, 1) - 1) % 3 + 1) {
                    1 => {
                        d.moveTo(self.offsetAt(n, pr.pos), false);
                        d.anchor = d.cursor;
                        st.dragging = true;
                    },
                    2 => {
                        d.selectWordAt(self.offsetAt(n, pr.pos));
                        st.dragging = false;
                    },
                    else => {
                        d.selectAll();
                        st.dragging = false;
                    },
                }
                st.goal_x = null;
                st.last_change_other = true;
                n.ui.needs_frame = true;
                return true;
            },
            .motion => |pos| if (st.dragging) {
                d.cursor = self.offsetAt(n, pos);
                st.reveal = true;
                st.last_change_other = true;
                n.ui.needs_frame = true;
            },
            .release => {
                st.dragging = false;
                if (d.selection() == null) d.anchor = null;
                return true;
            },
            .scroll => |sc| {
                st.scroll += sc.dy;
                n.ui.needs_frame = true;
                return true;
            },
            .focus => st.focused = true,
            .blur => {
                st.focused = false;
                st.preedit_len = 0;
            },
            .key => |k| {
                if (!k.pressed) return true;
                st.last_change_other = true;
                if (self.key(n, st, k)) st.changed() else n.ui.needs_frame = true;
                return true;
            },
            .text_commit => |t| {
                st.preedit_len = 0;
                st.last_change_other = false;
                d.insert(t);
                st.changed();
                return true;
            },
            .text_delete_surrounding => |del| {
                st.last_change_other = false;
                if (d.deleteSurrounding(del.before_length, del.after_length)) st.changed();
                return true;
            },
            .text_preedit => |pre| {
                const len = @min(pre.text.len, st.preedit_buf.len);
                @memcpy(st.preedit_buf[0..len], pre.text[0..len]);
                st.preedit_len = len;
                n.ui.needs_frame = true;
                return true;
            },
            .context => |pos| {
                n.ui.focus(n);
                st.dragging = false;
                const at = self.offsetAt(n, pos);
                const inside = if (d.selection()) |sel| at >= sel[0] and at <= sel[1] else false;
                if (!inside) d.moveTo(at, false);
                const can_copy = d.selection() != null;
                const origin = n.position();
                n.ui.openMenu(n, .{ origin[0] + pos[0], origin[1] + pos[1] }, &.{
                    .{ .label = "Cut", .shortcut = "Ctrl+X", .enabled = can_copy, .on_press = .of(st, State.cut) },
                    .{ .label = "Copy", .shortcut = "Ctrl+C", .enabled = can_copy, .on_press = .of(st, State.copy) },
                    .{ .label = "Paste", .shortcut = "Ctrl+V", .on_press = .of(st, State.paste) },
                    .{ .label = "Select all", .shortcut = "Ctrl+A", .enabled = d.text().len > 0, .on_press = .of(st, State.selectAll) },
                });
                return true;
            },
            else => {},
        }
        return false;
    }

    /// Edits or moves for a key; returns whether the text changed.
    fn key(self: *const TextArea, n: *Node, st: *State, k: Event.Key) bool {
        const d = self.doc;
        st.reveal = true;
        if (k.ctrl) {
            switch (k.key) {
                .a => d.selectAll(),
                .c => st.copy(),
                .x => if (d.selection() != null) {
                    st.copy();
                    return d.deleteSelection();
                },
                // The text comes later (see `State.pasted`).
                .v => st.paste(),
                .home => d.moveTo(0, k.shift),
                .end => d.moveTo(d.text().len, k.shift),
                // Word movement: Ctrl+Left/Right move by word; Shift extends
                // the selection. Ctrl+Backspace/Delete delete a whole word.
                .left => d.moveTo(edit.wordBefore(d.text(), d.cursor), k.shift),
                .right => d.moveTo(edit.wordAfter(d.text(), d.cursor), k.shift),
                .backspace => {
                    if (d.deleteSelection()) return true;
                    const from = edit.wordBefore(d.text(), d.cursor);
                    if (from == d.cursor) return false;
                    d.remove(from, d.cursor);
                    d.cursor = from;
                    return true;
                },
                .delete => {
                    if (d.deleteSelection()) return true;
                    const to = edit.wordAfter(d.text(), d.cursor);
                    if (to == d.cursor) return false;
                    d.remove(d.cursor, to);
                    return true;
                },
                else => {},
            }
            return false;
        }
        const vertical = k.key == .up or k.key == .down or k.key == .page_up or k.key == .page_down;
        if (!vertical) st.goal_x = null;
        switch (k.key) {
            .backspace => {
                if (d.deleteSelection()) return true;
                if (d.cursor == 0) return false;
                const from = d.before(d.cursor);
                d.remove(from, d.cursor);
                d.cursor = from;
                return true;
            },
            .delete => {
                if (d.deleteSelection()) return true;
                if (d.cursor == d.text().len) return false;
                d.remove(d.cursor, d.after(d.cursor));
                return true;
            },
            .enter, .keypad_enter => {
                d.insert("\n");
                return true;
            },
            .tab => {
                d.insert("\t");
                return true;
            },
            // Without Shift, a selection collapses to its start or end.
            .left => if (!k.shift and d.selection() != null) d.moveTo(d.selection().?[0], false) else d.moveTo(d.before(d.cursor), k.shift),
            .right => if (!k.shift and d.selection() != null) d.moveTo(d.selection().?[1], false) else d.moveTo(d.after(d.cursor), k.shift),
            .home, .end => {
                const lines = st.lines.items;
                if (lines.len > 0) {
                    const l = lines[lineOf(lines, d.cursor)];
                    d.moveTo(if (k.key == .home) l.start else l.end, k.shift);
                }
            },
            .up, .down, .page_up, .page_down => {
                const s = self.style(n) orelse return false;
                const lines = st.lines.items;
                if (lines.len == 0) return false;
                const li = lineOf(lines, d.cursor);
                const l = lines[li];
                const x = st.goal_x orelse font.measure(s, d.text()[l.start..d.cursor]);
                st.goal_x = x;
                const page: usize = @max(1, @as(usize, @intFromFloat(@max(0, (n.size.h - 2 * pad) / s.lineHeight()))) -| 1);
                const target: usize = switch (k.key) {
                    .up => if (li == 0) return d.moveTo(0, k.shift) != {} and false else li - 1,
                    .down => if (li + 1 >= lines.len) return d.moveTo(d.text().len, k.shift) != {} and false else li + 1,
                    .page_up => li -| page,
                    else => @min(li + page, lines.len - 1),
                };
                d.moveTo(self.offsetInLine(s, lines[target], x), k.shift);
            },
            else => if (k.char) |c| {
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &enc) catch return false;
                d.insert(enc[0..len]);
                return true;
            },
        }
        return false;
    }

    /// The byte offset nearest `pos` (in the widget).
    fn offsetAt(self: *const TextArea, n: *Node, pos: Point) usize {
        const st = n.state(State);
        const s = self.style(n) orelse return 0;
        const lines = st.lines.items;
        if (lines.len == 0) return 0;
        const row = @as(isize, @intFromFloat(@floor((pos[1] + st.scroll - pad) / s.lineHeight())));
        const li: usize = @intCast(std.math.clamp(row, 0, @as(isize, @intCast(lines.len - 1))));
        return self.offsetInLine(s, lines[li], pos[0] - pad);
    }

    /// The character boundary in `l` nearest `x`.
    /// Uses a single forward Layout pass accumulating advance widths (O(N)).
    fn offsetInLine(self: *const TextArea, s: font.Style, l: Line, x: f32) usize {
        const text = self.doc.text();
        var best = l.start;
        var best_d = @abs(x);
        var lay = font.Layout.init(s, text[l.start..l.end], 0);
        while (lay.next()) |_| {
            // `lay.at` is the byte index into the slice text[l.start..l.end]
            // after consuming the current codepoint, so l.start + lay.at is
            // the byte boundary in the document text just after this glyph.
            const boundary = l.start + lay.at;
            const dist = @abs(lay.x - x);
            if (dist < best_d) {
                best = boundary;
                best_d = dist;
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

/// The line (an index) the cursor at `offset` is on: at a wrap, the line
/// after.
fn lineOf(lines: []const Line, offset: usize) usize {
    if (lines.len == 0) return 0;
    var lo: usize = 0;
    var hi: usize = lines.len;
    // The last line starting at or before it.
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (lines[mid].start <= offset) lo = mid else hi = mid;
    }
    return lo;
}

/// Wraps `text` into lines of at most `width` (between words, or within a
/// word too long for a line).
fn wrapText(gpa: std.mem.Allocator, out: *std.ArrayList(Line), s: font.Style, text: []const u8, width: f32) void {
    var start: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        wrapLine(gpa, out, s, text, start, nl, width);
        if (nl == text.len) return;
        start = nl + 1;
    }
}

fn wrapLine(gpa: std.mem.Allocator, out: *std.ArrayList(Line), s: font.Style, text: []const u8, from: usize, to: usize, width: f32) void {
    var start = from;
    while (start <= to) {
        // Single forward pass: walk every glyph once, tracking the last space
        // break that still fits and the last character boundary that fits.
        var lay = font.Layout.init(s, text[start..to], 0);
        var brk: ?usize = null; // byte boundary after the last fitting space
        var fit: usize = start; // last character boundary whose cumulative width <= width
        var fits_all = true;
        while (lay.next()) |item| {
            // item.x  = pen x *before* this glyph's advance (cumulative width so far)
            // lay.x   = pen x *after*  this glyph's advance
            // lay.at  = byte offset into text[start..to] just after this glyph
            const boundary = start + lay.at;
            // Original logic: for a space at byte i, record brk=i+1 iff
            //   measure(text[start..i]) <= width, i.e. the text up to (not
            //   including) the space fits. That equals item.x <= width.
            if (text[start + lay.at - 1] == ' ' and item.x <= width) {
                brk = boundary;
            }
            if (lay.x > width) {
                fits_all = false;
                break;
            }
            fit = boundary;
        }
        if (fits_all) {
            out.append(gpa, .{ .start = start, .end = to }) catch return;
            return;
        }
        const end: usize = brk orelse (if (fit > start) fit else start + (std.unicode.utf8ByteSequenceLength(text[start]) catch 1));
        out.append(gpa, .{ .start = start, .end = end }) catch return;
        start = end;
    }
}

// --- Tests ---------------------------------------------------------------------

const testing = std.testing;
const Padding = @import("padding.zig").Padding;

test "a document: typing, selecting and deleting whole characters" {
    var d = try Document.init(testing.allocator, "héllo");
    defer d.deinit();
    d.moveTo(3, false);
    try testing.expectEqual(@as(usize, 1), d.before(3));
    try testing.expectEqual(@as(usize, 6), d.after(3) + 2);
    d.insert("\tx\r\ny\x07");
    try testing.expectEqualStrings("hé    x\nyllo", d.text());
    d.moveTo(0, false);
    d.moveTo(3, true);
    d.insert("H");
    try testing.expectEqualStrings("H    x\nyllo", d.text());
    try testing.expect(d.version > 0);
}

test "a document: init normalizes UTF-8 and moveTo snaps to character boundaries" {
    var d = try Document.init(testing.allocator, "café\r\n\t—🌍\xff");
    defer d.deinit();
    try testing.expectEqual(@as(usize, 0), d.cursor);
    try testing.expectEqual(@as(u64, 0), d.version);
    try testing.expectEqualStrings("café\n    —🌍", d.text());
    // "caf" is 3 bytes, "é" is bytes 3..5; moving to byte 4 snaps back to byte 3.
    d.moveTo(4, false);
    try testing.expectEqual(@as(usize, 3), d.cursor);
    try testing.expectEqual(@as(usize, 5), d.after(d.cursor));
    // "—" is 3 bytes (10..13), "🌍" is 4 bytes (13..17); moving to byte 15 snaps to 13.
    d.moveTo(15, true);
    try testing.expectEqual(@as(usize, 13), d.cursor);
    try testing.expectEqual([2]usize{ 3, 13 }, d.selection().?);
    _ = d.deleteSelection();
    try testing.expectEqualStrings("caf🌍", d.text());
}

test "lines wrap between words, or within one too long" {
    const f = try font.Font.init(font.default_font_data);
    const s: font.Style = .{ .font = &f, .size = 16 };
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(testing.allocator);
    const text = "the quick brown fox\n\nsupercalifragilistic";
    wrapText(testing.allocator, &lines, s, text, font.measure(s, "the quick brown"));
    // "the quick brown ", "fox", "", then the long word in pieces.
    try testing.expectEqualStrings("the quick brown ", text[lines.items[0].start..lines.items[0].end]);
    try testing.expectEqualStrings("fox", text[lines.items[1].start..lines.items[1].end]);
    try testing.expectEqual(lines.items[2].start, lines.items[2].end);
    try testing.expect(lines.items.len > 4);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (lines.items[3..]) |l| try joined.appendSlice(testing.allocator, text[l.start..l.end]);
    try testing.expectEqualStrings("supercalifragilistic", joined.items);
    // A word too long for a line, in pieces.
    lines.clearRetainingCapacity();
    wrapText(testing.allocator, &lines, s, "supercalifragilistic", font.measure(s, "super"));
    try testing.expect(lines.items.len >= 4);
    for (lines.items[0 .. lines.items.len - 1], lines.items[1..]) |a, b| try testing.expectEqual(a.end, b.start);
    try testing.expectEqual(@as(usize, 20), lines.items[lines.items.len - 1].end);
    lines.clearRetainingCapacity();
    wrapText(testing.allocator, &lines, s, text, font.measure(s, "the quick brown"));
    // The cursor at a wrap is on the next line.
    try testing.expectEqual(@as(usize, 1), lineOf(lines.items, lines.items[1].start));
    try testing.expectEqual(@as(usize, 0), lineOf(lines.items, 3));
}

test "typing into a text area, moving up and down, and copying" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    try u.loadKeymap(@import("window").xkb.testdata.us);
    var d = try Document.init(testing.allocator, "first line\nsecond line");
    defer d.deinit();
    const App = struct {
        doc: *Document,
        pub fn build(self: *const @This(), cx: *widget.BuildContext) widget.Widget {
            return cx.make(Padding{ .padding = .all(10), .child = cx.make(TextArea{ .doc = self.doc, .autofocus = true }) });
        }
    };
    u.frame(500, 300, 0, App{ .doc = &d });
    const press = struct {
        fn key(uu: *WindowUi, k: widget.KeyboardKey) void {
            uu.keyEvent(k, true);
            uu.keyEvent(k, false);
        }
    }.key;
    // At the start; down, then End: the end of the second line.
    press(u, .down);
    u.frame(500, 300, 1, App{ .doc = &d });
    try testing.expectEqual(@as(usize, 11), d.cursor);
    press(u, .end);
    try testing.expectEqual(d.text().len, d.cursor);
    press(u, .enter);
    press(u, .a);
    try testing.expectEqualStrings("first line\nsecond line\na", d.text());
    // Up twice: the first line; Shift+End selects it, and Ctrl+C copies.
    u.frame(500, 300, 2, App{ .doc = &d });
    press(u, .up);
    press(u, .up);
    press(u, .home);
    u.keyEvent(.left_shift, true);
    press(u, .end);
    u.keyEvent(.left_shift, false);
    u.keyEvent(.left_ctrl, true);
    press(u, .c);
    u.keyEvent(.left_ctrl, false);
    try testing.expectEqualStrings("first line", u.shared.local_clipboard.items);
    press(u, .backspace);
    try testing.expectEqualStrings("\nsecond line\na", d.text());
}
