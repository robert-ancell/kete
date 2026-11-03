//! Dragging and dropping within a window. A `Draggable` is clicked as a
//! `Pressable` is, but held down and moved (further than `slop`) it is
//! dragged: a chip with its icon and label follows the pointer, above
//! everything (`WindowUi.drag`), and the `DropTarget` under the pointer that
//! takes what is dragged is highlighted. Let go over it, the target is
//! given the draggable's `data`; anywhere else, nothing happens.
//!
//! A finger drags too, where nothing under it scrolls (where something
//! does, it scrolls that instead).

const std = @import("std");
const gfx = @import("gfx");
const icons = @import("icons");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const PointerInteraction = @import("pressable.zig").PointerInteraction;
const RoundedBox = @import("rounded_box.zig").RoundedBox;
const Padding = @import("padding.zig").Padding;
const Row = @import("flex.zig").Row;
const Icon = @import("icon.zig").Icon;
const Text = @import("text.zig").Text;
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;

const Point = geometry.Point;
const Widget = widget.Widget;
const Node = widget.WidgetNode;
const Event = widget.Event;
const Callback = widget.Callback;
const ValueCallback = widget.ValueCallback;
const Context = widget.BuildContext;
const Painter = painter_mod.Painter;

/// How far the pointer moves, held down, before it drags.
pub const slop = 8;

/// What is being dragged: kept by the `WindowUi` while it is.
pub const Drag = struct {
    /// The draggable's node, and what it carries.
    source: *Node,
    data: usize,
    /// The chip's (the `WindowUi`'s own copy).
    label: []u8,
    icon: ?icons.IconName,
    /// Where the pointer is, in the window.
    pos: Point,
    /// The target under it that would take it, if any.
    target: ?*Node = null,
};

/// Makes its child something to drag with the pointer, to drop on a `DropTarget`.
pub const Draggable = struct {
    /// What a target is given when this is dropped on it.
    data: usize,
    /// The text on the chip that follows the pointer.
    label: []const u8 = "",
    /// The icon on that chip.
    icon: ?icons.IconName = null,
    /// Clicked (pressed and let go without dragging).
    on_press: ?Callback = null,
    /// Kept up to date, as `Pressable`'s is.
    interaction: ?*PointerInteraction = null,
    /// The widget in it.
    child: ?Widget = null,

    pub const State = struct {
        /// Where the button went down, in the window, while it is down.
        start: ?Point = null,
    };

    pub fn cursor(self: *const Draggable, n: *Node, _: Point) ?widget.PointerCursor {
        if (n.ui.drag) |d| if (d.source == n) return .grabbing;
        return if (self.on_press != null) .pointer else .grab;
    }

    pub fn event(self: *const Draggable, n: *Node, e: Event) bool {
        var dummy: PointerInteraction = .{};
        const i = self.interaction orelse &dummy;
        const st = n.state(State);
        const origin = n.position();
        switch (e) {
            .enter, .leave => {
                const hovered = e == .enter;
                if (i.hovered != hovered) n.ui.needs_frame = true;
                i.hovered = hovered;
            },
            .press => |p| {
                if (p.button != .left) return false;
                if (self.interaction != null) n.ui.needs_frame = true;
                i.pressed = true;
                st.start = .{ origin[0] + p.pos[0], origin[1] + p.pos[1] };
                return true;
            },
            .motion => |p| {
                const start = st.start orelse return false;
                const at: Point = .{ origin[0] + p[0], origin[1] + p[1] };
                if (n.ui.drag) |d| {
                    if (d.source == n) n.ui.moveDrag(at);
                } else if (@abs(at[0] - start[0]) > slop or @abs(at[1] - start[1]) > slop) {
                    i.pressed = false;
                    n.ui.startDrag(.{ .source = n, .data = self.data, .label = @constCast(self.label), .icon = self.icon, .pos = at });
                }
            },
            .release => |r| {
                if (self.interaction != null) n.ui.needs_frame = true;
                i.pressed = false;
                const was_down = st.start != null;
                st.start = null;
                if (n.ui.drag) |d| if (d.source == n) {
                    // Let go without a pointer (a touch taken away): no drop.
                    n.ui.endDrag(!(r.pos[0] == -1 and r.pos[1] == -1 and !r.inside));
                    return true;
                };
                if (was_down and r.inside) if (self.on_press) |f| {
                    f.call();
                    n.ui.needs_frame = true;
                };
                return true;
            },
            else => {},
        }
        return false;
    }
};

/// Takes what is dropped on it (a `Draggable`'s data), and is highlighted
/// while something it takes is dragged over it.
pub const DropTarget = struct {
    /// Null: it takes nothing.
    on_drop: ?ValueCallback(usize) = null,
    /// Whether it takes this (all, if null).
    accepts: ?*const fn (ctx: ?*const anyopaque, data: usize) bool = null,
    /// What `accepts` is called with.
    accepts_ctx: ?*const anyopaque = null,
    /// The highlight's corners.
    radius: f32 = 12,
    /// The widget in it.
    child: ?Widget = null,

    /// Whether it takes `data`, if it were dropped on it.
    pub fn takes(self: *const DropTarget, data: usize) bool {
        if (self.on_drop == null) return false;
        const f = self.accepts orelse return true;
        return f(self.accepts_ctx, data);
    }

    pub fn event(_: *const DropTarget, _: *Node, _: Event) bool {
        return false;
    }

    pub fn paint(self: *const DropTarget, n: *Node, p: *Painter) void {
        const d = n.ui.drag orelse return;
        if (d.target != n) return;
        const t = n.theme();
        const c = p.canvas();
        const r: gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };
        c.fillRoundedRect(r, .all(self.radius), t.primary.withAlpha(0.12));
        c.strokeRoundedRect(r, .all(self.radius), 2, t.primary);
    }
};

/// The chip that follows the pointer: the icon and label of what is
/// dragged.
pub const Chip = struct {
    label: []const u8,
    icon: ?icons.IconName,

    pub fn build(self: *const Chip, cx: *Context) Widget {
        const t = cx.theme();
        const text = cx.make(ConstrainedBox{ .constraints = .{ .max_w = 240 }, .child = cx.make(Text{ .text = self.label, .style = .{ .size = 15, .color = t.on_surface }, .wrap = false, .ellipsis = true }) });
        return cx.make(RoundedBox{
            .color = t.secondary_container,
            .border_color = t.outline_variant,
            .radius = .all(16),
            .child = cx.make(Padding{ .padding = .symmetric(12, 6), .child = cx.make(Row{ .spacing = 8, .fill = false, .children = if (self.icon) |ic|
                cx.makeAll(.{ Icon{ .icon = ic, .size = 20, .color = t.on_surface }, text })
            else
                &.{text} }) }),
        });
    }
};

/// The deepest target under `pos` (in the window) that takes `data`, in
/// the nodes `path` (deepest first).
pub fn targetIn(path: []const *Node, data: usize) ?*Node {
    for (path) |n| if (n.widget.as(DropTarget)) |t| if (t.takes(data)) return n;
    return null;
}
