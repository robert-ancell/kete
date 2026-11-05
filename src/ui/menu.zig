//! Menu: a list of actions shown above everything else
//! at a point (where the right button was pressed, say): see
//! `WindowUi.openMenu`. Its items can have icons, a keyboard shortcut and
//! a check, and be set apart by dividers; one can open a submenu, which
//! opens beside the menu. Pressing an item closes the menu and does the
//! action; pressing anywhere else, or Escape, closes it. It goes down and
//! to the right of the point, or up or to the left where there is no room,
//! and stays in the window (`place`).

const a11y = @import("accessibility.zig");
const Node = @import("widget.zig").WidgetNode;
const std = @import("std");
const icons = @import("icons");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const focus_mod = @import("focus.zig");
const PointerInteraction = @import("pressable.zig").PointerInteraction;
const Pressable = @import("pressable.zig").Pressable;
const RoundedBox = @import("rounded_box.zig").RoundedBox;
const HorizontalDivider = @import("divider.zig").HorizontalDivider;
const Icon = @import("icon.zig").Icon;
const SizedBox = @import("sized_box.zig").SizedBox;
const Padding = @import("padding.zig").Padding;
const Column = @import("flex.zig").Column;
const ScrollView = @import("scroll_view.zig").ScrollView;
const Row = @import("flex.zig").Row;
const Expanded = @import("expanded.zig").Expanded;
const Text = @import("text.zig").Text;

const Point = geometry.Point;
const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Context = widget.BuildContext;
const Callback = widget.Callback;
const Event = widget.Event;

/// One item of a `Menu`: an action, a choice that is checked or not, a
/// divider, or a door to a submenu.
///
/// ![A menu of items](images/Menu.png)
pub const Item = struct {
    /// The text of the item.
    label: []const u8 = "",
    /// What the item is.
    kind: Kind = .action,
    /// Whether a `checkbox` or `radio` item is checked.
    checked: bool = false,
    /// An icon before the text.
    leading_icon: ?icons.IconName = null,
    /// An icon after the text (and the shortcut).
    trailing_icon: ?icons.IconName = null,
    /// Its keyboard shortcut, shown at the right ("Ctrl+C").
    shortcut: []const u8 = "",
    /// Destructive action (e.g. delete): shown in the theme's error colour
    /// when enabled.
    destructive: bool = false,
    /// Shown dimmed, and not pressable, if not.
    enabled: bool = true,
    /// Called when it is pressed.
    on_press: ?Callback = null,
    /// The items of a menu that opens beside this one when it is pressed,
    /// or the pointer rests on it (an arrow shows at its right). Then
    /// `on_press`, `shortcut` and `trailing_icon` are not used. Menus are
    /// nested to three levels.
    submenu: []const Item = &.{},
    /// Kept at the bottom of the menu, in view, when the menu is too tall
    /// for the window and its other items scroll: for the items at its end
    /// (a divider too, to show them apart), such as one that manages what
    /// the others list.
    pinned: bool = false,

    /// What an item is.
    pub const Kind = enum {
        /// Does something when pressed.
        action,
        /// Turns something on or off: shows a check when `checked`.
        checkbox,
        /// One choice of several: tinted when `checked`.
        radio,
        /// A line between the items above and below; nothing else of it is
        /// used.
        divider,
    };

    /// A line between the items above and below.
    pub const divider: Item = .{ .kind = .divider };

    fn hasSubmenu(it: Item) bool {
        return it.kind != .divider and it.submenu.len > 0;
    }

    fn height(it: Item) f32 {
        return if (it.kind == .divider) divider_height else item_height;
    }
};

pub const width = 220;
pub const item_height = 44;
/// The height of a divider: its line, with room above and below.
pub const divider_height = 9;
/// Space above and below the items.
pub const padding = 8;
/// How far a submenu is over the menu it opens from.
const submenu_overlap = 4;
/// The most menus open at once (the menu, and its submenus).
const max_depth = 4;

/// How far down a menu of `items` the item at `index` starts (from the
/// top of its items, not its padding).
fn itemTop(items: []const Item, index: usize) f32 {
    var y: f32 = 0;
    for (items[0..index]) |it| y += it.height();
    return y;
}

/// A copy of `items`, their texts and submenus too, in `a`.
pub fn cloneItems(a: std.mem.Allocator, items: []const Item) std.mem.Allocator.Error![]Item {
    const out = try a.dupe(Item, items);
    for (out) |*it| {
        it.label = try a.dupe(u8, it.label);
        it.shortcut = try a.dupe(u8, it.shortcut);
        if (it.submenu.len > 0) it.submenu = try cloneItems(a, it.submenu);
    }
    return out;
}

/// The menu's items, on a surface, with the submenus open from them.
///
/// ![The Menu example](images/Menu.png)
///
/// ```zig
/// // In a callback (with `state.anchor = cx.anchor()` taken while building):
/// state.anchor.openMenu(&.{
///     .{ .label = "Cut", .leading_icon = .content_cut, .shortcut = "Ctrl+X", .on_press = .of(state, State.save) },
///     .{ .label = "Copy", .leading_icon = .content_copy, .shortcut = "Ctrl+C", .on_press = .of(state, State.save) },
///     .{ .label = "Paste", .leading_icon = .content_paste, .shortcut = "Ctrl+V" },
///     kete.MenuItem.divider,
///     .{ .label = "Sort by", .leading_icon = .sort, .submenu = &.{
///         .{ .label = "Name", .kind = .radio, .checked = true, .on_press = .of(state, State.save) },
///         .{ .label = "Date", .kind = .radio, .on_press = .of(state, State.save) },
///     } },
///     .{ .label = "Delete", .leading_icon = .delete, .destructive = true, .on_press = .of(state, State.save) },
/// });
/// ```
pub const Menu = struct {
    /// The menu's items, from top to bottom.
    items: []const Item,

    /// What is open, and where the menus are.
    pub const State = struct {
        /// The items of the menu, from the last build.
        items: []const Item = &.{},
        /// How many submenus are open.
        depth: usize = 0,
        /// The index of the item each open menu opened its submenu from (the
        /// menu's first item is `path[0]`'s menu).
        path: [max_depth - 1]u16 = @splat(0),
        /// The item of each menu that opened its submenu.
        rows: [max_depth - 1]?*Node = @splat(null),
        /// The menu that is to be given the keyboard's focus once it is made.
        focus_level: ?usize = null,
        /// Where the menu's top left is in the window, as last laid out.
        offset: Point = .{ 0, 0 },
        /// How far the menu itself is from the top left of everything open
        /// (nothing, until a submenu opens to its left or above it).
        origin: Point = .{ 0, 0 },
        /// The size of the menu itself.
        first_size: Size = .{ .w = 0, .h = 0 },

        /// The items of the menu at `level` (0 is the menu).
        fn itemsAt(st: *const State, level: usize) []const Item {
            var items = st.items;
            for (st.path[0..level]) |i| items = items[i].submenu;
            return items;
        }

        /// The pointer is over the item `index`, `row`, of the menu at
        /// `level`: the submenus of the menus below are closed, and its
        /// submenu opens if it has one.
        fn hover(st: *State, level: usize, index: usize, row: *Node) void {
            const items = st.itemsAt(level);
            const it = items[index];
            if (it.hasSubmenu() and it.enabled and level + 1 < max_depth) {
                if (st.depth == level + 1 and st.path[level] == index) return;
                st.path[level] = @intCast(index);
                st.rows[level] = row;
                st.depth = level + 1;
            } else {
                if (st.depth <= level) return;
                st.depth = level;
            }
            row.ui.needs_frame = true;
        }

        /// Opens the submenu of the item `index`, `row`, of the menu at
        /// `level`, and gives it the keyboard's focus if `focus`.
        fn open(st: *State, level: usize, index: usize, row: *Node, focus: bool) void {
            st.depth = 0;
            st.hover(level, index, row);
            if (focus) st.focus_level = level + 1;
            row.ui.needs_frame = true;
        }

        /// Closes the menu at `level` (not the first), and gives the item
        /// that opened it the focus.
        fn closeLevel(st: *State, level: usize) void {
            const row = st.rows[level - 1] orelse return;
            st.depth = level - 1;
            if (focus_mod.first(row)) |f| focus_mod.show(row.ui, f);
            row.ui.needs_frame = true;
        }
    };

    pub fn accessible(_: *const Menu, _: *Node) ?a11y.Info {
        return .{ .role = .menu, .orientation = .vertical };
    }

    pub fn build(self: *const Menu, cx: *Context, state: *State) Widget {
        state.items = self.items;
        // What is open is only as deep as the items still go.
        var level: usize = 0;
        var items = self.items;
        while (level < state.depth) : (level += 1) {
            const i = state.path[level];
            if (i >= items.len or !items[i].hasSubmenu()) break;
            items = items[i].submenu;
        }
        state.depth = level;

        const panels = cx.arena.alloc(Widget, state.depth + 1) catch return cx.make(SizedBox.empty);
        for (panels, 0..) |*panel, k| panel.* = cx.make(MenuPanel{ .menu = state, .level = k, .items = state.itemsAt(k) });
        return cx.make(MenuCascade{ .menu = state, .children = panels });
    }

    /// Gives the keyboard's focus to the submenu that is to have it (one
    /// opened with the keyboard), once it has been made.
    pub fn focusPending(root: *Node) void {
        if (root.widget.as(Menu) == null) return;
        const st = root.state(State);
        const level = st.focus_level orelse return;
        if (level > st.depth) {
            st.focus_level = null;
            return;
        }
        const cascade = root.child(0);
        if (level >= cascade.childCount()) return;
        if (focus_mod.first(cascade.child(level))) |f| {
            st.focus_level = null;
            focus_mod.show(root.ui, f);
        }
    }

    /// Whether `pos` (in the window) is over the menu or one of its
    /// submenus.
    pub fn contains(root: *const Node, pos: Point) bool {
        const x = pos[0] - root.offset[0];
        const y = pos[1] - root.offset[1];
        if (x < 0 or y < 0 or x >= root.size.w or y >= root.size.h) return false;
        if (root.widget.as(Menu) == null) return true;
        const cascade = root.children.items[0];
        for (cascade.children.items) |panel| {
            const px = x - cascade.offset[0] - panel.offset[0];
            const py = y - cascade.offset[1] - panel.offset[1];
            if (px >= 0 and py >= 0 and px < panel.size.w and py < panel.size.h) return true;
        }
        return false;
    }
};

/// The menu and its open submenus, side by side: the first where the
/// menu goes, the others beside the item they opened from (to its left
/// where there is no room at its right), all inside the window.
const MenuCascade = struct {
    menu: *Menu.State,
    children: []const Widget = &.{},

    pub fn layout(self: *const MenuCascade, n: *Node, c: Constraints) Size {
        const st = self.menu;
        const win = n.ui.menu_window;
        const at: Point = if (n.ui.menu) |m| m.at else .{ 0, 0 };
        const loose = c.loosen();
        var rects: [max_depth]geometry.Rect = undefined;
        const count = n.childCount();

        // No menu is taller than the window: what doesn't fit scrolls.
        const fit: Constraints = .{ .max_w = loose.max_w, .max_h = win.h };
        const first = n.child(0).layout(fit);
        st.first_size = first;
        const p = place(win, at, first);
        rects[0] = .{ .x = p[0], .y = p[1], .w = first.w, .h = first.h };
        for (1..count) |k| {
            const s = n.child(k).layout(fit);
            const parent = rects[k - 1];
            const row_top = parent.y + rowTop(n.child(k - 1), st.rows[k - 1], st.itemsAt(k - 1), st.path[k - 1]);
            var x = parent.x + parent.w - submenu_overlap;
            if (x + s.w > win.w) {
                const left = parent.x - s.w + submenu_overlap;
                x = if (left >= 0) left else @max(@min(x, win.w - s.w), 0);
            }
            const y = std.math.clamp(row_top - padding, 0, @max(win.h - s.h, 0));
            rects[k] = .{ .x = x, .y = y, .w = s.w, .h = s.h };
        }

        var lo: Point = .{ rects[0].x, rects[0].y };
        var hi: Point = .{ rects[0].x + rects[0].w, rects[0].y + rects[0].h };
        for (rects[1..count]) |r| {
            lo = .{ @min(lo[0], r.x), @min(lo[1], r.y) };
            hi = .{ @max(hi[0], r.x + r.w), @max(hi[1], r.y + r.h) };
        }
        for (rects[0..count], 0..) |r, k| n.child(k).place(r.x - lo[0], r.y - lo[1]);
        st.offset = lo;
        st.origin = .{ rects[0].x - lo[0], rects[0].y - lo[1] };
        return .{ .w = hi[0] - lo[0], .h = hi[1] - lo[1] };
    }

    pub fn minSize(_: *const MenuCascade, n: *Node, c: Constraints) Size {
        return n.child(0).minSize(c.loosen());
    }

    /// How far down the menu `panel` the item `index` (`row`, if it is
    /// known) is, as laid out: scrolled, or pinned at the bottom.
    fn rowTop(panel: *Node, row: ?*Node, items: []const Item, index: usize) f32 {
        if (row) |r| {
            var y: f32 = 0;
            var at: ?*Node = r;
            while (at) |a| : (at = a.parent) {
                if (a == panel) return y;
                y += a.offset[1];
            }
        }
        return padding + itemTop(items, index);
    }
};

/// One menu's items, on a surface.
const MenuPanel = struct {
    menu: *Menu.State,
    /// 0 for the menu, 1 for the submenu of one of its items, and so on.
    level: usize,
    items: []const Item,

    pub fn accessible(self: *const MenuPanel, _: *Node) ?a11y.Info {
        if (self.level == 0) return null;
        return .{ .role = .menu, .orientation = .vertical };
    }

    pub fn build(self: *const MenuPanel, cx: *Context) Widget {
        const t = cx.theme();
        const rows = cx.arena.alloc(Widget, self.items.len) catch return cx.make(SizedBox.empty);
        // Room for icons before the labels, if any item has one.
        var leading = false;
        for (self.items) |it| {
            if (it.kind != .divider and (it.leading_icon != null or it.kind == .checkbox)) leading = true;
        }
        for (self.items, rows, 0..) |it, *row, i| {
            row.* = if (it.kind == .divider)
                cx.make(Padding{ .padding = .symmetric(0, 4), .child = cx.make(HorizontalDivider{}) })
            else
                cx.make(MenuRow{ .item = it, .menu = self.menu, .level = self.level, .index = i, .leading_slot = leading });
        }
        // The items pinned at the end stay below those that scroll.
        var first_pinned = self.items.len;
        while (first_pinned > 0 and self.items[first_pinned - 1].pinned) first_pinned -= 1;
        return cx.make(RoundedBox{
            .color = t.surface_container,
            .border_color = t.outline_variant,
            .radius = .all(4),
            .child = cx.make(SizedBox{ .width = width, .child = cx.make(Padding{
                .padding = .symmetric(0, padding),
                .child = cx.make(MenuItems{ .children = cx.makeAll(.{
                    ScrollView{ .child = cx.make(Column{ .fill = false, .cross_axis_alignment = .stretch, .children = rows[0..first_pinned] }) },
                    Column{ .fill = false, .cross_axis_alignment = .stretch, .children = rows[first_pinned..] },
                }) }),
            }) }),
        });
    }
};

/// A menu's items: those that scroll (in a scroll view, though they all
/// show if the menu fits the window), and those pinned below them.
const MenuItems = struct {
    children: []const Widget,

    pub fn layout(_: *const MenuItems, n: *Node, c: Constraints) Size {
        const w = c.max_w;
        const inner: Constraints = .{ .min_w = w, .max_w = w };
        const pinned = n.child(1).layout(inner);
        // The scroll view takes all the height it is given: its items,
        // measured on their own, say how much they want.
        const scroll = n.child(0);
        const want = if (scroll.childCount() > 0) scroll.child(0).layout(inner).h else 0;
        const h = if (c.boundedHeight()) @min(want, @max(c.max_h - pinned.h, 0)) else want;
        _ = scroll.layout(.tight(.{ .w = w, .h = h }));
        scroll.place(0, 0);
        n.child(1).place(0, h);
        return c.constrain(.{ .w = w, .h = h + pinned.h });
    }

    pub fn minSize(_: *const MenuItems, n: *Node, c: Constraints) Size {
        const w = c.max_w;
        const pinned = n.child(1).minSize(.{ .min_w = w, .max_w = w });
        return c.constrain(.{ .w = w, .h = pinned.h + item_height });
    }

    /// The menu's rows (and dividers), from top to bottom.
    fn rows(n: *Node, out: *std.ArrayList(*Node)) !void {
        const scroll = n.child(0);
        if (scroll.childCount() > 0) try out.appendSlice(n.ui.gpa, scroll.child(0).children.items);
        try out.appendSlice(n.ui.gpa, n.child(1).children.items);
    }

    /// Scrolls the items so that `row` (one that scrolls) shows.
    fn reveal(row: *Node) void {
        const column = row.parent orelse return;
        const scroll = column.parent orelse return;
        if (!scroll.widget.is(ScrollView)) return;
        const st = scroll.state(ScrollView.State);
        const top = row.offset[1];
        const bottom = top + row.size.h;
        const to = if (top < st.offset) top else if (bottom > st.offset + st.viewport) bottom - st.viewport else return;
        if (st.scrollTo(to)) row.ui.needs_frame = true;
    }
};

/// An item: its icon, label and shortcut, tinted when the pointer is over it or presses it.
const MenuRow = struct {
    item: Item,
    menu: *Menu.State,
    level: usize,
    index: usize,
    /// Whether there is room before the label for an icon or a check.
    leading_slot: bool,

    pub const State = struct {
        interaction: PointerInteraction = .{},
        /// Where the item is, from the last build.
        anchor: widget.WidgetAnchor = .{},
        /// The action, the UI (whose menu closes) and where the item is, from
        /// the last build.
        action: ?Callback = null,
        ui: ?*@import("runtime.zig").WindowUi = null,
        menu: ?*Menu.State = null,
        level: usize = 0,
        index: usize = 0,
        submenu: bool = false,

        fn press(s: *State) void {
            const menu = s.menu orelse return;
            if (s.submenu) {
                const row = s.anchor.node orelse return;
                const focus = if (s.ui) |u| u.focus_visible else false;
                menu.open(s.level, s.index, row, focus);
                return;
            }
            // Closed first: the action may open another.
            if (s.ui) |u| u.closeMenu();
            if (s.action) |a| a.call();
        }
    };

    fn opensSubmenu(self: *const MenuRow) bool {
        return self.item.hasSubmenu() and self.item.enabled and self.level + 1 < max_depth;
    }

    pub fn accessible(self: *const MenuRow, _: *Node) ?a11y.Info {
        const it = self.item;
        return .{
            .role = switch (it.kind) {
                .checkbox => .menuitemcheckbox,
                .radio => .menuitemradio,
                else => .menuitem,
            },
            .label = it.label,
            .keyshortcuts = it.shortcut,
            .activate = if (self.opensSubmenu()) null else it.on_press,
            .disabled = !it.enabled,
            .checked = if (it.kind == .checkbox or it.kind == .radio) (if (it.checked) .true else .false) else null,
            .haspopup = if (it.hasSubmenu()) .menu else null,
            .expanded = if (it.hasSubmenu()) self.menu.depth > self.level and self.menu.path[self.level] == self.index else null,
        };
    }

    pub fn event(self: *const MenuRow, n: *Node, e: Event) bool {
        switch (e) {
            .enter => {
                self.menu.hover(self.level, self.index, n);
                return false;
            },
            .key => |k| {
                if (!k.pressed) return false;
                switch (k.key) {
                    .right => {
                        if (!self.opensSubmenu()) return false;
                        self.menu.open(self.level, self.index, n, true);
                        return true;
                    },
                    .left => {
                        if (self.level == 0) return false;
                        self.menu.closeLevel(self.level);
                        return true;
                    },
                    .up, .down => return moveWithin(n, k.key == .down),
                    else => return false,
                }
            },
            else => return false,
        }
    }

    /// Moves the focus to the next item of the menu `n` is in that takes it
    /// (the previous, if not `forward`), round to the first at the end.
    fn moveWithin(n: *Node, forward: bool) bool {
        var menu = n.parent orelse return false;
        while (!menu.widget.is(MenuItems)) menu = menu.parent orelse return false;
        var items: std.ArrayList(*Node) = .empty;
        defer items.deinit(n.ui.gpa);
        MenuItems.rows(menu, &items) catch return false;
        var list: std.ArrayList(*Node) = .empty;
        defer list.deinit(n.ui.gpa);
        var now: ?usize = null;
        for (items.items) |item| {
            const f = focus_mod.first(item) orelse continue;
            if (n.ui.focused) |cur| if (focus_mod.within(cur, item)) {
                now = list.items.len;
            };
            list.append(n.ui.gpa, f) catch return false;
        }
        if (list.items.len == 0) return false;
        const len = list.items.len;
        const next = if (now) |i| (if (forward) (i + 1) % len else (i + len - 1) % len) else if (forward) 0 else len - 1;
        focus_mod.show(n.ui, list.items[next]);
        // The row (the item the focus is in) scrolled into view.
        for (items.items) |item| {
            if (focus_mod.within(list.items[next], item)) MenuItems.reveal(item);
        }
        return true;
    }

    pub fn build(self: *const MenuRow, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const it = self.item;
        const submenu = self.opensSubmenu();
        const enabled = it.enabled and (it.on_press != null or submenu);
        state.anchor = cx.anchor();
        state.action = if (enabled and !submenu) it.on_press else null;
        state.ui = cx.ui;
        state.menu = self.menu;
        state.level = self.level;
        state.index = self.index;
        state.submenu = submenu;
        const i = state.interaction;
        const open_here = self.menu.depth > self.level and self.menu.path[self.level] == self.index;
        const accent = if (it.destructive) t.@"error" else t.on_surface;
        const layer: f32 = if (!enabled) 0 else if (i.pressed) 0.10 else if (i.hovered or open_here) 0.08 else 0;
        const label_color = if (enabled) accent else t.on_surface.withAlpha(0.38);
        const hint_color = if (enabled) (if (it.destructive) t.@"error" else t.on_surface_variant) else t.on_surface.withAlpha(0.38);
        const chosen = it.kind == .radio and it.checked;
        const fill = if (layer > 0) accent.withAlpha(layer) else null;

        var parts: [4]Widget = undefined;
        var count: usize = 0;
        if (self.leading_slot) {
            const lead: ?icons.IconName = if (it.kind == .checkbox) (if (it.checked) .check else null) else it.leading_icon;
            parts[count] = if (lead) |name|
                cx.make(Icon{ .icon = name, .size = 24, .color = label_color })
            else
                cx.make(SizedBox{ .width = 24, .height = 24 });
            count += 1;
        }
        parts[count] = cx.make(Expanded{ .child = cx.make(Text{ .text = it.label, .style = .{ .size = t.label_size, .color = label_color }, .wrap = false, .ellipsis = true }) });
        count += 1;
        if (!submenu and it.shortcut.len > 0) {
            parts[count] = cx.make(Text{ .text = it.shortcut, .style = .{ .size = t.label_size, .color = hint_color }, .wrap = false });
            count += 1;
        }
        const trailing: ?icons.IconName = if (it.hasSubmenu()) .arrow_right else it.trailing_icon;
        if (trailing) |name| {
            parts[count] = cx.make(Icon{ .icon = name, .size = 24, .color = hint_color });
            count += 1;
        }

        return cx.make(Pressable{
            .on_press = if (enabled) .of(state, State.press) else null,
            .interaction = &state.interaction,
            .focus_radius = 0,
            .child = cx.make(RoundedBox{ .color = if (chosen) t.secondary_container else null, .child = cx.make(RoundedBox{ .color = fill, .child = cx.make(SizedBox{
                .height = item_height,
                .child = cx.make(Padding{ .padding = .symmetric(12, 0), .child = cx.make(Row{ .spacing = 12, .children = parts[0..count] }) }),
            }) }) }),
        });
    }
};

/// Where a menu `size` big goes for a point `at`, in a window `window`
/// big: down and to the right of the point; up or to the left of it where
/// there is no room that way but is the other; and slid into the window
/// if neither way fits.
pub fn place(window: Size, at: Point, size: Size) Point {
    return .{ axis(at[0], size.w, window.w), axis(at[1], size.h, window.h) };
}

fn axis(at: f32, size: f32, room: f32) f32 {
    if (at + size <= room) return at;
    if (at - size >= 0) return at - size;
    return @max(@min(at, room - size), 0);
}

const testing = std.testing;

test "menus go down and right, flipped or slid where there is no room" {
    const win: Size = .{ .w = 800, .h = 600 };
    const sz: Size = .{ .w = 200, .h = 150 };
    try testing.expectEqual(Point{ 100, 50 }, place(win, .{ 100, 50 }, sz));
    // Near the bottom right corner: up and to the left.
    try testing.expectEqual(Point{ 550, 400 }, place(win, .{ 750, 550 }, sz));
    // Too tall to go either way: slid in, its top showing first.
    try testing.expectEqual(Point{ 100, 0 }, place(win, .{ 100, 50 }, .{ .w = 200, .h = 700 }));
    try testing.expectEqual(Point{ 100, 350 }, place(win, .{ 100, 500 }, sz));
}
