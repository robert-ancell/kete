//! Text: lines broken at `\n`, and wrapped at spaces to fit the width. A
//! word wider than the space it has overflows (and is marked).

const a11y = @import("accessibility.zig");
const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Node = widget.WidgetNode;
const Painter = painter_mod.Painter;

/// How a `Text` is drawn.
pub const TextStyle = struct {
    /// Pixels per em (the theme's body size if not given).
    size: ?f32 = null,
    /// The theme's text colour if not given.
    color: ?gfx.Color = null,
    /// The UI's font if not given (another must last as long as the text
    /// is shown).
    font: ?*const font.Font = null,
};

/// Where each line of a `Text` sits in the width it has.
pub const TextAlign = enum {
    /// At the start of the width (the left).
    start,
    /// In the middle of it.
    center,
    /// At the end of it (the right).
    end,
};

pub const Line = struct {
    text: []const u8,
    width: f32,
};

/// Text: lines of it, in the theme's text colour and body size unless the
/// `style` says otherwise.
///
/// ![The Text example](images/Text.png)
///
/// ```zig
/// const t = cx.theme();
/// return cx.make(kete.SizedBox{ .width = 280, .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .start, .spacing = 8, .children = cx.makeAll(.{
///     kete.Text{ .text = "Headline", .style = .{ .size = 28, .color = t.primary }, .wrap = false },
///     kete.Text{ .text = "Text wraps to the width it is given, and can be aligned in it." },
/// }) }) });
/// ```
pub const Text = struct {
    /// What it says (UTF-8; `\n` starts a new line).
    text: []const u8,
    /// Its size, colour and font.
    style: TextStyle = .{},
    /// Where each line sits in the width it has.
    text_align: TextAlign = .start,
    /// Wrap at spaces to fit the width (otherwise only `\n` breaks lines).
    wrap: bool = true,
    /// End lines too wide for the space with "…" instead of overflowing.
    ellipsis: bool = false,
    /// The way its lines run: right (as usual), or up (turned a quarter
    /// counter-clockwise, as along a card's left edge), left (upside down)
    /// or down (turned a quarter clockwise, as on a book's spine). Turned a
    /// quarter, it wraps (and aligns) in the height it has, and is as wide
    /// as its lines are high.
    direction: gfx.Canvas.TextDirection = .right,

    const Laid = struct { lines: []const Line, style: font.Style };

    /// What the last measurements of the text were, so that the same text
    /// in the same font and width is not measured again each frame.
    pub const State = struct {
        /// The text the entries are for.
        text: []u8 = &.{},
        /// The last two measurements (the widths it is laid out in and
        /// measured at differ).
        entries: [2]Entry = .{ .{}, .{} },
        /// Which entry the next measurement replaces.
        next: u1 = 0,
        gpa: ?std.mem.Allocator = null,

        const Entry = struct {
            valid: bool = false,
            font: ?*const font.Font = null,
            size: f32 = 0,
            width: f32 = 0,
            /// Each line's place in the text, and its width.
            lines: []Span = &.{},
        };

        const Span = struct { start: u32, end: u32, width: f32 };

        pub fn deinit(s: *State) void {
            s.forget();
        }

        fn forget(s: *State) void {
            const gpa = s.gpa orelse return;
            for (&s.entries) |*e| {
                gpa.free(e.lines);
                e.* = .{};
            }
            gpa.free(s.text);
            s.text = &.{};
        }
    };

    /// `wrap` of the text in the width, as last measured if it was.
    fn wrapped(self: *const Text, n: *Node, style: font.Style, width: f32) ![]Line {
        const arena = n.ui.arena();
        const st = n.state(State);
        const gpa = n.ui.gpa;
        st.gpa = gpa;
        if (!std.mem.eql(u8, st.text, self.text)) {
            st.forget();
            st.text = gpa.dupe(u8, self.text) catch return wrap(arena, &n.ui.atlas.runs, style, self.text, width);
        }
        for (&st.entries) |*e| {
            if (!e.valid or e.font != style.font or e.size != style.size or e.width != width) continue;
            const lines = try arena.alloc(Line, e.lines.len);
            for (lines, e.lines) |*l, span| l.* = .{ .text = self.text[span.start..span.end], .width = span.width };
            return lines;
        }
        const lines = try wrap(arena, &n.ui.atlas.runs, style, self.text, width);
        const e = &st.entries[st.next];
        st.next +%= 1;
        gpa.free(e.lines);
        e.* = .{};
        if (gpa.alloc(State.Span, lines.len)) |spans| {
            for (spans, lines) |*span, l| {
                const start = @intFromPtr(l.text.ptr) - @intFromPtr(self.text.ptr);
                span.* = .{ .start = @intCast(start), .end = @intCast(start + l.text.len), .width = l.width };
            }
            e.* = .{ .valid = true, .font = style.font, .size = style.size, .width = width, .lines = spans };
        } else |_| {}
        return lines;
    }

    fn fontStyle(self: *const Text, n: *const Node) ?font.Style {
        const f = self.style.font orelse n.ui.font orelse return null;
        const size = self.style.size orelse n.theme().body_size;
        if (!(size > 0) or !std.math.isFinite(size)) return null;
        return .{ .font = f, .size = size };
    }

    pub fn accessible(self: *const Text, _: *Node) ?a11y.Info {
        // Text: a paragraph of it (named by nothing; its text is its
        // content), as text in a page is.
        return .{ .role = .paragraph, .text = self.text };
    }

    /// Whether its lines run up or down (so its width and height are its
    /// lines' height and length).
    fn sideways(self: *const Text) bool {
        return self.direction == .up or self.direction == .down;
    }

    /// `c`, with width and height swapped if the text runs sideways: the
    /// constraints in the text's own terms, and back.
    fn turn(self: *const Text, c: Constraints) Constraints {
        if (!self.sideways()) return c;
        return .{ .min_w = c.min_h, .max_w = c.max_h, .min_h = c.min_w, .max_h = c.max_w };
    }

    fn turnSize(self: *const Text, s: Size) Size {
        return if (self.sideways()) .{ .w = s.h, .h = s.w } else s;
    }

    pub fn layout(self: *const Text, n: *Node, c_in: Constraints) Size {
        const c = self.turn(c_in);
        const style = self.fontStyle(n) orelse return c.smallest();
        const arena = n.ui.arena();
        const lines = self.wrapped(n, style, if (self.wrap) c.max_w else geometry.inf) catch return c.smallest();
        if (self.ellipsis and c.boundedWidth()) for (lines) |*l| {
            if (l.width > c.max_w) l.* = ellipsize(arena, &n.ui.atlas.runs, style, l.text, c.max_w) catch l.*;
        };
        var widest: f32 = 0;
        for (lines) |l| widest = @max(widest, l.width);
        const height = @as(f32, @floatFromInt(lines.len)) * style.lineHeight();
        const laid = arena.create(Laid) catch return c.smallest();
        laid.* = .{ .lines = lines, .style = style };
        n.scratch = laid;
        const content = self.turnSize(.{ .w = widest, .h = height });
        n.setContent(.{ .x = 0, .y = 0, .w = content.w, .h = content.h });
        return self.turnSize(c.constrain(.{ .w = @ceil(widest), .h = @ceil(height) }));
    }

    pub fn minSize(self: *const Text, n: *Node, c_in: Constraints) Size {
        const c = self.turn(c_in);
        const style = self.fontStyle(n) orelse return c.smallest();
        // Wrapped, with no width to fit, it can be as narrow as its widest
        // word (never a whole paragraph on one line).
        const wrap_w = if (!self.wrap) geometry.inf else if (c.boundedWidth()) c.max_w else 0;
        const lines = self.wrapped(n, style, wrap_w) catch return c.smallest();
        var widest: f32 = 0;
        if (self.ellipsis) {
            widest = if (self.text.len > 0) n.ui.atlas.runs.measure(style, ellipsis_text) else 0;
        } else {
            for (lines) |l| widest = @max(widest, l.width);
        }
        const height = @as(f32, @floatFromInt(lines.len)) * style.lineHeight();
        return self.turnSize(c.constrain(.{ .w = @ceil(widest), .h = @ceil(height) }));
    }

    pub fn paint(self: *const Text, n: *Node, p: *Painter) void {
        const laid: *const Laid = @ptrCast(@alignCast(n.scratch orelse return));
        const color = self.style.color orelse n.theme().on_surface;
        const lh = laid.style.lineHeight();
        // Its length along the lines, in its own terms.
        const length = if (self.sideways()) n.size.h else n.size.w;
        const w = n.size.w;
        const h = n.size.h;
        for (laid.lines, 0..) |l, i| {
            // Along the line and across the lines, then turned.
            const a: f32 = switch (self.text_align) {
                .start => 0,
                .center => @max((length - l.width) / 2, 0),
                .end => @max(length - l.width, 0),
            };
            const b = @as(f32, @floatFromInt(i)) * lh + laid.style.ascent();
            const from: [2]f32 = switch (self.direction) {
                .right => .{ a, b },
                .up => .{ b, h - a },
                .left => .{ w - a, h - b },
                .down => .{ w - b, a },
            };
            _ = p.textRunning(laid.style.size, from, self.direction, l.text, color);
        }
    }
};

const ellipsis_text = "…";

/// As much of `text` as fits `max_width` with "…" after it.
pub fn ellipsize(gpa: std.mem.Allocator, runs: *font.RunCache, style: font.Style, text: []const u8, max_width: f32) !Line {
    const dots = runs.measure(style, ellipsis_text);
    if (dots > max_width) return .{ .text = "", .width = 0 };
    var l = font.Layout.init(style, text, 0);
    var end: usize = 0;
    while (l.next()) |_| {
        if (l.x + dots > max_width) break;
        end = l.at;
    }
    const kept = std.mem.trimEnd(u8, text[0..end], " ");
    const out = try std.mem.concat(gpa, u8, &.{ kept, ellipsis_text });
    return .{ .text = out, .width = runs.measure(style, out) };
}

/// Breaks text into lines no wider than `max_width` where it can: at
/// newlines, and at spaces (a word too wide gets a line of its own).
pub fn wrap(gpa: std.mem.Allocator, runs: *font.RunCache, style: font.Style, text: []const u8, max_width: f32) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |para| {
        const whole = runs.measure(style, para);
        if (whole <= max_width) {
            try lines.append(gpa, .{ .text = para, .width = whole });
            continue;
        }
        var start: usize = 0;
        while (start < para.len) {
            // The longest run of whole words that fits, or one word.
            var end = std.mem.indexOfScalarPos(u8, para, start, ' ') orelse para.len;
            var width: f32 = 0;
            var target_rel: usize = end - start;
            var have_first = false;
            var l = font.Layout.init(style, para[start..], 0);
            while (l.next()) |_| {
                if (l.at == target_rel) {
                    if (!have_first) {
                        have_first = true;
                        width = l.x;
                        if (end >= para.len or width > max_width) break;
                        const next = std.mem.indexOfScalarPos(u8, para, end + 1, ' ') orelse para.len;
                        target_rel = next - start;
                    } else {
                        if (l.x > max_width) break;
                        end = start + target_rel;
                        width = l.x;
                        if (end >= para.len) break;
                        const next = std.mem.indexOfScalarPos(u8, para, end + 1, ' ') orelse para.len;
                        target_rel = next - start;
                    }
                }
            }
            try lines.append(gpa, .{ .text = para[start..end], .width = width });
            // The spaces where it broke start no line.
            start = end;
            while (start < para.len and para[start] == ' ') start += 1;
        }
    }
    return lines.items;
}

test "ellipsis" {
    const f = try font.Font.init(font.default_font_data);
    const style: font.Style = .{ .font = &f, .size = 16 };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var runs = font.RunCache.init(gpa);
    defer runs.deinit();
    const name = "archive-2026-10-18-backup-snapshot.tar.gz";
    const max = font.measure(style, "archive-2026…");
    const l = try ellipsize(arena.allocator(), &runs, style, name, max);
    try std.testing.expectEqualStrings("archive-2026…", l.text);
    try std.testing.expect(l.width <= max);
    // Characters are not split.
    const accents = try ellipsize(arena.allocator(), &runs, style, "éééééééééé", font.measure(style, "éé…") + 1);
    try std.testing.expectEqualStrings("éé…", accents.text);
    // Too narrow for even the dots: nothing.
    try std.testing.expectEqualStrings("", (try ellipsize(arena.allocator(), &runs, style, name, 2)).text);
}

test "wrapping" {
    const f = try font.Font.init(font.default_font_data);
    const style: font.Style = .{ .font = &f, .size = 16 };
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var runs = font.RunCache.init(gpa);
    defer runs.deinit();
    const one = try wrap(a, &runs, style, "Hello there", geometry.inf);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    const w = font.measure(style, "Hello there");
    const two = try wrap(a, &runs, style, "Hello there world", w + 1);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqualStrings("Hello there", two[0].text);
    try std.testing.expectEqualStrings("world", two[1].text);
    // A word wider than the space still gets a line, and breaks show.
    const long = try wrap(a, &runs, style, "Supercalifragilistic is\nlong", 30);
    try std.testing.expectEqualStrings("Supercalifragilistic", long[0].text);
    try std.testing.expect(long[0].width > 30);
    try std.testing.expectEqualStrings("is", long[1].text);
    try std.testing.expectEqualStrings("long", long[2].text);
}
