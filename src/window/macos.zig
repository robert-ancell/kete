//! MacWindow: a native macOS window: AppKit's NSWindow, with the system's
//! own title bar, buttons, resizing and full screen (the system draws
//! the decorations), and a view of kete's in it. The view can go under the
//! title bar (`Options.draw_in_title_bar`), with the system's buttons over
//! it: `cutouts` says where they are.
//!
//! Frames are drawn on the CPU into one of three buffers in turn (so the
//! damage tracking draws only what changed, as on Wayland) and shown as
//! the contents of the view's Core Animation layer. AppKit's events become
//! kete's `InputEvent`s: macOS key codes become `KeyboardKey`s, and Command counts as Control (so Command and C copies).
//! What the toolkit waits on as well (`window.Source`s: image loads,
//! wakes) is watched through the main run loop, so it sleeps until there
//! is something to do, and read through the app's `std.Io` once it is
//! readable. AppKit must be run on the main thread, so the UI's task must
//! be there (and waits in AppKit, not in the `Io`).
//!
//! Everything AppKit has is loaded when the window is opened (see
//! `gfx.objc`), so kete builds for macOS without its SDK.
//!
//! The GPU draws frames when it can: the Metal renderer asks for the
//! view's layer as a `CAMetalLayer` (`beginMetalFrame`) and presents
//! frames in it itself.

const std = @import("std");
const gfx = @import("gfx");
const window = @import("window.zig");
const objc = gfx.objc;
const sys = @import("sys.zig");
const clipboard = @import("clipboard.zig");

const Id = objc.Id;
const msg = objc.msg;
const InputEvent = window.InputEvent;

// AppKit's modifier flags.
const flag_shift = 1 << 17;
const flag_control = 1 << 18;
const flag_option = 1 << 19;
const flag_command = 1 << 20;

pub const MacWindow = struct {
    gpa: std.mem.Allocator,
    win: Id,
    view: Id,
    delegate: Id,
    title_buf: []u8,
    /// The view's size in points (the toolkit's logical pixels), and how
    /// many pixels each is.
    width: u32,
    height: u32,
    scale: u32 = 1,
    /// The window system asked for it to be closed (taken by the app).
    close_requested: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    /// The content is under the title bar (`Options.draw_in_title_bar`).
    draw_in_title_bar: bool = false,
    /// The last press of the left button (kept), which moving the window
    /// from where the app says (`startMove`) goes on from.
    last_press: Id = null,
    refresh_ns: u64 = std.time.ns_per_s / 60,
    /// A frame was shown less than a refresh ago (when the display shows
    /// it), so the next waits; and when it was shown.
    frame_pending: bool = false,
    /// What draws a frame from inside AppKit's own loops (see
    /// `window.Window.setRedraw`).
    redraw: ?window.Redraw = null,
    /// What draws a frame at each refresh while AppKit holds on to the
    /// app's loop (`pump` waiting longer than it was asked to: while the
    /// window is resized by its edge, goes to or from full screen, or is
    /// held by its title bar). It fires only then.
    hold_timer: Id = null,
    /// Whether `maximized` is still what AppKit says (asking it, isZoomed,
    /// can take a long time, so only when it may have changed).
    zoom_known: bool = false,
    presented_ns: u64 = 0,
    /// Events since the last `takeInput`, and those it gave.
    input: std.ArrayList(InputEvent) = .empty,
    taken: std.ArrayList(InputEvent) = .empty,
    modifiers: u64 = 0,
    /// The pointer lock asked for (`lockPointer`), and whether it is in
    /// effect (while the window has the keyboard): the pointer is hidden,
    /// held at the middle of the window, and its moves come as
    /// `relative_motion`.
    lock_wanted: bool = false,
    pointer_locked: bool = false,
    /// The buffers frames are drawn in, in turn, and which is being drawn.
    buffers: [3]Buffer = @splat(.{}),
    back: usize = 0,
    frames: u64 = 0,
    color_space: ?*anyopaque = null,
    /// The view's layers: the one the CPU's frames are the contents of, and
    /// the one the GPU draws in (made when it first does); which it has;
    /// and the size of the GPU's frames, when last drawn (0 by 0: none
    /// yet), which keeps them from one to the next.
    plain_layer: Id = null,
    /// The view's display link (macOS 14 and later), which says when each
    /// frame shown is on the screen (and pauses while none is waiting to
    /// be); without one, that is reckoned from the display's refresh rate.
    display_link: Id = null,
    metal_layer: Id = null,
    on_gpu: bool = false,
    gpu_size: [2]u32 = .{ 0, 0 },
    /// Its popups (menus and tooltips, each a panel of its own: see
    /// `openPopup`), and the next one's id.
    popups: [max_popups]?Popup = @splat(null),
    next_popup_id: u32 = 1,
    /// What it does its I/O through, and the display it is on (its own,
    /// if it was opened by `open`).
    io: std.Io,
    display: *MacDisplay,
    owns_display: bool = false,

    const max_popups = 4;

    /// A popup: a borderless panel over the window (a child window of it),
    /// whose view's input goes to the window (in its coordinates), and
    /// what it shows.
    const Popup = struct {
        id: u32,
        placement: window.PopupPlacement,
        panel: Id,
        view: Id,
        layer: Id,
        /// Where its top left is, in the window's coordinates (logical
        /// pixels), and its size in pixels.
        position: [2]i32,
        pixel_size: [2]u32,
        /// What is drawn in it (straight alpha, as kete draws).
        pixels: []u32 = &.{},
    };

    pub const platform: window.WindowPlatform = .macos;
    pub const decorations: window.WindowDecorations = .system;

    const Buffer = struct {
        pixels: ?*Pixels = null,
        width: u32 = 0,
        height: u32 = 0,
        /// The frame it was last shown in (0: never).
        drawn: u64 = 0,
    };

    /// A buffer's pixels, which the images shown of it share (the layer
    /// keeps its last for as long as it likes): freed when neither the
    /// buffer nor any image has them, on whichever thread lets them go
    /// last.
    const Pixels = struct {
        refs: std.atomic.Value(u32) = .init(1),
        mem: []u32,

        fn create(len: usize) !*Pixels {
            const a = std.heap.c_allocator;
            const p = try a.create(Pixels);
            p.* = .{ .mem = a.alloc(u32, len) catch |e| {
                a.destroy(p);
                return e;
            } };
            return p;
        }

        fn ref(p: *Pixels) void {
            _ = p.refs.fetchAdd(1, .monotonic);
        }

        fn unref(p: *Pixels) void {
            if (p.refs.fetchSub(1, .acq_rel) != 1) return;
            std.heap.c_allocator.free(p.mem);
            std.heap.c_allocator.destroy(p);
        }

        /// CoreGraphics is done with an image's.
        fn released(info: ?*anyopaque, _: ?*const anyopaque, _: usize) callconv(.c) void {
            const p: *Pixels = @ptrCast(@alignCast(info orelse return));
            p.unref();
        }
    };

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = .{ 960, 640 },
        min_size: ?[2]u32 = null,
        maximized: bool = false,
        /// The app draws in the title bar: the window's content fills it, and
        /// the window's buttons are over the content (`cutouts`).
        draw_in_title_bar: bool = false,
        /// A window it belongs to (a dialog's, a tool window's): it stays
        /// above it, and moves with it.
        parent: ?*MacWindow = null,
    };

    /// Opens a window on a display of its own (and, the first time,
    /// starts the app: its menu, with Quit, and its place in the Dock).
    pub fn open(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !*MacWindow {
        const d = try MacDisplay.open(gpa, io, environ);
        errdefer d.close();
        const w = try d.openWindow(options);
        w.owns_display = true;
        return w;
    }

    fn openOn(d: *MacDisplay, options: Options) !*MacWindow {
        const gpa = d.gpa;
        const pool = objc.push();
        defer objc.pop(pool);
        const app = startApp();

        const w = try gpa.create(MacWindow);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa, .io = d.io, .display = d, .win = null, .view = null, .delegate = null, .title_buf = try gpa.dupe(u8, options.title), .width = options.size[0], .height = options.size[1] };
        errdefer gpa.free(w.title_buf);

        const rect: objc.Rect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(options.size[0]), .height = @floatFromInt(options.size[1]) } };
        // Titled, closable, minimizable and resizable: the system's frame
        // (with the content under the title bar, if the app draws there).
        const style: u64 = 1 | 2 | 4 | 8 | (if (options.draw_in_title_bar) @as(u64, 1 << 15) else 0);
        const nswin = msg(Id, objc.class("NSWindow"), "alloc", .{});
        w.win = msg(Id, nswin, "initWithContentRect:styleMask:backing:defer:", .{ rect, style, @as(u64, 2), objc.no });
        msg(void, w.win, "setReleasedWhenClosed:", .{objc.no});
        msg(void, w.win, "setTitle:", .{objc.nsString(options.title)});
        msg(void, w.win, "setAcceptsMouseMovedEvents:", .{objc.yes});
        w.draw_in_title_bar = options.draw_in_title_bar;
        if (options.draw_in_title_bar) {
            // The title bar shows nothing of its own (the buttons stay).
            msg(void, w.win, "setTitlebarAppearsTransparent:", .{objc.yes});
            msg(void, w.win, "setTitleVisibility:", .{@as(isize, 1)});
        }

        // A view hosting a layer of its own, whose contents are the frames.
        w.view = msg(Id, msg(Id, viewClass(), "alloc", .{}), "initWithFrame:", .{rect});
        objc.setOwner(w.view, w);
        w.plain_layer = objc.retain(msg(Id, objc.class("CALayer"), "layer", .{}));
        keepTopLeft(w.plain_layer);
        msg(void, w.view, "setLayer:", .{w.plain_layer});
        msg(void, w.view, "setWantsLayer:", .{objc.yes});
        // Moves, entering and leaving, wherever the pointer is in it.
        const tracking = msg(Id, objc.class("NSTrackingArea"), "alloc", .{});
        const opts: u64 = 0x01 | 0x02 | 0x80 | 0x200; // entered/exited, moved, always, in visible rect
        const area = msg(Id, tracking, "initWithRect:options:owner:userInfo:", .{ rect, opts, w.view, @as(Id, null) });
        msg(void, w.view, "addTrackingArea:", .{area});
        msg(void, area, "release", .{});
        msg(void, w.win, "setContentView:", .{w.view});

        w.delegate = msg(Id, delegateClass(), "new", .{});
        objc.setOwner(w.delegate, w);
        msg(void, w.win, "setDelegate:", .{w.delegate});

        if (options.min_size) |m| w.setMinSize(m[0], m[1]);
        msg(void, w.win, "center", .{});
        msg(void, w.win, "makeKeyAndOrderFront:", .{@as(Id, null)});
        msg(void, w.win, "makeFirstResponder:", .{w.view});
        if (options.maximized) msg(void, w.win, "zoom:", .{@as(Id, null)});
        if (options.parent) |parent| msg(void, parent.win, "addChildWindow:ordered:", .{ w.win, @as(isize, 1) });
        msg(void, app, "activateIgnoringOtherApps:", .{objc.yes});

        w.updateScale();
        if (msg(Id, objc.class("NSScreen"), "mainScreen", .{})) |screen| {
            const fps = msg(isize, screen, "maximumFramesPerSecond", .{});
            if (fps > 0) w.refresh_ns = std.time.ns_per_s / @as(u64, @intCast(fps));
        }
        if (msg(objc.Bool, w.view, "respondsToSelector:", .{objc.sel("displayLinkWithTarget:selector:")}) != 0) {
            if (msg(Id, w.view, "displayLinkWithTarget:selector:", .{ w.delegate, objc.sel("displayTick:") })) |link| {
                msg(void, link, "setPaused:", .{objc.yes});
                msg(void, link, "addToRunLoop:forMode:", .{ msg(Id, objc.class("NSRunLoop"), "mainRunLoop", .{}), objc.constant("NSRunLoopCommonModes") });
                w.display_link = objc.retain(link);
            }
        }
        windows.append(gpa, w) catch {};
        return w;
    }

    pub fn close(w: *MacWindow) void {
        const pool = objc.push();
        defer objc.pop(pool);
        w.unlockPointer();
        for (&w.popups) |*slot| if (slot.*) |*pop| {
            w.destroyPopup(pop);
            slot.* = null;
        };
        w.setRedraw(null);
        msg(void, w.win, "setDelegate:", .{@as(Id, null)});
        msg(void, w.win, "close", .{});
        objc.setOwner(w.delegate, null);
        objc.setOwner(w.view, null);
        msg(void, w.delegate, "release", .{});
        msg(void, w.view, "release", .{});
        msg(void, w.win, "release", .{});
        objc.release(w.plain_layer);
        objc.release(w.last_press);
        if (w.display_link) |link| {
            msg(void, link, "invalidate", .{});
            objc.release(link);
        }
        objc.release(w.metal_layer);
        for (w.buffers) |b| if (b.pixels) |px| px.unref();
        if (w.color_space) |cs| if (objc.symbol(*const fn (?*anyopaque) callconv(.c) void, "CGColorSpaceRelease")) |f| f(cs);
        w.input.deinit(w.gpa);
        w.taken.deinit(w.gpa);
        w.gpa.free(w.title_buf);
        if (std.mem.indexOfScalar(*MacWindow, windows.items, w)) |i| _ = windows.swapRemove(i);
        // The last to close frees the list, for the next to open to start anew.
        if (windows.items.len == 0) {
            windows.deinit(w.gpa);
            windows = .empty;
        }
        const d = w.display;
        const owned = w.owns_display;
        w.gpa.destroy(w);
        if (owned) d.close();
    }

    pub fn getTitle(w: *const MacWindow) []const u8 {
        return w.title_buf;
    }

    /// Sets the title the window's title bar shows.
    pub fn setTitle(w: *MacWindow, title: []const u8) void {
        const owned = w.gpa.dupe(u8, title) catch return;
        w.gpa.free(w.title_buf);
        w.title_buf = owned;
        const pool = objc.push();
        defer objc.pop(pool);
        msg(void, w.win, "setTitle:", .{objc.nsString(title)});
    }

    pub fn size(w: *const MacWindow) [2]u32 {
        return .{ w.width, w.height };
    }

    pub fn getScale(w: *const MacWindow) u32 {
        return w.scale;
    }

    pub fn refreshNs(w: *const MacWindow) u64 {
        return w.refresh_ns;
    }

    // --- Events -------------------------------------------------------------------

    /// Now, on the clock frames and input are timed on.
    fn now(w: *const MacWindow) u64 {
        return window.nowNs(w.io);
    }

    /// Handles what has come (to any of the display's windows), without
    /// waiting.
    pub fn poll(w: *MacWindow) !void {
        return w.display.poll();
    }

    /// Waits up to `timeout_ns` for something (an event, or a watched
    /// source readable), and handles what has come (see `MacDisplay.wait`).
    pub fn wait(w: *MacWindow, timeout_ns: u64) !void {
        return w.display.wait(timeout_ns);
    }

    /// When the next frame can be drawn, if a frame shown is waited for.
    fn pendingUntil(w: *const MacWindow) ?u64 {
        if (!w.frame_pending) return null;
        return w.presented_ns + w.pendingGrace();
    }

    fn updatePending(w: *MacWindow) void {
        // `presented_ns` is when the frame drawn is shown: the next can be
        // drawn then, for the refresh after.
        if (w.frame_pending and w.now() >= w.presented_ns + w.pendingGrace()) w.frame_pending = false;
    }

    /// When a frame drawn now would be shown: at the display's next
    /// refresh after the last.
    pub fn nextPresentationNs(w: *const MacWindow, now_ns: u64) u64 {
        if (w.presented_ns == 0) return now_ns;
        if (now_ns < w.presented_ns) return w.presented_ns + w.refresh_ns;
        const periods = (now_ns - w.presented_ns) / w.refresh_ns + 1;
        return w.presented_ns + periods * w.refresh_ns;
    }

    pub fn takeInput(w: *MacWindow) []const InputEvent {
        w.taken.clearRetainingCapacity();
        std.mem.swap(std.ArrayList(InputEvent), &w.input, &w.taken);
        return w.taken.items;
    }

    fn push(w: *MacWindow, e: InputEvent) void {
        w.input.append(w.gpa, e) catch {};
    }

    /// The view's new size, if it changed (and its scale, kept).
    pub fn applyConfigure(w: *MacWindow) !?[2]u32 {
        const pool = objc.push();
        defer objc.pop(pool);
        const bounds = objc.msgRect(w.view, "bounds");
        const nw: u32 = @intFromFloat(@max(@round(bounds.size.width), 1));
        const nh: u32 = @intFromFloat(@max(@round(bounds.size.height), 1));
        const old_scale = w.scale;
        w.updateScale();
        w.fullscreen = msg(u64, w.win, "styleMask", .{}) & (1 << 14) != 0;
        if (w.fullscreen) {
            w.maximized = false;
        } else if (!w.zoom_known) {
            w.maximized = msg(objc.Bool, w.win, "isZoomed", .{}) != 0;
            w.zoom_known = true;
        }
        if (nw == w.width and nh == w.height and old_scale == w.scale) return null;
        w.width = nw;
        w.height = nh;
        return .{ nw, nh };
    }

    fn updateScale(w: *MacWindow) void {
        const s = msg(objc.CGFloat, w.win, "backingScaleFactor", .{});
        w.scale = @intFromFloat(@max(@round(s), 1));
    }

    /// What the system's appearance is: dark (true) or light.
    pub fn prefersDark(_: *const MacWindow) ?bool {
        const pool = objc.push();
        defer objc.pop(pool);
        const app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
        const appearance = msg(Id, app, "effectiveAppearance", .{}) orelse return null;
        const name = objc.utf8(msg(Id, appearance, "name", .{}));
        return std.mem.indexOf(u8, name, "Dark") != null;
    }

    // --- Frames -------------------------------------------------------------------

    /// Frames drawn on the GPU are in the Metal layer's drawables; the
    /// CPU's in memory.
    pub fn bufferTransport(w: *const MacWindow) window.WindowBufferTransport {
        return if (w.on_gpu) .swapchain else .memory;
    }

    /// The view's layer as a `CAMetalLayer`, its drawables as big as the
    /// view in pixels, for the GPU to draw the next frame in.
    pub fn beginMetalFrame(w: *MacWindow) ?gfx.MetalTarget {
        const pool = objc.push();
        defer objc.pop(pool);
        if (w.metal_layer == null) {
            const cls = objc.class("CAMetalLayer") orelse return null;
            w.metal_layer = objc.retain(msg(Id, cls, "layer", .{}));
            msg(void, w.metal_layer, "setOpaque:", .{objc.yes});
            keepTopLeft(w.metal_layer);
        }
        if (!w.on_gpu) {
            msg(void, w.view, "setLayer:", .{w.metal_layer});
            w.on_gpu = true;
            w.gpu_size = .{ 0, 0 };
        }
        const pw = w.width * w.scale;
        const ph = w.height * w.scale;
        msg(void, w.metal_layer, "setContentsScale:", .{@as(objc.CGFloat, @floatFromInt(w.scale))});
        msg(void, w.metal_layer, "setDrawableSize:", .{objc.Size{ .width = @floatFromInt(pw), .height = @floatFromInt(ph) }});
        // While resized by its edge, a frame is shown with the window's new
        // size (in its transaction), not after it.
        msg(void, w.metal_layer, "setPresentsWithTransaction:", .{msg(objc.Bool, w.view, "inLiveResize", .{})});
        return .{ .layer = w.metal_layer.?, .width = pw, .height = ph };
    }

    /// The next buffer to draw a frame in, as big as the view in pixels.
    pub fn beginSoftwareFrame(w: *MacWindow) !gfx.software.Image {
        if (w.on_gpu) {
            // Back to the CPU (the GPU could not draw).
            msg(void, w.view, "setLayer:", .{w.plain_layer});
            w.on_gpu = false;
        }
        w.back = (w.back + 1) % w.buffers.len;
        const b = &w.buffers[w.back];
        const pw = w.width * w.scale;
        const ph = w.height * w.scale;
        if (b.pixels == null or b.width != pw or b.height != ph) {
            if (b.pixels) |px| px.unref();
            b.* = .{};
            const px = try Pixels.create(@as(usize, pw) * ph);
            @memset(px.mem, 0xff000000);
            b.* = .{ .pixels = px, .width = pw, .height = ph };
        }
        return .{ .pixels = b.pixels.?.mem, .width = pw, .height = ph };
    }

    /// How many frames ago the buffer `beginSoftwareFrame` gave was last shown (0:
    /// never).
    pub fn bufferAge(w: *const MacWindow) u32 {
        // The renderer keeps the GPU's frame, while it is the same size.
        if (w.on_gpu) return if (w.gpu_size[0] == w.width * w.scale and w.gpu_size[1] == w.height * w.scale) 1 else 0;
        const b = &w.buffers[w.back];
        if (b.drawn == 0) return 0;
        return @intCast(@min(w.frames + 1 - b.drawn, std.math.maxInt(u32)));
    }

    /// Shows the buffer drawn: the layer's contents (the whole of it; the
    /// layer is composited by the system).
    pub fn showDamaged(w: *MacWindow, _: ?[]const gfx.Viewport) !void {
        if (w.on_gpu) {
            // Presented by the renderer.
            w.gpu_size = .{ w.width * w.scale, w.height * w.scale };
            w.frames += 1;
            w.shown();
            return;
        }
        const pool = objc.push();
        defer objc.pop(pool);
        const b = &w.buffers[w.back];
        const px = b.pixels orelse return;
        const cg = cgFunctions() orelse return error.NoCoreGraphics;
        if (w.color_space == null) w.color_space = cg.colorSpace();
        // The buffer itself (not a copy): it is drawn in again only two
        // frames later, when the layer has long since shown it. The image
        // keeps its pixels (until CoreGraphics lets them go).
        px.ref();
        const provider = cg.provider(px, px.mem.ptr, px.mem.len * 4, &Pixels.released) orelse {
            px.unref();
            return error.NoCoreGraphics;
        };
        defer cg.releaseProvider(provider);
        // 0xAARRGGBB in memory, little-endian: BGRA, its alpha ignored.
        const info: u32 = (2 << 12) | 6;
        const image = cg.image(b.width, b.height, 8, 32, @as(usize, b.width) * 4, w.color_space, info, provider, null, false, 0);
        defer cg.releaseImage(image);
        const transaction = objc.class("CATransaction");
        msg(void, transaction, "begin", .{});
        msg(void, transaction, "setDisableActions:", .{objc.yes});
        // Its pixels the view's at its scale (the layer keeps them at its
        // top left corner, not stretched to fit).
        msg(void, w.plain_layer, "setContentsScale:", .{@as(objc.CGFloat, @floatFromInt(w.scale))});
        msg(void, msg(Id, w.view, "layer", .{}), "setContents:", .{image});
        msg(void, transaction, "commit", .{});
        w.frames += 1;
        b.drawn = w.frames;
        w.shown();
    }

    /// A frame has been given to be shown: when it will be (the display
    /// link says, if there is one; reckoned meanwhile), the next waits.
    fn shown(w: *MacWindow) void {
        w.presented_ns = w.nextPresentationNs(w.now());
        w.frame_pending = true;
        if (w.display_link) |link| msg(void, link, "setPaused:", .{objc.no});
    }

    /// How long past when a frame shown is reckoned to be on the screen it
    /// is waited for: a refresh, with a display link to say (which may be
    /// late), none without.
    fn pendingGrace(w: *const MacWindow) u64 {
        return if (w.display_link != null) w.refresh_ns else 0;
    }

    // --- The window ------------------------------------------------------------------

    pub fn setMinSize(w: *MacWindow, width: u32, height: u32) void {
        msg(void, w.win, "setContentMinSize:", .{objc.Size{ .width = @floatFromInt(width), .height = @floatFromInt(height) }});
        // AppKit only keeps it from shrinking past the minimum: one already
        // smaller grows to it, its top left corner where it was. Full
        // screen, it is the screen's size.
        if (w.fullscreen) return;
        const bounds = objc.msgRect(w.view, "bounds");
        const dw = @max(@as(objc.CGFloat, @floatFromInt(width)) - bounds.size.width, 0);
        const dh = @max(@as(objc.CGFloat, @floatFromInt(height)) - bounds.size.height, 0);
        if (dw == 0 and dh == 0) return;
        var frame = objc.msgRect(w.win, "frame");
        frame.size.width += dw;
        frame.size.height += dh;
        frame.origin.y -= dh;
        msg(void, w.win, "setFrame:display:", .{ frame, objc.yes });
    }

    pub fn setRedraw(w: *MacWindow, redraw: ?window.Redraw) void {
        w.redraw = redraw;
        if (redraw == null) {
            if (w.hold_timer) |timer| {
                msg(void, timer, "invalidate", .{});
                objc.release(timer);
                w.hold_timer = null;
            }
            return;
        }
        if (w.hold_timer != null) return;
        const seconds = @as(f64, @floatFromInt(w.refresh_ns)) / std.time.ns_per_s;
        const timer = msg(Id, objc.class("NSTimer"), "timerWithTimeInterval:target:selector:userInfo:repeats:", .{ seconds, w.delegate, objc.sel("holdTick:"), @as(Id, null), objc.yes }) orelse return;
        msg(void, timer, "setFireDate:", .{msg(Id, objc.class("NSDate"), "distantFuture", .{})});
        // In AppKit's own loops (as while it tracks the mouse), as in ours.
        const loop = msg(Id, objc.class("NSRunLoop"), "currentRunLoop", .{});
        msg(void, loop, "addTimer:forMode:", .{ timer, objc.constant("kCFRunLoopCommonModes") });
        w.hold_timer = objc.retain(timer);
    }

    /// Sets the hold timer to fire a frame after `pump` should be done
    /// waiting `seconds` (null: not to).
    fn armHoldTimer(w: *MacWindow, seconds: ?f64) void {
        const timer = w.hold_timer orelse return;
        const date = if (seconds) |s|
            msg(Id, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{s + @as(f64, @floatFromInt(w.refresh_ns)) / std.time.ns_per_s})
        else
            msg(Id, objc.class("NSDate"), "distantFuture", .{});
        msg(void, timer, "setFireDate:", .{date});
    }

    fn drawNow(w: *MacWindow) void {
        const r = w.redraw orelse return;
        r.f(r.ctx);
    }

    pub fn setMaximized(w: *MacWindow, on: bool) void {
        if ((msg(objc.Bool, w.win, "isZoomed", .{}) != 0) != on) msg(void, w.win, "zoom:", .{@as(Id, null)});
    }

    /// Starts moving the window with the pointer, from the last press of the left
    /// button: for the app's own title bar.
    pub fn startMove(w: *MacWindow) void {
        const e = w.last_press orelse return;
        msg(void, w.win, "performWindowDragWithEvent:", .{e});
    }

    /// Where the window's buttons (close, minimize, zoom) are over the content,
    /// if the app draws in the title bar: their rectangle, with some room
    /// around it. None in fullscreen, when they are hidden.
    pub fn cutouts(w: *const MacWindow, out: *[window.max_cutouts]gfx.Rect) usize {
        if (!w.draw_in_title_bar or w.fullscreen) return 0;
        const pool = objc.push();
        defer objc.pop(pool);
        var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
        var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
        for ([_]isize{ 0, 1, 2 }) |which| {
            const button = msg(Id, w.win, "standardWindowButton:", .{which}) orelse continue;
            if (msg(objc.Bool, button, "isHidden", .{}) != 0) continue;
            const parent = msg(Id, button, "superview", .{}) orelse continue;
            const frame = objc.msgRect(button, "frame");
            // Two corners, in the window's coordinates and then the view's
            // (where down is positive).
            const corners = [2]objc.Point{
                .{ .x = frame.origin.x, .y = frame.origin.y },
                .{ .x = frame.origin.x + frame.size.width, .y = frame.origin.y + frame.size.height },
            };
            for (corners) |corner| {
                const in_window = msg(objc.Point, parent, "convertPoint:toView:", .{ corner, @as(Id, null) });
                const p = msg(objc.Point, w.view, "convertPoint:fromView:", .{ in_window, @as(Id, null) });
                lo = .{ @min(lo[0], @as(f32, @floatCast(p.x))), @min(lo[1], @as(f32, @floatCast(p.y))) };
                hi = .{ @max(hi[0], @as(f32, @floatCast(p.x))), @max(hi[1], @as(f32, @floatCast(p.y))) };
            }
        }
        if (lo[0] > hi[0]) return 0;
        const room = 6;
        const x = @max(lo[0] - room, 0);
        const y = @max(lo[1] - room, 0);
        out[0] = .{ .x = x, .y = y, .w = hi[0] + room - x, .h = hi[1] + room - y };
        return 1;
    }

    pub fn setMinimized(w: *MacWindow) void {
        msg(void, w.win, "miniaturize:", .{@as(Id, null)});
    }

    pub fn setFullscreen(w: *MacWindow, on: bool) void {
        if (w.fullscreen != on) msg(void, w.win, "toggleFullScreen:", .{@as(Id, null)});
    }

    /// Locks the pointer (see `Window.lockPointer`): hidden and held at the
    /// middle of the window while it has the keyboard, its moves told as
    /// `relative_motion`. Whether it can be.
    pub fn lockPointer(w: *MacWindow) bool {
        if (w.lock_wanted) return true;
        if (pointerFunctions() == null) return false;
        w.lock_wanted = true;
        if (msg(objc.Bool, w.win, "isKeyWindow", .{}) != 0) w.holdPointer();
        return true;
    }

    /// Lets the pointer go (see `Window.unlockPointer`).
    pub fn unlockPointer(w: *MacWindow) void {
        if (!w.lock_wanted) return;
        w.lock_wanted = false;
        w.releasePointer();
    }

    /// Holds the pointer (the lock takes effect): moved to the middle of
    /// the window, kept there (the mouse no longer moves it), and hidden.
    fn holdPointer(w: *MacWindow) void {
        if (w.pointer_locked) return;
        const pf = pointerFunctions() orelse return;
        const pool = objc.push();
        defer objc.pop(pool);
        // The middle of the view, on the screen; in CoreGraphics' terms,
        // from the top of the main screen down.
        const bounds = objc.msgRect(w.view, "bounds");
        const mid_view: objc.Point = .{ .x = bounds.origin.x + bounds.size.width / 2, .y = bounds.origin.y + bounds.size.height / 2 };
        const in_window = msg(objc.Point, w.view, "convertPoint:toView:", .{ mid_view, @as(Id, null) });
        const on_screen = msg(objc.Point, w.win, "convertPointToScreen:", .{in_window});
        const main = msg(Id, msg(Id, objc.class("NSScreen"), "screens", .{}), "firstObject", .{});
        const main_height = if (main != null) objc.msgRect(main, "frame").size.height else 0;
        _ = pf.warp(.{ .x = on_screen.x, .y = main_height - on_screen.y });
        _ = pf.associate(0);
        msg(void, objc.class("NSCursor"), "hide", .{});
        w.pointer_locked = true;
        w.push(.{ .pointer_locked = true });
        postWake();
    }

    /// Lets the pointer go (the lock no longer in effect).
    fn releasePointer(w: *MacWindow) void {
        if (!w.pointer_locked) return;
        const pf = pointerFunctions() orelse return;
        _ = pf.associate(1);
        msg(void, objc.class("NSCursor"), "unhide", .{});
        w.pointer_locked = false;
        w.push(.{ .pointer_locked = false });
        postWake();
    }

    pub fn setCursor(_: *MacWindow, cursor: window.PointerCursor) void {
        const pool = objc.push();
        defer objc.pop(pool);
        const name: [*:0]const u8 = switch (cursor) {
            .pointer => "pointingHandCursor",
            .text => "IBeamCursor",
            .grab => "openHandCursor",
            .grabbing, .move => "closedHandCursor",
            .crosshair => "crosshairCursor",
            .not_allowed => "operationNotAllowedCursor",
            .ew_resize => "resizeLeftRightCursor",
            .ns_resize => "resizeUpDownCursor",
            else => "arrowCursor",
        };
        msg(void, msg(Id, objc.class("NSCursor"), name, .{}), "set", .{});
    }

    pub fn copy(_: *MacWindow, text: []const u8) void {
        const pool = objc.push();
        defer objc.pop(pool);
        const pb = msg(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
        _ = msg(isize, pb, "clearContents", .{});
        _ = msg(objc.Bool, pb, "setString:forType:", .{ objc.nsString(text), objc.constant("NSPasteboardTypeString") });
    }

    pub fn paste(_: *MacWindow, sink: clipboard.Sink) void {
        const pool = objc.push();
        defer objc.pop(pool);
        const pb = msg(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
        const str = msg(Id, pb, "stringForType:", .{objc.constant("NSPasteboardTypeString")});
        sink.f(sink.ctx, if (str == null) null else objc.utf8(str));
    }

    // --- Popups -------------------------------------------------------------------

    /// Opens a popup (a menu or a tooltip) where `placement` says, by
    /// Wayland's positioner model (`window.Positioner`), kept on the
    /// window's screen: a borderless panel over the window that does not
    /// take the keyboard (so a menu's keys still come to the window), its
    /// pointer input the window's, in the window's coordinates. A tooltip
    /// lets the pointer through. Null if it cannot be opened.
    pub fn openPopup(w: *MacWindow, placement: window.PopupPlacement) ?u32 {
        const slot = for (&w.popups) |*slot| {
            if (slot.* == null) break slot;
        } else return null;
        const pool = objc.push();
        defer objc.pop(pool);
        const screen = msg(Id, w.win, "screen", .{}) orelse msg(Id, objc.class("NSScreen"), "mainScreen", .{}) orelse return null;
        const pos = placement.positioner(.{ w.width, w.height }).place(w.viewRectOf(objc.msgRect(screen, "visibleFrame")));
        const width: objc.CGFloat = @floatFromInt(@max(placement.size[0], 1));
        const height: objc.CGFloat = @floatFromInt(@max(placement.size[1], 1));
        const top_left = w.screenPointOf(.{ .x = @floatFromInt(pos[0]), .y = @floatFromInt(pos[1]) });
        const frame: objc.Rect = .{ .origin = .{ .x = top_left.x, .y = top_left.y - height }, .size = .{ .width = width, .height = height } };

        // Borderless (0), and not activating the app when used (1 << 7).
        const panel = msg(Id, msg(Id, objc.class("NSPanel"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ frame, @as(u64, 1 << 7), @as(u64, 2), objc.no }) orelse return null;
        msg(void, panel, "setReleasedWhenClosed:", .{objc.no});
        msg(void, panel, "setOpaque:", .{objc.no});
        msg(void, panel, "setBackgroundColor:", .{msg(Id, objc.class("NSColor"), "clearColor", .{})});
        // Kete draws the shadow (in the popup's own pixels).
        msg(void, panel, "setHasShadow:", .{objc.no});
        msg(void, panel, "setLevel:", .{@as(isize, 101)}); // NSPopUpMenuWindowLevel
        msg(void, panel, "setAcceptsMouseMovedEvents:", .{objc.yes});
        if (placement.kind == .tooltip) msg(void, panel, "setIgnoresMouseEvents:", .{objc.yes});

        const bounds: objc.Rect = .{ .origin = .{ .x = 0, .y = 0 }, .size = frame.size };
        const view = msg(Id, msg(Id, viewClass(), "alloc", .{}), "initWithFrame:", .{bounds});
        objc.setOwner(view, w);
        const layer = objc.retain(msg(Id, objc.class("CALayer"), "layer", .{}));
        keepTopLeft(layer);
        msg(void, view, "setLayer:", .{layer});
        msg(void, view, "setWantsLayer:", .{objc.yes});
        const tracking = msg(Id, objc.class("NSTrackingArea"), "alloc", .{});
        const opts: u64 = 0x01 | 0x02 | 0x80 | 0x200; // entered/exited, moved, always, in visible rect
        const area = msg(Id, tracking, "initWithRect:options:owner:userInfo:", .{ bounds, opts, view, @as(Id, null) });
        msg(void, view, "addTrackingArea:", .{area});
        msg(void, area, "release", .{});
        msg(void, panel, "setContentView:", .{view});
        // Over the window, moving with it.
        msg(void, w.win, "addChildWindow:ordered:", .{ panel, @as(isize, 1) }); // NSWindowAbove

        const id = w.next_popup_id;
        w.next_popup_id +%= 1;
        slot.* = .{
            .id = id,
            .placement = placement,
            .panel = panel,
            .view = view,
            .layer = layer,
            .position = pos,
            .pixel_size = .{ @max(placement.size[0], 1) * w.scale, @max(placement.size[1], 1) * w.scale },
        };
        return id;
    }

    /// `r` (in screen coordinates) in the view's (top left at 0, 0).
    fn viewRectOf(w: *const MacWindow, r: objc.Rect) window.positioner_mod.Rect {
        const tl = w.viewPointOf(.{ .x = r.origin.x, .y = r.origin.y + r.size.height });
        const br = w.viewPointOf(.{ .x = r.origin.x + r.size.width, .y = r.origin.y });
        const x0: i32 = @intFromFloat(@ceil(tl.x));
        const y0: i32 = @intFromFloat(@ceil(tl.y));
        const x1: i32 = @intFromFloat(@floor(br.x));
        const y1: i32 = @intFromFloat(@floor(br.y));
        return .{ x0, y0, @max(x1 - x0, 1), @max(y1 - y0, 1) };
    }

    fn viewPointOf(w: *const MacWindow, on_screen: objc.Point) objc.Point {
        const in_window = msg(objc.Point, w.win, "convertPointFromScreen:", .{on_screen});
        return msg(objc.Point, w.view, "convertPoint:fromView:", .{ in_window, @as(Id, null) });
    }

    fn screenPointOf(w: *const MacWindow, in_view: objc.Point) objc.Point {
        const in_window = msg(objc.Point, w.view, "convertPoint:toView:", .{ in_view, @as(Id, null) });
        return msg(objc.Point, w.win, "convertPointToScreen:", .{in_window});
    }

    fn popupOf(w: *MacWindow, id: u32) ?*Popup {
        for (&w.popups) |*slot| if (slot.*) |*pop| if (pop.id == id) return pop;
        return null;
    }

    pub fn closePopup(w: *MacWindow, id: u32) void {
        for (&w.popups) |*slot| if (slot.*) |*pop| if (pop.id == id) {
            const pool = objc.push();
            defer objc.pop(pool);
            w.destroyPopup(pop);
            slot.* = null;
            return;
        };
    }

    fn destroyPopup(w: *MacWindow, pop: *Popup) void {
        msg(void, w.win, "removeChildWindow:", .{pop.panel});
        msg(void, pop.panel, "orderOut:", .{@as(Id, null)});
        objc.setOwner(pop.view, null);
        msg(void, pop.panel, "setContentView:", .{@as(Id, null)});
        msg(void, pop.view, "release", .{});
        objc.release(pop.layer);
        msg(void, pop.panel, "release", .{});
        w.gpa.free(pop.pixels);
    }

    /// Where the popup is, in the window's coordinates (known as soon as
    /// it is opened: kete places it).
    pub fn popupPosition(w: *MacWindow, id: u32) ?[2]i32 {
        const pop = w.popupOf(id) orelse return null;
        return pop.position;
    }

    /// The buffer to draw the popup in, all of it, at the window's scale.
    pub fn beginSoftwarePopupFrame(w: *MacWindow, id: u32) !?gfx.software.Image {
        const pop = w.popupOf(id) orelse return null;
        const len = @as(usize, pop.pixel_size[0]) * pop.pixel_size[1];
        if (pop.pixels.len != len) {
            w.gpa.free(pop.pixels);
            pop.pixels = &.{};
            pop.pixels = try w.gpa.alloc(u32, len);
        }
        return .{ .pixels = pop.pixels, .width = pop.pixel_size[0], .height = pop.pixel_size[1] };
    }

    /// Shows what was drawn in the popup (and the popup, the first time).
    pub fn showPopup(w: *MacWindow, id: u32) !void {
        const pop = w.popupOf(id) orelse return;
        const pool = objc.push();
        defer objc.pop(pool);
        const cg = cgFunctions() orelse return error.NoCoreGraphics;
        if (w.color_space == null) w.color_space = cg.colorSpace();
        // An image of its own (Core Animation keeps it as long as it
        // likes), premultiplied, as Core Graphics wants.
        const px = try Pixels.create(pop.pixels.len);
        window.premultiply(px.mem, pop.pixels);
        const provider = cg.provider(px, px.mem.ptr, px.mem.len * 4, &Pixels.released) orelse {
            px.unref();
            return error.NoCoreGraphics;
        };
        defer cg.releaseProvider(provider);
        // 0xAARRGGBB in memory, little-endian: BGRA, premultiplied.
        const info: u32 = (2 << 12) | 2;
        const image = cg.image(pop.pixel_size[0], pop.pixel_size[1], 8, 32, @as(usize, pop.pixel_size[0]) * 4, w.color_space, info, provider, null, false, 0);
        defer cg.releaseImage(image);
        const transaction = objc.class("CATransaction");
        msg(void, transaction, "begin", .{});
        msg(void, transaction, "setDisableActions:", .{objc.yes});
        msg(void, pop.layer, "setContentsScale:", .{@as(objc.CGFloat, @floatFromInt(w.scale))});
        msg(void, pop.layer, "setContents:", .{image});
        msg(void, transaction, "commit", .{});
        if (msg(objc.Bool, pop.panel, "isVisible", .{}) == 0) msg(void, pop.panel, "orderFront:", .{@as(Id, null)});
    }

    /// The window stopped being where its menus were for (it lost the
    /// keyboard, or began to be moved or resized): they are done, as a
    /// compositor ends a popup whose grab broke.
    fn endMenus(w: *MacWindow) void {
        for (w.popups) |slot| if (slot) |pop| {
            if (pop.placement.kind == .menu) w.push(.{ .popup_done = pop.id });
        };
    }

    // --- Watching sources -------------------------------------------------------------

    /// Waits on `source` too (see `MacDisplay.watch`).
    pub fn watch(w: *MacWindow, source: window.Source, on: bool) void {
        w.display.watch(source, on);
    }

    // --- AppKit's calls --------------------------------------------------------------

    fn ofView(view: Id) ?*MacWindow {
        return objc.owner(MacWindow, view);
    }

    /// Where an event happened, in the view (top left at 0, 0): on a popup,
    /// by way of the screen (so in the window's coordinates still).
    fn locate(w: *const MacWindow, event: Id) [2]f32 {
        var in_window = msg(objc.Point, event, "locationInWindow", .{});
        const from = msg(Id, event, "window", .{});
        if (from != null and from != w.win) {
            const on_screen = msg(objc.Point, from, "convertPointToScreen:", .{in_window});
            in_window = msg(objc.Point, w.win, "convertPointFromScreen:", .{on_screen});
        }
        const p = msg(objc.Point, w.view, "convertPoint:fromView:", .{ in_window, @as(Id, null) });
        return .{ @floatCast(p.x), @floatCast(p.y) };
    }

    /// Whether the pointer is over the window or one of its popups (where
    /// leaving one for another is not leaving).
    fn pointerOver(w: *const MacWindow) bool {
        const at = msg(objc.Point, objc.class("NSEvent"), "mouseLocation", .{});
        const inside = struct {
            fn f(r: objc.Rect, p: objc.Point) bool {
                return p.x >= r.origin.x and p.x < r.origin.x + r.size.width and p.y >= r.origin.y and p.y < r.origin.y + r.size.height;
            }
        }.f;
        if (inside(objc.msgRect(w.win, "frame"), at)) return true;
        for (w.popups) |slot| if (slot) |pop| {
            if (pop.placement.kind == .menu and inside(objc.msgRect(pop.panel, "frame"), at)) return true;
        };
        return false;
    }

    fn mouse(view: Id, event: Id, button: window.PointerButton, pressed: bool) void {
        const w = ofView(view) orelse return;
        if (button == .left and pressed) {
            const kept = objc.retain(event);
            objc.release(w.last_press);
            w.last_press = kept;
        }
        const pos = w.locate(event);
        w.push(.{ .motion = pos });
        w.push(.{ .button = .{ .pos = pos, .button = button, .pressed = pressed } });
    }

    fn key(view: Id, event: Id, pressed: bool) void {
        const w = ofView(view) orelse return;
        const flags = msg(u64, event, "modifierFlags", .{});
        w.modifiers = flags;
        // A key the toolkit has no name for still types what it does.
        const which_key = window.evdev.keyOf(linuxKey(msg(u16, event, "keyCode", .{})) orelse 0);
        // What it types (none for controls and function keys).
        var char: ?u21 = null;
        if (pressed) {
            const text = objc.utf8(msg(Id, event, "characters", .{}));
            if (text.len > 0) if (std.unicode.utf8Decode(text[0..(std.unicode.utf8ByteSequenceLength(text[0]) catch 1)])) |ch| {
                if (ch >= 0x20 and ch != 0x7f and !(ch >= 0xf700 and ch <= 0xf8ff)) char = ch;
            } else |_| {};
        }
        const ctrl = flags & (flag_control | flag_command) != 0;
        if (which_key == .other and (char == null or ctrl)) return;
        w.push(.{ .key = .{ .key = which_key, .pressed = pressed, .char = if (ctrl) null else char, .shift = flags & flag_shift != 0, .ctrl = ctrl } });
    }

    const view_methods = struct {
        fn yesFn(_: Id, _: objc.Sel) callconv(.c) objc.Bool {
            return objc.yes;
        }
        fn mouseDown(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, .left, true);
        }
        fn mouseUp(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, .left, false);
        }
        fn rightMouseDown(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, .right, true);
        }
        fn rightMouseUp(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, .right, false);
        }
        fn otherMouseDown(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, .middle, true);
        }
        fn otherMouseUp(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            mouse(v, e, .middle, false);
        }
        fn mouseMoved(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            const w = ofView(v) orelse return;
            if (w.pointer_locked) {
                // Held still: how far the mouse moved, in points (down
                // is positive).
                const dx = msg(objc.CGFloat, e, "deltaX", .{});
                const dy = msg(objc.CGFloat, e, "deltaY", .{});
                if (dx != 0 or dy != 0) w.push(.{ .relative_motion = .{ @floatCast(dx), @floatCast(dy) } });
                return;
            }
            w.push(.{ .motion = w.locate(e) });
        }
        fn mouseExited(v: Id, _: objc.Sel, _: Id) callconv(.c) void {
            const w = ofView(v) orelse return;
            // From the window onto a popup (or back) it has not left.
            if (w.pointerOver()) return;
            w.push(.leave);
        }
        fn scrollWheel(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            const w = ofView(v) orelse return;
            // A trackpad's in points; a wheel's in lines (about ten each).
            const precise = msg(objc.Bool, e, "hasPreciseScrollingDeltas", .{}) != 0;
            const k: f64 = if (precise) 1 else 10;
            const dx = msg(objc.CGFloat, e, "scrollingDeltaX", .{});
            const dy = msg(objc.CGFloat, e, "scrollingDeltaY", .{});
            w.push(.{ .scroll = .{ .pos = w.locate(e), .dx = @floatCast(-dx * k), .dy = @floatCast(-dy * k) } });
        }
        fn keyDown(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            key(v, e, true);
        }
        fn keyUp(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            key(v, e, false);
        }
        fn flagsChanged(v: Id, _: objc.Sel, e: Id) callconv(.c) void {
            const w = ofView(v) orelse return;
            w.modifiers = msg(u64, e, "modifierFlags", .{});
        }
        fn nothing(_: Id, _: objc.Sel) callconv(.c) void {}
    };

    const delegate_methods = struct {
        fn windowShouldClose(d: Id, _: objc.Sel, _: Id) callconv(.c) objc.Bool {
            // The app closes it, if it will, when it takes the request.
            if (objc.owner(MacWindow, d)) |w| w.close_requested = true;
            postWake();
            return objc.no;
        }
        fn changed(d: Id, _: objc.Sel, _: Id) callconv(.c) void {
            // A size or scale to apply: woken to.
            _ = d;
            postWake();
        }
        fn resized(d: Id, sel: objc.Sel, n: Id) callconv(.c) void {
            changed(d, sel, n);
            const w = objc.owner(MacWindow, d) orelse return;
            // Resized by its edge, AppKit keeps the app's loop until the
            // mouse is let go: a frame at each size is drawn from here
            // (and from the hold timer between). It is not zoomed until
            // let go.
            if (msg(objc.Bool, w.view, "inLiveResize", .{}) != 0) return w.drawNow();
            w.zoom_known = false;
        }
        /// The window lost the keyboard (the app went to the back, or
        /// another of its windows came forward), or began to be moved or
        /// resized: its menus are done.
        fn endMenus(d: Id, _: objc.Sel, _: Id) callconv(.c) void {
            const w = objc.owner(MacWindow, d) orelse return;
            w.endMenus();
            postWake();
        }
        /// The window lost the keyboard: its menus are done, and a pointer
        /// lock lets go until it gets it back.
        fn resignKey(d: Id, _: objc.Sel, _: Id) callconv(.c) void {
            const w = objc.owner(MacWindow, d) orelse return;
            w.endMenus();
            w.releasePointer();
            postWake();
        }
        fn becomeKey(d: Id, _: objc.Sel, _: Id) callconv(.c) void {
            const w = objc.owner(MacWindow, d) orelse return;
            if (w.lock_wanted) w.holdPointer();
        }
        fn modeChanged(d: Id, sel: objc.Sel, n: Id) callconv(.c) void {
            // Out of a live resize, or to or from full screen.
            if (objc.owner(MacWindow, d)) |w| w.zoom_known = false;
            changed(d, sel, n);
        }
        /// A refresh of the display (from the display link): the frame
        /// shown is on the screen, so the next can be drawn.
        fn displayTick(d: Id, _: objc.Sel, link: Id) callconv(.c) void {
            const w = objc.owner(MacWindow, d) orelse return;
            const media_now = objc.symbol(*const fn () callconv(.c) f64, "CACurrentMediaTime") orelse return;
            const refreshed = msg(f64, link, "timestamp", .{});
            const next = msg(f64, link, "targetTimestamp", .{});
            // On the window's clock (whatever Core Animation's is).
            const ago: u64 = @intFromFloat(@max(media_now() - refreshed, 0) * std.time.ns_per_s);
            if (next > refreshed) w.refresh_ns = @intFromFloat((next - refreshed) * std.time.ns_per_s);
            w.presented_ns = w.now() -| ago;
            w.frame_pending = false;
            msg(void, link, "setPaused:", .{objc.yes});
            postWake();
        }
        fn holdTick(d: Id, _: objc.Sel, _: Id) callconv(.c) void {
            const w = objc.owner(MacWindow, d) orelse return;
            // Not as well as a frame just drawn, for a resize.
            if (w.frame_pending and w.now() < w.presented_ns) return;
            w.drawNow();
        }
    };

    fn viewClass() objc.Class {
        const m = view_methods;
        const b = if (@import("builtin").cpu.arch == .aarch64) "B@:" else "c@:";
        return objc.makeClass("KeteView", "NSView", &.{
            .{ .sel = "acceptsFirstResponder", .imp = &m.yesFn, .types = b },
            .{ .sel = "isFlipped", .imp = &m.yesFn, .types = b },
            .{ .sel = "acceptsFirstMouse:", .imp = &m.yesFn, .types = b },
            .{ .sel = "mouseDown:", .imp = &m.mouseDown, .types = "v@:@" },
            .{ .sel = "mouseUp:", .imp = &m.mouseUp, .types = "v@:@" },
            .{ .sel = "rightMouseDown:", .imp = &m.rightMouseDown, .types = "v@:@" },
            .{ .sel = "rightMouseUp:", .imp = &m.rightMouseUp, .types = "v@:@" },
            .{ .sel = "otherMouseDown:", .imp = &m.otherMouseDown, .types = "v@:@" },
            .{ .sel = "otherMouseUp:", .imp = &m.otherMouseUp, .types = "v@:@" },
            .{ .sel = "mouseMoved:", .imp = &m.mouseMoved, .types = "v@:@" },
            .{ .sel = "mouseDragged:", .imp = &m.mouseMoved, .types = "v@:@" },
            .{ .sel = "rightMouseDragged:", .imp = &m.mouseMoved, .types = "v@:@" },
            .{ .sel = "otherMouseDragged:", .imp = &m.mouseMoved, .types = "v@:@" },
            .{ .sel = "mouseExited:", .imp = &m.mouseExited, .types = "v@:@" },
            .{ .sel = "scrollWheel:", .imp = &m.scrollWheel, .types = "v@:@" },
            .{ .sel = "keyDown:", .imp = &m.keyDown, .types = "v@:@" },
            .{ .sel = "keyUp:", .imp = &m.keyUp, .types = "v@:@" },
            .{ .sel = "flagsChanged:", .imp = &m.flagsChanged, .types = "v@:@" },
        });
    }

    fn delegateClass() objc.Class {
        const m = delegate_methods;
        const b = if (@import("builtin").cpu.arch == .aarch64) "B@:@" else "c@:@";
        return objc.makeClass("KeteWindowDelegate", "NSObject", &.{
            .{ .sel = "windowShouldClose:", .imp = &m.windowShouldClose, .types = b },
            .{ .sel = "windowDidResize:", .imp = &m.resized, .types = "v@:@" },
            .{ .sel = "windowDidEndLiveResize:", .imp = &m.modeChanged, .types = "v@:@" },
            .{ .sel = "windowDidResignKey:", .imp = &m.resignKey, .types = "v@:@" },
            .{ .sel = "windowDidBecomeKey:", .imp = &m.becomeKey, .types = "v@:@" },
            .{ .sel = "windowWillMove:", .imp = &m.endMenus, .types = "v@:@" },
            .{ .sel = "windowWillStartLiveResize:", .imp = &m.endMenus, .types = "v@:@" },
            .{ .sel = "holdTick:", .imp = &m.holdTick, .types = "v@:@" },
            .{ .sel = "displayTick:", .imp = &m.displayTick, .types = "v@:@" },
            .{ .sel = "windowDidChangeBackingProperties:", .imp = &m.changed, .types = "v@:@" },
            .{ .sel = "windowDidEnterFullScreen:", .imp = &m.modeChanged, .types = "v@:@" },
            .{ .sel = "windowDidExitFullScreen:", .imp = &m.modeChanged, .types = "v@:@" },
        });
    }
};

/// A frame shown in `layer` stays at its top left corner, as big as it
/// was drawn, until one is drawn at the layer's new size (rather than
/// being stretched to it).
fn keepTopLeft(layer: Id) void {
    if (objc.constant("kCAGravityTopLeft")) |g| msg(void, layer, "setContentsGravity:", .{g});
}

/// The windows open (Quit closes them all), and the display they are on
/// (AppKit has one application a process, and so kete one display).
var windows: std.ArrayList(*MacWindow) = .empty;
var current_display: ?*MacDisplay = null;

/// The app's connection to AppKit, which its windows are opened on
/// (`openWindow`) and wait through together (`wait`, `poll`, `watch`): the
/// application (its menu, with Quit, and its place in the Dock), its event
/// loop, and what is watched through the main run loop as well. There is
/// one a process.
pub const MacDisplay = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The sources watched through the run loop.
    watched: [8]?Watch = @splat(null),
    /// The app was asked to quit (Quit in its menu, Command and Q).
    quit_requested: bool = false,

    pub const platform: window.WindowPlatform = .macos;

    /// A source, its CFFileDescriptor and run loop source, and whether its
    /// fd has been readable since it was last read.
    const Watch = struct { source: window.Source, ref: ?*anyopaque, cf_source: ?*anyopaque, ready: bool = false };

    /// Starts the app (once a process), doing its I/O through `io`.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !*MacDisplay {
        _ = environ;
        if (current_display != null) return error.DisplayOpen;
        try objc.load();
        const pool = objc.push();
        defer objc.pop(pool);
        _ = startApp();
        const d = try gpa.create(MacDisplay);
        d.* = .{ .gpa = gpa, .io = io };
        current_display = d;
        return d;
    }

    /// Lets it go (its windows must be closed first).
    pub fn close(d: *MacDisplay) void {
        const pool = objc.push();
        defer objc.pop(pool);
        for (&d.watched) |*slot| if (slot.*) |_| d.unwatch(slot);
        if (current_display == d) current_display = null;
        d.gpa.destroy(d);
    }

    /// Opens a window on it (closed with `MacWindow.close`).
    pub fn openWindow(d: *MacDisplay, options: MacWindow.Options) !*MacWindow {
        return MacWindow.openOn(d, options);
    }

    /// Takes the request to quit, if there was one.
    pub fn takeQuitRequest(d: *MacDisplay) bool {
        defer d.quit_requested = false;
        return d.quit_requested;
    }

    /// Handles what has come, without waiting.
    pub fn poll(d: *MacDisplay) !void {
        pump(0);
        try d.readReady();
        for (windows.items) |w| w.updatePending();
    }

    /// Waits up to `timeout_ns` for something (an event, or a watched
    /// source readable), and handles what has come: not past when a frame
    /// a window showed is on the screen, when it can draw the next.
    pub fn wait(d: *MacDisplay, timeout_ns: u64) !void {
        var ns = timeout_ns;
        const now_ns = window.nowNs(d.io);
        for (windows.items) |w| if (w.pendingUntil()) |until| {
            ns = @min(ns, until -| now_ns);
        };
        // Watched fds wake it once each wait (a callback each time one is
        // readable would come again and again until it is read).
        if (cfFunctions()) |cf| for (d.watched) |slot| if (slot) |x| cf.enable(x.ref, 1);
        pump(@as(f64, @floatFromInt(ns)) / std.time.ns_per_s);
        try d.readReady();
        for (windows.items) |w| w.updatePending();
    }

    /// Reads, through `io`, the watched sources whose fds were readable.
    fn readReady(d: *MacDisplay) !void {
        for (&d.watched) |*slot| if (slot.*) |*x| if (x.ready) {
            x.ready = false;
            const op = x.source.read(x.source.ctx) orelse continue;
            const result = try d.io.operate(op);
            x.source.done(x.source.ctx, result);
        };
    }

    /// Waits on `source` too (or stops, if not `on`): `wait` returns when
    /// its fd is readable, and has read it through `io`.
    pub fn watch(d: *MacDisplay, source: window.Source, on: bool) void {
        for (&d.watched) |*slot| if (slot.*) |x| if (x.source.eql(source)) {
            if (!on) d.unwatch(slot);
            return;
        };
        if (!on) return;
        const cf = cfFunctions() orelse return;
        for (&d.watched) |*slot| if (slot.* == null) {
            // The slot (where it stays) is the callback's.
            var ctx: CFContext = .{ .info = slot };
            const ref = cf.create(null, source.fd, 0, fdReadable, &ctx) orelse return;
            cf.enable(ref, 1);
            const cf_source = cf.source(null, ref, 0);
            cf.addSource(cf.mainLoop(), cf_source, objc.constant("kCFRunLoopCommonModes"));
            slot.* = .{ .source = source, .ref = ref, .cf_source = cf_source };
            return;
        };
    }

    fn unwatch(_: *MacDisplay, slot: *?Watch) void {
        const x = slot.* orelse return;
        if (cfFunctions()) |cf| {
            cf.invalidateSource(x.cf_source);
            cf.invalidate(x.ref);
            cf.release(x.cf_source);
            cf.release(x.ref);
        }
        slot.* = null;
    }
};
var app_started = false;

/// The shared application, started once: in the Dock, with a menu (the
/// app's, with Quit), and Quit asking the windows to close rather than
/// ending the process.
fn startApp() Id {
    const app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
    if (app_started) return app;
    app_started = true;
    _ = msg(objc.Bool, app, "setActivationPolicy:", .{@as(isize, 0)});
    const delegate = msg(Id, objc.makeClass("KeteAppDelegate", "NSObject", &.{
        .{ .sel = "applicationShouldTerminate:", .imp = &shouldTerminate, .types = "Q@:@" },
    }), "new", .{});
    msg(void, app, "setDelegate:", .{delegate});

    const bar = objc.new(objc.class("NSMenu"));
    const app_item = objc.new(objc.class("NSMenuItem"));
    msg(void, bar, "addItem:", .{app_item});
    const app_menu = objc.new(objc.class("NSMenu"));
    const quit = msg(Id, msg(Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{ objc.nsString("Quit"), objc.sel("terminate:"), objc.nsString("q") });
    msg(void, app_menu, "addItem:", .{quit});
    msg(void, app_item, "setSubmenu:", .{app_menu});
    msg(void, app, "setMainMenu:", .{bar});
    msg(void, app, "finishLaunching", .{});
    return app;
}

fn shouldTerminate(_: Id, _: objc.Sel, _: Id) callconv(.c) u64 {
    if (current_display) |d| d.quit_requested = true;
    postWake();
    // NSTerminateCancel: the app quits, if it will, when it takes the
    // request.
    return 0;
}

/// Handles AppKit's events: those that have come, or the first to come
/// within `seconds` (and those after it).
fn pump(seconds: f64) void {
    const pool = objc.push();
    defer objc.pop(pool);
    const app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
    const mode = objc.constant("NSDefaultRunLoopMode");
    // Should AppKit hold on to it for longer, frames are drawn meanwhile.
    for (windows.items) |w| w.armHoldTimer(seconds);
    defer for (windows.items) |w| w.armHoldTimer(null);
    var wait_for = seconds;
    while (true) {
        const until = msg(Id, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{wait_for});
        const event = msg(Id, app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ @as(u64, std.math.maxInt(u64)), until, mode, objc.yes }) orelse break;
        // Our own wakes are only to stop waiting.
        if (msg(u64, event, "type", .{}) != 15) msg(void, app, "sendEvent:", .{event});
        wait_for = 0;
    }
    msg(void, app, "updateWindows", .{});
}

/// Stops `pump` waiting (posting an event of the app's own, which it
/// passes over).
fn postWake() void {
    const app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
    const event = msg(Id, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
        @as(u64, 15), objc.Point{ .x = 0, .y = 0 }, @as(u64, 0), @as(f64, 0), @as(isize, 0), @as(Id, null), @as(i16, 0), @as(isize, 0), @as(isize, 0),
    });
    msg(void, app, "postEvent:atStart:", .{ event, objc.yes });
}

// --- CoreFoundation and CoreGraphics ---------------------------------------------------

const CFContext = extern struct {
    version: isize = 0,
    info: ?*anyopaque,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    describe: ?*const anyopaque = null,
};

const CF = struct {
    create: *const fn (?*anyopaque, sys.fd_t, u8, *const fn (?*anyopaque, u64, ?*anyopaque) callconv(.c) void, *const CFContext) callconv(.c) ?*anyopaque,
    enable: *const fn (?*anyopaque, u64) callconv(.c) void,
    source: *const fn (?*anyopaque, ?*anyopaque, isize) callconv(.c) ?*anyopaque,
    mainLoop: *const fn () callconv(.c) ?*anyopaque,
    addSource: *const fn (?*anyopaque, ?*anyopaque, Id) callconv(.c) void,
    invalidate: *const fn (?*anyopaque) callconv(.c) void,
    invalidateSource: *const fn (?*anyopaque) callconv(.c) void,
    release: *const fn (?*anyopaque) callconv(.c) void,
};

fn cfFunctions() ?CF {
    return .{
        .create = objc.symbol(@FieldType(CF, "create"), "CFFileDescriptorCreate") orelse return null,
        .enable = objc.symbol(@FieldType(CF, "enable"), "CFFileDescriptorEnableCallBacks") orelse return null,
        .source = objc.symbol(@FieldType(CF, "source"), "CFFileDescriptorCreateRunLoopSource") orelse return null,
        .mainLoop = objc.symbol(@FieldType(CF, "mainLoop"), "CFRunLoopGetMain") orelse return null,
        .addSource = objc.symbol(@FieldType(CF, "addSource"), "CFRunLoopAddSource") orelse return null,
        .invalidate = objc.symbol(@FieldType(CF, "invalidate"), "CFFileDescriptorInvalidate") orelse return null,
        .invalidateSource = objc.symbol(@FieldType(CF, "invalidateSource"), "CFRunLoopSourceInvalidate") orelse return null,
        .release = objc.symbol(@FieldType(CF, "release"), "CFRelease") orelse return null,
    };
}

/// A watched source's fd is readable: it is read after `pump`, which
/// stops waiting (it is watched again at the next `wait`).
fn fdReadable(_: ?*anyopaque, _: u64, info: ?*anyopaque) callconv(.c) void {
    const slot: *?MacDisplay.Watch = @ptrCast(@alignCast(info orelse return));
    if (slot.*) |*x| x.ready = true;
    postWake();
}

const CG = struct {
    colorSpace: *const fn () callconv(.c) ?*anyopaque,
    provider: *const fn (?*anyopaque, *const anyopaque, usize, ?*const fn (?*anyopaque, ?*const anyopaque, usize) callconv(.c) void) callconv(.c) ?*anyopaque,
    image: *const fn (usize, usize, usize, usize, usize, ?*anyopaque, u32, ?*anyopaque, ?*const anyopaque, bool, i32) callconv(.c) Id,
    releaseProvider: *const fn (?*anyopaque) callconv(.c) void,
    releaseImage: *const fn (Id) callconv(.c) void,
};

fn cgFunctions() ?CG {
    return .{
        .colorSpace = objc.symbol(@FieldType(CG, "colorSpace"), "CGColorSpaceCreateDeviceRGB") orelse return null,
        .provider = objc.symbol(@FieldType(CG, "provider"), "CGDataProviderCreateWithData") orelse return null,
        .image = objc.symbol(@FieldType(CG, "image"), "CGImageCreate") orelse return null,
        .releaseProvider = objc.symbol(@FieldType(CG, "releaseProvider"), "CGDataProviderRelease") orelse return null,
        .releaseImage = objc.symbol(@FieldType(CG, "releaseImage"), "CGImageRelease") orelse return null,
    };
}

/// Holding the pointer still (for a pointer lock): moving it, and whether
/// the mouse moves it.
const PointerFunctions = struct {
    warp: *const fn (objc.Point) callconv(.c) i32,
    associate: *const fn (u32) callconv(.c) i32,
};

fn pointerFunctions() ?PointerFunctions {
    return .{
        .warp = objc.symbol(@FieldType(PointerFunctions, "warp"), "CGWarpMouseCursorPosition") orelse return null,
        .associate = objc.symbol(@FieldType(PointerFunctions, "associate"), "CGAssociateMouseAndMouseCursorPosition") orelse return null,
    };
}

// --- Keys ------------------------------------------------------------------------------

/// The Linux key code (which `window.evdev` makes a `KeyboardKey` of) of a macOS one.
pub fn linuxKey(mac: u16) ?u32 {
    return switch (mac) {
        0 => 30, // A
        1 => 31, // S
        2 => 32, // D
        3 => 33, // F
        4 => 35, // H
        5 => 34, // G
        6 => 44, // Z
        7 => 45, // X
        8 => 46, // C
        9 => 47, // V
        11 => 48, // B
        12 => 16, // Q
        13 => 17, // W
        14 => 18, // E
        15 => 19, // R
        16 => 21, // Y
        17 => 20, // T
        18 => 2, // 1
        19 => 3, // 2
        20 => 4, // 3
        21 => 5, // 4
        22 => 7, // 6
        23 => 6, // 5
        24 => 13, // =
        25 => 10, // 9
        26 => 8, // 7
        27 => 12, // -
        28 => 9, // 8
        29 => 11, // 0
        30 => 27, // ]
        31 => 24, // O
        32 => 22, // U
        33 => 26, // [
        34 => 23, // I
        35 => 25, // P
        36 => 28, // Return
        37 => 38, // L
        38 => 36, // J
        39 => 40, // '
        40 => 37, // K
        41 => 39, // ;
        42 => 43, // backslash
        43 => 51, // ,
        44 => 53, // /
        45 => 49, // N
        46 => 50, // M
        47 => 52, // .
        48 => 15, // Tab
        49 => 57, // Space
        50 => 41, // `
        51 => 14, // Delete (backspace)
        10 => 86, // the ISO key by the left Shift
        53 => 1, // Escape
        65 => 83, // keypad .
        67 => 55, // keypad *
        69 => 78, // keypad +
        71 => 69, // keypad Clear (Num Lock)
        75 => 98, // keypad /
        76 => 96, // keypad Enter
        78 => 74, // keypad -
        81 => 117, // keypad =
        82 => 82, // keypad 0
        83 => 79, // keypad 1
        84 => 80, // keypad 2
        85 => 81, // keypad 3
        86 => 75, // keypad 4
        87 => 76, // keypad 5
        88 => 77, // keypad 6
        89 => 71, // keypad 7
        91 => 72, // keypad 8
        92 => 73, // keypad 9
        96 => 63, // F5
        97 => 64, // F6
        98 => 65, // F7
        99 => 61, // F3
        100 => 66, // F8
        101 => 67, // F9
        103 => 87, // F11
        109 => 68, // F10
        111 => 88, // F12
        114 => 110, // Help (Insert)
        115 => 102, // Home
        116 => 104, // Page Up
        117 => 111, // forward Delete
        118 => 62, // F4
        119 => 107, // End
        120 => 60, // F2
        121 => 109, // Page Down
        122 => 59, // F1
        123 => 105, // Left
        124 => 106, // Right
        125 => 108, // Down
        126 => 103, // Up
        else => null,
    };
}

test "macOS keys become the keyboard keys the toolkit has" {
    const keyOf = struct {
        fn f(mac: u16) window.KeyboardKey {
            return window.evdev.keyOf(linuxKey(mac) orelse 0);
        }
    }.f;
    try std.testing.expectEqual(window.KeyboardKey.escape, keyOf(53));
    try std.testing.expectEqual(window.KeyboardKey.tab, keyOf(48));
    try std.testing.expectEqual(window.KeyboardKey.enter, keyOf(36));
    try std.testing.expectEqual(window.KeyboardKey.left, keyOf(123));
    try std.testing.expectEqual(window.KeyboardKey.c, keyOf(8)); // for Command and C
    try std.testing.expect(linuxKey(200) == null);
}

test "a menu popup opens where the positioner puts it, on the screen, and shows what is drawn" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const w = MacWindow.open(testing.allocator, testing.io, .empty, .{ .title = "kete test", .size = .{ 300, 200 } }) catch return error.SkipZigTest;
    defer w.close();
    _ = try w.applyConfigure();
    const pool = objc.push();
    defer objc.pop(pool);

    // At the window's bottom right corner, bigger than the room below it
    // on most screens: it goes where the positioner says.
    const placement: window.PopupPlacement = .{ .kind = .menu, .anchor = .{ 299, 199, 1, 1 }, .size = .{ 240, 4000 }, .side = .below_right, .gap = 2 };
    const id = w.openPopup(placement) orelse return error.NoPopup;
    defer w.closePopup(id);
    const screen = msg(Id, w.win, "screen", .{}).?;
    const bounds = w.viewRectOf(objc.msgRect(screen, "visibleFrame"));
    const at = w.popupPosition(id).?;
    try testing.expectEqual(placement.positioner(.{ w.width, w.height }).place(bounds), at);
    // Taller than the screen: against its top, within it across.
    try testing.expectEqual(bounds[1], at[1]);
    try testing.expect(at[0] >= bounds[0] and at[0] + 240 <= bounds[0] + bounds[2]);

    const img = (try w.beginSoftwarePopupFrame(id)).?;
    try testing.expectEqual(@as(u32, 240 * w.scale), img.width);
    @memset(img.pixels, 0x80ff0000);
    try w.showPopup(id);
    const pop = w.popupOf(id).?;
    try testing.expect(msg(objc.Bool, pop.panel, "isVisible", .{}) != 0);
    // Over the window, not taking its keyboard.
    try testing.expect(msg(objc.Bool, pop.panel, "canBecomeKeyWindow", .{}) == 0);
}
