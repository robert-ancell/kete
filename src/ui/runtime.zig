//! `WindowUi`: a window's UI, which runs its widget tree (what the app's
//! windows share is `SharedResources`). Each frame it builds the root widget
//! (keeping the nodes and state that still match), lays it out to the
//! window's size, and paints it; `render` then draws it through the active `gfx.Renderer`
//! (Software, OpenGL, Vulkan, or a custom backend).
//! Pointer events go to the widgets under the pointer, and keys to the
//! widget with the keyboard (`focus`). A menu (`openMenu`) is shown above
//! everything and gets the pointer first; the right button, or a touch held
//! without moving (`long_press_ns`), asks the widget under it for one
//! (`Event.context`).
//!
//! A touch (one at a time) acts as the left button: a tap clicks. One
//! that moves pans: whatever can scroll under it follows it, and nothing is
//! clicked; if nothing can, it drags as the pointer would.
//!
//! Text is copied and pasted through `clipboard` (the system's, which the
//! app or window gives), or within the app if there is none.
//!
//!     const ui = try WindowUi.createDefault(gpa, io);
//!     defer ui.destroy();
//!     // Each frame:
//!     ui.frame(width, height, now_ns, MyApp{ .title = "Hello" });
//!     try ui.preview(image);

const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window");
const gfx = @import("gfx");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const theme_mod = @import("theme.zig");
const image_loader = @import("image_loader.zig");
const Theme = theme_mod.Theme;
const damage_mod = @import("damage.zig");
const menu_mod = @import("menu.zig");
const drag_mod = @import("drag.zig");
const tooltip_mod = @import("tooltip.zig");
const title_bar_mod = @import("title_bar.zig");
const accessibility = @import("accessibility.zig");
const focus_mod = @import("focus.zig");
const sys = window_mod.sys;
/// AT-SPI is Linux's (on other systems, nothing is offered yet).
const has_atspi = sys.is_linux;
const atspi = if (has_atspi) @import("atspi.zig") else struct {
    pub const Bridge = opaque {};
};

const Point = geometry.Point;
const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;
const Context = widget.BuildContext;
const Event = widget.Event;
const Painter = painter_mod.Painter;
const Segment = painter_mod.Segment;

/// The system's clipboard, for text: `Clipboard.of(&app_clipboard)`, for
/// a type with `copy(self, text)` and `paste(self, sink)`.
pub const Clipboard = struct {
    /// The clipboard's owner, which `vtable` acts on.
    ptr: *anyopaque,
    /// The functions that copy and paste.
    vtable: *const VTable,

    pub const Sink = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, text: ?[]const u8) void,
    };

    pub const VTable = struct {
        copy: *const fn (*anyopaque, []const u8) void,
        paste: *const fn (*anyopaque, Sink) void,
    };

    /// A clipboard that calls `copy` and `paste` on `ptr`, which must last as long as it is used.
    pub fn of(impl: anytype) Clipboard {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        return .{ .ptr = impl, .vtable = &struct {
            const vtable: VTable = .{ .copy = copy, .paste = paste };
            fn copy(ptr: *anyopaque, text: []const u8) void {
                T.copy(@ptrCast(@alignCast(ptr)), text);
            }
            fn paste(ptr: *anyopaque, sink: Sink) void {
                T.paste(@ptrCast(@alignCast(ptr)), .{ .ctx = sink.ctx, .f = sink.f });
            }
        }.vtable };
    }
};

/// Wakes an app's windows (or a `WindowUi`) for a frame from any thread or task:
/// for work done in the background (a fetch started with `io.async`, say),
/// once it has put what it made where the UI will find it. It neither
/// blocks nor allocates, so it can be used from anywhere. From
/// `App.waker` or `WindowUi.waker`; good for as long as
/// that is.
pub const Waker = struct {
    /// What the display waits on, once there is one (see `SharedResources.waker`).
    wake_: ?sys.Wake = null,
    /// Set when the UI is woken, in case it is not waiting on `wake_`.
    woken: ?*std.atomic.Value(bool) = null,

    /// Wakes the UI for a frame. Safe from any thread.
    pub fn wake(w: Waker) void {
        if (w.woken) |f| f.store(true, .release);
        if (w.wake_) |x| x.signal();
    }
};

/// What an app's windows share, each window's `WindowUi` drawing with it: the
/// fonts, the glyph atlas, the renderer, the images loaded, what wakes the
/// UI (`Waker`), the accessibility bus, and the clipboard within the app.
/// It does its I/O, and tells the time, through `io` (the app's).
pub const SharedResources = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Text is drawn in it; without one, text takes no space.
    font: ?*const font.Font,
    owned_font: ?font.Font = null,
    emoji_font: ?font.Font = null,
    /// Icons are drawn with it (see `Icon`).
    icon_font: font.Font,
    atlas: gfx.Atlas,
    vulkan_renderer: ?gfx.VulkanRenderer = null,
    opengl_renderer: ?gfx.OpenGlRenderer = null,
    metal_renderer: ?gfx.MetalRenderer = null,
    d3d11_renderer: ?gfx.D3D11Renderer = null,
    software_renderer: gfx.SoftwareRenderer = .{},
    renderer: ?gfx.Renderer = null,
    owns_renderer: bool = false,
    /// Images loaded in the background (for `Image`).
    images: image_loader.Cache = .{},
    /// Readable when a `Waker` has woken the UI (made by the first
    /// `waker`), and set (as it might be read by a window's wait first).
    wake: ?sys.Wake = null,
    woken: std.atomic.Value(bool) = .init(false),
    /// The connection to assistive technologies (once a window's
    /// `enableAccessibility` has made it).
    a11y: ?*atspi.Bridge = null,
    /// The next id for an object of the accessibility tree (unique in the
    /// app: each window's tree is offered with the others').
    a11y_next_id: u32 = accessibility.window_id,
    /// Text copied, when there is no system clipboard.
    local_clipboard: std.ArrayList(u8) = .empty,
    /// The windows' UIs (made by `createWindowUi`).
    uis: std.ArrayList(*WindowUi) = .empty,

    /// What the app's windows share, with the given `font` (`null` for no
    /// text font; icons still use the bundled Material Icons font). The
    /// renderer is the Metal one (on macOS), the Direct3D 11 one (on
    /// Windows), or the Vulkan one, then OpenGL (elsewhere), or else the
    /// software one.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, f: ?*const font.Font) !*SharedResources {
        const s = try gpa.create(SharedResources);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .images = .{ .io = io },
            .font = f,
            .icon_font = try font.Font.init(@import("icons").font_data),
            .atlas = try gfx.Atlas.init(gpa),
        };
        if (comptime builtin.os.tag == .macos) {
            if (gfx.MetalRenderer.initDefault(gpa)) |mtl| {
                s.metal_renderer = mtl;
                s.renderer = s.metal_renderer.?.renderer();
                s.owns_renderer = true;
            } else |_| {
                s.renderer = s.software_renderer.renderer();
            }
        } else if (comptime builtin.os.tag == .windows) {
            if (gfx.D3D11Renderer.initDefault(gpa)) |dx| {
                s.d3d11_renderer = dx;
                s.renderer = s.d3d11_renderer.?.renderer();
                s.owns_renderer = true;
            } else |_| {
                s.renderer = s.software_renderer.renderer();
            }
        } else if (gfx.VulkanRenderer.initDefault(gpa)) |vk| {
            s.vulkan_renderer = vk;
            s.renderer = s.vulkan_renderer.?.renderer();
            s.owns_renderer = true;
        } else |_| if (gfx.OpenGlRenderer.initDefault(gpa)) |gl| {
            s.opengl_renderer = gl;
            s.renderer = s.opengl_renderer.?.renderer();
            s.owns_renderer = true;
        } else |_| {
            s.renderer = s.software_renderer.renderer();
        }
        return s;
    }

    /// What the app's windows share, using the bundled default Fira Sans and
    /// Twemoji Mozilla fallback fonts.
    pub fn createDefault(gpa: std.mem.Allocator, io: std.Io) !*SharedResources {
        return createWithFontData(gpa, io, font.default_font_data);
    }

    /// What the app's windows share, drawing text in the OpenType or
    /// TrueType font in `data` (which must outlive it), falling back to the
    /// bundled Twemoji Mozilla font for emoji.
    pub fn createWithFontData(gpa: std.mem.Allocator, io: std.Io, data: []const u8) !*SharedResources {
        const s = try create(gpa, io, null);
        errdefer s.destroy();
        s.owned_font = try font.Font.init(data);
        s.emoji_font = font.Font.init(font.emoji_font_data) catch null;
        const f = &s.owned_font.?;
        if (s.emoji_font) |*ef| f.fallback = ef;
        s.font = f;
        return s;
    }

    /// Lets it go: the windows' UIs must be destroyed first.
    pub fn destroy(s: *SharedResources) void {
        std.debug.assert(s.uis.items.len == 0);
        s.uis.deinit(s.gpa);
        s.images.deinit();
        if (s.wake) |*x| x.deinit();
        if (has_atspi) if (s.a11y) |b| b.close();
        s.local_clipboard.deinit(s.gpa);
        if (s.owns_renderer) if (s.renderer) |r| r.deinit();
        s.atlas.deinit();
        s.gpa.destroy(s);
    }

    /// A window's UI, drawing with what is shared (destroy it before this).
    pub fn createWindowUi(s: *SharedResources) !*WindowUi {
        const ui = try s.gpa.create(WindowUi);
        errdefer s.gpa.destroy(ui);
        ui.* = .{
            .shared = s,
            .gpa = s.gpa,
            .io = s.io,
            .font = s.font,
            .icon_font = &s.icon_font,
            .atlas = &s.atlas,
            .images = &s.images,
            .arenas = .{ .init(s.gpa), .init(s.gpa) },
            .presenter = .{ .renderer = s.renderer },
            .a11y_window_id = s.a11y_next_id,
        };
        s.a11y_next_id += 1;
        try s.uis.append(s.gpa, ui);
        return ui;
    }

    /// Draws every window with `r` (a custom or GPU `gfx.Renderer`, e.g.
    /// `OpenGlRenderer.renderer()`, `VulkanRenderer.renderer()`, or
    /// `gfx.Renderer.of(&my_backend)`), which is its to deinit if
    /// `take_ownership`.
    pub fn attachRenderer(s: *SharedResources, r: gfx.Renderer, take_ownership: bool) void {
        if (s.owns_renderer) if (s.renderer) |old| old.deinit();
        s.vulkan_renderer = null;
        s.opengl_renderer = null;
        s.metal_renderer = null;
        s.d3d11_renderer = null;
        s.renderer = r;
        s.owns_renderer = take_ownership;
        for (s.uis.items) |ui| ui.presenter = .{ .renderer = r };
    }

    /// Something to wake the UI for a frame from another thread or task
    /// (it only marks it to be drawn if there are no fds left).
    pub fn waker(s: *SharedResources) Waker {
        if (s.wake == null) s.wake = sys.Wake.create() catch return .{ .woken = &s.woken };
        return .{ .wake_ = s.wake, .woken = &s.woken };
    }

    /// What is read when a `Waker` wakes the UI (to wait on with the
    /// windows'), once there is a waker.
    pub fn wakeSource(s: *SharedResources) ?window_mod.Source {
        return if (s.wake) |*x| .ofWake(x) else null;
    }

    /// Takes the wakes since the last time; true if there were any.
    pub fn takeWakes(s: *SharedResources) bool {
        const drained = if (s.wake) |*w| w.drain() else false;
        return s.woken.swap(false, .acq_rel) or drained;
    }
};

/// A window's UI: its widget tree, focus, input, menus and frames (see the
/// top of this file).
pub const WindowUi = struct {
    /// What the app's windows share (see `SharedResources`), and whether this UI
    /// made it for itself (`create`: a UI of its own, with no others).
    shared: *SharedResources,
    /// Whether it made `shared` for itself, and so lets it go with itself.
    owns_shared: bool = false,
    /// From `shared`, which they are: what allocates, and what does the
    /// I/O and tells the time (the app's `Io`).
    gpa: std.mem.Allocator,
    /// The app's `Io`, which does the I/O and tells the time.
    io: std.Io,
    /// Text is drawn in it; without one, text takes no space (`shared`'s).
    font: ?*const font.Font,
    /// Icons are drawn with it (see `Icon`), glyphs kept in the atlas, and
    /// images loaded in the background (for `Image`): `shared`'s.
    icon_font: *const font.Font,
    /// The glyphs and icons drawn, as images (`shared`'s).
    atlas: *gfx.Atlas,
    /// The images loaded in the background (`shared`'s).
    images: *image_loader.Cache,
    /// The theme widgets are drawn in (see `Themed` for another below a widget).
    theme: Theme = .dark,
    /// The colour of the theme's surface when last seen, to redraw everything if it changes.
    last_surface: ?gfx.Color = null,
    /// The node of the root widget (made by the first `frame`).
    root: ?*Node = null,
    /// Widgets are made in one while the other holds the last frame's
    /// (which events between frames still use).
    arenas: [2]std.heap.ArenaAllocator,
    /// How many frames it has made.
    frame_no: u64 = 0,
    /// The time of the frame being made, on the monotonic clock (`window.nowNs`).
    now_ns: u64 = 0,
    /// Something changed (input, or a widget asked for another frame).
    needs_frame: bool = true,
    /// How many input events it has handled (`handleInput`).
    inputs: u64 = 0,
    /// The frame's drawing: canvases (kept for reuse) and GPU draws.
    canvases: std.ArrayList(*gfx.Canvas) = .empty,
    /// How many of `canvases` this frame has drawn on.
    canvases_used: usize = 0,
    /// What the frame draws, in order: 2D canvases and GPU draws.
    segments: std.ArrayList(Segment) = .empty,
    /// Where the pointer is, if it is over the window.
    pointer: ?Point = null,
    /// Event handlers under the pointer, deepest first.
    hovered: std.ArrayList(*Node) = .empty,
    /// Where the nodes under the pointer are found, before `hovered` takes them.
    hover_scratch: std.ArrayList(*Node) = .empty,
    /// The handler that took the pointer when a button went down.
    captured: ?*Node = null,
    /// The button that went down when it was taken (only its release
    /// gives it back).
    captured_button: widget.PointerButton = .left,
    /// The last press, to count the clicks of a double click.
    last_press: ?struct { ns: u64, pos: Point, button: widget.PointerButton, clicks: u8 } = null,
    /// The widget keys go to.
    focused: ?*Node = null,
    /// Whether the focus was moved by the keyboard (so its ring shows),
    /// not since the pointer was pressed.
    focus_visible: bool = false,
    /// What had the focus when a menu was opened from the keyboard (it
    /// has it again when the menu closes), and that the menu is to be
    /// given it once it is made.
    focus_before_menu: ?*Node = null,
    /// Whether the menu is to be given the focus when it is made.
    menu_focus_pending: bool = false,
    /// The keyboard layout in use (from the window, or `loaded_keymap`).
    keyboard: window_mod.KeyboardLayout = .{},
    /// A keymap of its own (`loadKeymap`), for keys from `keyEvent` that
    /// say nothing of what they type, and the modifiers it keeps.
    loaded_keymap: ?window_mod.xkb.Keymap = null,
    /// What it is to assistive technologies (once `enableAccessibility`
    /// has connected `shared` to AT-SPI): the last frame's tree, and the
    /// number for the next object.
    a11y_tree: ?*accessibility.Tree = null,
    /// The id of its window in the accessibility tree.
    a11y_window_id: u32 = accessibility.window_id,
    /// The modifiers and keys held, for `loaded_keymap`.
    key_state: window_mod.xkb.State = .{},
    /// The window fills the screen: title bars are not drawn.
    fullscreen: bool = false,
    /// Whether the window fills the work area (for `TitleBar`).
    maximized: bool = true,
    /// Whether the window is tiled by the compositor.
    tiled: bool = false,
    /// Active window decoration mode (`none`, `client`, `server`).
    decorations: window_mod.WindowDecorations = .none,
    /// The window attached to the UI, if any.
    win: ?window_mod.Window = null,
    /// What the window's title bar buttons do (set by `attachWindow`).
    controls: ?*window_mod.WindowControls = null,
    /// The app's window it is the UI of (null when it is not an `App`'s).
    app_window: ?*App.Window = null,
    /// Whether the app draws under the title bar (`WindowOptions.draw_in_title_bar`).
    content_in_title_bar: bool = false,
    /// The title bar node (used when `decorations == .toolkit`): the whole
    /// bar, or just the window's buttons, over the content.
    title_bar_root: ?*Node = null,
    /// What the window draws over the content (`cutouts`).
    cutouts_buf: [window_mod.max_cutouts]geometry.Rect = undefined,
    cutouts_len: usize = 0,
    /// The system's clipboard (the app gives it); without one, text is
    /// copied within the app (`local_clipboard`).
    clipboard: ?Clipboard = null,
    /// A paste under way: the widget that asked (whose going drops it),
    /// and where the text goes.
    paste: ?struct { owner: *Node, on_text: widget.ValueCallback([]const u8) } = null,
    /// The menu or popup shown, if any.
    menu: ?struct {
        content: union(enum) {
            items: struct { list: []menu_mod.Item, arena: std.heap.ArenaAllocator },
            popup: PopupBuilder,
        },
        at: Point,
        owner: *Node,
    } = null,
    /// The node of the menu or popup shown, if any.
    menu_root: ?*Node = null,
    /// The menu and tooltip in popups of their own, when the window has
    /// them (`Window.openPopup`); otherwise they are drawn in the window.
    menu_popup: ?PopupLayer = null,
    /// The size of the window the menu was last laid out in.
    menu_window: Size = .{ .w = 0, .h = 0 },
    /// The tooltip in a popup of its own, when the window has them.
    tooltip_popup: ?PopupLayer = null,
    /// Where the menu built this frame wants to be, if in popups.
    wanted_menu: ?window_mod.PopupPlacement = null,
    /// Where the tooltip built this frame wants to be, if in popups.
    wanted_tooltip: ?window_mod.PopupPlacement = null,
    /// How many of `segments` are the window's (the rest are popups').
    main_segments: usize = 0,
    /// What presents its frames in the window (with `renderer`).
    presenter: window_mod.Presenter = .{},
    /// What is being dragged, if anything (see drag.zig), and the chip
    /// that follows the pointer.
    drag: ?drag_mod.Drag = null,
    /// The node of the chip that follows the pointer while dragging.
    drag_root: ?*Node = null,
    /// Where the nodes under the pointer are found while dragging.
    drag_scratch: std.ArrayList(*Node) = .empty,
    /// The node of the tooltip shown, if any.
    tooltip_root: ?*Node = null,
    /// A touch held down on a widget, which becomes a long press
    /// (`Event.context`) if it stays there.
    hold: ?struct { node: *Node, pos: Point, since: ?u64 = null } = null,
    /// The touch followed (others are ignored).
    touch: ?struct { id: i32, start: Point, last: Point, moved: bool = false, panning: bool = false } = null,
    /// The release of a press that became a long press is not sent.
    swallow_release: bool = false,
    /// The window's physical buffer size at the last frame (`logical_size * scale`).
    frame_size: [2]u32 = .{ 1, 1 },
    /// The window's logical size at the last frame.
    logical_size: [2]u32 = .{ 1, 1 },
    /// The integer buffer scale factor (1 for standard DPI, 2+ for HiDPI).
    scale: u32 = 1,
    /// The minimum window size required by the widget tree at the last frame
    /// (at least `min_size_floor`).
    min_size: [2]u32 = .{ 1, 1 },
    /// Optional explicit floor for `min_size` (e.g. from `App.Options.min_size`).
    min_size_floor: [2]u32 = .{ 0, 0 },
    /// Incremented in `Node.reconcile` each time the widget tree's child list
    /// changes (nodes added, removed, or reordered).  Used to skip the full
    /// `minSize` traversal when the tree is structurally stable.
    build_version: u64 = 0,
    /// The `build_version` when the cached raw minimums were last computed.
    /// Initialised to `maxInt` so the very first frame always computes them.
    min_size_version: u64 = std.math.maxInt(u64),
    /// Cached result of `r.minSize(.unbounded)` from the last structural change.
    cached_raw_min: Size = .{},
    /// Cached result of `tb.minSize(.unbounded)` from the last structural change.
    cached_tb_min: Size = .{},
    /// What changed in the last frame (and the frames before).
    damage: damage_mod.Tracker = .{},
    /// Counts nodes as they are painted (their order is part of what they
    /// draw).
    paint_order: u64 = 0,
    /// How many scroll views are laying out their children.
    scrolling: u32 = 0,

    /// A menu or tooltip in a popup: the window's popup, where it is, and
    /// which of the frame's segments are drawn in it.
    pub const PopupLayer = struct {
        popup: window_mod.Popup,
        placement: window_mod.PopupPlacement,
        first: usize = 0,
        end: usize = 0,
        /// What it paints (`paintedHash`), and what it painted when last
        /// drawn: it is drawn again when they differ.
        hash: ?u64 = null,
        drawn_hash: ?u64 = null,
    };

    /// A builder that creates a popup widget each frame while open.
    pub const PopupBuilder = struct {
        ctx: *const anyopaque,
        f: *const fn (ctx: *const anyopaque, cx: *Context) Widget,

        pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), *Context) Widget) PopupBuilder {
            return .{ .ctx = ptr, .f = struct {
                fn call(raw: *const anyopaque, cx: *Context) Widget {
                    return f(@ptrCast(@alignCast(@constCast(raw))), cx);
                }
            }.call };
        }
    };

    /// Creates a `WindowUi` of its own (a window's, with no other windows to
    /// share with: see `SharedResources.createWindowUi`) with the given `font` (`null` for
    /// no text font; icons still use the bundled Material Icons font),
    /// drawn with the best renderer there is (see `SharedResources.create`).
    ///
    /// It does its I/O, and tells the time, through `io`: the app's (as
    /// from `std.process.Init`).
    pub fn create(gpa: std.mem.Allocator, io: std.Io, f: ?*const font.Font) !*WindowUi {
        return standalone(try SharedResources.create(gpa, io, f));
    }

    /// Creates a `WindowUi` of its own using the bundled default Fira Sans and
    /// Twemoji Mozilla fallback fonts.
    pub fn createDefault(gpa: std.mem.Allocator, io: std.Io) !*WindowUi {
        return standalone(try SharedResources.createDefault(gpa, io));
    }

    /// Creates a `WindowUi` of its own drawing text in the OpenType or TrueType
    /// font in `data` (which must outlive it), falling back to the bundled
    /// Twemoji Mozilla font for emoji.
    pub fn createWithFontData(gpa: std.mem.Allocator, io: std.Io, data: []const u8) !*WindowUi {
        return standalone(try SharedResources.createWithFontData(gpa, io, data));
    }

    fn standalone(shared: *SharedResources) !*WindowUi {
        errdefer shared.destroy();
        const ui = try shared.createWindowUi();
        ui.owns_shared = true;
        return ui;
    }

    /// Lets it go: its nodes, and the arenas. Its `shared` too if it made it.
    pub fn destroy(ui: *WindowUi) void {
        const shared = ui.shared;
        if (std.mem.indexOfScalar(*WindowUi, shared.uis.items, ui)) |i| _ = shared.uis.swapRemove(i);
        if (ui.tooltip_popup) |t| t.popup.close();
        if (ui.menu_popup) |m| m.popup.close();
        ui.closeMenu();
        ui.endDrag(false);
        if (ui.loaded_keymap) |*km| km.deinit();
        if (ui.title_bar_root) |tb| tb.destroy();
        // A UI of its own waited on what it shares through its window (an
        // app's, through its display).
        if (ui.owns_shared) if (ui.win) |w| {
            if (ui.images.waitSource()) |src| w.watch(src, false);
            if (shared.wakeSource()) |src| w.watch(src, false);
            if (has_atspi) if (shared.a11y) |b| w.watch(b.source(), false);
        };
        if (ui.a11y_tree) |t| {
            if (has_atspi) if (shared.a11y) |b| b.remove(t);
            t.deinit();
            ui.gpa.destroy(t);
        }
        if (ui.menu_root) |m| m.destroy();
        if (ui.drag_root) |d| d.destroy();
        if (ui.tooltip_root) |t| t.destroy();
        ui.drag_scratch.deinit(ui.gpa);
        if (ui.root) |r| r.destroy();
        ui.hovered.deinit(ui.gpa);
        ui.hover_scratch.deinit(ui.gpa);
        for (ui.canvases.items) |c| {
            c.deinit();
            ui.gpa.destroy(c);
        }
        ui.canvases.deinit(ui.gpa);
        ui.segments.deinit(ui.gpa);
        for (&ui.arenas) |*a| a.deinit();
        const owns_shared = ui.owns_shared;
        ui.gpa.destroy(ui);
        if (owns_shared) shared.destroy();
    }

    /// Attaches a custom or GPU `gfx.Renderer` (e.g. `OpenGlRenderer.renderer()`,
    /// `VulkanRenderer.renderer()`, or `gfx.Renderer.of(&my_backend)`): for
    /// all the app's windows (see `SharedResources.attachRenderer`).
    pub fn attachRenderer(ui: *WindowUi, r: gfx.Renderer, take_ownership: bool) void {
        ui.shared.attachRenderer(r, take_ownership);
    }

    /// Connects the UI's clipboard, keyboard layout, and window state to
    /// `win` (either a `window.Window` or a pointer such as `*window.WaylandWindow`).
    pub fn attachWindow(ui: *WindowUi, win: anytype, controls: ?*window_mod.WindowControls) void {
        const w = window_mod.Window.from(win);
        ui.win = w;
        ui.controls = controls;
        ui.syncWindow(w);
    }

    /// Updates the UI's keyboard layout and window state from `win` (the
    /// one place they are copied from the window). A change to how the
    /// window is shown redraws all of it.
    pub fn syncWindow(ui: *WindowUi, win: anytype) void {
        const w = window_mod.Window.from(win);
        if (ui.loaded_keymap == null) ui.keyboard = w.layout();
        const fullscreen = w.isFullscreen();
        const maximized = w.isMaximized();
        const tiled = w.isTiled();
        const decorations = w.decorations();
        const scale = @max(w.scale(), 1);
        if (fullscreen != ui.fullscreen or maximized != ui.maximized or tiled != ui.tiled or
            decorations != ui.decorations or scale != ui.scale)
        {
            ui.damage.invalidate();
            ui.needs_frame = true;
        }
        ui.fullscreen = fullscreen;
        ui.maximized = maximized;
        ui.tiled = tiled;
        ui.decorations = decorations;
        ui.scale = scale;
    }

    /// True when the toolkit should automatically add a `TitleBar` above the
    /// application's root widget (in a window whose decorations it draws,
    /// when not fullscreen).
    pub fn hasToolkitTitleBar(ui: *const WindowUi) bool {
        return ui.win != null and ui.decorations == .toolkit and !ui.fullscreen;
    }

    /// True when the toolkit draws the window's buttons over the content,
    /// which goes under the title bar (and not a bar of its own).
    pub fn hasControlsOverlay(ui: *const WindowUi) bool {
        return ui.content_in_title_bar and ui.hasToolkitTitleBar();
    }

    /// The parts of the window drawn over the app's content (a phone's
    /// notch, so to say): the window's buttons, if the content is in the title
    /// bar, in logical pixels. Good until the next frame.
    pub fn cutouts(ui: *const WindowUi) []const geometry.Rect {
        return ui.cutouts_buf[0..ui.cutouts_len];
    }

    /// What the app runs on (see `widget.BackendInfo`).
    pub fn backend(ui: *const WindowUi) widget.BackendInfo {
        return .{
            .platform = if (ui.win) |w| w.platform() else .headless,
            .wayland_extensions = if (ui.win) |w| waylandExtensionsOf(w) else &.{},
            .renderer = if (ui.shared.renderer) |r| r.backend() else .software,
            .keyboard = ui.keyboard,
        };
    }

    /// The Wayland extensions `w` uses, if it is a Wayland window.
    fn waylandExtensionsOf(w: window_mod.Window) []const []const u8 {
        // There is no Wayland backend to be on Windows.
        if (comptime builtin.os.tag == .windows) return &.{};
        const wl = w.as(window_mod.WaylandWindow) orelse return &.{};
        return wl.waylandExtensions();
    }

    /// The pointer cursor shape requested by the currently dragged,
    /// captured, or hovered widget.
    pub fn cursor(ui: *const WindowUi) widget.PointerCursor {
        if (ui.drag != null) return .grabbing;
        if (ui.captured) |cap| {
            if (cap.widget.vtable.cursor) |f| {
                const pos = ui.pointer orelse Point{ 0, 0 };
                if (f(cap.widget.ptr, cap, local(cap, pos))) |c| return c;
            }
        }
        if (ui.pointer) |pos| {
            for (ui.hovered.items) |n| {
                if (n.widget.vtable.cursor) |f| {
                    if (f(n.widget.ptr, n, local(n, pos))) |c| return c;
                }
            }
        }
        return .default;
    }

    /// Updates `win`'s cursor shape to match `ui.cursor()`.
    pub fn syncCursor(ui: *const WindowUi, win: anytype) void {
        window_mod.Window.from(win).setCursor(ui.cursor());
    }

    /// Updates `win`'s minimum size to match `ui.min_size`.
    pub fn syncMinSize(ui: *const WindowUi, win: anytype) void {
        window_mod.Window.from(win).setMinSize(ui.min_size[0], ui.min_size[1]);
    }

    /// The input method state for the currently focused widget, or null
    /// when no text input widget is focused.
    pub fn textInputState(ui: *const WindowUi) ?window_mod.TextInputState {
        const n = ui.focused orelse return null;
        const f = n.widget.vtable.text_input orelse return null;
        const info = f(n.widget.ptr, n) orelse return null;
        const origin = n.position();
        const ox: i32 = @intFromFloat(@round(origin[0]));
        const oy: i32 = @intFromFloat(@round(origin[1]));
        return .{
            .surrounding_text = info.surrounding_text,
            .cursor = info.cursor,
            .anchor = info.anchor,
            .change_cause = if (info.change_cause_other) .other else .input_method,
            .password = info.password,
            .multiline = info.multiline,
            .cursor_rect = .{
                ox + info.cursor_rect[0],
                oy + info.cursor_rect[1],
                info.cursor_rect[2],
                info.cursor_rect[3],
            },
        };
    }

    /// Synchronizes `win`'s input method state with the focused widget.
    pub fn syncTextInput(ui: *const WindowUi, win: anytype) void {
        window_mod.Window.from(win).setTextInput(ui.textInputState());
    }

    /// Something to wake the UI for a frame from another thread or task
    /// (it only marks it to be drawn if there are no fds left).
    pub fn waker(ui: *WindowUi) Waker {
        return ui.shared.waker();
    }

    /// What is read when a `Waker` wakes it (to wait on with the window's),
    /// once there is a waker.
    pub fn wakeSource(ui: *WindowUi) ?window_mod.Source {
        return ui.shared.wakeSource();
    }

    /// Takes the wakes since the last time; true if there were any.
    pub fn takeWakes(ui: *WindowUi) bool {
        return ui.shared.takeWakes();
    }

    /// Now, on the clock frames and input are timed on (`window.nowNs`).
    pub fn clockNs(ui: *const WindowUi) u64 {
        return window_mod.nowNs(ui.io);
    }

    /// The arena this frame's widgets are made in.
    pub fn arena(ui: *WindowUi) std.mem.Allocator {
        return ui.arenas[@intCast(ui.frame_no % 2)].allocator();
    }

    /// Builds, lays out and paints a frame with `root` (a widget's value)
    /// filling a `width` by `height` window.
    pub fn frame(ui: *WindowUi, width: u32, height: u32, now_ns: u64, root: anytype) void {
        ui.frame_no += 1;
        _ = ui.arenas[@intCast(ui.frame_no % 2)].reset(.retain_capacity);
        ui.now_ns = now_ns;
        ui.needs_frame = false;
        ui.checkHold();
        _ = ui.images.collect();
        const s = @max(ui.scale, 1);
        ui.damage.begin(ui.frame_no, width * s, height * s);
        var cx: Context = .{ .ui = ui, .arena = ui.arena() };
        const w = cx.make(root);
        if (ui.root) |r| if (r.widget.vtable != w.vtable or r.widget.key != w.key) {
            r.destroy();
            ui.root = null;
        };
        if (ui.root == null) ui.root = Node.create(ui, w);
        const r = ui.root orelse return;
        r.theme_ptr = null;
        r.build(w);
        const tb = ui.buildTitleBar();
        // The title-bar height is a constant; only the minimum width (and the
        // root's minimum size) need the expensive traversal, which we skip when
        // the tree structure has not changed since we last computed them.
        const overlay = ui.hasControlsOverlay();
        const tb_min_h: f32 = if (tb != null and !overlay) title_bar_mod.TitleBar.height else 0;
        if (ui.min_size_version != ui.build_version) {
            ui.cached_raw_min = r.minSize(.unbounded);
            ui.cached_tb_min = if (tb) |t| t.minSize(.unbounded) else .{};
            ui.min_size_version = ui.build_version;
        }
        // Always reapply the floor: it is set at window creation but may be
        // changed by the caller between frames (and in tests it often is).
        ui.min_size = .{
            @max(ui.min_size_floor[0], @as(u32, @intFromFloat(@ceil(@max(ui.cached_raw_min.w, ui.cached_tb_min.w, 1))))),
            @max(ui.min_size_floor[1], @as(u32, @intFromFloat(@ceil(@max(ui.cached_raw_min.h + tb_min_h, 1))))),
        };
        var w_px = width;
        var h_px = height;
        if (ui.win) |win| {
            ui.syncMinSize(win);
            if (!ui.fullscreen and !ui.maximized and !ui.tiled) {
                w_px = @max(w_px, ui.min_size[0]);
                h_px = @max(h_px, ui.min_size[1]);
            }
            ui.damage.resize(w_px * s, h_px * s);
        }
        if (ui.last_surface == null or !std.meta.eql(ui.last_surface.?, ui.theme.surface)) {
            ui.last_surface = ui.theme.surface;
            ui.damage.invalidate();
        }
        const window: Size = .{ .w = @floatFromInt(w_px), .h = @floatFromInt(h_px) };
        var tb_h: f32 = 0;
        if (tb) |t| if (!overlay) {
            const ts = t.layout(.{ .min_w = window.w, .max_w = window.w, .max_h = window.h });
            t.offset = .{ 0, 0 };
            tb_h = ts.h;
        };
        _ = r.layout(.tight(.{ .w = window.w, .h = @max(0, window.h - tb_h) }));
        r.offset = .{ 0, tb_h };
        // The window's buttons over the content, in the top right corner.
        ui.cutouts_len = 0;
        // What the window system draws over the content, if it does.
        if (!overlay) if (ui.win) |win| {
            ui.cutouts_len = win.cutouts(&ui.cutouts_buf).len;
        };
        if (tb) |t| if (overlay) {
            const ts = t.layout(.{ .max_w = window.w, .max_h = window.h });
            t.offset = .{ window.w - ts.w, 0 };
            if (ts.w > 0) {
                ui.cutouts_buf[0] = .{ .x = t.offset[0], .y = 0, .w = ts.w, .h = ts.h };
                ui.cutouts_len = 1;
            }
        };
        const m = ui.buildMenu(window);
        const d = ui.buildDrag(window);
        const tt = ui.buildTooltip(window);
        ui.syncPopups(m, tt);
        // If a modal dialog is open and focus is outside it, move focus to the
        // first focusable inside the dialog (or blur entirely if there is none).
        // This ensures "modal" is enforced: the background stays inert.
        if (ui.menu == null) if (focus_mod.scope(ui)) |dialog_scope| {
            const outside = if (ui.focused) |f| !focus_mod.within(f, dialog_scope) else false;
            if (outside) {
                if (focus_mod.first(dialog_scope)) |first| {
                    focus_mod.show(ui, first);
                } else {
                    ui.focus(null);
                }
            }
        };
        ui.paint(tb, r, d, m, tt, w_px, h_px);
        if (tb) |n| ui.damage.sweep(n);
        ui.damage.sweep(r);
        if (d) |n| ui.damage.sweep(n);
        if (m) |n| ui.damage.sweep(n);
        if (tt) |n| ui.damage.sweep(n);
        if (ui.pointer) |p| ui.updateHover(p);
        if (ui.win) |win| {
            ui.syncCursor(win);
            ui.syncTextInput(win);
        }
        if (ui.hold != null) ui.needs_frame = true;
        ui.images.evict(now_ns);
        if (ui.menu_focus_pending) if (ui.menu_root) |mr| if (focus_mod.first(mr)) |f| {
            ui.menu_focus_pending = false;
            focus_mod.show(ui, f);
        };
        if (ui.menu != null) if (ui.menu_root) |mr| menu_mod.Menu.focusPending(mr);
        ui.updateAccessibility();
    }

    /// Offers the UI to assistive technologies (screen readers) over
    /// AT-SPI, if the desktop has its bus (and `NO_AT_BRIDGE` is not set).
    /// Without it, nothing is offered; it can be tried again.
    pub fn enableAccessibility(ui: *WindowUi, environ: std.process.Environ) void {
        if (!has_atspi) return;
        if (ui.shared.a11y != null) return;
        if (envIs(environ, "NO_AT_BRIDGE", "1")) return;
        const title = if (ui.win) |w| w.title() else "";
        ui.shared.a11y = atspi.Bridge.connect(ui.gpa, ui.io, environ, title) catch null;
        ui.needs_frame = true;
    }

    /// The tree of the frame just made, offered (and what changed in it
    /// told), if it is offered at all.
    fn updateAccessibility(ui: *WindowUi) void {
        if (!has_atspi) return;
        const b = ui.shared.a11y orelse return;
        const root = ui.root orelse return;
        var extra: [3]*Node = undefined;
        var n: usize = 0;
        for ([_]?*Node{ ui.menu_root, ui.tooltip_root, ui.drag_root }) |r| if (r) |x| {
            extra[n] = x;
            n += 1;
        };
        const title = if (ui.win) |w| w.title() else "";
        const size: [2]f32 = .{ @floatFromInt(ui.logical_size[0]), @floatFromInt(ui.logical_size[1]) };
        const old = ui.a11y_tree;
        const tree = accessibility.build(ui.gpa, root, extra[0..n], title, size, ui.focused, ui.a11y_window_id, &ui.shared.a11y_next_id) catch {
            if (old) |t| {
                b.remove(t);
                t.deinit();
                ui.gpa.destroy(t);
                ui.a11y_tree = null;
            }
            return;
        };
        b.update(old, tree);
        ui.a11y_tree = tree;
        if (old) |t| {
            t.deinit();
            ui.gpa.destroy(t);
        }
    }

    /// Answers assistive technologies' calls; true if one did something
    /// (pressed a button), so a frame is needed.
    pub fn dispatchAccessibility(ui: *WindowUi) bool {
        if (!has_atspi) return false;
        const b = ui.shared.a11y orelse return false;
        const acted = b.dispatch();
        if (acted) ui.needs_frame = true;
        return acted;
    }

    fn buildTitleBar(ui: *WindowUi) ?*Node {
        if (!ui.hasToolkitTitleBar()) {
            if (ui.title_bar_root) |n| n.destroy();
            ui.title_bar_root = null;
            return null;
        }
        const title = if (ui.win) |w| w.title() else "";
        var cx: Context = .{ .ui = ui, .arena = ui.arena() };
        const w = if (ui.hasControlsOverlay()) cx.make(title_bar_mod.TitleBarControls{}) else cx.make(title_bar_mod.TitleBar{ .title = title });
        if (ui.title_bar_root) |tb| if (tb.widget.vtable != w.vtable) {
            tb.destroy();
            ui.title_bar_root = null;
        };
        if (ui.title_bar_root == null) ui.title_bar_root = Node.create(ui, w);
        const n = ui.title_bar_root orelse return null;
        n.theme_ptr = null;
        n.build(w);
        return n;
    }

    fn buildMenu(ui: *WindowUi, window: Size) ?*Node {
        ui.wanted_menu = null;
        const menu = ui.menu orelse {
            if (ui.menu_root) |n| n.destroy();
            ui.menu_root = null;
            return null;
        };
        // In the theme of the widget that opened it.
        var cx: Context = .{ .ui = ui, .arena = ui.arena(), .theme_ptr = menu.owner.theme_ptr };
        const w = switch (menu.content) {
            .items => |items| cx.make(menu_mod.Menu{ .items = items.list }),
            .popup => |popup| popup.f(popup.ctx, &cx),
        };
        if (ui.menu_root) |m| if (m.widget.vtable != w.vtable) {
            m.destroy();
            ui.menu_root = null;
        };
        if (ui.menu_root == null) ui.menu_root = Node.create(ui, w);
        const n = ui.menu_root orelse return null;
        n.theme_ptr = menu.owner.theme_ptr;
        n.build(w);
        ui.menu_window = window;
        const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
        // The menu itself where `place` puts it, with its submenus about it.
        var origin: Point = .{ 0, 0 };
        if (n.widget.as(menu_mod.Menu) != null) {
            const st = n.state(menu_mod.Menu.State);
            n.offset = st.offset;
            origin = st.origin;
        } else n.offset = menu_mod.place(window, menu.at, size);
        if (ui.usesPopups()) ui.wanted_menu = .{
            .kind = .menu,
            .anchor = .{ @intFromFloat(@round(menu.at[0] - origin[0])), @intFromFloat(@round(menu.at[1] - origin[1])), 1, 1 },
            .size = popupSize(size),
            .side = .below_right,
        };
        return n;
    }

    fn buildDrag(ui: *WindowUi, window: Size) ?*Node {
        const d = ui.drag orelse {
            if (ui.drag_root) |n| n.destroy();
            ui.drag_root = null;
            return null;
        };
        var cx: Context = .{ .ui = ui, .arena = ui.arena() };
        const w = cx.make(drag_mod.Chip{ .label = d.label, .icon = d.icon });
        if (ui.drag_root == null) ui.drag_root = Node.create(ui, w);
        const n = ui.drag_root orelse return null;
        n.theme_ptr = d.source.theme_ptr;
        n.build(w);
        const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
        n.offset = .{
            std.math.clamp(d.pos[0] + 12, 0, @max(0, window.w - size.w)),
            std.math.clamp(d.pos[1] + 16, 0, @max(0, window.h - size.h)),
        };
        return n;
    }

    fn buildTooltip(ui: *WindowUi, window: Size) ?*Node {
        ui.wanted_tooltip = null;
        if (ui.menu == null and ui.drag == null) {
            for (ui.hovered.items) |target| {
                if (target.laid_out != ui.frame_no) continue;
                const tt = target.widget.as(tooltip_mod.Tooltip) orelse continue;
                if (tt.text.len == 0) continue;
                var cx: Context = .{ .ui = ui, .arena = ui.arena() };
                const w = cx.make(tooltip_mod.Bubble{ .text = tt.text });
                if (ui.tooltip_root == null) ui.tooltip_root = Node.create(ui, w);
                const n = ui.tooltip_root orelse return null;
                n.theme_ptr = target.theme_ptr;
                n.build(w);
                const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
                const at = target.position();
                n.offset = tooltip_mod.place(window, .{ .x = at[0], .y = at[1], .w = target.size.w, .h = target.size.h }, size);
                if (ui.usesPopups()) ui.wanted_tooltip = .{
                    .kind = .tooltip,
                    .anchor = .{ @intFromFloat(@round(at[0])), @intFromFloat(@round(at[1])), @intFromFloat(@round(target.size.w)), @intFromFloat(@round(target.size.h)) },
                    .size = popupSize(size),
                    .side = .above,
                    .gap = tooltip_mod.gap,
                };
                return n;
            }
        }
        if (ui.tooltip_root) |n| n.destroy();
        ui.tooltip_root = null;
        return null;
    }

    fn paint(ui: *WindowUi, tb: ?*Node, r: *Node, drag: ?*Node, menu: ?*Node, tooltip: ?*Node, width: u32, height: u32) void {
        // Sweep the run cache once per logical frame.  Doing it here (rather
        // than inside paintOnce) means the retry pass on atlas-full does not
        // sweep again and evict runs that the first pass already marked `used`
        // but the second pass has not yet re-reached.
        ui.atlas.beginFrame();
        ui.paintOnce(tb, r, drag, menu, tooltip, width, height);
        // The glyph atlas filled part way through, so some text is missing
        // glyphs: painted again with it empty, so that the frame is whole.
        // (Otherwise the text would stay that way in this frame's buffer,
        // where nothing changed after, while the window's other buffers
        // show it whole: it would flicker as they take turns.)
        if (ui.atlas.full) ui.paintOnce(tb, r, drag, menu, tooltip, width, height);
    }

    fn paintOnce(ui: *WindowUi, tb: ?*Node, r: *Node, drag: ?*Node, menu: ?*Node, tooltip: ?*Node, width: u32, height: u32) void {
        ui.atlas.beginPass();
        ui.canvases_used = 0;
        ui.segments.clearRetainingCapacity();
        const s = @max(ui.scale, 1);
        ui.logical_size = .{ width, height };
        ui.frame_size = .{ width * s, height * s };
        ui.paint_order = 0;
        var p: Painter = .{ .ui = ui, .node = r };
        const overlay = ui.hasControlsOverlay();
        if (tb) |t| if (!overlay) p.paintNode(t);
        p.paintNode(r);
        if (tb) |t| if (overlay) p.paintNode(t);
        if (drag) |d| p.paintNode(d);
        if (menu) |m| if (ui.menu_popup == null) p.paintNode(m);
        if (tooltip) |tt| if (ui.tooltip_popup == null) p.paintNode(tt);
        ui.main_segments = ui.segments.items.len;
        if (menu) |m| if (ui.menu_popup) |*layer| ui.paintPopup(m, layer);
        if (tooltip) |tt| if (ui.tooltip_popup) |*layer| ui.paintPopup(tt, layer);
    }

    /// Whether menus and tooltips go in popups of their own.
    fn usesPopups(ui: *const WindowUi) bool {
        const w = ui.win orelse return false;
        return w.supportsPopups();
    }

    fn popupSize(size: Size) [2]u32 {
        return .{ @intFromFloat(@max(@ceil(size.w), 1)), @intFromFloat(@max(@ceil(size.h), 1)) };
    }

    /// Opens and closes the popups for the menu and tooltip built this
    /// frame (closing first, the newest first, as the window system
    /// requires), and puts the menu and tooltip where their popups are.
    fn syncPopups(ui: *WindowUi, menu: ?*Node, tooltip: ?*Node) void {
        const w = ui.win orelse return;
        const stale = struct {
            fn f(layer: ?PopupLayer, wanted: ?window_mod.PopupPlacement) bool {
                const l = layer orelse return false;
                const want = wanted orelse return true;
                return !l.placement.eql(want);
            }
        }.f;
        const menu_stale = stale(ui.menu_popup, ui.wanted_menu);
        if (stale(ui.tooltip_popup, ui.wanted_tooltip) or menu_stale) if (ui.tooltip_popup) |t| {
            t.popup.close();
            ui.tooltip_popup = null;
        };
        if (menu_stale) {
            ui.menu_popup.?.popup.close();
            ui.menu_popup = null;
        }
        if (ui.wanted_menu) |pl| if (ui.menu_popup == null) {
            if (w.openPopup(pl)) |popup| ui.menu_popup = .{ .popup = popup, .placement = pl };
        };
        if (ui.wanted_tooltip) |pl| if (ui.tooltip_popup == null) {
            if (w.openPopup(pl)) |popup| ui.tooltip_popup = .{ .popup = popup, .placement = pl };
        };
        // Where the window system put them (until it has, where they
        // would go in the window).
        if (menu) |n| if (ui.menu_popup) |l| if (l.popup.position()) |at| {
            n.offset = .{ @floatFromInt(at[0]), @floatFromInt(at[1]) };
        };
        if (tooltip) |n| if (ui.tooltip_popup) |l| if (l.popup.position()) |at| {
            n.offset = .{ @floatFromInt(at[0]), @floatFromInt(at[1]) };
        };
    }

    /// Paints a menu or tooltip on canvases of its own, its size, with its
    /// top left at the origin.
    fn paintPopup(ui: *WindowUi, n: *Node, layer: *PopupLayer) void {
        layer.first = ui.segments.items.len;
        _ = ui.newCanvasSized(layer.placement.size);
        var p: Painter = .{ .ui = ui, .node = n, .origin = .{ -n.offset[0], -n.offset[1] }, .track_damage = false };
        p.paintNode(n);
        layer.end = ui.segments.items.len;
        // What a 3D area draws is only known once it has: redraw it always.
        layer.hash = paintedHash(ui.segments.items[layer.first..layer.end]);
        if (layer.hash == null) layer.drawn_hash = null;
    }

    /// What `segments` paint, to tell whether a popup needs drawing again:
    /// null if it cannot be told (they hold GPU areas).
    pub fn paintedHash(segments: []const Segment) ?u64 {
        var h = std.hash.Wyhash.init(0);
        for (segments) |seg| switch (seg) {
            .canvas => |c| for (c.batches.items) |*b| {
                h.update(std.mem.asBytes(&b.kind));
                h.update(std.mem.sliceAsBytes(b.floats.items));
                if (b.clip) |r| h.update(std.mem.asBytes(&r)) else h.update("no clip");
                if (b.image) |img| {
                    // Known by its id: new pixels are a new image.
                    h.update(std.mem.asBytes(&img.id));
                    h.update(std.mem.asBytes(&[_]u32{ img.width, img.height }));
                }
            },
            .gpu => return null,
        };
        return h.final();
    }

    // --- Menus ------------------------------------------------------------------

    /// Opens a menu of `items` (copied) at `at`, for `owner`; any menu open is closed.
    pub fn openMenu(ui: *WindowUi, owner: *Node, at: Point, items: []const menu_mod.Item) void {
        ui.closeMenu();
        ui.focusMenuWhenMade();
        var copy_arena: std.heap.ArenaAllocator = .init(ui.gpa);
        const copy = menu_mod.cloneItems(copy_arena.allocator(), items) catch {
            copy_arena.deinit();
            return;
        };
        ui.menu = .{ .content = .{ .items = .{ .list = copy, .arena = copy_arena } }, .at = at, .owner = owner };
        ui.needs_frame = true;
    }

    /// Opens a popup made by `popup` at `at`, for `owner`; any menu open is closed.
    pub fn openPopup(ui: *WindowUi, owner: *Node, at: Point, popup: PopupBuilder) void {
        ui.closeMenu();
        ui.focusMenuWhenMade();
        ui.menu = .{ .content = .{ .popup = popup }, .at = at, .owner = owner };
        ui.needs_frame = true;
    }

    /// Closes the menu or popup, if one is open.
    pub fn closeMenu(ui: *WindowUi) void {
        const menu = ui.menu orelse return;
        switch (menu.content) {
            .items => |items| {
                var copy_arena = items.arena;
                copy_arena.deinit();
            },
            .popup => {},
        }
        ui.menu = null;
        ui.needs_frame = true;
        ui.menu_focus_pending = false;
        // The focus back where it was before the menu (if it is in it).
        if (ui.focus_before_menu) |n| {
            ui.focus_before_menu = null;
            const in_menu = if (ui.focused) |f| if (ui.menu_root) |m| focus_mod.within(f, m) else false else true;
            if (in_menu) ui.focus(n);
        }
    }

    /// A menu opened from the keyboard: it has the focus once it is made,
    /// and gives it back when it closes.
    fn focusMenuWhenMade(ui: *WindowUi) void {
        if (!ui.focus_visible) return;
        ui.menu_focus_pending = true;
        ui.focus_before_menu = ui.focused;
    }

    // --- Dragging -----------------------------------------------------------------

    /// Starts dragging `d`: it follows the pointer until `endDrag`.
    pub fn startDrag(ui: *WindowUi, d: drag_mod.Drag) void {
        ui.endDrag(false);
        var drag = d;
        drag.label = ui.gpa.dupe(u8, d.label) catch return;
        drag.target = null;
        ui.drag = drag;
        ui.moveDrag(d.pos);
    }

    /// Moves the drag to `pos`, finding what it is over.
    pub fn moveDrag(ui: *WindowUi, pos: Point) void {
        const d = &(ui.drag orelse return);
        d.pos = pos;
        ui.drag_scratch.clearRetainingCapacity();
        if (ui.root) |r| _ = r.hitTest(.{ pos[0] - r.offset[0], pos[1] - r.offset[1] }, &ui.drag_scratch);
        d.target = drag_mod.targetIn(ui.drag_scratch.items, d.data);
        ui.needs_frame = true;
    }

    /// Ends the drag; if `drop`, it is dropped on what it is over, if that takes it.
    pub fn endDrag(ui: *WindowUi, drop: bool) void {
        const d = ui.drag orelse return;
        ui.drag = null;
        ui.gpa.free(d.label);
        ui.needs_frame = true;
        if (!drop) return;
        const target = d.target orelse return;
        const t = target.widget.as(drag_mod.DropTarget) orelse return;
        if (t.on_drop) |f| f.call(d.data);
    }

    // --- Copy and paste -----------------------------------------------------------

    /// Copies `text` to the clipboard (the window's, or the app's own if there is none).
    pub fn copyText(ui: *WindowUi, text: []const u8) void {
        if (ui.clipboard) |c| return c.vtable.copy(c.ptr, text);
        if (ui.win) |w| if (w.hasClipboard()) return w.copy(text);
        ui.shared.local_clipboard.clearRetainingCapacity();
        ui.shared.local_clipboard.appendSlice(ui.gpa, text) catch {};
    }

    /// Asks for the clipboard's text, which is given to `on_text` (null if
    /// there is none) while `owner` is there.
    pub fn pasteText(ui: *WindowUi, owner: *Node, on_text: widget.ValueCallback([]const u8)) void {
        ui.paste = .{ .owner = owner, .on_text = on_text };
        if (ui.clipboard) |c| return c.vtable.paste(c.ptr, .{ .ctx = ui, .f = pasted });
        if (ui.win) |w| if (w.hasClipboard()) return w.paste(.{ .ctx = ui, .f = pasted });
        pasted(ui, if (ui.shared.local_clipboard.items.len > 0) ui.shared.local_clipboard.items else null);
    }

    fn pasted(ctx: *anyopaque, text: ?[]const u8) void {
        const ui: *WindowUi = @ptrCast(@alignCast(ctx));
        const p = ui.paste orelse return;
        ui.paste = null;
        if (text) |t| p.on_text.call(t);
        ui.needs_frame = true;
    }

    // --- Long presses ---------------------------------------------------------------

    pub const long_press_ns = 500 * std.time.ns_per_ms;
    pub const touch_slop = 8;

    fn checkHold(ui: *WindowUi) void {
        const h = &(ui.hold orelse return);
        const since = h.since orelse {
            h.since = ui.now_ns;
            return;
        };
        if (ui.now_ns -| since < long_press_ns) return;
        const n = h.node;
        const pos = h.pos;
        ui.hold = null;
        if (send(n, .{ .context = local(n, pos) })) {
            ui.captured = null;
            ui.swallow_release = true;
        }
    }

    /// The canvas the next 2D drawing goes on (a new one after a GPU draw).
    pub fn currentCanvas(ui: *WindowUi) *gfx.Canvas {
        if (ui.segments.items.len > 0) switch (ui.segments.items[ui.segments.items.len - 1]) {
            .canvas => |c| return c,
            .gpu => {},
        };
        return ui.newCanvas() orelse {
            if (ui.canvases.items.len > 0) return ui.canvases.items[0];
            return &scratch_canvas;
        };
    }

    var scratch_canvas: gfx.Canvas = .init(std.heap.page_allocator);

    fn newCanvas(ui: *WindowUi) ?*gfx.Canvas {
        return ui.newCanvasSized(ui.logical_size);
    }

    fn newCanvasSized(ui: *WindowUi, size: [2]u32) ?*gfx.Canvas {
        if (ui.canvases_used == ui.canvases.items.len) {
            const c = ui.gpa.create(gfx.Canvas) catch return null;
            c.* = .init(ui.gpa);
            ui.canvases.append(ui.gpa, c) catch {
                ui.gpa.destroy(c);
                return null;
            };
        }
        const c = ui.canvases.items[ui.canvases_used];
        c.beginScaled(size[0], size[1], @max(ui.scale, 1));
        ui.segments.append(ui.gpa, .{ .canvas = c }) catch return null;
        ui.canvases_used += 1;
        return c;
    }

    /// Adds a GPU draw to the frame, after what is drawn so far.
    pub fn addGpu(ui: *WindowUi, d: painter_mod.GpuDraw) void {
        ui.segments.append(ui.gpa, .{ .gpu = d }) catch {};
    }

    /// Whether anything on the screen changed in the last frame.
    pub fn changed(ui: *const WindowUi) bool {
        return !ui.damage.frame.isEmpty();
    }

    /// The parts of the screen that changed in the last frame.
    pub fn damaged(ui: *const WindowUi) []const geometry.Rect {
        return ui.damage.frame.slice();
    }

    /// `damaged`, as viewports in `out`.
    pub fn damagedViewports(ui: *const WindowUi, out: *[damage_mod.Region.max_rects]gfx.Viewport) []const gfx.Viewport {
        const rects = ui.damaged();
        for (rects, out[0..rects.len]) |r, *v| v.* = .{
            .x = @intFromFloat(r.x),
            .y = @intFromFloat(r.y),
            .width = @intFromFloat(r.w),
            .height = @intFromFloat(r.h),
        };
        return out[0..rects.len];
    }

    /// The parts that have to be drawn for a buffer last drawn `age` frames ago.
    pub fn repaint(ui: *const WindowUi, age: u32) damage_mod.Region {
        return ui.damage.repaint(age);
    }

    /// `region`'s parts, as viewports in `out`.
    pub fn regionViewports(region: *const damage_mod.Region, out: *[damage_mod.Region.max_rects]gfx.Viewport) []const gfx.Viewport {
        for (region.slice(), out[0..region.len]) |r, *v| v.* = .{
            .x = @intFromFloat(r.x),
            .y = @intFromFloat(r.y),
            .width = @intFromFloat(r.w),
            .height = @intFromFloat(r.h),
        };
        return out[0..region.len];
    }

    /// Renders the last painted frame through `ui.shared.renderer` into `target`.
    /// `target` is a pointer to the renderer's target type (`*gfx.software.Image`
    /// for the software renderer); another type is `error.WrongTarget`.
    pub fn render(ui: *WindowUi, target: anytype, damage: ?[]const gfx.Viewport) !void {
        const r = ui.shared.renderer orelse return error.NoRenderer;
        try r.renderSegments(ui.canvases.items[0..ui.canvases_used], ui.segments.items[0..ui.main_segments], target, damage);
    }

    /// Draws the last painted frame into `img` on the CPU using `gfx.software`.
    pub fn preview(ui: *WindowUi, img: gfx.software.Image) !void {
        var mutable_img = img;
        for (ui.segments.items) |s| switch (s) {
            .canvas => |c| try gfx.software.render(c, mutable_img),
            .gpu => |g| try g.f(g.ctx, @ptrCast(&mutable_img), g.area),
        };
    }

    /// The frame last painted, to present over `clear` (ARGB): the window's
    /// segments, and what changed in it (see `gfx.Frame`). It is good until
    /// the next `frame`.
    pub fn framePacket(ui: *const WindowUi, clear: u32) gfx.Frame {
        var f: gfx.Frame = .{
            .canvases = ui.canvases.items[0..ui.canvases_used],
            .segments = ui.segments.items[0..ui.main_segments],
            .clear = clear,
            .damage = damageOf(&ui.damage.frame),
        };
        comptime std.debug.assert(damage_mod.Tracker.history_len + 1 <= gfx.Frame.max_ages);
        comptime std.debug.assert(damage_mod.Region.max_rects <= gfx.frame.Damage.max_rects);
        f.ages = @intCast(ui.damage.known + 1);
        for (f.repaints[0 .. @as(usize, f.ages) + 1], 0..) |*r, age| r.* = damageOf(&ui.damage.repaint(@intCast(age)));
        return f;
    }

    fn damageOf(region: *const damage_mod.Region) gfx.frame.Damage {
        var out: [damage_mod.Region.max_rects]gfx.Viewport = undefined;
        var d: gfx.frame.Damage = .{};
        for (regionViewports(region, &out)) |v| d.add(v);
        return d;
    }

    /// If the last `frame` changed anything, renders only the damaged parts
    /// into `win` (a `window.Window`, or a pointer to a window) and presents it.
    pub fn present(ui: *WindowUi, win: anytype, clear: u32) !bool {
        const w = window_mod.Window.from(win);
        const popups = try ui.presentPopups();
        if (!ui.changed()) return popups;
        const f = ui.framePacket(clear);
        try ui.presenter.present(w, &f);
        return true;
    }

    /// Draws the menu and tooltip popups (whole: they are small).
    fn presentPopups(ui: *WindowUi) !bool {
        var shown = false;
        for ([_]*?PopupLayer{ &ui.menu_popup, &ui.tooltip_popup }) |slot| {
            const layer = &(slot.* orelse continue);
            if (layer.end <= layer.first or (layer.hash != null and layer.drawn_hash == layer.hash)) continue;
            const segments = ui.segments.items[layer.first..layer.end];
            var canvases: [16]*const gfx.Canvas = undefined;
            var n: usize = 0;
            for (segments) |s| switch (s) {
                .canvas => |c| if (n < canvases.len) {
                    canvases[n] = c;
                    n += 1;
                },
                .gpu => {},
            };
            const f: gfx.Frame = .{ .canvases = canvases[0..n], .segments = segments, .clear = 0 };
            if (!try ui.presenter.presentPopup(layer.popup, &f)) {
                ui.needs_frame = true;
                continue;
            }
            layer.drawn_hash = layer.hash;
            shown = true;
        }
        return shown;
    }

    // --- Input ------------------------------------------------------------------

    /// Handles an input event from the window.
    pub fn handleInput(ui: *WindowUi, e: window_mod.InputEvent) void {
        ui.inputs +%= 1;
        switch (e) {
            .motion => |pos| ui.pointerMotion(pos),
            .button => |b| ui.pointerButton(b.pos, b.button, b.pressed),
            .scroll => |s| ui.pointerScroll(s.pos, s.dx, s.dy),
            .key => |k| if (ui.loaded_keymap != null)
                ui.keyEvent(k.key, k.pressed)
            else
                ui.key(.{ .key = k.key, .pressed = k.pressed, .char = k.char, .shift = k.shift, .ctrl = k.ctrl }),
            .leave => ui.pointerLeave(),
            .touch_down => |t| ui.touchDown(t.id, t.pos),
            .touch_motion => |t| ui.touchMotion(t.id, t.pos),
            .touch_up => |id| ui.touchUp(id),
            .touch_cancel => ui.touchCancel(),
            .relative_motion, .pointer_locked => {},
            .text_commit => |*c| if (ui.focused) |n| {
                _ = send(n, .{ .text_commit = c.slice() });
                ui.needs_frame = true;
            },
            .text_preedit => |*p| if (ui.focused) |n| {
                _ = send(n, .{ .text_preedit = .{ .text = p.slice(), .cursor_begin = p.cursor_begin, .cursor_end = p.cursor_end } });
                ui.needs_frame = true;
            },
            .text_delete_surrounding => |d| if (ui.focused) |n| {
                _ = send(n, .{ .text_delete_surrounding = .{ .before_length = d.before_length, .after_length = d.after_length } });
                ui.needs_frame = true;
            },
            .drag_enter, .drag_motion, .drop => |pos| {
                ui.pointer = pos;
                ui.updateHover(pos);
            },
            .drag_leave => ui.pointerLeave(),
            .popup_done => |id| {
                // The window system closed it: a menu goes; a tooltip
                // comes back next frame if it is still wanted.
                if (ui.menu_popup) |m| if (m.popup.id == id) {
                    if (ui.tooltip_popup) |t| {
                        t.popup.close();
                        ui.tooltip_popup = null;
                    }
                    m.popup.close();
                    ui.menu_popup = null;
                    ui.closeMenu();
                };
                if (ui.tooltip_popup) |t| if (t.popup.id == id) {
                    t.popup.close();
                    ui.tooltip_popup = null;
                    ui.needs_frame = true;
                };
            },
        }
    }

    /// Takes the input from `win` (a `Window`, or a pointer to a window) and handles it.
    pub fn takeInput(ui: *WindowUi, win: anytype) void {
        const w = window_mod.Window.from(win);
        ui.syncWindow(w);
        for (w.takeInput()) |e| ui.handleInput(e);
        ui.syncCursor(w);
    }

    /// The pointer moved to `pos` (in the window).
    pub fn pointerMotion(ui: *WindowUi, pos: Point) void {
        ui.pointer = pos;
        ui.updateHover(pos);
        var i: usize = 0;
        while (i < ui.hovered.items.len) {
            const n = ui.hovered.items[i];
            if (send(n, .{ .motion = local(n, pos) })) {
                ui.needs_frame = true;
            }
            if (i < ui.hovered.items.len and ui.hovered.items[i] == n) i += 1;
        }
        if (ui.captured) |n| if (std.mem.indexOfScalar(*Node, ui.hovered.items, n) == null) {
            if (send(n, .{ .motion = local(n, pos) })) ui.needs_frame = true;
        };
        if (ui.win) |win| ui.syncCursor(win);
    }

    /// Presses this close together, in time and space, are one double
    /// click (or a triple click, or more).
    pub const multi_click_ns = 400 * std.time.ns_per_ms;
    pub const multi_click_slop = 6;

    /// A pointer button went down or up at `pos`.
    pub fn pointerButton(ui: *WindowUi, pos: Point, button: widget.PointerButton, pressed: bool) void {
        ui.pointerButtonAt(pos, button, pressed, ui.clockNs());
    }

    /// `pointerButton`, at a time on the monotonic clock (`window.nowNs`).
    pub fn pointerButtonAt(ui: *WindowUi, pos: Point, button: widget.PointerButton, pressed: bool, now_ns: u64) void {
        ui.pointer = pos;
        ui.updateHover(pos);
        ui.needs_frame = true;
        defer if (ui.win) |win| ui.syncCursor(win);
        if (pressed) {
            // The pointer's: the focus ring goes.
            ui.focus_visible = false;
            if (ui.captured != null) return;
            if (ui.menu != null and !ui.overMenu()) {
                ui.closeMenu();
                return;
            }
            const clicks: u8 = if (ui.last_press) |last| if (last.button == button and
                now_ns -| last.ns <= multi_click_ns and
                @abs(pos[0] - last.pos[0]) <= multi_click_slop and
                @abs(pos[1] - last.pos[1]) <= multi_click_slop) last.clicks +| 1 else 1 else 1;
            ui.last_press = .{ .ns = now_ns, .pos = pos, .button = button, .clicks = clicks };
            if (ui.focused) |f| if (std.mem.indexOfScalar(*Node, ui.hovered.items, f) == null) ui.focus(null);
            if (button == .right) {
                var i: usize = 0;
                while (i < ui.hovered.items.len) {
                    const n = ui.hovered.items[i];
                    if (send(n, .{ .context = local(n, pos) })) return;
                    if (i < ui.hovered.items.len and ui.hovered.items[i] == n) i += 1;
                }
            }
            var i: usize = 0;
            while (i < ui.hovered.items.len) {
                const n = ui.hovered.items[i];
                if (send(n, .{ .press = .{ .pos = local(n, pos), .button = button, .clicks = clicks } })) {
                    if (std.mem.indexOfScalar(*Node, ui.hovered.items, n) != null) {
                        ui.captured = n;
                        ui.captured_button = button;
                    }
                    return;
                }
                if (i < ui.hovered.items.len and ui.hovered.items[i] == n) i += 1;
            }
        } else if (ui.swallow_release) {
            ui.swallow_release = false;
            ui.hold = null;
        } else if (ui.captured) |n| {
            if (button != ui.captured_button) return;
            ui.hold = null;
            ui.captured = null;
            const inside = std.mem.indexOfScalar(*Node, ui.hovered.items, n) != null;
            _ = send(n, .{ .release = .{ .pos = local(n, pos), .button = button, .inside = inside } });
        }
    }

    // --- Touch ----------------------------------------------------------------------

    /// A touch went down at `pos`; one at a time is followed, and acts as the left button.
    pub fn touchDown(ui: *WindowUi, id: i32, pos: Point) void {
        if (ui.touch != null) return;
        ui.touch = .{ .id = id, .start = pos, .last = pos };
        ui.pointerButton(pos, .left, true);
        if (ui.captured) |n| ui.hold = .{ .node = n, .pos = pos };
    }

    /// The touch `id` moved to `pos`.
    pub fn touchMotion(ui: *WindowUi, id: i32, pos: Point) void {
        const t = &(ui.touch orelse return);
        if (t.id != id) return;
        if (ui.swallow_release) return;
        if (!t.moved and @abs(pos[0] - t.start[0]) <= touch_slop and @abs(pos[1] - t.start[1]) <= touch_slop) return;
        const first = !t.moved;
        t.moved = true;
        ui.hold = null;
        const dx = t.last[0] - pos[0];
        const dy = t.last[1] - pos[1];
        t.last = pos;
        if (t.panning) {
            _ = ui.pan(t.start, dx, dy);
            return;
        }
        if (first and ui.pan(t.start, dx, dy)) {
            t.panning = true;
            ui.cancelPress();
            return;
        }
        ui.pointerMotion(pos);
    }

    /// The touch `id` came up.
    pub fn touchUp(ui: *WindowUi, id: i32) void {
        const t = ui.touch orelse return;
        if (t.id != id) return;
        if (!t.panning) ui.pointerButton(t.last, .left, false);
        ui.touch = null;
        ui.hold = null;
        ui.swallow_release = false;
        ui.pointerLeave();
    }

    /// The touches were cancelled.
    pub fn touchCancel(ui: *WindowUi) void {
        ui.cancelPress();
        ui.touch = null;
        ui.hold = null;
        ui.swallow_release = false;
        ui.pointerLeave();
    }

    fn pan(ui: *WindowUi, at: Point, dx: f32, dy: f32) bool {
        ui.updateHover(at);
        var i: usize = 0;
        while (i < ui.hovered.items.len) {
            const n = ui.hovered.items[i];
            if (send(n, .{ .scroll = .{ .pos = local(n, at), .dx = dx, .dy = dy, .touch = true } })) {
                ui.needs_frame = true;
                return true;
            }
            if (i < ui.hovered.items.len and ui.hovered.items[i] == n) i += 1;
        }
        return false;
    }

    fn cancelPress(ui: *WindowUi) void {
        const n = ui.captured orelse return;
        ui.captured = null;
        _ = send(n, .{ .release = .{ .pos = .{ -1, -1 }, .button = ui.captured_button, .inside = false } });
        ui.needs_frame = true;
    }

    /// The wheel turned at `pos`: by `dy` pixels down and `dx` right.
    pub fn pointerScroll(ui: *WindowUi, pos: Point, dx: f32, dy: f32) void {
        ui.pointer = pos;
        ui.updateHover(pos);
        var i: usize = 0;
        while (i < ui.hovered.items.len) {
            const n = ui.hovered.items[i];
            if (send(n, .{ .scroll = .{ .pos = local(n, pos), .dx = dx, .dy = dy } })) {
                ui.needs_frame = true;
                return;
            }
            if (i < ui.hovered.items.len and ui.hovered.items[i] == n) i += 1;
        }
    }

    /// Gives the keyboard focus to `n` (or to none), telling the nodes losing and gaining it.
    pub fn focus(ui: *WindowUi, n: ?*Node) void {
        if (ui.focused == n) return;
        if (ui.focused) |old| _ = send(old, .blur);
        ui.focused = n;
        if (n) |new| _ = send(new, .focus);
        ui.needs_frame = true;
    }

    /// Gives it a keymap of its own (XKB's text format), for keys from
    /// `keyEvent`: what they type, and the modifiers they change. (Keys from
    /// a window with a keymap come with what they type.)
    pub fn loadKeymap(ui: *WindowUi, text: []const u8) !void {
        var km = try window_mod.xkb.Keymap.parse(ui.gpa, text);
        if (ui.loaded_keymap) |*old| old.deinit();
        ui.loaded_keymap = km;
        ui.key_state = .{};
        ui.keyboard = .init(km.layoutName(.{}), km.layoutCode(.{}));
    }

    /// A key went down or up: what it types, by `loaded_keymap` if it has
    /// one.
    pub fn keyEvent(ui: *WindowUi, which: widget.KeyboardKey, pressed: bool) void {
        const km = &(ui.loaded_keymap orelse return ui.key(.{ .key = which, .pressed = pressed }));
        // A key the keymap has no code for types nothing.
        const code = window_mod.evdev.codeOf(which) orelse return ui.key(.{ .key = which, .pressed = pressed });
        const mods = ui.key_state.mods();
        const char = if (pressed) km.char(code, ui.key_state) else null;
        km.update(&ui.key_state, code, pressed);
        ui.key(.{
            .key = which,
            .pressed = pressed,
            .char = char,
            .shift = mods & window_mod.xkb.shift_mask != 0,
            .ctrl = mods & window_mod.xkb.control_mask != 0,
        });
    }

    /// A key went down or up, with what it types (if anything) and the
    /// modifiers held.
    pub fn key(ui: *WindowUi, k: widget.Event.Key) void {
        switch (k.key) {
            // Modifiers only change what other keys do.
            .left_shift, .right_shift, .left_ctrl, .right_ctrl, .right_alt => return,
            .escape => if (k.pressed and ui.menu != null) {
                ui.closeMenu();
                return;
            },
            else => {},
        }
        ui.needs_frame = true;
        // Tab moves the focus (Control and Tab, from what takes Tab).
        if (k.key == .tab) {
            const takes_tab = if (ui.focused) |f| f.widget.vtable.takes_tab else false;
            if (k.ctrl or !takes_tab) {
                if (k.pressed) _ = focus_mod.move(ui, !k.shift);
                return;
            }
        }
        var e = k;
        // Control and a key is a shortcut, not typing.
        if (!k.pressed or k.ctrl) e.char = null;
        // To what has the focus, then what that is in, until one takes it.
        // If a modal dialog is open, only deliver to widgets inside its scope.
        const modal_scope: ?*Node = if (ui.menu == null) focus_mod.scope(ui) else null;
        var at = ui.focused;
        while (at) |n| : (at = n.parent) {
            if (modal_scope) |s| if (!focus_mod.within(n, s)) break;
            if (send(n, .{ .key = e })) return;
        }
        if (!k.pressed) return;
        switch (k.key) {
            // Escape dismisses the dialog in front.
            .escape => if (ui.root) |r| if (focus_mod.topDialog(r)) |d| {
                if (d.widget.as(@import("dialog.zig").Dialog).?.on_dismiss) |f| f.call();
            },
            // Up and down move through a menu.
            .up, .down => if (ui.menu != null) {
                _ = focus_mod.move(ui, k.key == .down);
            },
            else => {},
        }
    }

    /// The pointer left the window.
    pub fn pointerLeave(ui: *WindowUi) void {
        ui.cancelPress();
        ui.hold = null;
        ui.swallow_release = false;
        ui.pointer = null;
        var i: usize = 0;
        while (i < ui.hovered.items.len) {
            const n = ui.hovered.items[i];
            _ = send(n, .leave);
            if (i < ui.hovered.items.len and ui.hovered.items[i] == n) i += 1;
        }
        ui.hovered.clearRetainingCapacity();
        if (ui.win) |win| ui.syncCursor(win);
        ui.needs_frame = true;
    }

    fn updateHover(ui: *WindowUi, pos: Point) void {
        ui.hover_scratch.clearRetainingCapacity();
        if (ui.menu != null) {
            if (ui.menu_root) |m| _ = m.hitTest(.{ pos[0] - m.offset[0], pos[1] - m.offset[1] }, &ui.hover_scratch);
        } else {
            var hit = false;
            if (ui.title_bar_root) |tb| {
                hit = tb.hitTest(.{ pos[0] - tb.offset[0], pos[1] - tb.offset[1] }, &ui.hover_scratch);
            }
            if (!hit) {
                if (ui.root) |r| _ = r.hitTest(.{ pos[0] - r.offset[0], pos[1] - r.offset[1] }, &ui.hover_scratch);
            }
        }
        var i: usize = 0;
        while (i < ui.hovered.items.len) {
            const n = ui.hovered.items[i];
            if (std.mem.indexOfScalar(*Node, ui.hover_scratch.items, n) == null) {
                _ = send(n, .leave);
                ui.needs_frame = true;
            }
            if (i < ui.hovered.items.len and ui.hovered.items[i] == n) i += 1;
        }
        i = 0;
        while (i < ui.hover_scratch.items.len) {
            const n = ui.hover_scratch.items[i];
            if (std.mem.indexOfScalar(*Node, ui.hovered.items, n) == null) {
                _ = send(n, .enter);
                ui.needs_frame = true;
            }
            if (i < ui.hover_scratch.items.len and ui.hover_scratch.items[i] == n) i += 1;
        }
        std.mem.swap(std.ArrayList(*Node), &ui.hovered, &ui.hover_scratch);
    }

    fn send(n: *Node, e: Event) bool {
        const f = n.widget.vtable.event orelse return false;
        return f(n.widget.ptr, n, e);
    }

    fn local(n: *const Node, pos: Point) Point {
        const at = n.position();
        return .{ pos[0] - at[0], pos[1] - at[1] };
    }

    fn overMenu(ui: *const WindowUi) bool {
        const m = ui.menu_root orelse return false;
        const pos = ui.pointer orelse return false;
        return menu_mod.Menu.contains(m, pos);
    }

    /// Drops what refers to `n`, which is going: a menu it opened, a drag from it, a paste for it.
    pub fn forget(ui: *WindowUi, n: *Node) void {
        if (ui.menu) |m| if (m.owner == n) ui.closeMenu();
        if (ui.drag) |*d| {
            if (d.source == n) ui.endDrag(false) else if (d.target == n) d.target = null;
        }
        if (ui.paste) |p| if (p.owner == n) {
            ui.paste = null;
        };
        if (ui.hold) |h| if (h.node == n) {
            ui.hold = null;
        };
        if (ui.captured == n) ui.captured = null;
        if (ui.focused == n) ui.focused = null;
        if (ui.focus_before_menu == n) ui.focus_before_menu = null;
        if (std.mem.indexOfScalar(*Node, ui.hovered.items, n)) |i| _ = ui.hovered.orderedRemove(i);
        if (std.mem.indexOfScalar(*Node, ui.hover_scratch.items, n)) |i| _ = ui.hover_scratch.orderedRemove(i);
    }
};

/// Whether environment variable `key` is `value` (both ASCII).
fn envIs(environ: std.process.Environ, comptime key: []const u8, comptime value: []const u8) bool {
    if (builtin.os.tag == .windows) {
        const v = environ.getWindows(std.unicode.utf8ToUtf16LeStringLiteral(key)) orelse return false;
        if (v.len != value.len) return false;
        for (v, value) |a, b| if (a != b) return false;
        return true;
    }
    const v = environ.getPosix(key) orelse return false;
    return std.mem.eql(u8, v, value);
}

/// A native toolkit app: its windows (the system's own, opened on a
/// `window.NativeDisplay`, unless it is given a display), each with its
/// `WindowControls` and a `WindowUi`, and what they share (`SharedResources`: the font, the
/// renderer, the theme). The app runs them in a loop of its own:
///
///     const app = try App.init(gpa, io, environ, .{ .on_quit_request = .quit, .on_last_window_closed = .quit });
///     defer app.deinit();
///     var root: Root = .{ .state = &state };
///     _ = try app.openWindow(.{ .title = "Hello", .root = .of(&root), .on_close_request = .close });
///     try app.run();
///
/// Each window draws its root widget (`Root.of`) whenever something in it
/// changed: input, a `Waker`, a widget's animation. Input in one window
/// redraws the others too (it may have changed what they show).
///
/// What the system asks (to close a window, to quit) is done as its
/// options say: by default nothing is, and it is the app's own to do
/// (with `Window.close` and `quit`). Callbacks are called on the app's
/// thread, in `step`.
///
/// It does its I/O, waits, and tells the time through the `std.Io` it is
/// given (the app's, as from `std.process.Init`), so other tasks on it go
/// on while `step` waits: a fetch started with `io.async`, which wakes
/// the UI (`SharedResources.waker`) when it is done.
pub const App = struct {
    /// What the app allocates with.
    gpa: std.mem.Allocator,
    /// What does the app's I/O and tells the time.
    io: std.Io,
    /// The process's environment.
    environ: std.process.Environ,
    /// The connection to the window system, which its windows are opened on.
    display: window_mod.Display,
    /// Whether `deinit` closes `display` (it was opened by `init`).
    owns_display: bool = false,
    /// What its windows share.
    shared: *SharedResources,
    /// Its windows, open and closed (until destroyed).
    windows: std.ArrayList(*Window) = .empty,
    /// How many of them are open.
    open_windows: usize = 0,
    /// Whether the last open one was closed since `step` last saw.
    last_window_closed: bool = false,
    /// The name the window system knows the app by (the first window's `app_id`).
    app_id: ?[]const u8 = null,
    /// What is done when the system asks the app to quit.
    on_quit_request: OnQuitRequest = .ignore,
    /// What is done when the last open window is closed.
    on_last_window_closed: OnLastWindowClosed = .ignore,
    /// `quit` was called: `step` returns false.
    quitting: bool = false,
    /// The theme the app is set to (from the system, or `setTheme`).
    theme: theme_mod.ThemeMode = .dark,
    /// The system's appearance (dark or not) when last seen, for windows
    /// that say (macOS): the theme follows it when it changes.
    system_dark: ?bool = null,
    /// Whether the display waits on the image loader.
    watching_images: bool = false,
    /// Whether the display waits on the `Waker`s.
    watching_wake: bool = false,
    /// Whether the display waits on the accessibility bus.
    watching_a11y: bool = false,
    /// Inside `step`: destroyed windows are swept when `step` finishes.
    stepping: bool = false,
    /// Each frame's timings written to stderr (`KETE_TRACE=1`).
    trace: bool = false,

    /// What is done when the system asks the app to quit (macOS's Quit,
    /// ⌘Q): nothing, `quit`, or a callback.
    pub const OnQuitRequest = union(enum) {
        ignore,
        quit,
        call: widget.Callback,
    };
    /// What is done when the last open window is closed: nothing (the app
    /// goes on, with no windows), `quit`, or a callback.
    pub const OnLastWindowClosed = union(enum) {
        ignore,
        quit,
        call: widget.Callback,
    };
    /// What is done when a window is asked to close (its close button):
    /// nothing, `Window.close`, or a callback given the window.
    pub const OnCloseRequest = union(enum) {
        ignore,
        close,
        call: widget.ValueCallback(*Window),
    };

    /// The root widget a window draws (a pointer to it, which must last as
    /// long as the window, or until another is given with `setRoot`):
    /// `.of(&root)`. Its fields can be changed in place; the window is
    /// redrawn when something changes (see `App`).
    pub const Root = struct {
        ptr: *const anyopaque,
        frame: *const fn (ptr: *const anyopaque, ui: *WindowUi, width: u32, height: u32, now_ns: u64) void,

        pub fn of(root: anytype) Root {
            const T = @typeInfo(@TypeOf(root)).pointer.child;
            return .{ .ptr = @ptrCast(root), .frame = struct {
                fn frame(p: *const anyopaque, ui: *WindowUi, width: u32, height: u32, now_ns: u64) void {
                    const r: *const T = @ptrCast(@alignCast(p));
                    ui.frame(width, height, now_ns, r.*);
                }
            }.frame };
        }
    };

    pub const Options = struct {
        /// What the system knows the app by (Wayland's app id), for its
        /// windows.
        app_id: ?[]const u8 = null,
        /// The OpenType or TrueType font text is drawn in (the file's
        /// bytes, which must outlive the app); the bundled Fira Sans if
        /// null.
        font_data: ?[]const u8 = null,
        /// What its windows are on (a custom backend's, or
        /// `window.Display.single` for a custom backend's one window),
        /// which stays the caller's to close after the app; the system's
        /// own (a `window.NativeDisplay`) if null.
        display: ?window_mod.Display = null,
        on_quit_request: OnQuitRequest = .ignore,
        on_last_window_closed: OnLastWindowClosed = .ignore,
    };

    /// How a window opened by `openWindow` starts out.
    pub const WindowOptions = struct {
        title: []const u8,
        /// What it draws.
        root: Root,
        size: [2]u32 = .{ 1280, 720 },
        min_size: ?[2]u32 = null,
        maximized: bool = false,
        /// Whether what it draws goes under its title bar, the way the
        /// system's own controls (close, minimize, maximize) are drawn over
        /// it: where they are is in `Window.cutouts`, and `WindowDragArea`
        /// marks what moves the window. Where the window system draws the
        /// title bar (and will not leave it), it is not under it.
        draw_in_title_bar: bool = false,
        /// What is under it all (ARGB); the theme's surface colour if null.
        clear_color: ?u32 = null,
        /// A window it belongs to (a dialog's, a tool window's): it stays
        /// above it.
        parent: ?*Window = null,
        on_close_request: OnCloseRequest = .ignore,
    };

    /// How a window added by `addWindow` is used.
    pub const AddOptions = struct {
        /// What it draws.
        root: Root,
        min_size: ?[2]u32 = null,
        /// As `WindowOptions.draw_in_title_bar` says (the window is already
        /// open, so a backend's own asks for it when it is).
        draw_in_title_bar: bool = false,
        clear_color: ?u32 = null,
        on_close_request: OnCloseRequest = .ignore,
    };

    /// Makes an app with no windows yet (opened by `openWindow`): on the
    /// system's display (connecting to the Wayland compositor in
    /// `environ`, on Linux; AppKit, on macOS), unless `options` gives one.
    /// It does its I/O through `io`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !*App {
        const owns_display = options.display == null;
        const display: window_mod.Display = options.display orelse .of(try window_mod.NativeDisplay.open(gpa, io, environ));
        errdefer if (owns_display) display.close();
        const shared = if (options.font_data) |data| try SharedResources.createWithFontData(gpa, io, data) else try SharedResources.createDefault(gpa, io);
        errdefer shared.destroy();
        const a = try gpa.create(App);
        a.* = .{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .display = display,
            .owns_display = owns_display,
            .shared = shared,
            .app_id = options.app_id,
            .on_quit_request = options.on_quit_request,
            .on_last_window_closed = options.on_last_window_closed,
            .trace = envIs(environ, "KETE_TRACE", "1"),
        };
        return a;
    }

    /// Something to wake the app's windows for a frame from another thread or
    /// task (see `Waker`).
    pub fn waker(a: *App) Waker {
        return a.shared.waker();
    }

    /// Closes its windows (and frees their handles), and lets it go.
    pub fn deinit(a: *App) void {
        for (a.windows.items) |w| {
            w.close();
            a.gpa.destroy(w);
        }
        a.windows.deinit(a.gpa);
        if (a.watching_images) if (a.shared.images.waitSource()) |src| a.display.watch(src, false);
        if (a.watching_wake) if (a.shared.wakeSource()) |src| a.display.watch(src, false);
        if (has_atspi and a.watching_a11y) if (a.shared.a11y) |b| a.display.watch(b.source(), false);
        a.shared.destroy();
        if (a.owns_display) a.display.close();
        a.gpa.destroy(a);
    }

    /// Opens a window of the display's, as `options` says.
    pub fn openWindow(a: *App, options: WindowOptions) !*Window {
        const parent: ?window_mod.Window = if (options.parent) |p| (if (p.closed) return error.ParentClosed else p.win) else null;
        const win = try a.display.openWindow(.{
            .title = options.title,
            .app_id = a.app_id,
            .size = options.size,
            .min_size = options.min_size,
            .maximized = options.maximized,
            .draw_in_title_bar = options.draw_in_title_bar,
            .parent = parent,
        });
        errdefer win.close();
        const w = try a.adopt(win, .{ .root = options.root, .min_size = options.min_size, .draw_in_title_bar = options.draw_in_title_bar, .clear_color = options.clear_color, .on_close_request = options.on_close_request });
        w.owns_window = true;
        w.ui.enableAccessibility(a.environ);
        return w;
    }

    /// Adds `win` (a custom backend's window: a `window.Window`, or a
    /// pointer to a window `Window.of` takes), which is already open and
    /// stays the caller's to close after the app's window is closed.
    pub fn addWindow(a: *App, win: anytype, options: AddOptions) !*Window {
        return a.adopt(window_mod.Window.from(win), options);
    }

    fn adopt(a: *App, win: window_mod.Window, options: AddOptions) !*Window {
        try a.windows.ensureUnusedCapacity(a.gpa, 1);
        const ui = try a.shared.createWindowUi();
        errdefer ui.destroy();
        const w = try a.gpa.create(Window);
        w.* = .{
            .app = a,
            .win = win,
            .controls = .init(win),
            .ui = ui,
            .root = options.root,
            .clear_color = options.clear_color,
            .on_close_request = options.on_close_request,
        };
        a.windows.appendAssumeCapacity(w);
        a.open_windows += 1;
        if (a.followSystem()) a.applyTheme();
        ui.theme = a.theme.scheme();
        ui.min_size_floor = options.min_size orelse .{ 0, 0 };
        ui.content_in_title_bar = options.draw_in_title_bar;
        ui.attachWindow(win, &w.controls);
        ui.app_window = w;
        win.setRedraw(.{ .ctx = w, .f = Window.redraw });
        return w;
    }

    /// Makes `step` return false (from its next return on): the app
    /// should end.
    pub fn quit(a: *App) void {
        a.quitting = true;
    }

    /// Takes the system's appearance, if a window says what it is and it
    /// has changed since last seen; true if it had.
    fn followSystem(a: *App) bool {
        const dark = for (a.windows.items) |w| {
            if (w.closed) continue;
            if (w.win.prefersDark()) |d| break d;
        } else return false;
        if (a.system_dark == dark) return false;
        a.system_dark = dark;
        a.theme = if (dark) .dark else .light;
        return true;
    }

    /// Gives every window's UI the app's theme, and redraws them.
    fn applyTheme(a: *App) void {
        for (a.windows.items) |w| if (!w.closed) {
            w.ui.theme = a.theme.scheme();
            w.dirty = true;
        };
    }

    /// Sets the theme (light or dark) of all its windows.
    pub fn setTheme(a: *App, mode: theme_mod.ThemeMode) void {
        a.theme = mode;
        a.applyTheme();
    }

    /// Runs the app until it quits (`quit`, or a request the options make
    /// a quit): `step` after `step`.
    pub fn run(a: *App) !void {
        while (try a.step(std.math.maxInt(u64))) {}
    }

    /// One turn of the app's loop (see `run`, for an app that has a loop
    /// of its own): waits until there is something to do (a frame to draw
    /// that its window is ready for, or something from the windows, or,
    /// with nothing to draw, `idle_timeout_ns`); does what the system
    /// asked (as the options say, or by their callbacks); brings the UIs
    /// up to date with their windows, gives them their input (their
    /// widgets' callbacks are called), and draws the windows that have a
    /// frame to draw. False when the app should end (`quit` was called).
    ///
    /// A frame is drawn only once the window has shown the last one, so
    /// that it is drawn for the time it will be shown, not a frame early.
    ///
    /// It waits through the app's `std.Io`, so other tasks on it go on
    /// meanwhile; `error.Canceled` if this task is canceled.
    pub fn step(a: *App, idle_timeout_ns: u64) !bool {
        if (a.quitting) return false;
        a.stepping = true;
        defer {
            a.stepping = false;
            a.sweepDestroyedWindows();
        }
        // Woken when an image is loaded, as by the windows' events.
        if (!a.watching_images) if (a.shared.images.waitSource()) |src| {
            a.display.watch(src, true);
            a.watching_images = true;
        };
        if (!a.watching_wake) if (a.shared.wakeSource()) |src| {
            a.display.watch(src, true);
            a.watching_wake = true;
        };
        if (has_atspi and !a.watching_a11y) if (a.shared.a11y) |b| {
            a.display.watch(b.source(), true);
            a.watching_a11y = true;
        };
        // Not waiting at all if a window has a frame to draw now, or else
        // not past a frame's time if one has a frame to draw at all.
        var timeout_ns = idle_timeout_ns;
        const ready = for (a.windows.items) |w| {
            if (w.closed or !w.wantsFrame()) continue;
            if (!w.idle and !w.win.isFramePending()) break true;
            const refresh = w.win.refreshNs();
            timeout_ns = @min(timeout_ns, if (refresh > 0) refresh else 16 * std.time.ns_per_ms);
        } else false;
        if (ready) try a.display.poll() else try a.display.wait(timeout_ns);

        // What is the app's, for all its windows.
        var all = false;
        if (a.shared.images.collect()) all = true;
        if (a.shared.takeWakes()) all = true;
        if (has_atspi) if (a.shared.a11y) |b| if (b.dispatch()) {
            all = true;
        };
        if (a.followSystem()) a.applyTheme();
        if (a.display.takeQuitRequest()) switch (a.on_quit_request) {
            .ignore => {},
            .quit => a.quit(),
            .call => |c| c.call(),
        };

        // Each window's (by index: a callback may open more).
        var i: usize = 0;
        while (i < a.windows.items.len) : (i += 1) {
            const w = a.windows.items[i];
            if (w.closed) continue;
            if (all) w.dirty = true;
            const asked = w.win.takeCloseRequest();
            const pressed = w.controls.close_requested;
            w.controls.close_requested = false;
            if (asked or pressed) switch (w.on_close_request) {
                .ignore => {},
                .close => w.close(),
                .call => |c| {
                    w.busy = true;
                    c.call(w);
                    w.busy = false;
                    if (w.closed) w.release();
                },
            };
            if (w.closed) continue;
            if (try w.win.applyConfigure() != null) w.dirty = true;
            const suspended = w.win.isSuspended();
            if (suspended != w.suspended) {
                w.suspended = suspended;
                if (suspended) w.win.releaseSpareBuffers() else w.dirty = true;
            }
            w.ui.syncWindow(w.win);
        }
        a.takeInput();
        if (a.last_window_closed) {
            a.last_window_closed = false;
            if (a.open_windows == 0) switch (a.on_last_window_closed) {
                .ignore => {},
                .quit => a.quit(),
                .call => |c| c.call(),
            };
        }
        if (a.quitting) return false;
        i = 0;
        while (i < a.windows.items.len) : (i += 1) {
            const w = a.windows.items[i];
            if (!w.closed) try w.draw();
        }
        return !a.quitting;
    }

    fn sweepDestroyedWindows(a: *App) void {
        var i: usize = 0;
        while (i < a.windows.items.len) {
            const w = a.windows.items[i];
            if (w.destroyed and !w.busy and !w.drawing) {
                w.release();
                _ = a.windows.orderedRemove(i);
                a.gpa.destroy(w);
            } else {
                i += 1;
            }
        }
    }

    /// Hands each window's input to its UI (its widgets' callbacks are
    /// called): if any came, every window is drawn again.
    fn takeInput(a: *App) void {
        var any = false;
        var i: usize = 0;
        while (i < a.windows.items.len) : (i += 1) {
            const w = a.windows.items[i];
            if (w.closed) continue;
            const before = w.ui.inputs;
            w.busy = true;
            w.ui.takeInput(w.win);
            w.busy = false;
            if (w.ui.inputs != before) any = true;
            if (w.closed) w.release();
        }
        if (any) for (a.windows.items) |w| {
            if (!w.closed) w.dirty = true;
        };
    }

    /// One of the app's windows (see `openWindow`), and its UI, which draws
    /// its root. Closed (`close`), its handle stays valid until it is
    /// destroyed (`destroy`, or `App.deinit`).
    pub const Window = struct {
        app: *App,
        /// The window system's window, for what a custom backend adds (the
        /// methods above do what an app needs of it).
        win: window_mod.Window,
        /// Whether `close` closes `win` (it was opened by `openWindow`).
        owns_window: bool = false,
        /// What its title bar's buttons do (see `window.WindowControls`).
        controls: window_mod.WindowControls,
        /// Its UI (destroyed when it is closed).
        ui: *WindowUi,
        root: Root,
        clear_color: ?u32 = null,
        on_close_request: OnCloseRequest = .ignore,
        closed: bool = false,
        destroyed: bool = false,
        /// Closed while its UI was handling input or drawing: it is let go
        /// when that is done.
        busy: bool = false,
        released: bool = false,
        dirty: bool = true,
        /// A frame is being drawn because the window asked (from inside the
        /// window system's loop, which holds the app's).
        held: bool = false,
        /// The last frame drawn showed nothing, so `step` waits rather than
        /// going straight on to draw again.
        idle: bool = false,
        suspended: bool = false,
        /// A frame is being drawn.
        drawing: bool = false,
        /// When the last frame (`KETE_TRACE=1`) was begun.
        last_frame_ns: u64 = 0,

        /// Closes it (its UI too): its handle stays valid, until it is
        /// destroyed.
        pub fn close(w: *Window) void {
            if (w.closed) return;
            w.closed = true;
            const a = w.app;
            a.open_windows -= 1;
            if (a.open_windows == 0) a.last_window_closed = true;
            if (!w.busy and !w.drawing) w.release();
        }

        fn release(w: *Window) void {
            if (w.released) return;
            w.released = true;
            w.win.setRedraw(null);
            w.ui.destroy();
            if (w.owns_window) w.win.close();
        }

        /// Whether it has been closed.
        pub fn isClosed(w: *const Window) bool {
            return w.closed;
        }

        /// Closes it (if it is open), and frees its handle.
        pub fn destroy(w: *Window) void {
            w.destroyed = true;
            w.close();
            const a = w.app;
            if (w.busy or w.drawing or a.stepping) return;
            if (std.mem.indexOfScalar(*Window, a.windows.items, w)) |i| _ = a.windows.orderedRemove(i);
            a.gpa.destroy(w);
        }

        /// Changes the title the system shows for it.
        pub fn setTitle(w: *Window, text: []const u8) void {
            if (w.closed) return;
            w.win.setTitle(text);
            w.dirty = true;
        }

        /// How the frames reach the window system (`memory`, `linux_dmabuf`,
        /// `swapchain`, `custom`).
        pub const BufferTransport = window_mod.WindowBufferTransport;
        /// How the window system knows a GPU buffer is finished (`none`,
        /// `implicit`, `explicit`).
        pub const BufferSync = window_mod.WindowBufferSync;
        /// How frames are paced and synchronized with the display.
        pub const FrameSync = window_mod.WindowFrameSync;
        /// Who draws a window's title bar and borders (`none`, `toolkit`,
        /// `system`).
        pub const Decorations = window_mod.WindowDecorations;

        /// Its size in logical pixels, `[width, height]` (zeros once it is
        /// closed). Its buffer is this many times `scale()` across.
        pub fn size(w: *const Window) [2]u32 {
            if (w.closed) return .{ 0, 0 };
            return w.win.size();
        }

        /// How many pixels each of its logical pixels is, on its display (1
        /// once it is closed).
        pub fn scale(w: *const Window) u32 {
            if (w.closed) return 1;
            return @max(w.win.scale(), 1);
        }

        /// Sets the smallest size, in logical pixels, the user can resize it to.
        pub fn setMinSize(w: *Window, width: u32, height: u32) void {
            if (w.closed) return;
            w.win.setMinSize(width, height);
        }

        /// Whether it fills the screen.
        pub fn isMaximized(w: *const Window) bool {
            return !w.closed and w.win.isMaximized();
        }

        /// Makes it fill the screen (`on`), or go back to its own size.
        pub fn setMaximized(w: *Window, on: bool) void {
            if (w.closed) return;
            w.win.setMaximized(on);
        }

        /// Hides it (to the dock or task bar); the system shows it again.
        pub fn setMinimized(w: *Window) void {
            if (w.closed) return;
            w.win.setMinimized();
        }

        /// The parts of it the window system or the toolkit draws over what
        /// the app draws (as a phone's notch is), in logical pixels from its
        /// top left: the window's buttons, when the app draws in the title
        /// bar (`WindowOptions.draw_in_title_bar`): the toolkit's, or the
        /// window system's. The app can draw under them, but should keep what
        /// matters out of them. Empty otherwise.
        /// Good until the next frame.
        pub fn cutouts(w: *const Window) []const geometry.Rect {
            if (w.closed) return &.{};
            return w.ui.cutouts();
        }

        /// Whether what the app draws goes under the window's title bar, with
        /// the window's buttons over it (`cutouts`): false where the window
        /// system draws the title bar, or the window is fullscreen, and the
        /// app has to draw its own bar below it, if it has one.
        pub fn contentInTitleBar(w: *const Window) bool {
            return !w.closed and (w.ui.hasControlsOverlay() or w.ui.cutouts().len > 0);
        }

        /// Whether it covers the whole display.
        pub fn isFullscreen(w: *const Window) bool {
            return !w.closed and w.win.isFullscreen();
        }

        /// Makes it cover the whole display (`on`), or go back to its own size.
        pub fn setFullscreen(w: *Window, on: bool) void {
            if (w.closed) return;
            w.win.setFullscreen(on);
        }

        /// Whether it is tiled against other windows or the screen's edges.
        pub fn isTiled(w: *const Window) bool {
            return !w.closed and w.win.isTiled();
        }

        /// Who draws its title bar and borders.
        pub fn decorations(w: *const Window) Decorations {
            return if (w.closed) .none else w.ui.decorations;
        }

        /// How its frames reach the window system.
        pub fn bufferTransport(w: *const Window) BufferTransport {
            return if (w.closed) .memory else w.win.bufferTransport();
        }

        /// How the window system knows a GPU buffer is finished.
        pub fn bufferSync(w: *const Window) BufferSync {
            return if (w.closed) .none else w.win.bufferSync();
        }

        /// How its frames are paced and synchronized with the display.
        pub fn frameSync(w: *const Window) FrameSync {
            return if (w.closed) .{} else w.win.frameSync();
        }

        /// The refresh rate of the display it is on, in Hz, or 0 if unknown.
        pub fn refreshHz(w: *const Window) f32 {
            return if (w.closed) 0 else w.win.refreshHz();
        }

        /// Draws `root` from now on.
        pub fn setRoot(w: *Window, root: Root) void {
            w.root = root;
            w.dirty = true;
        }

        /// Whether there is a frame to draw: the window shows, and something
        /// changed or a widget asked for one.
        fn wantsFrame(w: *const Window) bool {
            return !w.suspended and (w.dirty or w.ui.needs_frame);
        }

        /// Draws and shows a frame of its root (for now, on the `Io`'s
        /// clock), if there is one to draw and the window is ready for it.
        fn draw(w: *Window) !void {
            w.idle = true;
            if (!w.wantsFrame()) return;
            if (w.win.isFramePending()) {
                if (try w.ui.presentPopups()) w.idle = false;
                return;
            }
            try w.drawFrame();
        }

        fn drawFrame(w: *Window) !void {
            w.drawing = true;
            defer {
                w.drawing = false;
                if (w.closed) w.release();
            }
            w.dirty = false;
            const extent = w.win.size();
            const now_ns = w.ui.clockNs();
            const target_ns = w.win.nextPresentationNs(now_ns);
            const begun = w.ui.clockNs();
            w.root.frame(w.root.ptr, w.ui, extent[0], extent[1], target_ns);
            const built = w.ui.clockNs();
            w.win.setPresentationTime(target_ns);
            const clear = w.clear_color orelse w.ui.theme.surface.toArgb();
            const shown = try w.ui.present(w.win, clear);
            if (shown) w.idle = false;
            if (w.app.trace) w.traceFrame(begun, built, shown);
        }

        /// Writes how the frame just drawn went (`KETE_TRACE=1`): since the
        /// last began, whether the window system was holding the loop (the
        /// window asked for it), and how long it took to build and to present.
        fn traceFrame(w: *Window, begun: u64, built: u64, shown: bool) void {
            const done = w.ui.clockNs();
            const ms = struct {
                fn f(ns: u64) f64 {
                    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
                }
            }.f;
            const index = std.mem.indexOfScalar(*Window, w.app.windows.items, w) orelse 0;
            std.debug.print("kete: window {d} frame {d}: +{d:.1} ms{s}{s} build {d:.1} present {d:.1}\n", .{
                index,
                w.ui.frame_no,
                ms(begun -| w.last_frame_ns),
                if (w.held) " held" else "",
                if (shown) "" else " (nothing shown)",
                ms(built - begun),
                ms(done - built),
            });
            w.last_frame_ns = begun;
        }

        /// Draws a frame of its root, at the window's size now, if there is
        /// one to draw (it was resized, or a widget asked for one): the
        /// window asks, from inside the window system's loop (which holds
        /// the app's: macOS's, while the window is resized by its edge).
        fn redraw(ctx: *anyopaque) void {
            const w: *Window = @ptrCast(@alignCast(ctx));
            // Not inside a frame (one can resize the window, to its minimum).
            if (w.drawing or w.closed) return;
            if (w.win.applyConfigure() catch return) |_| w.dirty = true;
            if (!w.wantsFrame()) return;
            w.ui.syncWindow(w.win);
            w.held = true;
            defer w.held = false;
            w.drawFrame() catch {};
        }
    };
};

test "forgetting a hovered node during pointer dispatch is memory-safe" {
    const f = try font.Font.init(font.default_font_data);
    const ui = try WindowUi.create(std.testing.allocator, std.testing.io, &f);
    defer ui.destroy();

    const Watcher = struct {
        child: ?Widget = null,
        target: *?*Node,
        leaves: *usize,

        pub fn layout(_: *const @This(), n: *Node, c: Constraints) Size {
            const s = c.constrain(.{ .w = 100, .h = 100 });
            if (n.childCount() > 0) _ = n.child(0).layout(.tight(s));
            return s;
        }

        pub fn event(self: *const @This(), n: *Node, e: Event) bool {
            switch (e) {
                .leave => {
                    self.leaves.* += 1;
                    if (self.target.*) |t| {
                        self.target.* = null;
                        n.ui.forget(t);
                    }
                },
                else => {},
            }
            return false;
        }
    };

    var target: ?*Node = null;
    var leaves: usize = 0;
    const S = struct {
        target: *?*Node,
        leaves: *usize,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(Watcher{
                .target = self.target,
                .leaves = self.leaves,
                .child = cx.make(Watcher{
                    .target = self.target,
                    .leaves = self.leaves,
                }),
            });
        }
    };
    ui.frame(200, 100, 0, S{ .target = &target, .leaves = &leaves });
    ui.pointerMotion(.{ 10, 50 });
    try std.testing.expectEqual(@as(usize, 2), ui.hovered.items.len);
    // When hovered.items[0] handles .leave, it forgets hovered.items[0] mid-iteration.
    target = ui.hovered.items[0];
    ui.pointerLeave();
    try std.testing.expectEqual(@as(usize, 0), ui.hovered.items.len);
    try std.testing.expectEqual(@as(usize, 2), leaves);
}
