//! Tests of the toolkit: layouts (sensible and not), state, input, and
//! what is painted (drawn on the CPU with the real shaders).

const std = @import("std");
const builtin = @import("builtin");
const gfx = @import("gfx");
const font = @import("font");
const window = @import("window");
const ui = @import("ui.zig");

const testing = std.testing;
const Widget = ui.Widget;
const Context = ui.BuildContext;
const Node = ui.WidgetNode;

const fira_data = font.default_font_data;

/// The first node (depth first) whose widget is a `T`.
fn find(n: *Node, comptime T: type) ?*Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (find(ch, T)) |f| return f;
    return null;
}

fn findAll(n: *Node, comptime T: type, out: *std.ArrayList(*Node)) !void {
    if (n.widget.is(T)) try out.append(testing.allocator, n);
    for (n.children.items) |ch| try findAll(ch, T, out);
}

const Image = struct {
    pixels: []u32,
    img: gfx.software.Image,

    fn init(u: *ui.WindowUi, w: u32, h: u32) !Image {
        const pixels = try testing.allocator.alloc(u32, w * h);
        @memset(pixels, 0xff000000);
        const img: gfx.software.Image = .{ .pixels = pixels, .width = w, .height = h };
        try u.preview(img);
        return .{ .pixels = pixels, .img = img };
    }

    fn deinit(i: Image) void {
        testing.allocator.free(i.pixels);
    }

    fn at(i: Image, x: u32, y: u32) u32 {
        return i.img.at(x, y);
    }
};

fn channels(px: u32) [3]u8 {
    return .{ @truncate(px >> 16), @truncate(px >> 8), @truncate(px) };
}

fn isYellow(px: u32) bool {
    const c = channels(px);
    return c[0] > 150 and c[1] > 150 and c[2] < 100;
}

const red = gfx.Color.rgb(0xff0000);
const blue = gfx.Color.rgb(0x0000ff);

/// A root made by a function, for tests.
fn Root(comptime f: fn (*Context) Widget) type {
    return struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return f(cx);
        }
    };
}

test "an overflowing row is clipped, and striped along the edge it overflows" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 100, .height = 40, .child = cx.make(ui.Row{ .children = cx.makeAll(.{
                ui.SizedBox{ .width = 80, .child = cx.make(ui.RoundedBox{ .color = red }) },
                ui.SizedBox{ .width = 80, .child = cx.make(ui.RoundedBox{ .color = blue }) },
            }) }) }) });
        }
    }.f;
    u.frame(200, 60, 0, Root(build){});
    const row = find(u.root.?, ui.Row).?;
    try testing.expectEqual(@as(f32, 60), row.overflow.right);
    try testing.expectEqual(@as(f32, 0), row.overflow.bottom);
    const img = try Image.init(u, 200, 60);
    defer img.deinit();
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(40, 20));
    try testing.expectEqual(@as(u32, 0xff0000ff), img.at(85, 20));
    // The stripes along the right edge: some yellow there, none before.
    var yellow: u32 = 0;
    for (0..40) |y| for (92..100) |x| {
        yellow += @intFromBool(isYellow(img.at(@intCast(x), @intCast(y))));
    };
    try testing.expect(yellow > 40);
    // Nothing past the row.
    for (0..60) |y| try testing.expectEqual(@as(u32, 0xff000000), img.at(120, @intCast(y)));
    for (0..200) |x| try testing.expectEqual(@as(u32, 0xff000000), img.at(@intCast(x), 50));
}

/// A widget whose layout returns nonsense.
const Nonsense = struct {
    pub fn layout(_: *const Nonsense, _: *Node, _: ui.Constraints) ui.Size {
        return .{ .w = std.math.nan(f32), .h = -std.math.inf(f32) };
    }
};

test "layouts that make no sense still lay out" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Column{
                .children = cx.makeAll(.{
                    // A column in a column: unbounded height, where Expanded
                    // has no space to share.
                    cx.make(ui.Column{ .children = cx.makeAll(.{
                        ui.Expanded{ .child = cx.make(ui.Text{ .text = "Expanded in unbounded space" }) },
                        Nonsense{},
                    }) }),
                    // A row in a row: unbounded width.
                    cx.make(ui.Row{ .children = cx.makeAll(.{ui.Row{ .children = cx.makeAll(.{ui.Text{ .text = "Row in a row" }}) }}) }),
                    ui.SizedBox{ .width = -5, .height = std.math.nan(f32) },
                    ui.Padding{ .padding = .all(1000), .child = cx.make(ui.Text{ .text = "Padded away" }) },
                    ui.Align.center(cx.make(ui.Overlay{})),
                }),
            });
        }
    }.f;
    u.frame(300, 200, 0, Root(build){});
    // Everything got a finite size, and the column says it overflows.
    const Check = struct {
        fn all(n: *Node) !void {
            try testing.expect(std.math.isFinite(n.size.w) and n.size.w >= 0);
            try testing.expect(std.math.isFinite(n.size.h) and n.size.h >= 0);
            for (n.children.items) |ch| try all(ch);
        }
    };
    try Check.all(u.root.?);
    try testing.expect(u.root.?.child(0).overflow.bottom > 0);
    const img = try Image.init(u, 300, 200);
    img.deinit();
}

const Counter = struct {
    pub const State = struct {
        count: u32 = 0,
        fn add(s: *State) void {
            s.count += 1;
        }
    };

    pub fn build(_: *const Counter, cx: *Context, state: *State) Widget {
        return cx.make(ui.Column{ .children = cx.makeAll(.{
            ui.Text{ .text = cx.fmt("Count {d}", .{state.count}) },
            ui.OutlinedButton{ .label = "Add", .on_press = .of(state, State.add) },
            ui.OutlinedButton{ .label = "Disabled" },
        }) });
    }
};

fn click(u: *ui.WindowUi, n: *Node) void {
    const at = n.position();
    const p: ui.Point = .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, .left, true);
    u.pointerButton(p, .left, false);
}

test "buttons call back, state lasts between frames, and hovering tints" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    u.frame(300, 200, 0, Counter{});
    var buttons: std.ArrayList(*Node) = .empty;
    defer buttons.deinit(testing.allocator);
    try findAll(u.root.?, ui.OutlinedButton, &buttons);
    try testing.expectEqual(@as(usize, 2), buttons.items.len);
    // Material's size, centred in the column.
    try testing.expectEqual(@as(f32, 40), buttons.items[0].size.h);

    click(u, buttons.items[0]);
    click(u, buttons.items[0]);
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);
    u.frame(300, 200, 1, Counter{});
    try testing.expectEqualStrings("Count 2", find(u.root.?, ui.Text).?.widget.as(ui.Text).?.text);
    // Still over the button: tinted.
    try testing.expect(find(buttons.items[0], ui.RoundedBox).?.widget.as(ui.RoundedBox).?.color != null);

    // The disabled button does nothing, and is not tinted.
    click(u, buttons.items[1]);
    u.frame(300, 200, 2, Counter{});
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);
    try testing.expect(find(buttons.items[1], ui.RoundedBox).?.widget.as(ui.RoundedBox).?.color == null);

    // Pressing, moving off and releasing is not a click.
    const b = buttons.items[0];
    const at = b.position();
    u.pointerMotion(.{ at[0] + 5, at[1] + 20 });
    u.pointerButton(.{ at[0] + 5, at[1] + 20 }, .left, true);
    u.pointerMotion(.{ 299, 199 });
    u.pointerButton(.{ 299, 199 }, .left, false);
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);

    // Another button going up while the left is held is not a click; the
    // left going up is.
    const over: ui.Point = .{ at[0] + 5, at[1] + 20 };
    u.pointerMotion(over);
    u.pointerButton(over, .left, true);
    u.pointerButton(over, .right, true);
    u.pointerButton(over, .right, false);
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);
    u.pointerButton(over, .left, false);
    try testing.expectEqual(@as(u32, 3), u.root.?.state(Counter.State).count);
}

var freed: u32 = 0;

const Keeper = struct {
    id: u32,
    pub const State = struct {
        id: u32,
        pub fn deinit(_: *State) void {
            freed += 1;
        }
    };
    pub fn initState(self: *const Keeper) State {
        return .{ .id = self.id };
    }
    pub fn build(_: *const Keeper, cx: *Context, _: *State) Widget {
        return cx.make(ui.SizedBox{ .width = 10, .height = 10 });
    }
};

const Keepers = struct {
    ids: []const u32,
    pub fn build(self: *const Keepers, cx: *Context) Widget {
        var children = cx.arena.alloc(Widget, self.ids.len) catch return cx.make(ui.SizedBox.empty);
        for (self.ids, 0..) |id, i| children[i] = cx.make(Keeper{ .id = id }).withKey(id);
        return cx.make(ui.Column{ .children = children });
    }
};

test "keys keep state when siblings come and go, and dropped state is freed" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    freed = 0;
    u.frame(100, 100, 0, Keepers{ .ids = &.{ 1, 2, 3 } });
    u.frame(100, 100, 0, Keepers{ .ids = &.{ 3, 1 } });
    var keepers: std.ArrayList(*Node) = .empty;
    defer keepers.deinit(testing.allocator);
    try findAll(u.root.?, Keeper, &keepers);
    try testing.expectEqual(@as(u32, 3), keepers.items[0].state(Keeper.State).id);
    try testing.expectEqual(@as(u32, 1), keepers.items[1].state(Keeper.State).id);
    try testing.expectEqual(@as(u32, 1), freed);
    u.destroy();
    try testing.expectEqual(@as(u32, 3), freed);
}

test "unkeyed siblings keep their state when a different widget is inserted before them" {
    // Regression test: inserting a widget of a different type at position 0
    // must not cause unkeyed same-type siblings at positions 1+ to steal each
    // other's state.
    const UnkeyedKeepers = struct {
        show_extra: bool,
        ids: []const u32,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            const n = self.ids.len + @intFromBool(self.show_extra);
            var children = cx.arena.alloc(Widget, n) catch return cx.make(ui.SizedBox.empty);
            var at: usize = 0;
            // When show_extra=true put a Counter (different vtable) at front.
            if (self.show_extra) {
                children[at] = cx.make(Counter{});
                at += 1;
            }
            for (self.ids) |id| {
                // No withKey: these are unkeyed.
                children[at] = cx.make(Keeper{ .id = id });
                at += 1;
            }
            return cx.make(ui.Column{ .children = children });
        }
    };
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    freed = 0;
    // Frame 1: [Keeper(1), Keeper(2)] — initialises state with ids 1 and 2.
    u.frame(100, 100, 0, UnkeyedKeepers{ .show_extra = false, .ids = &.{ 1, 2 } });
    // Frame 2: [Counter, Keeper(1), Keeper(2)] — Counter has a different vtable
    // so the two Keepers must still match their original nodes (id=1, id=2),
    // not shift-match (id=2, fresh).
    u.frame(100, 100, 1, UnkeyedKeepers{ .show_extra = true, .ids = &.{ 1, 2 } });
    var keepers: std.ArrayList(*Node) = .empty;
    defer keepers.deinit(testing.allocator);
    try findAll(u.root.?, Keeper, &keepers);
    try testing.expectEqual(@as(usize, 2), keepers.items.len);
    try testing.expectEqual(@as(u32, 1), keepers.items[0].state(Keeper.State).id);
    try testing.expectEqual(@as(u32, 2), keepers.items[1].state(Keeper.State).id);
    // The Counter node is new — the two Keepers are reused, none freed yet.
    try testing.expectEqual(@as(u32, 0), freed);
}

test "text wraps to fit, and a word that cannot is marked" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{
                .width = 70,
                .child = cx.make(ui.Text{ .text = "Some words then Supercalifragilistic", .style = .{ .size = 14 } }),
            }) });
        }
    }.f;
    u.frame(200, 200, 0, Root(build){});
    const t = find(u.root.?, ui.Text).?;
    const line = (font.Style{ .font = &fira, .size = 14 }).lineHeight();
    try testing.expect(t.size.h > 2.5 * line);
    try testing.expect(t.overflow.right > 0);
    const img = try Image.init(u, 200, 200);
    defer img.deinit();
    // Text was drawn.
    var lit: u32 = 0;
    for (img.pixels) |px| lit += @intFromBool(channels(px)[2] > 128);
    try testing.expect(lit > 50);
}

test "an overlay's top layer takes the pointer where it has something" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    const S = struct {
        var below: u32 = 0;
        var above: u32 = 0;
        fn addBelow(_: *const u8) void {
            below += 1;
        }
        fn addAbove(_: *const u8) void {
            above += 1;
        }
        const token: u8 = 0;
        fn f(cx: *Context) Widget {
            return cx.make(ui.Overlay{ .children = cx.makeAll(.{
                ui.Pressable{ .on_press = .of(&token, addBelow) },
                ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 50, .height = 50, .child = cx.make(ui.Pressable{ .on_press = .of(&token, addAbove) }) }) },
            }) });
        }
    };
    u.frame(200, 200, 0, Root(S.f){});
    for ([_]ui.Point{ .{ 10, 10 }, .{ 100, 100 }, .{ 20, 40 } }) |p| {
        u.pointerMotion(p);
        u.pointerButton(p, .left, true);
        u.pointerButton(p, .left, false);
    }
    try testing.expectEqual(@as(u32, 2), S.above);
    try testing.expectEqual(@as(u32, 1), S.below);
}

/// Draws straight to the GPU.
const GpuView = struct {
    fn draw(_: *const GpuView, _: *anyopaque, _: gfx.GpuArea) anyerror!void {}
    pub fn paint(self: *const GpuView, _: *Node, p: *ui.Painter) void {
        p.gpu(self, draw);
    }
};

test "GPU draws go between the 2D layers, in the tree's order" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Overlay{ .children = cx.makeAll(.{
                ui.RoundedBox{ .color = red },
                ui.Padding{ .padding = .all(10), .child = cx.make(GpuView{}) },
                ui.Align.center(cx.make(ui.Text{ .text = "Over" })),
            }) });
        }
    }.f;
    u.frame(200, 100, 0, Root(build){});
    const segs = u.segments.items;
    try testing.expectEqual(@as(usize, 3), segs.len);
    try testing.expect(segs[0] == .canvas and segs[1] == .gpu and segs[2] == .canvas);
    try testing.expectEqual(gfx.Viewport{ .x = 10, .y = 10, .width = 180, .height = 80 }, segs[1].gpu.area.viewport);
    try testing.expect(segs[1].gpu.area.scissor == null);
}

test "rows and columns align and space their children" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Column{ .children = cx.makeAll(.{
                ui.Row{ .main_axis_alignment = .center, .spacing = 10, .children = cx.makeAll(.{
                    ui.SizedBox{ .width = 20, .height = 10 },
                    ui.SizedBox{ .width = 30, .height = 20 },
                }) },
                ui.Row{ .main_axis_alignment = .space_between, .cross_axis_alignment = .end, .children = cx.makeAll(.{
                    ui.SizedBox{ .width = 20, .height = 10 },
                    ui.Expanded{ .child = cx.make(ui.SizedBox{ .height = 5 }) },
                    ui.SizedBox{ .width = 30, .height = 20 },
                }) },
            }) });
        }
    }.f;
    u.frame(200, 100, 0, Root(build){});
    const col = u.root.?.child(0);
    const r1 = col.child(0);
    // 20 + 10 + 30 = 60 wide, centred in 200; the small box centred
    // across.
    try testing.expectEqual(ui.Point{ 70, 5 }, r1.child(0).offset);
    try testing.expectEqual(ui.Point{ 100, 0 }, r1.child(1).offset);
    try testing.expectEqual(@as(f32, 20), r1.size.h);
    const r2 = col.child(1);
    try testing.expectEqual(@as(f32, 150), r2.child(1).size.w);
    try testing.expectEqual(ui.Point{ 170, 0 }, r2.child(2).offset);
    try testing.expectEqual(ui.Point{ 20, 15 }, r2.child(1).offset);
}

const Choice = enum { a, b, c };

const Controls = struct {
    pub const State = struct {
        checked: bool = false,
        on: bool = false,
        choice: Choice = .a,
        fn setChecked(s: *State, v: bool) void {
            s.checked = v;
        }
        fn setOn(s: *State, v: bool) void {
            s.on = v;
        }
        fn choose(s: *State, v: Choice) void {
            s.choice = v;
        }
    };

    pub fn build(_: *const Controls, cx: *Context, state: *State) Widget {
        return cx.make(ui.Column{ .cross_axis_alignment = .start, .children = cx.makeAll(.{
            ui.CheckboxRow{ .value = state.checked, .on_changed = .of(state, State.setChecked), .label = "Check" },
            ui.SwitchRow{ .value = state.on, .on_changed = .of(state, State.setOn), .label = "Switch" },
            ui.RadioRow(Choice){ .value = .a, .group_value = state.choice, .on_changed = .of(state, State.choose), .label = "A" },
            ui.RadioRow(Choice){ .value = .b, .group_value = state.choice, .on_changed = .of(state, State.choose), .label = "B" },
            ui.RadioRow(Choice){ .value = .c, .group_value = state.choice, .label = "C (disabled)" },
            ui.Checkbox{ .value = true },
        }) });
    }
};

fn clickAt(u: *ui.WindowUi, p: ui.Point) void {
    u.pointerMotion(p);
    u.pointerButton(p, .left, true);
    u.pointerButton(p, .left, false);
}

test "checkboxes, switches and radio buttons report changes, and their labels press them" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    u.frame(400, 400, 0, Controls{});
    var items: std.ArrayList(*Node) = .empty;
    defer items.deinit(testing.allocator);
    try findAll(u.root.?, ui.Pressable, &items);
    try testing.expectEqual(@as(usize, 6), items.items.len);
    for (items.items[0..5]) |n| try testing.expectEqual(@as(f32, 40), n.size.h);
    const st = u.root.?.state(Controls.State);

    // The box itself, then the label.
    click(u, find(items.items[0], ui.checkbox.CheckboxMark).?);
    try testing.expect(st.checked);
    u.frame(400, 400, 1, Controls{});
    const label = find(items.items[0], ui.Text).?;
    click(u, label);
    try testing.expect(!st.checked);
    u.frame(400, 400, 2, Controls{});

    // The switch slides over, asking for frames until it is there.
    click(u, items.items[1]);
    try testing.expect(st.on);
    u.frame(400, 400, 3, Controls{});
    try testing.expect(u.needs_frame);
    u.frame(400, 400, 3 + ui.Switch.travel_ns / 2, Controls{});
    const mark = find(items.items[1], ui.@"switch".SwitchMark).?.widget.as(ui.@"switch".SwitchMark).?;
    try testing.expect(mark.position > 0.3 and mark.position < 0.7);
    u.frame(400, 400, 3 + ui.Switch.travel_ns * 2, Controls{});
    try testing.expectEqual(@as(f32, 1), find(items.items[1], ui.@"switch".SwitchMark).?.widget.as(ui.@"switch".SwitchMark).?.position);
    u.frame(400, 400, 4 + ui.Switch.travel_ns * 2, Controls{});
    try testing.expect(!u.needs_frame);

    // Radio buttons: choosing B selects it; C is disabled.
    click(u, items.items[3]);
    try testing.expectEqual(Choice.b, st.choice);
    click(u, items.items[4]);
    try testing.expectEqual(Choice.b, st.choice);
    u.frame(400, 400, 5 + ui.Switch.travel_ns * 2, Controls{});
    try testing.expect(!find(items.items[2], ui.radio.RadioMark).?.widget.as(ui.radio.RadioMark).?.selected);
    try testing.expect(find(items.items[3], ui.radio.RadioMark).?.widget.as(ui.radio.RadioMark).?.selected);

    // A disabled checkbox ignores clicks (and draws without failing).
    click(u, items.items[5]);
    const img = try Image.init(u, 400, 400);
    img.deinit();
}

const Label = struct {
    text: []const u8,
    pub fn build(self: *const Label, cx: *Context) Widget {
        return cx.make(ui.Column{ .cross_axis_alignment = .start, .children = cx.makeAll(.{
            ui.Text{ .text = "Static title" },
            ui.Text{ .text = self.text },
            ui.OutlinedButton{ .label = "Button", .on_press = .of(&dummy_count, addDummy) },
        }) });
    }
};

var dummy_count: u32 = 0;
fn addDummy(c: *u32) void {
    c.* += 1;
}

fn within(r: ui.Rect, outer: ui.Rect) bool {
    return r.x >= outer.x and r.y >= outer.y and r.x + r.w <= outer.x + outer.w and r.y + r.h <= outer.y + outer.h;
}

test "only what changed is damaged" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    u.frame(300, 200, 0, Label{ .text = "One" });
    // The first frame: everything.
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 300, .h = 200 }, u.damaged()[0]);
    // The same again: nothing.
    u.frame(300, 200, 1, Label{ .text = "One" });
    try testing.expect(!u.changed());
    try testing.expect(u.repaint(1).isEmpty());

    // New text: only around it.
    u.frame(300, 200, 2, Label{ .text = "Two" });
    try testing.expect(u.changed());
    var texts: std.ArrayList(*Node) = .empty;
    defer texts.deinit(testing.allocator);
    try findAll(u.root.?, ui.Text, &texts);
    const second = texts.items[1];
    const at = second.position();
    // Glyphs can reach an em around the text's box.
    const near: ui.Rect = .{ .x = at[0] - 20, .y = at[1] - 30, .w = second.size.w + 60, .h = second.size.h + 50 };
    for (u.damaged()) |r| try testing.expect(within(r, near));
    const first = texts.items[0];
    for (u.damaged()) |r| try testing.expect(r.y > first.position()[1]);

    // Hovering the button: only the button.
    const button = find(u.root.?, ui.OutlinedButton).?;
    const b = button.position();
    u.pointerMotion(.{ b[0] + 10, b[1] + 10 });
    u.frame(300, 200, 3, Label{ .text = "Two" });
    const box: ui.Rect = .{ .x = b[0] - 2, .y = b[1] - 2, .w = button.size.w + 4, .h = button.size.h + 4 };
    try testing.expect(u.changed());
    for (u.damaged()) |r| try testing.expect(within(r, box));
    // The buffer from two frames ago also needs the text's change.
    try testing.expect(u.repaint(2).len >= 1);
    var covers_text = false;
    for (u.repaint(2).slice()) |r| covers_text = covers_text or r.intersects(.{ .x = at[0], .y = at[1], .w = second.size.w, .h = second.size.h });
    try testing.expect(covers_text);
}

const Maybe = struct {
    show: bool,
    pub fn build(self: *const Maybe, cx: *Context) Widget {
        return cx.make(ui.Column{ .children = if (self.show) cx.makeAll(.{
            ui.SizedBox{ .width = 50, .height = 20, .child = cx.make(ui.RoundedBox{ .color = red }) },
        }) else &.{} });
    }
};

test "a removed widget damages where it was" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    u.frame(200, 100, 0, Maybe{ .show = true });
    u.frame(200, 100, 1, Maybe{ .show = true });
    try testing.expect(!u.changed());
    u.frame(200, 100, 2, Maybe{ .show = false });
    try testing.expect(u.changed());
    for (u.damaged()) |r| try testing.expect(within(r, .{ .x = 74, .y = 0, .w = 52, .h = 22 }));
}

const Keyed = struct {
    key: ?u64,
    fn draw(_: *const Keyed, _: *anyopaque, _: gfx.GpuArea) anyerror!void {}
    pub fn paint(self: *const Keyed, _: *Node, p: *ui.Painter) void {
        p.gpuWith(.{ .key = self.key, .bounds = .{ .x = 10, .y = 10, .w = 20, .h = 20 } }, self, draw);
    }
};

test "GPU draws are damaged every frame, unless their key stays the same" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    u.frame(100, 100, 0, Keyed{ .key = null });
    u.frame(100, 100, 1, Keyed{ .key = null });
    try testing.expectEqual(ui.Rect{ .x = 10, .y = 10, .w = 20, .h = 20 }, u.damaged()[0]);
    u.frame(100, 100, 2, Keyed{ .key = 7 });
    u.frame(100, 100, 3, Keyed{ .key = 7 });
    try testing.expect(!u.changed());
    u.frame(100, 100, 4, Keyed{ .key = 8 });
    try testing.expectEqual(ui.Rect{ .x = 10, .y = 10, .w = 20, .h = 20 }, u.damaged()[0]);
}

test "a grid puts as many cells in a row as fit" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            var cells: [7]Widget = undefined;
            for (&cells) |*c| c.* = cx.make(ui.RoundedBox{ .color = red });
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 250, .child = cx.make(ui.Grid.fixed(cx, &cells, .{ .w = 60, .h = 40 }, 10)) }) });
        }
    }.f;
    u.frame(400, 300, 0, Root(build){});
    var cells: std.ArrayList(*Node) = .empty;
    defer cells.deinit(testing.allocator);
    try findAll(u.root.?, ui.RoundedBox, &cells);
    // 250 wide: three 60-wide cells with 10 between (four would need 270).
    try testing.expectEqual(@as(usize, 7), cells.items.len);
    try testing.expectEqual(ui.Point{ 140, 0 }, cells.items[2].offset);
    try testing.expectEqual(ui.Point{ 0, 50 }, cells.items[3].offset);
    try testing.expectEqual(ui.Point{ 0, 100 }, cells.items[6].offset);
    try testing.expectEqual(ui.Size{ .w = 60, .h = 40 }, cells.items[6].size);
    const grid = find(u.root.?, ui.Grid).?;
    try testing.expectEqual(ui.Size{ .w = 250, .h = 140 }, grid.size);
}

const VirtualItems = struct {
    pressed: ?usize = null,
    made: usize = 0,

    const Press = struct {
        items: *VirtualItems,
        i: usize,
        fn f(p: *const Press) void {
            p.items.pressed = p.i;
        }
    };

    fn item(items: *VirtualItems, cx: *Context, i: usize) Widget {
        items.made += 1;
        const p = cx.arena.create(Press) catch unreachable;
        p.* = .{ .items = items, .i = i };
        return cx.make(ui.Pressable{ .on_press = .of(p, Press.f), .child = cx.make(ui.RoundedBox{ .color = if (i % 2 == 0) red else blue }) });
    }
};

const VirtualApp = struct {
    items: *VirtualItems,
    in_scroll_view: bool = true,
    pub fn build(self: *const @This(), cx: *Context) Widget {
        const grid = cx.make(ui.Grid{ .count = 100, .cell = .{ .w = 50, .h = 40 }, .spacing = 10, .item = .of(self.items, VirtualItems.item) });
        return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = if (self.in_scroll_view) cx.make(ui.ScrollView{ .child = grid }) else grid }) });
    }
};

test "a virtual grid makes only the rows that show, as it scrolls" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    var items: VirtualItems = .{};
    u.frame(400, 400, 0, VirtualApp{ .items = &items });
    const view = find(u.root.?, ui.ScrollView).?;
    const grid = view.child(0);
    // 188 wide beside the bar: three columns; 34 rows of 50.
    try testing.expectEqual(ui.Size{ .w = 188, .h = 34 * 50 - 10 }, grid.size);
    // Rows 0 to 5 show (300 of 50 each), and one more is made.
    try testing.expectEqual(@as(usize, 21), grid.childCount());
    try testing.expectEqual(ui.Point{ 60, 50 }, grid.child(4).offset);
    try testing.expectEqual(ui.Size{ .w = 50, .h = 40 }, grid.child(4).size);
    // The next frame makes the same ones, with the rest of the tree.
    items.made = 0;
    u.frame(400, 400, 1, VirtualApp{ .items = &items });
    try testing.expectEqual(@as(usize, 21), items.made);

    // Scrolled to 1000: rows 20 to 25 show; 19 to 26 are made.
    _ = view.state(ui.ScrollView.State).scrollTo(1000);
    u.frame(400, 400, 2, VirtualApp{ .items = &items });
    try testing.expectEqual(@as(usize, 24), grid.childCount());
    try testing.expectEqual(@as(?u64, 57), grid.child(0).widget.key);
    try testing.expectEqual(ui.Point{ 0, 19 * 50 }, grid.child(0).offset);
    try testing.expect(!grid.child(0).paint.valid);
    try testing.expect(grid.child(3).paint.valid);
    // Pressing one presses the right item.
    u.pointerMotion(.{ 70, 15 });
    u.pointerButton(.{ 70, 15 }, .left, true);
    u.pointerButton(.{ 70, 15 }, .left, false);
    try testing.expectEqual(@as(?usize, 61), items.pressed);

    // Not in a scroll view: all of it shows.
    u.frame(400, 400, 3, VirtualApp{ .items = &items, .in_scroll_view = false });
    try testing.expectEqual(@as(usize, 100), find(u.root.?, ui.Grid).?.childCount());
}

const RevealApp = struct {
    reveal: ?u64 = null,
    pub fn build(self: *const @This(), cx: *Context) Widget {
        // Twenty rows of 30, keyed 1000 + their index.
        const rows = cx.arena.alloc(Widget, 20) catch unreachable;
        for (rows, 0..) |*r, i| r.* = cx.make(ui.SizedBox{ .height = 30 }).withKey(1000 + @as(u64, i));
        return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
            .reveal = self.reveal,
            .child = cx.make(ui.Column{ .fill = false, .children = rows }),
        }) }) });
    }
};

test "a scroll view scrolls to reveal a widget by its key, when that changes" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    u.frame(400, 400, 0, RevealApp{});
    const st = find(u.root.?, ui.ScrollView).?.state(ui.ScrollView.State);
    try testing.expectEqual(@as(f32, 0), st.offset);
    // Row 15 is below the 300 that show: its bottom is put at the bottom.
    u.frame(400, 400, 1, RevealApp{ .reveal = 1015 });
    try testing.expectEqual(@as(f32, 16 * 30 - 300), st.offset);
    // The same key does not scroll again.
    _ = st.scrollTo(0);
    u.frame(400, 400, 2, RevealApp{ .reveal = 1015 });
    try testing.expectEqual(@as(f32, 0), st.offset);
    // A row above the view is put at the top.
    _ = st.scrollTo(300);
    u.frame(400, 400, 3, RevealApp{ .reveal = 1002 });
    try testing.expectEqual(@as(f32, 2 * 30), st.offset);
}

test "icons are drawn from the icon font, in their box" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.Row{ .fill = false, .children = cx.makeAll(.{
                ui.Icon{ .icon = .folder, .size = 48, .color = red },
                ui.OutlinedButton{ .label = "Up", .icon = .arrow_upward },
                ui.OutlinedButton{ .icon = .close },
                ui.OutlinedButton{ .label = "More", .trailing_icon = .expand_more },
            }) }) });
        }
    }.f;
    u.frame(400, 100, 0, Root(build){});
    const icon = find(u.root.?, ui.Icon).?;
    try testing.expectEqual(ui.Size{ .w = 48, .h = 48 }, icon.size);
    var img = try Image.init(u, 400, 100);
    defer img.deinit();
    // The folder fills the middle of its box, and nothing is below it.
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(24, 28));
    try testing.expectEqual(@as(u32, 0xff000000), img.at(24, 60));
    // A button's icon goes before its label (or after, for trailing_icon),
    // in the label's colour; one with only an icon is round.
    var buttons: std.ArrayList(*Node) = .empty;
    defer buttons.deinit(testing.allocator);
    try findAll(u.root.?, ui.OutlinedButton, &buttons);
    const with_label = buttons.items[0];
    const glyph = find(with_label, ui.Icon).?;
    const label = find(with_label, ui.Text).?;
    try testing.expect(glyph.position()[0] < label.position()[0]);
    try testing.expectEqual(label.widget.as(ui.Text).?.style.color.?, glyph.widget.as(ui.Icon).?.color.?);
    try testing.expectEqual(@as(f32, 40), buttons.items[1].size.h);
    try testing.expect(find(buttons.items[1], ui.Text) == null);
    const with_trailing = buttons.items[2];
    try testing.expect(find(with_trailing, ui.Text).?.position()[0] < find(with_trailing, ui.Icon).?.position()[0]);
}

test "images fit the space given, keeping their shape, and text can have its own font" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    const pixels: [8]u32 = .{ 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xff0000ff, 0xff0000ff, 0xff0000ff, 0xff0000ff };
    const pic = gfx.Image.init(&pixels, 4, 2);
    const App = struct {
        pic: *const gfx.Image,
        width: f32,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = self.width, .height = 100, .child = cx.make(ui.Align.center(cx.make(ui.Image{ .source = .{ .image = self.pic } }))) }) });
        }
    };
    // Smaller than the space: as big as it is.
    u.frame(300, 200, 0, App{ .pic = &pic, .width = 300 });
    try testing.expectEqual(ui.Size{ .w = 4, .h = 2 }, find(u.root.?, ui.Image).?.size);
    // Bigger: made to fit, keeping its shape (and drawn, top red, bottom blue).
    const big = gfx.Image.init(&(@as([200 * 50]u32, @splat(0xffff0000)) ++ @as([200 * 50]u32, @splat(0xff0000ff))), 200, 100);
    u.frame(300, 200, 1, App{ .pic = &big, .width = 100 });
    const node = find(u.root.?, ui.Image).?;
    try testing.expectEqual(ui.Size{ .w = 100, .h = 50 }, node.size);
    try testing.expectEqual(ui.Point{ 0, 25 }, node.offset);
    var img = try Image.init(u, 300, 200);
    defer img.deinit();
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(50, 30));
    try testing.expectEqual(@as(u32, 0xff0000ff), img.at(50, 70));
    try testing.expectEqual(@as(u32, 0xff000000), img.at(50, 80));

    // Text in another font: the icon font draws "folder" as its icon.
    const icon_font = try font.Font.init(ui.Icon.font_data);
    const Shown = struct {
        f: *const font.Font,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.Text{ .text = "\u{e2c7}", .style = .{ .size = 40, .font = self.f } }) });
        }
    };
    u.frame(300, 200, 2, Shown{ .f = &icon_font });
    const text = find(u.root.?, ui.Text).?;
    try testing.expectApproxEqAbs(@as(f32, 40), text.size.w, 0.5);
}

test "a scroll view scrolls with the wheel and its bar, and paints only what shows" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            var rows: [20]Widget = undefined;
            for (&rows, 0..) |*r, i| r.* = cx.make(ui.SizedBox{ .height = 50, .child = cx.make(ui.RoundedBox{ .color = if (i % 2 == 0) red else blue }) });
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &rows }),
            }) }) });
        }
    }.f;
    u.frame(400, 400, 0, Root(build){});
    const view = find(u.root.?, ui.ScrollView).?;
    const column = view.child(0);
    const st = view.state(ui.ScrollView.State);
    // Too tall: the bar takes its width, and nothing counts as overflow.
    try testing.expectEqual(ui.Size{ .w = 200, .h = 300 }, view.size);
    try testing.expectEqual(@as(f32, 188), column.size.w);
    try testing.expectEqual(@as(f32, 1000), st.content);
    try testing.expect(!view.overflow.any());
    // Rows below the view are not painted.
    try testing.expect(column.child(5).paint.valid);
    try testing.expect(!column.child(6).paint.valid);

    // The wheel: a notch (15 pixels) scrolls three times that.
    u.pointerScroll(.{ 100, 100 }, 0, 15);
    try testing.expect(u.needs_frame);
    u.frame(400, 400, 1, Root(build){});
    try testing.expectEqual(@as(f32, 45), st.offset);
    try testing.expectEqual(ui.Point{ 0, -45 }, column.offset);
    try testing.expect(u.changed());
    // No further than the end, and no further back than the top.
    u.pointerScroll(.{ 100, 100 }, 0, 10000);
    u.frame(400, 400, 2, Root(build){});
    try testing.expectEqual(@as(f32, 700), st.offset);
    try testing.expect(!column.child(0).paint.valid);
    try testing.expect(column.child(19).paint.valid);
    u.pointerScroll(.{ 100, 100 }, 0, -10000);
    u.frame(400, 400, 3, Root(build){});
    try testing.expectEqual(@as(f32, 0), st.offset);
    // At the top already, the wheel up is not taken.
    u.needs_frame = false;
    u.pointerScroll(.{ 100, 100 }, 0, -15);
    try testing.expect(!u.needs_frame);

    // Pressing the bar below the thumb (90 tall: 300 of 1000) jumps there,
    // centred on the pointer; dragging moves it.
    u.pointerMotion(.{ 194, 255 });
    u.pointerButton(.{ 194, 255 }, .left, true);
    // The thumb's top at 210 of the 210 it can travel: the end.
    try testing.expectEqual(@as(f32, 700), st.offset);
    u.pointerMotion(.{ 194, 150 });
    try testing.expectEqual(@as(f32, 350), st.offset);
    u.pointerButton(.{ 194, 150 }, .left, false);
    try testing.expect(st.grab == null);
    u.frame(400, 400, 4, Root(build){});
    try testing.expectEqual(ui.Point{ 0, -350 }, column.offset);

    // Content that fits needs no bar, and does not scroll.
    const short = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .child = cx.make(ui.SizedBox{ .height = 100, .child = cx.make(ui.RoundedBox{ .color = red }) }),
            }) }) });
        }
    }.f;
    u.frame(400, 400, 5, Root(short){});
    const v2 = find(u.root.?, ui.ScrollView).?;
    try testing.expectEqual(@as(f32, 200), v2.child(0).size.w);
    try testing.expectEqual(@as(f32, 0), v2.state(ui.ScrollView.State).offset);
}

test "a scroll view scrolls to the widget it is told to reveal, once" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    const Reveal = struct {
        target: ?u64,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            var rows: [20]Widget = undefined;
            for (&rows, 0..) |*r, i| r.* = cx.make(ui.SizedBox{ .height = 50, .child = cx.make(ui.RoundedBox{ .color = red }) }).withKey(i);
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .reveal = self.target,
                .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &rows }),
            }) }) });
        }
    };
    u.frame(400, 400, 0, Reveal{ .target = 12 });
    const st = find(u.root.?, ui.ScrollView).?.state(ui.ScrollView.State);
    // Row 12 (600 to 650) at the bottom of the view.
    try testing.expectEqual(@as(f32, 350), st.offset);
    // Scrolled away, it stays away until another is revealed.
    _ = st.scrollTo(0);
    u.frame(400, 400, 1, Reveal{ .target = 12 });
    try testing.expectEqual(@as(f32, 0), st.offset);
    u.frame(400, 400, 2, Reveal{ .target = 19 });
    try testing.expectEqual(@as(f32, 700), st.offset);
    // Above the view: at its top.
    u.frame(400, 400, 3, Reveal{ .target = 2 });
    try testing.expectEqual(@as(f32, 100), st.offset);
}

test "a tap presses a button; a touch that moves over a list scrolls it, pressing nothing" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    const Count = struct {
        var presses: u32 = 0;
        fn press(_: *u8) void {
            presses += 1;
        }
    };
    Count.presses = 0;
    var dummy: u8 = 0;
    const App = struct {
        dummy: *u8,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            var rows: [20]Widget = undefined;
            for (&rows) |*r| r.* = cx.make(ui.Pressable{ .on_press = .of(self.dummy, Count.press), .child = cx.make(ui.SizedBox{ .height = 50 }) });
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &rows }),
            }) }) });
        }
    };
    u.frame(400, 400, 0, App{ .dummy = &dummy });
    const st = find(u.root.?, ui.ScrollView).?.state(ui.ScrollView.State);
    // A tap: a press.
    u.touchDown(1, .{ 100, 100 });
    u.touchUp(1);
    try testing.expectEqual(@as(u32, 1), Count.presses);
    // A touch that wobbles less than the slop is still a tap.
    u.touchDown(2, .{ 100, 100 });
    u.touchMotion(2, .{ 103, 104 });
    u.touchUp(2);
    try testing.expectEqual(@as(u32, 2), Count.presses);
    // Up the list by 60: the list follows it, by as much, and the row it
    // went down on is not pressed.
    u.frame(400, 400, 1, App{ .dummy = &dummy });
    u.touchDown(3, .{ 100, 200 });
    u.touchMotion(3, .{ 100, 170 });
    u.touchMotion(3, .{ 100, 140 });
    u.touchUp(3);
    try testing.expectEqual(@as(f32, 60), st.offset);
    try testing.expectEqual(@as(u32, 2), Count.presses);
    // Nothing is hovered once it is up.
    try testing.expectEqual(@as(usize, 0), u.hovered.items.len);
    // A second finger while one is down is ignored; a cancelled touch
    // presses nothing.
    u.touchDown(4, .{ 100, 100 });
    u.touchDown(5, .{ 100, 150 });
    u.touchUp(5);
    u.touchCancel();
    try testing.expectEqual(@as(u32, 2), Count.presses);
    try testing.expect(u.captured == null);
}

const DragTest = struct {
    dropped: *?usize,
    clicked: *u32,

    fn drop(self: *const DragTest, data: usize) void {
        self.dropped.* = data;
    }

    fn pressed(self: *const DragTest) void {
        self.clicked.* += 1;
    }

    fn odd(_: ?*const anyopaque, data: usize) bool {
        return data % 2 == 1;
    }

    pub fn build(self: *const DragTest, cx: *Context) Widget {
        const box = cx.make(ui.SizedBox{ .width = 80, .height = 80 });
        return cx.make(ui.Row{ .children = cx.makeAll(.{
            ui.Draggable{ .data = 7, .label = "seven", .on_press = .of(self, pressed), .child = box },
            ui.Draggable{ .data = 8, .label = "eight", .child = box },
            ui.DropTarget{ .on_drop = .of(self, drop), .accepts = odd, .child = box },
        }) });
    }
};

test "dragging onto a target that takes it drops it there; a click is still a click" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    var dropped: ?usize = null;
    var clicked: u32 = 0;
    const w: DragTest = .{ .dropped = &dropped, .clicked = &clicked };
    u.frame(300, 100, 0, w);
    // Pressed and let go without moving: clicked.
    u.pointerMotion(.{ 40, 40 });
    u.pointerButton(.{ 40, 40 }, .left, true);
    u.pointerMotion(.{ 43, 42 });
    u.pointerButton(.{ 43, 42 }, .left, false);
    try testing.expectEqual(@as(u32, 1), clicked);
    try testing.expect(u.drag == null);

    // Dragged to the target: the chip follows, the target lights up, and
    // it gets 7 (no click).
    u.pointerButton(.{ 40, 40 }, .left, true);
    u.pointerMotion(.{ 120, 40 });
    try testing.expectEqualStrings("seven", u.drag.?.label);
    try testing.expect(u.drag.?.target == null);
    u.pointerMotion(.{ 200, 40 });
    try testing.expect(u.drag.?.target.?.widget.is(ui.DropTarget));
    u.frame(300, 100, 1, w);
    try testing.expect(u.drag_root != null);
    try testing.expectEqualStrings("seven", find(u.drag_root.?, ui.Text).?.widget.as(ui.Text).?.text);
    u.pointerButton(.{ 200, 40 }, .left, false);
    try testing.expectEqual(@as(?usize, 7), dropped);
    try testing.expectEqual(@as(u32, 1), clicked);
    try testing.expect(u.drag == null);
    u.frame(300, 100, 2, w);
    try testing.expect(u.drag_root == null);

    // 8 is not taken: no target, nothing dropped.
    dropped = null;
    u.pointerMotion(.{ 120, 40 });
    u.pointerButton(.{ 120, 40 }, .left, true);
    u.pointerMotion(.{ 200, 40 });
    try testing.expect(u.drag.?.target == null);
    u.pointerButton(.{ 200, 40 }, .left, false);
    try testing.expect(dropped == null);

    // If the pointer leaves the window during a press or drag, it is cancelled
    // cleanly so later clicks still work.
    u.pointerMotion(.{ 40, 40 });
    u.pointerButton(.{ 40, 40 }, .left, true);
    try testing.expect(u.captured != null);
    u.pointerLeave();
    try testing.expect(u.captured == null);
    try testing.expectEqual(@as(u32, 1), clicked);
    clickAt(u, .{ 40, 40 });
    try testing.expectEqual(@as(u32, 2), clicked);
}

test "sliders, dropdowns, dialogs, tooltips, chips, badges, tabs and rails" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();

    const Mode = enum { one, two, three };
    const Gallery = struct {
        pub const State = struct {
            slider_val: f32 = 0.25,
            discrete_val: f32 = 20,
            mode: Mode = .one,
            chip_selected: bool = false,
            chip_removed: bool = false,
            tab: usize = 0,
            rail: usize = 0,
            dialog_open: bool = false,
            confirmed: u32 = 0,
            dismissed: u32 = 0,
            snack_actions: u32 = 0,

            fn setSlider(s: *State, v: f32) void {
                s.slider_val = v;
            }
            fn setDiscrete(s: *State, v: f32) void {
                s.discrete_val = v;
            }
            fn setMode(s: *State, m: Mode) void {
                s.mode = m;
            }
            fn toggleChip(s: *State) void {
                s.chip_selected = !s.chip_selected;
            }
            fn removeChip(s: *State) void {
                s.chip_removed = true;
            }
            fn setTab(s: *State, idx: usize) void {
                s.tab = idx;
            }
            fn setRail(s: *State, idx: usize) void {
                s.rail = idx;
            }
            fn confirm(s: *State) void {
                s.confirmed += 1;
                s.dialog_open = false;
            }
            fn dismiss(s: *State) void {
                s.dismissed += 1;
                s.dialog_open = false;
            }
            fn snackAct(s: *State) void {
                s.snack_actions += 1;
            }
        };

        pub fn build(_: *const @This(), cx: *Context, state: *State) Widget {
            const opts = [_]ui.Select(Mode).Option{
                .{ .value = .one, .item = .{ .label = "One" } },
                .{ .value = .two, .item = .{ .label = "Two" } },
                .{ .value = .three, .item = .{ .label = "Three" } },
            };
            const rail_items = [_]ui.NavigationRail.Item{
                .{ .label = "First", .icon = .folder },
                .{ .label = "Second", .icon = .settings, .badge = 4 },
            };
            const tabs = [_]ui.Tab{
                .{ .label = "Alpha", .icon = .apps },
                .{ .label = "Beta", .badge = 2 },
            };
            const main_col = cx.make(ui.Row{
                .children = cx.makeAll(.{
                    ui.NavigationRail{
                        .items = &rail_items,
                        .selected = state.rail,
                        .on_select = .of(state, State.setRail),
                        .extended = false,
                    },
                    ui.VerticalDivider{},
                    ui.Expanded{
                        .child = cx.make(ui.Column{
                            .cross_axis_alignment = .stretch,
                            .spacing = 8,
                            .children = cx.makeAll(.{
                                ui.TabBar{
                                    .tabs = &tabs,
                                    .selected = state.tab,
                                    .on_select = .of(state, State.setTab),
                                },
                                ui.Slider{
                                    .value = state.slider_val,
                                    .on_changed = .of(state, State.setSlider),
                                },
                                ui.Slider{
                                    .value = state.discrete_val,
                                    .min = 0,
                                    .max = 100,
                                    .divisions = 4,
                                    .on_changed = .of(state, State.setDiscrete),
                                },
                                ui.ProgressBar{ .value = state.slider_val },
                                ui.Select(Mode){
                                    .options = &opts,
                                    .value = state.mode,
                                    .on_changed = .of(state, State.setMode),
                                },
                                ui.Row{
                                    .spacing = 8,
                                    .children = cx.makeAll(.{
                                        ui.FilledButton{ .label = "Filled", .on_press = .of(state, State.toggleChip) },
                                        ui.TonalButton{ .label = "Tonal", .on_press = .of(state, State.toggleChip) },
                                        ui.TextButton{ .label = "Text", .on_press = .of(state, State.toggleChip) },
                                        ui.Tooltip{
                                            .text = "Settings tip",
                                            .child = cx.make(ui.IconButton{ .icon = .settings, .variant = .tonal, .on_press = .of(state, State.toggleChip) }),
                                        },
                                        ui.Chip{
                                            .label = "Tag",
                                            .selected = state.chip_selected,
                                            .on_press = .of(state, State.toggleChip),
                                            .on_remove = .of(state, State.removeChip),
                                        },
                                        ui.Badge{ .count = 150, .child = cx.make(ui.Icon{ .icon = .wifi }) },
                                    }),
                                },
                                ui.Card{
                                    .variant = .outlined,
                                    .child = cx.make(ui.ListItem{
                                        .headline = "Row title",
                                        .supporting_text = "Details",
                                        .leading_icon = .folder,
                                        .trailing_icon = .chevron_right,
                                    }),
                                },
                            }),
                        }),
                    },
                }),
            });
            const with_snack = cx.make(ui.Snackbar{
                .message = "Saved",
                .action_label = "Undo",
                .on_action = .of(state, State.snackAct),
                .child = main_col,
            });
            return cx.make(ui.Dialog{
                .open = state.dialog_open,
                .title = "Confirm?",
                .description = "Are you sure?",
                .dismiss_label = "No",
                .on_dismiss = .of(state, State.dismiss),
                .confirm_label = "Yes",
                .on_confirm = .of(state, State.confirm),
                .child = with_snack,
            });
        }
    };

    u.frame(900, 700, 0, Gallery{});
    const st = u.root.?.state(Gallery.State);

    // Drag continuous slider to 75% and discrete slider (4 divisions) near 70% -> snaps to 75.
    var sliders: std.ArrayList(*Node) = .empty;
    defer sliders.deinit(testing.allocator);
    try findAll(u.root.?, ui.Slider, &sliders);
    try testing.expectEqual(@as(usize, 2), sliders.items.len);
    {
        const s0 = sliders.items[0];
        const pos = s0.position();
        const x0 = pos[0] + ui.Slider.halo_radius;
        const x1 = pos[0] + s0.size.w - ui.Slider.halo_radius;
        u.pointerMotion(.{ x0 + (x1 - x0) * 0.5, pos[1] + 10 });
        u.pointerButton(.{ x0 + (x1 - x0) * 0.5, pos[1] + 10 }, .left, true);
        u.pointerMotion(.{ x0 + (x1 - x0) * 0.75, pos[1] + 10 });
        u.pointerButton(.{ x0 + (x1 - x0) * 0.75, pos[1] + 10 }, .left, false);
        try testing.expectApproxEqAbs(@as(f32, 0.75), st.slider_val, 0.01);

        const s1 = sliders.items[1];
        const p1 = s1.position();
        const d0 = p1[0] + ui.Slider.halo_radius;
        const d1 = p1[0] + s1.size.w - ui.Slider.halo_radius;
        clickAt(u, .{ d0 + (d1 - d0) * 0.70, p1[1] + 10 });
        try testing.expectEqual(@as(f32, 75), st.discrete_val);
    }

    // Hovering the Tooltip shows tooltip_root on the next frame.
    const tt_node = find(u.root.?, ui.Tooltip).?;
    const tt_pos = tt_node.position();
    u.pointerMotion(.{ tt_pos[0] + 10, tt_pos[1] + 10 });
    u.frame(900, 700, 1, Gallery{});
    try testing.expect(u.tooltip_root != null);
    try testing.expectEqualStrings("Settings tip", find(u.tooltip_root.?, ui.Text).?.widget.as(ui.Text).?.text);

    // DropdownMenu opens a menu and picks an option.
    const dd = find(u.root.?, ui.DropdownMenu).?;
    click(u, dd);
    u.frame(900, 700, 2, Gallery{});
    try testing.expect(u.menu_root != null);
    const mpos = u.menu_root.?.offset;
    clickAt(u, .{ mpos[0] + 30, mpos[1] + ui.menu.padding + ui.menu.item_height * 2.5 });
    try testing.expectEqual(Mode.three, st.mode);

    // Dialog blocks background clicks, confirms via FilledButton, and dismisses via scrim.
    st.dialog_open = true;
    u.frame(900, 700, 3, Gallery{});
    clickAt(u, .{ 10, 10 });
    try testing.expectEqual(@as(u32, 1), st.dismissed);
    try testing.expect(!st.dialog_open);

    st.dialog_open = true;
    u.frame(900, 700, 4, Gallery{});
    const dialog_node = find(u.root.?, ui.Dialog).?;
    var filled_btns: std.ArrayList(*Node) = .empty;
    defer filled_btns.deinit(testing.allocator);
    try findAll(dialog_node, ui.FilledButton, &filled_btns);
    // The last FilledButton in the tree is the dialog's Confirm button.
    click(u, filled_btns.items[filled_btns.items.len - 1]);
    try testing.expectEqual(@as(u32, 1), st.confirmed);
    try testing.expect(!st.dialog_open);
}

test "widget cursor shapes reflect hovered and captured widgets" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();

    var slider_val: f32 = 0.5;
    const SetSlider = struct {
        fn set(v: *f32, x: f32) void {
            v.* = x;
        }
    };

    const CursorApp = struct {
        slider_val: *f32,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{
                .alignment = .top_left,
                .child = cx.make(ui.Column{
                    .cross_axis_alignment = .start,
                    .spacing = 10,
                    .children = cx.makeAll(.{
                        ui.OutlinedButton{ .label = "Enabled", .on_press = .of(&dummy_count, addDummy) },
                        ui.OutlinedButton{ .label = "Disabled" },
                        ui.SizedBox{
                            .width = 200,
                            .child = cx.make(ui.TextField{ .initial = "hello" }),
                        },
                        ui.SizedBox{
                            .width = 200,
                            .child = cx.make(ui.Slider{ .value = self.slider_val.*, .on_changed = .of(self.slider_val, SetSlider.set) }),
                        },
                        ui.Draggable{
                            .data = 1,
                            .label = "drag-me",
                            .child = cx.make(ui.SizedBox{ .width = 80, .height = 40 }),
                        },
                    }),
                }),
            });
        }
    };

    const w: CursorApp = .{ .slider_val = &slider_val };
    u.frame(400, 400, 0, w);

    // Empty background -> default cursor.
    u.pointerMotion(.{ 350, 350 });
    try testing.expectEqual(ui.PointerCursor.default, u.cursor());

    // Enabled button -> pointer cursor; disabled button -> default cursor.
    var buttons: std.ArrayList(*Node) = .empty;
    defer buttons.deinit(testing.allocator);
    try findAll(u.root.?, ui.OutlinedButton, &buttons);
    const btn_pos = buttons.items[0].position();
    u.pointerMotion(.{ btn_pos[0] + 10, btn_pos[1] + 10 });
    try testing.expectEqual(ui.PointerCursor.pointer, u.cursor());

    const dis_pos = buttons.items[1].position();
    u.pointerMotion(.{ dis_pos[0] + 10, dis_pos[1] + 10 });
    try testing.expectEqual(ui.PointerCursor.default, u.cursor());

    // TextField -> text cursor.
    const tf = find(u.root.?, ui.TextField).?;
    const tf_pos = tf.position();
    u.pointerMotion(.{ tf_pos[0] + 10, tf_pos[1] + 10 });
    try testing.expectEqual(ui.PointerCursor.text, u.cursor());

    // Slider -> pointer cursor.
    const sl = find(u.root.?, ui.Slider).?;
    const sl_pos = sl.position();
    u.pointerMotion(.{ sl_pos[0] + 30, sl_pos[1] + 10 });
    try testing.expectEqual(ui.PointerCursor.pointer, u.cursor());

    // Draggable -> grab when hovered, grabbing while actively dragging.
    const dr = find(u.root.?, ui.Draggable).?;
    const dr_pos = dr.position();
    u.pointerMotion(.{ dr_pos[0] + 10, dr_pos[1] + 10 });
    try testing.expectEqual(ui.PointerCursor.grab, u.cursor());
    u.pointerButton(.{ dr_pos[0] + 10, dr_pos[1] + 10 }, .left, true);
    u.pointerMotion(.{ dr_pos[0] + 40, dr_pos[1] + 10 });
    try testing.expectEqual(ui.PointerCursor.grabbing, u.cursor());
    u.pointerButton(.{ dr_pos[0] + 40, dr_pos[1] + 10 }, .left, false);
}

test "zwp_text_input_v3 events commit text, render preedit, and delete surrounding bytes in TextField" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();

    const FieldApp = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{
                .alignment = .top_left,
                .child = cx.make(ui.SizedBox{
                    .width = 240,
                    .child = cx.make(ui.TextField{ .initial = "hello" }),
                }),
            });
        }
    };

    u.frame(300, 100, 0, FieldApp{});
    // Before focus, textInputState is null.
    try testing.expect(u.textInputState() == null);

    // Click to focus the TextField at the end of "hello".
    const tf = find(u.root.?, ui.TextField).?;
    clickAt(u, .{ tf.position()[0] + 200, tf.position()[1] + 15 });
    u.frame(300, 100, 1, FieldApp{});

    const st0 = u.textInputState().?;
    try testing.expectEqualStrings("hello", st0.surrounding_text);
    try testing.expectEqual(@as(u32, 5), st0.cursor);
    try testing.expectEqual(@as(u32, 5), st0.anchor);

    const tf_state = find(u.root.?, ui.TextField).?.state(ui.TextField.State);

    // Preedit string appears without mutating committed text yet.
    var pre_ev: window.InputEvent = .{ .text_preedit = .{ .len = 2, .cursor_begin = 2, .cursor_end = 2 } };
    @memcpy(pre_ev.text_preedit.buf[0..2], "ni");
    u.handleInput(pre_ev);
    try testing.expectEqualStrings("hello", tf_state.text());
    u.frame(300, 100, 2, FieldApp{});

    // Commit string replaces preedit and inserts into the TextField.
    var com_ev: window.InputEvent = .{ .text_commit = .{ .len = 1 } };
    com_ev.text_commit.buf[0] = '!';
    u.handleInput(com_ev);
    u.handleInput(.{ .text_preedit = .{} });
    try testing.expectEqualStrings("hello!", tf_state.text());

    // delete_surrounding_text deletes 2 bytes before cursor ("o!").
    u.handleInput(.{ .text_delete_surrounding = .{ .before_length = 2, .after_length = 0 } });
    try testing.expectEqualStrings("hell", tf_state.text());
}

test "WindowUi.createDefault loads bundled Fira Sans and Twemoji fallback fonts" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    try testing.expect(u.font != null);
    try testing.expect(u.font.?.fallback != null);
    u.frame(200, 80, 0, ui.Text{ .text = "Hello 😀" });
    const img = try Image.init(u, 200, 80);
    defer img.deinit();
    var lit: u32 = 0;
    for (img.pixels) |px| if (px != 0xff000000) {
        lit += 1;
    };
    try testing.expect(lit > 50);
}

test "minimum window size is computed from widget tree and synchronized to window" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();

    const MockWin = struct {
        w: u32 = 300,
        h: u32 = 200,
        min_size: [2]u32 = .{ 0, 0 },
        pub fn size(self: *const @This()) [2]u32 {
            return .{ self.w, self.h };
        }
        pub fn setMinSize(self: *@This(), mw: u32, mh: u32) void {
            self.min_size = .{ mw, mh };
            if (self.w < mw) self.w = mw;
            if (self.h < mh) self.h = mh;
        }
    };
    var mock: MockWin = .{};
    u.attachWindow(&mock, null);
    u.maximized = false;

    const MinApp = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Column{
                .cross_axis_alignment = .stretch,
                .children = cx.makeAll(.{
                    ui.TitleBar{ .title = "Min Size" },
                    ui.Expanded{
                        .child = cx.make(ui.Padding{
                            .padding = .all(20),
                            .child = cx.make(ui.SizedBox{ .width = 400, .height = 260 }),
                        }),
                    },
                }),
            });
        }
    };

    u.frame(mock.w, mock.h, 0, MinApp{});
    try testing.expectEqual([2]u32{ 440, 344 }, u.min_size);
    try testing.expectEqual([2]u32{ 440, 344 }, mock.min_size);
    try testing.expectEqual([2]u32{ 440, 344 }, u.frame_size);
    try testing.expect(!u.root.?.overflow.any());

    // Explicit min_size_floor is respected when larger than content minimum.
    u.min_size_floor = .{ 500, 400 };
    u.frame(mock.w, mock.h, 1, MinApp{});
    try testing.expectEqual([2]u32{ 500, 400 }, u.min_size);
    try testing.expectEqual([2]u32{ 500, 400 }, mock.min_size);
}

test "HiDPI scale factor renders text and shapes at physical buffer resolution while keeping logical layout" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    u.theme = .light;

    const HiDpiWin = struct {
        width: u32 = 200,
        height: u32 = 80,
        scale: u32 = 2,
    };
    var win: HiDpiWin = .{};
    u.attachWindow(&win, null);
    try testing.expectEqual(@as(u32, 2), u.scale);

    var clicked = false;
    u.frame(200, 80, 0, ui.FilledButton{
        .label = "Sharp Text",
        .icon = .check,
        .on_press = .of(&clicked, struct {
            fn f(flag: *bool) void {
                flag.* = true;
            }
        }.f),
    });
    try testing.expectEqual([2]u32{ 200, 80 }, u.logical_size);
    try testing.expectEqual([2]u32{ 400, 160 }, u.frame_size);

    const img = try Image.init(u, 400, 160);
    defer img.deinit();
    // Both top-left and bottom-right quadrants of the 400x160 physical buffer
    // should contain rendered button pixels.
    try testing.expectEqual(u.theme.primary.toArgb(), img.at(40, 40));
    try testing.expectEqual(u.theme.primary.toArgb(), img.at(360, 120));
}

test "BuildContext.backend reports platform, buffer transport, and renderer" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();

    const expected_renderer: gfx.RenderBackend = if (u.shared.d3d11_renderer != null)
        .d3d11
    else if (u.shared.metal_renderer != null)
        .metal
    else if (u.shared.vulkan_renderer != null)
        .vulkan
    else if (u.shared.opengl_renderer != null)
        .opengl
    else
        .software;

    const Probe = struct {
        out: *ui.BackendInfo,
        win: *?*ui.Window,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            self.out.* = cx.backend();
            self.win.* = cx.window();
            return cx.make(ui.SizedBox.empty);
        }
    };

    var info: ui.BackendInfo = .{};
    var win: ?*ui.Window = null;
    // A UI on its own is in no app's window.
    u.frame(320, 240, 0, Probe{ .out = &info, .win = &win });
    try testing.expectEqual(window.WindowPlatform.headless, info.platform);
    try testing.expect(win == null);
    try testing.expectEqual(expected_renderer, info.renderer);

    // A Wayland window (Linux and macOS, where its code builds).
    if (comptime builtin.os.tag != .windows) {
        var wl_win: window.WaylandWindow = .{
            .gpa = testing.allocator,
            .io = testing.io,
            .conn = undefined,
            .clipboard = .{ .gpa = testing.allocator, .io = testing.io },
            .wm_base = .{ .id = 2 },
            .presentation = .{ .id = 3 },
            .fifo = .{ .id = 4 },
            .width = 800,
            .height = 600,
            .min_size = .{ 1, 1 },
            .scale = 2,
        };
        for ([_][]const u8{ "xdg_wm_base", "wp_presentation", "wp_fifo_manager_v1" }, 1..) |name, id| wl_win.globals.add(@intCast(id), name, 1);
        wl_win.updateExtensions();
        u.attachWindow(&wl_win, null);
        var handle: ui.Window = .{ .app = undefined, .win = .from(&wl_win), .controls = .{}, .ui = u, .root = undefined };
        u.app_window = &handle;
        u.frame(800, 600, 1, Probe{ .out = &info, .win = &win });
        try testing.expect(win == &handle);
        const w = win.?;
        try testing.expectEqual(window.WindowPlatform.wayland, info.platform);
        try testing.expectEqual(window.WindowDecorations.toolkit, w.decorations());
        try testing.expectEqual(window.WindowBufferTransport.memory, w.bufferTransport());
        try testing.expectEqual(window.WindowBufferSync.none, w.bufferSync());
        try testing.expect(w.frameSync().vsync);
        try testing.expect(w.frameSync().frame_callback);
        try testing.expect(w.frameSync().presentation_time);
        try testing.expect(w.frameSync().fifo);
        try testing.expect(!w.frameSync().timed_presentation);
        try testing.expect(info.hasWaylandExtension("xdg_wm_base"));
        try testing.expect(info.hasWaylandExtension("wp_presentation"));
        try testing.expect(info.hasWaylandExtension("wp_fifo_manager_v1"));
        try testing.expect(!info.hasWaylandExtension("wp_commit_timing_manager_v1"));
        try testing.expectEqual(expected_renderer, info.renderer);
        try testing.expectEqual([2]u32{ 800, 600 }, w.size());
        try testing.expectEqual(@as(u32, 2), w.scale());

        wl_win.system_decorations = true;
        u.attachWindow(&wl_win, null);
        u.frame(800, 600, 2, Probe{ .out = &info, .win = &win });
        try testing.expectEqual(window.WindowDecorations.system, win.?.decorations());
        u.app_window = null;
    }
}

test "VulkanRenderer, OpenGlRenderer, and SoftwareRenderer render UI widgets and text" {
    // Vulkan and OpenGL are not built for Windows.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    try vulkanOpenGlAndSoftware();
}

fn vulkanOpenGlAndSoftware() !void {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    u.theme = .light;

    var clicked = false;
    u.frame(200, 80, 0, ui.FilledButton{
        .label = "GPU 2D",
        .icon = .check,
        .on_press = .of(&clicked, struct {
            fn f(flag: *bool) void {
                flag.* = true;
            }
        }.f),
    });

    // 1. Default renderer (Vulkan -> OpenGL -> Software)
    {
        const img = try Image.init(u, 200, 80);
        defer img.deinit();
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(20, 20));
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(180, 60));
    }

    // 2. Explicitly test OpenGlRenderer if available
    if (gfx.OpenGlRenderer.initDefault(testing.allocator)) |gl_val| {
        var gl = gl_val;
        defer gl.deinit();
        u.attachRenderer(gl.renderer(), false);
        try testing.expectEqual(gfx.RenderBackend.opengl, u.shared.renderer.?.backend());
        const img = try Image.init(u, 200, 80);
        defer img.deinit();
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(20, 20));
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(180, 60));
    } else |_| {}

    // 3. Explicitly test SoftwareRenderer fallback
    {
        u.attachRenderer(u.shared.software_renderer.renderer(), false);
        try testing.expectEqual(gfx.RenderBackend.software, u.shared.renderer.?.backend());
        const img = try Image.init(u, 200, 80);
        defer img.deinit();
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(20, 20));
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(180, 60));
    }
}
test "any window can show frames and give the clipboard, not only Wayland's" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();

    const PlainWin = struct {
        width: u32 = 120,
        height: u32 = 60,
        pixels: [120 * 60]u32 = @splat(0),
        shown: u32 = 0,
        copied: [16]u8 = undefined,
        copied_len: usize = 0,
        pub fn beginSoftwareFrame(w: *@This()) !gfx.software.Image {
            return .{ .pixels = &w.pixels, .width = w.width, .height = w.height };
        }
        pub fn showDamaged(w: *@This(), _: ?[]const gfx.Viewport) !void {
            w.shown += 1;
        }
        pub fn copy(w: *@This(), text: []const u8) void {
            @memcpy(w.copied[0..text.len], text);
            w.copied_len = text.len;
        }
        pub fn paste(w: *@This(), sink: window.clipboard.Sink) void {
            sink.f(sink.ctx, w.copied[0..w.copied_len]);
        }
    };
    var win: PlainWin = .{};
    u.attachWindow(&win, null);
    u.frame(win.width, win.height, 0, ui.SizedBox{ .width = 10, .height = 10 });
    try testing.expect(try u.present(&win, 0xff112233));
    try testing.expectEqual(@as(u32, 1), win.shown);
    try testing.expectEqual(@as(u32, 0xff112233), win.pixels[0]);
    // Nothing changed: nothing to show.
    u.frame(win.width, win.height, 1, ui.SizedBox{ .width = 10, .height = 10 });
    try testing.expect(!try u.present(&win, 0xff112233));

    u.copyText("hello");
    try testing.expectEqualStrings("hello", win.copied[0..win.copied_len]);

    // A renderer drawing into something else cannot draw into the window's
    // buffer.
    var wrong: u32 = 0;
    try testing.expectError(error.WrongTarget, u.render(&wrong, null));
}

/// A window with popups (as Wayland's `xdg_popup`): it records what is
/// opened and closed, and puts each popup at a fixed place.
const PopupWin = struct {
    width: u32 = 400,
    height: u32 = 300,
    pixels: [400 * 300]u32 = @splat(0),
    popup_pixels: [300 * 300]u32 = @splat(0),
    opened: std.ArrayList(window.PopupPlacement) = .empty,
    /// Opens (positive ids) and closes (negative), in order.
    log: std.ArrayList(i64) = .empty,
    next: u32 = 1,
    popup_size: [2]u32 = .{ 0, 0 },
    configured: bool = true,
    shown: u32 = 0,
    /// Where popups go: past the window's right edge, as a popup can.
    const at: [2]i32 = .{ 350, 40 };

    fn deinit(w: *PopupWin) void {
        w.opened.deinit(testing.allocator);
        w.log.deinit(testing.allocator);
    }
    pub fn beginSoftwareFrame(w: *PopupWin) !gfx.software.Image {
        return .{ .pixels = &w.pixels, .width = w.width, .height = w.height };
    }
    pub fn showDamaged(_: *PopupWin, _: ?[]const gfx.Viewport) !void {}
    pub fn openPopup(w: *PopupWin, pl: window.PopupPlacement) ?u32 {
        w.opened.append(testing.allocator, pl) catch return null;
        w.log.append(testing.allocator, w.next) catch return null;
        w.popup_size = pl.size;
        w.next += 1;
        return w.next - 1;
    }
    pub fn closePopup(w: *PopupWin, id: u32) void {
        w.log.append(testing.allocator, -@as(i64, id)) catch {};
    }
    pub fn popupPosition(_: *PopupWin, _: u32) ?[2]i32 {
        return at;
    }
    pub fn beginSoftwarePopupFrame(w: *PopupWin, _: u32) !?gfx.software.Image {
        if (!w.configured) return null;
        return .{ .pixels = w.popup_pixels[0 .. w.popup_size[0] * w.popup_size[1]], .width = w.popup_size[0], .height = w.popup_size[1] };
    }
    pub fn showPopup(w: *PopupWin, _: u32) !void {
        w.shown += 1;
    }
};

test "menus and tooltips go in popups of their own when the window has them" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    u.attachRenderer(u.shared.software_renderer.renderer(), false);
    u.theme = .light;
    var win: PopupWin = .{};
    defer win.deinit();
    u.attachWindow(&win, null);

    const HelpRoot = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.Tooltip{
                .text = "Help",
                .child = cx.make(ui.SizedBox{ .width = 100, .height = 40 }),
            }) });
        }
    };
    var pressed = false;
    const press = struct {
        fn f(b: *bool) void {
            b.* = true;
        }
    }.f;

    // Hovering the widget opens its tooltip in a popup above it.
    // On Wayland, a newly opened xdg_popup is not yet configured on the
    // frame it opens (`beginSoftwarePopupFrame` returns `null`); `present` must
    // request another frame so the popup is drawn once configured.
    u.frame(win.width, win.height, 0, HelpRoot{});
    _ = try u.present(&win, 0xff000000);
    win.configured = false;
    u.pointerMotion(.{ 50, 20 });
    u.frame(win.width, win.height, 1, HelpRoot{});
    try testing.expectEqual(@as(usize, 1), win.opened.items.len);
    const tip = win.opened.items[0];
    try testing.expectEqual(window.PopupKind.tooltip, tip.kind);
    try testing.expectEqual(window.PopupPlacement.Side.above, tip.side);
    try testing.expectEqual([4]i32{ 0, 0, 100, 40 }, tip.anchor);
    try testing.expect(!u.needs_frame);
    try testing.expect(!try u.present(&win, 0xff000000));
    try testing.expectEqual(@as(u32, 0), win.shown);
    try testing.expect(u.needs_frame);

    // Once the compositor configures the popup, the requested frame draws
    // it; a subsequent unchanged frame does not redraw it.
    win.configured = true;
    u.frame(win.width, win.height, 1, HelpRoot{});
    try testing.expect(try u.present(&win, 0xff000000));
    try testing.expectEqual(@as(u32, 1), win.shown);
    try testing.expect(!u.needs_frame);
    u.frame(win.width, win.height, 1, HelpRoot{});
    try testing.expect(!try u.present(&win, 0xff000000));
    try testing.expectEqual(@as(u32, 1), win.shown);

    // A menu: the tooltip's popup closes before the menu's opens.
    win.shown = 0;
    u.openMenu(u.root.?, .{ 30, 25 }, &.{.{ .label = "Copy", .on_press = .of(&pressed, press) }});
    u.frame(win.width, win.height, 2, HelpRoot{});
    try testing.expectEqualSlices(i64, &.{ 1, -1, 2 }, win.log.items);
    const menu = win.opened.items[1];
    try testing.expectEqual(window.PopupKind.menu, menu.kind);
    try testing.expectEqual([4]i32{ 30, 25, 1, 1 }, menu.anchor);
    try testing.expectEqual(window.PopupPlacement.Side.below_right, menu.side);
    // It is where the popup is (past the window's edge), drawn in the
    // popup and not in the window.
    try testing.expectEqual(ui.Point{ 350, 40 }, u.menu_root.?.offset);
    @memset(&win.pixels, 0);
    try testing.expect(try u.present(&win, 0xff000000));
    try testing.expect(win.shown > 0);
    const surface = u.theme.surface_container.toArgb();
    try testing.expectEqual(surface, win.popup_pixels[10 * win.popup_size[0] + 10]);
    try testing.expect(win.pixels[60 * win.width + 60] != surface);

    // Pointer events there go to it: pressing its item does the action and
    // closes it (and its popup).
    const item: ui.Point = .{ 350 + 20, 40 + 8 + 20 };
    u.pointerMotion(item);
    u.pointerButton(item, .left, true);
    u.pointerButton(item, .left, false);
    try testing.expect(pressed);
    try testing.expect(u.menu == null);
    u.frame(win.width, win.height, 3, HelpRoot{});
    try testing.expectEqual(@as(i64, -2), win.log.items[win.log.items.len - 1]);

    // The window system closing a menu's popup closes the menu.
    u.openMenu(u.root.?, .{ 30, 25 }, &.{.{ .label = "Copy" }});
    u.frame(win.width, win.height, 4, HelpRoot{});
    const id: u32 = @intCast(win.log.items[win.log.items.len - 1]);
    u.handleInput(.{ .popup_done = id });
    try testing.expect(u.menu == null);
    try testing.expect(u.menu_popup == null);
    try testing.expectEqual(-@as(i64, id), win.log.items[win.log.items.len - 1]);
}

/// A renderer that can draw straight into dmabufs (or fail to), and draws
/// the CPU way with the software renderer.
const DirectRenderer = struct {
    fail: bool = false,
    direct: u32 = 0,
    clears: usize = 0,
    damage: usize = 0,
    pub fn prepare(_: *DirectRenderer, _: []const *const gfx.Canvas) !void {}
    pub fn record(_: *DirectRenderer, c: *const gfx.Canvas, target: *gfx.software.Image, damage: ?[]const gfx.Viewport) !void {
        try gfx.software.renderWithDamage(c, target.*, damage);
    }
    pub fn renderDmabuf(r: *DirectRenderer, _: []const *const gfx.Canvas, _: []const gfx.Segment, _: *const gfx.DmabufTarget, _: u32, clear_rects: []const gfx.Viewport, damage: []const gfx.Viewport) !void {
        if (r.fail) return error.Unsupported;
        r.direct += 1;
        r.clears = clear_rects.len;
        r.damage = damage.len;
    }
};

/// A window whose buffers are dmabufs.
const DmabufWin = struct {
    width: u32 = 200,
    height: u32 = 100,
    pixels: [200 * 100]u32 = @splat(0),
    cpu_frames: u32 = 0,
    shown: u32 = 0,
    pub fn beginSoftwareFrame(w: *DmabufWin) !gfx.software.Image {
        w.cpu_frames += 1;
        return .{ .pixels = &w.pixels, .width = w.width, .height = w.height };
    }
    pub fn beginDmabufFrame(w: *DmabufWin) ?gfx.DmabufTarget {
        return .{ .id = 1, .fd = -1, .fourcc = 0, .modifier = 0, .offset = 0, .stride = w.width * 4, .width = w.width, .height = w.height, .origin = .{ 0, 0 }, .content = .{ w.width, w.height }, .cpu = .{ .ctx = w, .begin = cpuBegin, .end = cpuEnd } };
    }
    fn cpuBegin(ctx: *anyopaque) anyerror!gfx.software.Image {
        const w: *DmabufWin = @ptrCast(@alignCast(ctx));
        return .{ .pixels = &w.pixels, .width = w.width, .height = w.height };
    }
    fn cpuEnd(_: *anyopaque) void {}
    pub fn showDamaged(w: *DmabufWin, _: ?[]const gfx.Viewport) !void {
        w.shown += 1;
    }
};

test "frames are drawn straight into dmabufs when the renderer can, and the CPU way when it cannot" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    var r: DirectRenderer = .{};
    u.attachRenderer(gfx.Renderer.of(&r), false);
    var win: DmabufWin = .{};
    u.attachWindow(&win, null);
    const content = ui.SizedBox{ .width = 20, .height = 20 };

    // On the GPU: the whole window is cleared and drawn, and nothing is
    // mapped for the CPU.
    u.frame(win.width, win.height, 0, content);
    try testing.expect(try u.present(&win, 0xff102030));
    try testing.expectEqual(@as(u32, 1), r.direct);
    try testing.expectEqual(@as(usize, 1), r.clears);
    try testing.expectEqual(@as(u32, 0), win.cpu_frames);
    try testing.expectEqual(@as(u32, 1), win.shown);

    // A renderer that fails: the frame is drawn on the CPU, and the GPU way
    // is not tried again.
    r.fail = true;
    u.frame(win.width, win.height, 1, content);
    u.damage.invalidate();
    try testing.expect(try u.present(&win, 0xff102030));
    try testing.expectEqual(@as(u32, 1), win.cpu_frames);
    try testing.expectEqual(@as(u32, 0xff102030), win.pixels[0]);
    r.fail = false;
    u.frame(win.width, win.height, 2, content);
    u.damage.invalidate();
    _ = try u.present(&win, 0xff102030);
    try testing.expectEqual(@as(u32, 1), r.direct);
    try testing.expectEqual(@as(u32, 2), win.cpu_frames);
}

test "a GPU draw can also say how to draw straight into a GPU frame, which the CPU way ignores" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    u.attachRenderer(u.shared.software_renderer.renderer(), false);
    const Area = struct {
        var cpu: u32 = 0;
        var direct: u32 = 0;
        pub fn layout(_: *const @This(), _: *Node, c: ui.Constraints) ui.Size {
            return c.constrain(.{ .w = 40, .h = 30 });
        }
        pub fn paint(self: *const @This(), _: *Node, p: *ui.Painter) void {
            p.gpuWithDirect(.{ .fills = true }, self, draw, drawDirect);
        }
        fn draw(_: *const @This(), _: *gfx.software.Image, _: gfx.GpuArea) anyerror!void {
            cpu += 1;
        }
        fn drawDirect(_: *const @This(), backend: gfx.RenderBackend, _: *const anyopaque, _: gfx.GpuArea) anyerror!bool {
            direct += 1;
            return backend == .vulkan;
        }
    };
    u.frame(100, 100, 0, Area{});
    const seg = for (u.segments.items) |s| {
        if (s == .gpu) break s.gpu;
    } else return error.TestUnexpectedResult;
    try testing.expect(seg.direct != null);
    try testing.expect(seg.area.fills);
    // The software renderer draws it the CPU way.
    var pixels: [100 * 100]u32 = @splat(0);
    var img: gfx.software.Image = .{ .pixels = &pixels, .width = 100, .height = 100 };
    try u.render(&img, null);
    try testing.expectEqual(@as(u32, 1), Area.cpu);
    try testing.expectEqual(@as(u32, 0), Area.direct);
    // A GPU frame gets the direct draw, which may decline.
    var frame: u8 = 0;
    try testing.expect(try seg.direct.?(seg.ctx, .vulkan, &frame, seg.area));
    try testing.expect(!try seg.direct.?(seg.ctx, .opengl, &frame, seg.area));
}

test "an animated widget makes its child from how far through it is, and stops asking for frames at the end" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    const Anim = struct {
        t: f32 = -1,
        restart: u64 = 0,
        repeat: ui.AnimatedWidget.Repeat = .once,
        fn child(a: *@This(), cx: *Context, t: f32) Widget {
            a.t = t;
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 10 + 90 * t, .height = 10 }) });
        }
    };
    const AnimRoot = struct {
        a: *Anim,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.AnimatedWidget{
                .duration_ns = 1000,
                .delay_ns = 100,
                .repeat = self.a.repeat,
                .restart = self.a.restart,
                .builder = .of(self.a, Anim.child),
            });
        }
    };
    var a: Anim = .{};
    // It starts the first frame it is built, waits out its delay, and
    // runs for its duration.
    u.frame(200, 100, 5000, AnimRoot{ .a = &a });
    try testing.expectEqual(@as(f32, 0), a.t);
    try testing.expect(u.needs_frame);
    u.frame(200, 100, 5100, AnimRoot{ .a = &a });
    try testing.expectEqual(@as(f32, 0), a.t);
    u.frame(200, 100, 5350, AnimRoot{ .a = &a });
    try testing.expectApproxEqAbs(@as(f32, 0.25), a.t, 1e-6);
    try testing.expect(u.needs_frame);
    // The child is made afresh from it.
    try testing.expectEqual(@as(f32, 32.5), find(u.root.?, ui.SizedBox).?.size.w);
    // At the end, it stays at 1 and asks for no more frames.
    u.frame(200, 100, 6100, AnimRoot{ .a = &a });
    try testing.expectEqual(@as(f32, 1), a.t);
    try testing.expect(!u.needs_frame);
    u.frame(200, 100, 9000, AnimRoot{ .a = &a });
    try testing.expectEqual(@as(f32, 1), a.t);
    try testing.expect(!u.needs_frame);
    // Changing `restart` starts it over.
    a.restart += 1;
    u.frame(200, 100, 10_000, AnimRoot{ .a = &a });
    try testing.expectEqual(@as(f32, 0), a.t);
    u.frame(200, 100, 10_600, AnimRoot{ .a = &a });
    try testing.expectApproxEqAbs(@as(f32, 0.5), a.t, 1e-6);
    // Looping, it goes from 0 to 1 over and over; reversing, back and forth.
    a.repeat = .loop;
    u.frame(200, 100, 11_850, AnimRoot{ .a = &a });
    try testing.expectApproxEqAbs(@as(f32, 0.75), a.t, 1e-6);
    try testing.expect(u.needs_frame);
    a.repeat = .reverse;
    u.frame(200, 100, 11_850, AnimRoot{ .a = &a });
    try testing.expectApproxEqAbs(@as(f32, 0.25), a.t, 1e-6);
    u.frame(200, 100, 12_350, AnimRoot{ .a = &a });
    try testing.expectApproxEqAbs(@as(f32, 0.25), a.t, 1e-6);
    try testing.expect(u.needs_frame);
}

test "what a popup paints is told apart by its shapes, clips and images, and not at all with a GPU area" {
    const hash = ui.WindowUi.paintedHash;
    const rect: gfx.Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    var a = gfx.Canvas.init(testing.allocator);
    defer a.deinit();
    a.begin(100, 50);
    a.fillRect(rect, red);
    var b = gfx.Canvas.init(testing.allocator);
    defer b.deinit();
    b.begin(100, 50);
    b.fillRect(rect, red);
    // The same shapes, the same.
    try testing.expectEqual(hash(&.{.{ .canvas = &a }}).?, hash(&.{.{ .canvas = &b }}).?);
    // A different colour, or a clip (here cutting nothing off), differs.
    b.begin(100, 50);
    b.fillRect(rect, blue);
    try testing.expect(hash(&.{.{ .canvas = &a }}).? != hash(&.{.{ .canvas = &b }}).?);
    b.begin(100, 50);
    b.setClip(.{ .x = 0, .y = 0, .w = 100, .h = 50 });
    b.fillRect(rect, red);
    try testing.expect(hash(&.{.{ .canvas = &a }}).? != hash(&.{.{ .canvas = &b }}).?);
    // A different image in the same place differs.
    const pixels: [4]u32 = @splat(0xffffffff);
    const one = gfx.Image.init(&pixels, 2, 2);
    const other = gfx.Image.init(&pixels, 2, 2);
    a.begin(100, 50);
    a.drawImage(&one, rect, 1);
    b.begin(100, 50);
    b.drawImage(&other, rect, 1);
    try testing.expect(hash(&.{.{ .canvas = &a }}).? != hash(&.{.{ .canvas = &b }}).?);
    // What a GPU area draws is not known.
    const noop = struct {
        fn f(_: *const anyopaque, _: *anyopaque, _: gfx.GpuArea) anyerror!void {}
    }.f;
    try testing.expectEqual(@as(?u64, null), hash(&.{ .{ .canvas = &a }, .{ .gpu = .{ .ctx = undefined, .f = noop, .area = undefined } } }));
}

test "Themed gives the widgets below it, and the menus they open, a theme of its own" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    // Notes the primary colour of the theme it is built and laid out in.
    const Probe = struct {
        built: *gfx.Color,
        laid_out: *gfx.Color,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            self.built.* = cx.theme().primary;
            return cx.make(ProbeLeaf{ .laid_out = self.laid_out });
        }
    };
    var outside: [2]gfx.Color = undefined;
    var inside: [2]gfx.Color = undefined;
    var nested: [2]gfx.Color = undefined;
    const Probes = struct {
        outside: *[2]gfx.Color,
        inside: *[2]gfx.Color,
        nested: *[2]gfx.Color,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            var reds = cx.theme().*;
            reds.primary = red;
            var blues = reds;
            blues.primary = blue;
            return cx.make(ui.Row{ .children = cx.makeAll(.{
                Probe{ .built = &self.outside[0], .laid_out = &self.outside[1] },
                ui.Themed{ .theme = reds, .child = cx.make(ui.Row{ .children = cx.makeAll(.{
                    Probe{ .built = &self.inside[0], .laid_out = &self.inside[1] },
                    ui.Themed{ .theme = blues, .child = cx.make(Probe{ .built = &self.nested[0], .laid_out = &self.nested[1] }) },
                }) }) },
            }) });
        }
    };
    const root: Probes = .{ .outside = &outside, .inside = &inside, .nested = &nested };
    u.frame(300, 100, 0, root);
    try testing.expectEqual(ui.Theme.dark.primary, outside[0]);
    try testing.expectEqual(ui.Theme.dark.primary, outside[1]);
    try testing.expectEqual(red, inside[0]);
    try testing.expectEqual(red, inside[1]);
    try testing.expectEqual(blue, nested[0]);
    try testing.expectEqual(blue, nested[1]);
    // The app's theme still reaches what is not themed, as it changes.
    u.theme = .light;
    u.frame(300, 100, 1, root);
    try testing.expectEqual(ui.Theme.light.primary, outside[0]);
    try testing.expectEqual(red, inside[0]);
    // A menu opened from inside is in the theme it was opened in.
    var leaves: std.ArrayList(*Node) = .empty;
    defer leaves.deinit(testing.allocator);
    try findAll(u.root.?, ProbeLeaf, &leaves);
    u.openMenu(leaves.items[1], .{ 10, 10 }, &.{.{ .label = "Copy" }});
    u.frame(300, 100, 2, root);
    try testing.expectEqual(red, u.menu_root.?.theme().primary);
    try testing.expectEqual(red, find(u.menu_root.?, ui.Text).?.theme().primary);
    u.closeMenu();
    u.openMenu(leaves.items[0], .{ 10, 10 }, &.{.{ .label = "Copy" }});
    u.frame(300, 100, 3, root);
    try testing.expectEqual(ui.Theme.light.primary, u.menu_root.?.theme().primary);
}

/// Notes the primary colour of the theme it is laid out in.
const ProbeLeaf = struct {
    laid_out: *gfx.Color,
    pub fn layout(self: *const ProbeLeaf, n: *Node, c: ui.Constraints) ui.Size {
        self.laid_out.* = n.theme().primary;
        return c.constrain(.{ .w = 20, .h = 20 });
    }
};

test "the baseline schemes are Material's, and say which is dark" {
    try testing.expectEqual(ui.Theme.Brightness.dark, ui.Theme.dark.brightness);
    try testing.expectEqual(ui.Theme.Brightness.light, ui.Theme.light.brightness);
    try testing.expectEqual(gfx.Color.rgb(0xf2b8b5), ui.Theme.dark.@"error");
    try testing.expectEqual(gfx.Color.rgb(0x601410), ui.Theme.dark.on_error);
    try testing.expectEqual(gfx.Color.rgb(0xb3261e), ui.Theme.light.@"error");
    try testing.expectEqual(gfx.Color.rgb(0xffffff), ui.Theme.light.on_error);
}

/// Frames until no image is loading (or a few seconds have gone).
fn frameUntilLoaded(u: *ui.WindowUi, root: anytype) !void {
    for (0..5000) |i| {
        u.frame(200, 200, i, root);
        var any_loading = false;
        var it = u.images.entries.valueIterator();
        while (it.next()) |e| any_loading = any_loading or e.*.status == .loading;
        if (!any_loading) return;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

test "an image loads in the background, showing what it is given meanwhile, or nothing" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    var pixels: [12 * 8]u32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = 0xff000000 | @as(u32, @intCast(i)) * 0x010203;
    const png = try gfx.png.encode(testing.allocator, &pixels, 12, 8);
    defer testing.allocator.free(png);
    const ImageRoot = struct {
        source: ui.Image.Source,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            const spinner = struct {
                fn f(c: *Context) Widget {
                    return c.make(ui.Spinner{ .size = 30 });
                }
            }.f;
            const broken = struct {
                fn f(c: *Context) Widget {
                    return c.make(ui.Text{ .text = "broken" });
                }
            }.f;
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.Row{ .children = cx.makeAll(.{
                ui.Image{ .source = self.source, .loading = .func(spinner), .failed = .func(broken) },
                ui.Image{ .source = self.source },
            }) }) });
        }
    };
    var root: ImageRoot = .{ .source = .{ .bytes = png } };
    // While it loads: the spinner, and nothing.
    u.frame(200, 200, 0, root);
    if (find(u.root.?, ui.Spinner) == null) return error.NoSpinner;
    try testing.expect(find(u.root.?, ui.image.Picture) == null);
    try frameUntilLoaded(u, root);
    var pictures: std.ArrayList(*Node) = .empty;
    defer pictures.deinit(testing.allocator);
    try findAll(u.root.?, ui.image.Picture, &pictures);
    try testing.expectEqual(@as(usize, 2), pictures.items.len);
    try testing.expectEqual(ui.Size{ .w = 12, .h = 8 }, pictures.items[0].size);
    try testing.expect(find(u.root.?, ui.Spinner) == null);
    const shown = pictures.items[0].widget.as(ui.image.Picture).?.image;
    try testing.expectEqualSlices(u32, &pixels, shown.pixels);

    // From a file, a file:// URL, and a data: URL.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile(std.testing.io, "pic.png", .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, png);
    }
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &dir_buf)];
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/pic.png", .{dir});
    defer testing.allocator.free(path);
    const file_url = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{path});
    defer testing.allocator.free(file_url);
    const b64 = try testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
    defer testing.allocator.free(b64);
    const data_url = try std.fmt.allocPrint(testing.allocator, "data:image/png;base64,{s}", .{std.base64.standard.Encoder.encode(b64, png)});
    defer testing.allocator.free(data_url);
    for ([_]ui.Image.Source{ .{ .file = path }, .{ .url = file_url }, .{ .url = data_url } }) |source| {
        root = .{ .source = source };
        try frameUntilLoaded(u, root);
        pictures.clearRetainingCapacity();
        try findAll(u.root.?, ui.image.Picture, &pictures);
        try testing.expectEqual(@as(usize, 2), pictures.items.len);
        try testing.expectEqualSlices(u32, &pixels, pictures.items[0].widget.as(ui.image.Picture).?.image.pixels);
    }

    // What cannot be loaded: what `failed` makes, and nothing.
    for ([_]ui.Image.Source{ .{ .bytes = "not an image" }, .{ .file = "/no/such/file.png" }, .{ .url = "gopher://example.com/a.png" } }) |source| {
        root = .{ .source = source };
        try frameUntilLoaded(u, root);
        try testing.expectEqualStrings("broken", find(u.root.?, ui.Text).?.widget.as(ui.Text).?.text);
        try testing.expect(find(u.root.?, ui.image.Picture) == null);
    }

    // Not shown for a while: let go of.
    const before = u.images.entries.count();
    root = .{ .source = .{ .image = shown } };
    u.frame(200, 200, 10 * std.time.ns_per_s, root);
    try testing.expectEqual(before, u.images.entries.count());
    u.frame(200, 200, 100 * std.time.ns_per_s, root);
    try testing.expectEqual(@as(usize, 0), u.images.entries.count());
}

test "an image too big for the GPU is made smaller to fit" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    const w = 3000;
    const h = 30;
    const pixels = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(pixels);
    for (pixels, 0..) |*p, i| p.* = if (i % w < w / 2) 0xffff0000 else 0xff0000ff;
    const png = try gfx.png.encode(testing.allocator, pixels, w, h);
    defer testing.allocator.free(png);
    const ImageRoot = struct {
        png: []const u8,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Image{ .source = .{ .bytes = self.png } });
        }
    };
    try frameUntilLoaded(u, ImageRoot{ .png = png });
    const pic = find(u.root.?, ui.image.Picture).?.widget.as(ui.image.Picture).?.image;
    try testing.expectEqual(@as(u32, gfx.Image.max_size), pic.width);
    try testing.expectEqual(@as(u32, 20), pic.height);
    try testing.expectEqual(@as(u32, 0xffff0000), pic.pixels[0]);
    try testing.expectEqual(@as(u32, 0xff0000ff), pic.pixels[pic.width - 1]);
}

const MapTiles = struct {
    pictures: [2]gfx.Image,
    /// Levels further in than this are not there yet.
    ready_to: u8 = 30,
    shapes: ?*const ui.MapSource.VectorTile = null,

    pub fn tile(s: *MapTiles, req: ui.MapSource.Request) ui.MapSource.Tile {
        if (req.id.z > s.ready_to) return .pending;
        if (s.shapes) |v| return .{ .vector = v };
        return .{ .image = .{ .image = &s.pictures[req.id.x % 2] } };
    }
};

const MapApp = struct {
    tiles: *MapTiles,
    position: *ui.MapPosition,
    show_globe: bool,
    style: ?*const ui.MapStyle = null,

    fn move(position: *ui.MapPosition, to: ui.MapPosition) void {
        position.* = to;
    }

    pub fn build(self: *const MapApp, cx: *Context) Widget {
        return cx.make(ui.MapView{
            .source = .of(self.tiles, .{}),
            .position = self.position.*,
            .on_move = .of(self.position, move),
            .show_globe = self.show_globe,
            .style = self.style,
            .space = .rgb(0x000000),
            .atmosphere = false,
        });
    }
};

test "a map view shows its source's tiles, flat or on a globe, and those further out while they come" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    var tiles: MapTiles = .{ .pictures = .{
        gfx.Image.init(&.{ 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000 }, 2, 2),
        gfx.Image.init(&.{ 0xff0000ff, 0xff0000ff, 0xff0000ff, 0xff0000ff }, 2, 2),
    } };
    // Flat, at zoom 1 (the world 512 across), with 0° in the middle: the
    // western tiles (red) left of it, the eastern (blue) right.
    var position: ui.MapPosition = .{ .zoom = 1 };
    u.frame(400, 300, 0, MapApp{ .tiles = &tiles, .position = &position, .show_globe = false });
    var img = try Image.init(u, 400, 300);
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(100, 150));
    try testing.expectEqual(@as(u32, 0xff0000ff), img.at(300, 150));
    img.deinit();
    // Those not there yet: the one further out that is (red) instead.
    tiles.ready_to = 0;
    u.frame(400, 300, 1, MapApp{ .tiles = &tiles, .position = &position, .show_globe = false });
    img = try Image.init(u, 400, 300);
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(300, 150));
    img.deinit();
    tiles.ready_to = 30;

    // Zoomed out, a globe in space: at its middle the tile there, and
    // black around it.
    position = .{ .center = .{ .lon = 45 }, .zoom = 1 };
    u.frame(400, 300, 2, MapApp{ .tiles = &tiles, .position = &position, .show_globe = true });
    img = try Image.init(u, 400, 300);
    try testing.expectEqual(@as(u32, 0xff0000ff), img.at(200, 150));
    try testing.expectEqual(@as(u32, 0xff000000), img.at(5, 5));
    img.deinit();

    // Shapes, in a style: the tile filled green.
    const outline = [_]ui.MapSource.VectorTile.Point{ .{ 0, 0 }, .{ 4096, 0 }, .{ 4096, 4096 }, .{ 0, 4096 } };
    const land = [_]ui.MapSource.VectorTile.Feature{.{ .geometry = .{ .polygon = &.{&outline} } }};
    const shapes: ui.MapSource.VectorTile = .{ .layers = &.{.{ .name = "land", .features = &land }} };
    tiles.shapes = &shapes;
    const style: ui.MapStyle = .{ .background = .rgb(0xffffff), .layers = &.{.{ .source_layer = "land", .draw = .{ .fill = .rgb(0x00ff00) } }} };
    u.frame(400, 300, 3, MapApp{ .tiles = &tiles, .position = &position, .show_globe = false, .style = &style });
    img = try Image.init(u, 400, 300);
    try testing.expectEqual(@as(u32, 0xff00ff00), img.at(200, 150));
    img.deinit();
}

test "a map view draws its vector tiles' pictures, keeps them as it moves, and draws them again in a new style" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    // Every tile: a red line down its west edge, 6 wide (half of it in the
    // tile to the west).
    const edge = [_]ui.MapSource.VectorTile.Point{ .{ 0, 0 }, .{ 0, 4096 } };
    const lines = [_]ui.MapSource.VectorTile.Feature{.{ .geometry = .{ .lines = &.{&edge} } }};
    const shapes: ui.MapSource.VectorTile = .{ .layers = &.{.{ .name = "edges", .features = &lines }} };
    var tiles: MapTiles = .{ .pictures = undefined, .shapes = &shapes };
    const red_lines: ui.MapStyle = .{ .background = .rgb(0xffffff), .layers = &.{.{ .draw = .{ .line = .{ .color = .rgb(0xff0000), .width = 6 } } }} };
    // Flat at zoom 1: the world 512 across, 0° (the tiles' edge) in the
    // middle.
    var position: ui.MapPosition = .{ .zoom = 1 };
    u.frame(400, 300, 0, MapApp{ .tiles = &tiles, .position = &position, .show_globe = false, .style = &red_lines });
    const map = find(u.root.?, ui.MapView).?;
    const pics = map.state(ui.MapView.State).pictures.?;
    // Those there was no time for in a frame come in the next ones (drawn
    // as shapes meanwhile).
    var frame_no: u64 = 1;
    while (pics.entries.count() < 4 and frame_no < 20) : (frame_no += 1) {
        try testing.expect(u.needs_frame);
        u.frame(400, 300, frame_no, MapApp{ .tiles = &tiles, .position = &position, .show_globe = false, .style = &red_lines });
    }
    try testing.expectEqual(@as(u32, 4), pics.entries.count());
    // The line on both sides of the edge: the west tile's picture has the
    // half of it in it from the east tile.
    var img = try Image.init(u, 400, 300);
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(198, 150));
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(201, 150));
    try testing.expectEqual(@as(u32, 0xffffffff), img.at(190, 150));
    img.deinit();

    // Moved a little: the same pictures.
    const before = pics.entries.get(.{ .z = 1, .x = 0, .y = 0 }).?;
    position.center.lon = 10;
    u.frame(400, 300, frame_no, MapApp{ .tiles = &tiles, .position = &position, .show_globe = false, .style = &red_lines });
    try testing.expectEqual(before, pics.entries.get(.{ .z = 1, .x = 0, .y = 0 }).?);

    // In another style: drawn again, in it.
    const blue_lines: ui.MapStyle = .{ .background = .rgb(0xffffff), .layers = &.{.{ .draw = .{ .line = .{ .color = .rgb(0x0000ff), .width = 6 } } }} };
    position.center.lon = 0;
    while (frame_no < 40) : (frame_no += 1) {
        u.frame(400, 300, frame_no + 1, MapApp{ .tiles = &tiles, .position = &position, .show_globe = false, .style = &blue_lines });
        if (!u.needs_frame) break;
    }
    img = try Image.init(u, 400, 300);
    try testing.expectEqual(@as(u32, 0xff0000ff), img.at(198, 150));
    img.deinit();
}

test "a map view without a handler for moves is not moved" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    var tiles: MapTiles = .{ .pictures = .{
        gfx.Image.init(&.{0xffff0000}, 1, 1),
        gfx.Image.init(&.{0xff0000ff}, 1, 1),
    } };
    const Still = struct {
        tiles: *MapTiles,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.MapView{ .source = .of(self.tiles, .{}), .position = .{ .zoom = 1 }, .show_globe = false });
        }
    };
    u.frame(400, 300, 0, Still{ .tiles = &tiles });
    u.pointerMotion(.{ 200, 150 });
    try testing.expect(u.cursor() != ui.PointerCursor.grab);
    u.pointerButton(.{ 200, 150 }, .left, true);
    try testing.expect(u.cursor() != ui.PointerCursor.grabbing);
    u.pointerMotion(.{ 250, 150 });
    u.pointerButton(.{ 250, 150 }, .left, false);
}

test "a map view is dragged and zoomed" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    var tiles: MapTiles = .{ .pictures = .{
        gfx.Image.init(&.{0xffff0000}, 1, 1),
        gfx.Image.init(&.{0xff0000ff}, 1, 1),
    } };
    var position: ui.MapPosition = .{ .center = .{ .lon = 45 }, .zoom = 1 };
    const app: MapApp = .{ .tiles = &tiles, .position = &position, .show_globe = false };
    u.frame(400, 300, 0, app);
    // Dragged 50 pixels right: the world (512 across) moves with it.
    u.pointerMotion(.{ 200, 150 });
    u.pointerButton(.{ 200, 150 }, .left, true);
    try testing.expectEqual(ui.PointerCursor.grabbing, u.cursor());
    u.pointerMotion(.{ 250, 150 });
    u.pointerButton(.{ 250, 150 }, .left, false);
    try testing.expectApproxEqAbs(45 - 50.0 / 512.0 * 360.0, position.center.lon, 1e-6);
    try testing.expectApproxEqAbs(0, position.center.lat, 1e-6);
    // The wheel zooms in about the pointer: what is under it stays.
    u.frame(400, 300, 1, app);
    const before = ui.map_view.View.init(position, .{ 400, 300 }, .flat).unproject(.{ 300, 100 }).?;
    u.pointerScroll(.{ 300, 100 }, 0, -30);
    try testing.expectApproxEqAbs(2, position.zoom, 1e-6);
    const after = ui.map_view.View.init(position, .{ 400, 300 }, .flat).projectCoordinate(before);
    try testing.expectApproxEqAbs(300, after.pos[0], 1e-3);
    try testing.expectApproxEqAbs(100, after.pos[1], 1e-3);

    // Dragged on the globe, north and east: it turns, and the zoom stays.
    position = .{ .center = .{ .lat = 10, .lon = 20 }, .zoom = 2.5 };
    const globe: MapApp = .{ .tiles = &tiles, .position = &position, .show_globe = true };
    u.frame(400, 300, 2, globe);
    // (Away from the last press, so it is not a double click.)
    u.pointerMotion(.{ 220, 130 });
    u.pointerButton(.{ 220, 130 }, .left, true);
    for (1..6) |i| u.pointerMotion(.{ 220 - 10 * @as(f32, @floatFromInt(i)), 130 + 12 * @as(f32, @floatFromInt(i)) });
    u.pointerButton(.{ 170, 190 }, .left, false);
    try testing.expect(position.center.lat > 20 and position.center.lon > 20);
    try testing.expectEqual(@as(f64, 2.5), position.zoom);
}

/// A window whose two buffers are drawn in turn, as a compositor gives
/// them back, keeping what was drawn in each.
const TwoBufferWin = struct {
    const w = 900;
    const h = 800;
    width: u32 = w,
    height: u32 = h,
    pixels: [2][w * h]u32 = .{ @splat(0), @splat(0) },
    drawn: [2]u64 = .{ 0, 0 },
    frames: u64 = 0,
    back: usize = 0,

    pub fn beginSoftwareFrame(win: *TwoBufferWin) !gfx.software.Image {
        win.back = @intCast(win.frames % 2);
        return .{ .pixels = &win.pixels[win.back], .width = w, .height = h };
    }
    pub fn bufferAge(win: *const TwoBufferWin) u32 {
        const d = win.drawn[win.back];
        return if (d == 0) 0 else @intCast(win.frames + 1 - d);
    }
    pub fn showDamaged(win: *TwoBufferWin, _: ?[]const gfx.Viewport) !void {
        win.frames += 1;
        win.drawn[win.back] = win.frames;
    }
};

test "text drawn as the glyph atlas fills is drawn whole, in every buffer" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    u.attachRenderer(u.shared.software_renderer.renderer(), false);
    var win: TwoBufferWin = .{};
    u.attachWindow(&win, null);
    // Lines of letters far apart, one changing size each frame (so the
    // atlas fills with glyphs of new sizes, now and then part way through
    // a frame).
    const Lines = struct {
        sizes: [3]f32,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            var lines: [3]Widget = undefined;
            for (&lines, self.sizes) |*l, size| l.* = cx.make(ui.Text{ .text = "abcdefghijklm", .style = .{ .size = size }, .wrap = false });
            return cx.make(ui.Column{ .fill = false, .cross_axis_alignment = .start, .spacing = 160, .children = cx.arena.dupe(Widget, &lines) catch &.{} });
        }
    };
    var lines: Lines = .{ .sizes = @splat(20) };
    var want: [TwoBufferWin.w * TwoBufferWin.h]u32 = undefined;
    for (0..90) |f| {
        lines.sizes[f % lines.sizes.len] = 24 + @as(f32, @floatFromInt(f * 37 % 71));
        u.frame(TwoBufferWin.w, TwoBufferWin.h, f, lines);
        _ = try u.present(&win, 0xff000000);
        @memset(&want, 0xff000000);
        var want_img: gfx.software.Image = .{ .pixels = &want, .width = TwoBufferWin.w, .height = TwoBufferWin.h };
        try u.render(&want_img, null);
        try testing.expectEqualSlices(u32, &want, &win.pixels[win.back]);
    }
}

test "an image shows a part of itself: of pixels in memory, or only that part loaded" {
    const u = try ui.WindowUi.create(testing.allocator, testing.io, null);
    defer u.destroy();
    // Red above, blue below, 12 by 8.
    var pixels: [12 * 8]u32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = if (i < 12 * 4) 0xffff0000 else 0xff0000ff;
    const pic = gfx.Image.init(&pixels, 12, 8);
    const png = try gfx.png.encode(testing.allocator, &pixels, 12, 8);
    defer testing.allocator.free(png);
    const PartRoot = struct {
        source: ui.Image.Source,
        region: ui.Image.Region,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            const broken = struct {
                fn f(c: *Context) Widget {
                    return c.make(ui.SizedBox{ .width = 7, .height = 7 });
                }
            }.f;
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.Image{ .source = self.source, .region = self.region, .failed = .func(broken) }) });
        }
    };
    for ([_]ui.Image.Source{ .{ .image = &pic }, .{ .bytes = png } }) |source| {
        // The bottom half, from the third column: as big as it, and blue.
        const root: PartRoot = .{ .source = source, .region = .{ .x = 2, .y = 4, .w = 6, .h = 10 } };
        try frameUntilLoaded(u, root);
        u.frame(200, 200, 9000, root);
        const node = find(u.root.?, ui.Image).?;
        try testing.expectEqual(ui.Size{ .w = 6, .h = 4 }, node.children.items[0].size);
        var img = try Image.init(u, 200, 200);
        try testing.expectEqual(@as(u32, 0xff0000ff), img.at(0, 0));
        try testing.expectEqual(@as(u32, 0xff0000ff), img.at(5, 3));
        try testing.expectEqual(@as(u32, 0xff000000), img.at(6, 0));
        img.deinit();
        // A part beyond the picture: what shows when it cannot be loaded.
        const off: PartRoot = .{ .source = source, .region = .{ .x = 20, .y = 0, .w = 2, .h = 2 } };
        try frameUntilLoaded(u, off);
        u.frame(200, 200, 9001, off);
        try testing.expectEqual(ui.Size{ .w = 7, .h = 7 }, find(u.root.?, ui.Image).?.children.items[0].size);
    }
}

const A11yApp = struct {
    pressed: *u32,
    checked: *bool,
    level: *f32,

    fn press(c: *u32) void {
        c.* += 1;
    }
    fn check(b: *bool, v: bool) void {
        b.* = v;
    }
    fn setLevel(l: *f32, v: f32) void {
        l.* = v;
    }

    pub fn build(self: *const A11yApp, cx: *Context) Widget {
        return cx.make(ui.Column{ .fill = false, .cross_axis_alignment = .start, .children = cx.makeAll(.{
            ui.Accessible{ .role = .heading, .level = 1, .label = "Settings", .child = cx.make(ui.Text{ .text = "Settings" }) },
            ui.Text{ .text = "Hello" },
            ui.FilledButton{ .label = "OK", .on_press = .of(self.pressed, press) },
            ui.CheckboxRow{ .value = self.checked.*, .label = "Wi-Fi", .on_changed = .of(self.checked, check) },
            ui.Slider{ .value = self.level.*, .min = 0, .max = 10, .divisions = 10, .on_changed = .of(self.level, setLevel) },
            ui.Accessible{ .label = "Zoom in", .child = cx.make(ui.IconButton{ .icon = .add, .on_press = .of(self.pressed, press) }) },
            ui.Tooltip{ .text = "Remove it", .child = cx.make(ui.IconButton{ .icon = .remove, .on_press = .of(self.pressed, press) }) },
            ui.Accessible{ .hidden = true, .child = cx.make(ui.Text{ .text = "decoration" }) },
            ui.TextField{ .placeholder = "Name", .initial = "Ada" },
        }) });
    }
};

test "the accessibility tree: roles, names, states and values of the widgets, and what describes them" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    var pressed: u32 = 0;
    var checked = false;
    var level: f32 = 3;
    const app: A11yApp = .{ .pressed = &pressed, .checked = &checked, .level = &level };
    u.frame(400, 600, 0, app);
    var next: u32 = 2;
    const tree = try ui.accessibility.build(testing.allocator, u.root.?, &.{}, "Test", .{ 400, 600 }, u.focused, ui.accessibility.window_id, &next);
    defer {
        tree.deinit();
        testing.allocator.destroy(tree);
    }
    const objs = tree.objects;
    try testing.expectEqual(ui.accessibility.window_id, objs[0].id);
    try testing.expectEqualStrings("Test", objs[0].info.label);
    // The window's children, in order: the heading (its text in it), the
    // paragraph of text, the button (its label its name, its children
    // presentational, as ARIA has a button's), the check box, the slider,
    // the two icon buttons (named by what describes them), and the field;
    // the hidden text not at all.
    const want = [_]struct { ui.Accessible.Role, []const u8, usize }{
        .{ .heading, "Settings", 1 }, .{ .paragraph, "", 0 },   .{ .button, "OK", 0 },
        .{ .checkbox, "Wi-Fi", 0 },   .{ .slider, "", 0 },      .{ .button, "Zoom in", 0 },
        .{ .button, "remove", 0 },    .{ .textbox, "Name", 0 },
    };
    try testing.expectEqual(want.len, objs[0].children.len);
    for (want, objs[0].children) |w, ci| {
        try testing.expectEqual(w[0], objs[ci].info.role);
        try testing.expectEqualStrings(w[1], objs[ci].info.label);
        try testing.expectEqual(w[2], objs[ci].children.len);
    }
    try testing.expectEqualStrings("Hello", objs[objs[0].children[1]].info.text.?);
    try testing.expectEqual(want.len + 2, objs.len);
    // The tooltip describes the button it names already.
    try testing.expectEqualStrings("Remove it", objs[objs[0].children[6]].info.description);
    // States and values; actions do what pressing does.
    const check_box = &objs[objs[0].children[3]];
    try testing.expectEqual(ui.Accessible.Tristate.false, check_box.info.checked.?);
    check_box.info.activate.?.call();
    try testing.expect(checked);
    const slider = &objs[objs[0].children[4]];
    try testing.expectEqual(@as(f64, 3), slider.info.valuenow.?);
    try testing.expectEqual(@as(f64, 10), slider.info.valuemax.?);
    slider.info.set_value.?.call(7);
    try testing.expectEqual(@as(f32, 7), level);
    objs[objs[0].children[2]].info.activate.?.call();
    try testing.expectEqual(@as(u32, 1), pressed);
    const field = &objs[objs[0].children[7]];
    try testing.expectEqualStrings("Ada", field.info.text.?);
    try testing.expect(!field.info.readonly and !field.info.multiline);
    // The heading's level.
    try testing.expectEqual(@as(u8, 1), objs[objs[0].children[0]].info.level.?);
    // Ids last from frame to frame.
    u.frame(400, 600, 1, app);
    const again = try ui.accessibility.build(testing.allocator, u.root.?, &.{}, "Test", .{ 400, 600 }, u.focused, ui.accessibility.window_id, &next);
    defer {
        again.deinit();
        testing.allocator.destroy(again);
    }
    for (objs, again.objects) |a, b| try testing.expectEqual(a.id, b.id);
    try testing.expectEqual(ui.Accessible.Tristate.true, again.objects[again.objects[0].children[3]].info.checked.?);
}

const FocusApp = struct {
    pressed: *u32,
    checked: *bool,
    level: *f32,
    choice: *u8,
    doc: *ui.TextDocument,

    fn press(c: *u32) void {
        c.* += 1;
    }
    fn check(b: *bool, v: bool) void {
        b.* = v;
    }
    fn setLevel(l: *f32, v: f32) void {
        l.* = v;
    }
    fn choose(c: *u8, v: u8) void {
        c.* = v;
    }

    pub fn build(self: *const FocusApp, cx: *Context) Widget {
        return cx.make(ui.Column{
            .fill = false,
            .cross_axis_alignment = .start,
            .children = cx.makeAll(.{
                ui.FilledButton{ .label = "A", .on_press = .of(self.pressed, press) },
                ui.TextField{ .placeholder = "Name" },
                ui.CheckboxRow{ .value = self.checked.*, .label = "Wi-Fi", .on_changed = .of(self.checked, check) },
                ui.Slider{ .value = self.level.*, .min = 0, .max = 10, .divisions = 10, .on_changed = .of(self.level, setLevel) },
                // Disabled: passed over.
                cx.make(ui.FilledButton{ .label = "Off" }),
                ui.RadioRow(u8){ .value = 1, .group_value = self.choice.*, .label = "One", .on_changed = .of(self.choice, choose) },
                ui.RadioRow(u8){ .value = 2, .group_value = self.choice.*, .label = "Two", .on_changed = .of(self.choice, choose) },
                ui.SizedBox{ .width = 200, .height = 60, .child = cx.make(ui.TextArea{ .doc = self.doc }) },
            }),
        });
    }
};

fn pressKey(u: *ui.WindowUi, root: anytype, key: ui.KeyboardKey, mods: struct { shift: bool = false, ctrl: bool = false }) void {
    u.key(.{ .key = key, .pressed = true, .shift = mods.shift, .ctrl = mods.ctrl });
    u.key(.{ .key = key, .pressed = false, .shift = mods.shift, .ctrl = mods.ctrl });
    u.frame(400, 600, 0, root);
}

/// The widget of type `T` the focus is in (it, or one it is in).
fn focusedIn(u: *ui.WindowUi, comptime T: type) bool {
    var at = u.focused;
    while (at) |n| : (at = n.parent) if (n.widget.is(T)) return true;
    return false;
}

test "Tab moves the keyboard's focus through what takes it, and keys use what has it" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    var pressed: u32 = 0;
    var checked = false;
    var level: f32 = 3;
    var choice: u8 = 1;
    var doc = try ui.TextDocument.init(testing.allocator, "");
    defer doc.deinit();
    const app: FocusApp = .{ .pressed = &pressed, .checked = &checked, .level = &level, .choice = &choice, .doc = &doc };
    u.frame(400, 600, 0, app);
    try testing.expect(u.focused == null);

    // In order, past the disabled button, round to the start.
    const order = [_]type{ ui.FilledButton, ui.TextField, ui.CheckboxRow, ui.Slider, ui.RadioRow(u8), ui.RadioRow(u8), ui.TextArea };
    inline for (order) |T| {
        pressKey(u, app, .tab, .{});
        try testing.expect(focusedIn(u, T));
        try testing.expect(u.focus_visible);
    }
    // The text area types a tab (as spaces); Control and Tab moves on.
    pressKey(u, app, .tab, .{});
    try testing.expect(doc.text().len > 0 and std.mem.trim(u8, doc.text(), " \t").len == 0);
    pressKey(u, app, .tab, .{ .ctrl = true });
    try testing.expect(focusedIn(u, ui.FilledButton));
    // And back.
    pressKey(u, app, .tab, .{ .shift = true });
    try testing.expect(focusedIn(u, ui.TextArea));

    // Space and Enter press what has the focus.
    pressKey(u, app, .tab, .{ .ctrl = true });
    pressKey(u, app, .space, .{});
    pressKey(u, app, .enter, .{});
    try testing.expectEqual(@as(u32, 2), pressed);
    pressKey(u, app, .tab, .{});
    pressKey(u, app, .tab, .{});
    pressKey(u, app, .space, .{});
    try testing.expect(checked);
    // The arrows move the slider, and choose among the radio buttons.
    pressKey(u, app, .tab, .{});
    pressKey(u, app, .right, .{});
    try testing.expectEqual(@as(f32, 4), level);
    pressKey(u, app, .end, .{});
    try testing.expectEqual(@as(f32, 10), level);
    pressKey(u, app, .tab, .{});
    pressKey(u, app, .down, .{});
    try testing.expectEqual(@as(u8, 2), choice);
    pressKey(u, app, .down, .{});
    try testing.expectEqual(@as(u8, 1), choice);

    // The pointer pressed: the ring goes.
    u.pointerMotion(.{ 399, 599 });
    u.pointerButton(.{ 399, 599 }, .left, true);
    u.pointerButton(.{ 399, 599 }, .left, false);
    try testing.expect(!u.focus_visible);

    // What assistive technologies are told: the check box takes the
    // focus, and the radio button has it.
    // (And clicked off it, it has the focus no more.)
    try testing.expect(u.focused == null);
    u.frame(400, 600, 1, app);
    var next: u32 = 2;
    pressKey(u, app, .tab, .{ .shift = true });
    // (From the text area, which takes Tab: Control, Shift and Tab.)
    pressKey(u, app, .tab, .{ .shift = true, .ctrl = true });
    const tree = try ui.accessibility.build(testing.allocator, u.root.?, &.{}, "", .{ 400, 600 }, u.focused, ui.accessibility.window_id, &next);
    defer {
        tree.deinit();
        testing.allocator.destroy(tree);
    }
    const objs = tree.objects;
    try testing.expect(objs[objs[0].children[2]].focusable);
    const f = tree.focused.?;
    try testing.expectEqual(ui.Accessible.Role.radio, objs[f].info.role);
    try testing.expect(objs[f].focused);
    try testing.expect(!objs[objs[0].children[2]].focused);
}

const DialogApp = struct {
    dismissed: *u32,
    fn dismiss(d: *u32) void {
        d.* += 1;
    }
    pub fn build(self: *const DialogApp, cx: *Context) Widget {
        return cx.make(ui.Dialog{
            .title = "Delete it?",
            .confirm_label = "Delete",
            .on_confirm = .of(self.dismissed, dismiss),
            .dismiss_label = "Cancel",
            .on_dismiss = .of(self.dismissed, dismiss),
            .child = cx.make(ui.Column{ .children = cx.makeAll(.{
                ui.FilledButton{ .label = "Behind", .on_press = .of(self.dismissed, dismiss) },
            }) }),
        });
    }
};

test "an open dialog keeps the focus in it, and Escape dismisses it" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    var dismissed: u32 = 0;
    const app: DialogApp = .{ .dismissed = &dismissed };
    u.frame(400, 600, 0, app);
    const dialog = find(u.root.?, ui.Dialog).?;
    const behind = find(u.root.?, ui.FilledButton).?;
    // Round its two buttons, never to the one behind it.
    var seen: [4]?*Node = @splat(null);
    for (&seen) |*s| {
        pressKey(u, app, .tab, .{});
        try testing.expect(ui.focus.within(u.focused.?, dialog));
        try testing.expect(!ui.focus.within(u.focused.?, behind));
        s.* = u.focused;
    }
    try testing.expect(seen[0] != seen[1] and seen[0] == seen[2]);
    pressKey(u, app, .escape, .{});
    try testing.expectEqual(@as(u32, 1), dismissed);
}

test "a menu opened from the keyboard has the focus, and gives it back" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.WindowUi.create(testing.allocator, testing.io, &fira);
    defer u.destroy();
    var picked: usize = 0;
    const MenuApp = struct {
        picked: *usize,
        fn pick(p: *usize, i: usize) void {
            p.* = i;
        }
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.DropdownMenu{
                .options = &.{ .{ .label = "Red" }, .{ .label = "Green" }, .{ .label = "Blue" } },
                .selected = self.picked.*,
                .on_selected = .of(self.picked, pick),
            }) });
        }
    };
    const app: MenuApp = .{ .picked = &picked };
    u.frame(400, 600, 0, app);
    pressKey(u, app, .tab, .{});
    const opener = u.focused.?;
    pressKey(u, app, .enter, .{});
    try testing.expect(u.menu != null);
    try testing.expect(ui.focus.within(u.focused.?, u.menu_root.?));
    pressKey(u, app, .down, .{});
    pressKey(u, app, .down, .{});
    pressKey(u, app, .enter, .{});
    try testing.expectEqual(@as(usize, 2), picked);
    try testing.expect(u.menu == null);
    try testing.expectEqual(opener, u.focused.?);
}

test "a Waker woken by a task on the Io ends the wait for it" {
    if (!window.sys.is_linux) return error.SkipZigTest;
    const io = testing.io;
    const u = try ui.WindowUi.createDefault(testing.allocator, io);
    defer u.destroy();
    const waker = u.waker();
    const Task = struct {
        fn run(t_io: std.Io, w: ui.Waker) void {
            t_io.sleep(.fromMilliseconds(10), .awake) catch return;
            w.wake();
        }
    };
    const start = window.nowNs(io);
    var task = io.async(Task.run, .{ io, waker });
    defer task.cancel(io);
    try window.waitSources(io, &.{u.wakeSource().?}, 5 * std.time.ns_per_s);
    task.await(io);
    try testing.expect(window.nowNs(io) - start < std.time.ns_per_s);
    try testing.expect(u.takeWakes());
    try testing.expect(!u.takeWakes());
}

/// A display of `AppWin`s, which the system asks to close (or the app to
/// quit) when a test says.
const AppDisplay = struct {
    windows: [4]AppWin = @splat(.{}),
    len: usize = 0,
    quit_requested: bool = false,

    const AppWin = struct {
        width: u32 = 64,
        height: u32 = 48,
        pixels: [64 * 48]u32 = @splat(0),
        shown: u32 = 0,
        close_requested: bool = false,
        closed: bool = false,
        parent: ?*AppWin = null,

        pub const Options = struct {
            title: []const u8,
            parent: ?*AppWin = null,
        };
        pub fn beginSoftwareFrame(w: *AppWin) !gfx.software.Image {
            return .{ .pixels = &w.pixels, .width = w.width, .height = w.height };
        }
        pub fn showDamaged(w: *AppWin, _: ?[]const gfx.Viewport) !void {
            w.shown += 1;
        }
        pub fn close(w: *AppWin) void {
            w.closed = true;
        }
    };

    pub fn openWindow(d: *AppDisplay, o: AppWin.Options) !*AppWin {
        if (d.len == d.windows.len) return error.TooManyWindows;
        d.windows[d.len] = .{ .parent = o.parent };
        d.len += 1;
        return &d.windows[d.len - 1];
    }
    pub fn takeQuitRequest(d: *AppDisplay) bool {
        defer d.quit_requested = false;
        return d.quit_requested;
    }
};

test "an app's windows are closed as their options say, and it quits as its own say" {
    var display: AppDisplay = .{};
    const Seen = struct {
        quit_asked: u32 = 0,
        last_closed: u32 = 0,
        close_asked: ?*ui.Window = null,
        fn quitAsked(s: *@This()) void {
            s.quit_asked += 1;
        }
        fn lastClosed(s: *@This()) void {
            s.last_closed += 1;
        }
        fn closeAsked(s: *@This(), w: *ui.Window) void {
            s.close_asked = w;
        }
    };
    var seen: Seen = .{};
    const app = try ui.App.init(testing.allocator, testing.io, .empty, .{
        .display = .of(&display),
        .on_quit_request = .{ .call = .of(&seen, Seen.quitAsked) },
        .on_last_window_closed = .{ .call = .of(&seen, Seen.lastClosed) },
    });
    defer app.deinit();
    app.shared.attachRenderer(app.shared.software_renderer.renderer(), false);
    const box: ui.SizedBox = .{ .width = 10, .height = 10 };
    const main = try app.openWindow(.{ .title = "main", .root = .of(&box) });
    const kept = try app.openWindow(.{ .title = "kept", .root = .of(&box), .parent = main, .on_close_request = .{ .call = .of(&seen, Seen.closeAsked) } });
    const closing = try app.openWindow(.{ .title = "closing", .root = .of(&box), .on_close_request = .close });
    try testing.expectEqual(&display.windows[0], display.windows[1].parent.?);

    // Each window is drawn by the app, once (until something changes).
    try testing.expect(try app.step(0));
    for (display.windows[0..3]) |w| try testing.expectEqual(@as(u32, 1), w.shown);
    try testing.expect(try app.step(0));
    try testing.expectEqual(@as(u32, 1), display.windows[0].shown);

    // By default, a request to close is the app's to act on: nothing is
    // done. Asked to, the window closes, or the callback is called.
    for (&display.windows) |*w| w.close_requested = true;
    try testing.expect(try app.step(0));
    try testing.expect(!main.isClosed());
    try testing.expectEqual(kept, seen.close_asked.?);
    try testing.expect(!kept.isClosed());
    try testing.expect(closing.isClosed());
    try testing.expect(display.windows[2].closed);
    // A closed window's handle stays (until it is destroyed), and it is
    // drawn no more.
    try testing.expect(try app.step(0));
    try testing.expectEqual(@as(u32, 1), display.windows[2].shown);
    closing.destroy();

    // The system's request to quit is told; the app goes on until it quits.
    display.quit_requested = true;
    try testing.expect(try app.step(0));
    try testing.expectEqual(@as(u32, 1), seen.quit_asked);

    // Its last window closed, it is told so, and goes on with none.
    kept.close();
    try testing.expect(try app.step(0));
    try testing.expectEqual(@as(u32, 0), seen.last_closed);
    main.close();
    try testing.expect(try app.step(0));
    try testing.expectEqual(@as(u32, 1), seen.last_closed);
    try testing.expect(try app.step(0));
    try testing.expectEqual(@as(u32, 1), seen.last_closed);

    // A window opened again; told to, it quits once that is closed.
    app.on_last_window_closed = .quit;
    const again = try app.openWindow(.{ .title = "again", .root = .of(&box) });
    try testing.expect(try app.step(0));
    again.close();
    try testing.expect(!try app.step(0));
}

test "makeAll makes each of a tuple's values a widget, taking widgets as they are" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    const S = struct {
        var all: []const Widget = &.{};
        fn build(cx: *Context) Widget {
            const keyed = cx.make(ui.SizedBox{ .width = 5, .height = 5 }).withKey(7);
            all = cx.makeAll(.{ ui.SizedBox{ .width = 10, .height = 20 }, keyed });
            return cx.make(ui.Column{ .children = all });
        }
    };
    u.frame(100, 100, 0, Root(S.build){});
    try testing.expectEqual(@as(usize, 2), S.all.len);
    try testing.expectEqual(@as(f32, 20), S.all[0].as(ui.SizedBox).?.height.?);
    try testing.expectEqual(@as(?u64, 7), S.all[1].key);
}

test "an anchor opens a menu just below its widget, and one taken from no widget nothing" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    const S = struct {
        var anchor: ui.WidgetAnchor = .{};
        fn build(cx: *Context) Widget {
            return cx.make(ui.Padding{ .padding = .all(20), .child = cx.make(ui.Align{
                .alignment = .top_left,
                .child = cx.make(Kept{}),
            }) });
        }
        const Kept = struct {
            pub fn build(_: *const @This(), cx: *Context) Widget {
                anchor = cx.anchor();
                return cx.make(ui.SizedBox{ .width = 50, .height = 30 });
            }
        };
    };
    u.frame(200, 200, 0, Root(S.build){});
    (ui.WidgetAnchor{}).openMenu(&.{.{ .label = "Nothing" }});
    try testing.expect(u.menu == null);
    S.anchor.openMenu(&.{.{ .label = "Cut" }});
    try testing.expect(u.menu != null);
    try testing.expectEqual(ui.Point{ 20, 50 }, u.menu.?.at);
}

fn findLabel(n: *Node, label: []const u8) ?*Node {
    if (n.widget.as(ui.Text)) |t| if (std.mem.eql(u8, t.text, label)) return n;
    for (n.children.items) |ch| if (findLabel(ch, label)) |f| return f;
    return null;
}

fn middleOf(n: *Node) ui.Point {
    const at = n.position();
    return .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
}

test "menu items open submenus, which keys move in and out of, and dividers set items apart" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    const S = struct {
        var hits: u32 = 0;
        fn bump(p: *u32) void {
            p.* += 1;
        }
        const deeper = [_]ui.MenuItem{.{ .label = "Deepest", .on_press = .of(&hits, bump) }};
        const sub = [_]ui.MenuItem{
            .{ .label = "Deep", .on_press = .of(&hits, bump) },
            ui.MenuItem.divider,
            .{ .label = "Further", .submenu = &deeper },
        };
        const items = [_]ui.MenuItem{
            .{ .label = "Plain", .leading_icon = .folder, .on_press = .of(&hits, bump) },
            .{ .label = "Check", .kind = .checkbox, .checked = true, .on_press = .of(&hits, bump) },
            ui.MenuItem.divider,
            .{ .label = "More", .submenu = &sub },
        };
        fn build(cx: *Context) Widget {
            return cx.make(ui.SizedBox{ .width = 10, .height = 10 });
        }
    };
    const app = Root(S.build){};
    u.frame(600, 400, 0, app);
    u.openMenu(u.root.?, .{ 20, 20 }, &S.items);
    u.frame(600, 400, 1, app);
    const root = u.menu_root.?;
    const cascade = root.child(0);
    try testing.expectEqual(@as(usize, 1), cascade.childCount());
    // Items, a divider (shorter), and room around them.
    const panel = cascade.child(0);
    try testing.expectEqual(3 * ui.menu.item_height + ui.menu.divider_height + 2 * ui.menu.padding, panel.size.h);

    // The pointer on an item with a submenu opens it, beside the menu.
    const more = findLabel(root, "More").?;
    u.pointerMotion(middleOf(more));
    u.frame(600, 400, 2, app);
    try testing.expectEqual(@as(usize, 2), cascade.childCount());
    try testing.expect(cascade.child(1).position()[0] > panel.position()[0] + panel.size.w - 8);
    try testing.expect(ui.menu.Menu.contains(root, middleOf(cascade.child(1))));
    // On another item, it closes.
    u.pointerMotion(middleOf(findLabel(root, "Plain").?));
    u.frame(600, 400, 3, app);
    try testing.expectEqual(@as(usize, 1), cascade.childCount());

    // Pressing the item in the submenu does it, and closes everything.
    u.pointerMotion(middleOf(findLabel(root, "More").?));
    u.frame(600, 400, 4, app);
    clickAt(u, middleOf(findLabel(root, "Deep").?));
    try testing.expectEqual(@as(u32, 1), S.hits);
    try testing.expect(u.menu == null);

    // From the keyboard: down to "More" (past the divider), right into
    // its submenu, which has the focus, and left out of it.
    u.openMenu(u.root.?, .{ 20, 20 }, &S.items);
    u.frame(600, 400, 5, app);
    const root2 = u.menu_root.?;
    pressKey(u, app, .down, .{});
    pressKey(u, app, .down, .{});
    pressKey(u, app, .down, .{});
    try testing.expect(ui.focus.within(findLabel(root2, "More").?, u.focused.?));
    pressKey(u, app, .right, .{});
    pressKey(u, app, .down, .{});
    try testing.expectEqual(@as(usize, 2), root2.child(0).childCount());
    try testing.expect(ui.focus.within(u.focused.?, root2.child(0).child(1)));
    // Down wraps within the submenu: it does not leave for the menu.
    pressKey(u, app, .down, .{});
    try testing.expect(ui.focus.within(u.focused.?, root2.child(0).child(1)));
    pressKey(u, app, .left, .{});
    try testing.expectEqual(@as(usize, 1), root2.child(0).childCount());
    try testing.expect(ui.focus.within(findLabel(root2, "More").?, u.focused.?));
    pressKey(u, app, .escape, .{});
    try testing.expect(u.menu == null);
}

test "a dropdown's options are menu items: icons, dividers and disabled choices, with the choice made marked" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    var picked: usize = 99;
    const App = struct {
        picked: *usize,
        fn pick(p: *usize, i: usize) void {
            p.* = i;
        }
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.DropdownMenu{
                .options = &.{
                    .{ .label = "Light", .leading_icon = .light_mode },
                    .{ .label = "Dark", .leading_icon = .dark_mode, .enabled = false },
                    ui.MenuItem.divider,
                    .{ .label = "Automatic", .leading_icon = .settings },
                },
                .selected = 3,
                .on_selected = .of(self.picked, pick),
            }) });
        }
    };
    const app: App = .{ .picked = &picked };
    u.frame(400, 400, 0, app);
    // The button shows the choice made, with its icon.
    try testing.expect(findLabel(u.root.?, "Automatic") != null);
    click(u, find(u.root.?, ui.DropdownMenu).?);
    u.frame(400, 400, 1, app);
    const root = u.menu_root.?;
    const panel = root.child(0).child(0);
    try testing.expectEqual(@as(usize, 4), find(panel, ui.Column).?.childCount());
    // A disabled choice does nothing; the one after the divider is index 3.
    clickAt(u, middleOf(findLabel(root, "Dark").?));
    try testing.expectEqual(@as(usize, 99), picked);
    try testing.expect(u.menu != null);
    clickAt(u, middleOf(findLabel(root, "Automatic").?));
    try testing.expectEqual(@as(usize, 3), picked);
    try testing.expect(u.menu == null);
}

test "text measured again only when its text, font or width changes" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    const S = struct {
        var words: []const u8 = "one two three four";
        var width: f32 = 400;
        var size: f32 = 16;
        fn build(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = width, .child = cx.make(ui.Text{
                .text = words,
                .style = .{ .size = size },
            }) }) });
        }
    };
    const app = Root(S.build){};
    u.frame(600, 400, 0, app);
    const text = find(u.root.?, ui.Text).?;
    const one_line = text.size;
    const widest = text.content.?.w;
    // The same again: the same size.
    u.frame(600, 400, 1, app);
    try testing.expectEqual(one_line, text.size);
    try testing.expectEqual(widest, text.content.?.w);
    // Narrower, it wraps.
    S.width = 60;
    u.frame(600, 400, 2, app);
    try testing.expect(text.size.h > one_line.h);
    // Back to the width it had: the old measurement.
    S.width = 400;
    u.frame(600, 400, 3, app);
    try testing.expectEqual(one_line, text.size);
    // Other words, and another size.
    S.words = "one";
    u.frame(600, 400, 4, app);
    try testing.expect(text.content.?.w < widest);
    S.words = "one two three four";
    S.size = 32;
    u.frame(600, 400, 5, app);
    try testing.expect(text.content.?.w > widest);
}

test "a badge sits on its child's corner as Material 3's does, the child's size the whole widget's" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    const S = struct {
        fn build(cx: *Context) Widget {
            return cx.make(ui.Padding{ .padding = .all(20), .child = cx.make(ui.Row{ .fill = false, .spacing = 40, .children = cx.makeAll(.{
                ui.Badge{ .count = 3, .child = cx.make(ui.Icon{ .icon = .mail, .size = 24 }) },
                ui.Badge{ .child = cx.make(ui.Icon{ .icon = .chat, .size = 24 }) },
            }) }) });
        }
    };
    u.frame(300, 200, 0, Root(S.build){});
    var badges: std.ArrayList(*Node) = .empty;
    defer badges.deinit(testing.allocator);
    try findAll(u.root.?, ui.Badge, &badges);
    try testing.expectEqual(@as(usize, 2), badges.items.len);
    for (badges.items, 0..) |b, i| {
        const box = b.child(0);
        // As big as the icon, the badge not counted as overflowing it.
        try testing.expectEqual(@as(f32, 24), box.size.w);
        try testing.expectEqual(@as(f32, 24), box.size.h);
        try testing.expect(!box.overflow.any());
        const pill = box.child(1);
        if (i == 0) {
            // A pill 16 high, from 12 in from the icon's right edge, its
            // bottom 14 below the icon's top (so 2 above it).
            try testing.expectEqual(@as(f32, 16), pill.size.h);
            try testing.expectEqual(@as(f32, 16), pill.size.w);
            try testing.expectEqual(@as(f32, 12), pill.offset[0]);
            try testing.expectEqual(@as(f32, -2), pill.offset[1]);
        } else {
            // A 6 px dot inside the icon's top-right corner.
            try testing.expectEqual(@as(f32, 6), pill.size.w);
            try testing.expectEqual(@as(f32, 18), pill.offset[0]);
            try testing.expectEqual(@as(f32, 0), pill.offset[1]);
        }
    }
}

test "text running up, left or down is the upright text turned, and as big turned" {
    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    u.attachRenderer(u.shared.software_renderer.renderer(), false);
    const Case = struct {
        direction: gfx.Canvas.TextDirection,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.Text{
                .text = "Card 1\nWrites",
                .style = .{ .size = 14, .color = .rgb(0xffffff) },
                .direction = self.direction,
            }) });
        }
    };
    const n = 120;
    u.theme = .dark;
    u.frame(n, n, 0, Case{ .direction = .right });
    const upright = find(u.root.?, ui.Text).?.size;
    var want = try Image.init(u, n, n);
    defer want.deinit();
    const bg = want.at(n - 1, n - 1);
    const w: u32 = @intFromFloat(upright.w);
    const h: u32 = @intFromFloat(upright.h);
    for ([_]gfx.Canvas.TextDirection{ .up, .left, .down }, 1..) |dir, frame| {
        u.frame(n, n, frame, Case{ .direction = dir });
        const size = find(u.root.?, ui.Text).?.size;
        const sideways = dir != .left;
        try testing.expectEqual(if (sideways) upright.h else upright.w, size.w);
        try testing.expectEqual(if (sideways) upright.w else upright.h, size.h);
        var got = try Image.init(u, n, n);
        defer got.deinit();
        var lit: u32 = 0;
        for (0..h) |y| for (0..w) |x| {
            const xi: u32 = @intCast(x);
            const yi: u32 = @intCast(y);
            const to: [2]u32 = switch (dir) {
                .up => .{ yi, w - 1 - xi },
                .left => .{ w - 1 - xi, h - 1 - yi },
                .down => .{ h - 1 - yi, xi },
                .right => unreachable,
            };
            try testing.expectEqual(want.at(xi, yi), got.at(to[0], to[1]));
            lit += @intFromBool(want.at(xi, yi) != bg);
        };
        try testing.expect(lit > 40);
    }
}

/// A scene that draws nothing: the area shows its clear colour.
const ClearScene = struct {
    pub fn render(_: *const ClearScene, _: anytype) !void {}
};

fn signalTimelineLater(io: std.Io, ctx: *const gfx.VulkanContext, sem: gfx.vulkan.VkSemaphore, value: u64) void {
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    ctx.signalTimeline(sem, value) catch {};
}

test "VulkanArea draws with the app's context once the app's work is done" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var app_ctx = gfx.VulkanContext.init(testing.allocator) catch return error.SkipZigTest;
    defer app_ctx.deinit();
    if (!app_ctx.supportsTimelines()) return error.SkipZigTest;
    const sem = try app_ctx.createTimeline(0);
    defer app_ctx.destroyTimeline(sem);

    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    u.attachRenderer(u.shared.software_renderer.renderer(), false);
    u.frame(40, 30, 0, ui.VulkanArea(ClearScene){
        .scene = .{},
        .samples = 1,
        .clear_color = red,
        .context = &app_ctx,
        .wait = .{ .semaphore = sem, .value = 1 },
    });

    // Drawn once another thread says the work it waits for is done (50ms on).
    const start = std.Io.Clock.awake.now(testing.io);
    const thread = try std.Thread.spawn(.{}, signalTimelineLater, .{ testing.io, &app_ctx, sem, 1 });
    const img = try Image.init(u, 40, 30);
    defer img.deinit();
    const waited = start.durationTo(std.Io.Clock.awake.now(testing.io));
    thread.join();
    try testing.expect(waited.toMilliseconds() >= 40);
    try testing.expectEqual(red.toArgb(), img.at(20, 15));

    // The app's context is still the app's once the area is gone.
    u.frame(40, 30, 0, ui.SizedBox{});
    const other = try app_ctx.createTimeline(0);
    app_ctx.destroyTimeline(other);
}

const FenceFromSibling = struct {
    share: *const gfx.OpenGlContext,
    fence: ?gfx.opengl.Wait = null,
    sibling: ?gfx.OpenGlContext = null,

    /// Makes a context sharing `share`'s on this thread, and a fence after
    /// its work, as an app drawing on another thread would.
    fn run(f: *FenceFromSibling) void {
        var sibling = gfx.OpenGlContext.initSharing(testing.allocator, f.share) catch return;
        sibling.gl.ClearColor(0, 1, 0, 1);
        f.fence = sibling.createFence() catch null;
        f.sibling = sibling;
    }
};

test "OpenGlArea draws with the app's context once another context's work is done" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var app_ctx = gfx.OpenGlContext.init(testing.allocator) catch return error.SkipZigTest;
    defer app_ctx.deinit();

    var job: FenceFromSibling = .{ .share = &app_ctx };
    const thread = try std.Thread.spawn(.{}, FenceFromSibling.run, .{&job});
    thread.join();
    var sibling = job.sibling orelse return error.SkipZigTest;
    defer sibling.deinit();
    const fence = job.fence orelse return error.SkipZigTest;
    defer sibling.destroyFence(fence);

    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    u.attachRenderer(u.shared.software_renderer.renderer(), false);
    u.frame(40, 30, 0, ui.OpenGlArea(ClearScene){
        .scene = .{},
        .samples = 1,
        .clear_color = blue,
        .context = &app_ctx,
        .wait = fence,
    });
    const img = try Image.init(u, 40, 30);
    defer img.deinit();
    try testing.expectEqual(blue.toArgb(), img.at(20, 15));
}

/// A window whose buffer is a real dmabuf, from GBM: drawn into on the GPU
/// (`beginDmabufFrame`), or mapped and drawn into on the CPU.
const GbmWin = struct {
    dev: *const window.wayland.DmaBufDevice,
    buf: window.wayland.DmaBufDevice.Allocation,
    width: u32,
    height: u32,
    /// The shadow's margin around the content, and the frame drawn in it.
    margin: u32 = 0,
    frame: ?gfx.renderer.WindowFrame = null,
    map_data: ?*anyopaque = null,
    cpu_frames: u32 = 0,
    shown: u32 = 0,

    const ar24: u32 = std.mem.readInt(u32, "AR24", .little);

    fn init(dev: *const window.wayland.DmaBufDevice, width: u32, height: u32) !GbmWin {
        return .{ .dev = dev, .buf = try dev.alloc(width, height, ar24), .width = width, .height = height };
    }

    fn deinit(w: *GbmWin) void {
        _ = std.os.linux.close(w.buf.dmabuf_fd);
        w.dev.gbm.bo_destroy(w.buf.bo);
    }

    /// The whole buffer, mapped (until `unmap`).
    fn map(w: *GbmWin) !gfx.software.Image {
        var stride: u32 = 0;
        const ptr = w.dev.gbm.bo_map(w.buf.bo, 0, 0, w.width, w.height, window.wayland.DmaBufDevice.gbm_bo_transfer_read_write, &stride, &w.map_data) orelse return error.MapFailed;
        const words: [*]u32 = @ptrCast(@alignCast(ptr));
        return .{ .pixels = words[0 .. @as(usize, stride / 4) * w.height], .width = w.width, .height = w.height, .stride = stride / 4 };
    }

    fn unmap(w: *GbmWin) void {
        w.dev.gbm.bo_unmap(w.buf.bo, w.map_data);
        w.map_data = null;
    }

    /// The content, inside the margin.
    fn content(w: *GbmWin, img: gfx.software.Image) gfx.software.Image {
        const at = @as(usize, w.margin) * img.rowStride() + w.margin;
        return .{ .pixels = img.pixels[at..], .width = w.width - 2 * w.margin, .height = w.height - 2 * w.margin, .stride = img.stride };
    }

    pub fn beginSoftwareFrame(w: *GbmWin) !gfx.software.Image {
        w.cpu_frames += 1;
        return w.content(try w.map());
    }

    pub fn beginDmabufFrame(w: *GbmWin) ?gfx.DmabufTarget {
        return .{
            .id = 1,
            .fd = w.buf.dmabuf_fd,
            .fourcc = ar24,
            .modifier = w.buf.modifier,
            .offset = w.buf.offset,
            .stride = w.buf.stride,
            .width = w.width,
            .height = w.height,
            .origin = .{ w.margin, w.margin },
            .content = .{ w.width - 2 * w.margin, w.height - 2 * w.margin },
            .cpu = .{ .ctx = w, .begin = cpuBegin, .end = cpuEnd },
            .frame = w.frame,
        };
    }

    fn cpuBegin(ctx: *anyopaque) anyerror!gfx.software.Image {
        const w: *GbmWin = @ptrCast(@alignCast(ctx));
        return w.content(try w.map());
    }

    fn cpuEnd(ctx: *anyopaque) void {
        const w: *GbmWin = @ptrCast(@alignCast(ctx));
        w.unmap();
    }

    pub fn showDamaged(w: *GbmWin, _: ?[]const gfx.Viewport) !void {
        if (w.map_data != null) w.unmap();
        w.shown += 1;
    }
};

test "OpenGlRenderer draws straight into a dmabuf, with an OpenGlArea copied in on the GPU" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var dev = window.wayland.DmaBufDevice.open() orelse return error.SkipZigTest;
    defer dev.close();
    var gl = gfx.OpenGlRenderer.initDefault(testing.allocator) catch return error.SkipZigTest;
    defer gl.deinit();
    var win = GbmWin.init(&dev, 64, 48) catch return error.SkipZigTest;
    defer win.deinit();

    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    u.attachRenderer(gl.renderer(), false);
    u.attachWindow(&win, null);
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Row{ .children = cx.makeAll(.{
                ui.SizedBox{ .width = 32 },
                ui.Expanded{ .child = cx.make(ui.OpenGlArea(ClearScene){ .scene = .{}, .samples = 1, .clear_color = red, .min_width = 0, .min_height = 0 }) },
            }) });
        }
    }.f;
    u.frame(64, 48, 0, Root(build){});
    try testing.expect(try u.present(&win, 0xff102030));
    // Drawn on the GPU: it was never mapped for the CPU to draw.
    try testing.expectEqual(@as(u32, 0), win.cpu_frames);

    const img = try win.map();
    defer win.unmap();
    // The area on the right, the right way up; the window's clear on the left.
    try testing.expectEqual(red.toArgb(), img.at(48, 2));
    try testing.expectEqual(red.toArgb(), img.at(48, 45));
    try testing.expect(img.at(8, 24) != red.toArgb());
}

test "OpenGlRenderer draws a window's frame round what it draws into a dmabuf" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var dev = window.wayland.DmaBufDevice.open() orelse return error.SkipZigTest;
    defer dev.close();
    var gl = gfx.OpenGlRenderer.initDefault(testing.allocator) catch return error.SkipZigTest;
    defer gl.deinit();
    var win = GbmWin.init(&dev, 96, 80) catch return error.SkipZigTest;
    defer win.deinit();
    win.margin = 16;
    win.frame = .{ .radius = 8, .scale = 1 };

    const u = try ui.WindowUi.createDefault(testing.allocator, testing.io);
    defer u.destroy();
    u.attachRenderer(gl.renderer(), false);
    u.attachWindow(&win, null);
    u.frame(64, 48, 0, ui.SizedBox{});
    try testing.expect(try u.present(&win, 0xff102030));
    try testing.expectEqual(@as(u32, 0), win.cpu_frames);

    const img = try win.map();
    defer win.unmap();
    const alpha = struct {
        fn f(px: u32) u32 {
            return px >> 24;
        }
    }.f;
    // The content's middle is the window's clear, its corner rounded off,
    // and the shadow under it (below it more than above) fades out into
    // the margin.
    try testing.expectEqual(@as(u32, 0xff102030), img.at(48, 40));
    try testing.expect(alpha(img.at(16, 16)) < 0xff);
    try testing.expect(alpha(img.at(48, 66)) > 0);
    try testing.expect(alpha(img.at(48, 66)) > alpha(img.at(48, 13)));
    try testing.expectEqual(@as(u32, 0), alpha(img.at(1, 1)));
}
