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
    const uniform_color = tri[0][2] == tri[1][2] and tri[1][2] == tri[2][2] and
        tri[0][3] == tri[1][3] and tri[1][3] == tri[2][3] and
        tri[0][4] == tri[1][4] and tri[1][4] == tri[2][4];
    const flat_argb = packArgb(tri[0][2], tri[0][3], tri[0][4], 1.0);

    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[@as(usize, @intCast(y)) * stride ..];
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        var x = x0;
        while (x < x1) : (x += 1) {
            const c_ = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, cy };
            const w = barycentric(p, area, c_) orelse continue;
            if (uniform_color) {
                row[@intCast(x)] = flat_argb;
            } else {
                const inv_sum = 1.0 / (w[0] + w[1] + w[2]);
                const r = (w[0] * tri[0][2] + w[1] * tri[1][2] + w[2] * tri[2][2]) * inv_sum;
                const g = (w[0] * tri[0][3] + w[1] * tri[1][3] + w[2] * tri[2][3]) * inv_sum;
                const b = (w[0] * tri[0][4] + w[1] * tri[1][4] + w[2] * tri[2][4]) * inv_sum;
                row[@intCast(x)] = packArgb(r, g, b, 1.0);
            }
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
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[@as(usize, @intCast(y)) * stride ..];
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        var x = x0;
        while (x < x1) : (x += 1) {
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
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[@as(usize, @intCast(y)) * stride ..];
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        var x = x0;
        while (x < x1) : (x += 1) {
            const c_ = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, cy };
            const w = barycentric(p, area, c_) orelse continue;
            const inv_sum = 1.0 / (w[0] + w[1] + w[2]);
            const lx = (w[0] * tri[0][2] + w[1] * tri[1][2] + w[2] * tri[2][2]) * inv_sum;
            const ly = (w[0] * tri[0][3] + w[1] * tri[1][3] + w[2] * tri[2][3]) * inv_sum;
            const hw = (w[0] * tri[0][4] + w[1] * tri[1][4] + w[2] * tri[2][4]) * inv_sum;
            const hh = (w[0] * tri[0][5] + w[1] * tri[1][5] + w[2] * tri[2][5]) * inv_sum;
            const radius = (w[0] * tri[0][6] + w[1] * tri[1][6] + w[2] * tri[2][6]) * inv_sum;
            const stroke = (w[0] * tri[0][7] + w[1] * tri[1][7] + w[2] * tri[2][7]) * inv_sum;
            const r = (w[0] * tri[0][8] + w[1] * tri[1][8] + w[2] * tri[2][8]) * inv_sum;
            const g = (w[0] * tri[0][9] + w[1] * tri[1][9] + w[2] * tri[2][9]) * inv_sum;
            const b = (w[0] * tri[0][10] + w[1] * tri[1][10] + w[2] * tri[2][10]) * inv_sum;
            const a = (w[0] * tri[0][11] + w[1] * tri[1][11] + w[2] * tri[2][11]) * inv_sum;

            const ax = @abs(lx);
            const ay = @abs(ly);
            const qx = ax - (hw - radius);
            const qy = ay - (hh - radius);
            const mx = @max(qx, 0.0);
            const my = @max(qy, 0.0);
            const d = @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0.0) - radius;
            const sx = ax - hw;
            const sy = ay - hh;
            const cov = shapeCoverage(d, sx, sy, 0.0) - shapeCoverage(d, sx, sy, stroke);
            if (cov > 0.0) {
                const ux: usize = @intCast(x);
                row[ux] = blendOver(row[ux], r, g, b, a * cov);
            }
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

    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[@as(usize, @intCast(y)) * stride ..];
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        var x = x0;
        while (x < x1) : (x += 1) {
            const c_ = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, cy };
            const w = barycentric(p, area, c_) orelse continue;
            const inv_sum = 1.0 / (w[0] + w[1] + w[2]);
            const u = (w[0] * tri[0][2] + w[1] * tri[1][2] + w[2] * tri[2][2]) * inv_sum;
            const v = (w[0] * tri[0][3] + w[1] * tri[1][3] + w[2] * tri[2][3]) * inv_sum;
            const r = (w[0] * tri[0][4] + w[1] * tri[1][4] + w[2] * tri[2][4]) * inv_sum;
            const g = (w[0] * tri[0][5] + w[1] * tri[1][5] + w[2] * tri[2][5]) * inv_sum;
            const b = (w[0] * tri[0][6] + w[1] * tri[1][6] + w[2] * tri[2][6]) * inv_sum;
            const a = (w[0] * tri[0][7] + w[1] * tri[1][7] + w[2] * tri[2][7]) * inv_sum;

            const tx: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(u * aw_f))), 0, max_tx));
            const ty: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(v * ah_f))), 0, max_ty));
            const cov_u8 = atlas.pixels[ty * atlas_mod.width + tx];
            if (cov_u8 > 0) {
                const cov = @as(f32, @floatFromInt(cov_u8)) / 255.0;
                const ux: usize = @intCast(x);
                row[ux] = blendOver(row[ux], r, g, b, a * cov);
            }
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

    var y = y0;
    while (y < y1) : (y += 1) {
        const row = pixels[@as(usize, @intCast(y)) * stride ..];
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        var x = x0;
        while (x < x1) : (x += 1) {
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

inline fn blendOver(dst: u32, r: f32, g: f32, b: f32, a: f32) u32 {
    const alpha = std.math.clamp(a, 0.0, 1.0);
    if (alpha <= 0.0) return dst;
    const sr: u32 = @intFromFloat(@round(std.math.clamp(r, 0.0, 1.0) * 255.0));
    const sg: u32 = @intFromFloat(@round(std.math.clamp(g, 0.0, 1.0) * 255.0));
    const sb: u32 = @intFromFloat(@round(std.math.clamp(b, 0.0, 1.0) * 255.0));
    const sa: u32 = @intFromFloat(@round(alpha * 255.0));
    if (sa == 0) return dst;
    if (sa == 255) return 0xff000000 | (sr << 16) | (sg << 8) | sb;
    const da = (dst >> 24) & 0xff;
    const inv_a = 255 - sa;
    if (da == 255) {
        // Fast path: opaque destination → result is always fully opaque,
        // and premultiplied == straight so the simpler integer formula applies.
        const out_r = (sr * sa + ((dst >> 16) & 0xff) * inv_a + 127) / 255;
        const out_g = (sg * sa + ((dst >> 8) & 0xff) * inv_a + 127) / 255;
        const out_b = (sb * sa + (dst & 0xff) * inv_a + 127) / 255;
        return 0xff000000 | (out_r << 16) | (out_g << 8) | out_b;
    }
    // General case: Porter-Duff "over" with straight alpha.  The previous
    // integer formula used `dr * inv_a` instead of `dr * da * inv_a / 255`,
    // which is only correct when da=255 (handled above).
    const sa_f = alpha;
    const da_f = @as(f32, @floatFromInt(da)) / 255.0;
    const out_a_f = sa_f + da_f * (1.0 - sa_f);
    if (out_a_f <= 0.0) return 0;
    const da_inv_sa = da_f * (1.0 - sa_f);
    const out_r_f = (std.math.clamp(r, 0.0, 1.0) * sa_f + @as(f32, @floatFromInt((dst >> 16) & 0xff)) / 255.0 * da_inv_sa) / out_a_f;
    const out_g_f = (std.math.clamp(g, 0.0, 1.0) * sa_f + @as(f32, @floatFromInt((dst >> 8) & 0xff)) / 255.0 * da_inv_sa) / out_a_f;
    const out_b_f = (std.math.clamp(b, 0.0, 1.0) * sa_f + @as(f32, @floatFromInt(dst & 0xff)) / 255.0 * da_inv_sa) / out_a_f;
    return (@as(u32, @intFromFloat(@round(out_a_f * 255.0))) << 24) |
        (@as(u32, @intFromFloat(@round(std.math.clamp(out_r_f, 0.0, 1.0) * 255.0))) << 16) |
        (@as(u32, @intFromFloat(@round(std.math.clamp(out_g_f, 0.0, 1.0) * 255.0))) << 8) |
        @as(u32, @intFromFloat(@round(std.math.clamp(out_b_f, 0.0, 1.0) * 255.0)));
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
