//! ScaleDown: its child at the size it wants, made smaller to fit if it
//! does not.

const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// Its child at the size it wants, or, if that does not fit, drawn smaller
/// (keeping its shape) until it does; never bigger. For a picture made at
/// a size that suits big screens (a keyboard's layout, say) on a small
/// one. The child is laid out at its own size, and drawn and hit scaled,
/// as in a `Transform`: text in it stays sharp.
///
/// ![The ScaleDown example](images/ScaleDown.png)
///
/// (`box` stands for any widget: a labelled rounded rectangle.)
///
/// ```zig
/// return cx.make(kete.Padding{ .padding = .all(16), .child = cx.make(kete.Row{ .spacing = 16, .children = cx.makeAll(.{
///     kete.SizedBox{ .width = 200, .height = 60, .child = cx.make(kete.ScaleDown{ .child = box(cx, "Fits", 120, 48) }) },
///     kete.SizedBox{ .width = 120, .height = 60, .child = cx.make(kete.ScaleDown{ .child = box(cx, "Made smaller", 200, 48) }) },
/// }) }) });
/// ```
pub const ScaleDown = struct {
    child: ?Widget = null,

    pub fn layout(_: *const ScaleDown, n: *Node, c: Constraints) Size {
        if (n.childCount() == 0) return c.constrain(.{});
        const ch = n.child(0);
        const want = ch.layout(.{});
        const k = factor(c, want);
        ch.place(0, 0);
        // Laid out bigger than it is drawn: not overflow.
        ch.overhangs = k < 1;
        return c.constrain(.{ .w = want.w * k, .h = want.h * k });
    }

    /// It can be made as small as need be.
    pub fn minSize(_: *const ScaleDown, _: *Node, c: Constraints) Size {
        return c.constrain(.{});
    }

    pub fn paintTransform(_: *const ScaleDown, n: *const Node) gfx.Affine {
        if (n.childCount() == 0) return .identity;
        const ch = n.children.items[0];
        if (ch.size.w <= 0 or ch.size.h <= 0) return .identity;
        const k = @min(n.size.w / ch.size.w, n.size.h / ch.size.h, 1);
        return .scaling(k, k);
    }

    /// How much smaller `want` must be to fit `c` (1: it fits).
    fn factor(c: Constraints, want: Size) f32 {
        var k: f32 = 1;
        if (c.boundedWidth() and want.w > c.max_w and want.w > 0) k = @min(k, c.max_w / want.w);
        if (c.boundedHeight() and want.h > c.max_h and want.h > 0) k = @min(k, c.max_h / want.h);
        return k;
    }
};
