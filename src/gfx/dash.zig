//! Dashed lines: how a line is broken into dashes (`Dash`), and finding the
//! dashes of a polyline that can be seen (`walk`), so that drawing one
//! costs as much as the dashes in view, however long the line is (a line
//! across a map zoomed far in is millions of dashes long, nearly all of
//! them out of sight). Each dash is a piece of the line, given as a
//! polyline of its own, so that a dash turns a corner as the line does.

const std = @import("std");
const geometry = @import("geometry.zig");

const Point = geometry.Point;

/// How a line is broken into dashes: lengths along it, drawn and then
/// gaps in turn (as SVG's `stroke-dasharray`; an odd number of them is
/// repeated, so that each is a dash once and a gap once), repeating.
///
///     .{ .pattern = &.{ 6, 4 } } // dashes 6 long, 4 apart
///     .{ .pattern = &.{ 0, 6 }, .cap = .round } // dots, 6 apart
///     .{ .pattern = &.{ 12, 4, 2, 4 } } // dash, dot, dash, dot
pub const Dash = struct {
    /// The lengths, in logical pixels.
    pattern: []const f32,
    /// How far into the pattern the line begins.
    offset: f32 = 0,
    /// The ends of each dash: cut square, or rounded (half the line's
    /// width beyond the dash, so a dash of no length is a dot).
    cap: Cap = .butt,
    /// On a closed line (a rectangle's edge, a circle), the lengths
    /// stretched or shrunk a little so that the pattern goes round a whole
    /// number of times (no short dash, or dots too close, where it meets
    /// itself).
    fit: bool = true,

    pub const Cap = enum { butt, round };

    /// How much the lengths are stretched on a closed line `length` long
    /// (1 if not, or if `fit` is off).
    pub fn fitScale(d: Dash, length: f32) f32 {
        const p = d.period();
        if (!d.fit or p <= 0 or length <= 0) return 1;
        const times = @max(@round(length / p), 1);
        return length / (times * p);
    }

    /// The pattern's length (twice its lengths' sum, if there is an odd
    /// number of them).
    pub fn period(d: Dash) f32 {
        var sum: f32 = 0;
        for (d.pattern) |l| sum += @max(l, 0);
        return if (d.pattern.len % 2 == 1) 2 * sum else sum;
    }

    /// How much of the line is dashes (for one too fine to draw dash by
    /// dash: it is drawn whole, as faint).
    pub fn drawn(d: Dash) f32 {
        const p = d.period();
        if (p <= 0) return 1;
        var on: f32 = 0;
        const n = if (d.pattern.len % 2 == 1) 2 * d.pattern.len else d.pattern.len;
        for (0..n) |i| if (i % 2 == 0) {
            on += @max(d.pattern[i % d.pattern.len], 0);
        };
        return on / p;
    }

    /// The length of the `i`th part of the (repeated) pattern.
    fn part(d: Dash, i: usize) f32 {
        return @max(d.pattern[i % d.pattern.len], 0);
    }

    fn parts(d: Dash) usize {
        return if (d.pattern.len % 2 == 1) 2 * d.pattern.len else d.pattern.len;
    }
};

/// Where along the pattern a distance is: which part (dashes are the even
/// ones), and how much of it is left (in pixels).
const Phase = struct { part: usize, left: f64 };

fn phaseAt(d: Dash, scale: f64, distance: f64) Phase {
    const p = @as(f64, d.period()) * scale;
    var at = @mod(distance + @as(f64, d.offset) * scale, p);
    for (0..d.parts()) |i| {
        const l = @as(f64, d.part(i)) * scale;
        // (A dot, a dash of no length, is at the distance it is at.)
        if (at < l or (l == 0 and at == 0)) return .{ .part = i, .left = l - at };
        at -= l;
    }
    return .{ .part = 0, .left = @as(f64, d.part(0)) * scale };
}

/// Where a segment from `a` to `b` is within `r` (x0, y0, x1, y1): the
/// fractions of it from and to, or null if none of it is (Liang and
/// Barsky's way).
fn clip(a: Point, b: Point, r: [4]f32) ?[2]f64 {
    var t0: f64 = 0;
    var t1: f64 = 1;
    const d: Point = .{ b[0] - a[0], b[1] - a[1] };
    const ps = [4]f32{ -d[0], d[0], -d[1], d[1] };
    const qs = [4]f32{ a[0] - r[0], r[2] - a[0], a[1] - r[1], r[3] - a[1] };
    for (ps, qs) |p, q| {
        if (p == 0) {
            if (q < 0) return null;
            continue;
        }
        const t = @as(f64, q) / p;
        if (p < 0) t0 = @max(t0, t) else t1 = @min(t1, t);
        if (t0 > t1) return null;
    }
    return .{ t0, t1 };
}

/// What the dashes found are given to: each as a polyline (one point,
/// for a dash of no length).
pub const Emit = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, points: []const Point) void,
};

/// The most dashes `walk` finds in one call: past them (a pattern far too
/// fine for the length in view), it stops.
pub const max_dashes = 1 << 16;

/// Finds the dashes of a polyline (in pixels, closed back to its first
/// point if `closed`) dashed as `d` at `scale` pixels to its unit, that
/// are within `visible` (x0, y0, x1, y1), and gives each to `emit`. Parts
/// of the line out of view cost a step each, however many dashes they
/// are. The pattern runs on along the line, round its corners. False if
/// there were too many dashes to give them all.
pub fn walk(points: []const Point, closed: bool, d: Dash, scale: f32, visible: [4]f32, emit: Emit) bool {
    if (points.len == 0 or d.pattern.len == 0 or d.period() <= 0) return true;
    var dash: [geometry.max_points]Point = undefined;
    var dash_len: usize = 0;
    // Where along the line the dash being made ends (it may go on into
    // the next segment). Distances are kept in f64: along a line millions
    // of pixels long, f32 cannot step by a dash a pixel or two long.
    var dash_end: f64 = 0;
    var count: usize = 0;
    var along: f64 = 0;
    const n = points.len;
    const segments = if (closed) n else n - 1;
    // Round a closed line, a dash at its end is the one at its start.
    var total: f64 = 0;
    if (closed) for (0..n) |i| {
        const a = points[i];
        const b = points[(i + 1) % n];
        total += std.math.hypot(@as(f64, b[0] - a[0]), @as(f64, b[1] - a[1]));
    };
    for (0..segments) |i| {
        const a = points[i];
        const b = points[(i + 1) % n];
        const len: f64 = std.math.hypot(@as(f64, b[0] - a[0]), @as(f64, b[1] - a[1]));
        defer along += len;
        if (len <= 0) continue;
        const t = clip(a, b, visible) orelse {
            flush(emit, &dash, &dash_len, &count);
            continue;
        };
        const s0 = along + t[0] * len;
        const s1 = along + t[1] * len;
        // A dash goes on into this segment only from where it ended.
        if (dash_len > 0 and @abs(dash_end - s0) > 1e-3) flush(emit, &dash, &dash_len, &count);
        var phase = phaseAt(d, scale, s0);
        var s = s0;
        while (true) {
            // Where this part of the pattern ends, and where it stops being
            // in view.
            const end = s + phase.left;
            const stop = @min(s1, end);
            // A dash only beginning where the view ends begins in the
            // next segment, if anywhere (a dash of no length is a dot).
            const again = closed and dash_len == 0 and s >= total - 1e-4;
            if (phase.part % 2 == 0 and !(stop <= s and end > s) and !again) {
                if (dash_len == 0) {
                    dash[0] = pointAt(a, b, len, s - along);
                    dash_len = 1;
                }
                if (stop > s) {
                    if (dash_len == dash.len) {
                        // Too many corners for one dash: it goes on as
                        // another, from here.
                        const last = dash[dash_len - 1];
                        flush(emit, &dash, &dash_len, &count);
                        dash[0] = last;
                        dash_len = 1;
                    }
                    dash[dash_len] = pointAt(a, b, len, stop - along);
                    dash_len += 1;
                }
                dash_end = stop;
                // Done within the view; otherwise it may go on into the
                // next segment.
                if (end <= s1) flush(emit, &dash, &dash_len, &count);
            }
            if (count >= max_dashes) return false;
            if (end > s1) break;
            s = end;
            const next = (phase.part + 1) % d.parts();
            phase = .{ .part = next, .left = @as(f64, d.part(next)) * scale };
        }
    }
    flush(emit, &dash, &dash_len, &count);
    return count < max_dashes;
}

fn pointAt(a: Point, b: Point, len: f64, at: f64) Point {
    const k: f32 = @floatCast(at / len);
    return .{ a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k };
}

fn flush(emit: Emit, dash: []Point, dash_len: *usize, count: *usize) void {
    if (dash_len.* == 0) return;
    emit.f(emit.ctx, dash[0..dash_len.*]);
    dash_len.* = 0;
    count.* += 1;
}

const testing = std.testing;

/// The dashes a walk gave: their ends.
const Found = struct {
    dashes: [64][2]Point = undefined,
    corners: [64]usize = undefined,
    n: usize = 0,
    total: usize = 0,

    fn add(ctx: *anyopaque, points: []const Point) void {
        const f: *Found = @ptrCast(@alignCast(ctx));
        f.total += 1;
        if (f.n == f.dashes.len) return;
        f.dashes[f.n] = .{ points[0], points[points.len - 1] };
        f.corners[f.n] = points.len;
        f.n += 1;
    }

    fn emit(f: *Found) Emit {
        return .{ .ctx = f, .f = add };
    }
};

const everywhere = [4]f32{ -1e9, -1e9, 1e9, 1e9 };

test "a line is broken into its pattern's dashes, from its offset" {
    var f: Found = .{};
    // 0 to 30: dashes 6 long, 4 apart, the first 2 into the pattern.
    try testing.expect(walk(&.{ .{ 0, 0 }, .{ 30, 0 } }, false, .{ .pattern = &.{ 6, 4 }, .offset = 2 }, 1, everywhere, f.emit()));
    const want = [_][2]f32{ .{ 0, 4 }, .{ 8, 14 }, .{ 18, 24 }, .{ 28, 30 } };
    try testing.expectEqual(want.len, f.n);
    for (want, f.dashes[0..f.n]) |w, got| {
        try testing.expectApproxEqAbs(w[0], got[0][0], 1e-4);
        try testing.expectApproxEqAbs(w[1], got[1][0], 1e-4);
    }
    // At twice the scale, twice as long.
    f = .{};
    _ = walk(&.{ .{ 0, 0 }, .{ 20, 0 } }, false, .{ .pattern = &.{ 6, 4 } }, 2, everywhere, f.emit());
    try testing.expectEqual(@as(usize, 1), f.n);
    try testing.expectApproxEqAbs(@as(f32, 12), f.dashes[0][1][0], 1e-4);
}

test "a dash turns a corner as one piece, and dots are dashes of no length" {
    var f: Found = .{};
    // A dash 10 long from 5 before the corner to 5 after it.
    _ = walk(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 } }, false, .{ .pattern = &.{ 10, 10 }, .offset = 15 }, 1, everywhere, f.emit());
    try testing.expectEqual(@as(usize, 1), f.n);
    try testing.expectEqual(@as(usize, 3), f.corners[0]);
    try testing.expectEqual(Point{ 5, 0 }, f.dashes[0][0]);
    try testing.expectEqual(Point{ 10, 5 }, f.dashes[0][1]);

    f = .{};
    _ = walk(&.{ .{ 0, 0 }, .{ 20, 0 } }, false, .{ .pattern = &.{ 0, 5 }, .cap = .round }, 1, everywhere, f.emit());
    // At 0, 5, 10, 15 and 20.
    try testing.expectEqual(@as(usize, 5), f.n);
    for (f.dashes[0..f.n], f.corners[0..f.n], 0..) |dot, corners, k| {
        try testing.expectEqual(@as(usize, 1), corners);
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(k * 5)), dot[0][0], 1e-4);
    }
}

test "only the dashes in view are found, however long the line" {
    var f: Found = .{};
    // A line ten million pixels long, dashed every 2, seen through a
    // window 20 across in its middle: the five dashes there, at once.
    const view = [4]f32{ 5_000_000, -5, 5_000_020, 5 };
    try testing.expect(walk(&.{ .{ 0, 0 }, .{ 10_000_000, 0 } }, false, .{ .pattern = &.{ 2, 2 } }, 1, view, f.emit()));
    try testing.expectEqual(@as(usize, 5), f.total);
    try testing.expectApproxEqAbs(@as(f32, 5_000_000), f.dashes[0][0][0], 1);
    // A line of many segments, all but one out of view: no dashes from
    // them.
    var pts: [400]Point = undefined;
    for (&pts, 0..) |*p, k| p.* = .{ @floatFromInt(k * 1000), if (k % 2 == 0) 0 else 1000 };
    f = .{};
    _ = walk(&pts, false, .{ .pattern = &.{ 3, 3 } }, 1, .{ -10, -10, 1, 1 }, f.emit());
    try testing.expect(f.total <= 2);
}

test "round a closed line, the pattern is fitted a whole number of times" {
    const d: Dash = .{ .pattern = &.{ 0, 7 }, .cap = .round };
    // 100 round: 14 dots, 100/14 apart (not 7, with the last 2 from the first).
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 98.0), d.fitScale(100), 1e-5);
    var f: Found = .{};
    _ = walk(&.{ .{ 0, 0 }, .{ 25, 0 }, .{ 25, 25 }, .{ 0, 25 } }, true, d, d.fitScale(100), everywhere, f.emit());
    try testing.expectEqual(@as(usize, 14), f.n);
    var off = d;
    off.fit = false;
    try testing.expectEqual(@as(f32, 1), off.fitScale(100));
}
