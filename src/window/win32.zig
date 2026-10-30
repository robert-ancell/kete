//! Win32Window: a native Windows window (a Win32 `HWND`, with the system's
//! own title bar, buttons, resizing and full screen), and kete's
//! `InputEvent`s from its messages: Windows' scan codes become `KeyboardKey`s,
//! and each key's character is the `WM_CHAR`
//! that `TranslateMessage` makes of it (so dead keys and the keyboard's
//! layout work as everywhere else on Windows).
//!
//! The content can go under the title bar (`Options.draw_in_title_bar`): the
//! window has no frame of its own then (`WM_NCCALCSIZE`), its edges that resize
//! are answered for (`WM_NCHITTEST`), and DWM still draws its buttons over the
//! content, in the frame extended into it: `cutouts` says where they are.
//!
//! It is single-threaded, and is built not to drop frames:
//!
//! * One wait for everything (`wait`): `MsgWaitForMultipleObjectsEx` on
//!   the window's messages, the watched sources' handles, and a
//!   high-resolution waitable timer for the frame's deadline (not the
//!   default 15.6 ms tick).
//! * Frames drawn on the GPU go to a flip-model swap chain with a frame
//!   latency waitable object (see `gfx.d3d11.SwapChain`), which the wait
//!   includes: a frame is drawn as soon as a buffer is free (just after a
//!   refresh), with the input read just before, and `Present` never
//!   blocks. The frames say what changed (dirty rectangles), so that DWM
//!   composes only that; out of sight (occluded or minimized), none are
//!   drawn.
//! * Frames are timed by the display: DWM's composition timing says when
//!   the next refresh is, and how long each is (for frames drawn on the
//!   CPU, which have no swap chain to say).
//! * Windows' modal loops (resizing or moving the window, holding its
//!   title bar, the system menu) hold the app's loop until they end; while
//!   they run, frames are drawn from inside them (`Window.setRedraw`): at
//!   each new size, and at each refresh from a message posted to itself
//!   that waits for the refresh (but returns at once for input).
//!
//! The Windows API is loaded at run time (see `gfx.winapi`), so nothing is
//! linked but kernel32.

const std = @import("std");
const gfx = @import("gfx");
const window = @import("window.zig");
const clipboard = @import("clipboard.zig");
const keys = @import("win32_keys.zig");

const w32 = gfx.winapi;
const InputEvent = window.InputEvent;
const HWND = w32.HWND;
const UINT = w32.UINT;
const WPARAM = w32.WPARAM;
const LPARAM = w32.LPARAM;
const LRESULT = w32.LRESULT;

// Messages.
const WM_DESTROY = 0x0002;
const WM_SIZE = 0x0005;
const WM_KILLFOCUS = 0x0008;
const WM_PAINT = 0x000f;
const WM_CLOSE = 0x0010;
const WM_ERASEBKGND = 0x0014;
const WM_SETTINGCHANGE = 0x001a;
const WM_SETCURSOR = 0x0020;
const WM_GETMINMAXINFO = 0x0024;
const WM_DISPLAYCHANGE = 0x007e;
const WM_NCCREATE = 0x0081;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_CHAR = 0x0102;
const WM_DEADCHAR = 0x0103;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_SYSCHAR = 0x0106;
const WM_TIMER = 0x0113;
const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_MBUTTONDOWN = 0x0207;
const WM_MBUTTONUP = 0x0208;
const WM_MOUSEWHEEL = 0x020a;
const WM_XBUTTONDOWN = 0x020b;
const WM_XBUTTONUP = 0x020c;
const WM_MOUSEHWHEEL = 0x020e;
const WM_ENTERMENULOOP = 0x0211;
const WM_EXITMENULOOP = 0x0212;
const WM_ENTERSIZEMOVE = 0x0231;
const WM_EXITSIZEMOVE = 0x0232;
const WM_CAPTURECHANGED = 0x0215;
const WM_ACTIVATE = 0x0006;
const WM_MOUSEACTIVATE = 0x0021;
const WM_NCLBUTTONDOWN = 0x00a1;
const WM_NCCALCSIZE = 0x0083;
const WM_NCHITTEST = 0x0084;
const MA_NOACTIVATE = 3;
const WS_EX_LAYERED: w32.DWORD = 0x00080000;
const WS_EX_NOACTIVATE: w32.DWORD = 0x08000000;
const WS_EX_TOOLWINDOW: w32.DWORD = 0x00000080;
const WS_EX_TRANSPARENT: w32.DWORD = 0x00000020;
const SW_SHOWNOACTIVATE = 4;
const max_popups = 4;
const WM_MOUSELEAVE = 0x02a3;
const WM_DPICHANGED = 0x02e0;
/// Posted to itself while a modal loop runs: draw the next frame.
const WM_APP_FRAME = 0x8000 + 1;

const WS_OVERLAPPEDWINDOW: w32.DWORD = 0x00cf0000;
const WS_POPUP: w32.DWORD = 0x80000000;
const WS_VISIBLE: w32.DWORD = 0x10000000;
const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
const GWLP_USERDATA: c_int = -21;
const GWL_STYLE: c_int = -16;
const SW_SHOW = 5;
const SW_MAXIMIZE = 3;
const SW_MINIMIZE = 6;
const SW_RESTORE = 9;
const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOACTIVATE: UINT = 0x0010;
const SWP_FRAMECHANGED: UINT = 0x0020;
const SWP_NOOWNERZORDER: UINT = 0x0200;
const SWP_NOMOVE: UINT = 0x0002;
const PM_REMOVE: UINT = 1;
const PM_NOREMOVE: UINT = 0;
const QS_ALLINPUT: w32.DWORD = 0x04ff;
const QS_INPUT: UINT = 0x0407;
const MWMO_INPUTAVAILABLE: w32.DWORD = 0x0004;
const HTCLIENT = 1;
const HTCAPTION = 2;
const HTLEFT = 10;
const HTRIGHT = 11;
const HTTOP = 12;
const HTTOPLEFT = 13;
const HTTOPRIGHT = 14;
const HTBOTTOM = 15;
const HTBOTTOMLEFT = 16;
const HTBOTTOMRIGHT = 17;
const SM_CYCAPTION = 4;
const SM_CXSIZEFRAME = 32;
const SM_CXPADDEDBORDER = 92;
const DWMWA_CAPTION_BUTTON_BOUNDS: w32.DWORD = 5;
const TME_LEAVE: w32.DWORD = 2;
const CF_UNICODETEXT: UINT = 13;
const SPI_GETWHEELSCROLLLINES: UINT = 0x68;
const MONITOR_DEFAULTTONEAREST: w32.DWORD = 2;
const DWMWA_USE_IMMERSIVE_DARK_MODE: w32.DWORD = 20;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
const VK_SHIFT = 0x10;
const VK_CONTROL = 0x11;
const VK_MENU = 0x12;
const MAPVK_VK_TO_VSC_EX: UINT = 4;
const WHEEL_DELTA = 120;
const SIZE_MINIMIZED = 1;
const frame_timer_id: usize = 1;
const max_watched = 8;

/// The app's connection to Windows, which its windows are opened on
/// (`openWindow`) and wait through together (`wait`, `poll`, `watch`): the
/// thread's messages (for all its windows), the swap chains' waitable
/// objects, and the watched sources' handles, in one wait.
pub const Win32Display = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    windows: std.ArrayList(*Win32Window) = .empty,
    /// What `wait` waits on as well as the windows' messages, and the
    /// high-resolution timer for its deadline.
    watched: [max_watched]?window.Source = @splat(null),
    timer: ?w32.HANDLE = null,
    /// The app was asked to quit (the session ending).
    quit_requested: bool = false,

    pub const platform: window.WindowPlatform = .windows;
    const max_windows = 32;

    /// Ready to open windows (each monitor's own DPI told as it changes,
    /// Windows 10 1703 on), doing its I/O through `io`.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !*Win32Display {
        _ = environ;
        const u = w32.user32() orelse return error.NoUser32;
        _ = u.SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        Win32Window.registerClass(u, @ptrCast(w32.GetModuleHandleW(null)));
        const d = try gpa.create(Win32Display);
        d.* = .{ .gpa = gpa, .io = io };
        d.timer = w32.CreateWaitableTimerExW(null, null, w32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, w32.TIMER_ALL_ACCESS);
        return d;
    }

    /// Lets it go (its windows must be closed first).
    pub fn close(d: *Win32Display) void {
        std.debug.assert(d.windows.items.len == 0);
        if (d.timer) |t| _ = w32.CloseHandle(t);
        d.windows.deinit(d.gpa);
        d.gpa.destroy(d);
    }

    /// Opens a window on it (closed with `Win32Window.close`).
    pub fn openWindow(d: *Win32Display, options: Win32Window.Options) !*Win32Window {
        if (d.windows.items.len == max_windows) return error.TooManyWindows;
        try d.windows.ensureUnusedCapacity(d.gpa, 1);
        const w = try Win32Window.openOn(d, options);
        d.windows.appendAssumeCapacity(w);
        return w;
    }

    fn forget(d: *Win32Display, w: *Win32Window) void {
        if (std.mem.indexOfScalar(*Win32Window, d.windows.items, w)) |i| _ = d.windows.orderedRemove(i);
    }

    /// Takes the request to quit, if there was one.
    pub fn takeQuitRequest(d: *Win32Display) bool {
        defer d.quit_requested = false;
        return d.quit_requested;
    }

    /// Handles the messages that have come, without waiting.
    pub fn poll(d: *Win32Display) !void {
        Win32Window.pump();
        for (d.windows.items) |w| w.updatePending();
    }

    /// Waits up to `timeout_ns` for a message or a watched source (and not
    /// past when a window's next frame can be drawn: a buffer of its swap
    /// chain is free, or its deadline), and handles what came.
    pub fn wait(d: *Win32Display, timeout_ns: u64) !void {
        const u = w32.user32() orelse return;
        var ns = timeout_ns;
        var handles: [max_watched + max_windows + 1]w32.HANDLE = undefined;
        // Which window each swap chain's object is of.
        var swap_of: [max_windows]*Win32Window = undefined;
        var n: w32.DWORD = 0;
        const now_ns = window.nowNs(d.io);
        for (d.windows.items) |w| {
            if (w.on_gpu and w.swap != null) {
                // The swap chain says when a buffer is free.
                if (!w.swap_ready) {
                    swap_of[n] = w;
                    handles[n] = w.swap.?.waitable;
                    n += 1;
                }
            } else if (w.frame_pending) ns = @min(ns, w.presented_ns -| now_ns);
            // Out of sight, it is asked again now and then whether it shows.
            if (w.occluded) ns = @min(ns, 100 * std.time.ns_per_ms);
        }
        const swaps = n;
        for (d.watched) |slot| if (slot) |s| {
            handles[n] = s.fd;
            n += 1;
        };
        // A deadline to the 100 ns, on a high-resolution timer, rather than
        // to the millisecond (and the scheduler's tick).
        var ms: w32.DWORD = w32.INFINITE;
        if (ns != std.math.maxInt(u64)) {
            if (d.timer) |t| {
                const due: i64 = -@as(i64, @intCast(@max(ns / 100, 1)));
                if (w32.SetWaitableTimer(t, &due, 0, null, null, w32.FALSE) != 0) {
                    handles[n] = t;
                    n += 1;
                } else ms = Win32Window.msCeil(ns);
            } else ms = Win32Window.msCeil(ns);
        }
        const woke = u.MsgWaitForMultipleObjectsEx(n, &handles, ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (d.timer) |t| _ = w32.CancelWaitableTimer(t);
        // A swap chain's object, if it woke the wait, was taken by it.
        if (woke >= w32.WAIT_OBJECT_0 and woke < w32.WAIT_OBJECT_0 + swaps) swap_of[woke - w32.WAIT_OBJECT_0].swap_ready = true;
        Win32Window.pump();
        for (d.windows.items) |w| w.updatePending();
    }

    /// Waits on `source` too (or stops, if not `on`): signalled, it wakes
    /// `wait` (a `sys.Wake` is an event, taken by the wait itself).
    pub fn watch(d: *Win32Display, source: window.Source, on: bool) void {
        for (&d.watched) |*slot| if (slot.*) |s| if (s.eql(source)) {
            if (!on) slot.* = null;
            return;
        };
        if (!on) return;
        for (&d.watched) |*slot| if (slot.* == null) {
            slot.* = source;
            return;
        };
    }
};

pub const Win32Window = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    hwnd: HWND,
    title_buf: []u8,
    /// The client area in logical pixels (its pixels over `scale`, rounded
    /// up), and how many pixels each is (the monitor's DPI over 96, rounded:
    /// kete's scales are whole).
    width: u32,
    height: u32,
    scale: u32 = 1,
    /// The client area in pixels.
    pixel_size: [2]u32 = .{ 0, 0 },
    /// The window system asked for it to be closed (taken by the app).
    close_requested: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    minimized: bool = false,
    /// The placement and style to go back to from full screen.
    restore: w32.WINDOWPLACEMENT = .{},
    restore_style: isize = 0,
    min_size: [2]u32 = .{ 1, 1 },
    cursor: window.PointerCursor = .default,
    /// Whether the pointer is in the window (its leaving is tracked), and
    /// the buttons held (the window has the mouse while any is).
    pointer_in: bool = false,
    buttons_held: u32 = 0,
    /// Where the pointer last was in the window, in logical pixels (where
    /// the wheel turns: its messages say where on the screen).
    last_pointer: [2]f32 = .{ 0, 0 },
    /// The system's appearance, as last read (on open and when Settings
    /// changes it).
    dark: ?bool = null,
    /// A display refresh lasts this long, and the frame given last is shown
    /// at `presented_ns` (the refresh after it was given): the next waits
    /// until then.
    refresh_ns: u64 = std.time.ns_per_s / 60,
    frame_pending: bool = false,
    presented_ns: u64 = 0,
    /// What draws a frame from inside Windows' modal loops (see
    /// `window.Window.setRedraw`), and whether one is running.
    redraw: ?window.Redraw = null,
    in_modal: bool = false,
    /// A frame message is in the queue (there is never more than one).
    frame_posted: bool = false,
    /// Events since the last `takeInput`, and those it gave.
    input: std.ArrayList(InputEvent) = .empty,
    taken: std.ArrayList(InputEvent) = .empty,
    /// The swap chain the GPU's frames go to (made on the renderer's device
    /// when it first draws), its back buffer while a frame is drawn in it,
    /// whether it has a buffer free (its waitable object signalled, and so
    /// taken), and the size of the last frame drawn there (0 by 0: none
    /// yet), which the renderer keeps from one to the next. And whether
    /// the window is out of sight (its frames would not be seen).
    swap: ?gfx.d3d11.SwapChain = null,
    back: ?*anyopaque = null,
    swap_ready: bool = false,
    on_gpu: bool = false,
    gpu_size: [2]u32 = .{ 0, 0 },
    occluded: bool = false,
    /// The CPU's frame (pixels a row at a time, top first, 0xAARRGGBB),
    /// shown with GDI; and whether it has been shown at this size.
    pixels: []u32 = &.{},
    pixels_size: [2]u32 = .{ 0, 0 },
    pixels_shown: bool = false,
    /// The display it is on (its own, if it was opened by `open`), and the
    /// high-resolution timer for frames' deadlines in Windows' modal loops.
    display: *Win32Display,
    owns_display: bool = false,
    timer: ?w32.HANDLE = null,
    /// The pending high surrogate of a character `WM_CHAR` gives in two.
    high_surrogate: u16 = 0,
    /// Its popups (menus and tooltips, each a window of its own: see
    /// `openPopup`), and the next one's id.
    popups: [max_popups]?Popup = @splat(null),
    next_popup_id: u32 = 1,
    /// The content is under the title bar (`Options.draw_in_title_bar`).
    draw_in_title_bar: bool = false,

    /// A popup: a layered window over the window (owned by it), which never
    /// takes the keyboard, its pointer input the window's (in its
    /// coordinates), and what it shows.
    const Popup = struct {
        id: u32,
        placement: window.PopupPlacement,
        hwnd: HWND,
        /// Where its top left is: in the window's coordinates (logical
        /// pixels), and on the screen (pixels); its size in pixels.
        position: [2]i32,
        screen_at: w32.POINT,
        pixel_size: [2]u32,
        /// What is drawn in it (straight alpha, as kete draws), and the
        /// DIB section it is shown from (premultiplied), in a memory DC.
        pixels: []u32 = &.{},
        dc: ?w32.HDC = null,
        bitmap: ?w32.HANDLE = null,
        bits: ?[*]u32 = null,
        shown: bool = false,
    };

    pub const platform: window.WindowPlatform = .windows;
    pub const decorations: window.WindowDecorations = .system;

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = .{ 960, 640 },
        min_size: ?[2]u32 = null,
        maximized: bool = false,
        /// The app draws in the title bar: the window's content fills it, and
        /// the window's buttons are over the content (`cutouts`).
        draw_in_title_bar: bool = false,
        /// A window it belongs to (a dialog's, a tool window's): it owns
        /// it, so that it stays above it, and is minimized with it.
        parent: ?*Win32Window = null,
    };

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("KeteWindow");
    const popup_class_name = std.unicode.utf8ToUtf16LeStringLiteral("KetePopup");

    /// Opens a window on a display of its own.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !*Win32Window {
        const d = try Win32Display.open(gpa, io, environ);
        errdefer d.close();
        const w = try d.openWindow(options);
        w.owns_display = true;
        return w;
    }

    fn openOn(d: *Win32Display, options: Options) !*Win32Window {
        const gpa = d.gpa;
        const u = w32.user32() orelse return error.NoUser32;
        const instance: ?w32.HINSTANCE = @ptrCast(w32.GetModuleHandleW(null));

        const w = try gpa.create(Win32Window);
        errdefer gpa.destroy(w);
        w.* = .{
            .gpa = gpa,
            .io = d.io,
            .display = d,
            .hwnd = undefined,
            .title_buf = try gpa.dupe(u8, options.title),
            .width = options.size[0],
            .height = options.size[1],
            .draw_in_title_bar = options.draw_in_title_bar,
        };
        errdefer gpa.free(w.title_buf);
        if (options.min_size) |m| w.min_size = m;

        var title_w: [256]u16 = undefined;
        // Sized for its DPI once it has one (WM_DPICHANGED, or below).
        const owner: ?w32.HWND = if (options.parent) |parent| parent.hwnd else null;
        const hwnd = u.CreateWindowExW(0, class_name, w32.wide(&title_w, options.title).ptr, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, owner, null, instance, w) orelse return error.CreateWindowFailed;
        w.hwnd = hwnd;
        w.updateScale(u);
        w.extendFrame(u);
        w.resizeTo(u, options.size);
        w.dark = w32.appsUseDark();
        w.applyDarkTitleBar();
        w.updateRefresh();
        w.timer = w32.CreateWaitableTimerExW(null, null, w32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, w32.TIMER_ALL_ACCESS);
        _ = u.ShowWindow(hwnd, if (options.maximized) SW_MAXIMIZE else SW_SHOW);
        _ = try w.applyConfigure();
        return w;
    }

    fn registerClass(u: *const w32.User32, instance: ?w32.HINSTANCE) void {
        const S = struct {
            var done = false;
        };
        if (S.done) return;
        S.done = true;
        const wc: w32.WNDCLASSEXW = .{
            // CS_HREDRAW | CS_VREDRAW: not needed (nothing is stretched),
            // and no background brush (WM_ERASEBKGND does nothing).
            .lpfnWndProc = wndProc,
            .hInstance = instance,
            .hCursor = u.LoadCursorW(null, 32512),
            .lpszClassName = class_name,
        };
        _ = u.RegisterClassExW(&wc);
        const popup_wc: w32.WNDCLASSEXW = .{
            .lpfnWndProc = popupProc,
            .hInstance = instance,
            .hCursor = u.LoadCursorW(null, 32512),
            .lpszClassName = popup_class_name,
        };
        _ = u.RegisterClassExW(&popup_wc);
    }

    pub fn close(w: *Win32Window) void {
        for (&w.popups) |*slot| if (slot.*) |*pop| {
            w.destroyPopup(pop);
            slot.* = null;
        };
        if (w32.user32()) |u| {
            _ = u.KillTimer(w.hwnd, frame_timer_id);
            _ = u.SetWindowLongPtrW(w.hwnd, GWLP_USERDATA, 0);
            _ = u.DestroyWindow(w.hwnd);
        }
        if (w.timer) |t| _ = w32.CloseHandle(t);
        w32.release(w.back);
        if (w.swap) |*sc| sc.deinit();
        w.gpa.free(w.pixels);
        w.input.deinit(w.gpa);
        w.taken.deinit(w.gpa);
        w.gpa.free(w.title_buf);
        const d = w.display;
        d.forget(w);
        w.gpa.destroy(w);
        if (w.owns_display) d.close();
    }

    pub fn getTitle(w: *const Win32Window) []const u8 {
        return w.title_buf;
    }

    pub fn setTitle(w: *Win32Window, title: []const u8) void {
        const owned = w.gpa.dupe(u8, title) catch return;
        w.gpa.free(w.title_buf);
        w.title_buf = owned;
        const u = w32.user32() orelse return;
        var buf: [256]u16 = undefined;
        _ = u.SetWindowTextW(w.hwnd, w32.wide(&buf, title).ptr);
    }

    pub fn size(w: *const Win32Window) [2]u32 {
        return .{ w.width, w.height };
    }

    pub fn getScale(w: *const Win32Window) u32 {
        return w.scale;
    }

    pub fn refreshNs(w: *const Win32Window) u64 {
        return w.refresh_ns;
    }

    pub fn isSuspended(w: *const Win32Window) bool {
        return w.minimized or w.occluded;
    }

    pub fn prefersDark(w: *const Win32Window) ?bool {
        return w.dark;
    }

    /// Sets the window's size to `logical` (its client area, in logical
    /// pixels at its scale).
    fn resizeTo(w: *Win32Window, u: *const w32.User32, logical: [2]u32) void {
        var r: w32.RECT = .{ .right = @intCast(logical[0] * w.scale), .bottom = @intCast(logical[1] * w.scale) };
        w.outerRect(u, &r);
        _ = u.SetWindowPos(w.hwnd, null, 0, 0, r.right - r.left, r.bottom - r.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    /// Whether the content is under the title bar, and the window has no
    /// frame of its own (`Options.draw_in_title_bar`; not in fullscreen).
    fn customFrame(w: *const Win32Window) bool {
        return w.draw_in_title_bar and !w.fullscreen;
    }

    /// How thick the window's frame is, in pixels at its DPI (what a
    /// maximized window overhangs the screen by, and its edges that resize).
    fn frameThickness(w: *const Win32Window, u: *const w32.User32) i32 {
        const dpi = u.GetDpiForWindow(w.hwnd);
        const d: w32.UINT = if (dpi == 0) 96 else dpi;
        return u.GetSystemMetricsForDpi(SM_CXSIZEFRAME, d) + u.GetSystemMetricsForDpi(SM_CXPADDEDBORDER, d);
    }

    /// Makes `r` (a client area) the window's rectangle round it: with a frame
    /// of its own, the rectangle it is (a window with the content in the title
    /// bar has none).
    fn outerRect(w: *const Win32Window, u: *const w32.User32, r: *w32.RECT) void {
        if (w.draw_in_title_bar) return;
        const dpi = u.GetDpiForWindow(w.hwnd);
        _ = u.AdjustWindowRectExForDpi(r, WS_OVERLAPPEDWINDOW, w32.FALSE, 0, if (dpi == 0) 96 else dpi);
    }

    /// Has DWM draw the window's buttons over the content (it draws them in
    /// the part of the frame extended into the client area), and the frame
    /// worked out again.
    fn extendFrame(w: *Win32Window, u: *const w32.User32) void {
        if (!w.draw_in_title_bar) return;
        const d = w32.dwmapi() orelse return;
        const dpi = u.GetDpiForWindow(w.hwnd);
        const caption = u.GetSystemMetricsForDpi(SM_CYCAPTION, if (dpi == 0) 96 else dpi);
        const margins: w32.MARGINS = .{ .cyTopHeight = w.frameThickness(u) + caption };
        _ = d.DwmExtendFrameIntoClientArea(w.hwnd, &margins);
        _ = u.SetWindowPos(w.hwnd, null, 0, 0, 0, 0, SWP_NOMOVE | 0x0001 | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }

    /// Starts moving the window with the pointer, from the left button's press:
    /// for the app's own title bar. Nothing, if it is not held.
    pub fn startMove(w: *Win32Window) void {
        if (w.buttons_held == 0) return;
        const u = w32.user32() orelse return;
        _ = u.ReleaseCapture();
        _ = u.SendMessageW(w.hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    }

    /// Where the window's buttons (minimize, maximize, close) are over the
    /// content, if the app draws in the title bar: their rectangle, with some
    /// room around it. None in fullscreen, or minimized.
    pub fn cutouts(w: *const Win32Window, out: *[window.max_cutouts]gfx.Rect) usize {
        if (!w.customFrame() or w.minimized) return 0;
        const d = w32.dwmapi() orelse return 0;
        const u = w32.user32() orelse return 0;
        var r: w32.RECT = .{};
        if (!w32.succeeded(d.DwmGetWindowAttribute(w.hwnd, DWMWA_CAPTION_BUTTON_BOUNDS, &r, @sizeOf(w32.RECT)))) return 0;
        // In the window's pixels from its top left: the client area is inside
        // it by what a maximized window overhangs the screen by.
        const inset: i32 = if (u.IsZoomed(w.hwnd) != 0) w.frameThickness(u) else 0;
        const s: f32 = @floatFromInt(w.scale);
        const room = 6;
        const x = @max(@as(f32, @floatFromInt(r.left - inset)) / s - room, 0);
        const y = @max(@as(f32, @floatFromInt(r.top - inset)) / s - room, 0);
        const right = @as(f32, @floatFromInt(r.right - inset)) / s + room;
        const bottom = @as(f32, @floatFromInt(r.bottom - inset)) / s + room;
        out[0] = .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
        return 1;
    }

    fn updateScale(w: *Win32Window, u: *const w32.User32) void {
        const dpi = u.GetDpiForWindow(w.hwnd);
        // 125% is 1, 150% and 175% are 2: kete's scales are whole.
        w.scale = if (dpi == 0) 1 else @max(1, (dpi + 48) / 96);
    }

    /// The display's refresh, from DWM.
    fn updateRefresh(w: *Win32Window) void {
        const t = w32.CompositionTiming.get() orelse return;
        const ns = w32.qpcToNs(@intCast(t.refresh_qpc));
        if (ns >= std.time.ns_per_ms) w.refresh_ns = ns;
    }

    /// The window's client area, and its state: its new logical size if
    /// it changed (or its scale did).
    pub fn applyConfigure(w: *Win32Window) !?[2]u32 {
        const u = w32.user32() orelse return null;
        var r: w32.RECT = .{};
        _ = u.GetClientRect(w.hwnd, &r);
        w.minimized = u.IsIconic(w.hwnd) != 0;
        if (w.occluded) if (w.swap) |*sc| {
            w.occluded = sc.occluded();
        };
        if (w.minimized) return null;
        w.maximized = !w.fullscreen and u.IsZoomed(w.hwnd) != 0;
        const old_scale = w.scale;
        w.updateScale(u);
        const pw: u32 = @intCast(@max(r.right - r.left, 1));
        const ph: u32 = @intCast(@max(r.bottom - r.top, 1));
        w.pixel_size = .{ pw, ph };
        // Rounded up: the frame covers the whole client area (its last row
        // and column cut off).
        const nw = (pw + w.scale - 1) / w.scale;
        const nh = (ph + w.scale - 1) / w.scale;
        if (nw == w.width and nh == w.height and old_scale == w.scale) return null;
        w.width = nw;
        w.height = nh;
        return .{ nw, nh };
    }

    // --- The window's messages ---------------------------------------------------------

    fn ofHwnd(hwnd: HWND) ?*Win32Window {
        const u = w32.user32() orelse return null;
        const p = u.GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (p == 0) return null;
        return @ptrFromInt(@as(usize, @bitCast(p)));
    }

    fn wndProc(hwnd: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(w32.cc) LRESULT {
        const u = w32.user32().?;
        if (message == WM_NCCREATE) {
            // Its CREATESTRUCTW's first field: what CreateWindowExW was given.
            const create: *const ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = u.SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(create.*)));
            return u.DefWindowProcW(hwnd, message, wparam, lparam);
        }
        const w = ofHwnd(hwnd) orelse return u.DefWindowProcW(hwnd, message, wparam, lparam);
        if (w.handle(u, message, wparam, lparam)) |result| return result;
        return u.DefWindowProcW(hwnd, message, wparam, lparam);
    }

    /// Handles a message (null: as Windows does by default).
    fn handle(w: *Win32Window, u: *const w32.User32, message: UINT, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
        switch (message) {
            WM_CLOSE => {
                // The app closes it, if it will, when it takes the request.
                w.close_requested = true;
                return 0;
            },
            WM_DESTROY => return 0,
            WM_ERASEBKGND => return 1,
            WM_PAINT => {
                var ps: w32.PAINTSTRUCT = undefined;
                if (u.BeginPaint(w.hwnd, &ps)) |hdc| {
                    // What was shown is shown again (it has not changed):
                    // DWM keeps the swap chain's, the CPU's is drawn again.
                    if (!w.on_gpu and w.pixels_shown) w.blit(hdc);
                    _ = u.EndPaint(w.hwnd, &ps);
                }
                return 0;
            },
            WM_SIZE => {
                w.minimized = wparam == SIZE_MINIMIZED;
                // While resized by its edge, each size is drawn at once.
                if (w.in_modal and !w.minimized) w.drawNow();
                return 0;
            },
            WM_GETMINMAXINFO => {
                const info: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                var r: w32.RECT = .{ .right = @intCast(w.min_size[0] * w.scale), .bottom = @intCast(w.min_size[1] * w.scale) };
                w.outerRect(u, &r);
                info.ptMinTrackSize = .{ .x = r.right - r.left, .y = r.bottom - r.top };
                return 0;
            },
            WM_DPICHANGED => {
                // The size Windows suggests for the new DPI.
                const r: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = u.SetWindowPos(w.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
                w.extendFrame(u);
                return 0;
            },
            WM_NCCALCSIZE => {
                // With the content in the title bar, the whole window is the
                // client area (but for what a maximized window overhangs the
                // screen by).
                if (!w.customFrame()) return null;
                if (wparam != 0) {
                    const params: *w32.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    if (u.IsZoomed(w.hwnd) != 0) {
                        const f = w.frameThickness(u);
                        params.rgrc[0].left += f;
                        params.rgrc[0].top += f;
                        params.rgrc[0].right -= f;
                        params.rgrc[0].bottom -= f;
                    }
                }
                return 0;
            },
            WM_NCHITTEST => {
                if (!w.customFrame()) return null;
                // The window's buttons are DWM's to answer for.
                if (w32.dwmapi()) |d| {
                    var result: LRESULT = 0;
                    if (d.DwmDefWindowProc(w.hwnd, message, wparam, lparam, &result) != 0) return result;
                }
                if (u.IsZoomed(w.hwnd) != 0) return HTCLIENT;
                // The edges, which resize it (there is no frame to do so).
                var r: w32.RECT = .{};
                _ = u.GetWindowRect(w.hwnd, &r);
                const bits: usize = @bitCast(lparam);
                const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(bits))));
                const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16))));
                const f = w.frameThickness(u);
                const left = x < r.left + f;
                const right = x >= r.right - f;
                const top = y < r.top + f;
                const bottom = y >= r.bottom - f;
                if (top and left) return HTTOPLEFT;
                if (top and right) return HTTOPRIGHT;
                if (bottom and left) return HTBOTTOMLEFT;
                if (bottom and right) return HTBOTTOMRIGHT;
                if (left) return HTLEFT;
                if (right) return HTRIGHT;
                if (top) return HTTOP;
                if (bottom) return HTBOTTOM;
                return HTCLIENT;
            },
            WM_DISPLAYCHANGE => {
                w.updateRefresh();
                return null;
            },
            WM_SETTINGCHANGE => {
                // "ImmersiveColorSet": light or dark may have changed.
                w.dark = w32.appsUseDark();
                w.applyDarkTitleBar();
                return null;
            },
            WM_SETCURSOR => {
                if ((@as(usize, @bitCast(lparam)) & 0xffff) != HTCLIENT) return null;
                _ = u.SetCursor(cursorHandle(u, w.cursor));
                return 1;
            },
            WM_ENTERSIZEMOVE, WM_ENTERMENULOOP => {
                // Moved or resized: its popups are done (a tooltip comes
                // back where it now goes); the system menu ends its menus.
                w.endPopups(message == WM_ENTERSIZEMOVE);
                w.enterModal(u);
                return null;
            },
            WM_ACTIVATE => {
                // Another app, or another window, took the keyboard: its
                // menus are done, as a compositor ends a popup whose grab
                // broke.
                if (wparam & 0xffff == 0) w.endPopups(false);
                return null;
            },
            WM_NCLBUTTONDOWN => {
                w.endPopups(false);
                return null;
            },
            WM_EXITSIZEMOVE, WM_EXITMENULOOP => {
                w.exitModal(u);
                return null;
            },
            WM_APP_FRAME => {
                w.frame_posted = false;
                if (w.in_modal) w.modalFrame(u);
                return 0;
            },
            WM_TIMER => {
                if (wparam != frame_timer_id) return null;
                // Windows delivers timers only once input has been handled:
                // the frames go on from here if they stopped for input.
                if (w.in_modal and !w.frame_posted) w.modalFrame(u);
                return 0;
            },
            WM_CAPTURECHANGED => {
                w.buttons_held = 0;
                return null;
            },
            WM_KILLFOCUS => {
                w.high_surrogate = 0;
                return null;
            },
            WM_MOUSEMOVE => {
                if (!w.pointer_in) {
                    w.pointer_in = true;
                    var tme: w32.TRACKMOUSEEVENT = .{ .dwFlags = TME_LEAVE, .hwndTrack = w.hwnd };
                    _ = u.TrackMouseEvent(&tme);
                }
                w.last_pointer = w.pointAt(lparam);
                w.push(.{ .motion = w.last_pointer });
                return 0;
            },
            WM_MOUSELEAVE => {
                w.pointer_in = false;
                // Onto one of its popups is not leaving.
                if (!w.pointerOverPopup(u)) w.push(.leave);
                return 0;
            },
            WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_XBUTTONDOWN, WM_XBUTTONUP => {
                w.button(u, w.hwnd, w.pointAt(lparam), message, wparam);
                return if (message == WM_XBUTTONDOWN or message == WM_XBUTTONUP) 1 else 0;
            },
            WM_MOUSEWHEEL, WM_MOUSEHWHEEL => {
                const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                var lines: UINT = 3;
                _ = u.SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
                // A notch is `lines` lines, of about ten pixels each (as on
                // macOS); up and right are positive.
                const px = @as(f32, @floatFromInt(delta)) / WHEEL_DELTA * @as(f32, @floatFromInt(@min(lines, 100))) * 10;
                // The wheel's position is on the screen: the pointer's last
                // in the window is used instead.
                const pos = w.last_pointer;
                if (message == WM_MOUSEWHEEL) {
                    w.push(.{ .scroll = .{ .pos = pos, .dx = 0, .dy = -px } });
                } else {
                    w.push(.{ .scroll = .{ .pos = pos, .dx = px, .dy = 0 } });
                }
                return 0;
            },
            WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP => {
                w.key(u, wparam, lparam, message == WM_KEYDOWN or message == WM_SYSKEYDOWN);
                // Alt and F10 keep their system meanings (Alt+F4, the
                // system menu).
                return if (message == WM_SYSKEYDOWN or message == WM_SYSKEYUP) null else 0;
            },
            WM_CHAR => {
                // A character with no key down before it (typed with Alt
                // and the keypad, or given by an input method).
                if (w.charOf(@intCast(wparam & 0xffff))) |ch| w.push(.{ .key = .{ .key = .other, .pressed = true, .char = ch } });
                return 0;
            },
            WM_SYSCHAR => {
                // Alt and a letter would beep (there is no menu bar); Alt
                // and Space opens the system menu.
                return if (wparam == ' ') null else 0;
            },
            else => return null,
        }
    }

    fn push(w: *Win32Window, e: InputEvent) void {
        w.input.append(w.gpa, e) catch {};
    }

    pub fn takeInput(w: *Win32Window) []const InputEvent {
        w.taken.clearRetainingCapacity();
        std.mem.swap(std.ArrayList(InputEvent), &w.input, &w.taken);
        return w.taken.items;
    }

    /// Where a mouse message's pointer is, in logical pixels.
    fn pointAt(w: *const Win32Window, lparam: LPARAM) [2]f32 {
        const bits: usize = @bitCast(lparam);
        const x: i16 = @bitCast(@as(u16, @truncate(bits)));
        const y: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
        const s: f32 = @floatFromInt(w.scale);
        return .{ @as(f32, @floatFromInt(x)) / s, @as(f32, @floatFromInt(y)) / s };
    }

    /// A button message (on the window, or a popup: `hwnd`), at `pos` in the
    /// window's coordinates.
    fn button(w: *Win32Window, u: *const w32.User32, hwnd: HWND, pos: [2]f32, message: UINT, wparam: WPARAM) void {
        const which: window.PointerButton, const pressed: bool = switch (message) {
            WM_LBUTTONDOWN => .{ .left, true },
            WM_LBUTTONUP => .{ .left, false },
            WM_RBUTTONDOWN => .{ .right, true },
            WM_RBUTTONUP => .{ .right, false },
            WM_MBUTTONDOWN => .{ .middle, true },
            WM_MBUTTONUP => .{ .middle, false },
            else => .{ if ((wparam >> 16) & 0xffff == 1) .back else .forward, message == WM_XBUTTONDOWN },
        };
        w.last_pointer = pos;
        // The window has the mouse while a button is held (a drag goes on
        // outside it).
        const bit: u32 = @as(u32, 1) << @backingInt(which);
        if (pressed) {
            if (w.buttons_held == 0) _ = u.SetCapture(hwnd);
            w.buttons_held |= bit;
        } else {
            w.buttons_held &= ~bit;
            if (w.buttons_held == 0) _ = u.ReleaseCapture();
        }
        w.push(.{ .button = .{ .pos = pos, .button = which, .pressed = pressed } });
    }

    fn key(w: *Win32Window, u: *const w32.User32, wparam: WPARAM, lparam: LPARAM, pressed: bool) void {
        const vk: u32 = @intCast(wparam & 0xffff);
        var k = keys.scanOf(lparam);
        // Injected keys may come without a scan code.
        if (k.scan == 0) {
            const sc = u.MapVirtualKeyW(vk, MAPVK_VK_TO_VSC_EX);
            k = .{ .scan = sc & 0xff, .extended = sc & 0xff00 == 0xe000 };
        }
        const which_key = window.evdev.keyOf(keys.linuxKey(k.scan, k.extended, vk));
        const shift = u.GetKeyState(VK_SHIFT) < 0;
        const alt = u.GetKeyState(VK_MENU) < 0;
        // AltGr is Ctrl and Alt together: what it types is not a shortcut.
        const ctrl = u.GetKeyState(VK_CONTROL) < 0 and !alt;
        // What it types: the WM_CHAR TranslateMessage put after it.
        var char: ?u21 = null;
        if (pressed) {
            // Two, for a character beyond the Basic Multilingual Plane (a
            // surrogate pair).
            var m: w32.MSG = undefined;
            for (0..2) |_| {
                if (u.PeekMessageW(&m, w.hwnd, WM_CHAR, WM_DEADCHAR, PM_REMOVE) == 0) break;
                // A dead key types nothing yet (the next key does).
                if (m.message == WM_DEADCHAR) break;
                if (w.charOf(@intCast(m.wParam & 0xffff))) |ch| {
                    char = ch;
                    break;
                }
                if (w.high_surrogate == 0) break;
            }
        }
        if (which_key == .other and (char == null or ctrl)) return;
        w.push(.{ .key = .{ .key = which_key, .pressed = pressed, .char = if (ctrl) null else char, .shift = shift, .ctrl = ctrl } });
    }

    /// The character of a `WM_CHAR`'s UTF-16 unit (null for controls, and
    /// for the first half of a pair, kept for the second).
    fn charOf(w: *Win32Window, unit: u16) ?u21 {
        if (unit >= 0xd800 and unit < 0xdc00) {
            w.high_surrogate = unit;
            return null;
        }
        var ch: u21 = unit;
        if (unit >= 0xdc00 and unit < 0xe000) {
            if (w.high_surrogate == 0) return null;
            ch = 0x10000 + ((@as(u21, w.high_surrogate) - 0xd800) << 10) + (unit - 0xdc00);
        }
        w.high_surrogate = 0;
        if (ch < 0x20 or ch == 0x7f) return null;
        return ch;
    }

    // --- Waiting -------------------------------------------------------------------

    /// Handles the messages that have come (for any of the display's
    /// windows), without waiting.
    pub fn poll(w: *Win32Window) !void {
        return w.display.poll();
    }

    /// Waits up to `timeout_ns` for a message or a watched source (see
    /// `Win32Display.wait`).
    pub fn wait(w: *Win32Window, timeout_ns: u64) !void {
        return w.display.wait(timeout_ns);
    }

    fn msCeil(ns: u64) w32.DWORD {
        return @intCast(@min((ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms, w32.INFINITE - 1));
    }

    /// Dispatches the messages there are (for all the thread's windows).
    fn pump() void {
        const u = w32.user32() orelse return;
        var m: w32.MSG = undefined;
        while (u.PeekMessageW(&m, null, 0, 0, PM_REMOVE) != 0) {
            _ = u.TranslateMessage(&m);
            _ = u.DispatchMessageW(&m);
        }
    }

    /// Waits on `source` too (see `Win32Display.watch`).
    pub fn watch(w: *Win32Window, source: window.Source, on: bool) void {
        w.display.watch(source, on);
    }

    fn now(w: *const Win32Window) u64 {
        return window.nowNs(w.io);
    }

    fn updatePending(w: *Win32Window) void {
        if (w.on_gpu) if (w.swap) |sc| {
            // Taken now if it is signalled (and so kept as `swap_ready`).
            if (!w.swap_ready and w32.WaitForSingleObject(sc.waitable, 0) == w32.WAIT_OBJECT_0) w.swap_ready = true;
            w.frame_pending = !w.swap_ready;
            return;
        };
        if (w.frame_pending and w.now() >= w.presented_ns) w.frame_pending = false;
    }

    /// When a frame drawn now would be shown: at the display's next refresh
    /// (as DWM says it is), on kete's clock.
    pub fn nextPresentationNs(w: *const Win32Window, now_ns: u64) u64 {
        if (w32.CompositionTiming.get()) |t| {
            const period = w32.qpcToNs(@intCast(t.refresh_qpc));
            const qpc_now = w32.nowQpc();
            const vblank = w32.qpcToNs(@intCast(t.vblank_qpc));
            const qnow = w32.qpcToNs(qpc_now);
            if (period > 0) {
                // The next refresh after now, on the performance counter,
                // moved to kete's clock.
                const ahead = if (vblank > qnow) vblank - qnow else period - ((qnow - vblank) % period);
                return now_ns + ahead;
            }
        }
        if (w.presented_ns == 0 or now_ns >= w.presented_ns + w.refresh_ns) return now_ns;
        return w.presented_ns + w.refresh_ns;
    }

    /// A frame has been given to be shown: the next waits for the refresh
    /// it is shown at.
    fn shown(w: *Win32Window) void {
        const t = w.now();
        w.presented_ns = w.nextPresentationNs(t);
        w.frame_pending = true;
    }

    // --- Windows' modal loops ----------------------------------------------------------

    pub fn setRedraw(w: *Win32Window, redraw: ?window.Redraw) void {
        w.redraw = redraw;
    }

    fn drawNow(w: *Win32Window) void {
        const r = w.redraw orelse return;
        r.f(r.ctx);
    }

    /// A modal loop has begun (resizing or moving the window, its title bar
    /// held, the system menu): frames are drawn from inside it, at each
    /// refresh, until it ends. A message posted to itself does that; the
    /// loop takes posted messages before input, so it is not posted again
    /// while input waits (the loop handles that first), and a timer, which
    /// comes after input, starts it again.
    fn enterModal(w: *Win32Window, u: *const w32.User32) void {
        if (w.in_modal) return;
        w.in_modal = true;
        _ = u.SetTimer(w.hwnd, frame_timer_id, @intCast(@max(w.refresh_ns / std.time.ns_per_ms, 1)), null);
        w.postFrame(u);
    }

    fn postFrame(w: *Win32Window, u: *const w32.User32) void {
        if (w.frame_posted) return;
        w.frame_posted = u.PostMessageW(w.hwnd, WM_APP_FRAME, 0, 0) != 0;
    }

    fn exitModal(w: *Win32Window, u: *const w32.User32) void {
        if (!w.in_modal) return;
        w.in_modal = false;
        _ = u.KillTimer(w.hwnd, frame_timer_id);
    }

    /// In a modal loop: waits for the next refresh (returning at once for
    /// input, which the loop then handles), draws a frame if one is wanted,
    /// and posts itself again for the next, unless input waits. It waits
    /// whether or not the last drew anything, so that a loop with nothing
    /// to draw does not spin.
    fn modalFrame(w: *Win32Window, u: *const w32.User32) void {
        if (u.GetQueueStatus(QS_INPUT) >> 16 == 0) {
            const gpu_wait = w.on_gpu and w.swap != null and !w.swap_ready;
            // Until a buffer is free, on the GPU; else the next refresh.
            const ns = if (gpu_wait) 2 * w.refresh_ns else w.nextPresentationNs(w.now()) -| w.now();
            var handles: [2]w32.HANDLE = undefined;
            var n: w32.DWORD = 0;
            if (gpu_wait) {
                handles[n] = w.swap.?.waitable;
                n += 1;
            }
            var ms: w32.DWORD = msCeil(ns);
            if (!gpu_wait and ns > 0) if (w.timer) |t| {
                const due: i64 = -@as(i64, @intCast(@max(ns / 100, 1)));
                if (w32.SetWaitableTimer(t, &due, 0, null, null, w32.FALSE) != 0) {
                    handles[n] = t;
                    n += 1;
                    ms = w32.INFINITE;
                }
            };
            if (ns > 0) {
                const woke = u.MsgWaitForMultipleObjectsEx(n, &handles, ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
                if (gpu_wait and woke == w32.WAIT_OBJECT_0) w.swap_ready = true;
                if (!gpu_wait) if (w.timer) |t| {
                    _ = w32.CancelWaitableTimer(t);
                };
            }
        }
        w.updatePending();
        if (!w.frame_pending) w.drawNow();
        if (w.in_modal and u.GetQueueStatus(QS_INPUT) >> 16 == 0) w.postFrame(u);
    }

    // --- The window ------------------------------------------------------------------

    pub fn setMinSize(w: *Win32Window, width: u32, height: u32) void {
        if (w.min_size[0] == width and w.min_size[1] == height) return;
        w.min_size = .{ @max(width, 1), @max(height, 1) };
        // A window already smaller grows to it.
        if (w.fullscreen or w.maximized) return;
        if (w.width < width or w.height < height) {
            const u = w32.user32() orelse return;
            w.resizeTo(u, .{ @max(w.width, width), @max(w.height, height) });
        }
    }

    pub fn setMaximized(w: *Win32Window, on: bool) void {
        const u = w32.user32() orelse return;
        _ = u.ShowWindow(w.hwnd, if (on) SW_MAXIMIZE else SW_RESTORE);
    }

    pub fn setMinimized(w: *Win32Window) void {
        const u = w32.user32() orelse return;
        _ = u.ShowWindow(w.hwnd, SW_MINIMIZE);
    }

    /// Full screen: no frame, over the whole of its monitor (the taskbar
    /// too), which lets DWM show its frames straight to the display.
    pub fn setFullscreen(w: *Win32Window, on: bool) void {
        if (w.fullscreen == on) return;
        const u = w32.user32() orelse return;
        if (on) {
            w.restore = .{};
            _ = u.GetWindowPlacement(w.hwnd, &w.restore);
            w.restore_style = u.GetWindowLongPtrW(w.hwnd, GWL_STYLE);
            const monitor = u.MonitorFromWindow(w.hwnd, MONITOR_DEFAULTTONEAREST) orelse return;
            var mi: w32.MONITORINFO = .{};
            if (u.GetMonitorInfoW(monitor, &mi) == 0) return;
            const style: isize = @bitCast(@as(usize, (WS_POPUP | WS_VISIBLE)));
            _ = u.SetWindowLongPtrW(w.hwnd, GWL_STYLE, style);
            const r = mi.rcMonitor;
            _ = u.SetWindowPos(w.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
            w.fullscreen = true;
        } else {
            _ = u.SetWindowLongPtrW(w.hwnd, GWL_STYLE, w.restore_style);
            _ = u.SetWindowPlacement(w.hwnd, &w.restore);
            _ = u.SetWindowPos(w.hwnd, null, 0, 0, 0, 0, SWP_NOMOVE | 0x0001 | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
            w.fullscreen = false;
        }
    }

    pub fn isFullscreen(w: *const Win32Window) bool {
        return w.fullscreen;
    }

    pub fn setCursor(w: *Win32Window, cursor: window.PointerCursor) void {
        if (w.cursor == cursor) return;
        w.cursor = cursor;
        if (!w.pointer_in) return;
        const u = w32.user32() orelse return;
        _ = u.SetCursor(cursorHandle(u, cursor));
    }

    fn cursorHandle(u: *const w32.User32, cursor: window.PointerCursor) ?w32.HCURSOR {
        const id: usize = switch (cursor) {
            .default => 32512, // IDC_ARROW
            .pointer => 32649, // IDC_HAND
            .text => 32513, // IDC_IBEAM
            .grab, .grabbing, .move => 32646, // IDC_SIZEALL
            .crosshair => 32515, // IDC_CROSS
            .not_allowed => 32648, // IDC_NO
            .wait => 32514, // IDC_WAIT
            .progress => 32650, // IDC_APPSTARTING
            .help => 32651, // IDC_HELP
            .ew_resize => 32644, // IDC_SIZEWE
            .ns_resize => 32645, // IDC_SIZENS
            .nwse_resize => 32642, // IDC_SIZENWSE
            .nesw_resize => 32643, // IDC_SIZENESW
        };
        return u.LoadCursorW(null, id);
    }

    /// The title bar dark or light, as the app's appearance.
    fn applyDarkTitleBar(w: *Win32Window) void {
        const d = w32.dwmapi() orelse return;
        const on: w32.BOOL = if (w.dark orelse false) w32.TRUE else w32.FALSE;
        _ = d.DwmSetWindowAttribute(w.hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &on, @sizeOf(w32.BOOL));
    }

    // --- Frames (on the CPU) -----------------------------------------------------------

    /// Frames drawn on the GPU go to the swap chain; the CPU's, in memory,
    /// are shown with GDI.
    pub fn bufferTransport(w: *const Win32Window) window.WindowBufferTransport {
        return if (w.on_gpu) .swapchain else .memory;
    }

    /// The swap chain's back buffer, as big as the client area in pixels
    /// (made on `device` the first time), for the GPU to draw the next
    /// frame in.
    pub fn beginD3D11Frame(w: *Win32Window, device: *anyopaque) ?gfx.D3D11Target {
        const pw = w.width * w.scale;
        const ph = w.height * w.scale;
        if (w.swap) |*sc| if (sc.device != device) {
            sc.deinit();
            w.swap = null;
        };
        if (w.swap == null) {
            w.swap = gfx.d3d11.SwapChain.create(device, w.hwnd, pw, ph) catch return null;
            w.swap_ready = false;
            w.gpu_size = .{ 0, 0 };
        }
        const sc = &w.swap.?;
        // A frame drawn before a buffer is free (at a new size, as the
        // window is resized) waits for one, so that `Present` does not.
        if (!w.swap_ready and w32.WaitForSingleObject(sc.waitable, msCeil(2 * w.refresh_ns)) == w32.WAIT_OBJECT_0) w.swap_ready = true;
        sc.resize(pw, ph) catch return null;
        w32.release(w.back);
        w.back = sc.backBuffer() catch return null;
        w.on_gpu = true;
        return .{ .texture = w.back.?, .width = pw, .height = ph, .window = w.hwnd };
    }

    /// The buffer to draw the next frame in, as big as the client area in
    /// pixels (its logical size at its scale).
    pub fn beginSoftwareFrame(w: *Win32Window) !gfx.software.Image {
        // Back to the CPU (the GPU could not draw): the swap chain goes, or
        // it would be shown over what GDI draws.
        if (w.swap) |*sc| {
            w32.release(w.back);
            w.back = null;
            sc.deinit();
            w.swap = null;
        }
        w.on_gpu = false;
        const pw = w.width * w.scale;
        const ph = w.height * w.scale;
        if (w.pixels_size[0] != pw or w.pixels_size[1] != ph) {
            w.gpa.free(w.pixels);
            w.pixels = &.{};
            w.pixels = try w.gpa.alloc(u32, @as(usize, pw) * ph);
            @memset(w.pixels, 0xff000000);
            w.pixels_size = .{ pw, ph };
            w.pixels_shown = false;
        }
        return .{ .pixels = w.pixels, .width = pw, .height = ph };
    }

    /// The one buffer is drawn in again each frame: it has the last (as the
    /// renderer's frame does, while it is the same size).
    pub fn bufferAge(w: *const Win32Window) u32 {
        if (w.on_gpu) return if (w.gpu_size[0] == w.width * w.scale and w.gpu_size[1] == w.height * w.scale) 1 else 0;
        return if (w.pixels_shown) 1 else 0;
    }

    /// Shows the frame drawn: the swap chain's (presented at the next
    /// refresh, what changed said), or the CPU's buffer.
    pub fn showDamaged(w: *Win32Window, damage: ?[]const gfx.Viewport) !void {
        if (w.on_gpu) if (w.swap) |*sc| {
            w32.release(w.back);
            w.back = null;
            switch (sc.present(damage)) {
                .shown => {},
                .occluded => w.occluded = true,
                .failed => return error.PresentFailed,
            }
            w.gpu_size = .{ sc.width, sc.height };
            w.swap_ready = false;
            w.shown();
            return;
        };
        const u = w32.user32() orelse return error.NoUser32;
        const hdc = u.GetDC(w.hwnd) orelse return error.NoDeviceContext;
        defer _ = u.ReleaseDC(w.hwnd, hdc);
        w.blit(hdc);
        w.pixels_shown = true;
        w.shown();
    }

    fn blit(w: *const Win32Window, hdc: w32.HDC) void {
        const g = w32.gdi32() orelse return;
        if (w.pixels.len == 0) return;
        // Top row first (a negative height); 0xAARRGGBB is BGRA in memory,
        // as a 32-bit DIB's pixels are.
        const bmi: w32.BITMAPINFOHEADER = .{ .biWidth = @intCast(w.pixels_size[0]), .biHeight = -@as(w32.LONG, @intCast(w.pixels_size[1])) };
        _ = g.SetDIBitsToDevice(hdc, 0, 0, w.pixels_size[0], w.pixels_size[1], 0, 0, 0, w.pixels_size[1], w.pixels.ptr, &bmi, 0);
    }

    // --- Popups -------------------------------------------------------------------

    /// Opens a popup (a menu or a tooltip) where `placement` says, by
    /// Wayland's positioner model (`window.Positioner`), kept on its
    /// anchor's monitor: a layered window over the window (owned by it, so
    /// above it, and hidden with it) that never takes the keyboard (so a
    /// menu's keys still come to the window), its pointer input the
    /// window's, in the window's coordinates. A tooltip lets the pointer
    /// through. Null if it cannot be opened.
    pub fn openPopup(w: *Win32Window, placement: window.PopupPlacement) ?u32 {
        const u = w32.user32() orelse return null;
        const slot = for (&w.popups) |*slot| {
            if (slot.* == null) break slot;
        } else return null;
        var origin: w32.POINT = .{ .x = 0, .y = 0 };
        _ = u.ClientToScreen(w.hwnd, &origin);
        const s: i32 = @intCast(w.scale);
        const pos = placement.positioner(.{ w.width, w.height }).place(w.workAreaOf(u, origin, placement.anchor));
        const pw = @max(placement.size[0], 1) * w.scale;
        const ph = @max(placement.size[1], 1) * w.scale;
        const at: w32.POINT = .{ .x = origin.x + pos[0] * s, .y = origin.y + pos[1] * s };
        var ex = WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
        if (placement.kind == .tooltip) ex |= WS_EX_TRANSPARENT;
        const instance: ?w32.HINSTANCE = @ptrCast(w32.GetModuleHandleW(null));
        const hwnd = u.CreateWindowExW(ex, popup_class_name, std.unicode.utf8ToUtf16LeStringLiteral(""), WS_POPUP, at.x, at.y, @intCast(pw), @intCast(ph), w.hwnd, null, instance, w) orelse return null;
        const id = w.next_popup_id;
        w.next_popup_id +%= 1;
        slot.* = .{ .id = id, .placement = placement, .hwnd = hwnd, .position = pos, .screen_at = at, .pixel_size = .{ pw, ph } };
        return id;
    }

    /// The work area (the screen less the taskbar) of the monitor `anchor`
    /// is on, in the window's coordinates (its client area's top left is at
    /// `origin` on the screen).
    fn workAreaOf(w: *const Win32Window, u: *const w32.User32, origin: w32.POINT, anchor: [4]i32) window.positioner_mod.Rect {
        const s: i32 = @intCast(w.scale);
        const centre: w32.POINT = .{ .x = origin.x + (anchor[0] + @divTrunc(anchor[2], 2)) * s, .y = origin.y + (anchor[1] + @divTrunc(anchor[3], 2)) * s };
        var mi: w32.MONITORINFO = .{};
        const monitor = u.MonitorFromPoint(centre, MONITOR_DEFAULTTONEAREST);
        if (monitor == null or u.GetMonitorInfoW(monitor.?, &mi) == 0) return .{ -1 << 20, -1 << 20, 2 << 20, 2 << 20 };
        const r = mi.rcWork;
        // Inward, to whole logical pixels.
        const x0 = std.math.divCeil(i32, r.left - origin.x, s) catch 0;
        const y0 = std.math.divCeil(i32, r.top - origin.y, s) catch 0;
        const x1 = std.math.divFloor(i32, r.right - origin.x, s) catch 0;
        const y1 = std.math.divFloor(i32, r.bottom - origin.y, s) catch 0;
        return .{ x0, y0, @max(x1 - x0, 1), @max(y1 - y0, 1) };
    }

    fn popupOf(w: *Win32Window, id: u32) ?*Popup {
        for (&w.popups) |*slot| if (slot.*) |*pop| if (pop.id == id) return pop;
        return null;
    }

    fn popupOfHwnd(w: *Win32Window, hwnd: HWND) ?*Popup {
        for (&w.popups) |*slot| if (slot.*) |*pop| if (pop.hwnd == hwnd) return pop;
        return null;
    }

    pub fn closePopup(w: *Win32Window, id: u32) void {
        for (&w.popups) |*slot| if (slot.*) |*pop| if (pop.id == id) {
            w.destroyPopup(pop);
            slot.* = null;
            return;
        };
    }

    fn destroyPopup(w: *Win32Window, pop: *Popup) void {
        if (w32.user32()) |u| {
            _ = u.SetWindowLongPtrW(pop.hwnd, GWLP_USERDATA, 0);
            _ = u.DestroyWindow(pop.hwnd);
        }
        if (w32.gdi32()) |g| {
            if (pop.dc) |dc| _ = g.DeleteDC(dc);
            if (pop.bitmap) |b| _ = g.DeleteObject(b);
        }
        w.gpa.free(pop.pixels);
    }

    /// Where the popup is, in the window's coordinates (known as soon as
    /// it is opened: kete places it).
    pub fn popupPosition(w: *Win32Window, id: u32) ?[2]i32 {
        const pop = w.popupOf(id) orelse return null;
        return pop.position;
    }

    /// The buffer to draw the popup in, all of it, at the window's scale.
    pub fn beginSoftwarePopupFrame(w: *Win32Window, id: u32) !?gfx.software.Image {
        const pop = w.popupOf(id) orelse return null;
        const len = @as(usize, pop.pixel_size[0]) * pop.pixel_size[1];
        if (pop.pixels.len != len) {
            w.gpa.free(pop.pixels);
            pop.pixels = &.{};
            pop.pixels = try w.gpa.alloc(u32, len);
        }
        return .{ .pixels = pop.pixels, .width = pop.pixel_size[0], .height = pop.pixel_size[1] };
    }

    /// Shows what was drawn in the popup (premultiplied, per-pixel alpha),
    /// and the popup, the first time (without taking the keyboard).
    pub fn showPopup(w: *Win32Window, id: u32) !void {
        const pop = w.popupOf(id) orelse return;
        const u = w32.user32() orelse return error.NoUser32;
        const g = w32.gdi32() orelse return error.NoGdi32;
        if (pop.bits == null) {
            const bmi: w32.BITMAPINFOHEADER = .{ .biWidth = @intCast(pop.pixel_size[0]), .biHeight = -@as(w32.LONG, @intCast(pop.pixel_size[1])) };
            var bits: ?*anyopaque = null;
            pop.bitmap = g.CreateDIBSection(null, &bmi, 0, &bits, null, 0) orelse return error.NoBitmap;
            pop.bits = @ptrCast(@alignCast(bits orelse return error.NoBitmap));
            pop.dc = g.CreateCompatibleDC(null) orelse return error.NoDeviceContext;
            _ = g.SelectObject(pop.dc.?, pop.bitmap.?);
        }
        const len = @as(usize, pop.pixel_size[0]) * pop.pixel_size[1];
        window.premultiply(pop.bits.?[0..len], pop.pixels);
        const extent: w32.SIZE = .{ .cx = @intCast(pop.pixel_size[0]), .cy = @intCast(pop.pixel_size[1]) };
        const src: w32.POINT = .{ .x = 0, .y = 0 };
        const blend: w32.BLENDFUNCTION = .{};
        if (u.UpdateLayeredWindow(pop.hwnd, null, &pop.screen_at, &extent, pop.dc, &src, 0, &blend, w32.ULW_ALPHA) == 0) return error.UpdateLayeredWindowFailed;
        if (!pop.shown) {
            _ = u.ShowWindow(pop.hwnd, SW_SHOWNOACTIVATE);
            pop.shown = true;
        }
    }

    /// Its menus are done (and its tooltips too, if `all`): as a compositor
    /// ends a popup whose grab broke. The UI closes them.
    fn endPopups(w: *Win32Window, all: bool) void {
        for (w.popups) |slot| if (slot) |pop| {
            if (all or pop.placement.kind == .menu) w.push(.{ .popup_done = pop.id });
        };
    }

    /// Whether the pointer is over one of its popups.
    fn pointerOverPopup(w: *Win32Window, u: *const w32.User32) bool {
        var at: w32.POINT = undefined;
        if (u.GetCursorPos(&at) == 0) return false;
        const under = u.WindowFromPoint(at) orelse return false;
        return w.popupOfHwnd(under) != null;
    }

    fn popupProc(hwnd: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(w32.cc) LRESULT {
        const u = w32.user32().?;
        if (message == WM_NCCREATE) {
            const create: *const ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = u.SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(create.*)));
            return u.DefWindowProcW(hwnd, message, wparam, lparam);
        }
        const w = ofHwnd(hwnd) orelse return u.DefWindowProcW(hwnd, message, wparam, lparam);
        const pop = w.popupOfHwnd(hwnd) orelse return u.DefWindowProcW(hwnd, message, wparam, lparam);
        switch (message) {
            // Clicked, it does not take the keyboard from the window.
            WM_MOUSEACTIVATE => return MA_NOACTIVATE,
            WM_ERASEBKGND => return 1,
            WM_SETCURSOR => {
                _ = u.SetCursor(cursorHandle(u, w.cursor));
                return 1;
            },
            WM_MOUSEMOVE => {
                var tme: w32.TRACKMOUSEEVENT = .{ .dwFlags = TME_LEAVE, .hwndTrack = hwnd };
                _ = u.TrackMouseEvent(&tme);
                w.last_pointer = popupPoint(w, pop, lparam);
                w.push(.{ .motion = w.last_pointer });
                return 0;
            },
            WM_MOUSELEAVE => {
                // Onto the window, or another popup, is not leaving.
                if (!w.pointer_in and !w.pointerOverPopup(u)) w.push(.leave);
                return 0;
            },
            WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_XBUTTONDOWN, WM_XBUTTONUP => {
                w.button(u, hwnd, popupPoint(w, pop, lparam), message, wparam);
                return if (message == WM_XBUTTONDOWN or message == WM_XBUTTONUP) 1 else 0;
            },
            else => return u.DefWindowProcW(hwnd, message, wparam, lparam),
        }
    }

    /// Where a mouse message on a popup is, in the window's coordinates.
    fn popupPoint(w: *const Win32Window, pop: *const Popup, lparam: LPARAM) [2]f32 {
        const local = w.pointAt(lparam);
        return .{ @as(f32, @floatFromInt(pop.position[0])) + local[0], @as(f32, @floatFromInt(pop.position[1])) + local[1] };
    }

    // --- The clipboard ---------------------------------------------------------------

    pub fn copy(w: *Win32Window, text: []const u8) void {
        const u = w32.user32() orelse return;
        if (!openClipboard(u, w.hwnd)) return;
        defer _ = u.CloseClipboard();
        _ = u.EmptyClipboard();
        // UTF-16, with a 0 at its end.
        const units = std.unicode.calcUtf16LeLen(text) catch return;
        const mem = w32.GlobalAlloc(w32.GMEM_MOVEABLE, (units + 1) * 2) orelse return;
        const p: [*]u16 = @ptrCast(@alignCast(w32.GlobalLock(mem) orelse {
            _ = w32.GlobalFree(mem);
            return;
        }));
        const n = std.unicode.utf8ToUtf16Le(p[0..units], text) catch 0;
        p[n] = 0;
        _ = w32.GlobalUnlock(mem);
        // The clipboard has it from now on (if it took it).
        if (u.SetClipboardData(CF_UNICODETEXT, mem) == null) _ = w32.GlobalFree(mem);
    }

    pub fn paste(w: *Win32Window, sink: clipboard.Sink) void {
        const u = w32.user32() orelse return sink.f(sink.ctx, null);
        if (!openClipboard(u, w.hwnd)) return sink.f(sink.ctx, null);
        defer _ = u.CloseClipboard();
        const mem = u.GetClipboardData(CF_UNICODETEXT) orelse return sink.f(sink.ctx, null);
        const p: [*]const u16 = @ptrCast(@alignCast(w32.GlobalLock(mem) orelse return sink.f(sink.ctx, null)));
        defer _ = w32.GlobalUnlock(mem);
        const max = w32.GlobalSize(mem) / 2;
        var len: usize = 0;
        while (len < max and p[len] != 0) len += 1;
        const text = std.unicode.utf16LeToUtf8Alloc(w.gpa, p[0..len]) catch return sink.f(sink.ctx, null);
        defer w.gpa.free(text);
        sink.f(sink.ctx, text);
    }

    /// Opens the clipboard, trying a few times (another app may have it
    /// for a moment).
    fn openClipboard(u: *const w32.User32, hwnd: HWND) bool {
        for (0..5) |_| {
            if (u.OpenClipboard(hwnd) != 0) return true;
        }
        return false;
    }
};

test {
    _ = keys;
}

test "frames are presented to a window through its swap chain, on WARP" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var dx = gfx.D3D11Renderer.initWarp(testing.allocator) catch |e| {
        if (e == error.NoShaders) return error.SkipZigTest;
        return e;
    };
    defer dx.deinit();
    const w = try Win32Window.open(testing.allocator, testing.io, .empty, .{ .title = "kete test", .size = .{ 200, 120 } });
    defer w.close();
    var canvas = gfx.Canvas.init(testing.allocator);
    defer canvas.deinit();
    var p: window.Presenter = .{ .renderer = dx.renderer() };
    for (0..3) |i| {
        try w.wait(std.time.ns_per_s / 10);
        _ = try w.applyConfigure();
        const pw = w.width * w.scale;
        const ph = w.height * w.scale;
        canvas.begin(pw, ph);
        canvas.fillRect(.{ .x = 0, .y = 0, .w = @floatFromInt(pw), .h = @floatFromInt(ph) }, .rgb(@intCast(0x203040 + i)));
        var f: gfx.Frame = .{ .canvases = &.{&canvas}, .segments = &.{.{ .canvas = &canvas }}, .clear = 0xff000000 };
        const rect: gfx.Viewport = if (i == 0) .{ .width = pw, .height = ph } else .{ .x = 8, .y = 8, .width = 32, .height = 24 };
        f.repaints[0].add(rect);
        f.damage.add(rect);
        try p.present(.from(w), &f);
        // Into the swap chain, on the GPU (not on the CPU).
        try testing.expect(w.on_gpu);
        try testing.expectEqual([2]u32{ pw, ph }, w.gpu_size);
    }
}

test "a menu popup opens where the positioner puts it, takes no keyboard, and its input is the window's" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const w = try Win32Window.open(testing.allocator, testing.io, .empty, .{ .title = "kete test", .size = .{ 300, 200 } });
    defer w.close();
    _ = try w.applyConfigure();
    const u = w32.user32().?;

    const placement: window.PopupPlacement = .{ .kind = .menu, .anchor = .{ 299, 199, 1, 1 }, .size = .{ 240, 4000 }, .side = .below_right, .gap = 2 };
    const id = w.openPopup(placement) orelse return error.NoPopup;
    defer w.closePopup(id);
    var origin: w32.POINT = .{ .x = 0, .y = 0 };
    _ = u.ClientToScreen(w.hwnd, &origin);
    const bounds = w.workAreaOf(u, origin, placement.anchor);
    const at = w.popupPosition(id).?;
    try testing.expectEqual(placement.positioner(.{ w.width, w.height }).place(bounds), at);
    // Taller than the screen: against its top.
    try testing.expectEqual(bounds[1], at[1]);

    const img = (try w.beginSoftwarePopupFrame(id)).?;
    @memset(img.pixels, 0x80ff0000);
    try w.showPopup(id);
    const pop = w.popupOf(id).?;
    try testing.expect(u.IsWindowVisible(pop.hwnd) != 0);

    // A move on it, 10 by 5 pixels in: in the window's coordinates.
    _ = w.takeInput();
    const lp: LPARAM = @intCast(10 | (5 << 16));
    _ = Win32Window.popupProc(pop.hwnd, WM_MOUSEMOVE, 0, lp);
    const s: f32 = @floatFromInt(w.scale);
    const events = w.takeInput();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual([2]f32{ @as(f32, @floatFromInt(at[0])) + 10 / s, @as(f32, @floatFromInt(at[1])) + 5 / s }, events[0].motion);
    // Clicked, it does not take the keyboard.
    try testing.expectEqual(@as(LRESULT, MA_NOACTIVATE), Win32Window.popupProc(pop.hwnd, WM_MOUSEACTIVATE, 0, 0));
}
