//! Opacity: draws its child (and everything in it) see-through.

const widget = @import("widget.zig");

const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// Draws its child faded: everything in it as opaque as `opacity` (0,
/// not drawn, to 1, as it is) says, times what any `Opacity` it is in
/// says. For fading something in or out (with `AnimatedWidget`) without
/// changing each of its colours. It is laid out, and takes the pointer, as
/// it would if it were opaque: leave it out, or what it presses does
/// nothing, while it cannot be seen.
///
/// Each shape in it fades on its own, so where they overlap the one below
/// shows through the one above, as it would not if the whole were drawn
/// and then faded. A 3D view in it (`VulkanArea` and the like) is not
/// faded.
///
/// ![The Opacity example](images/Opacity.png)
///
/// (`box` stands for any widget: a labelled rounded rectangle.)
///
/// ```zig
/// return cx.make(kete.Padding{ .padding = .all(16), .child = cx.make(kete.Row{ .spacing = 16, .children = cx.makeAll(.{
///     box(cx, "Opaque", 80, 48),
///     kete.Opacity{ .opacity = 0.6, .child = box(cx, "0.6", 80, 48) },
///     kete.Opacity{ .opacity = 0.25, .child = box(cx, "0.25", 80, 48) },
/// }) }) });
/// ```
pub const Opacity = struct {
    /// How opaque: 0 is not drawn at all, 1 is drawn as it is.
    opacity: f32 = 1,
    child: ?Widget = null,

    pub fn paintOpacity(self: *const Opacity, _: *const Node) f32 {
        return self.opacity;
    }
};
