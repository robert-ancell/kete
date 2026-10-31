//! Vertex layouts, SPIR-V shader blobs (compiled at build time from the Zig
//! shaders in `src/gfx/shaders/*.zig`), GLSL 330 fallback shader sources
//! (`src/gfx/shaders/*.vert` and `*.frag`), and the Metal Shading Language
//! source (`src/gfx/shaders/canvas.metal`) for Kete's 2D canvas batches:
//!
//! * `shape`: anti-aliased rounded rectangles, filled or stroked. Each
//!   vertex carries the rectangle: the fragment's position relative to its
//!   centre, its half size, corner radius and stroke width, and the colour.
//!   The fragment shader computes the signed distance to the rounded outline
//!   and turns it into coverage over one pixel.
//! * `solid`: triangles with a colour per vertex, for polygons and strokes
//!   whose anti-aliased edges are fringes fading to transparent.
//! * `opaque`: `solid` without blending, for triangles opaque all over
//!   (the insides of filled shapes, the cores of strokes).
//! * `text`: glyphs, their coverage from the single-channel glyph atlas
//!   texture.
//! * `image`: images, from their own RGBA textures (with the text vertices'
//!   layout: a texture position and a colour to tint them with).

const std = @import("std");

/// Floats per shape vertex: clip x, y; then local x, y, half width,
/// half height; radius, stroke width; then r, g, b, a.
pub const shape_floats = 12;
/// Floats per solid vertex: clip x, y; then r, g, b, a.
pub const solid_floats = 6;
/// Floats per text/image vertex: clip x, y; atlas u, v; then r, g, b, a.
pub const text_floats = 8;

pub const Attribute = struct {
    location: u32,
    components: u32,
    offset: u32,
};

pub const Layout = struct {
    vertex_stride: u32,
    attributes: []const Attribute,
};

pub const shape_layout: Layout = .{
    .vertex_stride = shape_floats * 4,
    .attributes = &.{
        .{ .location = 0, .components = 2, .offset = 0 },
        .{ .location = 1, .components = 4, .offset = 8 },
        .{ .location = 2, .components = 2, .offset = 24 },
        .{ .location = 3, .components = 4, .offset = 32 },
    },
};

/// Floats per window frame vertex: clip x, y; buffer pixel x, y; the
/// window's centre x, y and half size; radius, scale, mode, unused.
pub const window_floats = 12;

pub const window_layout: Layout = .{
    .vertex_stride = window_floats * 4,
    .attributes = &.{
        .{ .location = 0, .components = 2, .offset = 0 },
        .{ .location = 1, .components = 2, .offset = 8 },
        .{ .location = 2, .components = 4, .offset = 16 },
        .{ .location = 3, .components = 4, .offset = 32 },
    },
};

pub const solid_layout: Layout = .{
    .vertex_stride = solid_floats * 4,
    .attributes = &.{
        .{ .location = 0, .components = 2, .offset = 0 },
        .{ .location = 1, .components = 4, .offset = 8 },
    },
};

pub const text_layout: Layout = .{
    .vertex_stride = text_floats * 4,
    .attributes = &.{
        .{ .location = 0, .components = 2, .offset = 0 },
        .{ .location = 1, .components = 2, .offset = 8 },
        .{ .location = 2, .components = 4, .offset = 16 },
    },
};

// --- SPIR-V shaders (compiled from src/gfx/shaders/*.zig) -------------------

pub const shape_spv align(4) = @embedFile("shape.spv").*;
pub const solid_spv align(4) = @embedFile("solid.spv").*;
pub const text_spv align(4) = @embedFile("text.spv").*;
pub const image_spv align(4) = @embedFile("image.spv").*;
/// A window's shadow and rounded corners (`window.zig`).
pub const window_spv align(4) = @embedFile("window.spv").*;

pub const shape_gl_spv align(4) = @embedFile("shape_gl.spv").*;
pub const solid_gl_spv align(4) = @embedFile("solid_gl.spv").*;
pub const text_gl_spv align(4) = @embedFile("text_gl.spv").*;
pub const image_gl_spv align(4) = @embedFile("image_gl.spv").*;
pub const window_gl_spv align(4) = @embedFile("window_gl.spv").*;

// --- GLSL 330 fallback shaders (from src/gfx/shaders/*.vert / *.frag) -------

pub const glsl_shape_vs: [:0]const u8 = @embedFile("shaders/shape.vert");
pub const glsl_shape_fs: [:0]const u8 = @embedFile("shaders/shape.frag");
pub const glsl_solid_vs: [:0]const u8 = @embedFile("shaders/solid.vert");
pub const glsl_solid_fs: [:0]const u8 = @embedFile("shaders/solid.frag");
pub const glsl_text_vs: [:0]const u8 = @embedFile("shaders/text.vert");
pub const glsl_text_fs: [:0]const u8 = @embedFile("shaders/text.frag");
pub const glsl_image_fs: [:0]const u8 = @embedFile("shaders/image.frag");
pub const glsl_window_vs: [:0]const u8 = @embedFile("shaders/window.vert");
pub const glsl_window_fs: [:0]const u8 = @embedFile("shaders/window.frag");

// --- Metal Shading Language shaders (src/gfx/shaders/canvas.metal) -----------

/// All of them, with the entry points `shape_vs`, `shape_fs`, `solid_vs`,
/// `solid_fs`, `text_vs`, `text_fs` and `image_fs`.
pub const msl: [:0]const u8 = @embedFile("shaders/canvas.metal");

/// The DXBC (Direct3D 11) shaders, compiled from `shaders/canvas.hlsl` by
/// fxc when kete is built on Windows (empty with `-Dwindows-check`).
pub const dxbc = if (@import("builtin").os.tag == .windows) struct {
    pub const shape_vs = @embedFile("shape_vs.dxbc");
    pub const solid_vs = @embedFile("solid_vs.dxbc");
    pub const text_vs = @embedFile("text_vs.dxbc");
    pub const shape_ps = @embedFile("shape_ps.dxbc");
    pub const solid_ps = @embedFile("solid_ps.dxbc");
    pub const text_ps = @embedFile("text_ps.dxbc");
    pub const image_ps = @embedFile("image_ps.dxbc");
} else struct {};

test "vertex layouts match float counts and SPIR-V / GLSL shaders are valid" {
    for ([_]Layout{ shape_layout, solid_layout, text_layout }, [_]u32{ shape_floats, solid_floats, text_floats }) |layout, floats| {
        var total: u32 = 0;
        for (layout.attributes) |a| {
            try std.testing.expectEqual(total * 4, a.offset);
            total += a.components;
        }
        try std.testing.expectEqual(floats, total);
        try std.testing.expectEqual(floats * 4, layout.vertex_stride);
    }
    for ([_][]const u8{ &shape_spv, &solid_spv, &text_spv, &image_spv }) |spv| {
        try std.testing.expect(spv.len > 0 and spv.len % 4 == 0);
    }
    for ([_][:0]const u8{ glsl_shape_vs, glsl_shape_fs, glsl_solid_vs, glsl_solid_fs, glsl_text_vs, glsl_text_fs, glsl_image_fs, glsl_window_vs, glsl_window_fs }) |src| {
        try std.testing.expect(std.mem.startsWith(u8, src, "#version 330 core\n") or std.mem.startsWith(u8, src, "#version 330 core\r\n"));
    }
    for ([_][]const u8{ "shape_vs", "shape_fs", "solid_vs", "solid_fs", "text_vs", "text_fs", "image_fs" }) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, msl, entry) != null);
    }
}
