//! An app with a window backend of its own (`zig build run-custom-backend`),
//! which kete can be built without its own for (`-Dbackends=false`: then it
//! needs nothing of the system, not even libc).
//!
//! Its window is a picture in memory: kete draws a button counting its
//! presses into it with the software renderer, the button is pressed three
//! times, and saves what it shows as `custom_backend.png`. A real backend
//! (SDL, GLFW, a framebuffer, a game engine's window) shows its frames, and
//! gives the input it takes, the same way.

const std = @import("std");
const kete = @import("kete");

/// A button that counts its presses, in the middle of the window.
const Counter = struct {
    count: *u32,

    fn increment(count: *u32) void {
        count.* += 1;
    }

    pub fn build(self: *const Counter, cx: *kete.BuildContext) kete.Widget {
        return cx.make(kete.Align.center(cx.make(kete.FilledButton{
            .label = cx.fmt("Pressed {d} times", .{self.count.*}),
            .on_press = .of(self.count, increment),
        })));
    }
};

/// A window that is a picture in memory, as `kete.window.Window.of` takes:
/// its size, a buffer to draw each frame into, what to do with a frame
/// drawn, and the input it has for the app. What it leaves out (popups,
/// cursors, the clipboard, ...) the window has not got.
const PictureWindow = struct {
    width: u32,
    height: u32,
    pixels: []u32,
    /// The frames it has shown.
    frames: u32 = 0,
    /// Input for the app: taken by it each turn.
    input: std.ArrayList(kete.window.InputEvent) = .empty,
    taken: std.ArrayList(kete.window.InputEvent) = .empty,
    closing: bool = false,

    pub fn beginSoftwareFrame(w: *PictureWindow) !kete.gfx.software.Image {
        return .{ .pixels = w.pixels, .width = w.width, .height = w.height };
    }

    pub fn showDamaged(w: *PictureWindow, _: ?[]const kete.gfx.Viewport) !void {
        w.frames += 1;
    }

    pub fn takeInput(w: *PictureWindow) []const kete.window.InputEvent {
        std.mem.swap(std.ArrayList(kete.window.InputEvent), &w.input, &w.taken);
        w.input.clearRetainingCapacity();
        return w.taken.items;
    }

    pub fn takeCloseRequest(w: *PictureWindow) bool {
        return w.closing;
    }
};

/// The display its windows are on: it opens one, and has nothing to wait
/// for (a real one waits for its events, up to `timeout_ns`).
const PictureDisplay = struct {
    gpa: std.mem.Allocator,
    window: ?PictureWindow = null,

    pub fn openWindow(d: *PictureDisplay, o: struct { title: []const u8, size: [2]u32 = .{ 320, 200 } }) !*PictureWindow {
        if (d.window != null) return error.OneWindowOnly;
        const pixels = try d.gpa.alloc(u32, o.size[0] * o.size[1]);
        d.window = .{ .width = o.size[0], .height = o.size[1], .pixels = pixels };
        return &d.window.?;
    }

    pub fn close(d: *PictureDisplay) void {
        const w = &(d.window orelse return);
        w.input.deinit(d.gpa);
        w.taken.deinit(d.gpa);
        d.gpa.free(w.pixels);
    }
};

/// Runs the counter on a `PictureWindow` (pressing + `presses` times) and
/// returns it, to be closed with `display`.
fn run(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, display: *PictureDisplay, presses: u32) !*PictureWindow {
    const app = try kete.App.init(gpa, io, environ, .{
        .display = .of(display),
        .on_last_window_closed = .quit,
    });
    defer app.deinit();

    var count: u32 = 0;
    const root: Counter = .{ .count = &count };
    _ = try app.openWindow(.{ .title = "Custom backend", .size = .{ 320, 200 }, .root = .of(&root), .on_close_request = .close });
    const w = &display.window.?;

    // The button, in the middle.
    const middle: [2]f32 = .{ @as(f32, @floatFromInt(w.width)) / 2, @as(f32, @floatFromInt(w.height)) / 2 };
    var pressed: u32 = 0;
    while (try app.step(0)) {
        if (w.input.items.len > 0) continue;
        if (pressed < presses) {
            pressed += 1;
            try w.input.appendSlice(gpa, &.{
                .{ .motion = middle },
                .{ .button = .{ .pos = middle, .button = .left, .pressed = true } },
                .{ .button = .{ .pos = middle, .button = .left, .pressed = false } },
            });
        } else if (count == presses and w.frames > 0) {
            w.closing = true;
        } else if (w.frames > 100) {
            return error.ButtonNotPressed;
        }
    }
    return w;
}

pub fn main(init: std.process.Init) !void {
    var display: PictureDisplay = .{ .gpa = init.gpa };
    defer display.close();
    const w = try run(init.gpa, init.io, init.minimal.environ, &display, 3);

    const png = try kete.gfx.png.encode(init.gpa, w.pixels, w.width, w.height);
    defer init.gpa.free(png);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "custom_backend.png", .data = png });
}

test "the counter runs, and is pressed, on a window of the app's own" {
    var display: PictureDisplay = .{ .gpa = std.testing.allocator };
    defer display.close();
    const w = try run(std.testing.allocator, std.testing.io, .empty, &display, 3);
    try std.testing.expect(w.frames > 0);
    // Something was drawn over the clear colour.
    const first = w.pixels[0];
    try std.testing.expect(for (w.pixels) |p| {
        if (p != first) break true;
    } else false);
}
