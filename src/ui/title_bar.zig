//! TitleBar: the bar across the top of an app's window, with its title in
//! the middle and, at the right end, buttons that minimize, maximize (or
//! restore) and close it; dragging the bar moves the window. A title too
//! long for the bar ends in "…", and the bar is never narrower than its
//! buttons either side of a "…".
//!
//! When the toolkit draws the window's decorations (`decorations == .toolkit`),
//! `WindowUi` automatically adds `TitleBar` above the app's root widget; when
//! the window system draws them (`decorations == .system`) or the window is
//! fullscreen, no `TitleBar` is added.

const a11y = @import("accessibility.zig");
const std = @import("std");
const WindowControls = @import("window").WindowControls;
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Column = @import("flex.zig").Column;
const RoundedBox = @import("rounded_box.zig").RoundedBox;
const Padding = @import("padding.zig").Padding;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const BarButton = @import("bar_button.zig").BarButton;
const Text = @import("text.zig").Text;

const Node = widget.WidgetNode;
const Context = widget.BuildContext;
const Widget = widget.Widget;
const Size = geometry.Size;
const Constraints = geometry.Constraints;

/// A window's title bar, drawn by the toolkit where the window system does
/// not: its title, and buttons to minimize, maximize and close it. The toolkit
/// adds it to a window itself (see `Window.decorations`), so apps do not
/// make one.
pub const TitleBar = struct {
    /// The text in the bar.
    title: []const u8,
    /// Pressing the close button (defaults to `cx.ui.controls` when set);
    /// without it there is none.
    on_close: ?widget.Callback = null,
    /// Pressing the minimize button (defaults to `cx.ui.controls` when set,
    /// if the window can be minimized); without it there is none.
    on_minimize: ?widget.Callback = null,
    /// Pressing the maximize button, which shows whether the window fills
    /// the screen (defaults to `cx.ui.controls` when set, if the window can
    /// be maximized); without it there is none.
    on_maximize: ?widget.Callback = null,
    /// Whether the window is maximized (so the maximize button shows restoring).
    maximized: bool = true,
    /// A press on the bar itself, to start moving the window (defaults to
    /// `cx.ui.controls` when set).
    on_drag: ?widget.Callback = null,

    pub const height = 44;
    /// The buttons' size, the space between them, and that at the bar's
    /// ends and around the title.
    pub const button_size = 34;
    pub const spacing = 4;
    pub const margin = 8;
    /// How much of the title still shows in the narrowest window.
    const min_title_width = 120;

    pub fn accessible(self: *const TitleBar, _: *Node) ?a11y.Info {
        // Its title, and the window's buttons.
        return .{ .role = .toolbar, .label = self.title };
    }

    pub fn build(self: *const TitleBar, cx: *Context) Widget {
        // A fullscreen window has none.
        if (cx.ui.fullscreen) return cx.make(@import("sized_box.zig").SizedBox.empty);
        const actions = actionsOf(cx, .{ .minimize = self.on_minimize, .maximize = self.on_maximize, .close = self.on_close, .drag = self.on_drag });
        const maximized = if (self.on_maximize != null) self.maximized else cx.ui.maximized;
        const t = cx.theme();
        return cx.make(DragArea{ .on_drag = actions.drag, .on_maximize = actions.maximize, .child = cx.make(RoundedBox{ .color = t.surface_container, .child = cx.make(Bar{
            .title = self.title,
            .children = cx.makeAll(.{
                Text{ .text = self.title, .style = .{ .color = t.on_surface }, .wrap = false, .ellipsis = true },
                Row{ .spacing = spacing, .fill = false, .children = buttonsOf(cx, actions, maximized) },
            }),
        }) }) });
    }
};

/// What the window's buttons do, and what pressing its title bar does: null
/// where the window cannot.
const Actions = struct {
    minimize: ?widget.Callback = null,
    maximize: ?widget.Callback = null,
    close: ?widget.Callback = null,
    drag: ?widget.Callback = null,
};

/// What `given` says, or else what the window's controls do (if it can).
fn actionsOf(cx: *Context, given: Actions) Actions {
    const controls = cx.ui.controls;
    const win = cx.ui.win;
    const can_minimize = if (win) |w| w.canMinimize() else false;
    const can_maximize = if (win) |w| w.canMaximize() else true;
    return .{
        .minimize = given.minimize orelse if (controls) |c| (if (can_minimize) widget.Callback.of(c, WindowControls.minimize) else null) else null,
        .maximize = given.maximize orelse if (controls) |c| (if (can_maximize) widget.Callback.of(c, WindowControls.toggleMaximized) else null) else null,
        .close = given.close orelse if (controls) |c| widget.Callback.of(c, WindowControls.close) else null,
        .drag = given.drag orelse if (controls) |c| widget.Callback.of(c, WindowControls.drag) else null,
    };
}

/// The buttons for what `actions` has, left to right.
fn buttonsOf(cx: *Context, actions: Actions, maximized: bool) []const Widget {
    const buttons = cx.arena.alloc(Widget, 3) catch return &.{};
    var n: usize = 0;
    if (actions.minimize) |f| {
        buttons[n] = cx.make(BarButton{ .on_press = f, .size = TitleBar.button_size, .icon = .minimize });
        n += 1;
    }
    if (actions.maximize) |f| {
        // A square fills the screen; two, one behind the other, go back
        // to the window's own size.
        buttons[n] = cx.make(BarButton{ .on_press = f, .size = TitleBar.button_size, .icon = if (maximized) .filter_none else .crop_square });
        n += 1;
    }
    if (actions.close) |f| {
        buttons[n] = cx.make(BarButton{ .on_press = f, .size = TitleBar.button_size, .icon = .close });
        n += 1;
    }
    return buttons[0..n];
}

/// The window's buttons on their own, in the top right corner over what the
/// app draws (see `WindowUi.cutouts`): for a window whose content is in its
/// title bar. The buttons have no background, as the system's have.
pub const TitleBarControls = struct {
    pub fn build(_: *const TitleBarControls, cx: *Context) Widget {
        if (cx.ui.fullscreen) return cx.make(@import("sized_box.zig").SizedBox.empty);
        const buttons = buttonsOf(cx, actionsOf(cx, .{}), cx.ui.maximized);
        const room = (TitleBar.height - TitleBar.button_size) / 2;
        return cx.make(Padding{
            .padding = .{ .top = room, .bottom = room, .right = TitleBar.margin },
            .child = cx.make(Row{ .spacing = TitleBar.spacing, .fill = false, .children = buttons }),
        });
    }
};

/// Where pressing the left button starts moving the window, and a double
/// click maximizes it (or takes it back): the app's own title bar, or the
/// part of it that is not a button or the like, for a window whose content
/// is in its title bar.
pub const WindowDragArea = struct {
    /// What is in it.
    child: ?Widget = null,

    pub fn build(self: *const WindowDragArea, cx: *Context) Widget {
        const actions = actionsOf(cx, .{});
        return cx.make(DragArea{ .on_drag = actions.drag, .on_maximize = actions.maximize, .child = self.child });
    }
};

/// The title and the buttons: the buttons at the right end, and the title
/// in the middle of the bar, or as near it as it can be left of the buttons.
/// What does not fit ends in "…".
const Bar = struct {
    title: []const u8,
    /// The title's text, and the row of buttons.
    children: []const Widget,

    pub fn layout(_: *const Bar, n: *Node, c: Constraints) Size {
        const w = c.constrain(.{ .w = c.max_w, .h = TitleBar.height }).w;
        const h: f32 = TitleBar.height;
        const buttons = n.child(1);
        const bs = buttons.layout(.{ .max_w = w, .max_h = h });
        const buttons_x = w - TitleBar.margin - bs.w;
        buttons.place(buttons_x, (h - bs.h) / 2);
        const title = n.child(0);
        const end = (if (bs.w > 0) buttons_x else w) - TitleBar.margin;
        const ts = title.layout(.{ .max_w = @max(end - TitleBar.margin, 0), .max_h = h });
        const centred = (w - ts.w) / 2;
        title.place(@max(TitleBar.margin, @min(centred, end - ts.w)), @round((h - ts.h) / 2));
        return c.constrain(.{ .w = w, .h = h });
    }

    pub fn minSize(self: *const Bar, n: *Node, c: Constraints) Size {
        const buttons = n.child(1).minSize(.{});
        const title: f32 = if (n.ui.font) |f| n.ui.atlas.runs.measure(.{ .font = f, .size = n.theme().body_size }, self.title) else 0;
        const gap: f32 = if (buttons.w > 0) TitleBar.margin else 0;
        return c.constrain(.{ .w = TitleBar.margin + @ceil(@min(title, TitleBar.min_title_width)) + gap + buttons.w + TitleBar.margin, .h = TitleBar.height });
    }
};

/// Calls `on_drag` when pressed, and `on_maximize` instead on the second
/// click of a double click (the buttons on it get their presses first). It
/// does not take the pointer: the shell does, to move the window, so the
/// release never comes here.
const DragArea = struct {
    on_drag: ?widget.Callback,
    on_maximize: ?widget.Callback,
    child: ?Widget = null,

    pub fn event(self: *const DragArea, _: *Node, e: widget.Event) bool {
        switch (e) {
            .press => |p| if (p.button == .left) {
                const double = p.clicks % 2 == 0 and self.on_maximize != null;
                if (if (double) self.on_maximize else self.on_drag) |f| f.call();
            },
            else => {},
        }
        return false;
    }
};

const testing = std.testing;

test "the title bar's buttons, and dragging it" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const font = @import("font");
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const App = struct {
        closed: bool = false,
        drags: u32 = 0,
        maximizes: u32 = 0,
        fn close(a: *@This()) void {
            a.closed = true;
        }
        fn drag(a: *@This()) void {
            a.drags += 1;
        }
        fn maximize(a: *@This()) void {
            a.maximizes += 1;
        }
    };
    var app: App = .{};
    u.frame(800, 600, 0, Column{ .cross_axis_alignment = .stretch, .children = &.{} });
    const Root = struct {
        app: *App,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(Column{ .cross_axis_alignment = .stretch, .children = cx.makeAll(.{
                TitleBar{ .title = "Settings", .on_close = .of(self.app, App.close), .on_maximize = .of(self.app, App.maximize), .on_drag = .of(self.app, App.drag) },
            }) });
        }
    };
    u.frame(800, 600, 0, Root{ .app = &app });
    // The bar is across the top, 44 high; the button at its right end.
    const at: geometry.Point = .{ 800 - 8 - 17, 22 };
    u.pointerMotion(at);
    u.pointerButton(at, .left, true);
    u.pointerButton(at, .left, false);
    try testing.expect(app.closed);
    // Elsewhere on the bar starts a drag (and closes nothing).
    app.closed = false;
    u.pointerMotion(.{ 400, 22 });
    u.pointerButton(.{ 400, 22 }, .left, true);
    try testing.expect(!app.closed);
    try testing.expectEqual(@as(u32, 1), app.drags);
    // The shell takes the pointer for the drag, so no release comes; the
    // next press still works. The maximize button is left of the close
    // button.
    const max_at: geometry.Point = .{ 800 - 8 - 34 - 4 - 17, 22 };
    u.pointerMotion(max_at);
    u.pointerButton(max_at, .left, true);
    u.pointerButton(max_at, .left, false);
    try testing.expectEqual(@as(u32, 1), app.maximizes);
    try testing.expectEqual(@as(u32, 1), app.drags);
}

test "double clicking the title bar toggles maximize, instead of dragging" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const font = @import("font");
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const App = struct {
        drags: u32 = 0,
        maximizes: u32 = 0,
        fn drag(a: *@This()) void {
            a.drags += 1;
        }
        fn maximize(a: *@This()) void {
            a.maximizes += 1;
        }
    };
    var app: App = .{};
    const Root = struct {
        app: *App,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(Column{ .cross_axis_alignment = .stretch, .children = cx.makeAll(.{
                TitleBar{ .title = "Settings", .on_maximize = .of(self.app, App.maximize), .on_drag = .of(self.app, App.drag) },
            }) });
        }
    };
    u.frame(800, 600, 0, Root{ .app = &app });
    const ms = std.time.ns_per_ms;
    const at: geometry.Point = .{ 400, 22 };
    u.pointerMotion(at);
    // The first press drags; the shell takes the pointer, so no release
    // comes. The second, soon after, maximizes.
    u.pointerButtonAt(at, .left, true, 1000 * ms);
    u.pointerButtonAt(at, .left, true, 1200 * ms);
    try testing.expectEqual(@as(u32, 1), app.drags);
    try testing.expectEqual(@as(u32, 1), app.maximizes);
    // A third drags again, and a fourth restores.
    u.pointerButtonAt(at, .left, true, 1400 * ms);
    u.pointerButtonAt(at, .left, true, 1600 * ms);
    try testing.expectEqual(@as(u32, 2), app.drags);
    try testing.expectEqual(@as(u32, 2), app.maximizes);
    // Presses too slow, or too far apart, are separate clicks.
    u.pointerButtonAt(at, .left, true, 3000 * ms);
    u.pointerButtonAt(at, .left, true, 3000 * ms + WindowUi.multi_click_ns + 1);
    const away: geometry.Point = .{ 400 + WindowUi.multi_click_slop + 1, 22 };
    u.pointerMotion(away);
    u.pointerButtonAt(away, .left, true, 3000 * ms + WindowUi.multi_click_ns + 100 * ms);
    try testing.expectEqual(@as(u32, 5), app.drags);
    try testing.expectEqual(@as(u32, 2), app.maximizes);
}

test "a fullscreen window has no title bar" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const font = @import("font");
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var closed = false;
    const Root = struct {
        closed: *bool,
        fn close(b: *bool) void {
            b.* = true;
        }
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(Column{ .cross_axis_alignment = .stretch, .children = cx.makeAll(.{
                TitleBar{ .title = "Settings", .on_close = .of(self.closed, close) },
            }) });
        }
    };
    u.fullscreen = true;
    u.frame(800, 600, 0, Root{ .closed = &closed });
    // Where its close button would be, there is nothing to press.
    const at: geometry.Point = .{ 800 - 8 - 17, 22 };
    u.pointerMotion(at);
    u.pointerButton(at, .left, true);
    u.pointerButton(at, .left, false);
    try testing.expect(!closed);
    // Out of fullscreen, it is back.
    u.fullscreen = false;
    u.frame(800, 600, 1, Root{ .closed = &closed });
    u.pointerMotion(at);
    u.pointerButton(at, .left, true);
    u.pointerButton(at, .left, false);
    try testing.expect(closed);
}

test "the title bar defaults to the UI's window controls" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const font = @import("font");
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var controls: WindowControls = .{ .win = undefined };
    u.controls = &controls;
    const Root = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(Column{ .cross_axis_alignment = .stretch, .children = cx.makeAll(.{
                TitleBar{ .title = "Settings" },
            }) });
        }
    };
    u.frame(800, 600, 0, Root{});
    const at: geometry.Point = .{ 800 - 8 - 17, 22 };
    u.pointerMotion(at);
    u.pointerButton(at, .left, true);
    u.pointerButton(at, .left, false);
    try testing.expect(controls.close_requested);
}

test "WindowUi automatically adds TitleBar when the toolkit draws the decorations and omits it when the system does" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const window_mod = @import("window");
    const font = @import("font");
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    const MockWaylandWin = struct {
        pub const platform: window_mod.WindowPlatform = .wayland;
        pub const buffer_transport: window_mod.WindowBufferTransport = .memory;
        title: []const u8 = "Kete Test",
        decorations: window_mod.WindowDecorations = .toolkit,
        width: u32 = 800,
        height: u32 = 600,
    };
    var mock_win: MockWaylandWin = .{};
    var controls: WindowControls = .init(&mock_win);
    u.attachWindow(&mock_win, &controls);

    const Root = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(SizedBox{ .width = 200, .height = 100 });
        }
    };

    // With the toolkit drawing the decorations, TitleBar is added automatically above root.
    u.frame(800, 600, 0, Root{});
    try testing.expect(u.title_bar_root != null);
    try testing.expectEqual(@as(f32, TitleBar.height), u.root.?.offset[1]);
    try testing.expectEqual(@as(f32, 600 - TitleBar.height), u.root.?.size.h);
    try testing.expectEqual(window_mod.WindowDecorations.toolkit, u.decorations);

    // Clicking the automatic title bar's close button triggers controls.close_requested.
    const at: geometry.Point = .{ 800 - 8 - 17, 22 };
    u.pointerMotion(at);
    u.pointerButton(at, .left, true);
    u.pointerButton(at, .left, false);
    try testing.expect(controls.close_requested);

    // When the system draws the decorations, TitleBar is not added.
    controls.close_requested = false;
    mock_win.decorations = .system;
    u.syncWindow(&mock_win);
    u.frame(800, 600, 1, Root{});
    try testing.expect(u.title_bar_root == null);
    try testing.expectEqual(@as(f32, 0), u.root.?.offset[1]);
    try testing.expectEqual(@as(f32, 600), u.root.?.size.h);
    try testing.expectEqual(window_mod.WindowDecorations.system, u.decorations);
}

test "a window whose content is in its title bar has the buttons over it, reported as a cutout" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const window_mod = @import("window");
    const font = @import("font");
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    const MockWaylandWin = struct {
        pub const platform: window_mod.WindowPlatform = .wayland;
        pub const buffer_transport: window_mod.WindowBufferTransport = .memory;
        title: []const u8 = "Kete Test",
        decorations: window_mod.WindowDecorations = .toolkit,
        width: u32 = 800,
        height: u32 = 600,
    };
    var mock_win: MockWaylandWin = .{};
    var controls: WindowControls = .init(&mock_win);
    u.attachWindow(&mock_win, &controls);
    u.content_in_title_bar = true;

    const Root = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(SizedBox{ .width = 200, .height = 100 });
        }
    };

    // The content fills the window: nothing is above it, and the buttons
    // are in the corner, where the window says they are.
    u.frame(800, 600, 0, Root{});
    try testing.expect(u.title_bar_root != null);
    try testing.expectEqual(@as(f32, 0), u.root.?.offset[1]);
    try testing.expectEqual(@as(f32, 600), u.root.?.size.h);
    try testing.expect(u.hasControlsOverlay());
    const cut = u.cutouts();
    try testing.expectEqual(@as(usize, 1), cut.len);
    try testing.expectEqual(@as(f32, 0), cut[0].y);
    try testing.expectEqual(@as(f32, 800), cut[0].x + cut[0].w);
    try testing.expectEqual(@as(f32, TitleBar.height), cut[0].h);

    // The close button is in it, and does what the system's does.
    const at: geometry.Point = .{ 800 - 8 - 17, 22 };
    u.pointerMotion(at);
    u.pointerButton(at, .left, true);
    u.pointerButton(at, .left, false);
    try testing.expect(controls.close_requested);

    // Where the system draws the decorations, the content is not under them.
    controls.close_requested = false;
    mock_win.decorations = .system;
    u.syncWindow(&mock_win);
    u.frame(800, 600, 1, Root{});
    try testing.expect(u.title_bar_root == null);
    try testing.expect(!u.hasControlsOverlay());
    try testing.expectEqual(@as(usize, 0), u.cutouts().len);
}

test "the parts a window system draws over the content are reported, as the toolkit's buttons are" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const window_mod = @import("window");
    const font = @import("font");
    const f = try font.Font.init(font.default_font_data);
    const u = try WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    // A window like macOS's: its system draws the decorations, and its buttons
    // are over the content, in the top left corner.
    const MockMacWin = struct {
        pub const platform: window_mod.WindowPlatform = .macos;
        pub const buffer_transport: window_mod.WindowBufferTransport = .memory;
        pub const decorations: window_mod.WindowDecorations = .system;
        title: []const u8 = "Kete Test",
        width: u32 = 800,
        height: u32 = 600,
        buttons: bool = true,
        pub fn cutouts(self: *const @This(), out: *[window_mod.max_cutouts]geometry.Rect) usize {
            if (!self.buttons) return 0;
            out[0] = .{ .x = 8, .y = 6, .w = 60, .h = 20 };
            return 1;
        }
    };
    var mock_win: MockMacWin = .{};
    u.attachWindow(&mock_win, null);
    const Root = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(SizedBox{ .width = 200, .height = 100 });
        }
    };
    u.frame(800, 600, 0, Root{});
    try testing.expect(u.title_bar_root == null);
    try testing.expectEqual(@as(usize, 1), u.cutouts().len);
    try testing.expectEqual(@as(f32, 60), u.cutouts()[0].w);
    // The root fills the window: the title bar is the system's, and not the toolkit's.
    try testing.expectEqual(@as(f32, 600), u.root.?.size.h);

    // In fullscreen they are gone.
    mock_win.buttons = false;
    u.frame(800, 600, 1, Root{});
    try testing.expectEqual(@as(usize, 0), u.cutouts().len);
}

fn findText(n: *Node) ?*Node {
    if (n.widget.is(Text)) return n;
    for (n.children.items) |ch| if (findText(ch)) |t| return t;
    return null;
}

test "a long title ends in an ellipsis before the buttons, and the bar sets the window's minimum width" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const window_mod = @import("window");
    const u = try WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();

    const MockWin = struct {
        pub const platform: window_mod.WindowPlatform = .wayland;
        title: []const u8 = "A very long window title that cannot possibly fit in a narrow window",
        decorations: window_mod.WindowDecorations = .toolkit,
        width: u32 = 300,
        height: u32 = 200,
        min_size: [2]u32 = .{ 0, 0 },
        minimized: u32 = 0,
        pub fn setMaximized(_: *@This(), _: bool) void {}
        pub fn setMinimized(self: *@This()) void {
            self.minimized += 1;
        }
        pub fn setMinSize(self: *@This(), w: u32, h: u32) void {
            self.min_size = .{ w, h };
        }
    };
    var win: MockWin = .{};
    var controls: WindowControls = .init(&win);
    u.attachWindow(&win, &controls);
    u.maximized = false;
    const Root = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(SizedBox{ .width = 10, .height = 10 });
        }
    };
    u.frame(win.width, win.height, 0, Root{});
    const bar = u.title_bar_root.?;
    const text = findText(bar).?;
    // In the app's text size, not a heading's.
    try testing.expect(text.size.h < 22);
    // Ellipsized, ending before the first (minimize) button, which is
    // three buttons from the right end.
    const text_right = text.position()[0] + text.size.w;
    const first_button = @as(f32, @floatFromInt(win.width)) - TitleBar.margin - 3 * TitleBar.button_size - 2 * TitleBar.spacing;
    try testing.expect(text_right <= first_button - TitleBar.margin);
    try testing.expect(!text.overflow.any());
    // The window is never too narrow for the buttons and the start of the
    // title.
    const buttons = 3 * TitleBar.button_size + 2 * TitleBar.spacing;
    try testing.expectEqual(@as(u32, 3 * TitleBar.margin + TitleBar.min_title_width + buttons), win.min_size[0]);

    // The first button minimizes.
    const at: geometry.Point = .{ first_button + TitleBar.button_size / 2, TitleBar.height / 2 };
    u.pointerMotion(at);
    u.pointerButton(at, .left, true);
    u.pointerButton(at, .left, false);
    try testing.expectEqual(@as(u32, 1), win.minimized);

    // So the title is never squeezed to less than that.
    u.frame(win.min_size[0], win.height, 1, Root{});
    try testing.expect(findText(u.title_bar_root.?).?.size.w > TitleBar.min_title_width - 20);
}

test "a window that cannot be minimized has no minimize button" {
    const WindowUi = @import("runtime.zig").WindowUi;
    const window_mod = @import("window");
    const u = try WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    const MockWin = struct {
        pub const platform: window_mod.WindowPlatform = .wayland;
        title: []const u8 = "Title",
        decorations: window_mod.WindowDecorations = .toolkit,
        width: u32 = 400,
        height: u32 = 200,
        pub fn setMaximized(_: *@This(), _: bool) void {}
        pub fn setMinimized(_: *@This()) void {}
        pub fn canMinimize(_: *const @This()) bool {
            return false;
        }
    };
    var win: MockWin = .{};
    var controls: WindowControls = .init(&win);
    u.attachWindow(&win, &controls);
    u.frame(win.width, win.height, 0, SizedBox{ .width = 10, .height = 10 });
    var buttons: usize = 0;
    const count = struct {
        fn f(n: *Node, out: *usize) void {
            if (n.widget.is(BarButton)) out.* += 1;
            for (n.children.items) |ch| f(ch, out);
        }
    }.f;
    count(u.title_bar_root.?, &buttons);
    // Maximize and close.
    try testing.expectEqual(@as(usize, 2), buttons);
}
