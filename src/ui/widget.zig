//! Widgets, and the tree of nodes that keeps them between frames.
//!
//! A `Widget` is an immutable description of part of the screen, made
//! fresh every frame (in the frame's arena) from any struct type:
//!
//! * A type with `build` is made of other widgets. If it declares a
//!   `State` type, it is also stateful: the state lives as long as the
//!   widget stays at its place in the tree, and `build` gets it:
//!
//!       const Counter = struct {
//!           pub const State = struct { count: u32 = 0 };
//!           pub fn build(_: *const Counter, cx: *Context, state: *State) Widget { ... }
//!       };
//!
//! * Any other type lays out and paints itself (and its children):
//!   `layout` sizes it within its constraints and places its children,
//!   `paint` draws it, `event` handles pointer events. Each is optional:
//!   by default a widget passes its constraints to its children, stacks
//!   them at its top left and is as big as allowed. Children are found in
//!   a `child: Widget` (or `?Widget`) or a `children: []const Widget`
//!   field, or made by a `children` function taking the `BuildContext` and the
//!   node (for widgets that make only the children that show: see
//!   `realize` and grid.zig).
//!
//! A node is a widget's place in the tree. Each frame the new widgets are
//! matched to the nodes of the last (by position and type, or by key), so
//! state and layout carry over; nodes that no longer match are freed.

const Accessibility = @import("accessibility.zig");
const std = @import("std");
const Theme = @import("theme.zig").Theme;
const gfx = @import("gfx");
const window_mod = @import("window");
const geometry = @import("geometry.zig");
const painter_mod = @import("painter.zig");
const runtime = @import("runtime.zig");
const menu_mod = @import("menu.zig");

const Size = geometry.Size;
const Point = geometry.Point;
const Rect = geometry.Rect;
const Constraints = geometry.Constraints;
const Painter = painter_mod.Painter;
const WindowUi = runtime.WindowUi;

/// A widget: a description of part of the screen, made fresh every frame
/// by `BuildContext.make` from any struct type (see the top of this file for what
/// such a type can have).
pub const Widget = struct {
    /// The widget's value (made with `BuildContext.make`, in the frame's arena).
    ptr: *const anyopaque,
    /// What the toolkit calls on it: `layout`, `paint`, `event` and the rest.
    vtable: *const VTable,
    /// Matches this widget to the same node across frames when siblings
    /// come and go (otherwise matched by position).
    key: ?u64 = null,

    /// The same widget with `key` set, to match it to its node when siblings come and go.
    pub fn withKey(w: Widget, key: u64) Widget {
        var out = w;
        out.key = key;
        return out;
    }

    /// Whether it is a `T`.
    pub fn is(w: Widget, comptime T: type) bool {
        return w.vtable == vtableFor(T);
    }

    /// The widget's value, if it is a `T`.
    pub fn as(w: Widget, comptime T: type) ?*const T {
        return if (w.is(T)) @ptrCast(@alignCast(w.ptr)) else null;
    }

    /// Makes a widget of a value that lives at least until the next frame
    /// is built (see `BuildContext.make` for values made while building).
    pub fn of(comptime T: type, ptr: *const T) Widget {
        return .{ .ptr = ptr, .vtable = vtableFor(T) };
    }
};

/// The pointer shape a widget asks for while the pointer is over it (or
/// while it has captured the pointer).
pub const PointerCursor = window_mod.PointerCursor;

/// A focused text widget's state, for the platform's input method.
pub const TextInputInfo = struct {
    surrounding_text: []const u8 = "",
    cursor: u32 = 0,
    anchor: u32 = 0,
    /// Cursor rectangle in the widget's local coordinates (`[x, y, width, height]`).
    cursor_rect: [4]i32 = .{ 0, 0, 1, 20 },
    password: bool = false,
    multiline: bool = false,
    change_cause_other: bool = false,
};

/// What happens to a widget with an `event` function. It returns whether it
/// took the event (so that it goes no further); taking it draws nothing
/// again: a widget that changes (or calls back) asks for another frame
/// (`needs_frame` on its node's UI).
pub const Event = union(enum) {
    /// The pointer moved over it (or onto something inside it).
    enter,
    leave,
    /// A button went down over it. Returning true takes the pointer: it
    /// gets the release, wherever that is. `clicks` counts the presses in
    /// quick succession at about the same place: 2 for the second of a
    /// double click, 3 for a triple click, and so on.
    press: struct { pos: Point, button: PointerButton, clicks: u8 = 1 },
    release: struct { pos: Point, button: PointerButton, inside: bool },
    /// The pointer moved, over it or while it has the pointer.
    motion: Point,
    /// The wheel turned over it: by `dy` pixels down (and `dx` right).
    /// Returning true says it scrolled; otherwise it goes to the widgets
    /// around it.
    /// `touch`: a finger moved it (by exactly that much: a pan), rather
    /// than a wheel (whose notches may scroll further).
    scroll: struct { pos: Point, dx: f32, dy: f32, touch: bool = false },
    /// It got the keyboard (`WindowUi.focus`), or lost it.
    focus,
    blur,
    /// A key went down or up while it has the keyboard.
    key: Key,
    /// An input method committed UTF-8 text (`zwp_text_input_v3`).
    text_commit: []const u8,
    /// An input method updated its preedit string (`zwp_text_input_v3`).
    text_preedit: struct { text: []const u8, cursor_begin: i32 = 0, cursor_end: i32 = 0 },
    /// An input method asked to delete bytes around the cursor
    /// (`zwp_text_input_v3`).
    text_delete_surrounding: struct { before_length: u32, after_length: u32 },
    /// A menu is asked for at a point in it: the right button was pressed
    /// there, or the left held down there without moving. Returning true
    /// says it showed one (`WindowUi.openMenu`).
    context: Point,

    pub const Key = struct {
        key: KeyboardKey,
        pressed: bool,
        /// The character it types, by the keymap (the window's, or
        /// `WindowUi.loadKeymap`'s), if any: none while Control is held.
        char: ?u21 = null,
        /// Modifiers held.
        ctrl: bool = false,
        shift: bool = false,
    };
};

/// The key in `Event.key`.
pub const KeyboardKey = window_mod.KeyboardKey;

/// The pointer button in `Event.press` and `.release`.
pub const PointerButton = window_mod.PointerButton;

/// Something to call later, typically a method of a widget's state:
/// `Callback.of(state, State.increment)`.
pub const Callback = struct {
    /// What `f` is called with (the `ptr` of `of`).
    ctx: *anyopaque,
    /// The function to call.
    f: *const fn (*anyopaque) void,

    /// A callback that calls `f` with `ptr` (`ptr` must last as long as the callback is used).
    pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr)) void) Callback {
        const P = @TypeOf(ptr);
        return .{ .ctx = @ptrCast(@constCast(ptr)), .f = struct {
            fn call(ctx: *anyopaque) void {
                f(@as(P, @ptrCast(@alignCast(ctx))));
            }
        }.call };
    }

    /// Calls it.
    pub fn call(c: Callback) void {
        c.f(c.ctx);
    }
};

/// A callback given a value (a control's new value, say):
/// `ValueCallback(bool).of(state, State.setLighting)`.
pub fn ValueCallback(comptime T: type) type {
    return struct {
        /// What `f` is called with (the `ptr` of `of`).
        ctx: *anyopaque,
        /// The function to call.
        f: *const fn (*anyopaque, T) void,

        /// A callback that calls `f` with `ptr` and the value (`ptr` must last
        /// as long as the callback is used).
        pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), T) void) @This() {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(@constCast(ptr)), .f = struct {
                fn call(ctx: *anyopaque, v: T) void {
                    f(@as(P, @ptrCast(@alignCast(ctx))), v);
                }
            }.call };
        }

        /// Calls it with `v`.
        pub fn call(c: @This(), v: T) void {
            c.f(c.ctx, v);
        }
    };
}

pub const VTable = struct {
    name: []const u8,
    build: ?*const fn (*const anyopaque, *BuildContext, ?*anyopaque) Widget,
    children: *const fn (*const anyopaque) []const Widget,
    layout: ?*const fn (*const anyopaque, *WidgetNode, Constraints) Size,
    min_size: ?*const fn (*const anyopaque, *WidgetNode, Constraints) Size,
    paint: ?*const fn (*const anyopaque, *WidgetNode, *Painter) void,
    paint_over: ?*const fn (*const anyopaque, *WidgetNode, *Painter) void,
    event: ?*const fn (*const anyopaque, *WidgetNode, Event) bool,
    hit_test: ?*const fn (*const anyopaque, *WidgetNode, Point) bool,
    cursor: ?*const fn (*const anyopaque, *WidgetNode, Point) ?PointerCursor,
    text_input: ?*const fn (*const anyopaque, *WidgetNode) ?TextInputInfo,
    /// What it is to assistive technologies (a screen reader), if anything
    /// (`pub fn accessible(self, n) ?accessibility.Info`).
    accessible: ?*const fn (*const anyopaque, *WidgetNode) ?Accessibility.Info,
    /// Whether it takes the keyboard's focus now (`pub fn focusable(self,
    /// n) bool`): Tab moves it from one to the next.
    focusable: ?*const fn (*const anyopaque, *WidgetNode) bool,
    /// Tab is a key it takes (`pub const takes_tab = true`: a text area
    /// types it), so only Control and Tab moves the focus from it.
    takes_tab: bool,
    /// Makes its children (instead of `children`), when the tree is built.
    make_children: ?*const fn (*const anyopaque, *BuildContext, *WidgetNode) []const Widget,
    /// Told, once laid out in a scroll view, what of it shows (relative to
    /// itself), to make the children there.
    realize: ?*const fn (*const anyopaque, *WidgetNode, Rect) void,
    /// Scrolls its child (`pub const scrolls = true`): it tells the
    /// widgets in it what shows (see `WidgetNode.realizeIn`).
    scrolls: bool,
    state: ?StateOps,
    /// Shows only what of its children is within its bounds, without
    /// counting the rest as overflow (`pub const clips_children = true`:
    /// a scroll view).
    clips_children: bool,
};

pub const StateOps = struct {
    size: usize,
    alignment: std.mem.Alignment,
    init: *const fn (*const anyopaque, *anyopaque) void,
    deinit: *const fn (*anyopaque) void,
};

/// The vtable of widgets of type `T` (one per type, so it identifies it).
pub fn vtableFor(comptime T: type) *const VTable {
    return &struct {
        const vtable: VTable = makeVTable(T);
    }.vtable;
}

fn makeVTable(comptime T: type) VTable {
    const S = struct {
        fn self(ptr: *const anyopaque) *const T {
            return @ptrCast(@alignCast(ptr));
        }
        fn build(ptr: *const anyopaque, cx: *BuildContext, state: ?*anyopaque) Widget {
            const param_types = @typeInfo(@TypeOf(T.build)).@"fn".param_types;
            if (param_types.len == 3) return T.build(self(ptr), cx, @ptrCast(@alignCast(state.?)));
            return T.build(self(ptr), cx);
        }
        fn children(ptr: *const anyopaque) []const Widget {
            const w = self(ptr);
            if (@hasField(T, "children")) return w.children;
            if (@hasField(T, "child")) {
                if (@FieldType(T, "child") == Widget) return @as(*const [1]Widget, &w.child);
                if (w.child) |*c| return @as(*const [1]Widget, c);
            }
            return &.{};
        }
        fn layout(ptr: *const anyopaque, n: *WidgetNode, c: Constraints) Size {
            return T.layout(self(ptr), n, c);
        }
        fn minSize(ptr: *const anyopaque, n: *WidgetNode, c: Constraints) Size {
            return T.minSize(self(ptr), n, c);
        }
        fn paint(ptr: *const anyopaque, n: *WidgetNode, p: *Painter) void {
            T.paint(self(ptr), n, p);
        }
        fn paintOver(ptr: *const anyopaque, n: *WidgetNode, p: *Painter) void {
            T.paintOver(self(ptr), n, p);
        }
        fn event(ptr: *const anyopaque, n: *WidgetNode, e: Event) bool {
            return T.event(self(ptr), n, e);
        }
        fn hitTest(ptr: *const anyopaque, n: *WidgetNode, p: Point) bool {
            return T.hitTest(self(ptr), n, p);
        }
        fn cursor(ptr: *const anyopaque, n: *WidgetNode, p: Point) ?PointerCursor {
            return T.cursor(self(ptr), n, p);
        }
        fn textInput(ptr: *const anyopaque, n: *WidgetNode) ?TextInputInfo {
            return T.textInput(self(ptr), n);
        }
        fn accessible(ptr: *const anyopaque, n: *WidgetNode) ?Accessibility.Info {
            return T.accessible(self(ptr), n);
        }
        fn focusable(ptr: *const anyopaque, n: *WidgetNode) bool {
            return T.focusable(self(ptr), n);
        }
        fn makeChildren(ptr: *const anyopaque, cx: *BuildContext, n: *WidgetNode) []const Widget {
            return T.children(self(ptr), cx, n);
        }
        fn realize(ptr: *const anyopaque, n: *WidgetNode, visible: Rect) void {
            T.realize(self(ptr), n, visible);
        }
        fn initState(ptr: *const anyopaque, state: *anyopaque) void {
            const st: *T.State = @ptrCast(@alignCast(state));
            st.* = if (@hasDecl(T, "initState")) T.initState(self(ptr)) else .{};
        }
        fn deinitState(state: *anyopaque) void {
            if (@hasDecl(T.State, "deinit")) @as(*T.State, @ptrCast(@alignCast(state))).deinit();
        }
    };
    return .{
        .name = @typeName(T),
        .build = if (@hasDecl(T, "build")) S.build else null,
        .children = S.children,
        .layout = if (@hasDecl(T, "layout")) S.layout else null,
        .min_size = if (@hasDecl(T, "minSize")) S.minSize else null,
        .paint = if (@hasDecl(T, "paint")) S.paint else null,
        .paint_over = if (@hasDecl(T, "paintOver")) S.paintOver else null,
        .event = if (@hasDecl(T, "event")) S.event else null,
        .hit_test = if (@hasDecl(T, "hitTest")) S.hitTest else null,
        .cursor = if (@hasDecl(T, "cursor")) S.cursor else null,
        .text_input = if (@hasDecl(T, "textInput")) S.textInput else null,
        .accessible = if (@hasDecl(T, "accessible")) S.accessible else null,
        .focusable = if (@hasDecl(T, "focusable")) S.focusable else null,
        .takes_tab = @hasDecl(T, "takes_tab") and T.takes_tab,
        .make_children = if (@hasDecl(T, "children")) S.makeChildren else null,
        .realize = if (@hasDecl(T, "realize")) S.realize else null,
        .scrolls = @hasDecl(T, "scrolls") and T.scrolls,
        .clips_children = @hasDecl(T, "clips_children") and T.clips_children,
        .state = if (@hasDecl(T, "State")) .{
            .size = @sizeOf(T.State),
            .alignment = .of(T.State),
            .init = S.initState,
            .deinit = S.deinitState,
        } else null,
    };
}

/// Shown in place of a widget that could not be made (out of memory).
const Missing = struct {
    pub fn layout(_: *const Missing, _: *WidgetNode, c: Constraints) Size {
        return c.smallest();
    }

    pub fn minSize(_: *const Missing, _: *WidgetNode, c: Constraints) Size {
        return c.smallest();
    }
};
const missing: Missing = .{};

/// Where a widget is (from `BuildContext.anchor`, as it is built), to open a menu
/// from later, as a button's callback does. Kept in the widget's `State`,
/// it is good for as long as the widget is there.
pub const WidgetAnchor = struct {
    /// The node of the widget, or null if there is none.
    node: ?*WidgetNode = null,

    /// Opens a menu of `items` (copied) just below the widget, as a
    /// dropdown's; nothing, if it was not taken while building a widget.
    pub fn openMenu(a: WidgetAnchor, items: []const menu_mod.Item) void {
        const n = a.node orelse return;
        const pos = n.position();
        n.ui.openMenu(n, .{ pos[0], pos[1] + n.size.h }, items);
    }
};

/// What `build` functions get: the frame's arena, and the UI.
pub const BuildContext = struct {
    /// The UI the widget is built in: its window's (its `theme`, the
    /// app's `io`, and what the app's windows share, as `shared`).
    ui: *WindowUi,
    /// The frame's arena, which `make`, `makeAll` and `fmt` allocate in:
    /// what is made in it lasts until the frame after next is built (so it
    /// is there while this frame is laid out, painted and handles input,
    /// and while the next is built). Never freed one by one.
    arena: std.mem.Allocator,
    /// The toolkit's own (not for an app's widgets, which have `anchor`):
    /// the node the widget is built in, or null for what is built outside
    /// one (a menu's or popup's content, the title bar).
    node: ?*WidgetNode = null,
    /// The theme the widget is built in, if not the UI's (that of the
    /// nearest `Themed` above it): read it with `theme`.
    theme_ptr: ?*const Theme = null,

    /// A widget of `value`'s type, copied into the frame's arena (with
    /// its `children` slice, so `&.{ a, b }` can be passed directly).
    pub fn make(cx: *BuildContext, value: anytype) Widget {
        const T = @TypeOf(value);
        const p = cx.arena.create(T) catch return Widget.of(Missing, &missing);
        p.* = value;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |field_name, FieldType| {
            switch (@typeInfo(FieldType)) {
                .pointer => |ptr| if (ptr.size == .slice and ptr.attrs.@"const" and ptr.child != u8) {
                    @field(p, field_name) = cx.arena.dupe(ptr.child, @field(value, field_name)) catch &.{};
                },
                else => {},
            }
        }
        return Widget.of(T, p);
    }

    /// Widgets of the values in the tuple `values` (each made as `make`
    /// does; any already a `Widget` taken as it is), as a slice in the
    /// frame's arena: for `children`.
    pub fn makeAll(cx: *BuildContext, values: anytype) []const Widget {
        const fields = @typeInfo(@TypeOf(values)).@"struct".field_types;
        const out = cx.arena.alloc(Widget, fields.len) catch return &.{};
        inline for (fields, 0..) |F, i| {
            out[i] = if (F == Widget) values[i] else cx.make(values[i]);
        }
        return out;
    }

    /// Where the widget being built is, to open a menu from later (from a
    /// callback): see `WidgetAnchor`.
    pub fn anchor(cx: *const BuildContext) WidgetAnchor {
        return .{ .node = cx.node };
    }

    /// Text formatted into the frame's arena.
    pub fn fmt(cx: *BuildContext, comptime f: []const u8, args: anytype) []const u8 {
        return cx.arena.print(f, args) catch "…";
    }

    /// The theme the widget is in: the app's, or that of the nearest
    /// `Themed` above it.
    pub fn theme(cx: *const BuildContext) *const Theme {
        return cx.theme_ptr orelse &cx.ui.theme;
    }

    /// The frame's time, in nanoseconds (for animations).
    pub fn now(cx: *const BuildContext) u64 {
        return cx.ui.now_ns;
    }

    /// Asks for another frame after this one (for animations).
    pub fn requestFrame(cx: *BuildContext) void {
        cx.ui.needs_frame = true;
    }

    /// What the app runs on: the windowing platform and the extensions its
    /// compositor offers, the 2D renderer (`software`, `opengl`, `vulkan`,
    /// ...), and the keyboard's layout.
    pub fn backend(cx: *const BuildContext) BackendInfo {
        return cx.ui.backend();
    }

    /// The app's window the widget is in, to ask how it is shown (its size,
    /// scale and state, how its frames are presented, who draws its
    /// decorations) or to act on (`Window.setMaximized` and the like); null
    /// if the UI is not an `App`'s (one run on its own).
    pub fn window(cx: *const BuildContext) ?*runtime.App.Window {
        return cx.ui.app_window;
    }
};

/// What the app runs on: the same for all its windows (see `Window` for a
/// window's own).
pub const BackendInfo = struct {
    /// The windowing system the app runs on (`wayland`, `headless`,
    /// `windows`, `macos`, `custom`).
    pub const Platform = window_mod.WindowPlatform;

    /// Windowing platform.
    platform: Platform = .headless,
    /// The Wayland protocol extensions the compositor offers that kete can
    /// use (none on other platforms).
    wayland_extensions: []const []const u8 = &.{},
    /// 2D UI rendering backend (`software`, `opengl`, `vulkan`, `metal`,
    /// `d3d11`, `custom`).
    renderer: gfx.RenderBackend = .software,
    /// The keyboard layout in use (`.name()` "English (UK)", `.code()` "gb").
    keyboard: window_mod.KeyboardLayout = .{},

    /// Whether the compositor offers the Wayland extension `ext_name`.
    pub fn hasWaylandExtension(info: BackendInfo, ext_name: []const u8) bool {
        for (info.wayland_extensions) |ext| {
            if (std.mem.eql(u8, ext, ext_name)) return true;
        }
        return false;
    }
};

pub const Edges = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn any(e: Edges) bool {
        return e.left > 0 or e.top > 0 or e.right > 0 or e.bottom > 0;
    }
};

/// A widget's place in the tree, kept between frames.
pub const WidgetNode = struct {
    /// The UI (a window's) it is in.
    ui: *WindowUi,
    /// The widget it is the place of, from the last frame it was built in.
    widget: Widget,
    /// The node it is a child of (null for the root).
    parent: ?*WidgetNode = null,
    /// Its widget's state (see `state`), if the widget has a `State` type.
    state_ptr: ?*anyopaque = null,
    /// The nodes of the widgets it is made of (its `child` or `children`, or what it builds).
    children: std.ArrayList(*WidgetNode) = .empty,
    /// From the last layout: its size.
    size: Size = .{},
    /// From the last layout: where it is in its parent.
    offset: Point = .{ 0, 0 },
    /// What the widget drew beyond its children (text), if it can be
    /// bigger than the widget (see `setContent`).
    content: ?Rect = null,
    /// How far its children (or content) reach past each edge.
    overflow: Edges = .{},
    /// Placed partly outside its parent on purpose (a badge over an icon's
    /// corner): not counted as the parent's overflow. Its parent's layout
    /// sets it, each time it places it.
    overhangs: bool = false,
    /// The frame it was last laid out in.
    laid_out: u64 = 0,
    /// Whatever the widget's layout wants to keep for its paint, in the
    /// frame's arena.
    scratch: ?*anyopaque = null,
    /// Whether the widget, or one below it (not past a scroll view), makes
    /// only the children that show (`realize`), so that `realizeIn` has
    /// something to do here. Set when it is built.
    realizes: bool = false,
    /// What it drew when last painted (to find what changed).
    paint: @import("damage.zig").Painted = .{},
    /// The theme it is in, if not the app's: its parent's, or one a
    /// `Themed` gives (set as it is built; see `theme`).
    theme_ptr: ?*const Theme = null,
    /// Its object's number for assistive technologies, once it has one.
    a11y_id: u32 = 0,

    /// The theme the widget is in: the app's, or that of the nearest
    /// `Themed` above it (for `layout`, `paint` and `event` functions).
    pub fn theme(n: *const WidgetNode) *const Theme {
        return n.theme_ptr orelse &n.ui.theme;
    }

    /// Its `i`th child.
    pub fn child(n: *const WidgetNode, i: usize) *WidgetNode {
        return n.children.items[i];
    }

    /// How many children it has.
    pub fn childCount(n: *const WidgetNode) usize {
        return n.children.items.len;
    }

    /// The state of a stateful widget.
    pub fn state(n: *const WidgetNode, comptime S: type) *S {
        return @ptrCast(@alignCast(n.state_ptr.?));
    }

    /// Where it goes in its parent (for `layout` functions).
    pub fn place(n: *WidgetNode, x: f32, y: f32) void {
        n.offset = .{ x, y };
    }

    /// For widgets that draw more than their children: the area (relative
    /// to the widget) their drawing needs. Overflow is shown if it is
    /// bigger than the widget.
    pub fn setContent(n: *WidgetNode, r: Rect) void {
        n.content = r;
    }

    /// Lays the node out within `c` and returns its size. Never fails:
    /// constraints and sizes that make no sense are made to.
    pub fn layout(n: *WidgetNode, c_in: Constraints) Size {
        const c = c_in.sanitize();
        n.laid_out = n.ui.frame_no;
        n.content = null;
        n.scratch = null;
        for (n.children.items) |ch| {
            ch.offset = .{ 0, 0 };
            ch.size = .{};
            ch.overhangs = false;
        }
        const want = if (n.widget.vtable.layout) |f| f(n.widget.ptr, n, c) else n.defaultLayout(c);
        n.size = c.sanitizeSize(want);
        if (n.widget.vtable.clips_children) n.overflow = .{} else n.findOverflow();
        return n.size;
    }

    /// Children get the same constraints and go at the top left; the
    /// node is as big as allowed, or as its biggest child if unbounded.
    fn defaultLayout(n: *WidgetNode, c: Constraints) Size {
        if (n.children.items.len == 0) return c.biggest();
        var biggest: Size = .{};
        for (n.children.items) |ch| {
            const s = ch.layout(c);
            biggest = .{ .w = @max(biggest.w, s.w), .h = @max(biggest.h, s.h) };
        }
        return c.constrain(biggest);
    }

    /// The smallest size the node and its children need within `c` without
    /// overflowing or mutating layout state.
    pub fn minSize(n: *WidgetNode, c_in: Constraints) Size {
        const c = c_in.sanitize();
        const want = if (n.widget.vtable.min_size) |f|
            f(n.widget.ptr, n, c)
        else if (n.widget.vtable.layout) |f| blk: {
            const saved_size = n.size;
            const saved_offset = n.offset;
            const saved_content = n.content;
            const saved_overflow = n.overflow;
            const saved_laid_out = n.laid_out;
            const saved_scratch = n.scratch;
            const saved_needs_frame = n.ui.needs_frame;
            defer {
                n.size = saved_size;
                n.offset = saved_offset;
                n.content = saved_content;
                n.overflow = saved_overflow;
                n.laid_out = saved_laid_out;
                n.scratch = saved_scratch;
                n.ui.needs_frame = saved_needs_frame;
            }
            break :blk f(n.widget.ptr, n, c);
        } else n.defaultMinSize(c);
        return c.sanitizeSize(want);
    }

    fn defaultMinSize(n: *WidgetNode, c: Constraints) Size {
        if (n.children.items.len == 0) return c.smallest();
        var biggest: Size = .{};
        for (n.children.items) |ch| {
            const s = ch.minSize(c);
            biggest = .{ .w = @max(biggest.w, s.w), .h = @max(biggest.h, s.h) };
        }
        return c.constrain(biggest);
    }

    fn findOverflow(n: *WidgetNode) void {
        var x0: f32 = 0;
        var y0: f32 = 0;
        var x1 = n.size.w;
        var y1 = n.size.h;
        for (n.children.items) |ch| if (ch.laid_out == n.laid_out and !ch.overhangs) {
            x0 = @min(x0, ch.offset[0]);
            y0 = @min(y0, ch.offset[1]);
            x1 = @max(x1, ch.offset[0] + ch.size.w);
            y1 = @max(y1, ch.offset[1] + ch.size.h);
        };
        if (n.content) |r| {
            x0 = @min(x0, r.x);
            y0 = @min(y0, r.y);
            x1 = @max(x1, r.x + r.w);
            y1 = @max(y1, r.y + r.h);
        }
        // Less than half a pixel is rounding, not overflow.
        const over = struct {
            fn f(d: f32) f32 {
                return if (d > 0.5) d else 0;
            }
        }.f;
        n.overflow = .{ .left = over(-x0), .top = over(-y0), .right = over(x1 - n.size.w), .bottom = over(y1 - n.size.h) };
    }

    // --- Building -----------------------------------------------------------

    /// Makes the node for `w`, in `ui`, and builds it (null if there is no memory).
    pub fn create(ui: *WindowUi, w: Widget) ?*WidgetNode {
        const n = ui.gpa.create(WidgetNode) catch return null;
        n.* = .{ .ui = ui, .widget = w };
        if (w.vtable.state) |ops| {
            const mem = ui.gpa.rawAlloc(ops.size, ops.alignment, @returnAddress()) orelse {
                ui.gpa.destroy(n);
                return null;
            };
            ops.init(w.ptr, mem);
            n.state_ptr = mem;
        }
        return n;
    }

    /// Frees the node and those below it.
    pub fn destroy(n: *WidgetNode) void {
        for (n.children.items) |ch| ch.destroy();
        n.children.deinit(n.ui.gpa);
        n.ui.forget(n);
        n.ui.damage.removed(n);
        if (n.state_ptr) |s| {
            const ops = n.widget.vtable.state.?;
            ops.deinit(s);
            n.ui.gpa.rawFree(@as([*]u8, @ptrCast(s))[0..ops.size], ops.alignment, @returnAddress());
        }
        n.ui.gpa.destroy(n);
    }

    /// Gives the node this frame's widget, builds it, and does the same
    /// for the children.
    pub fn build(n: *WidgetNode, w: Widget) void {
        n.widget = w;
        // In its parent's theme (a root's is given before it is built),
        // unless it gives one of its own (`Themed`).
        if (n.parent) |p| n.theme_ptr = p.theme_ptr;
        if (w.vtable.build) |f| {
            var cx: BuildContext = .{ .ui = n.ui, .arena = n.ui.arena(), .node = n, .theme_ptr = n.theme_ptr };
            const built = f(w.ptr, &cx, n.state_ptr);
            n.reconcile(&.{built});
        } else if (w.vtable.make_children) |f| {
            var cx: BuildContext = .{ .ui = n.ui, .arena = n.ui.arena(), .node = n, .theme_ptr = n.theme_ptr };
            n.reconcile(f(w.ptr, &cx, n));
        } else {
            n.reconcile(w.vtable.children(w.ptr));
        }
        n.realizes = w.vtable.realize != null;
        if (!n.realizes) for (n.children.items) |ch| {
            if (ch.realizes and !ch.widget.vtable.scrolls) {
                n.realizes = true;
                break;
            }
        };
    }

    /// Matches the children's widgets to the existing child nodes (same
    /// type, and the same key or position), makes nodes for the rest, and
    /// frees the nodes left over. (Widgets that make their children as
    /// they are laid out call it then.)
    pub fn reconcile(n: *WidgetNode, widgets: []const Widget) void {
        if (widgets.len == n.children.items.len) {
            var all_match = true;
            for (widgets, n.children.items) |w, ch| {
                if (ch.widget.vtable != w.vtable or ch.widget.key != w.key) {
                    all_match = false;
                    break;
                }
            }
            if (all_match) {
                for (n.children.items, widgets) |ch, w| ch.build(w);
                return;
            }
        }
        const gpa = n.ui.gpa;
        const arena = n.ui.arena();
        // Signal that the tree structure changed so WindowUi.frame recomputes min_size.
        n.ui.build_version +%= 1;
        // The old children, aside (the list's memory is reused).
        const old_items: []*WidgetNode = arena.dupe(*WidgetNode, n.children.items) catch blk: {
            for (n.children.items) |o| o.destroy();
            break :blk &.{};
        };
        const old: struct { items: []*WidgetNode } = .{ .items = old_items };
        n.children.clearRetainingCapacity();
        // Which old nodes are kept (if this cannot be had, none are).
        const used: []bool = arena.alloc(bool, old.items.len) catch &.{};
        @memset(used, false);
        // The widget each new child gets.
        const matched: []Widget = arena.alloc(Widget, widgets.len) catch &.{};
        n.children.ensureTotalCapacity(gpa, widgets.len) catch {};
        for (widgets) |w| {
            if (n.children.items.len == matched.len) break;
            var found: ?usize = null;
            if (used.len == old.items.len) {
                if (w.key) |key| {
                    for (old.items, 0..) |o, j| if (!used[j] and o.widget.vtable == w.vtable and o.widget.key == key) {
                        found = j;
                        break;
                    };
                } else {
                    for (old.items, 0..) |o, j| if (!used[j] and o.widget.vtable == w.vtable and o.widget.key == null) {
                        found = j;
                        break;
                    };
                }
            }
            const node = if (found) |j| old.items[j] else WidgetNode.create(n.ui, w) orelse continue;
            n.children.append(gpa, node) catch {
                if (found == null) node.destroy();
                continue;
            };
            if (found) |j| used[j] = true;
            node.parent = n;
            matched[n.children.items.len - 1] = w;
        }
        for (old.items, 0..) |o, j| if (j >= used.len or !used[j]) o.destroy();
        for (n.children.items, matched[0..n.children.items.len]) |ch, w| ch.build(w);
    }

    // --- Hit testing ----------------------------------------------------------

    /// Adds the nodes under `p` (relative to this node) that handle events
    /// to `path`, deepest first. Returns whether anything here was hit.
    pub fn hitTest(n: *WidgetNode, p: Point, path: *std.ArrayList(*WidgetNode)) bool {
        if (n.laid_out != n.ui.frame_no) return false;
        if (p[0] < 0 or p[1] < 0 or p[0] >= n.size.w or p[1] >= n.size.h) return false;
        var hit = false;
        var i = n.children.items.len;
        while (i > 0) {
            i -= 1;
            const ch = n.children.items[i];
            if (ch.hitTest(.{ p[0] - ch.offset[0], p[1] - ch.offset[1] }, path)) {
                hit = true;
                break;
            }
        }
        const vt = n.widget.vtable;
        if (!hit) hit = if (vt.hit_test) |f| f(n.widget.ptr, n, p) else (vt.event != null or vt.cursor != null);
        if (hit and (vt.event != null or vt.cursor != null)) path.append(n.ui.gpa, n) catch {};
        return hit;
    }

    /// Tells the widgets that make only the children that show
    /// (`realize`), in it and below, what of them shows: `visible`
    /// (relative to this node). Scroll views below tell their own.
    pub fn realizeIn(n: *WidgetNode, visible: Rect) void {
        if (!n.realizes or n.laid_out != n.ui.frame_no) return;
        if (n.widget.vtable.realize) |f| return f(n.widget.ptr, n, visible);
        for (n.children.items) |ch| {
            if (ch.widget.vtable.scrolls) continue;
            ch.realizeIn(.{ .x = visible.x - ch.offset[0], .y = visible.y - ch.offset[1], .w = visible.w, .h = visible.h });
        }
    }

    /// Where the node's top left is in the window (as last laid out).
    pub fn position(n: *const WidgetNode) Point {
        var p = n.offset;
        var up = n.parent;
        while (up) |u| : (up = u.parent) p = .{ p[0] + u.offset[0], p[1] + u.offset[1] };
        return p;
    }
};
