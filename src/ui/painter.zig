//! Painting the laid-out tree: each widget draws on a 2D canvas, with its
//! top left as the origin, or adds a draw of its own straight to the GPU
//! frame (a 3D view, say). Those split the 2D drawing into layers below
//! and above them, so everything keeps the tree's order.
//!
//! Widgets whose children (or content) reach past their edges are clipped
//! to their bounds, and the edges that overflow get black and yellow
//! stripes: a layout that does not fit still shows, with the problem
//! marked. Widgets that clip on purpose (scroll views) get no stripes, and
//! what is outside the clip is not painted at all.

const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const runtime = @import("runtime.zig");

const Point = geometry.Point;
const Rect = geometry.Rect;
const Node = widget.WidgetNode;
const WindowUi = runtime.WindowUi;

/// Where a GPU draw goes, in the frame's pixels.
pub const GpuArea = gfx.GpuArea;
pub const GpuDraw = gfx.GpuDraw;
pub const Segment = gfx.Segment;

/// Black and yellow, three quarters opaque.
pub const stripe_colors = [2]gfx.Color{ gfx.Color.argb(0xbf000000), gfx.Color.argb(0xbfffff00) };
/// How deep the overflow stripes go into the widget.
pub const stripe_depth = 8;
const stripe_period = 12;

/// What a widget paints with: the canvas to draw on, text and icons, and
/// GPU draws, with the origin at the widget's top left and its clip applied.
pub const Painter = struct {
    /// The UI (a window's) being painted.
    ui: *WindowUi,
    /// The node being painted.
    node: *Node,
    /// Where the node's top left is in the frame.
    origin: Point = .{ 0, 0 },
    /// What may be drawn on, in the frame's pixels.
    clip: ?Rect = null,
    /// What the node being painted draws (see `damage.zig`).
    rec: ?*gfx.Record = null,
    /// Whether what is painted damages the window (not in a popup, which
    /// is drawn whole).
    track_damage: bool = true,

    /// The theme the widget being painted is in.
    pub fn theme(p: *const Painter) *const @import("theme.zig").Theme {
        return p.node.theme();
    }

    /// The canvas to draw on now, with the origin at the widget's top left
    /// and its clip applied.
    pub fn canvas(p: *Painter) *gfx.Canvas {
        const c = p.ui.currentCanvas();
        c.setOrigin(p.origin);
        c.clip = if (p.clip) |r| scaleRect(r, c.scale) else null;
        c.recorder = p.rec;
        return c;
    }

    /// Draws a line of text with its baseline at `baseline`; returns the
    /// pen position after it. Nothing is drawn without a font.
    pub fn text(p: *Painter, size: f32, x: f32, baseline: f32, str: []const u8, color: gfx.Color) f32 {
        const f = p.ui.font orelse return x;
        return p.canvas().drawText(p.ui.atlas, .{ .font = f, .size = size }, x, baseline, str, color);
    }

    /// Draws `str` in the UI's font from `from` (where its baseline starts),
    /// running `direction` (up, down or upside down, its glyphs turned with
    /// it); where its baseline ends.
    pub fn textRunning(p: *Painter, size: f32, from: [2]f32, direction: gfx.Canvas.TextDirection, str: []const u8, color: gfx.Color) [2]f32 {
        const f = p.ui.font orelse return from;
        return p.canvas().drawTextRunning(p.ui.atlas, .{ .font = f, .size = size }, from, direction, str, color);
    }

    /// Draws an icon `size` square with its top left at (`x`, `y`).
    pub fn icon(p: *Painter, which: @import("icons").IconName, x: f32, y: f32, size: f32, color: gfx.Color) void {
        var buf: [4]u8 = undefined;
        // Icons fill the em square, with the baseline at the bottom.
        _ = p.canvas().drawText(p.ui.atlas, .{ .font = p.ui.icon_font, .size = size }, x, y + size, @import("icons").text(which, &buf), color);
    }

    /// Limits drawing to `r` (relative to the widget) until `restoreClip`
    /// with what this returns.
    pub fn clipTo(p: *Painter, r: Rect) ?Rect {
        const old = p.clip;
        p.clip = intersect(p.clip, .{ .x = r.x + p.origin[0], .y = r.y + p.origin[1], .w = r.w, .h = r.h });
        p.syncCanvasClip();
        return old;
    }

    /// Goes back to the limit `clipTo` returned.
    pub fn restoreClip(p: *Painter, old: ?Rect) void {
        p.clip = old;
        p.syncCanvasClip();
    }

    fn syncCanvasClip(p: *const Painter) void {
        const items = p.ui.segments.items;
        if (items.len > 0) switch (items[items.len - 1]) {
            .canvas => |c| c.clip = if (p.clip) |cl| scaleRect(cl, c.scale) else null,
            .gpu => {},
        };
    }

    /// Adds a draw straight into the target frame over the widget's box,
    /// between what is painted before it and after it. `f` is called when
    /// the frame is rendered, with `ctx` (which must last until then: the
    /// widget, or its state) and the render target pointer.
    pub fn gpu(p: *Painter, ctx: anytype, comptime f: anytype) void {
        p.gpuWith(.{}, ctx, f);
    }

    pub const GpuOptions = struct {
        /// The part of the box it draws on (relative to the widget), if
        /// less than all of it.
        bounds: ?Rect = null,
        /// Identifies what it draws: the same key as last frame means the
        /// same picture (so nothing needs redrawing). Without one, it
        /// changes every frame.
        key: ?u64 = null,
        /// It sets every pixel of its box (within the clip), so what is
        /// under it need not be drawn.
        fills: bool = false,
    };

    /// `gpu` with `options`.
    pub fn gpuWith(p: *Painter, options: GpuOptions, ctx: anytype, comptime f: anytype) void {
        const Ctx = @TypeOf(ctx);
        const FnInfo = @typeInfo(@TypeOf(f)).@"fn";
        const TargetPtr = FnInfo.param_types[1].?;
        const s: f32 = @floatFromInt(@max(p.ui.scale, 1));
        const box = p.boxRect();
        const vp = viewport(scaleRect(box, s)) orelse return;
        var scissor: ?gfx.Viewport = null;
        if (p.clip) |clip| scissor = viewport(scaleRect(intersect(clip, box).?, s)) orelse return;
        if (p.rec) |rec| {
            const key = options.key orelse p.ui.frame_no;
            rec.hash.update(std.mem.asBytes(&key));
            const b = if (options.bounds) |r| intersect(box, .{ .x = r.x + p.origin[0], .y = r.y + p.origin[1], .w = r.w, .h = r.h }).? else box;
            if (intersect(p.clip, b)) |area| if (area.w > 0 and area.h > 0) {
                const scaled_area = scaleRect(area, s);
                rec.bounds = if (rec.bounds) |old| old.unite(scaled_area) else scaled_area;
            };
        }
        p.ui.addGpu(.{
            .ctx = @ptrCast(ctx),
            .f = struct {
                fn call(c: *const anyopaque, target: *anyopaque, area: GpuArea) anyerror!void {
                    const typed_target: TargetPtr = if (TargetPtr == *anyopaque)
                        target
                    else
                        @ptrCast(@alignCast(target));
                    return f(@as(Ctx, @ptrCast(@alignCast(@constCast(c)))), typed_target, area);
                }
            }.call,
            .area = .{ .viewport = vp, .scissor = scissor, .fills = options.fills },
        });
    }

    /// As `gpuWith`, and drawn with `direct` instead of `f` when the frame
    /// is drawn straight into the window on the GPU (see `gfx.GpuDraw.direct`).
    pub fn gpuWithDirect(p: *Painter, options: GpuOptions, ctx: anytype, comptime f: anytype, comptime direct: anytype) void {
        const Ctx = @TypeOf(ctx);
        const before = p.ui.segments.items.len;
        p.gpuWith(options, ctx, f);
        if (p.ui.segments.items.len == before) return;
        p.ui.segments.items[before].gpu.direct = struct {
            fn call(c: *const anyopaque, backend: gfx.RenderBackend, frame: *const anyopaque, area: GpuArea) anyerror!bool {
                return direct(@as(Ctx, @ptrCast(@alignCast(@constCast(c)))), backend, frame, area);
            }
        }.call;
    }

    fn boxRect(p: *const Painter) Rect {
        return .{ .x = p.origin[0], .y = p.origin[1], .w = p.node.size.w, .h = p.node.size.h };
    }

    /// Paints a node (laid out this frame) and everything below it.
    pub fn paintNode(p: *Painter, n: *Node) void {
        if (n.laid_out != p.ui.frame_no) return;
        const saved_origin = p.origin;
        const saved_clip = p.clip;
        const saved_node = p.node;
        defer {
            p.origin = saved_origin;
            p.clip = saved_clip;
            p.node = saved_node;
        }
        p.node = n;
        p.origin = .{ p.origin[0] + n.offset[0], p.origin[1] + n.offset[1] };
        const box = p.boxRect();
        if (p.clip) |c| {
            const visible = intersect(c, box).?;
            if (visible.w <= 0 or visible.h <= 0) return;
        }
        const overflowing = n.overflow.any();
        if (overflowing or n.widget.vtable.clips_children) p.clip = intersect(p.clip, box);
        if (p.clip) |c| if (c.w <= 0 or c.h <= 0) return;

        var rec: gfx.Record = .{};
        rec.hash.update(std.mem.asBytes(&p.ui.paint_order));
        p.ui.paint_order += 1;
        const saved_rec = p.rec;
        defer p.rec = saved_rec;
        p.rec = &rec;

        const vt = n.widget.vtable;
        if (vt.paint) |f| f(n.widget.ptr, n, p);
        for (n.children.items) |ch| p.paintNode(ch);
        p.node = n;
        p.rec = &rec;
        if (vt.paint_over) |f| f(n.widget.ptr, n, p);
        if (overflowing) p.paintOverflow(n, box);
        if (p.track_damage) p.ui.damage.painted(n, &rec);
    }

    /// Stripes along each edge that something reaches past.
    fn paintOverflow(p: *Painter, n: *Node, box: Rect) void {
        const o = n.overflow;
        const dx = @min(stripe_depth, box.w);
        const dy = @min(stripe_depth, box.h);
        if (o.left > 0) p.stripes(.{ .x = box.x, .y = box.y, .w = dx, .h = box.h });
        if (o.right > 0) p.stripes(.{ .x = box.x + box.w - dx, .y = box.y, .w = dx, .h = box.h });
        if (o.top > 0) p.stripes(.{ .x = box.x, .y = box.y, .w = box.w, .h = dy });
        if (o.bottom > 0) p.stripes(.{ .x = box.x, .y = box.y + box.h - dy, .w = box.w, .h = dy });
    }

    /// Diagonal black and yellow stripes over `r` (in logical frame pixels).
    pub fn stripes(p: *Painter, r: Rect) void {
        const clip = intersect(p.clip, r) orelse return;
        if (clip.w <= 0 or clip.h <= 0) return;
        const c = p.ui.currentCanvas();
        c.setOrigin(.{ 0, 0 });
        c.clip = scaleRect(clip, c.scale);
        c.recorder = p.rec;
        c.fillRect(r, stripe_colors[1]);
        const half = stripe_period / 2;
        var x = @floor((r.x - r.h) / stripe_period) * stripe_period;
        while (x < r.x + r.w) : (x += stripe_period) {
            c.fillPolygon(&.{ .{ x, r.y + r.h }, .{ x + r.h, r.y }, .{ x + r.h + half, r.y }, .{ x + half, r.y + r.h } }, stripe_colors[0]);
        }
    }
};

fn scaleRect(r: Rect, s: f32) Rect {
    return .{ .x = r.x * s, .y = r.y * s, .w = r.w * s, .h = r.h * s };
}

pub fn intersect(a: ?Rect, b: Rect) ?Rect {
    const r = a orelse return b;
    const x0 = @max(r.x, b.x);
    const y0 = @max(r.y, b.y);
    const x1 = @min(r.x + r.w, b.x + b.w);
    const y1 = @min(r.y + r.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0), .h = @max(y1 - y0, 0) };
}

/// Whole pixels covering `r`, or null if it is empty.
fn viewport(r: Rect) ?gfx.Viewport {
    const x0 = @floor(r.x);
    const y0 = @floor(r.y);
    const x1 = @ceil(r.x + r.w);
    const y1 = @ceil(r.y + r.h);
    if (!(x1 > x0 and y1 > y0) or @abs(x0) > 1e6 or @abs(y0) > 1e6 or x1 - x0 > 1e6 or y1 - y0 > 1e6) return null;
    return .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .width = @intFromFloat(x1 - x0), .height = @intFromFloat(y1 - y0) };
}
