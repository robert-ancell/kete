//! What changed on the screen between frames, so only that is redrawn.
//!
//! While painting, each node's own drawing is fingerprinted (the canvas
//! notes every shape, its position, colour and clip, and the node's place
//! in the painting order; see `gfx.Record`). A node whose fingerprint or
//! area differs from the last frame damages both its old and new areas, as
//! does a node that is no longer painted or is removed. GPU draws count as
//! changed every frame unless their widget gives a key.
//!
//! The damage is kept as a few rectangles. A window's buffers are reused
//! in turn, so a buffer last drawn `age` frames ago misses the damage of
//! the frames since: `repaint` gives that, from a short history, and
//! everything outside it still holds the right picture.

const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Rect = geometry.Rect;
const Node = widget.WidgetNode;

/// Rectangles in window pixels (whole pixels), overlapping ones merged:
/// no two overlap, so a renderer drawing each in turn draws every pixel
/// once (what is see-through is blended once).
pub const Region = struct {
    pub const max_rects = 4;

    rects: [max_rects]Rect = undefined,
    len: usize = 0,

    pub fn slice(r: *const Region) []const Rect {
        return r.rects[0..r.len];
    }

    pub fn isEmpty(r: *const Region) bool {
        return r.len == 0;
    }

    /// Adds `area` (made whole pixels): merged with the rectangles it
    /// touches, or, when there are already as many as can be kept, with the
    /// one that grows least.
    pub fn add(r: *Region, area: Rect) void {
        if (!(area.w > 0 and area.h > 0)) return;
        const x0 = @floor(area.x);
        const y0 = @floor(area.y);
        var a: Rect = .{ .x = x0, .y = y0, .w = @ceil(area.x + area.w) - x0, .h = @ceil(area.y + area.h) - y0 };
        var i: usize = 0;
        while (i < r.len) {
            if (touches(r.rects[i], a)) {
                a = r.rects[i].unite(a);
                r.rects[i] = r.rects[r.len - 1];
                r.len -= 1;
                i = 0;
            } else i += 1;
        }
        if (r.len < max_rects) {
            r.rects[r.len] = a;
            r.len += 1;
            return;
        }
        var best: usize = 0;
        var best_growth = std.math.inf(f32);
        for (r.rects[0..r.len], 0..) |q, j| {
            const growth = area_(q.unite(a)) - area_(q);
            if (growth < best_growth) {
                best = j;
                best_growth = growth;
            }
        }
        const merged = r.rects[best].unite(a);
        r.rects[best] = r.rects[r.len - 1];
        r.len -= 1;
        r.add(merged);
    }

    pub fn addRegion(r: *Region, other: *const Region) void {
        for (other.slice()) |q| r.add(q);
    }

    /// Within `bounds` (rectangles outside it go).
    pub fn clip(r: *Region, bounds: Rect) void {
        var out: Region = .{};
        for (r.slice()) |q| if (q.intersect(bounds)) |c| out.add(c);
        r.* = out;
    }

    fn touches(a: Rect, b: Rect) bool {
        return a.x <= b.x + b.w and b.x <= a.x + a.w and a.y <= b.y + b.h and b.y <= a.y + a.h;
    }

    fn area_(a: Rect) f32 {
        return a.w * a.h;
    }
};

pub const Tracker = struct {
    /// Frames of damage kept, for buffers this old.
    pub const history_len = 4;

    /// This frame's damage.
    frame: Region = .{},
    /// The damage of the frames before, most recent first.
    history: [history_len]Region = @splat(.{}),
    /// How many entries of `history` are known.
    known: usize = 0,
    size: [2]f32 = .{ 0, 0 },
    frame_no: u64 = 0,

    pub fn window(t: *const Tracker) Rect {
        return .{ .x = 0, .y = 0, .w = t.size[0], .h = t.size[1] };
    }

    /// Starts a frame of this size (a new size damages everything).
    ///
    /// Buffer ages count frames shown, and a frame that changed nothing is
    /// not shown, so only frames with damage are kept in the history: every
    /// frame that has damage must be shown.
    pub fn begin(t: *Tracker, frame_no: u64, width: u32, height: u32) void {
        if (t.frame_no != 0 and !t.frame.isEmpty()) {
            std.mem.copyBackwards(Region, t.history[1..], t.history[0 .. history_len - 1]);
            t.history[0] = t.frame;
            t.known = @min(t.known + 1, history_len);
        }
        t.frame = .{};
        t.frame_no = frame_no;
        t.resize(width, height);
    }

    /// Updates the current frame's window size (invalidating the frame if
    /// it changed).
    pub fn resize(t: *Tracker, width: u32, height: u32) void {
        const size = [2]f32{ @floatFromInt(width), @floatFromInt(height) };
        if (size[0] != t.size[0] or size[1] != t.size[1]) {
            t.size = size;
            t.invalidate();
        }
    }

    /// Marks the entire window as damaged and invalidates older buffers
    /// (e.g. when the window's size or surface clear colour changes).
    pub fn invalidate(t: *Tracker) void {
        t.frame.add(t.window());
        t.known = 0;
    }

    pub fn add(t: *Tracker, area: ?Rect) void {
        const a = area orelse return;
        if (a.intersect(t.window())) |c| t.frame.add(c);
    }

    /// A node has been painted, drawing what `rec` noted.
    pub fn painted(t: *Tracker, n: *Node, rec: *const gfx.Record) void {
        const hash = rec.final();
        const same = n.paint.valid and n.paint.hash == hash and std.meta.eql(n.paint.bounds, rec.bounds);
        if (!same) {
            if (n.paint.valid) t.add(n.paint.bounds);
            t.add(rec.bounds);
        }
        n.paint = .{ .valid = true, .hash = hash, .bounds = rec.bounds, .frame = t.frame_no };
    }

    /// Damages where nodes were painted last frame and not this one.
    pub fn sweep(t: *Tracker, n: *Node) void {
        if (n.paint.valid and n.paint.frame != t.frame_no) {
            t.add(n.paint.bounds);
            n.paint.valid = false;
        }
        for (n.children.items) |ch| t.sweep(ch);
    }

    /// A node is being freed: where it was painted is damaged.
    pub fn removed(t: *Tracker, n: *const Node) void {
        if (n.paint.valid) t.add(n.paint.bounds);
    }

    /// What must be drawn in a buffer last drawn `age` frames ago (1: the
    /// frame before this; 0: never, or its contents are unknown) for it to
    /// show this frame.
    pub fn repaint(t: *const Tracker, age: u32) Region {
        var r = t.frame;
        if (age == 0 or age - 1 > t.known) {
            r = .{};
            r.add(t.window());
            return r;
        }
        for (t.history[0 .. age - 1]) |*h| r.addRegion(h);
        return r;
    }
};

/// What a node drew last time it was painted.
pub const Painted = struct {
    valid: bool = false,
    hash: u64 = 0,
    bounds: ?Rect = null,
    frame: u64 = 0,
};

const testing = std.testing;

test "regions merge what touches, and keep at most a few rectangles" {
    var r: Region = .{};
    r.add(.{ .x = 0.5, .y = 0, .w = 10, .h = 10 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 11, .h = 10 }, r.slice()[0]);
    r.add(.{ .x = 5, .y = 5, .w = 10, .h = 10 });
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 15, .h = 15 }, r.slice()[0]);
    for (0..6) |i| r.add(.{ .x = 100 * @as(f32, @floatFromInt(i + 1)), .y = 0, .w = 10, .h = 10 });
    try testing.expectEqual(@as(usize, Region.max_rects), r.len);
    // Everything added is still covered.
    for (0..7) |i| {
        const x = if (i == 0) 0 else 100 * @as(f32, @floatFromInt(i));
        const covered = for (r.slice()) |q| {
            if (q.x <= x and q.x + q.w >= x + 10) break true;
        } else false;
        try testing.expect(covered);
    }
}

test "no two rectangles of a region overlap" {
    var prng: std.Random.DefaultPrng = .init(7);
    const rand = prng.random();
    for (0..200) |_| {
        var r: Region = .{};
        for (0..12) |_| {
            r.add(.{ .x = rand.float(f32) * 300, .y = rand.float(f32) * 200, .w = 1 + rand.float(f32) * 60, .h = 1 + rand.float(f32) * 40 });
            for (r.slice(), 0..) |a, i| for (r.slice()[i + 1 ..]) |b| {
                try testing.expect(!(a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h));
            };
        }
    }
}

test "buffers get the damage of the frames they missed" {
    var t: Tracker = .{};
    t.begin(1, 100, 100);
    // A new size: everything.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, t.frame.slice()[0]);
    t.begin(2, 100, 100);
    t.add(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    t.begin(3, 100, 100);
    t.add(.{ .x = 50, .y = 50, .w = 10, .h = 10 });
    // The buffer from the frame before needs this frame's damage; the one
    // from two frames ago, frame 2's as well.
    try testing.expectEqual(@as(usize, 1), t.repaint(1).len);
    try testing.expectEqual(@as(usize, 2), t.repaint(2).len);
    // Older than what is known, or unknown: everything.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, t.repaint(9).slice()[0]);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, t.repaint(0).slice()[0]);
    // Nothing changed: nothing to draw in last frame's buffer.
    t.begin(4, 100, 100);
    try testing.expect(t.repaint(1).isEmpty());
    // Frames without changes are not shown, and do not count: the next
    // change's buffer from two shown frames ago still gets frame 3's.
    t.begin(5, 100, 100);
    t.add(.{ .x = 90, .y = 0, .w = 10, .h = 10 });
    try testing.expectEqual(@as(usize, 2), t.repaint(2).len);
}
