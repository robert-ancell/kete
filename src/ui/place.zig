//! Place: puts its child at a point of the space it has, given as a
//! fraction of it.

const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Point = geometry.Point;
const Constraints = geometry.Constraints;
const Alignment = geometry.Alignment;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// Puts a point of its child (`anchor`: its middle, to begin with) at
/// `at`, a point of the space it fills given as fractions of it (0 to 1
/// across and down), moved by `offset` pixels; kept inside, if it fits.
/// Where `Align` puts a child's edges by the edges of the space (its
/// right edge at the right), `Place` puts a point of it at a point of the
/// space: for laying things out in proportion to the screen (words spread
/// evenly over it, say), and moving them from one point to another (with
/// `AnimatedWidget`).
///
/// Its fractions are of the space as it is, not mirrored right to left.
///
/// ![The Place example](images/Place.png)
///
/// (`box` stands for any widget: a labelled rounded rectangle.)
///
/// ```zig
/// return cx.make(kete.SizedBox{ .width = 240, .height = 120, .child = cx.make(kete.Overlay{ .children = cx.makeAll(.{
///     kete.Place{ .at = .{ 0.25, 0.3 }, .child = box(cx, "A quarter", 96, 40) },
///     kete.Place{ .at = .{ 0.75, 0.7 }, .child = box(cx, "Three quarters", 120, 40) },
/// }) }) });
/// ```
pub const Place = struct {
    /// Where, as fractions of the space: (0, 0) its top left, (0.5, 0.5)
    /// its middle, (1, 1) its bottom right.
    at: [2]f32 = .{ 0.5, 0.5 },
    /// Which point of the child goes there: its middle, its top centre and
    /// so on.
    anchor: Alignment = .center,
    /// Pixels it is moved by from there (across and down).
    offset: Point = .{ 0, 0 },
    /// Kept inside the space (if it fits).
    keep_inside: bool = true,
    child: ?Widget = null,

    pub fn layout(self: *const Place, n: *Node, c: Constraints) Size {
        const s = if (n.childCount() > 0) n.child(0).layout(c.loosen()) else Size{};
        const size = c.constrain(.{
            .w = if (c.boundedWidth()) c.max_w else s.w,
            .h = if (c.boundedHeight()) c.max_h else s.h,
        });
        if (n.childCount() > 0) {
            const at = self.childAt(size, s);
            n.child(0).place(at[0], at[1]);
        }
        return size;
    }

    pub fn minSize(_: *const Place, n: *Node, c: Constraints) Size {
        return if (n.childCount() > 0) n.child(0).minSize(c.loosen()) else .{};
    }

    /// Where the child's top left goes, in a space `outer`, the child
    /// `inner` big.
    pub fn childAt(self: *const Place, outer: Size, inner: Size) Point {
        // The anchor's place in the child (Alignment's -1 to 1 as 0 to 1).
        var x = outer.w * self.at[0] - inner.w * (self.anchor.x + 1) / 2 + self.offset[0];
        var y = outer.h * self.at[1] - inner.h * (self.anchor.y + 1) / 2 + self.offset[1];
        if (self.keep_inside) {
            x = std.math.clamp(x, 0, @max(outer.w - inner.w, 0));
            y = std.math.clamp(y, 0, @max(outer.h - inner.h, 0));
        }
        return .{ x, y };
    }
};
