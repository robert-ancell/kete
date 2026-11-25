//! Wrap: widgets in a row, going on in the next row when they do not fit.

const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const flex = @import("flex.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// Its children side by side, as many as fit across, then the rest in the
/// rows below: for chips, tags and the like, however wide the window is.
/// Each is as big as it wants (no wider than the whole). Mirrored right to
/// left.
///
/// ![The Wrap example](images/Wrap.png)
///
/// ```zig
/// return cx.make(kete.SizedBox{ .width = 260, .child = cx.make(kete.Wrap{ .spacing = 8, .run_spacing = 8, .children = cx.makeAll(.{
///     kete.Chip{ .label = "Apples", .on_press = .of(state, State.save) },
///     kete.Chip{ .label = "Bananas", .on_press = .of(state, State.save) },
///     kete.Chip{ .label = "Cherries", .on_press = .of(state, State.save) },
///     kete.Chip{ .label = "Dates", .on_press = .of(state, State.save) },
///     kete.Chip{ .label = "Elderberries", .on_press = .of(state, State.save) },
/// }) }) });
/// ```
pub const Wrap = struct {
    /// The widgets, in order: along each row, then down.
    children: []const Widget = &.{},
    /// Between each two in a row.
    spacing: f32 = 0,
    /// Between each two rows.
    run_spacing: f32 = 0,
    /// Where each row's widgets are along it (start, center or end).
    alignment: flex.MainAxisAlignment = .start,
    /// Where each widget is in its row's height.
    cross_axis_alignment: flex.CrossAxisAlignment = .center,

    pub fn layout(self: *const Wrap, n: *Node, c: Constraints) Size {
        const max_w = if (c.boundedWidth()) c.max_w else std.math.inf(f32);
        const kids = n.children.items;
        // Each as big as it wants (its size is kept on its node).
        for (kids) |ch| _ = ch.layout(.{ .max_w = max_w });
        var y: f32 = 0;
        var widest: f32 = 0;
        var i: usize = 0;
        while (i < kids.len) {
            // As many as fit in this row (one at least).
            var end = i + 1;
            var w = kids[i].size.w;
            var h = kids[i].size.h;
            while (end < kids.len and w + self.spacing + kids[end].size.w <= max_w) : (end += 1) {
                w += self.spacing + kids[end].size.w;
                h = @max(h, kids[end].size.h);
            }
            const room = if (std.math.isFinite(max_w)) max_w - w else 0;
            var x: f32 = switch (self.alignment) {
                .center => room / 2,
                .end => room,
                else => 0,
            };
            for (kids[i..end]) |ch| {
                const dy: f32 = switch (self.cross_axis_alignment) {
                    .start, .stretch => 0,
                    .center => (h - ch.size.h) / 2,
                    .end => h - ch.size.h,
                };
                ch.place(x, y + dy);
                x += ch.size.w + self.spacing;
            }
            widest = @max(widest, w);
            y += h;
            i = end;
            if (i < kids.len) y += self.run_spacing;
        }
        return c.constrain(.{ .w = if (std.math.isFinite(max_w) and self.alignment != .start) max_w else widest, .h = y });
    }

    pub fn minSize(_: *const Wrap, n: *Node, c: Constraints) Size {
        // As narrow as its widest child: the rest go below.
        var w: f32 = 0;
        var h: f32 = 0;
        for (n.children.items) |ch| {
            const s = ch.minSize(c.loosen());
            w = @max(w, s.w);
            h += s.h;
        }
        return c.constrain(.{ .w = w, .h = h });
    }
};
