//! Pressable: calls back when the child is clicked, and says whether the
//! pointer is over it and pressing it (`PointerInteraction`).

const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const focus = @import("focus.zig");
const Painter = @import("painter.zig").Painter;

const Widget = widget.Widget;
const Node = widget.WidgetNode;
const Event = widget.Event;
const Callback = widget.Callback;

/// Whether the pointer is over a widget, and pressing it.
pub const PointerInteraction = struct {
    /// Whether the pointer is over it.
    hovered: bool = false,
    /// Whether the pointer is held down on it.
    pressed: bool = false,
};

/// Calls `on_press` when the child is clicked (the left button pressed
/// and released over it), or, with the keyboard's focus (which it takes
/// if it can be pressed), when Space or Enter is pressed; and keeps
/// `interaction` up to date (for widgets that look different when hovered
/// or pressed: give it their state's). Focused from the keyboard, it has
/// a focus ring, its corners `focus_radius` (null: round).
pub const Pressable = struct {
    /// Called when it is pressed; without it, it cannot be.
    on_press: ?Callback = null,
    /// Kept up to date, for the widgets that look different when hovered or pressed.
    interaction: ?*PointerInteraction = null,
    /// The corners' radius of the focus ring.
    focus_radius: ?f32 = null,
    /// The widget in it.
    child: ?Widget = null,

    pub fn focusable(self: *const Pressable, _: *Node) bool {
        return self.on_press != null;
    }

    pub fn paintOver(self: *const Pressable, n: *Node, p: *Painter) void {
        focus.ring(n, p, self.focus_radius, false);
    }

    pub fn cursor(self: *const Pressable, _: *Node, _: geometry.Point) ?widget.PointerCursor {
        return if (self.on_press != null) .pointer else null;
    }

    pub fn event(self: *const Pressable, n: *Node, e: Event) bool {
        var dummy: PointerInteraction = .{};
        const i = self.interaction orelse &dummy;
        switch (e) {
            .enter, .leave => if (self.interaction) |it| {
                const hovered = e == .enter;
                if (it.hovered != hovered) n.ui.needs_frame = true;
                it.hovered = hovered;
            },
            .press => |p| {
                if (p.button != .left or self.on_press == null) return false;
                if (self.interaction != null) n.ui.needs_frame = true;
                i.pressed = true;
                return true;
            },
            .release => |r| {
                if (self.interaction != null) n.ui.needs_frame = true;
                i.pressed = false;
                if (r.inside) if (self.on_press) |f| {
                    f.call();
                    n.ui.needs_frame = true;
                };
                return true;
            },
            .key => |k| {
                if (k.key != .space and k.key != .enter and k.key != .keypad_enter) return false;
                const f = self.on_press orelse return false;
                if (k.pressed) {
                    f.call();
                    n.ui.needs_frame = true;
                }
                return true;
            },
            else => {},
        }
        return false;
    }
};
