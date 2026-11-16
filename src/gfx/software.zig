//! Software 2D renderer: rasterizes `Canvas` batches on the CPU into a 32-bit
//! `0xAARRGGBB` pixel buffer (`Image`), using the exact same SDF rounded-rect
//! coverage, top-left triangle fill rule, and source-over blending as the
//! GPU backends.
//!
//! Can be used standalone (`software.render(&canvas, img)`) or wrapped as a
//! `gfx.Renderer` (`SoftwareRenderer.renderer()`).

const std = @import("std");
const font = @import("font");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");
const atlas_mod = @import("atlas.zig");
const renderer_mod = @import("renderer.zig");

const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;
const Viewport = renderer_mod.Viewport;

/// A 32-bit `0xAARRGGBB` pixel buffer target for software rendering.
pub const Image = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    /// Row stride in pixels (0 defaults to `width`).
    stride: u32 = 0,

    pub inline fn rowStride(img: Image) usize {
        return if (img.stride == 0) img.width else img.stride;
    }

    pub fn at(img: Image, x: u32, y: u32) u32 {
        return img.pixels[@as(usize, y) * img.rowStride() + x];
    }

    pub fn clear(img: Image, color: u32) void {
        const s = img.rowStride();
        if (s == img.width) {
            @memset(img.pixels[0 .. @as(usize, img.width) * img.height], color);
        } else {
            for (0..img.height) |y| {
                @memset(img.pixels[y * s ..][0..img.width], color);
            }
        }
    }

    pub fn clearDamage(img: Image, damage: ?[]const Viewport, color: u32) void {
        const list = damage orelse {
            img.clear(color);
            return;
        };
        const s = img.rowStride();
        for (list) |vp| {
            const x0: usize = @intCast(@max(vp.x, 0));
            const y0: usize = @intCast(@max(vp.y, 0));
            const x1: usize = @intCast(@min(@max(vp.x + @as(i32, @intCast(vp.width)), 0), @as(i32, @intCast(img.width))));
            const y1: usize = @intCast(@min(@max(vp.y + @as(i32, @intCast(vp.height)), 0), @as(i32, @intCast(img.height))));
            if (x0 >= x1 or y0 >= y1) continue;
            for (y0..y1) |y| {
                @memset(img.pixels[y * s + x0 .. y * s + x1], color);
            }
        }
    }
    pub fn clearViewports(img: Image, color: u32, viewports: []const Viewport) void {
        img.clearDamage(viewports, color);
    }
};

/// Software implementation of `gfx.Renderer`. Target passed to `record` or
/// `Renderer.renderSegments` is `*const Image` or `*Image`.
pub const SoftwareRenderer = struct {
    pub const backend: renderer_mod.RenderBackend = .software;

    pub fn init() SoftwareRenderer {
        return .{};
    }

    pub fn deinit(_: *SoftwareRenderer) void {}

    pub fn renderer(self: *SoftwareRenderer) renderer_mod.Renderer {
        return .of(self);
    }

    pub fn prepare(_: *SoftwareRenderer, _: []const *const Canvas) !void {}

    pub fn record(_: *SoftwareRenderer, c: *const Canvas, target: *const Image, damage: ?[]const Viewport) !void {
        try renderWithDamage(c, target.*, damage);
    }

    pub fn draw(_: *SoftwareRenderer, c: *const Canvas, target: *const Image) !void {
        try renderWithDamage(c, target.*, null);
    }
};

/// Renders `c` into `img` across the whole buffer.
pub fn render(c: *const Canvas, img: Image) !void {
    return renderWithDamage(c, img, null);
}

/// Renders `c` into `img`, restricted to `damage` viewports when non-null.
pub fn renderWithDamage(c: *const Canvas, img: Image, damage: ?[]const Viewport) !void {
    if (img.width == 0 or img.height == 0) return;
    if (damage) |list| {
        if (list.len == 0) return;
        for (list) |vp| {
            renderClipped(c, img, vp);
        }
    } else {
        renderClipped(c, img, .{ .x = 0, .y = 0, .width = img.width, .height = img.height });
    }
}

fn renderClipped(c: *const Canvas, img: Image, region: Viewport) void {
    const f_w: f32 = @floatFromInt(img.width);
    const f_h: f32 = @floatFromInt(img.height);
    const stride = img.rowStride();

    const rx0: i32 = @max(region.x, 0);
    const ry0: i32 = @max(region.y, 0);
    const rx1: i32 = @min(region.x + @as(i32, @intCast(region.width)), @as(i32, @intCast(img.width)));
    const ry1: i32 = @min(region.y + @as(i32, @intCast(region.height)), @as(i32, @intCast(img.height)));
    if (rx0 >= rx1 or ry0 >= ry1) return;

    for (c.batches.items) |*b| {
        const floats = canvas_mod.floatsPerVertex(b.kind);
        const verts = b.floats.items;
        if (verts.len < 3 * floats) continue;

        var clip_x0 = rx0;
        var clip_y0 = ry0;
        var clip_x1 = rx1;
        var clip_y1 = ry1;
        if (b.clip) |clip| {
            clip_x0 = @max(clip_x0, @as(i32, @intFromFloat(@floor(clip.x))));
            clip_y0 = @max(clip_y0, @as(i32, @intFromFloat(@floor(clip.y))));
            clip_x1 = @min(clip_x1, @as(i32, @intFromFloat(@ceil(clip.x + clip.w))));
            clip_y1 = @min(clip_y1, @as(i32, @intFromFloat(@ceil(clip.y + clip.h))));
            if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) continue;
        }

        // Quick reject using batch bounds
        const bx0: i32 = @intFromFloat(@floor(b.bounds.x));
        const by0: i32 = @intFromFloat(@floor(b.bounds.y));
        const bx1: i32 = @intFromFloat(@ceil(b.bounds.x + b.bounds.w));
        const by1: i32 = @intFromFloat(@ceil(b.bounds.y + b.bounds.h));
        if (bx1 <= clip_x0 or bx0 >= clip_x1 or by1 <= clip_y0 or by0 >= clip_y1) continue;

        var t: usize = 0;
        while (t + 3 * floats <= verts.len) : (t += 3 * floats) {
            // Two triangles making a rectangle, upright and of one colour
            // (a box, a glyph): filled row by row, as a rectangle.
            if (b.kind != .shape and b.kind != .image and t + 6 * floats <= verts.len) {
                if (Rect.of(verts[t..][0 .. 6 * floats], floats, b.kind, f_w, f_h)) |r| {
                    r.fill(verts[t..][0..floats], b.kind, c.atlas, .{ clip_x0, clip_y0, clip_x1, clip_y1 }, img.pixels, stride);
                    t += 3 * floats;
                    continue;
                }
            }
            const tri = [3][]const f32{
                verts[t..][0..floats],
                verts[t + floats ..][0..floats],
                verts[t + 2 * floats ..][0..floats],
            };
            var p: [3][2]f32 = undefined;
            for (tri, &p) |vert, *q| {
                q.* = .{
                    (vert[0] + 1.0) * 0.5 * f_w,
                    (1.0 - vert[1]) * 0.5 * f_h,
                };
            }
            const area = edge(p[0], p[1], p[2]);
            if (area == 0) continue;

            var x0: i32 = @intFromFloat(@floor(@min(p[0][0], @min(p[1][0], p[2][0]))));
            var y0: i32 = @intFromFloat(@floor(@min(p[0][1], @min(p[1][1], p[2][1]))));
            var x1: i32 = @intFromFloat(@ceil(@max(p[0][0], @max(p[1][0], p[2][0]))));
            var y1: i32 = @intFromFloat(@ceil(@max(p[0][1], @max(p[1][1], p[2][1]))));
            x0 = @max(x0, clip_x0);
            y0 = @max(y0, clip_y0);
            x1 = @min(x1, clip_x1);
            y1 = @min(y1, clip_y1);
            if (x0 >= x1 or y0 >= y1) continue;

            switch (b.kind) {
                .@"opaque" => rasterizeOpaque(tri, p, area, x0, y0, x1, y1, img.pixels, stride),
                .solid => rasterizeSolid(tri, p, area, x0, y0, x1, y1, img.pixels, stride),
                .shape => rasterizeShape(tri, p, area, x0, y0, x1, y1, img.pixels, stride),
                .text => if (c.atlas) |atlas| rasterizeText(tri, p, area, x0, y0, x1, y1, atlas, img.pixels, stride),
                .image => if (b.image) |pic| rasterizeImage(tri, p, area, x0, y0, x1, y1, pic, img.pixels, stride),
            }
        }
    }
}

/// Two triangles of a batch that together are an upright rectangle (in
/// pixels), each half of it, of one colour (and, for a glyph, its texture
/// upright too): as triangles, its pixels are those whose centres are
/// in it, by the rule for pixels on an edge (the right and bottom edges'
/// are in, the left and top's not), and each is drawn once.
const Rect = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    /// A glyph's texture at the left and right, and top and bottom.
    u: [2]f32 = .{ 0, 0 },
    v: [2]f32 = .{ 0, 0 },

    fn of(v6: []const f32, floats: usize, kind: canvas_mod.BatchKind, f_w: f32, f_h: f32) ?Rect {
        const color: [2]usize = switch (kind) {
            .@"opaque" => .{ 2, 5 },
            .solid => .{ 2, 6 },
            .text => .{ 4, 8 },
            else => return null,
        };
        var pts: [6][2]f32 = undefined;
        for (&pts, 0..) |*q, i| {
            const vert = v6[i * floats ..][0..floats];
            q.* = .{ (vert[0] + 1.0) * 0.5 * f_w, (1.0 - vert[1]) * 0.5 * f_h };
            for (color[0]..color[1]) |k| if (vert[k] != v6[k]) return null;
        }
        var r: Rect = .{ .x0 = pts[0][0], .y0 = pts[0][1], .x1 = pts[0][0], .y1 = pts[0][1] };
        for (pts[1..]) |q| {
            r.x0 = @min(r.x0, q[0]);
            r.x1 = @max(r.x1, q[0]);
            r.y0 = @min(r.y0, q[1]);
            r.y1 = @max(r.y1, q[1]);
        }
        if (!(r.x0 < r.x1 and r.y0 < r.y1)) return null;
        // Each triangle three of the corners, and they lack opposite ones.
        var missing: [2]u2 = undefined;
        for (0..2) |half| {
            var seen: u4 = 0;
            for (pts[half * 3 ..][0..3]) |q| {
                const cx: u2 = if (q[0] == r.x0) 0 else if (q[0] == r.x1) 1 else return null;
                const cy: u2 = if (q[1] == r.y0) 0 else if (q[1] == r.y1) 1 else return null;
                seen |= @as(u4, 1) << (cy * 2 + cx);
            }
            if (@popCount(seen) != 3) return null;
            missing[half] = @intCast(@ctz(~seen));
        }
        if (missing[0] ^ missing[1] != 3) return null;
        if (kind == .text) {
            // The texture's u along x only, and v along y only.
            var have: [4]bool = @splat(false);
            for (pts, 0..) |q, i| {
                const vert = v6[i * floats ..][0..floats];
                const side: usize = if (q[0] == r.x0) 0 else 1;
                const top: usize = if (q[1] == r.y0) 0 else 1;
                if (have[side] and r.u[side] != vert[2]) return null;
                if (have[2 + top] and r.v[top] != vert[3]) return null;
                r.u[side] = vert[2];
                r.v[top] = vert[3];
                have[side] = true;
                have[2 + top] = true;
            }
        }
        return r;
    }

    fn fill(r: Rect, vert: []const f32, kind: canvas_mod.BatchKind, atlas: ?*const atlas_mod.Atlas, clip: [4]i32, pixels: []u32, stride: usize) void {
        const px0: i32 = @max(clip[0], @as(i32, @intFromFloat(@floor(r.x0 - 0.5))) + 1);
        const py0: i32 = @max(clip[1], @as(i32, @intFromFloat(@floor(r.y0 - 0.5))) + 1);
        const px1: i32 = @min(clip[2], @as(i32, @intFromFloat(@floor(r.x1 - 0.5))) + 1);
        const py1: i32 = @min(clip[3], @as(i32, @intFromFloat(@floor(r.y1 - 0.5))) + 1);
        if (px0 >= px1 or py0 >= py1) return;
        const xs: usize = @intCast(px0);
        const xe: usize = @intCast(px1);
        switch (kind) {
            .@"opaque" => {
                const argb = packArgb(vert[2], vert[3], vert[4], 1.0);
                var y = py0;
                while (y < py1) : (y += 1) @memset(pixels[@as(usize, @intCast(y)) * stride ..][xs..xe], argb);
            },
            .solid => {
                const src: Source = .of(vert[2], vert[3], vert[4]);
                var y = py0;
                while (y < py1) : (y += 1) blendSpan(pixels[@as(usize, @intCast(y)) * stride ..][xs..xe], src, vert[5]);
            },
            .text => {
                const atlas_ = atlas orelse return;
                const aw: f32 = @floatFromInt(atlas_mod.width);
                const ah: f32 = @floatFromInt(atlas_mod.height);
                const src: Source = .of(vert[4], vert[5], vert[6]);
                const alpha = vert[7];
                const du = (r.u[1] - r.u[0]) / (r.x1 - r.x0);
                const dv = (r.v[1] - r.v[0]) / (r.y1 - r.y0);
                // Whether each pixel along is the next texel along, well
                // inside it (so as the pixel's own sum would find).
                const tx0 = texelX(r.u[0], r.x0, du, aw, px0);
                const first = (r.u[0] + (@as(f32, @floatFromInt(px0)) + 0.5 - r.x0) * du) * aw;
                const frac = first - @floor(first);
                const one_to_one = du * aw == 1 and frac > 0.25 and frac < 0.75 and
                    tx0 + (xe - xs) <= atlas_mod.width and texelX(r.u[0], r.x0, du, aw, px1 - 1) == tx0 + (xe - xs - 1);
                var y = py0;
                while (y < py1) : (y += 1) {
                    const v = r.v[0] + (@as(f32, @floatFromInt(y)) + 0.5 - r.y0) * dv;
                    const ty: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(v * ah))), 0, atlas_mod.height - 1));
                    const atlas_row = atlas_.pixels[ty * atlas_mod.width ..][0..atlas_mod.width];
                    const row = pixels[@as(usize, @intCast(y)) * stride ..];
                    if (one_to_one) {
                        // A texel a pixel: along the atlas's row.
                        for (row[xs..xe], atlas_row[tx0..][0 .. xe - xs]) |*px, cov_u8| {
                            if (cov_u8 == 0) continue;
                            px.* = if (cov_u8 == 255 and alpha >= 1) src.rgb | 0xff000000 else blendSource(px.*, src, alpha * (@as(f32, @floatFromInt(cov_u8)) / 255.0));
                        }
                        continue;
                    }
                    var x = px0;
                    while (x < px1) : (x += 1) {
                        const cov_u8 = atlas_row[texelX(r.u[0], r.x0, du, aw, x)];
                        if (cov_u8 == 0) continue;
                        const ux: usize = @intCast(x);
                        row[ux] = if (cov_u8 == 255 and alpha >= 1) src.rgb | 0xff000000 else blendSource(row[ux], src, alpha * (@as(f32, @floatFromInt(cov_u8)) / 255.0));
                    }
                }
            },
            else => {},
        }
    }
};

/// The atlas's column at pixel column `x`, across a rectangle from `x_left`
/// (where it is at `u_left`, going `du` a pixel).
inline fn texelX(u_left: f32, x_left: f32, du: f32, aw: f32, x: i32) usize {
    const u = u_left + (@as(f32, @floatFromInt(x)) + 0.5 - x_left) * du;
    return @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(u * aw))), 0, atlas_mod.width - 1));
}

// Each rasterizer goes along the rows of the triangle's box, but only over
// the pixels in the triangle (`rowSpan`: found where its edges cross the
// row, and checked at its ends by `barycentric`, so it is the same pixels
// as testing each one). Where the triangle's colour (and a shape's size,
// radius and stroke) is the same at its three corners, as it is for any
// one shape, only what varies is interpolated, and the colour is made
// ready to blend once (`Source`); and the pixels well inside a filled
// shape are covered without working out its edge.

fn rasterizeOpaque(
    tri: [3][]const f32,
    p: [3][2]f32,
    area: f32,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    pixels: []u32,
    stride: usize,
) void {
    const uniform_color = uniformAttrs(tri, 2, 5);
    const flat_argb = packArgb(tri[0][2], tri[0][3], tri[0][4], 1.0);

    const edges: RowEdges = .of(p, area);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[@as(usize, @intCast(y)) * stride ..];
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        const span = rowSpan(p, area, &edges, cy, x0, x1);
        if (span[0] >= span[1]) continue;
        if (uniform_color) {
            @memset(row[@intCast(span[0])..@intCast(span[1])], flat_argb);
            continue;
        }
        var x = span[0];
        while (x < span[1]) : (x += 1) {
            const c_ = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, cy };
            const w = barycentric(p, area, c_) orelse continue;
            const inv_sum = 1.0 / (w[0] + w[1] + w[2]);
            const r = (w[0] * tri[0][2] + w[1] * tri[1][2] + w[2] * tri[2][2]) * inv_sum;
            const g = (w[0] * tri[0][3] + w[1] * tri[1][3] + w[2] * tri[2][3]) * inv_sum;
            const b = (w[0] * tri[0][4] + w[1] * tri[1][4] + w[2] * tri[2][4]) * inv_sum;
            row[@intCast(x)] = packArgb(r, g, b, 1.0);
        }
    }
}

fn rasterizeSolid(
    tri: [3][]const f32,
    p: [3][2]f32,
    area: f32,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    pixels: []u32,
    stride: usize,
) void {
    const uniform = uniformAttrs(tri, 2, 6);
    const src: Source = .of(tri[0][2], tri[0][3], tri[0][4]);
    const alpha = tri[0][5];
    const edges: RowEdges = .of(p, area);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[@as(usize, @intCast(y)) * stride ..];
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        const span = rowSpan(p, area, &edges, cy, x0, x1);
        if (span[0] >= span[1]) continue;
        if (uniform) {
            blendSpan(row[@intCast(span[0])..@intCast(span[1])], src, alpha);
            continue;
        }
        var x = span[0];
        while (x < span[1]) : (x += 1) {
            const c_ = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, cy };
            const w = barycentric(p, area, c_) orelse continue;
            const inv_sum = 1.0 / (w[0] + w[1] + w[2]);
            const r = (w[0] * tri[0][2] + w[1] * tri[1][2] + w[2] * tri[2][2]) * inv_sum;
            const g = (w[0] * tri[0][3] + w[1] * tri[1][3] + w[2] * tri[2][3]) * inv_sum;
            const b = (w[0] * tri[0][4] + w[1] * tri[1][4] + w[2] * tri[2][4]) * inv_sum;
            const a = (w[0] * tri[0][5] + w[1] * tri[1][5] + w[2] * tri[2][5]) * inv_sum;
            const ux: usize = @intCast(x);
            row[ux] = blendOver(row[ux], r, g, b, a);
        }
    }
}

fn shapeCoverage(d: f32, sx: f32, sy: f32, inset: f32) f32 {
    const by_distance = std.math.clamp(0.5 - (d + inset), 0.0, 1.0);
    const cx = std.math.clamp(0.5 - (sx + inset), 0.0, 1.0);
    const cy = std.math.clamp(0.5 - (sy + inset), 0.0, 1.0);
    return @min(by_distance, cx * cy);
}

/// How much of a pixel a rounded rectangle (or its stroke) covers, at
/// (`lx`, `ly`) from its middle.
inline fn shapeCover(lx: f32, ly: f32, hw: f32, hh: f32, radius: f32, stroke: f32) f32 {
    const ax = @abs(lx);
    const ay = @abs(ly);
    const qx = ax - (hw - radius);
    const qy = ay - (hh - radius);
    const mx = @max(qx, 0.0);
    const my = @max(qy, 0.0);
    const d = @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0.0) - radius;
    const sx = ax - hw;
    const sy = ay - hh;
    return shapeCoverage(d, sx, sy, 0.0) - shapeCoverage(d, sx, sy, stroke);
}

fn rasterizeShape(
    tri: [3][]const f32,
    p: [3][2]f32,
    area: f32,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    pixels: []u32,
    stride: usize,
) void {
    const uniform = uniformAttrs(tri, 4, 12);
    const src: Source = .of(tri[0][8], tri[0][9], tri[0][10]);
    const hw0 = tri[0][4];
    const hh0 = tri[0][5];
    const radius0 = tri[0][6];
    const stroke0 = tri[0][7];
    const alpha0 = tri[0][11];
    // A fill (its stroke wider than it is) covers all of a pixel at least
    // half a pixel inside its straight edges, clear of the corners' curves.
    const filled = stroke0 >= hw0 + hh0 + 1;
    const edges: RowEdges = .of(p, area);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[@as(usize, @intCast(y)) * stride ..];
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        const span = rowSpan(p, area, &edges, cy, x0, x1);
        var x = span[0];
        while (x < span[1]) : (x += 1) {
            const c_ = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, cy };
            const w = barycentric(p, area, c_) orelse continue;
            const inv_sum = 1.0 / (w[0] + w[1] + w[2]);
            const lx = (w[0] * tri[0][2] + w[1] * tri[1][2] + w[2] * tri[2][2]) * inv_sum;
            const ly = (w[0] * tri[0][3] + w[1] * tri[1][3] + w[2] * tri[2][3]) * inv_sum;
            const ux: usize = @intCast(x);
            if (uniform) {
                const ax = @abs(lx);
                const ay = @abs(ly);
                const inside = filled and ((ax <= hw0 - radius0 - 0.5 and ay <= hh0 - 0.5) or (ay <= hh0 - radius0 - 0.5 and ax <= hw0 - 0.5));
                const cov = if (inside) 1.0 else shapeCover(lx, ly, hw0, hh0, radius0, stroke0);
                if (cov > 0.0) row[ux] = blendSource(row[ux], src, alpha0 * cov);
                continue;
            }
            const hw = (w[0] * tri[0][4] + w[1] * tri[1][4] + w[2] * tri[2][4]) * inv_sum;
            const hh = (w[0] * tri[0][5] + w[1] * tri[1][5] + w[2] * tri[2][5]) * inv_sum;
            const radius = (w[0] * tri[0][6] + w[1] * tri[1][6] + w[2] * tri[2][6]) * inv_sum;
            const stroke = (w[0] * tri[0][7] + w[1] * tri[1][7] + w[2] * tri[2][7]) * inv_sum;
            const r = (w[0] * tri[0][8] + w[1] * tri[1][8] + w[2] * tri[2][8]) * inv_sum;
            const g = (w[0] * tri[0][9] + w[1] * tri[1][9] + w[2] * tri[2][9]) * inv_sum;
            const b = (w[0] * tri[0][10] + w[1] * tri[1][10] + w[2] * tri[2][10]) * inv_sum;
            const a = (w[0] * tri[0][11] + w[1] * tri[1][11] + w[2] * tri[2][11]) * inv_sum;
            const cov = shapeCover(lx, ly, hw, hh, radius, stroke);
            if (cov > 0.0) row[ux] = blendOver(row[ux], r, g, b, a * cov);
        }
    }
}

fn rasterizeText(
    tri: [3][]const f32,
    p: [3][2]f32,
    area: f32,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    atlas: *const atlas_mod.Atlas,
    pixels: []u32,
    stride: usize,
) void {
    const aw_f: f32 = @floatFromInt(atlas_mod.width);
    const ah_f: f32 = @floatFromInt(atlas_mod.height);
    const max_tx: i32 = @intCast(atlas_mod.width - 1);
    const max_ty: i32 = @intCast(atlas_mod.height - 1);
    const uniform = uniformAttrs(tri, 4, 8);
    const src: Source = .of(tri[0][4], tri[0][5], tri[0][6]);
    const alpha = tri[0][7];

    const edges: RowEdges = .of(p, area);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[@as(usize, @intCast(y)) * stride ..];
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        const span = rowSpan(p, area, &edges, cy, x0, x1);
        const at = atlasAt(tri, p, area, @as(f32, @floatFromInt(span[0])) + 0.5, cy, aw_f, ah_f);
        const next = atlasAt(tri, p, area, @as(f32, @floatFromInt(span[0])) + 1.5, cy, aw_f, ah_f);
        if (uniform and span[0] < span[1] and next[1] == at[1]) {
            // The span's pixels are all in the triangle (its ends are, and
            // it is convex), and on one row of the atlas (the glyph is
            // upright): its texels, stepped along the row.
            const du = next[0] - at[0];
            const ty: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(at[1]))), 0, max_ty));
            const atlas_row = atlas.pixels[ty * atlas_mod.width ..][0..atlas_mod.width];
            var u = at[0];
            var x = span[0];
            while (x < span[1]) : ({
                x += 1;
                u += du;
            }) {
                const tx: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(u))), 0, max_tx));
                const cov_u8 = atlas_row[tx];
                if (cov_u8 == 0) continue;
                const ux: usize = @intCast(x);
                row[ux] = if (cov_u8 == 255 and alpha >= 1) src.rgb | 0xff000000 else blendSource(row[ux], src, alpha * (@as(f32, @floatFromInt(cov_u8)) / 255.0));
            }
            continue;
        }
        var x = span[0];
        while (x < span[1]) : (x += 1) {
            const c_ = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, cy };
            const w = barycentric(p, area, c_) orelse continue;
            const inv_sum = 1.0 / (w[0] + w[1] + w[2]);
            const u = (w[0] * tri[0][2] + w[1] * tri[1][2] + w[2] * tri[2][2]) * inv_sum;
            const v = (w[0] * tri[0][3] + w[1] * tri[1][3] + w[2] * tri[2][3]) * inv_sum;
            const tx: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(u * aw_f))), 0, max_tx));
            const ty: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(v * ah_f))), 0, max_ty));
            const cov_u8 = atlas.pixels[ty * atlas_mod.width + tx];
            if (cov_u8 == 0) continue;
            const cov = @as(f32, @floatFromInt(cov_u8)) / 255.0;
            const ux: usize = @intCast(x);
            if (uniform) {
                row[ux] = blendSource(row[ux], src, alpha * cov);
                continue;
            }
            const r = (w[0] * tri[0][4] + w[1] * tri[1][4] + w[2] * tri[2][4]) * inv_sum;
            const g = (w[0] * tri[0][5] + w[1] * tri[1][5] + w[2] * tri[2][5]) * inv_sum;
            const b = (w[0] * tri[0][6] + w[1] * tri[1][6] + w[2] * tri[2][6]) * inv_sum;
            const a = (w[0] * tri[0][7] + w[1] * tri[1][7] + w[2] * tri[2][7]) * inv_sum;
            row[ux] = blendOver(row[ux], r, g, b, a * cov);
        }
    }
}

fn rasterizeImage(
    tri: [3][]const f32,
    p: [3][2]f32,
    area: f32,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    pic: *const canvas_mod.Image,
    pixels: []u32,
    stride: usize,
) void {
    if (pic.width == 0 or pic.height == 0) return;
    const pw_f: f32 = @floatFromInt(pic.width);
    const ph_f: f32 = @floatFromInt(pic.height);
    const max_tx: i32 = @intCast(pic.width - 1);
    const max_ty: i32 = @intCast(pic.height - 1);

    const edges: RowEdges = .of(p, area);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[@as(usize, @intCast(y)) * stride ..];
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        const span = rowSpan(p, area, &edges, cy, x0, x1);
        var x = span[0];
        while (x < span[1]) : (x += 1) {
            const c_ = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, cy };
            const w = barycentric(p, area, c_) orelse continue;
            const inv_sum = 1.0 / (w[0] + w[1] + w[2]);
            const u = (w[0] * tri[0][2] + w[1] * tri[1][2] + w[2] * tri[2][2]) * inv_sum;
            const v = (w[0] * tri[0][3] + w[1] * tri[1][3] + w[2] * tri[2][3]) * inv_sum;
            const vr = (w[0] * tri[0][4] + w[1] * tri[1][4] + w[2] * tri[2][4]) * inv_sum;
            const vg = (w[0] * tri[0][5] + w[1] * tri[1][5] + w[2] * tri[2][5]) * inv_sum;
            const vb = (w[0] * tri[0][6] + w[1] * tri[1][6] + w[2] * tri[2][6]) * inv_sum;
            const va = (w[0] * tri[0][7] + w[1] * tri[1][7] + w[2] * tri[2][7]) * inv_sum;

            const tx: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(u * pw_f))), 0, max_tx));
            const ty: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(v * ph_f))), 0, max_ty));
            const texel = pic.pixels[ty * pic.width + tx];
            const tr = @as(f32, @floatFromInt((texel >> 16) & 0xff)) / 255.0;
            const tg = @as(f32, @floatFromInt((texel >> 8) & 0xff)) / 255.0;
            const tb = @as(f32, @floatFromInt(texel & 0xff)) / 255.0;
            const ta = @as(f32, @floatFromInt((texel >> 24) & 0xff)) / 255.0;

            const ux: usize = @intCast(x);
            row[ux] = blendOver(row[ux], tr * vr, tg * vg, tb * vb, ta * va);
        }
    }
}

/// Whether the vertex values `from` to `to` are the same at the triangle's
/// three corners.
inline fn uniformAttrs(tri: [3][]const f32, comptime from: usize, comptime to: usize) bool {
    inline for (from..to) |i| {
        if (tri[0][i] != tri[1][i] or tri[1][i] != tri[2][i]) return false;
    }
    return true;
}

/// A triangle's edges, as where each crosses a row: worked out once, for
/// `rowSpan`'s guess at each row's span.
const RowEdges = struct {
    /// Where the edge is at y = 0, and how far it goes along x for each
    /// one down.
    x_at_0: [3]f32,
    dx_dy: [3]f32,
    /// Which side of the edge is inside: its right (+1, the edge bounds
    /// the span on the left), its left (-1), or, for a level edge,
    /// 0 (`level` then says where it is and which way is inside).
    side: [3]f32,
    level: [3][2]f32,

    fn of(p: [3][2]f32, area: f32) RowEdges {
        var r: RowEdges = undefined;
        const s = std.math.sign(area);
        inline for (0..3) |k| {
            const a = p[(k + 1) % 3];
            const b = p[(k + 2) % 3];
            const dy = b[1] - a[1];
            // The edge function's change along x.
            r.side[k] = std.math.sign(-dy * s);
            if (dy == 0) {
                r.x_at_0[k] = 0;
                r.dx_dy[k] = 0;
                r.level[k] = .{ a[1], (b[0] - a[0]) * s };
            } else {
                r.dx_dy[k] = (b[0] - a[0]) / dy;
                r.x_at_0[k] = a[0] - a[1] * r.dx_dy[k];
                r.level[k] = .{ 0, 0 };
            }
        }
        return r;
    }
};

/// The pixels in the triangle on the row at `cy`, between `x0` and `x1`:
/// guessed from where its edges cross the row, then checked at its ends,
/// so they are exactly those whose centres `barycentric` finds in it.
inline fn rowSpan(p: [3][2]f32, area: f32, edges: *const RowEdges, cy: f32, x0: i32, x1: i32) [2]i32 {
    var lo: f32 = @floatFromInt(x0);
    var hi: f32 = @floatFromInt(x1);
    inline for (0..3) |k| {
        if (edges.side[k] == 0) {
            if (edges.level[k][1] * (cy - edges.level[k][0]) < 0) return .{ x0, x0 };
        } else {
            // Where the edge crosses, as a pixel's left side.
            const at = edges.x_at_0[k] + cy * edges.dx_dy[k] - 0.5;
            if (edges.side[k] > 0) lo = @max(lo, at) else hi = @min(hi, at + 1);
        }
    }
    if (!(lo < hi + 4)) return .{ x0, x0 };
    // From the guess, a pixel spare, to the ends: inward past what is
    // out, or, if the guess was short, outward over what is in.
    const in = struct {
        inline fn at(q: [3][2]f32, ar: f32, x: i32, y: f32) bool {
            return barycentric(q, ar, .{ @as(f32, @floatFromInt(x)) + 0.5, y }) != null;
        }
    }.at;
    var start: i32 = @intFromFloat(@max(@floor(lo) - 1, @as(f32, @floatFromInt(x0))));
    var end: i32 = @intFromFloat(@min(@ceil(hi) + 1, @as(f32, @floatFromInt(x1))));
    if (start >= end) return .{ x0, x0 };
    if (in(p, area, start, cy)) {
        while (start > x0 and in(p, area, start - 1, cy)) start -= 1;
    } else {
        start += 1;
        while (start < end and !in(p, area, start, cy)) start += 1;
        if (start == end) return .{ x0, x0 };
    }
    if (in(p, area, end - 1, cy)) {
        while (end < x1 and in(p, area, end, cy)) end += 1;
    } else {
        end -= 1;
        while (end > start and !in(p, area, end - 1, cy)) end -= 1;
    }
    return .{ start, end };
}

/// Where in the atlas (in texels) the triangle's texture is at (`x`, `y`).
inline fn atlasAt(tri: [3][]const f32, p: [3][2]f32, area: f32, x: f32, y: f32, aw: f32, ah: f32) [2]f32 {
    var w: [3]f32 = undefined;
    const s = std.math.sign(area);
    inline for (0..3) |k| w[k] = canonicalEdge(p[(k + 1) % 3], p[(k + 2) % 3], .{ x, y }) * s;
    const inv_sum = 1.0 / (w[0] + w[1] + w[2]);
    return .{
        (w[0] * tri[0][2] + w[1] * tri[1][2] + w[2] * tri[2][2]) * inv_sum * aw,
        (w[0] * tri[0][3] + w[1] * tri[1][3] + w[2] * tri[2][3]) * inv_sum * ah,
    };
}

inline fn barycentric(p: [3][2]f32, area: f32, c_: [2]f32) ?[3]f32 {
    var w: [3]f32 = undefined;
    const s = std.math.sign(area);
    inline for (0..3) |k| {
        const a = p[(k + 1) % 3];
        const b = p[(k + 2) % 3];
        w[k] = canonicalEdge(a, b, c_) * s;
        if (w[k] < 0 or (w[k] == 0 and !topLeft(a, b, area))) return null;
    }
    return w;
}

inline fn canonicalEdge(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
    const swap = a[0] > b[0] or (a[0] == b[0] and a[1] > b[1]);
    return if (swap) -edge(b, a, c) else edge(a, b, c);
}

inline fn edge(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

/// Pixel centres_exactly on an edge belong to the triangle if the edge is
/// a top or left one (so a pixel on a shared edge is drawn once).
inline fn topLeft(a: [2]f32, b: [2]f32, area: f32) bool {
    const dx = (b[0] - a[0]) * std.math.sign(area);
    const dy = (b[1] - a[1]) * std.math.sign(area);
    return (dy == 0 and dx < 0) or dy > 0;
}

inline fn packArgb(r: f32, g: f32, b: f32, a: f32) u32 {
    const au: u32 = @intFromFloat(@round(std.math.clamp(a, 0.0, 1.0) * 255.0));
    const ru: u32 = @intFromFloat(@round(std.math.clamp(r, 0.0, 1.0) * 255.0));
    const gu: u32 = @intFromFloat(@round(std.math.clamp(g, 0.0, 1.0) * 255.0));
    const bu: u32 = @intFromFloat(@round(std.math.clamp(b, 0.0, 1.0) * 255.0));
    return (au << 24) | (ru << 16) | (gu << 8) | bu;
}

/// A colour to blend, made ready once: its channels clamped, and as bytes.
const Source = struct {
    r: f32,
    g: f32,
    b: f32,
    /// 0x00RRGGBB.
    rgb: u32,

    inline fn of(r: f32, g: f32, b: f32) Source {
        const cr = std.math.clamp(r, 0.0, 1.0);
        const cg = std.math.clamp(g, 0.0, 1.0);
        const cb = std.math.clamp(b, 0.0, 1.0);
        const sr: u32 = @intFromFloat(@round(cr * 255.0));
        const sg: u32 = @intFromFloat(@round(cg * 255.0));
        const sb: u32 = @intFromFloat(@round(cb * 255.0));
        return .{ .r = cr, .g = cg, .b = cb, .rgb = (sr << 16) | (sg << 8) | sb };
    }
};

inline fn blendOver(dst: u32, r: f32, g: f32, b: f32, a: f32) u32 {
    return blendSource(dst, .of(r, g, b), a);
}

/// `src`, `a` opaque, over `dst` (straight alpha, Porter-Duff "over").
inline fn blendSource(dst: u32, src: Source, a: f32) u32 {
    const alpha = std.math.clamp(a, 0.0, 1.0);
    if (alpha <= 0.0) return dst;
    const sa: u32 = @intFromFloat(@round(alpha * 255.0));
    if (sa == 0) return dst;
    if (sa == 255) return 0xff000000 | src.rgb;
    const da = (dst >> 24) & 0xff;
    // Over nothing: itself.
    if (da == 0) return (sa << 24) | src.rgb;
    const inv_a = 255 - sa;
    if (da == 255) {
        // An opaque destination: the result is opaque, and premultiplied is
        // straight, so whole numbers will do.
        const sr = (src.rgb >> 16) & 0xff;
        const sg = (src.rgb >> 8) & 0xff;
        const sb = src.rgb & 0xff;
        const out_r = (sr * sa + ((dst >> 16) & 0xff) * inv_a + 127) / 255;
        const out_g = (sg * sa + ((dst >> 8) & 0xff) * inv_a + 127) / 255;
        const out_b = (sb * sa + (dst & 0xff) * inv_a + 127) / 255;
        return 0xff000000 | (out_r << 16) | (out_g << 8) | out_b;
    }
    // Otherwise: "over" with straight alpha, the destination's own alpha
    // weighing its colour.
    const sa_f = alpha;
    const da_f = @as(f32, @floatFromInt(da)) / 255.0;
    const out_a_f = sa_f + da_f * (1.0 - sa_f);
    if (out_a_f <= 0.0) return 0;
    const da_inv_sa = da_f * (1.0 - sa_f);
    const out_r_f = (src.r * sa_f + @as(f32, @floatFromInt((dst >> 16) & 0xff)) / 255.0 * da_inv_sa) / out_a_f;
    const out_g_f = (src.g * sa_f + @as(f32, @floatFromInt((dst >> 8) & 0xff)) / 255.0 * da_inv_sa) / out_a_f;
    const out_b_f = (src.b * sa_f + @as(f32, @floatFromInt(dst & 0xff)) / 255.0 * da_inv_sa) / out_a_f;
    return (@as(u32, @intFromFloat(@round(out_a_f * 255.0))) << 24) |
        (@as(u32, @intFromFloat(@round(std.math.clamp(out_r_f, 0.0, 1.0) * 255.0))) << 16) |
        (@as(u32, @intFromFloat(@round(std.math.clamp(out_g_f, 0.0, 1.0) * 255.0))) << 8) |
        @as(u32, @intFromFloat(@round(std.math.clamp(out_b_f, 0.0, 1.0) * 255.0)));
}

/// `src`, `a` opaque, over each pixel of `row`: a run filled at once when
/// it covers what is there, or is drawn over nothing.
fn blendSpan(row: []u32, src: Source, a: f32) void {
    const alpha = std.math.clamp(a, 0.0, 1.0);
    if (alpha <= 0.0) return;
    const sa: u32 = @intFromFloat(@round(alpha * 255.0));
    if (sa == 0) return;
    if (sa == 255) return @memset(row, 0xff000000 | src.rgb);
    for (row) |*px| px.* = blendSource(px.*, src, a);
}

/// Writes the image as a binary PPM.
pub fn writePpm(img: Image, writer: anytype) !void {
    try writer.print("P6\n{d} {d}\n255\n", .{ img.width, img.height });
    const s = img.rowStride();
    for (0..img.height) |y| {
        for (img.pixels[y * s ..][0..img.width]) |px| {
            const rgb = [3]u8{ @truncate(px >> 16), @truncate(px >> 8), @truncate(px) };
            try writer.writeAll(&rgb);
        }
    }
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

fn channel(px: u32, shift: u5) i32 {
    return @intCast(px >> shift & 0xff);
}

fn expectNear(want: u32, got: u32, tolerance: i32) !void {
    for ([_]u5{ 0, 8, 16 }) |s| {
        const d = channel(want, s) - channel(got, s);
        if (d < -tolerance or d > tolerance) {
            std.debug.print("expected 0x{x:0>8}, got 0x{x:0>8}\n", .{ want, got });
            return error.TestExpectedEqual;
        }
    }
}

test "rounded rectangles: solid inside, clear outside, smooth corners and edges" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(64, 48);
    c.fillRoundedRect(.{ .x = 8, .y = 8, .w = 48, .h = 32 }, .all(10), Color.rgb(0xff0000));
    var pixels: [64 * 48]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 64, .height = 48 };
    try render(&c, img);
    // Inside, in the solid centre and in a corner cell.
    try expectNear(0xffff0000, img.at(32, 24), 1);
    try expectNear(0xffff0000, img.at(12, 14), 1);
    // Outside: beyond the corner's curve, and beside the rectangle.
    try expectNear(0xff000000, img.at(9, 9), 1);
    try expectNear(0xff000000, img.at(5, 24), 1);
    // The left edge at x = 8 runs between pixel columns: column 8 is
    // fully inside, column 7 fully outside.
    try expectNear(0xffff0000, img.at(8, 24), 1);
    try expectNear(0xff000000, img.at(7, 24), 1);
    // On the curve: partly covered.
    const curve = channel(img.at(10, 11), 16);
    try testing.expect(curve > 20 and curve < 235);
}

test "edges at half pixels are half covered, and blending mixes colours" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(32, 32);
    // Square edges through pixel centres: those pixels are half covered.
    c.fillRect(.{ .x = 4.5, .y = 4.5, .w = 20, .h = 20 }, Color.rgb(0xffffff));
    // A half-transparent blue square over part of it.
    c.fillRect(.{ .x = 16, .y = 16, .w = 10, .h = 10 }, Color.rgb(0x0000ff).withAlpha(0.5));
    var pixels: [32 * 32]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 32, .height = 32 };
    try render(&c, img);
    try expectNear(0xff808080, img.at(4, 10), 2);
    try expectNear(0xff808080, img.at(10, 4), 2);
    // A corner pixel: a quarter.
    try expectNear(0xff404040, img.at(4, 4), 3);
    // White under half blue; black under half blue.
    try expectNear(0xff8080ff, img.at(20, 20), 2);
    try expectNear(0xff000080, img.at(25, 25), 2);
}

test "strokes and polygons" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(40, 40);
    // A 2-pixel outline inside a 20x20 rounded square.
    c.strokeRoundedRect(.{ .x = 10, .y = 10, .w = 20, .h = 20 }, .all(4), 2, Color.rgb(0x00ff00));
    var pixels: [40 * 40]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 40, .height = 40 };
    try render(&c, img);
    try expectNear(0xff00ff00, img.at(10, 20), 1);
    try expectNear(0xff00ff00, img.at(11, 20), 1);
    try expectNear(0xff000000, img.at(12, 20), 1);
    try expectNear(0xff000000, img.at(20, 20), 1);
    try expectNear(0xff00ff00, img.at(20, 29), 1);

    // A triangle, filled: inside and outside.
    c.begin(40, 40);
    c.fillPolygon(&.{ .{ 5, 35 }, .{ 20, 5 }, .{ 35, 35 } }, Color.rgb(0xffffff));
    @memset(&pixels, 0xff000000);
    try render(&c, img);
    try expectNear(0xffffffff, img.at(20, 25), 1);
    try expectNear(0xff000000, img.at(5, 10), 1);
}

test "paths fill around their holes, and images bend to triangles" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(40, 40);
    c.fillPath(&.{ &.{ .{ 4, 4 }, .{ 36, 4 }, .{ 36, 36 }, .{ 4, 36 } }, &.{ .{ 12, 12 }, .{ 28, 12 }, .{ 28, 28 }, .{ 12, 28 } } }, Color.rgb(0xffffff));
    var pixels: [40 * 40]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 40, .height = 40 };
    try render(&c, img);
    try expectNear(0xffffffff, img.at(8, 20), 1);
    try expectNear(0xff000000, img.at(20, 20), 1);
    try expectNear(0xff000000, img.at(2, 20), 1);

    // The left half of a 2x1 image (red), on a triangle; the right half
    // (blue) on another, turned upside down.
    const pic = canvas_mod.Image.init(&.{ 0xffff0000, 0xff0000ff }, 2, 1);
    c.begin(40, 40);
    c.drawImageTriangles(&pic, &.{
        .{ 0, 0, 0, 0 },     .{ 20, 0, 0.5, 0 }, .{ 0, 20, 0, 1 },
        .{ 40, 40, 0.5, 0 }, .{ 20, 40, 1, 0 },  .{ 40, 20, 0.5, 1 },
    }, 1);
    @memset(&pixels, 0xff000000);
    try render(&c, img);
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(4, 4));
    try testing.expectEqual(@as(u32, 0xff000000), img.at(16, 16));
    try testing.expectEqual(@as(u32, 0xff0000ff), img.at(36, 36));
}

test "shaded triangles blend their colour by how much each corner has" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(40, 20);
    // White, none at the left and all at the right.
    c.fillShaded(&.{
        .{ 0, 0, 0 }, .{ 40, 0, 1 },  .{ 40, 20, 1 },
        .{ 0, 0, 0 }, .{ 40, 20, 1 }, .{ 0, 20, 0 },
    }, Color.rgb(0xffffff));
    var pixels: [40 * 20]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 40, .height = 20 };
    try render(&c, img);
    try expectNear(0xff000000, img.at(0, 10), 8);
    try expectNear(0xff808080, img.at(20, 10), 8);
    try expectNear(0xffffffff, img.at(39, 10), 8);
}

test "text matches the font renderer's own drawing" {
    const f = try font.Font.init(font.default_font_data);
    var atlas = try atlas_mod.Atlas.init(testing.allocator);
    defer atlas.deinit();
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(120, 40);
    const style: font.Style = .{ .font = &f, .size = 20 };
    const end = c.drawText(&atlas, style, 4.25, 28, "Kete", Color.rgb(0xffffff));
    try testing.expectApproxEqAbs(4.25 + font.measure(style, "Kete"), end, 0.001);
    var pixels: [120 * 40]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 120, .height = 40 };
    try render(&c, img);

    var cache = font.GlyphCache.init(testing.allocator);
    defer cache.deinit();
    var want: [120 * 40]u32 = @splat(0xff000000);
    _ = try font.draw(.{ .pixels = &want, .width = 120, .height = 40, .stride = 120 }, &cache, style, 4.25, 28, "Kete");
    var lit: u32 = 0;
    for (want, pixels) |w, g| {
        try expectNear(w, g, 1);
        lit += @intFromBool(g != 0xff000000);
    }
    try testing.expect(lit > 150);
}

test "text turned a quarter, a half or three quarters is the upright text turned, pixel for pixel" {
    const f = try font.Font.init(font.default_font_data);
    var atlas = try atlas_mod.Atlas.init(testing.allocator);
    defer atlas.deinit();
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    const n = 80;
    const style: font.Style = .{ .font = &f, .size = 16 };
    const width = font.measure(style, "Kg1");
    // Upright, its baseline from (10, 50) (and a quarter pixel along, for
    // the glyphs' steps).
    c.begin(n, n);
    _ = c.drawText(&atlas, style, 10.25, 50, "Kg1", Color.rgb(0xffffff));
    var upright: [n * n]u32 = @splat(0xff000000);
    try render(&c, .{ .pixels = &upright, .width = n, .height = n });
    var lit: u32 = 0;
    for (upright) |px| lit += @intFromBool(px != 0xff000000);
    try testing.expect(lit > 50);

    // Each way, from where the upright pixel (x, y) is turned to.
    const Case = struct { direction: Canvas.TextDirection, from: [2]f32, end: [2]f32 };
    const cases = [_]Case{
        .{ .direction = .up, .from = .{ 30, 69.75 }, .end = .{ 30, 69.75 - width } },
        .{ .direction = .left, .from = .{ 69.75, 30 }, .end = .{ 69.75 - width, 30 } },
        .{ .direction = .down, .from = .{ 50, 10.25 }, .end = .{ 50, 10.25 + width } },
    };
    for (cases) |case| {
        c.begin(n, n);
        const end = c.drawTextRunning(&atlas, style, case.from, case.direction, "Kg1", Color.rgb(0xffffff));
        try testing.expectApproxEqAbs(case.end[0], end[0], 0.001);
        try testing.expectApproxEqAbs(case.end[1], end[1], 0.001);
        var turned: [n * n]u32 = @splat(0xff000000);
        try render(&c, .{ .pixels = &turned, .width = n, .height = n });
        for (0..n) |y| for (0..n) |x| {
            // Along the text and across it, from the upright baseline's
            // start; then where that is, turned.
            const a = @as(i32, @intCast(x)) - 10;
            const b = @as(i32, @intCast(y)) - 50;
            const to: [2]i32 = switch (case.direction) {
                .up => .{ 30 + b, 69 - a },
                .left => .{ 69 - a, 30 - b - 1 },
                .down => .{ 50 - b - 1, 10 + a },
                .right => unreachable,
            };
            if (to[0] < 0 or to[1] < 0 or to[0] >= n or to[1] >= n) continue;
            try testing.expectEqual(upright[y * n + x], turned[@as(usize, @intCast(to[1])) * n + @as(usize, @intCast(to[0]))]);
        };
    }
}

test "images are drawn from their own textures, stretched, tinted by how opaque" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(64, 32);
    // Red, green / blue, translucent white.
    const pic = canvas_mod.Image.init(&.{ 0xffff0000, 0xff00ff00, 0xff0000ff, 0x80ffffff }, 2, 2);
    c.drawImage(&pic, .{ .x = 0, .y = 0, .w = 20, .h = 20 }, 1);
    // The same image again, half opaque: the same batch.
    c.drawImage(&pic, .{ .x = 30, .y = 0, .w = 20, .h = 20 }, 0.5);
    try testing.expectEqual(@as(usize, 1), c.batches.items.len);
    var pixels: [64 * 32]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 64, .height = 32 };
    try render(&c, img);
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(4, 4));
    try testing.expectEqual(@as(u32, 0xff00ff00), img.at(15, 4));
    try testing.expectEqual(@as(u32, 0xff0000ff), img.at(4, 15));
    try expectNear(0xff808080, img.at(15, 15), 1);
    // Half opaque: red over black, half way.
    try expectNear(0xff800000, img.at(34, 4), 1);
    // Outside it, nothing.
    try testing.expectEqual(@as(u32, 0xff000000), img.at(25, 4));
    try testing.expectEqual(@as(u32, 0xff000000), img.at(4, 25));
}

test "dashed lines are broken as their pattern says, and only the dashes in view are drawn" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    const n = 64;
    var pixels: [n * n]u32 = undefined;
    const img: Image = .{ .pixels = &pixels, .width = n, .height = n };
    const white = Color.rgb(0xffffff);
    const black: u32 = 0xff000000;

    // Dashes 6 long, 4 apart, along y = 10.
    c.begin(n, n);
    c.strokeDashedPolyline(&.{ .{ 2, 10 }, .{ 62, 10 } }, false, 2, .{ .pattern = &.{ 6, 4 } }, white);
    @memset(&pixels, black);
    try render(&c, img);
    for (0..60) |k| {
        const x = 2 + k;
        const on = k % 10 < 6;
        const px = pixels[9 * n + x];
        // Clear inside each dash and each gap (their ends are faded).
        if (k % 10 == 0 or k % 10 == 5 or k % 10 == 6 or k % 10 == 9) continue;
        try testing.expectEqual(if (on) @as(u32, 0xffffffff) else black, px);
    }

    // Dots: round, 8 apart.
    c.begin(n, n);
    c.strokeDashedPolyline(&.{ .{ 4, 30 }, .{ 60, 30 } }, false, 4, .{ .pattern = &.{ 0, 8 }, .cap = .round }, white);
    @memset(&pixels, black);
    try render(&c, img);
    try testing.expectEqual(@as(u32, 0xffffffff), pixels[29 * n + 4]);
    try testing.expectEqual(@as(u32, 0xffffffff), pixels[29 * n + 12]);
    try testing.expectEqual(black, pixels[29 * n + 8]);
    try testing.expectEqual(black, pixels[26 * n + 12]);

    // A dashed rectangle's edge is where a solid one's is: inside it.
    c.begin(n, n);
    c.strokeDashedRect(.{ .x = 10, .y = 10, .w = 40, .h = 40 }, 2, .{ .pattern = &.{ 4, 4 } }, white);
    @memset(&pixels, black);
    try render(&c, img);
    var lit: u32 = 0;
    for (12..48) |x| lit += @intFromBool(pixels[10 * n + x] == 0xffffffff);
    try testing.expect(lit > 10 and lit < 26);
    for (0..n) |x| try testing.expectEqual(black, pixels[9 * n + x]);

    // A line ten million pixels long through the canvas: only what is in
    // it is made (a few dashes' vertices, not millions).
    c.begin(n, n);
    c.strokeDashedPolyline(&.{ .{ -5_000_000, 40 }, .{ 5_000_000, 40 } }, false, 2, .{ .pattern = &.{ 2, 2 } }, white);
    var floats: usize = 0;
    for (c.batches.items) |*b| floats += b.floats.items.len;
    try testing.expect(floats > 0 and floats < 20_000);
}

test "a transform moves, scales and turns what is drawn" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    c.begin(64, 64);
    // Twice as big, about the square's middle (16, 16): 16 to 48.
    c.setTransform(canvas_mod.Affine.scaling(2, 2).about(.{ 16, 16 }).then(.translation(16, 16)));
    c.fillRect(.{ .x = 8, .y = 8, .w = 16, .h = 16 }, Color.rgb(0xff0000));
    var pixels: [64 * 64]u32 = @splat(0xff000000);
    const img: Image = .{ .pixels = &pixels, .width = 64, .height = 64 };
    try render(&c, img);
    try expectNear(0xffff0000, img.at(17, 17), 1);
    try expectNear(0xffff0000, img.at(46, 46), 1);
    try expectNear(0xff000000, img.at(14, 32), 1);
    try expectNear(0xff000000, img.at(49, 32), 1);

    // An eighth of a turn about its middle: a diamond, its corners
    // reaching out past the square's sides and its own corners clear.
    c.begin(64, 64);
    c.setTransform(canvas_mod.Affine.rotation(std.math.pi / 4.0).about(.{ 32, 32 }));
    c.fillRect(.{ .x = 16, .y = 16, .w = 32, .h = 32 }, Color.rgb(0xff0000));
    @memset(&pixels, 0xff000000);
    try render(&c, img);
    try expectNear(0xffff0000, img.at(32, 32), 1);
    try expectNear(0xffff0000, img.at(32, 12), 1);
    try expectNear(0xffff0000, img.at(12, 32), 1);
    try expectNear(0xff000000, img.at(17, 17), 1);
    try expectNear(0xff000000, img.at(46, 46), 1);
}
