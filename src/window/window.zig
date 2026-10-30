//! Window abstraction (`Window` vtable interface), input events (`InputEvent`),
//! text input state (`TextInputState`), window controls (`WindowControls`), keyboard
//! layout (`KeyboardLayout`) and keymaps (`xkb`), and the built-in window backends:
//! a Wayland client (`WaylandWindow`), a macOS one (`MacWindow`) and a
//! Windows one (`Win32Window`). `NativeWindow` is the one for the system
//! being built for.
//!
//! Apps can either use a backend directly or implement custom window
//! backends (for SDL or GLFW, say) via `Window.of(&impl)`.
//!
//! Windows are opened on a `Display` (the app's connection to the windowing
//! system: `NativeDisplay` is the system's), and wait through it together.
//! They do their I/O, and wait, through the app's `std.Io` (given when
//! the display is opened): what they wait on (their connection, and the
//! `Source`s watched with theirs) is read in one `std.Io.Batch`, so that
//! other tasks on the `Io` go on while the UI waits.

const std = @import("std");
const gfx = @import("gfx");

pub const clipboard = @import("clipboard.zig");
pub const positioner_mod = @import("positioner.zig");
/// Where popups go, as Wayland's `xdg_positioner` says.
pub const Positioner = positioner_mod.Positioner;
pub const present = @import("present.zig");
/// Presents `gfx.Frame`s in a window with a renderer.
pub const Presenter = present.Presenter;
pub const wayland = @import("wayland.zig");

pub const Clipboard = clipboard.Clipboard;
pub const DroppedData = clipboard.DroppedData;
pub const WaylandWindow = wayland.WaylandWindow;
pub const macos = @import("macos.zig");
pub const MacWindow = macos.MacWindow;
pub const win32 = @import("win32.zig");
pub const Win32Window = win32.Win32Window;
/// The window backend for the system being built for: AppKit's on macOS,
/// Win32's on Windows, Wayland's elsewhere.
pub const NativeWindow = switch (@import("builtin").os.tag) {
    .macos => MacWindow,
    .windows => Win32Window,
    else => WaylandWindow,
};
pub const WaylandDisplay = wayland.WaylandDisplay;
pub const MacDisplay = macos.MacDisplay;
pub const Win32Display = win32.Win32Display;
/// The display for the system being built for (that `NativeWindow`s are
/// opened on).
pub const NativeDisplay = switch (@import("builtin").os.tag) {
    .macos => MacDisplay,
    .windows => Win32Display,
    else => WaylandDisplay,
};

/// Now, in nanoseconds on the clock frames and input are timed on (the
/// monotonic one: `std.Io.Clock.awake`).
pub fn nowNs(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Clock.awake.now(io).nanoseconds));
}

/// Something a window waits on as well as its own events (a `sys.Wake`,
/// the accessibility bus): its fd, its next read through `std.Io` (into a
/// buffer of its own, which must last until `done`; null if there is
/// nothing to read now), and what to do with what that read.
pub const Source = struct {
    ctx: *anyopaque,
    fd: sys.fd_t,
    read: *const fn (ctx: *anyopaque) ?std.Io.Operation,
    done: *const fn (ctx: *anyopaque, result: std.Io.Operation.Result) void,

    /// A `sys.Wake`'s: read to take its wakes (which are dropped: the one
    /// that signals it says what it was for).
    pub fn ofWake(w: *sys.Wake) Source {
        const S = struct {
            fn read(ctx: *anyopaque) ?std.Io.Operation {
                return @as(*sys.Wake, @ptrCast(@alignCast(ctx))).readOperation();
            }
            fn done(_: *anyopaque, _: std.Io.Operation.Result) void {}
        };
        return .{ .ctx = w, .fd = w.fd(), .read = S.read, .done = S.done };
    }

    /// Whether two are the same source.
    pub fn eql(a: Source, b: Source) bool {
        return a.ctx == b.ctx and a.fd == b.fd;
    }
};

/// The most sources `waitSources` waits on at once.
pub const max_sources = 16;

/// Waits through `io` until one of `sources` has read something, or for
/// `timeout_ns` nanoseconds (forever if `maxInt(u64)`), and gives each what it read
/// (some may have read something even if others were first).
/// `error.Canceled` if the task is canceled.
pub fn waitSources(io: std.Io, sources: []const Source, timeout_ns: u64) !void {
    const timeout: std.Io.Timeout = if (timeout_ns == std.math.maxInt(u64))
        .none
    else
        .{ .duration = .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake } };
    // Which source each read is of.
    var of: [max_sources]usize = undefined;
    var ops: [max_sources]std.Io.Operation = undefined;
    var n: usize = 0;
    for (sources, 0..) |s, i| {
        if (n == max_sources) break;
        ops[n] = s.read(s.ctx) orelse continue;
        of[n] = i;
        n += 1;
    }
    if (n == 0) return timeout.sleep(io);
    var storage: [max_sources]std.Io.Operation.Storage = undefined;
    var batch: std.Io.Batch = .init(storage[0..n]);
    for (ops[0..n], 0..) |op, i| batch.addAt(@intCast(i), op);
    const waited = batch.awaitConcurrent(io, timeout);
    // The reads not done are given up; those done (even while being given
    // up) are handled.
    batch.cancel(io);
    while (batch.next()) |c| {
        const s = sources[of[c.index]];
        s.done(s.ctx, c.result);
    }
    waited catch |e| switch (e) {
        error.Timeout => {},
        else => return e,
    };
}

/// A key of the keyboard, by where it is and what it is called on a common
/// keyboard, whatever the layout: `.a` is the key that types "a" on a US
/// keyboard. Its keymap says what it types (`InputEvent.key`'s `char`).
pub const KeyboardKey = enum {
    escape,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    print_screen,
    scroll_lock,
    /// Pause or Break.
    pause,
    /// The key left of 1: ` and ~ on a US keyboard.
    grave,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,
    digit_0,
    /// - on a US keyboard.
    minus,
    /// = on a US keyboard.
    equal,
    backspace,
    tab,
    q,
    w,
    e,
    r,
    t,
    y,
    u,
    i,
    o,
    p,
    /// [ on a US keyboard.
    left_bracket,
    /// ] on a US keyboard.
    right_bracket,
    /// \ on a US keyboard.
    backslash,
    /// The Caps Lock key.
    caps_lock,
    a,
    s,
    d,
    f,
    g,
    h,
    j,
    k,
    l,
    /// ; on a US keyboard.
    semicolon,
    /// ' on a US keyboard.
    apostrophe,
    enter,
    left_shift,
    /// The key by the left Shift on some keyboards.
    intl_backslash,
    z,
    x,
    c,
    v,
    b,
    n,
    m,
    comma,
    period,
    slash,
    right_shift,
    left_ctrl,
    /// The Windows, Command or Super key, on the left.
    left_super,
    left_alt,
    space,
    right_alt,
    /// The Windows, Command or Super key, on the right.
    right_super,
    /// The key that asks for a context menu.
    menu,
    right_ctrl,
    insert,
    delete,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
    num_lock,
    keypad_divide,
    keypad_multiply,
    keypad_minus,
    keypad_plus,
    keypad_enter,
    keypad_equal,
    keypad_decimal,
    keypad_0,
    keypad_1,
    keypad_2,
    keypad_3,
    keypad_4,
    keypad_5,
    keypad_6,
    keypad_7,
    keypad_8,
    keypad_9,
    /// Any other.
    other,
};

/// A button of the pointer (a mouse's), in `InputEvent.button`.
pub const PointerButton = enum {
    /// The main button, to press and select with.
    left,
    /// The second button, to ask for a context menu with.
    right,
    /// The wheel, pressed.
    middle,
    /// The buttons at the side of a mouse, for going back and forward.
    back,
    forward,
    /// Any other.
    other,
};

/// The pointer shape the window shows (`Window.setCursor`). macOS has no
/// shape for `wait`, `progress`, `help`, `nwse_resize` or `nesw_resize`, and
/// shows the arrow for them.
pub const PointerCursor = enum {
    /// The arrow.
    default,
    /// A hand, over something that can be pressed (a link).
    pointer,
    /// An I-beam, over text.
    text,
    /// An open hand, over something that can be dragged.
    grab,
    /// A closed hand, while something is being dragged.
    grabbing,
    /// A cross, to point exactly.
    crosshair,
    /// Something is being moved.
    move,
    /// What is under the pointer cannot be used.
    not_allowed,
    /// The app is busy and cannot be used.
    wait,
    /// The app is busy but can still be used.
    progress,
    /// A question mark: help is there to be had.
    help,
    /// Resizing left and right.
    ew_resize,
    /// Resizing up and down.
    ns_resize,
    /// Resizing along the diagonal from the top left to the bottom right.
    nwse_resize,
    /// Resizing along the diagonal from the top right to the bottom left.
    nesw_resize,
};

/// The focused text widget's state, for the platform's input method.
pub const TextInputState = struct {
    /// The text around the cursor (all of it, or the part near it), for the
    /// input method to suggest from.
    surrounding_text: []const u8 = "",
    /// Byte offsets of the cursor and the selection's other end in
    /// `surrounding_text`.
    cursor: u32 = 0,
    anchor: u32 = 0,
    /// Whether the input method or something else (the app, the user
    /// editing directly) made the last change.
    change_cause: ChangeCause = .input_method,
    /// The text is secret: the input method should not learn or suggest it.
    password: bool = false,
    /// Enter adds a new line, rather than ending the text.
    multiline: bool = false,
    /// The cursor in window coordinates, in logical pixels (`[x, y, width, height]`).
    cursor_rect: [4]i32 = .{ 0, 0, 1, 20 },

    /// What made the last change to the text, for the input method.
    pub const ChangeCause = enum {
        /// The input method (its commit, or its deletion around the cursor).
        input_method,
        /// The app, or the user editing directly.
        other,
    };

    /// Whether two are the same, so a window need only be told of a change.
    pub fn eql(a: TextInputState, b: TextInputState) bool {
        return a.cursor == b.cursor and
            a.anchor == b.anchor and
            a.change_cause == b.change_cause and
            a.password == b.password and
            a.multiline == b.multiline and
            std.mem.eql(i32, &a.cursor_rect, &b.cursor_rect) and
            std.mem.eql(u8, a.surrounding_text, b.surrounding_text);
    }
};

/// What a receiver may do with what is dragged to it (see `Window.startDrag`).
pub const DragActions = struct {
    /// Make a copy of it.
    copy: bool = false,
    /// Take it from where it was dragged.
    move: bool = false,
    /// Ask the user which.
    ask: bool = false,
};

/// What the user did in the window, in `Window.takeInput`. The key, button,
/// scroll, pointer and popup events come from every window; so far, touch,
/// locked pointer, text input and drag-and-drop events come only from Wayland
/// ones (macOS and Windows windows do not make them yet).
/// Positions are `[x, y]` in logical pixels from the window's top left.
pub const InputEvent = union(enum) {
    /// The pointer moved to (or entered at) a position in the window.
    motion: [2]f32,
    /// A pointer button went down or up, with the pointer at `pos`.
    button: struct { pos: [2]f32, button: PointerButton, pressed: bool },
    /// A key went down or up: which it is, what it types (from the keymap)
    /// and the modifiers held, if the window has a keymap.
    key: struct { key: KeyboardKey, pressed: bool, char: ?u21 = null, shift: bool = false, ctrl: bool = false },
    /// The wheel turned: by `dy` logical pixels down (and `dx` right), with
    /// the pointer at `pos`.
    scroll: struct { pos: [2]f32, dx: f32, dy: f32 },
    /// The pointer left the window.
    leave,
    /// A touch went down at a position (`id` is the touch's while it
    /// lasts), moved, or came up.
    touch_down: struct { id: i32, pos: [2]f32 },
    touch_motion: struct { id: i32, pos: [2]f32 },
    touch_up: i32,
    /// The window's touches were cancelled by the shell.
    touch_cancel,
    /// Relative pointer motion `[dx, dy]`, in logical pixels, for a locked
    /// pointer (not yet on macOS and Windows).
    relative_motion: [2]f32,
    /// The pointer lock took effect (true), or ended (false) (not yet on macOS and Windows).
    pointer_locked: bool,
    /// An input method committed UTF-8 text (not yet on macOS and Windows).
    text_commit: struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    },
    /// An input method updated its preedit string, the text it is still composing.
    text_preedit: struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
        cursor_begin: i32 = 0,
        cursor_end: i32 = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    },
    /// An input method asked to delete bytes around the cursor.
    text_delete_surrounding: struct { before_length: u32, after_length: u32 },
    /// Something being dragged entered the window at a position (not yet on
    /// macOS and Windows).
    drag_enter: [2]f32,
    /// Something being dragged moved to a position in the window.
    drag_motion: [2]f32,
    /// Something being dragged left the window.
    drag_leave,
    /// Something was dropped at a position in the window (`Window.takeDrop`
    /// has what).
    drop: [2]f32,
    /// The window system closed a popup (`Window.openPopup`), with this id:
    /// a menu, when its pointer or keyboard was used elsewhere.
    popup_done: u32,
};

/// Windowing system / display server backend.
pub const WindowPlatform = enum {
    /// No window system: the app has no window.
    headless,
    /// Wayland (`WaylandWindow`).
    wayland,
    /// Windows (`Win32Window`).
    windows,
    /// macOS (`MacWindow`).
    macos,
    /// A backend of the app's own that does not say.
    custom,

    pub fn name(p: WindowPlatform) []const u8 {
        return switch (p) {
            .headless => "Headless",
            .wayland => "Wayland",
            .windows => "Windows",
            .macos => "macOS",
            .custom => "Custom",
        };
    }
};

/// Surface buffer presentation mechanism.
pub const WindowBufferTransport = enum {
    /// Frames drawn on the CPU, in memory the window system takes (shared
    /// memory with the compositor on Wayland).
    memory,
    /// Frames drawn on the GPU into dmabufs the compositor takes (Linux).
    linux_dmabuf,
    /// Frames drawn on the GPU into the window's own swapchain (a Metal
    /// layer on macOS).
    swapchain,
    /// A backend of the app's own that does not say.
    custom,

    pub fn name(t: WindowBufferTransport) []const u8 {
        return switch (t) {
            .memory => "CPU Memory",
            .linux_dmabuf => "linux_dmabuf",
            .swapchain => "Swapchain",
            .custom => "Custom",
        };
    }
};

/// Whether window decorations (title bar, drop shadows, resize borders) are
/// drawn by the toolkit (`toolkit`), the window system (`system`), or not at
/// all (`none`).
pub const WindowDecorations = enum {
    /// There are none: the window has no title bar or borders.
    none,
    /// The toolkit draws them: a `TitleBar` in the window, with a shadow and
    /// resize borders of its own. Used where the window system does not
    /// draw them.
    toolkit,
    /// The window system draws them.
    system,

    pub fn name(d: WindowDecorations) []const u8 {
        return switch (d) {
            .none => "None",
            .toolkit => "Toolkit",
            .system => "System",
        };
    }
};

/// How the window system knows a GPU buffer's drawing is finished (and
/// the window when it may draw in it again).
pub const WindowBufferSync = enum {
    /// There is nothing to wait for: the buffers are in CPU memory.
    none,
    /// Fences the kernel keeps with each buffer (dmabuf implicit sync). Linux
    /// only.
    implicit,
    /// Explicit timeline points the window and the GPU signal (Linux DRM
    /// syncobjs; `wp_linux_drm_syncobj_v1` on Wayland). Linux only.
    explicit,

    pub fn name(s: WindowBufferSync) []const u8 {
        return switch (s) {
            .none => "None",
            .implicit => "Implicit (dma-buf fences)",
            .explicit => "Explicit (DRM syncobj)",
        };
    }
};

/// How frames are paced and synchronized with the display, and what the
/// window system offers for it. Only `vsync` is known everywhere; the rest
/// are what Wayland compositors offer (and are false on other platforms).
pub const WindowFrameSync = packed struct(u8) {
    /// Frames are shown at most once a refresh, without tearing.
    vsync: bool = false,
    /// The window system says when to draw the next frame (Wayland's
    /// `wl_surface.frame`).
    frame_callback: bool = false,
    /// The window system says when each frame was shown (Wayland's
    /// `wp_presentation`).
    presentation_time: bool = false,
    /// Each frame waits for the last to be shown, not replacing it (Wayland's
    /// `wp_fifo_v1`).
    fifo: bool = false,
    /// Frames can be set to be shown at a time (Wayland's
    /// `wp_commit_timing_v1`: see `Window.setPresentationTime`).
    timed_presentation: bool = false,
    /// Unused: it makes the struct a whole byte.
    _pad: u3 = 0,
};

/// What a popup is for. A menu takes the keyboard and the pointer, and
/// goes when they are used outside the app; a tooltip takes no input (the
/// pointer goes through it).
pub const PopupKind = enum {
    /// A menu.
    menu,
    /// A tooltip.
    tooltip,
};

/// Where a popup goes (`Window.openPopup`), in the window's coordinates
/// (logical pixels). Where there is no room on the screen, it flips to the
/// other side of the anchor, or slides along it.
pub const PopupPlacement = struct {
    kind: PopupKind,
    /// The rectangle it is placed against, `[x, y, width, height]`.
    anchor: [4]i32,
    /// Its size, `[width, height]`.
    size: [2]u32,
    side: Side,
    /// How far it is from the anchor.
    gap: i32 = 0,

    /// Which side of the anchor a popup goes.
    pub const Side = enum {
        /// Down and to the right of the anchor's top left corner (a menu at
        /// a point: a 1 by 1 anchor).
        below_right,
        /// Centred above the anchor (a tooltip).
        above,
    };

    pub fn eql(a: PopupPlacement, b: PopupPlacement) bool {
        return std.meta.eql(a, b);
    }

    /// As Wayland's `xdg_positioner` says it (which the compositor places it
    /// by there, and `Positioner.place` elsewhere), in a window
    /// `window_size` big (the anchor kept inside it, as Wayland wants).
    pub fn positioner(pl: PopupPlacement, window_size: [2]u32) positioner_mod.Positioner {
        const ww: i32 = @intCast(@max(window_size[0], 1));
        const wh: i32 = @intCast(@max(window_size[1], 1));
        const ax = std.math.clamp(pl.anchor[0], 0, ww - 1);
        const ay = std.math.clamp(pl.anchor[1], 0, wh - 1);
        const rect: positioner_mod.Rect = .{ ax, ay, std.math.clamp(pl.anchor[2], 1, ww - ax), std.math.clamp(pl.anchor[3], 1, wh - ay) };
        const size: [2]i32 = .{ @intCast(@max(pl.size[0], 1)), @intCast(@max(pl.size[1], 1)) };
        return switch (pl.side) {
            .below_right => .{ .size = size, .anchor_rect = rect, .anchor = .top_left, .gravity = .bottom_right, .offset = .{ pl.gap, pl.gap }, .adjust = .{ .flip_x = true, .flip_y = true, .slide_x = true, .slide_y = true } },
            .above => .{ .size = size, .anchor_rect = rect, .anchor = .top, .gravity = .top, .offset = .{ 0, -pl.gap }, .adjust = .{ .flip_y = true, .slide_x = true, .slide_y = true } },
        };
    }
};

/// The most parts of a window the window system draws over its content
/// (`Window.cutouts`).
pub const max_cutouts = 4;

/// Generic window interface (`Window.of(&impl)`).
pub const Window = struct {
    /// The window it stands for (a pointer to a backend's window).
    ptr: *anyopaque,
    /// The functions that act on `ptr`.
    vtable: *const VTable,

    pub const VTable = struct {
        platform: *const fn (ptr: *anyopaque) WindowPlatform,
        bufferTransport: *const fn (ptr: *anyopaque) WindowBufferTransport,
        bufferSync: *const fn (ptr: *anyopaque) WindowBufferSync,
        frameSync: *const fn (ptr: *anyopaque) WindowFrameSync,
        refreshHz: *const fn (ptr: *anyopaque) f32,
        decorations: *const fn (ptr: *anyopaque) WindowDecorations,
        title: *const fn (ptr: *anyopaque) []const u8,
        setTitle: *const fn (ptr: *anyopaque, title: []const u8) void,
        poll: *const fn (ptr: *anyopaque) anyerror!void,
        wait: *const fn (ptr: *anyopaque, timeout_ns: u64) anyerror!void,
        takeInput: *const fn (ptr: *anyopaque) []const InputEvent,
        size: *const fn (ptr: *anyopaque) [2]u32,
        scale: *const fn (ptr: *anyopaque) u32,
        takeCloseRequest: *const fn (ptr: *anyopaque) bool,
        isSuspended: *const fn (ptr: *anyopaque) bool,
        isMaximized: *const fn (ptr: *anyopaque) bool,
        isFullscreen: *const fn (ptr: *anyopaque) bool,
        isTiled: *const fn (ptr: *anyopaque) bool,
        isFramePending: *const fn (ptr: *anyopaque) bool,
        setCursor: *const fn (ptr: *anyopaque, cursor: PointerCursor) void,
        setMinSize: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
        setRedraw: *const fn (ptr: *anyopaque, redraw: ?Redraw) void,
        setMaximized: *const fn (ptr: *anyopaque, on: bool) void,
        setMinimized: *const fn (ptr: *anyopaque) void,
        canMaximize: *const fn (ptr: *anyopaque) bool,
        canMinimize: *const fn (ptr: *anyopaque) bool,
        canFullscreen: *const fn (ptr: *anyopaque) bool,
        setFullscreen: *const fn (ptr: *anyopaque, on: bool) void,
        startMove: *const fn (ptr: *anyopaque) void,
        setTextInput: *const fn (ptr: *anyopaque, state: ?TextInputState) void,
        startDrag: *const fn (ptr: *anyopaque, mime_type: []const u8, bytes: []const u8, actions: DragActions) bool,
        takeDrop: *const fn (ptr: *anyopaque) ?DroppedData,
        nextPresentationNs: *const fn (ptr: *anyopaque, now_ns: u64) u64,
        setPresentationTime: *const fn (ptr: *anyopaque, target_ns: u64) void,
        layout: *const fn (ptr: *anyopaque) KeyboardLayout,
        watch: *const fn (ptr: *anyopaque, source: Source, on: bool) void,
        refreshNs: *const fn (ptr: *anyopaque) u64,
        cutouts: *const fn (ptr: *anyopaque, out: *[max_cutouts]gfx.Rect) usize,
        applyConfigure: *const fn (ptr: *anyopaque) anyerror!?[2]u32,
        releaseSpareBuffers: *const fn (ptr: *anyopaque) void,
        beginSoftwareFrame: *const fn (ptr: *anyopaque) anyerror!gfx.software.Image,
        beginDmabufFrame: *const fn (ptr: *anyopaque) ?gfx.DmabufTarget,
        beginMetalFrame: *const fn (ptr: *anyopaque) ?gfx.MetalTarget,
        beginD3D11Frame: *const fn (ptr: *anyopaque, device: *anyopaque) ?gfx.D3D11Target,
        bufferAge: *const fn (ptr: *anyopaque) u32,
        finishFrame: *const fn (ptr: *anyopaque, repainted: ?[]const gfx.Viewport) void,
        showDamaged: *const fn (ptr: *anyopaque, damage: ?[]const gfx.Viewport) anyerror!void,
        close: *const fn (ptr: *anyopaque) void,
        supportsPopups: *const fn (ptr: *anyopaque) bool,
        openPopup: *const fn (ptr: *anyopaque, placement: PopupPlacement) ?u32,
        closePopup: *const fn (ptr: *anyopaque, id: u32) void,
        popupPosition: *const fn (ptr: *anyopaque, id: u32) ?[2]i32,
        beginSoftwarePopupFrame: *const fn (ptr: *anyopaque, id: u32) anyerror!?gfx.software.Image,
        showPopup: *const fn (ptr: *anyopaque, id: u32) anyerror!void,
        copy: ?*const fn (ptr: *anyopaque, text: []const u8) void = null,
        paste: ?*const fn (ptr: *anyopaque, sink: clipboard.Sink) void = null,
        /// Whether the system's appearance is dark (null: it does not say).
        prefersDark: ?*const fn (ptr: *anyopaque) ?bool = null,
    };

    /// `win` as a `Window`: either one already, or a pointer to a type
    /// `of` takes.
    pub fn from(win: anytype) Window {
        return if (@TypeOf(win) == Window) win else of(win);
    }

    /// A `Window` for any backend: `impl` is a pointer to a struct that has
    /// what it supports as declarations (`poll`, `beginSoftwareFrame`, ...) or fields
    /// (`width`, `height`, ...). What it leaves out gets a default (no input,
    /// not maximized, no popups, ...), and it must outlive the `Window`.
    pub fn of(impl: anytype) Window {
        const Ptr = @TypeOf(impl);
        const T = @typeInfo(Ptr).pointer.child;
        const gen = struct {
            fn self(p: *anyopaque) *T {
                return @ptrCast(@alignCast(p));
            }
            fn platformFn(p: *anyopaque) WindowPlatform {
                if (@hasDecl(T, "platform")) {
                    if (@TypeOf(T.platform) == WindowPlatform) return T.platform;
                    return self(p).platform();
                }
                if (@hasField(T, "platform")) return self(p).platform;
                return .custom;
            }
            fn bufferTransportFn(p: *anyopaque) WindowBufferTransport {
                if (@hasDecl(T, "bufferTransport")) return self(p).bufferTransport();
                if (@hasDecl(T, "buffer_transport")) return T.buffer_transport;
                if (@hasField(T, "buffer_transport")) return self(p).buffer_transport;
                return .custom;
            }
            fn bufferSyncFn(p: *anyopaque) WindowBufferSync {
                if (@hasDecl(T, "bufferSync")) return self(p).bufferSync();
                if (@hasField(T, "buffer_sync")) return self(p).buffer_sync;
                return .none;
            }
            fn frameSyncFn(p: *anyopaque) WindowFrameSync {
                if (@hasDecl(T, "frameSync")) return self(p).frameSync();
                if (@hasField(T, "frame_sync")) return self(p).frame_sync;
                return .{};
            }
            fn refreshHzFn(p: *anyopaque) f32 {
                if (@hasDecl(T, "refreshHz")) return self(p).refreshHz();
                if (@hasField(T, "refresh_ns")) {
                    const r = self(p).refresh_ns;
                    if (r > 0) return @as(f32, @floatFromInt(std.time.ns_per_s)) / @as(f32, @floatFromInt(r));
                }
                return 0.0;
            }
            fn decorationsFn(p: *anyopaque) WindowDecorations {
                if (@hasDecl(T, "decorations")) {
                    if (@TypeOf(T.decorations) == WindowDecorations) return T.decorations;
                    return self(p).decorations();
                }
                if (@hasField(T, "decorations")) return self(p).decorations;
                return switch (platformFn(p)) {
                    .wayland => .toolkit,
                    .headless => .none,
                    else => .system,
                };
            }
            fn titleFn(p: *anyopaque) []const u8 {
                if (@hasDecl(T, "getTitle")) return self(p).getTitle();
                if (@hasField(T, "title")) return self(p).title;
                return "";
            }
            fn setTitleFn(p: *anyopaque, text: []const u8) void {
                if (@hasDecl(T, "setTitle")) self(p).setTitle(text);
            }
            fn pollFn(p: *anyopaque) anyerror!void {
                if (@hasDecl(T, "poll")) return self(p).poll();
            }
            fn waitFn(p: *anyopaque, timeout_ns: u64) anyerror!void {
                if (@hasDecl(T, "wait")) return self(p).wait(timeout_ns);
            }
            fn takeInputFn(p: *anyopaque) []const InputEvent {
                if (@hasDecl(T, "takeInput")) return self(p).takeInput();
                return &.{};
            }
            fn sizeFn(p: *anyopaque) [2]u32 {
                const s = self(p);
                if (@hasDecl(T, "size")) return s.size();
                return .{ s.width, s.height };
            }
            fn scaleFn(p: *anyopaque) u32 {
                const s = self(p);
                if (@hasDecl(T, "getScale")) return s.getScale();
                if (@hasField(T, "scale")) return s.scale;
                return 1;
            }
            fn takeCloseRequestFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasDecl(T, "takeCloseRequest")) return s.takeCloseRequest();
                if (@hasField(T, "close_requested")) {
                    defer s.close_requested = false;
                    return s.close_requested;
                }
                return false;
            }
            fn isSuspendedFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "suspended")) return s.suspended;
                return false;
            }
            fn isMaximizedFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "maximized")) return s.maximized;
                return false;
            }
            fn isFullscreenFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "fullscreen")) return s.fullscreen;
                return false;
            }
            fn isTiledFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "tiled")) return s.tiled;
                return false;
            }
            fn isFramePendingFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "frame_pending")) return s.frame_pending;
                return false;
            }
            fn setCursorFn(p: *anyopaque, cursor: PointerCursor) void {
                if (@hasDecl(T, "setCursor")) self(p).setCursor(cursor);
            }
            fn setMinSizeFn(p: *anyopaque, w: u32, h: u32) void {
                if (@hasDecl(T, "setMinSize")) self(p).setMinSize(w, h);
            }
            fn setRedrawFn(p: *anyopaque, r: ?Redraw) void {
                if (@hasDecl(T, "setRedraw")) self(p).setRedraw(r);
            }
            fn setMinimizedFn(p: *anyopaque) void {
                if (@hasDecl(T, "setMinimized")) self(p).setMinimized();
            }
            fn canMaximizeFn(p: *anyopaque) bool {
                if (@hasDecl(T, "canMaximize")) return self(p).canMaximize();
                return @hasDecl(T, "setMaximized");
            }
            fn canMinimizeFn(p: *anyopaque) bool {
                if (@hasDecl(T, "canMinimize")) return self(p).canMinimize();
                return @hasDecl(T, "setMinimized");
            }
            fn canFullscreenFn(p: *anyopaque) bool {
                if (@hasDecl(T, "canFullscreen")) return self(p).canFullscreen();
                return @hasDecl(T, "setFullscreen");
            }
            fn setMaximizedFn(p: *anyopaque, on: bool) void {
                if (@hasDecl(T, "setMaximized")) self(p).setMaximized(on);
            }
            fn setFullscreenFn(p: *anyopaque, on: bool) void {
                if (@hasDecl(T, "setFullscreen")) self(p).setFullscreen(on);
            }
            fn startMoveFn(p: *anyopaque) void {
                if (@hasDecl(T, "startMove")) self(p).startMove();
            }
            fn setTextInputFn(p: *anyopaque, state: ?TextInputState) void {
                if (@hasDecl(T, "setTextInput")) self(p).setTextInput(state);
            }
            fn startDragFn(p: *anyopaque, mime_type: []const u8, bytes: []const u8, actions: DragActions) bool {
                if (@hasDecl(T, "startDrag")) return self(p).startDrag(mime_type, bytes, actions);
                return false;
            }
            fn takeDropFn(p: *anyopaque) ?DroppedData {
                if (@hasDecl(T, "takeDrop")) return self(p).takeDrop();
                return null;
            }
            fn setPresentationTimeFn(p: *anyopaque, target_ns: u64) void {
                if (@hasDecl(T, "setPresentationTime")) self(p).setPresentationTime(target_ns);
            }
            fn nextPresentationNsFn(p: *anyopaque, now_ns: u64) u64 {
                if (@hasDecl(T, "nextPresentationNs")) return self(p).nextPresentationNs(now_ns);
                return now_ns;
            }
            fn watchFn(p: *anyopaque, source: Source, on: bool) void {
                if (@hasDecl(T, "watch")) self(p).watch(source, on);
            }
            fn layoutFn(p: *anyopaque) KeyboardLayout {
                if (@hasDecl(T, "layout")) return self(p).layout();
                return .{};
            }
            fn cutoutsFn(p: *anyopaque, out: *[max_cutouts]gfx.Rect) usize {
                if (@hasDecl(T, "cutouts")) return self(p).cutouts(out);
                return 0;
            }
            fn refreshNsFn(p: *anyopaque) u64 {
                if (@hasDecl(T, "refreshNs")) return self(p).refreshNs();
                if (@hasField(T, "refresh_ns")) return self(p).refresh_ns;
                return 0;
            }
            fn applyConfigureFn(p: *anyopaque) anyerror!?[2]u32 {
                if (@hasDecl(T, "applyConfigure")) return self(p).applyConfigure();
                return null;
            }
            fn releaseSpareBuffersFn(p: *anyopaque) void {
                if (@hasDecl(T, "releaseSpareBuffers")) self(p).releaseSpareBuffers();
            }
            fn beginSoftwareFrameFn(p: *anyopaque) anyerror!gfx.software.Image {
                if (@hasDecl(T, "beginSoftwareFrame")) return self(p).beginSoftwareFrame();
                return error.Unsupported;
            }
            fn beginDmabufFrameFn(p: *anyopaque) ?gfx.DmabufTarget {
                if (@hasDecl(T, "beginDmabufFrame")) return self(p).beginDmabufFrame();
                return null;
            }
            fn beginD3D11FrameFn(p: *anyopaque, device: *anyopaque) ?gfx.D3D11Target {
                if (@hasDecl(T, "beginD3D11Frame")) return self(p).beginD3D11Frame(device);
                return null;
            }
            fn beginMetalFrameFn(p: *anyopaque) ?gfx.MetalTarget {
                if (@hasDecl(T, "beginMetalFrame")) return self(p).beginMetalFrame();
                return null;
            }
            fn bufferAgeFn(p: *anyopaque) u32 {
                if (@hasDecl(T, "bufferAge")) return self(p).bufferAge();
                return 0;
            }
            fn finishFrameFn(p: *anyopaque, repainted: ?[]const gfx.Viewport) void {
                if (@hasDecl(T, "finishFrame")) self(p).finishFrame(repainted);
            }
            fn showDamagedFn(p: *anyopaque, damage: ?[]const gfx.Viewport) anyerror!void {
                if (@hasDecl(T, "showDamaged")) return self(p).showDamaged(damage);
                return error.Unsupported;
            }
            fn supportsPopupsFn(_: *anyopaque) bool {
                return @hasDecl(T, "openPopup");
            }
            fn openPopupFn(p: *anyopaque, placement: PopupPlacement) ?u32 {
                if (@hasDecl(T, "openPopup")) return self(p).openPopup(placement);
                return null;
            }
            fn closePopupFn(p: *anyopaque, id: u32) void {
                if (@hasDecl(T, "closePopup")) self(p).closePopup(id);
            }
            fn popupPositionFn(p: *anyopaque, id: u32) ?[2]i32 {
                if (@hasDecl(T, "popupPosition")) return self(p).popupPosition(id);
                return null;
            }
            fn beginSoftwarePopupFrameFn(p: *anyopaque, id: u32) anyerror!?gfx.software.Image {
                if (@hasDecl(T, "beginSoftwarePopupFrame")) return self(p).beginSoftwarePopupFrame(id);
                return null;
            }
            fn showPopupFn(p: *anyopaque, id: u32) anyerror!void {
                if (@hasDecl(T, "showPopup")) return self(p).showPopup(id);
            }
            fn closeFn(p: *anyopaque) void {
                if (@hasDecl(T, "close")) self(p).close();
            }
            fn copyFn(p: *anyopaque, text: []const u8) void {
                const s = self(p);
                if (@hasDecl(T, "copy")) s.copy(text) else if (@hasField(T, "clipboard")) s.clipboard.copy(text);
            }
            fn pasteFn(p: *anyopaque, sink: clipboard.Sink) void {
                const s = self(p);
                if (@hasDecl(T, "paste")) s.paste(sink) else if (@hasField(T, "clipboard")) s.clipboard.paste(sink);
            }
            fn prefersDarkFn(p: *anyopaque) ?bool {
                return self(p).prefersDark();
            }
            const vt = VTable{
                .platform = platformFn,
                .bufferTransport = bufferTransportFn,
                .bufferSync = bufferSyncFn,
                .frameSync = frameSyncFn,
                .refreshHz = refreshHzFn,
                .decorations = decorationsFn,
                .title = titleFn,
                .setTitle = setTitleFn,
                .poll = pollFn,
                .wait = waitFn,
                .takeInput = takeInputFn,
                .size = sizeFn,
                .scale = scaleFn,
                .takeCloseRequest = takeCloseRequestFn,
                .isSuspended = isSuspendedFn,
                .isMaximized = isMaximizedFn,
                .isFullscreen = isFullscreenFn,
                .isTiled = isTiledFn,
                .isFramePending = isFramePendingFn,
                .setCursor = setCursorFn,
                .setMinSize = setMinSizeFn,
                .setRedraw = setRedrawFn,
                .setMaximized = setMaximizedFn,
                .setMinimized = setMinimizedFn,
                .canMaximize = canMaximizeFn,
                .canMinimize = canMinimizeFn,
                .canFullscreen = canFullscreenFn,
                .setFullscreen = setFullscreenFn,
                .startMove = startMoveFn,
                .setTextInput = setTextInputFn,
                .startDrag = startDragFn,
                .takeDrop = takeDropFn,
                .nextPresentationNs = nextPresentationNsFn,
                .setPresentationTime = setPresentationTimeFn,
                .layout = layoutFn,
                .watch = watchFn,
                .refreshNs = refreshNsFn,
                .cutouts = cutoutsFn,
                .applyConfigure = applyConfigureFn,
                .releaseSpareBuffers = releaseSpareBuffersFn,
                .beginSoftwareFrame = beginSoftwareFrameFn,
                .beginDmabufFrame = beginDmabufFrameFn,
                .beginMetalFrame = beginMetalFrameFn,
                .beginD3D11Frame = beginD3D11FrameFn,
                .bufferAge = bufferAgeFn,
                .finishFrame = finishFrameFn,
                .showDamaged = showDamagedFn,
                .close = closeFn,
                .supportsPopups = supportsPopupsFn,
                .openPopup = openPopupFn,
                .closePopup = closePopupFn,
                .popupPosition = popupPositionFn,
                .beginSoftwarePopupFrame = beginSoftwarePopupFrameFn,
                .showPopup = showPopupFn,
                .copy = if (@hasDecl(T, "copy") or @hasField(T, "clipboard")) copyFn else null,
                .paste = if (@hasDecl(T, "paste") or @hasField(T, "clipboard")) pasteFn else null,
                .prefersDark = if (@hasDecl(T, "prefersDark")) prefersDarkFn else null,
            };
        };
        return .{ .ptr = @ptrCast(@constCast(impl)), .vtable = &gen.vt };
    }

    /// The backend `T` behind it (it was made by `of` from a `*T`), or null.
    pub fn as(w: Window, comptime T: type) ?*T {
        const probe: *T = @ptrFromInt(@max(@alignOf(T), 1));
        if (w.vtable != of(probe).vtable) return null;
        return @ptrCast(@alignCast(w.ptr));
    }

    /// The windowing system the window is on (`.custom` if the backend does not say).
    pub fn platform(w: Window) WindowPlatform {
        return w.vtable.platform(w.ptr);
    }
    /// How frames reach the window system: shared memory, dmabufs or a swapchain.
    pub fn bufferTransport(w: Window) WindowBufferTransport {
        return w.vtable.bufferTransport(w.ptr);
    }
    /// How the window system knows a GPU frame is finished being drawn.
    pub fn bufferSync(w: Window) WindowBufferSync {
        return w.vtable.bufferSync(w.ptr);
    }
    /// The frame pacing protocols the window uses.
    pub fn frameSync(w: Window) WindowFrameSync {
        return w.vtable.frameSync(w.ptr);
    }
    /// The refresh rate of the display the window is on, in hertz, or 0 if
    /// unknown (see `refreshNs`).
    pub fn refreshHz(w: Window) f32 {
        return w.vtable.refreshHz(w.ptr);
    }
    /// Who draws the window's title bar and borders: the toolkit, the window system
    /// or no one.
    pub fn decorations(w: Window) WindowDecorations {
        return w.vtable.decorations(w.ptr);
    }
    /// The window's title, or "" if it has none.
    pub fn title(w: Window) []const u8 {
        return w.vtable.title(w.ptr);
    }
    /// Sets the window's title, for the window system to show (in its title
    /// bar, task bar or window list).
    pub fn setTitle(w: Window, text: []const u8) void {
        w.vtable.setTitle(w.ptr, text);
    }
    /// Handles the events that have already come, without waiting. Read the
    /// input they made with `takeInput`.
    pub fn poll(w: Window) !void {
        return w.vtable.poll(w.ptr);
    }
    /// Handles events as `poll` does, but first waits up to `timeout_ns` nanoseconds
    /// (forever if `std.math.maxInt(u64)`) for something to come: an event, a paste, a read
    /// of a source added with `watch`, or a held key to repeat. Returns early when
    /// any of these arrives.
    pub fn wait(w: Window, timeout_ns: u64) !void {
        return w.vtable.wait(w.ptr, timeout_ns);
    }
    /// The input events since the last call, in order. The slice is valid until the
    /// next `poll`, `wait` or `takeInput`.
    pub fn takeInput(w: Window) []const InputEvent {
        return w.vtable.takeInput(w.ptr);
    }
    /// The window's size, `[width, height]` in logical pixels (multiply by `scale`
    /// for the pixels of the buffer).
    pub fn size(w: Window) [2]u32 {
        return w.vtable.size(w.ptr);
    }
    /// How many buffer pixels there are to a logical pixel (2 on a high density
    /// display), at least 1.
    pub fn scale(w: Window) u32 {
        return w.vtable.scale(w.ptr);
    }
    /// Takes the window system's request to close the window (the user
    /// pressed its close button), if there was one since last taken: it
    /// stays open until it is closed (`close`).
    pub fn takeCloseRequest(w: Window) bool {
        return w.vtable.takeCloseRequest(w.ptr);
    }
    /// Whether the window is not shown (minimized or hidden), so drawing frames
    /// would be wasted.
    pub fn isSuspended(w: Window) bool {
        return w.vtable.isSuspended(w.ptr);
    }
    /// Whether the window fills the screen (see `setMaximized`).
    pub fn isMaximized(w: Window) bool {
        return w.vtable.isMaximized(w.ptr);
    }
    /// Whether the window covers the whole display (see `setFullscreen`).
    pub fn isFullscreen(w: Window) bool {
        return w.vtable.isFullscreen(w.ptr);
    }
    /// Whether the window is tiled against other windows or the screen's edges, so it
    /// has no rounded corners or shadow of its own (false on macOS and Windows, which
    /// do not report it yet).
    pub fn isTiled(w: Window) bool {
        return w.vtable.isTiled(w.ptr);
    }
    /// Whether the last frame shown is still waiting for the windowing
    /// system to be ready for the next (drawing one now would only wait).
    pub fn isFramePending(w: Window) bool {
        return w.vtable.isFramePending(w.ptr);
    }
    /// Sets the shape the pointer shows over the window.
    pub fn setCursor(w: Window, cursor: PointerCursor) void {
        w.vtable.setCursor(w.ptr, cursor);
    }
    /// Sets the smallest size, in logical pixels, the user can resize the window to.
    pub fn setMinSize(w: Window, width: u32, height: u32) void {
        w.vtable.setMinSize(w.ptr, width, height);
    }
    /// What draws a frame now, for windows whose system holds on to the
    /// app's loop while they change (macOS, while one is resized by its
    /// edge); null for none. Windows that never do ignore it.
    pub fn setRedraw(w: Window, redraw: ?Redraw) void {
        w.vtable.setRedraw(w.ptr, redraw);
    }
    /// Hides the window (to the dock or task bar); the window system
    /// shows it again.
    pub fn setMinimized(w: Window) void {
        w.vtable.setMinimized(w.ptr);
    }
    /// Whether the window system can maximize the window (`canMinimize`: minimize
    /// it), for a title bar to show the buttons or not.
    pub fn canMaximize(w: Window) bool {
        return w.vtable.canMaximize(w.ptr);
    }
    /// Whether the window system can minimize the window (see `canMaximize`).
    pub fn canMinimize(w: Window) bool {
        return w.vtable.canMinimize(w.ptr);
    }
    /// Makes the window fill the screen (`on`), or go back to its own size.
    pub fn setMaximized(w: Window, on: bool) void {
        w.vtable.setMaximized(w.ptr, on);
    }
    /// Whether the window system can make the window fullscreen (see
    /// `canMaximize`).
    pub fn canFullscreen(w: Window) bool {
        return w.vtable.canFullscreen(w.ptr);
    }
    /// Makes the window cover the whole display (`on`), or go back to its own size.
    pub fn setFullscreen(w: Window, on: bool) void {
        w.vtable.setFullscreen(w.ptr, on);
    }
    /// Starts moving the window with the pointer, for a title bar pressed by the
    /// user. Does nothing unless a button is held. Not yet on macOS and Windows,
    /// where the system's own title bar moves the window.
    pub fn startMove(w: Window) void {
        w.vtable.startMove(w.ptr);
    }
    /// Tells the input method about the focused text widget (for composing text,
    /// an on-screen keyboard and where to put its candidates), or that none is
    /// focused if null. Commits come back as `text_commit` and `text_preedit` events.
    /// Not yet on macOS and Windows: it does nothing there.
    pub fn setTextInput(w: Window, state: ?TextInputState) void {
        w.vtable.setTextInput(w.ptr, state);
    }
    /// Starts dragging `bytes` of type `mime_type`, to be dropped on this window or
    /// another. `actions` is what the receiver may do with it. Returns false if it
    /// could not start (it has to follow a press). Not yet on macOS and Windows:
    /// false there.
    pub fn startDrag(w: Window, mime_type: []const u8, bytes: []const u8, actions: DragActions) bool {
        return w.vtable.startDrag(w.ptr, mime_type, bytes, actions);
    }
    /// The data dropped on the window since the last call, or null if there is none
    /// (always, so far, except on Wayland).
    pub fn takeDrop(w: Window) ?DroppedData {
        return w.vtable.takeDrop(w.ptr);
    }
    /// Says the next frame shown is drawn for `target_ns` (in nanoseconds on the
    /// monotonic clock, as `nextPresentationNs` gives): a window that can, does not
    /// show it before then (ignored by those that cannot: macOS and Windows, and
    /// Wayland compositors without timed presentation).
    pub fn setPresentationTime(w: Window, target_ns: u64) void {
        w.vtable.setPresentationTime(w.ptr, target_ns);
    }
    /// The time of the first display refresh after `now_ns`, both in nanoseconds on
    /// the monotonic clock (as `nowNs` gives), for drawing a frame to be shown then.
    /// `now_ns` itself if it is not known.
    pub fn nextPresentationNs(w: Window, now_ns: u64) u64 {
        return w.vtable.nextPresentationNs(w.ptr, now_ns);
    }
    /// Waits on `source` too in `wait` (`on`), or no longer: `wait`
    /// returns once it has read something, and has given it what it read.
    pub fn watch(w: Window, source: Source, on: bool) void {
        w.vtable.watch(w.ptr, source, on);
    }
    /// The keyboard layout in use (empty on macOS and Windows, which do not
    /// report it yet).
    pub fn layout(w: Window) KeyboardLayout {
        return w.vtable.layout(w.ptr);
    }
    /// The display's refresh period in nanoseconds, or 0 if unknown (see
    /// `refreshHz`).
    pub fn refreshNs(w: Window) u64 {
        return w.vtable.refreshNs(w.ptr);
    }
    /// The parts of the window the window system draws over what the app draws
    /// (the window's buttons, when it was opened with `draw_in_title_bar`), in
    /// logical pixels from its top left: written to `out`, and returned (none
    /// for a window that has not, or whose system draws the title bar apart
    /// from the content).
    pub fn cutouts(w: Window, out: *[max_cutouts]gfx.Rect) []const gfx.Rect {
        return out[0..w.vtable.cutouts(w.ptr, out)];
    }
    /// Applies the size the windowing system last asked for; returns it if
    /// it changed.
    pub fn applyConfigure(w: Window) !?[2]u32 {
        return w.vtable.applyConfigure(w.ptr);
    }
    /// Frees buffers not needed while the window is not shown.
    pub fn releaseSpareBuffers(w: Window) void {
        w.vtable.releaseSpareBuffers(w.ptr);
    }
    /// Begins the next frame, to be drawn into a buffer in CPU memory by the
    /// software renderer, or an error if the window cannot give one.
    pub fn beginSoftwareFrame(w: Window) !SoftwareFrame {
        const target = try w.vtable.beginSoftwareFrame(w.ptr);
        return .{ .win = w, .target = target, .age = w.vtable.bufferAge(w.ptr) };
    }
    /// Begins the next frame, to be drawn into a dmabuf by the GPU directly, or
    /// null if the window cannot give one (not Linux, or the frame is in shared
    /// memory).
    pub fn beginDmabufFrame(w: Window) ?DmabufFrame {
        const target = w.vtable.beginDmabufFrame(w.ptr) orelse return null;
        return .{ .win = w, .target = target, .age = w.vtable.bufferAge(w.ptr) };
    }
    /// Begins the next frame, to be drawn on the GPU into the window's swap
    /// chain's back buffer (the swap chain made on `device`, an
    /// `ID3D11Device`), or null if the window cannot give one (not Windows).
    pub fn beginD3D11Frame(w: Window, device: *anyopaque) ?D3D11Frame {
        const target = w.vtable.beginD3D11Frame(w.ptr, device) orelse return null;
        return .{ .win = w, .target = target, .age = w.vtable.bufferAge(w.ptr) };
    }
    /// Begins the next frame, to be drawn on the GPU into the window's Metal
    /// layer, or null if the window cannot give one (not macOS).
    pub fn beginMetalFrame(w: Window) ?MetalFrame {
        const target = w.vtable.beginMetalFrame(w.ptr) orelse return null;
        return .{ .win = w, .target = target, .age = w.vtable.bufferAge(w.ptr) };
    }
    /// Whether the window can open popups (`openPopup`): Wayland ones can, no
    /// others yet.
    pub fn supportsPopups(w: Window) bool {
        return w.vtable.supportsPopups(w.ptr);
    }
    /// Opens a surface of its own over the window (and maybe beyond it), placed as
    /// `placement` says, or null if the window cannot.
    pub fn openPopup(w: Window, placement: PopupPlacement) ?Popup {
        const id = w.vtable.openPopup(w.ptr, placement) orelse return null;
        return .{ .win = w, .id = id };
    }
    /// Closes the window and frees it.
    pub fn close(w: Window) void {
        w.vtable.close(w.ptr);
    }
    /// Whether the window has the system's clipboard (`copy`, `paste`).
    pub fn hasClipboard(w: Window) bool {
        return w.vtable.copy != null and w.vtable.paste != null;
    }
    /// Puts `text` on the system clipboard (if `hasClipboard`).
    pub fn copy(w: Window, text: []const u8) void {
        if (w.vtable.copy) |f| f(w.ptr, text);
    }
    /// Asks for the clipboard's text, which `sink` is called with when it comes (null
    /// if there is none, or the window has no clipboard).
    pub fn paste(w: Window, sink: clipboard.Sink) void {
        if (w.vtable.paste) |f| f(w.ptr, sink) else sink.f(sink.ctx, null);
    }
    /// Whether the system's appearance is dark (null if the window does not
    /// say, as Wayland's does not: the app's own theme setting applies).
    pub fn prefersDark(w: Window) ?bool {
        const f = w.vtable.prefersDark orelse return null;
        return f(w.ptr);
    }
};

/// `src` (straight alpha, as kete draws) premultiplied into `dst`: as
/// macOS's and Windows' popups (Core Animation, layered windows) show it.
pub fn premultiply(dst: []u32, src: []const u32) void {
    for (dst, src) |*d, p| {
        const a = p >> 24;
        if (a == 0xff) {
            d.* = p;
            continue;
        }
        const mul = struct {
            fn f(c: u32, alpha: u32) u32 {
                return (c * alpha + 127) / 255;
            }
        }.f;
        d.* = (a << 24) | (mul((p >> 16) & 0xff, a) << 16) | (mul((p >> 8) & 0xff, a) << 8) | mul(p & 0xff, a);
    }
}

/// A popup opened in a window (`Window.openPopup`): a menu or tooltip in a
/// surface of its own. Draw it with `beginSoftwareFrame` and `show`, and
/// `close` it when done (popups are closed newest first).
/// How a window opened by `Display.openWindow` starts out.
pub const WindowOptions = struct {
    title: []const u8,
    /// What the system knows the app by (Wayland's app id), if not the
    /// display's.
    app_id: ?[]const u8 = null,
    /// Its size in logical pixels (null: the backend's default).
    size: ?[2]u32 = null,
    min_size: ?[2]u32 = null,
    maximized: bool = false,
    /// The app draws in the window's title bar: the window system gives up
    /// drawing there where it can. On Wayland the compositor is asked to leave
    /// the decorations to the toolkit, which draws the window's buttons over
    /// the content; on macOS the content goes under the title bar, and the
    /// system's own buttons stay over it (see `Window.cutouts`).
    draw_in_title_bar: bool = false,
    /// A window it belongs to (a dialog's, a tool window's), opened on the
    /// same display: it stays above it.
    parent: ?Window = null,
};

/// The app's connection to the windowing system: what its windows are
/// opened on (`openWindow`), and wait through together (`wait`, `poll`,
/// `watch`), so that one wait covers all of them. `NativeDisplay` is the
/// system's; a custom backend's one window gets one of its own with
/// `single`.
pub const Display = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        platform: *const fn (ptr: *anyopaque) WindowPlatform,
        /// Null if it cannot open windows (`single`'s).
        openWindow: ?*const fn (ptr: *anyopaque, options: WindowOptions) anyerror!Window,
        poll: *const fn (ptr: *anyopaque) anyerror!void,
        wait: *const fn (ptr: *anyopaque, timeout_ns: u64) anyerror!void,
        watch: *const fn (ptr: *anyopaque, source: Source, on: bool) void,
        takeQuitRequest: *const fn (ptr: *anyopaque) bool,
        close: *const fn (ptr: *anyopaque) void,
    };

    /// A `Display` for any backend: `impl` is a pointer to a struct that has
    /// what it supports as declarations (`openWindow`, `wait`, `poll`,
    /// `watch`, `takeQuitRequest`, `close`, `platform`). Its `openWindow`
    /// takes its windows' own options (those of `WindowOptions` it has are
    /// filled in), and returns a pointer to one of them.
    pub fn of(impl: anytype) Display {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        const gen = struct {
            fn self(p: *anyopaque) *T {
                return @ptrCast(@alignCast(p));
            }
            fn platformFn(_: *anyopaque) WindowPlatform {
                if (@hasDecl(T, "platform")) return T.platform;
                return .custom;
            }
            const open_fn = if (@hasDecl(T, "openWindow")) @typeInfo(@TypeOf(T.openWindow)).@"fn" else undefined;
            fn openWindowFn(p: *anyopaque, options: WindowOptions) anyerror!Window {
                const Opts = open_fn.param_types[1].?;
                const W = @typeInfo(@typeInfo(open_fn.return_type.?).error_union.payload).pointer.child;
                var o: Opts = .{ .title = options.title };
                inline for (@typeInfo(Opts).@"struct".field_names) |name| {
                    if (comptime std.mem.eql(u8, name, "title")) continue;
                    if (comptime std.mem.eql(u8, name, "parent")) {
                        if (options.parent) |parent| o.parent = parent.as(W) orelse return error.ParentNotOnDisplay;
                    } else if (comptime std.mem.eql(u8, name, "size")) {
                        if (options.size) |size| o.size = size;
                    } else if (@hasField(WindowOptions, name)) {
                        @field(o, name) = @field(options, name);
                    }
                }
                return Window.of(try self(p).openWindow(o));
            }
            fn pollFn(p: *anyopaque) anyerror!void {
                if (@hasDecl(T, "poll")) return self(p).poll();
            }
            fn waitFn(p: *anyopaque, timeout_ns: u64) anyerror!void {
                if (@hasDecl(T, "wait")) return self(p).wait(timeout_ns);
            }
            fn watchFn(p: *anyopaque, source: Source, on: bool) void {
                if (@hasDecl(T, "watch")) self(p).watch(source, on);
            }
            fn takeQuitRequestFn(p: *anyopaque) bool {
                if (@hasDecl(T, "takeQuitRequest")) return self(p).takeQuitRequest();
                return false;
            }
            fn closeFn(p: *anyopaque) void {
                if (@hasDecl(T, "close")) self(p).close();
            }
            const vt = VTable{
                .platform = platformFn,
                .openWindow = if (@hasDecl(T, "openWindow")) openWindowFn else null,
                .poll = pollFn,
                .wait = waitFn,
                .watch = watchFn,
                .takeQuitRequest = takeQuitRequestFn,
                .close = closeFn,
            };
        };
        return .{ .ptr = @ptrCast(impl), .vtable = &gen.vt };
    }

    /// A display of `win`'s own, for a backend with one window that waits
    /// for itself (`Window.wait`, `poll`, `watch`): it opens no others, and
    /// closing it leaves the window be. `win` is a pointer `Window.of`
    /// takes, and must outlive it.
    pub fn single(win: anytype) Display {
        const T = @typeInfo(@TypeOf(win)).pointer.child;
        const gen = struct {
            fn w(p: *anyopaque) Window {
                return Window.of(@as(*T, @ptrCast(@alignCast(p))));
            }
            fn platformFn(p: *anyopaque) WindowPlatform {
                return w(p).platform();
            }
            fn pollFn(p: *anyopaque) anyerror!void {
                return w(p).poll();
            }
            fn waitFn(p: *anyopaque, timeout_ns: u64) anyerror!void {
                return w(p).wait(timeout_ns);
            }
            fn watchFn(p: *anyopaque, source: Source, on: bool) void {
                w(p).watch(source, on);
            }
            fn takeQuitRequestFn(_: *anyopaque) bool {
                return false;
            }
            fn closeFn(_: *anyopaque) void {}
            const vt = VTable{
                .platform = platformFn,
                .openWindow = null,
                .poll = pollFn,
                .wait = waitFn,
                .watch = watchFn,
                .takeQuitRequest = takeQuitRequestFn,
                .close = closeFn,
            };
        };
        return .{ .ptr = @ptrCast(@constCast(win)), .vtable = &gen.vt };
    }

    /// The windowing system it is on (`.custom` if the backend does not say).
    pub fn platform(d: Display) WindowPlatform {
        return d.vtable.platform(d.ptr);
    }
    /// Whether it can open windows (`openWindow`).
    pub fn canOpenWindows(d: Display) bool {
        return d.vtable.openWindow != null;
    }
    /// Opens a window on it (closed with `Window.close`).
    pub fn openWindow(d: Display, options: WindowOptions) !Window {
        const f = d.vtable.openWindow orelse return error.Unsupported;
        return f(d.ptr, options);
    }
    /// Handles what has come for its windows, without waiting.
    pub fn poll(d: Display) !void {
        return d.vtable.poll(d.ptr);
    }
    /// Waits up to `timeout_ns` (forever if `maxInt(u64)`) for something to
    /// come for its windows, or a watched source, and handles it.
    pub fn wait(d: Display, timeout_ns: u64) !void {
        return d.vtable.wait(d.ptr, timeout_ns);
    }
    /// Waits on `source` too (or stops, if not `on`).
    pub fn watch(d: Display, source: Source, on: bool) void {
        d.vtable.watch(d.ptr, source, on);
    }
    /// Takes the system's request for the app to quit (the session ending,
    /// macOS's Quit), if there was one.
    pub fn takeQuitRequest(d: Display) bool {
        return d.vtable.takeQuitRequest(d.ptr);
    }
    /// Lets it go (its windows must be closed first).
    pub fn close(d: Display) void {
        d.vtable.close(d.ptr);
    }
};

pub const Popup = struct {
    win: Window,
    /// What `InputEvent.popup_done` says when the window system closes it.
    id: u32,

    /// Closes the popup.
    pub fn close(p: Popup) void {
        p.win.vtable.closePopup(p.win.ptr, p.id);
    }

    /// Where the window system put the popup (`[x, y]` of its top left in the
    /// window's coordinates, in logical pixels), once it has.
    pub fn position(p: Popup) ?[2]i32 {
        return p.win.vtable.popupPosition(p.win.ptr, p.id);
    }

    /// The buffer to draw the popup's next frame into (all of it), or null
    /// if it cannot be drawn yet.
    pub fn beginSoftwareFrame(p: Popup) !?gfx.software.Image {
        return p.win.vtable.beginSoftwarePopupFrame(p.win.ptr, p.id);
    }

    /// Shows the frame drawn into `beginSoftwareFrame`'s buffer.
    pub fn show(p: Popup) !void {
        return p.win.vtable.showPopup(p.win.ptr, p.id);
    }
};

/// A frame begun in a window (`Window.beginSoftwareFrame`, `beginDmabufFrame`
/// or `beginMetalFrame`), of which `Target` is where it is drawn. Draw it (only
/// what `age` says is out of date), `finish` it, and `show` it, before another
/// is begun.
pub fn WindowFrame(comptime Target: type) type {
    return struct {
        win: Window,
        /// Where to draw the frame.
        target: Target,
        /// How many frames ago the buffer was last drawn: 1 if in the frame
        /// before, 0 if never.
        age: u32,

        /// Draws the window's own decorations over the `repainted` parts of
        /// the frame (or all of it if null).
        pub fn finish(f: @This(), repainted: ?[]const gfx.Viewport) void {
            f.win.vtable.finishFrame(f.win.ptr, repainted);
        }

        /// Shows the frame, telling the system what of it changed (or all of
        /// it if null).
        pub fn show(f: @This(), damage: ?[]const gfx.Viewport) !void {
            return f.win.vtable.showDamaged(f.win.ptr, damage);
        }
    };
}

/// A frame drawn on the CPU, in an image.
pub const SoftwareFrame = WindowFrame(gfx.software.Image);
/// A frame drawn by the GPU, in a dmabuf.
pub const DmabufFrame = WindowFrame(gfx.DmabufTarget);
/// A frame drawn by the GPU, in a Metal layer.
pub const MetalFrame = WindowFrame(gfx.MetalTarget);
/// A frame drawn by the GPU, in a Direct3D 11 swap chain's back buffer.
pub const D3D11Frame = WindowFrame(gfx.D3D11Target);

/// What an app's title bar does to its window (for the toolkit's TitleBar:
/// `.on_close = .of(&controls, WindowControls.close)`, and so on).
pub const WindowControls = struct {
    /// The window the buttons act on (none, if the controls are only used to ask to close).
    win: ?Window = null,
    /// The close button was pressed: the window should be closed (taken by
    /// the app as the window system's own request is).
    close_requested: bool = false,

    /// Controls for `impl`, a `Window` or a pointer to a window.
    pub fn init(impl: anytype) WindowControls {
        return .{ .win = Window.from(impl) };
    }

    /// The close button: asks for the window to be closed (see `close_requested`).
    pub fn close(c: *WindowControls) void {
        c.close_requested = true;
    }

    /// The minimize button: hide the window.
    pub fn minimize(c: *WindowControls) void {
        if (c.win) |w| w.setMinimized();
    }

    /// The maximize button: fill the screen, or go back to the window's
    /// own size.
    pub fn toggleMaximized(c: *WindowControls) void {
        if (c.win) |w| w.setMaximized(!w.isMaximized());
    }

    /// Toggle whether the window fills the entire display (fullscreen).
    pub fn toggleFullscreen(c: *WindowControls) void {
        if (c.win) |w| if (w.canFullscreen()) w.setFullscreen(!w.isFullscreen());
    }

    /// The title bar was pressed: drag the window (unless it fills the
    /// screen).
    pub fn drag(c: *WindowControls) void {
        if (c.win) |w| if (!w.isMaximized()) w.startMove();
    }
};

/// Keymaps: what each key types, from the compositor.
pub const xkb = @import("xkb.zig");
/// Linux's key codes, which `xkb` keymaps are in, and the `KeyboardKey`s they are.
pub const evdev = @import("evdev.zig");
/// Dead keys and the Compose key.
pub const compose = @import("compose.zig");
pub const dbus = @import("dbus.zig");
/// Draws a frame of the app's, at the window's size (see
/// `Window.setRedraw`).
pub const Redraw = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque) void,
};

pub const sys = @import("sys.zig");

/// The keyboard layout in use: its name ("English (UK)") and XKB code
/// ("gb"), from the keymap the compositor gave.
pub const KeyboardLayout = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    code_buf: [32]u8 = undefined,
    code_len: u8 = 0,

    pub fn init(name_: []const u8, code_: []const u8) KeyboardLayout {
        var l: KeyboardLayout = .{};
        l.name_len = @intCast(@min(name_.len, l.name_buf.len));
        @memcpy(l.name_buf[0..l.name_len], name_[0..l.name_len]);
        l.code_len = @intCast(@min(code_.len, l.code_buf.len));
        @memcpy(l.code_buf[0..l.code_len], code_[0..l.code_len]);
        return l;
    }

    /// Its name, or "" if no keymap has been given.
    pub fn name(l: *const KeyboardLayout) []const u8 {
        return l.name_buf[0..l.name_len];
    }

    pub fn code(l: *const KeyboardLayout) []const u8 {
        return l.code_buf[0..l.code_len];
    }
};

test "straight alpha is premultiplied" {
    var out: [3]u32 = undefined;
    premultiply(&out, &.{ 0xffff8000, 0x80ff8000, 0x00ffffff });
    try std.testing.expectEqual(@as(u32, 0xffff8000), out[0]);
    try std.testing.expectEqual(@as(u32, 0x80804000), out[1]);
    try std.testing.expectEqual(@as(u32, 0x00000000), out[2]);
}

test "sources are waited on through io, with a timeout" {
    if (!sys.is_linux) return error.SkipZigTest;
    const io = std.testing.io;
    var a = try sys.Wake.create();
    defer a.deinit();
    var b = try sys.Wake.create();
    defer b.deinit();
    const Count = struct {
        var done: u32 = 0;
        fn read(ctx: *anyopaque) ?std.Io.Operation {
            return @as(*sys.Wake, @ptrCast(@alignCast(ctx))).readOperation();
        }
        fn finished(_: *anyopaque, result: std.Io.Operation.Result) void {
            if (result.file_read_streaming) |n| {
                if (n > 0) done += 1;
            } else |_| {}
        }
    };
    const sources = [_]Source{
        .{ .ctx = &a, .fd = a.fd(), .read = Count.read, .done = Count.finished },
        .{ .ctx = &b, .fd = b.fd(), .read = Count.read, .done = Count.finished },
    };
    // Nothing: it waits out the timeout.
    const before = nowNs(io);
    try waitSources(io, &sources, 20 * std.time.ns_per_ms);
    try std.testing.expect(nowNs(io) - before >= 15 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 0), Count.done);
    // One woken: it is read, at once.
    b.signal();
    try waitSources(io, &sources, 5 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), Count.done);
    try std.testing.expect(nowNs(io) - before < std.time.ns_per_s);
    try std.testing.expect(!b.drain());
}

test "a display opens its windows with their own options, on it" {
    const testing = std.testing;
    const Win = struct {
        const Win = @This();
        title: []const u8,
        size: [2]u32,
        parent: ?*Win,
        closed: bool = false,
        width: u32 = 1,
        height: u32 = 1,

        pub const Options = struct {
            title: []const u8,
            size: [2]u32 = .{ 100, 50 },
            parent: ?*Win = null,
        };
        pub fn close(w: *@This()) void {
            w.closed = true;
        }
    };
    const Disp = struct {
        windows: [2]Win = undefined,
        len: usize = 0,
        waited: u64 = 0,

        pub fn openWindow(d: *@This(), o: Win.Options) !*Win {
            d.windows[d.len] = .{ .title = o.title, .size = o.size, .parent = o.parent };
            d.len += 1;
            return &d.windows[d.len - 1];
        }
        pub fn wait(d: *@This(), ns: u64) !void {
            d.waited = ns;
        }
    };
    var impl: Disp = .{};
    const d = Display.of(&impl);
    try testing.expect(d.canOpenWindows());
    try testing.expectEqual(WindowPlatform.custom, d.platform());
    const a = try d.openWindow(.{ .title = "a" });
    const b = try d.openWindow(.{ .title = "b", .size = .{ 30, 20 }, .parent = a });
    try testing.expectEqualStrings("a", impl.windows[0].title);
    try testing.expectEqual([2]u32{ 100, 50 }, impl.windows[0].size);
    try testing.expectEqual([2]u32{ 30, 20 }, impl.windows[1].size);
    try testing.expectEqual(&impl.windows[0], impl.windows[1].parent.?);
    try testing.expectEqual(&impl.windows[1], b.as(Win).?);
    try d.wait(5);
    try testing.expectEqual(@as(u64, 5), impl.waited);
    try testing.expect(!d.takeQuitRequest());

    // A parent from elsewhere is not one of its windows.
    var other: struct { width: u32 = 1, height: u32 = 1 } = .{};
    try testing.expectError(error.ParentNotOnDisplay, d.openWindow(.{ .title = "c", .parent = .of(&other) }));

    // A window of its own waits for itself.
    const single = Display.single(&impl.windows[0]);
    try testing.expect(!single.canOpenWindows());
    try testing.expectError(error.Unsupported, single.openWindow(.{ .title = "d" }));
    single.close();
    try testing.expect(!impl.windows[0].closed);
}

test {
    // The system's display is one `Display.of` takes.
    _ = &struct {
        fn f(d: *NativeDisplay) Display {
            return .of(d);
        }
    }.f;
    _ = present;
    _ = sys;
    _ = evdev;
    _ = @import("win32_keys.zig");
    _ = positioner_mod;
    switch (@import("builtin").os.tag) {
        .windows => _ = win32,
        else => {
            _ = clipboard;
            _ = wayland;
            _ = xkb;
            _ = compose;
            _ = dbus;
            _ = macos;
        },
    }
}
