//! Grid: a grid of many items all the same size, as many to a row as it
//! takes for none to be wider than `cell.w`, sharing its width (as
//! Material's grids, and Flutter's `GridView.extent`, are), of which only
//! those that show are made. The items are
//! made by a function, given their index, and only for the rows in view
//! (and a row either side) of the scroll view it is in. `Grid.fixed` is a
//! grid of widgets already made, and `Grid.list` a list: one column of
//! items as wide as it (a cell width of `Grid.fill`).
//! Because every cell is the same size, how big the grid is, and where
//! each item goes, is known without making them. Without a width to fill
//! (in a row, say), its cells are `cell.w` wide, all in one row.
//!
//!     cx.make(ui.ScrollView{ .child = cx.make(ui.Grid{
//!         .count = files.len,
//!         .cell = .{ .w = 128, .h = 124 },
//!         .item = .of(view, View.tile),
//!     }) })
//!
//! A long list, made as it scrolls:
//!
//!     cx.make(ui.ScrollView{ .child = cx.make(ui.Grid.list(lines.len, 22, .of(view, View.line))) })
//!
//! The items made are those of the frame before (so they are built with
//! the rest of the tree); if the scroll view shows other rows once laid
//! out, they are made then. Items are matched to their nodes by index,
//! unless the item has a key.

const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Rect = geometry.Rect;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;
const Context = widget.BuildContext;

/// A grid of equal cells, left to right and top to bottom, as many to a row as
/// keep them no wider than `cell.w` and as wide as share the grid's width,
/// that makes only the items in view when it is in a scroll view.
///
/// ![The Grid example](images/Grid.png)
///
/// (`box` stands for any widget: a labelled rounded rectangle.)
///
/// ```zig
/// return cx.make(kete.SizedBox{ .width = 260, .height = 140, .child = cx.make(kete.Grid.fixed(cx, &.{
///     box(cx, "1", 0, 0),
///     box(cx, "2", 0, 0),
///     box(cx, "3", 0, 0),
///     box(cx, "4", 0, 0),
///     box(cx, "5", 0, 0),
///     box(cx, "6", 0, 0),
/// }, .{ .w = 80, .h = 60 }, 8)) });
/// ```
pub const Grid = struct {
    /// How many items there are.
    count: usize,
    /// The size of every cell (and so every item): the widest it is (cells
    /// share the grid's width, as many to a row as keep them this wide or
    /// narrower), and how high. A width of `fill` makes a list: one
    /// column, its items as wide as the grid.
    cell: Size,
    /// Space between cells, across and down.
    spacing: f32 = 0,
    /// Makes the item at an index.
    item: ItemBuilder,
    /// Rows made beyond those in view, above and below, so a little
    /// scrolling needs nothing made.
    extra_rows: usize = 1,
    /// An item made even when it does not show: one a scroll view is to
    /// reveal (see `ScrollView.reveal`), which it can find only if it is
    /// made.
    keep: ?usize = null,

    /// A cell width that makes the grid a list (see `list`).
    pub const fill = std.math.inf(f32);

    /// A list of `count` items, each `row_height` high and as wide as the
    /// list, made by `item`: a grid with one column.
    pub fn list(count: usize, row_height: f32, item: ItemBuilder) Grid {
        return .{ .count = count, .cell = .{ .w = fill, .h = row_height }, .item = item };
    }

    /// A grid of `widgets` already made (they are copied into the frame's
    /// arena, as `cx.make` copies a `children` slice).
    pub fn fixed(cx: *Context, widgets: []const Widget, cell: Size, spacing: f32) Grid {
        const copy = cx.arena.dupe(Widget, widgets) catch &[_]Widget{};
        return .{ .count = copy.len, .cell = cell, .spacing = spacing, .item = .{ .ctx = @ptrCast(copy.ptr), .f = fixedItem } };
    }

    fn fixedItem(ctx: *const anyopaque, _: *Context, i: usize) Widget {
        const items: [*]const Widget = @ptrCast(@alignCast(ctx));
        return items[i];
    }

    /// Makes item `index` (in the frame's arena, with `cx.make`).
    pub const ItemBuilder = struct {
        ctx: *const anyopaque,
        f: *const fn (*const anyopaque, *Context, usize) Widget,

        pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), *Context, usize) Widget) ItemBuilder {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .f = struct {
                fn call(ctx: *const anyopaque, cx: *Context, i: usize) Widget {
                    return f(@as(P, @ptrCast(@alignCast(@constCast(ctx)))), cx, i);
                }
            }.call };
        }
    };

    pub const State = struct {
        /// The items made: from `first` up to `end`, and `kept` (made even
        /// though it does not show).
        first: usize = 0,
        end: usize = 0,
        kept: ?usize = null,
    };

    /// The items made with the rest of the tree: those of the last frame
    /// (and the item to keep).
    pub fn children(self: *const Grid, cx: *Context, n: *Node) []const Widget {
        const st = n.state(State);
        st.end = @min(st.end, self.count);
        st.first = @min(st.first, st.end);
        st.kept = self.extra(st.first, st.end);
        return self.make(cx, st.*);
    }

    /// The item to keep, if it is not among those from `first` to `end`.
    fn extra(self: *const Grid, first: usize, end: usize) ?usize {
        const k = self.keep orelse return null;
        return if (k < self.count and (k < first or k >= end)) k else null;
    }

    fn made(st: State) usize {
        return st.end - st.first + @intFromBool(st.kept != null);
    }

    /// The index of the `k`th item made: those in view, then the one kept.
    fn index(st: State, k: usize) usize {
        return if (k < st.end - st.first) st.first + k else st.kept.?;
    }

    fn make(self: *const Grid, cx: *Context, st: State) []const Widget {
        const out = cx.arena.alloc(Widget, made(st)) catch return &.{};
        for (out, 0..) |*w, k| {
            const i = index(st, k);
            const item = self.item.f(self.item.ctx, cx, i);
            w.* = if (item.key == null) item.withKey(i) else item;
        }
        return out;
    }

    fn gap(self: *const Grid) f32 {
        return if (std.math.isFinite(self.spacing)) @max(self.spacing, 0) else 0;
    }

    /// A list: one column, its items as wide as it.
    fn isList(self: *const Grid) bool {
        return !std.math.isFinite(self.cell.w);
    }

    /// How many to a row: as many as keep each no wider than `cell.w`
    /// (Flutter's `SliverGridDelegateWithMaxCrossAxisExtent`), or, without
    /// a width to share, all of them.
    fn columns(self: *const Grid, width: f32) usize {
        if (self.isList()) return 1;
        if (!std.math.isFinite(width)) return @max(self.count, 1);
        const pitch = @max(self.cell.w, 0) + self.gap();
        if (!(pitch > 0)) return @max(self.count, 1);
        return @max(1, @as(usize, @intFromFloat(@min(@ceil(@max(width, 0) / pitch), 1e9))));
    }

    /// How wide each cell is, `cols` sharing `width` (less the spacing
    /// between them).
    fn cellWidth(self: *const Grid, width: f32, cols: usize) f32 {
        if (!std.math.isFinite(width)) return if (self.isList()) 0 else @max(self.cell.w, 0);
        const n: f32 = @floatFromInt(cols);
        return @max((width - self.gap() * (n - 1)) / n, 0);
    }

    pub fn layout(self: *const Grid, n: *Node, c: Constraints) Size {
        const cols = self.columns(c.max_w);
        const rows = (self.count + cols - 1) / cols;
        const cw = if (self.isList()) 0 else @max(self.cell.w, 0);
        const ch = @max(self.cell.h, 0);
        const used: f32 = @floatFromInt(@min(cols, self.count));
        const r: f32 = @floatFromInt(rows);
        const content: Size = .{
            .w = if (c.boundedWidth()) c.max_w else used * (cw + self.gap()) - (if (self.count > 0) self.gap() else 0),
            .h = r * (ch + self.gap()) - (if (rows > 0) self.gap() else 0),
        };
        const size = c.constrain(content);
        n.size = size;
        self.place(n, cols);
        // In a scroll view, it says what shows once it is laid out (see
        // `realize`); otherwise all of it is made.
        if (n.ui.scrolling == 0) self.realize(n, .{ .x = 0, .y = 0, .w = content.w, .h = content.h });
        return size;
    }

    pub fn minSize(self: *const Grid, _: *Node, c: Constraints) Size {
        if (self.count == 0) return c.smallest();
        const cw = if (self.isList()) 0 else @max(self.cell.w, 0);
        const ch = @max(self.cell.h, 0);
        return c.constrain(.{ .w = cw, .h = ch });
    }

    /// Lays out the items made, each in its cell.
    fn place(self: *const Grid, n: *Node, cols: usize) void {
        const st = n.state(State);
        const cell: Size = .{ .w = self.cellWidth(n.size.w, cols), .h = @max(self.cell.h, 0) };
        for (n.children.items, 0..) |child, k| {
            const i = index(st.*, k);
            _ = child.layout(.tight(cell));
            const col: f32 = @floatFromInt(i % cols);
            const row: f32 = @floatFromInt(i / cols);
            child.place(col * (cell.w + self.gap()), row * (cell.h + self.gap()));
        }
    }

    /// `visible` (relative to the grid) is what shows: the items in the
    /// rows it covers are made, if they are not already, and laid out.
    pub fn realize(self: *const Grid, n: *Node, visible: Rect) void {
        const cols = self.columns(n.size.w);
        const pitch = @max(self.cell.h, 0) + self.gap();
        var want: State = .{};
        if (visible.h > 0 and visible.w > 0 and pitch > 0 and visible.y + visible.h > 0) {
            const top: usize = @intFromFloat(@max(@floor(visible.y / pitch), 0));
            const bottom: usize = @intFromFloat(@max(@ceil((visible.y + visible.h) / pitch), 0));
            want.first = @min((top -| self.extra_rows) * cols, self.count);
            want.end = @min((bottom + self.extra_rows) * cols, self.count);
        }
        want.kept = self.extra(want.first, want.end);
        const len = made(want);
        const st = n.state(State);
        if (std.meta.eql(st.*, want) and n.children.items.len == len) return;
        st.* = want;
        var cx: Context = .{ .ui = n.ui, .arena = n.ui.arena(), .node = n, .theme_ptr = n.theme_ptr };
        n.reconcile(self.make(&cx, want));
        if (n.children.items.len != len) {
            // Out of memory: none rather than the wrong ones.
            n.reconcile(&.{});
            st.* = .{};
        }
        self.place(n, cols);
    }
};
