//! ScrollView: shows the part of a child taller than itself that is
//! scrolled to, with the wheel or by dragging the bar at its right edge
//! (which takes its width from the child while there is anything to
//! scroll). The child is as wide as the view, and as tall as it likes.
//!
//!     cx.make(ui.ScrollView{ .child = cx.make(ui.Column{ .children = rows }) })
//!
//! The scroll position is the view's state: give the view a new key to
//! start again at the top (for a different list). `reveal` scrolls to a
//! widget in it (one given that key) when it changes: to show the item
//! picked, say.

const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;
const Event = widget.Event;
const Painter = painter_mod.Painter;

/// Scrolls its child, with a bar, by the wheel, touch or keyboard.
///
/// ![The ScrollView example](images/ScrollView.png)
///
/// ```zig
/// return cx.make(kete.SizedBox{ .width = 240, .height = 140, .child = cx.make(kete.ScrollView{ .child = cx.make(kete.Column{
///     .fill = false,
///     .cross_axis_alignment = .stretch,
///     .children = cx.makeAll(.{
///         kete.ListItem{ .headline = "One" },
///         kete.ListItem{ .headline = "Two" },
///         kete.ListItem{ .headline = "Three" },
///         kete.ListItem{ .headline = "Four" },
///         kete.ListItem{ .headline = "Five" },
///         kete.ListItem{ .headline = "Six" },
///     }),
/// }) }) });
/// ```
pub const ScrollView = struct {
    /// The widget that scrolls (as tall as it needs to be).
    child: Widget,
    /// The bar's width.
    bar_width: f32 = 12,
    /// How far a turn of the wheel scrolls, as a multiple of what the
    /// compositor reports (typically 15 pixels per wheel notch).
    wheel_factor: f32 = 3,
    /// The key of a widget in it to scroll to, when this changes.
    reveal: ?u64 = null,

    pub const clips_children = true;
    pub const scrolls = true;

    pub const State = struct {
        /// How far down the child is scrolled.
        offset: f32 = 0,
        /// From the last layout: the child's height, and the view's.
        content: f32 = 0,
        viewport: f32 = 0,
        /// Dragging the bar's thumb: how far down the thumb it was taken.
        grab: ?f32 = null,
        /// The last `reveal` scrolled to.
        revealed: ?u64 = null,
        hovered: bool = false,

        pub fn maxOffset(s: *const State) f32 {
            return @max(s.content - s.viewport, 0);
        }

        /// Scrolls to `offset` (as far as it goes). Returns whether it
        /// moved.
        pub fn scrollTo(s: *State, offset: f32) bool {
            const o = std.math.clamp(offset, 0, s.maxOffset());
            if (o == s.offset) return false;
            s.offset = o;
            return true;
        }
    };

    const Thumb = struct { y: f32, h: f32 };

    /// The bar's thumb, if there is anything to scroll.
    fn thumb(self: *const ScrollView, s: *const State) ?Thumb {
        if (s.maxOffset() <= 0 or s.viewport <= 0) return null;
        const h = @min(@max(s.viewport * s.viewport / s.content, self.bar_width * 3), s.viewport);
        return .{ .y = (s.viewport - h) * s.offset / s.maxOffset(), .h = h };
    }

    pub fn layout(self: *const ScrollView, n: *Node, c: Constraints) Size {
        const s = n.state(State);
        if (n.childCount() == 0) return c.biggest();
        const ch = n.child(0);
        const width = if (c.boundedWidth()) c.max_w else geometry.inf;
        const inner = struct {
            fn f(w: f32) Constraints {
                return if (std.math.isFinite(w)) .{ .min_w = w, .max_w = w } else .{};
            }
        }.f;
        // Widgets in it that make only what shows learn what does once it
        // is laid out.
        n.ui.scrolling += 1;
        defer n.ui.scrolling -= 1;
        var size = ch.layout(inner(width));
        const height = if (c.boundedHeight()) c.max_h else size.h;
        // Too tall: the bar takes its width.
        var bar: f32 = 0;
        if (size.h > height + 0.5) {
            bar = @min(self.bar_width, if (std.math.isFinite(width)) width else self.bar_width);
            size = ch.layout(inner(width - bar));
        }
        s.content = size.h;
        s.viewport = height;
        if (self.reveal != s.revealed) {
            s.revealed = self.reveal;
            if (self.reveal) |key| if (find(ch, key)) |target| {
                // Its top and bottom in the child.
                var y = target.offset[1];
                var up = target.parent;
                while (up) |u| : (up = u.parent) {
                    if (u == ch) break;
                    y += u.offset[1];
                }
                if (y < s.offset) s.offset = y else if (y + target.size.h > s.offset + height) s.offset = y + target.size.h - height;
            };
        }
        s.offset = std.math.clamp(s.offset, 0, s.maxOffset());
        ch.place(0, -@round(s.offset));
        ch.realizeIn(.{ .x = 0, .y = @round(s.offset), .w = if (std.math.isFinite(width)) width else size.w, .h = height });
        return c.constrain(.{ .w = if (std.math.isFinite(width)) width else size.w + bar, .h = height });
    }

    pub fn minSize(self: *const ScrollView, n: *Node, c: Constraints) Size {
        if (n.childCount() == 0) return c.smallest();
        const ch = n.child(0);
        const width = if (c.boundedWidth()) c.max_w else geometry.inf;
        const inner: Constraints = if (std.math.isFinite(width)) .{ .min_w = width, .max_w = width } else .{};
        n.ui.scrolling += 1;
        defer n.ui.scrolling -= 1;
        const size = ch.minSize(inner);
        const bar = if (size.h > 0) self.bar_width else 0;
        const min_h = @min(size.h, self.bar_width * 3);
        return c.constrain(.{
            .w = if (std.math.isFinite(width)) width else size.w + bar,
            .h = min_h,
        });
    }

    pub fn paintOver(self: *const ScrollView, n: *Node, p: *Painter) void {
        const s = n.state(State);
        const t = self.thumb(s) orelse return;
        const theme = n.theme();
        const inset = @max(self.bar_width / 4, 1);
        const w = self.bar_width - 2 * inset;
        p.canvas().fillRoundedRect(
            .{ .x = n.size.w - self.bar_width + inset, .y = t.y + inset, .w = w, .h = t.h - 2 * inset },
            .all(w / 2),
            theme.on_surface_variant.withAlpha(if (s.grab != null) 0.7 else if (s.hovered) 0.5 else 0.3),
        );
    }

    pub fn event(self: *const ScrollView, n: *Node, e: Event) bool {
        const s = n.state(State);
        switch (e) {
            .enter, .leave => {
                const hovered = e == .enter;
                if (s.hovered != hovered) n.ui.needs_frame = true;
                s.hovered = hovered;
            },
            .scroll => |sc| {
                // The content follows a finger; a wheel's notches go further.
                if (!s.scrollTo(s.offset + sc.dy * (if (sc.touch) 1 else self.wheel_factor))) return false;
                n.ui.needs_frame = true;
                return true;
            },
            .press => |pr| {
                const t = self.thumb(s) orelse return false;
                if (pr.button != .left or pr.pos[0] < n.size.w - self.bar_width) return false;
                // On the thumb, it is dragged from there; elsewhere on the
                // bar, it jumps to the pointer first.
                s.grab = if (pr.pos[1] >= t.y and pr.pos[1] < t.y + t.h) pr.pos[1] - t.y else t.h / 2;
                self.dragTo(s, pr.pos[1]);
                n.ui.needs_frame = true;
                return true;
            },
            .motion => |pos| if (s.grab != null) {
                self.dragTo(s, pos[1]);
                n.ui.needs_frame = true;
            },
            .release => {
                s.grab = null;
                n.ui.needs_frame = true;
                return true;
            },
            else => {},
        }
        return false;
    }

    /// The node (laid out this frame) whose widget has `key`.
    fn find(n: *Node, key: u64) ?*Node {
        if (n.widget.key == key and n.laid_out == n.ui.frame_no) return n;
        for (n.children.items) |c| if (find(c, key)) |f| return f;
        return null;
    }

    /// Scrolls so the thumb, taken at `grab`, is at `y`.
    fn dragTo(self: *const ScrollView, s: *State, y: f32) void {
        const t = self.thumb(s) orelse return;
        const travel = s.viewport - t.h;
        if (travel <= 0) return;
        _ = s.scrollTo((y - s.grab.?) / travel * s.maxOffset());
    }
};
