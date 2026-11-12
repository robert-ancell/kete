//! Presenting frames (`gfx.Frame`s) in a window with a renderer: on the GPU
//! straight into the window's buffer (a dmabuf on Wayland, or the Metal
//! layer on macOS) if they can, or else into its buffer on the CPU; only
//! what the buffer's age says has to be drawn, and then shown (only what
//! changed). It is done here and now, on the caller's thread.

const std = @import("std");
const gfx = @import("gfx");
const window_mod = @import("window.zig");

const Window = window_mod.Window;
const Viewport = gfx.Viewport;

pub const Presenter = struct {
    /// What draws the frames (none: they cannot be presented).
    renderer: ?gfx.Renderer = null,
    /// The renderer could not draw straight into the window's buffers, so
    /// frames are drawn into them on the CPU.
    no_direct: bool = false,

    /// Draws `frame` into the window's next buffer, and shows it.
    pub fn present(p: *Presenter, win: Window, frame: *const gfx.Frame) !void {
        const r = p.renderer orelse return error.NoRenderer;
        var uncovered_buf: [2][gfx.renderer.max_uncovered]Viewport = undefined;
        // On the GPU straight into the window's buffer (or Metal layer) if
        // they can, or else into the buffer on the CPU.
        if (p.directRenderer()) |dr| direct: {
            if (dr.hasDmabuf()) if (win.beginDmabufFrame()) |f| {
                const vps = frame.repaint(f.age);
                dr.renderDmabuf(frame.canvases, frame.segments, &f.target, frame.clear, gfx.renderer.uncovered(&uncovered_buf, vps, frame.segments), vps) catch {
                    p.no_direct = true;
                    break :direct;
                };
                f.finish(vps);
                return f.show(frame.damage.slice());
            };
            if (dr.hasD3D11()) if (win.beginD3D11Frame(dr.d3d11Device())) |f| {
                const vps = frame.repaint(f.age);
                dr.renderD3D11(frame.canvases, frame.segments, &f.target, frame.clear, gfx.renderer.uncovered(&uncovered_buf, vps, frame.segments), vps) catch {
                    p.no_direct = true;
                    break :direct;
                };
                f.finish(vps);
                return f.show(frame.damage.slice());
            };
            if (dr.hasMetal()) if (win.beginMetalFrame()) |f| {
                const vps = frame.repaint(f.age);
                dr.renderMetal(frame.canvases, frame.segments, &f.target, frame.clear, gfx.renderer.uncovered(&uncovered_buf, vps, frame.segments), vps) catch {
                    p.no_direct = true;
                    break :direct;
                };
                f.finish(vps);
                return f.show(frame.damage.slice());
            };
        }
        var f = try win.beginSoftwareFrame();
        const vps = frame.repaint(f.age);
        f.target.clearViewports(frame.clear, gfx.renderer.uncovered(&uncovered_buf, vps, frame.segments));
        try r.renderSegments(frame.canvases, frame.segments, &f.target, vps);
        f.finish(vps);
        try f.show(frame.damage.slice());
    }

    /// Draws `frame` whole into `popup`'s next buffer, and shows it; false if
    /// the popup has no buffer to draw into yet.
    pub fn presentPopup(p: *Presenter, popup: window_mod.Popup, frame: *const gfx.Frame) !bool {
        const r = p.renderer orelse return error.NoRenderer;
        var img = (try popup.beginSoftwareFrame()) orelse return false;
        img.clear(frame.clear);
        try r.prepare(frame.canvases);
        try r.render(frame.segments, &img, null);
        try popup.show();
        return true;
    }

    /// The renderer, if it may draw frames straight into the window's
    /// dmabufs, Metal layer or swap chain (it has not failed to).
    fn directRenderer(p: *const Presenter) ?gfx.Renderer {
        if (p.no_direct) return null;
        const r = p.renderer orelse return null;
        return if (r.hasDmabuf() or r.hasMetal() or r.hasD3D11()) r else null;
    }
};

test "a frame is drawn where its buffer's age says, and what changed is shown" {
    const testing = std.testing;
    const w = 16;
    const h = 8;
    // A window of one buffer, last drawn the frame before.
    const Win = struct {
        width: u32 = w,
        height: u32 = h,
        pixels: [w * h]u32 = @splat(0xff000000),
        shown: [4]Viewport = undefined,
        shown_len: usize = 0,

        pub fn size(win: *const @This()) [2]u32 {
            return .{ win.width, win.height };
        }
        pub fn beginSoftwareFrame(win: *@This()) !gfx.software.Image {
            return .{ .pixels = &win.pixels, .width = w, .height = h };
        }
        pub fn bufferAge(_: *const @This()) u32 {
            return 1;
        }
        pub fn showDamaged(win: *@This(), damage: ?[]const Viewport) !void {
            const d = damage.?;
            @memcpy(win.shown[0..d.len], d);
            win.shown_len = d.len;
        }
    };
    var win: Win = .{};
    var canvas = gfx.Canvas.init(testing.allocator);
    defer canvas.deinit();
    canvas.begin(w, h);
    canvas.fillRect(.{ .x = 0, .y = 0, .w = w, .h = h }, .rgb(0xff0000));
    var software: gfx.SoftwareRenderer = .{};
    var p: Presenter = .{ .renderer = software.renderer() };

    // All of it is red, but the buffer needs only its left half drawn.
    var f: gfx.Frame = .{ .canvases = &.{&canvas}, .segments = &.{.{ .canvas = &canvas }}, .clear = 0xff0000ff, .ages = 1 };
    f.repaints[0].add(.{ .width = w, .height = h });
    f.repaints[1].add(.{ .width = w / 2, .height = h });
    f.damage.add(.{ .width = w / 2, .height = h });
    try p.present(.from(&win), &f);
    try testing.expectEqual(@as(u32, 0xffff0000), win.pixels[0]);
    try testing.expectEqual(@as(u32, 0xffff0000), win.pixels[w / 2 - 1]);
    try testing.expectEqual(@as(u32, 0xff000000), win.pixels[w / 2]);
    try testing.expectEqual(@as(usize, 1), win.shown_len);
    try testing.expectEqual(@as(u32, w / 2), win.shown[0].width);
}
