//! MapView: a slippy map. The world, from a `MapSource`'s tiles (pictures,
//! or shapes drawn in a `MapStyle`), dragged about and zoomed with the
//! wheel (or a double click); flung, it carries on a little. Zoomed out,
//! it is a globe (unless `show_globe` is off), turned by dragging, that
//! becomes the flat map as it is zoomed in.
//!
//! Where it looks is a `MapPosition`, which the app keeps: it is given the
//! position to show, and told the position it is moved to (`on_move`).
//!
//!     cx.make(ui.MapView{
//!         .source = .of(&state.tiles, .{ .max_level = 14, .attribution = "© Someone" }),
//!         .style = &my_style,
//!         .position = state.position,
//!         .on_move = .of(state, State.setPosition),
//!     })
//!
//! Tiles that are not there yet are drawn from the nearest level out
//! that is (bigger, and blurrier); picture tiles load in the background,
//! as an `Image`'s do. Vector tiles are drawn once into pictures of their
//! own (see `map/pictures.zig`), which later frames draw, with the labels
//! drawn over them.

const focus = @import("focus.zig");
const a11y = @import("accessibility.zig");
const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const projection = @import("map/projection.zig");
const tiles = @import("map/tiles.zig");
const style_mod = @import("map/style.zig");
const tile_painter = @import("map/tile_painter.zig");
const pictures_mod = @import("map/pictures.zig");

const Size = geometry.Size;
const Point = geometry.Point;
const Constraints = geometry.Constraints;
const Node = widget.WidgetNode;
const Event = widget.Event;
const PointerCursor = widget.PointerCursor;
const ValueCallback = widget.ValueCallback;
const Painter = painter_mod.Painter;
const Color = gfx.Color;

pub const MapPosition = projection.MapPosition;
pub const MapCoordinate = projection.MapCoordinate;
pub const MapProjection = projection.MapProjection;
pub const View = projection.View;
pub const MapTileId = tiles.MapTileId;
pub const MapTile = tiles.MapTile;
pub const MapSource = tiles.MapSource;
pub const MapVectorTile = tiles.MapVectorTile;
pub const MapStyle = style_mod.MapStyle;
pub const MapTilePainter = tile_painter.MapTilePainter;
pub const MapLabelStyle = tile_painter.MapLabelStyle;

/// How night is shaded on a map.
pub const MapNight = struct {
    /// Where the sun is overhead.
    sun: MapCoordinate,
    /// The colour of the shade.
    color: Color = .rgb(0x000814),
    /// How dark it is where the sun is well below the horizon (and less
    /// in twilight, as it sets).
    opacity: f32 = 0.55,

    /// Night with the sun where it is overhead at `unix_seconds` (seconds
    /// since 1970 UTC), the rest of it at its defaults.
    pub fn at(unix_seconds: f64) MapNight {
        return .{ .sun = projection.subsolarPoint(unix_seconds) };
    }
};

/// The most tiles drawn at once.
const max_tiles = 512;
/// How far out a tile that is not there is drawn from instead.
const max_fallback = 6;

/// A map of the world made of tiles (vectors drawn by a style, or images), that
/// can be dragged, zoomed and flung, and is a globe when zoomed far out.
pub const MapView = struct {
    /// North is up, and east to the right, whichever way the interface
    /// runs.
    pub const left_to_right = true;

    /// Where the tiles come from.
    source: MapSource,
    /// How vector tiles are drawn: a plain style in the theme's colours if
    /// null.
    style: ?*const MapStyle = null,
    /// The place at its centre, and how close.
    position: MapPosition = .{},
    /// Whether the world is a globe when zoomed far out (it becomes the flat
    /// map as it is zoomed in), or the flat map at every zoom.
    show_globe: bool = true,
    /// The furthest out it can be zoomed.
    min_zoom: f64 = 0,
    /// The furthest in it can be zoomed.
    max_zoom: f64 = 20,
    /// Called with the position it is moved or zoomed to (by dragging, the
    /// wheel, the keys, or a fling carrying on); without it the map cannot
    /// be moved.
    on_move: ?ValueCallback(MapPosition) = null,
    /// Around the globe: the theme's surface if null.
    space: ?Color = null,
    /// Where there are no tiles (and on the globe, its poles, which the
    /// flat map does not reach): the style's background, or the theme's
    /// surface container, if null.
    background: ?Color = null,
    /// Whether the globe has a glow around it (its atmosphere).
    atmosphere: bool = true,
    /// The colour of that glow: the theme's primary, faint, if null.
    atmosphere_color: ?Color = null,
    /// Night where the sun has set, shaded on the globe (fading as the globe
    /// becomes the flat map): the time to show it for, in seconds since
    /// 1970 UTC; none if null.
    night: ?f64 = null,
    /// The colour of that shade: a dark blue if null.
    night_color: ?Color = null,
    /// Its width, in pixels, if it is not told how big to be.
    width: f32 = 480,
    /// Its height, in pixels, if it is not told how big to be.
    height: f32 = 320,

    pub const State = struct {
        /// The position it was last moved to, and the frame it was in: what it
        /// is at until the next frame is made with the app's.
        pending: ?MapPosition = null,
        pending_frame: u64 = 0,
        /// The place grabbed, while dragging.
        grab: ?MapCoordinate = null,
        /// The pointer's last moves (where, and when): how fast it was
        /// going when let go.
        trail: [4]struct { pos: [2]f64, ns: u64 } = undefined,
        trail_len: usize = 0,
        /// A fling's speed, in pixels a second.
        velocity: [2]f64 = .{ 0, 0 },
        last_ns: u64 = 0,
        /// The vector tiles' pictures (made when first wanted).
        pictures: ?*pictures_mod.Pictures = null,

        pub fn deinit(st: *State) void {
            const p = st.pictures orelse return;
            const gpa = p.gpa;
            p.deinit();
            gpa.destroy(p);
        }

        fn picturesOf(st: *State, gpa: std.mem.Allocator) ?*pictures_mod.Pictures {
            if (st.pictures == null) {
                const p = gpa.create(pictures_mod.Pictures) catch return null;
                p.* = .init(gpa);
                st.pictures = p;
            }
            return st.pictures;
        }
    };

    fn projectionOf(self: *const MapView) MapProjection {
        return if (self.show_globe) .globe else .flat;
    }

    /// The position it shows: the one it was just moved to, or the app's
    /// (kept in bounds).
    fn positionOf(self: *const MapView, n: *Node) MapPosition {
        const st = n.state(State);
        if (st.pending) |pos| if (st.pending_frame == n.ui.frame_no) return pos;
        return self.bounded(self.position);
    }

    /// `pos`, with its latitude, longitude and zoom in bounds.
    fn bounded(self: *const MapView, pos: MapPosition) MapPosition {
        return .{
            .center = .{ .lat = std.math.clamp(pos.center.lat, -projection.max_lat, projection.max_lat), .lon = projection.wrapLon(pos.center.lon) },
            .zoom = std.math.clamp(pos.zoom, self.min_zoom, self.max_zoom),
        };
    }

    fn size(n: *const Node) [2]f64 {
        return .{ n.size.w, n.size.h };
    }

    /// Says it was moved to `pos` (kept in bounds), and shows it so until the
    /// app gives the next frame its own.
    fn moveTo(self: *const MapView, n: *Node, pos: MapPosition) void {
        const f = self.on_move orelse return;
        const st = n.state(State);
        st.pending = self.bounded(pos);
        st.pending_frame = n.ui.frame_no;
        n.ui.needs_frame = true;
        f.call(st.pending.?);
    }

    pub fn focusable(self: *const MapView, _: *Node) bool {
        return self.on_move != null;
    }

    /// The keys: arrows move it, plus and minus zoom.
    fn key(self: *const MapView, n: *Node, k: Event.Key) bool {
        const cam = self.positionOf(n);
        const c: [2]f64 = .{ n.size.w / 2, n.size.h / 2 };
        const step = 80;
        const delta: ?[2]f64 = switch (k.key) {
            .left => .{ -step, 0 },
            .right => .{ step, 0 },
            .up => .{ 0, -step },
            .down => .{ 0, step },
            else => null,
        };
        if (delta) |d| {
            if (!k.pressed) return true;
            const place = View.init(cam, size(n), self.projectionOf()).unproject(c) orelse return true;
            // What is that way comes to the middle.
            self.moveTo(n, projection.moveTo(cam, size(n), self.projectionOf(), place, .{ c[0] - d[0], c[1] - d[1] }));
            return true;
        }
        const by: f64 = switch (k.key) {
            .equal, .keypad_plus => 1,
            .minus, .keypad_minus => -1,
            else => return false,
        };
        if (k.pressed) self.moveTo(n, projection.zoomAbout(cam, size(n), self.projectionOf(), c, by, self.min_zoom, self.max_zoom));
        return true;
    }

    pub fn accessible(self: *const MapView, n: *Node) ?a11y.Info {
        // An interactive widget of its own kind (its keys move it): an
        // application, called a map.
        const c = self.positionOf(n);
        const where = std.fmt.allocPrint(n.ui.arena(), "{d:.4}, {d:.4}, zoom {d:.1}", .{ c.center.lat, c.center.lon, c.zoom }) catch "";
        return .{ .role = .application, .roledescription = "map", .label = "Map", .description = where };
    }

    pub fn layout(self: *const MapView, _: *Node, c: Constraints) Size {
        return c.constrain(.{
            .w = if (c.boundedWidth()) c.max_w else self.width,
            .h = if (c.boundedHeight()) c.max_h else self.height,
        });
    }

    pub fn minSize(_: *const MapView, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = 120, .h = 90 });
    }

    pub fn cursor(self: *const MapView, n: *Node, _: Point) ?PointerCursor {
        if (self.on_move == null) return null;
        return if (n.state(State).grab != null) .grabbing else .grab;
    }

    pub fn event(self: *const MapView, n: *Node, e: Event) bool {
        if (self.on_move == null) return false;
        const st = n.state(State);
        const cam = self.positionOf(n);
        switch (e) {
            .press => |pr| {
                if (pr.button != .left) return false;
                const at: [2]f64 = .{ pr.pos[0], pr.pos[1] };
                st.velocity = .{ 0, 0 };
                if (pr.clicks == 2) {
                    self.moveTo(n, projection.zoomAbout(cam, size(n), self.projectionOf(), at, 1, self.min_zoom, self.max_zoom));
                    return true;
                }
                st.grab = View.init(cam, size(n), self.projectionOf()).unproject(at);
                st.trail[0] = .{ .pos = at, .ns = n.ui.clockNs() };
                st.trail_len = 1;
                n.ui.needs_frame = true;
                return true;
            },
            .motion => |pos| {
                const place = st.grab orelse return false;
                const at: [2]f64 = .{ pos[0], pos[1] };
                self.moveTo(n, projection.moveTo(cam, size(n), self.projectionOf(), place, at));
                if (st.trail_len == st.trail.len) {
                    std.mem.copyForwards(@TypeOf(st.trail[0]), st.trail[0 .. st.trail.len - 1], st.trail[1..]);
                    st.trail_len -= 1;
                }
                st.trail[st.trail_len] = .{ .pos = at, .ns = n.ui.clockNs() };
                st.trail_len += 1;
                return true;
            },
            .release => {
                if (st.grab == null) return false;
                st.grab = null;
                st.velocity = flingSpeed(st, n.ui.clockNs());
                st.last_ns = n.ui.now_ns;
                n.ui.needs_frame = true;
                return true;
            },
            .key => |k| return self.key(n, k),
            .scroll => |sc| {
                st.velocity = .{ 0, 0 };
                if (sc.touch) {
                    // A finger: the map follows it.
                    const c: [2]f64 = .{ n.size.w / 2, n.size.h / 2 };
                    const place = View.init(cam, size(n), self.projectionOf()).unproject(c) orelse return true;
                    self.moveTo(n, projection.moveTo(cam, size(n), self.projectionOf(), place, .{ c[0] - sc.dx, c[1] - sc.dy }));
                } else {
                    self.moveTo(n, projection.zoomAbout(cam, size(n), self.projectionOf(), .{ sc.pos[0], sc.pos[1] }, -sc.dy / 30, self.min_zoom, self.max_zoom));
                }
                return true;
            },
            else => {},
        }
        return false;
    }

    /// How fast the pointer was going when let go, in pixels a second:
    /// over its last moves, if it was still moving (none if it stopped, or
    /// moved too quickly to tell).
    fn flingSpeed(st: *const State, now: u64) [2]f64 {
        if (st.trail_len < 2) return .{ 0, 0 };
        const last = st.trail[st.trail_len - 1];
        const first = st.trail[0];
        if (now -| last.ns > 80 * std.time.ns_per_ms) return .{ 0, 0 };
        const dt = @as(f64, @floatFromInt(last.ns -| first.ns)) / std.time.ns_per_s;
        if (dt < 0.008) return .{ 0, 0 };
        var v: [2]f64 = .{ (last.pos[0] - first.pos[0]) / dt, (last.pos[1] - first.pos[1]) / dt };
        const speed = @sqrt(v[0] * v[0] + v[1] * v[1]);
        if (speed < 60) return .{ 0, 0 };
        if (speed > 5000) v = .{ v[0] * 5000 / speed, v[1] * 5000 / speed };
        return v;
    }

    /// A fling carrying on: the map moves on, slowing.
    fn fling(self: *const MapView, n: *Node) void {
        const st = n.state(State);
        const now = n.ui.now_ns;
        defer st.last_ns = now;
        if (st.velocity[0] == 0 and st.velocity[1] == 0) return;
        n.ui.needs_frame = true;
        const dt = std.math.clamp(@as(f64, @floatFromInt(now -| st.last_ns)) / std.time.ns_per_s, 0, 0.05);
        if (dt <= 0) return;
        const cam = self.positionOf(n);
        const c: [2]f64 = .{ n.size.w / 2, n.size.h / 2 };
        if (View.init(cam, size(n), self.projectionOf()).unproject(c)) |place| {
            self.moveTo(n, projection.moveTo(cam, size(n), self.projectionOf(), place, .{ c[0] + st.velocity[0] * dt, c[1] + st.velocity[1] * dt }));
        }
        const k = @exp(-dt * 4);
        st.velocity = .{ st.velocity[0] * k, st.velocity[1] * k };
        if (@abs(st.velocity[0]) + @abs(st.velocity[1]) < 20) st.velocity = .{ 0, 0 };
    }

    /// A tile that shows, and which copy of the world it is in (how far
    /// east of the world's tiles, in worlds).
    const Shown = struct { id: MapTileId, copy: f64 };

    /// What is drawn for a tile that shows: a tile at its level or
    /// further out (`from`).
    const Drawn = struct {
        shown: Shown,
        from: MapTileId,
        what: union(enum) { image: *const gfx.Image, vector: *const MapVectorTile },
    };

    /// The tiles' level at a zoom: the same wherever it is centred, so
    /// the tiles stay the same size as the globe turns.
    fn level(self: *const MapView, zoom: f64) u8 {
        const z = zoom - std.math.log2(@as(f64, @max(self.source.tile_size, 1)) / 256);
        const l: u8 = @intFromFloat(std.math.clamp(@round(z), 0, 30));
        return std.math.clamp(l, self.source.min_level, self.source.max_level);
    }

    /// The tiles of `lvl` that show.
    fn shownTiles(v: *const View, lvl: u8, out: *std.ArrayList(Shown), arena: std.mem.Allocator) void {
        const n: f64 = @floatFromInt(@as(u32, 1) << @intCast(lvl));
        if (v.flat >= 1) {
            // On the flat map: those in the view's rectangle (in as many
            // copies of the world as it reaches across).
            const x0 = v.center[0] - v.size[0] / 2 / v.world;
            const x1 = v.center[0] + v.size[0] / 2 / v.world;
            const y0 = @max(0, v.center[1] - v.size[1] / 2 / v.world);
            const y1 = @min(1, v.center[1] + v.size[1] / 2 / v.world);
            if (y1 <= y0) return;
            var ty = @floor(y0 * n);
            while (ty < @min(n, @ceil(y1 * n))) : (ty += 1) {
                var tx = @floor(x0 * n);
                while (tx < @ceil(x1 * n)) : (tx += 1) {
                    if (out.items.len == max_tiles) return;
                    const copy = @floor(tx / n);
                    out.append(arena, .{ .id = .{ .z = lvl, .x = @intFromFloat(tx - copy * n), .y = @intFromFloat(ty) }, .copy = copy }) catch return;
                }
            }
            return;
        }
        visit(v, .{ .z = 0, .x = 0, .y = 0 }, lvl, out, arena);
    }

    /// Those of `id`'s tiles at `lvl` that show on the globe (or between it
    /// and the flat map).
    fn visit(v: *const View, id: MapTileId, lvl: u8, out: *std.ArrayList(Shown), arena: std.mem.Allocator) void {
        if (out.items.len == max_tiles) return;
        const n: f64 = @floatFromInt(id.count());
        const copy = @round(v.center[0] - (@as(f64, @floatFromInt(id.x)) + 0.5) / n);
        if (id.z >= 2 and !shows(v, id, copy)) return;
        if (id.z == lvl) {
            out.append(arena, .{ .id = id, .copy = copy }) catch {};
            return;
        }
        for (0..4) |i| visit(v, .{ .z = id.z + 1, .x = id.x * 2 + @as(u32, @intCast(i % 2)), .y = id.y * 2 + @as(u32, @intCast(i / 2)) }, lvl, out, arena);
    }

    /// Whether some of a tile shows, as far as points across it tell.
    fn shows(v: *const View, id: MapTileId, copy: f64) bool {
        const n: f64 = @floatFromInt(id.count());
        const x0 = @as(f64, @floatFromInt(id.x)) / n + copy;
        const y0 = @as(f64, @floatFromInt(id.y)) / n;
        // The centre is in it.
        if (v.center[0] >= x0 and v.center[0] <= x0 + 1 / n and v.center[1] >= y0 and v.center[1] <= y0 + 1 / n) return true;
        const k = 6;
        var lo: [2]f64 = .{ std.math.inf(f64), std.math.inf(f64) };
        var hi: [2]f64 = .{ -std.math.inf(f64), -std.math.inf(f64) };
        var any = false;
        for (0..k + 1) |j| for (0..k + 1) |i| {
            const p = v.project(.{ x0 + @as(f64, @floatFromInt(i)) / k / n, y0 + @as(f64, @floatFromInt(j)) / k / n });
            if (!p.visible) continue;
            any = true;
            lo = .{ @min(lo[0], p.pos[0]), @min(lo[1], p.pos[1]) };
            hi = .{ @max(hi[0], p.pos[0]), @max(hi[1], p.pos[1]) };
        };
        if (!any) return false;
        // Between the points, a little further.
        const m = @max(hi[0] - lo[0], hi[1] - lo[1]) / k;
        return hi[0] + m >= 0 and hi[1] + m >= 0 and lo[0] - m <= v.size[0] and lo[1] - m <= v.size[1];
    }

    /// What there is to draw for a tile: it, or the nearest tile further
    /// out that is ready.
    fn resolve(self: *const MapView, n: *Node, shown: Shown) ?Drawn {
        var id = shown.id;
        for (0..max_fallback + 1) |_| {
            switch (self.source.tile(.{ .id = id, .waker = n.ui.waker() })) {
                .none => return null,
                .vector => |vt| return .{ .shown = shown, .from = id, .what = .{ .vector = vt } },
                .image => |src| switch (n.ui.images.get(src, n.ui.now_ns)) {
                    .ready => |img| return .{ .shown = shown, .from = id, .what = .{ .image = img } },
                    .loading, .failed => {},
                },
                .pending => {},
            }
            if (id.z <= self.source.min_level) return null;
            id = id.parent() orelse return null;
        }
        return null;
    }

    pub fn paint(self: *const MapView, n: *Node, p: *Painter) void {
        self.fling(n);
        const cam = self.positionOf(n);
        const t = n.theme();
        const v = View.init(cam, size(n), self.projectionOf());
        const arena = n.ui.arena();
        const background = self.background orelse if (self.style) |s| s.background else t.surface_container;
        const old_clip = p.clipTo(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h });
        defer p.restoreClip(old_clip);
        const c = p.canvas();
        const whole: gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };

        if (v.flat < 1) {
            // Space, the globe's glow, and the globe (growing to fill the
            // view as it becomes the flat map).
            c.fillRect(whole, self.space orelse t.surface);
            const centre: gfx.Point = .{ n.size.w / 2, n.size.h / 2 };
            const r: f32 = @floatCast(@min(v.discRadius() / @max(1 - v.flat, 0.01) / @max(1 - v.flat, 0.01), 1e6));
            if (self.atmosphere) {
                const glow = self.atmosphere_color orelse t.primary.withAlpha(0.35);
                for (0..6) |i| {
                    const k: f32 = @floatFromInt(i);
                    c.strokeCircle(centre, r + 1 + k * 2.5, 2.5, glow.withAlpha(glow.a * (1 - k / 6) * (1 - k / 6)));
                }
            }
            c.fillCircle(centre, r, background);
        } else c.fillRect(whole, background);

        var shown: std.ArrayList(Shown) = .empty;
        shownTiles(&v, self.level(cam.zoom), &shown, arena);
        var drawn: std.ArrayList(Drawn) = .empty;
        for (shown.items) |s| if (self.resolve(n, s)) |d| drawn.append(arena, d) catch break;

        // Pictures first, then shapes (each tile once, though it may be
        // drawn for several further in).
        for (drawn.items) |d| if (d.what == .image) drawImageTile(c, &v, d, arena);
        var labels: tile_painter.Labels = .{ .arena = arena, .area = whole, .font = n.ui.font, .atlas = n.ui.atlas };
        const plain = MapStyle.plainLayers(t);
        const layers = if (self.style) |s| s.layers else &plain;
        // Vector tiles' pictures, where they will do (or there is time to
        // draw them): their shapes are not drawn, only their labels.
        const pictures = n.state(State).picturesOf(n.ui.gpa);
        if (pictures) |pics| pics.beginFrame(n.ui.frame_no, pictures_mod.styleHash(background, layers));
        const Near = struct {
            view: *const MapView,
            node: *Node,
            fn get(ctx: *anyopaque, other: MapTileId) ?*const MapVectorTile {
                const near: *@This() = @ptrCast(@alignCast(ctx));
                return switch (near.view.source.tile(.{ .id = other, .waker = near.node.ui.waker() })) {
                    .vector => |vt| vt,
                    else => null,
                };
            }
        };
        var near: Near = .{ .view = self, .node = n };
        const Shapes = struct { tp: MapTilePainter, tile: *const MapVectorTile, pictured: bool };
        var shapes: std.ArrayList(Shapes) = .empty;
        for (drawn.items, 0..) |d, i| {
            const vt = switch (d.what) {
                .vector => |vt| vt,
                .image => continue,
            };
            const pictured = if (pictures) |pics| blk: {
                const shown_size = @round(256 * std.math.exp2(cam.zoom - @as(f64, @floatFromInt(d.from.z))));
                if (!(shown_size < 1e5)) break :blk false;
                const got = pics.get(.{
                    .id = d.from,
                    .tile = vt,
                    .size = @intFromFloat(shown_size),
                    .scale = @max(n.ui.scale, 1),
                    .zoom = cam.zoom,
                    .background = background,
                    .layers = layers,
                    .nearby = .{ .ctx = &near, .get = Near.get },
                    .atlas = n.ui.atlas,
                    .io = n.ui.io,
                });
                if (got.more) n.ui.needs_frame = true;
                const img = got.image orelse break :blk false;
                drawImageTile(c, &v, .{ .shown = d.shown, .from = d.from, .what = .{ .image = img } }, arena);
                break :blk true;
            } else false;
            const dup = for (drawn.items[0..i]) |e| {
                if (std.meta.eql(e.from, d.from) and e.shown.copy == d.shown.copy and e.what == .vector) break true;
            } else false;
            if (dup) continue;
            const span = 1 / @as(f64, @floatFromInt(d.from.count()));
            shapes.append(arena, .{ .tile = vt, .pictured = pictured, .tp = .{
                .canvas = c,
                .arena = arena,
                .view = &v,
                .id = d.from,
                .corner = .{ @as(f64, @floatFromInt(d.from.x)) * span + d.shown.copy, @as(f64, @floatFromInt(d.from.y)) * span },
                .span = span,
                .extent = vt.extent,
                .zoom = cam.zoom,
                .labels = &labels,
            } }) catch break;
        }
        // Each layer of the style across all the tiles not in pictures
        // before the next (so a tile's fills do not cover the lines of
        // those before it), then night over them, and labels last, over
        // everything.
        for ([_]bool{ false, true }) |label_pass| {
            if (label_pass) if (self.night) |when| {
                var night = MapNight.at(when);
                if (self.night_color) |color| night.color = color;
                drawNight(c, &v, night, arena);
            };
            for (layers) |*l| {
                if ((l.draw == .label) != label_pass) continue;
                for (shapes.items) |*sh| if (label_pass or !sh.pictured) MapStyle.drawLayer(l, &sh.tp, sh.tile);
            }
        }

        focus.ring(n, p, 0, true);
        if (self.source.attribution.len > 0) if (n.ui.font) |f| {
            const size_px = 11;
            const w = n.ui.atlas.runs.measure(.{ .font = f, .size = size_px }, self.source.attribution);
            const box: gfx.Rect = .{ .x = n.size.w - w - 12, .y = n.size.h - 20, .w = w + 12, .h = 20 };
            c.fillRoundedRect(box, .{ .tl = 6 }, t.surface.withAlpha(0.8));
            _ = c.drawText(n.ui.atlas, .{ .font = f, .size = size_px }, box.x + 6, box.y + 14, self.source.attribution, t.on_surface_variant);
        };
    }

    /// Shades night on the side of the globe that shows: a mesh over it,
    /// each corner as dark as the sun is below the horizon there (none
    /// while it is up, darkening through twilight, and as dark as it gets
    /// 12° below). It fades as the globe becomes the flat map.
    fn drawNight(c: *gfx.Canvas, v: *const View, night: MapNight, arena: std.mem.Allocator) void {
        const fade: f32 = @floatCast(1 - v.flat);
        if (fade <= 0 or night.opacity <= 0) return;
        const rings = 24;
        const sectors = 72;
        const sun = projection.direction(night.sun);
        // Rings round the camera's axis, out to just short of the edge.
        const edge = v.horizonAngle() * 0.999;
        var verts: [rings + 1][sectors][3]f32 = undefined;
        for (0..rings + 1) |i| for (0..sectors) |j| {
            const rho = edge * @as(f64, @floatFromInt(i)) / rings;
            const az = std.math.tau * @as(f64, @floatFromInt(j)) / sectors;
            const place = v.placeAt(.{ @sin(rho) * @cos(az), @sin(rho) * @sin(az), @cos(rho) });
            const p = v.projectCoordinate(place).pos;
            const dir = projection.direction(place);
            const height = std.math.asin(std.math.clamp(dir[0] * sun[0] + dir[1] * sun[1] + dir[2] * sun[2], -1, 1)) * 180 / std.math.pi;
            const t: f32 = @floatCast(std.math.clamp((1 - height) / 13, 0, 1));
            verts[i][j] = .{ @floatCast(p[0]), @floatCast(p[1]), t * t * (3 - 2 * t) * night.opacity * fade };
        };
        var tris: std.ArrayList([3]f32) = .empty;
        tris.ensureTotalCapacity(arena, rings * sectors * 6) catch return;
        for (0..rings) |i| for (0..sectors) |j| {
            const k = (j + 1) % sectors;
            const a = verts[i][j];
            const b = verts[i][k];
            const cc = verts[i + 1][k];
            const d = verts[i + 1][j];
            // The first ring is the one point in the middle.
            if (i > 0) tris.appendSliceAssumeCapacity(&.{ a, b, cc });
            tris.appendSliceAssumeCapacity(&.{ a, cc, d });
        };
        c.fillShaded(tris.items, night.color);
    }

    /// Draws a picture tile (or the part of one further out that is where
    /// it shows): on the flat map, as it is; bent, as a mesh.
    fn drawImageTile(c: *gfx.Canvas, v: *const View, d: Drawn, arena: std.mem.Allocator) void {
        const img = d.what.image;
        const id = d.shown.id;
        // The part of the picture: all of it, or of one further out, the
        // part that is this tile.
        const sub: f32 = @floatFromInt(@as(u32, 1) << @intCast(id.z - d.from.z));
        const s0 = @as(f32, @floatFromInt(id.x - d.from.x * @as(u32, @intFromFloat(sub)))) / sub;
        const t0 = @as(f32, @floatFromInt(id.y - d.from.y * @as(u32, @intFromFloat(sub)))) / sub;
        const uv = 1 / sub;
        const span = 1 / @as(f64, @floatFromInt(id.count()));
        const x0 = @as(f64, @floatFromInt(id.x)) * span + d.shown.copy;
        const y0 = @as(f64, @floatFromInt(id.y)) * span;
        if (v.flat >= 1) {
            // Whole pixels, so that tiles at their size are sharp.
            const a = v.project(.{ x0, y0 }).pos;
            const b = v.project(.{ x0 + span, y0 + span }).pos;
            const l: f32 = @floatCast(@round(a[0]));
            const tp: f32 = @floatCast(@round(a[1]));
            const r: f32 = @floatCast(@round(b[0]));
            const bt: f32 = @floatCast(@round(b[1]));
            c.drawImageTriangles(img, &.{
                .{ l, tp, s0, t0 }, .{ r, tp, s0 + uv, t0 },      .{ r, bt, s0 + uv, t0 + uv },
                .{ l, tp, s0, t0 }, .{ r, bt, s0 + uv, t0 + uv }, .{ l, bt, s0, t0 + uv },
            }, 1);
            return;
        }
        const segs: usize = std.math.clamp(@as(usize, 128) >> @intCast(@min(id.z, 7)), 2, 16);
        const grid = arena.alloc(View.Projected, (segs + 1) * (segs + 1)) catch return;
        for (0..segs + 1) |j| for (0..segs + 1) |i| {
            grid[j * (segs + 1) + i] = v.project(.{ x0 + span * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segs)), y0 + span * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(segs)) });
        };
        var corners: std.ArrayList([4]f32) = .empty;
        corners.ensureTotalCapacity(arena, segs * segs * 6) catch return;
        const step = uv / @as(f32, @floatFromInt(segs));
        for (0..segs) |j| for (0..segs) |i| {
            const k = [4]usize{ j * (segs + 1) + i, j * (segs + 1) + i + 1, (j + 1) * (segs + 1) + i + 1, (j + 1) * (segs + 1) + i };
            const uvs = [4][2]f32{
                .{ s0 + step * @as(f32, @floatFromInt(i)), t0 + step * @as(f32, @floatFromInt(j)) },
                .{ s0 + step * @as(f32, @floatFromInt(i + 1)), t0 + step * @as(f32, @floatFromInt(j)) },
                .{ s0 + step * @as(f32, @floatFromInt(i + 1)), t0 + step * @as(f32, @floatFromInt(j + 1)) },
                .{ s0 + step * @as(f32, @floatFromInt(i)), t0 + step * @as(f32, @floatFromInt(j + 1)) },
            };
            for ([2][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 3 } }) |tri| {
                // On the globe, triangles with a corner on the side that
                // shows (any on the far side brought to the globe's edge);
                // part way to the flat map, only those all on it.
                const shown = @as(u8, @intFromBool(grid[k[tri[0]]].visible)) + @intFromBool(grid[k[tri[1]]].visible) + @intFromBool(grid[k[tri[2]]].visible);
                if (shown == 0 or (v.flat > 0 and shown < 3)) continue;
                for (tri) |q| {
                    const pos = grid[k[q]].pos;
                    corners.appendAssumeCapacity(.{ @floatCast(pos[0]), @floatCast(pos[1]), uvs[q][0], uvs[q][1] });
                }
            }
        };
        c.drawImageTriangles(img, corners.items, 1);
    }
};
