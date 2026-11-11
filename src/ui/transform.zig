//! Transform: draws its child moved, scaled, turned or skewed, laid out
//! as if it were not.

const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Alignment = geometry.Alignment;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// Draws its child moved, scaled, turned or skewed (`transform`, about
/// `origin`): for animating it (a button that shakes, or pulses). It takes
/// the space the child would and places the widgets round it as if it were
/// not transformed, so the child can be drawn over them. It is hit where
/// it is drawn, within the widgets it is in.
///
/// Text only scaled stays sharp; turned or skewed, it is drawn with the
/// pixels of its upright glyphs. A 3D view in it (`VulkanArea` and the
/// like) is moved and scaled to the box it ends up in, not turned.
///
/// ![The Transform example](images/Transform.png)
///
/// (`box` stands for any widget: a labelled rounded rectangle.)
///
/// ```zig
/// return cx.make(kete.Padding{ .padding = .all(16), .child = cx.make(kete.Row{ .spacing = 32, .children = cx.makeAll(.{
///     kete.Transform.rotate(-std.math.pi / 12.0, box(cx, "Turned", 80, 48)),
///     kete.Transform.scale(1.25, box(cx, "Scaled", 80, 48)),
///     kete.Transform.translate(0, 12, box(cx, "Moved", 80, 48)),
/// }) }) });
/// ```
pub const Transform = struct {
    /// How it is drawn: in the child's coordinates, with (0, 0) at
    /// `origin`.
    transform: gfx.Affine = .identity,
    /// The point of the child it is done about: its middle, so a scale
    /// grows it in every direction, and a turn spins it in place.
    origin: Alignment = .center,
    child: ?Widget = null,

    /// `child` moved by (`x`, `y`).
    pub fn translate(x: f32, y: f32, child: Widget) Transform {
        return .{ .transform = .translation(x, y), .child = child };
    }

    /// `child` scaled by `factor` about its middle.
    pub fn scale(factor: f32, child: Widget) Transform {
        return .{ .transform = .scaling(factor, factor), .child = child };
    }

    /// `child` turned by `radians` clockwise about its middle.
    pub fn rotate(radians: f32, child: Widget) Transform {
        return .{ .transform = .rotation(radians), .child = child };
    }

    pub fn paintTransform(self: *const Transform, n: *const Node) gfx.Affine {
        const pivot = self.origin.place(n.size, .{});
        return self.transform.about(pivot);
    }
};
