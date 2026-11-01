//! Loading images in the background, for `Image`: from files, URLs
//! (`http://`, `https://`, `file://`, `data:`), or a file's bytes; PNG,
//! JPEG, GIF (its first frame) or WebP, made smaller to fit
//! `gfx.Image.max_size` if they are bigger.
//!
//! Loads are done by up to `max_workers` tasks on the app's `std.Io`
//! (`Io.Group.concurrent`; done in turn, as they are asked for, if it has
//! no concurrency), reading files and fetching URLs through it too. They
//! wake the UI when one is done (`waitSource`), and the UI takes what is done
//! (`collect`). An image is kept while it shows, and for `keep_ns` after
//! it last did, so one shown again soon is not loaded again.

const std = @import("std");
const window = @import("window");
const sys = window.sys;
const gfx = @import("gfx");

/// Shared with the workers (which may be on other threads), so
/// thread-safe.
const alloc = std.heap.smp_allocator;

pub const max_workers = 4;
pub const keep_ns = 30 * std.time.ns_per_s;

/// Where an image comes from.
pub const Source = union(enum) {
    /// Pixels in memory, shown at once (they must last as long as they
    /// show).
    image: *const gfx.Image,
    /// A PNG, JPEG, GIF or WebP file.
    file: []const u8,
    /// `http://`, `https://`, `file://`, or `data:` (base64 or not).
    url: []const u8,
    /// An image file's bytes, copied (and known by where they are: the
    /// same place with other bytes is not loaded again).
    bytes: []const u8,
};

/// A part of an image, in its pixels (as it is shown, after a JPEG's
/// EXIF orientation).
pub const Region = gfx.png.Region;

/// How loading an image is going.
pub const Status = union(enum) {
    loading,
    ready: *const gfx.Image,
    failed,
};

pub const Cache = struct {
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    shared: ?*Shared = null,
    /// What loads are done through (none: none can be).
    io: ?std.Io = null,

    const Entry = struct {
        key: []u8,
        status: enum { loading, ready, failed } = .loading,
        pixels: []u32 = &.{},
        image: gfx.Image = undefined,
        last_used_ns: u64,
    };

    pub fn deinit(c: *Cache) void {
        var it = c.entries.valueIterator();
        while (it.next()) |e| free(e.*);
        c.entries.deinit(alloc);
        if (c.shared) |s| s.close();
        c.* = .{};
    }

    fn free(e: *Entry) void {
        alloc.free(e.pixels);
        alloc.free(e.key);
        alloc.destroy(e);
    }

    /// How loading `source` is going, starting it if it has not been.
    pub fn get(c: *Cache, source: Source, now_ns: u64) Status {
        return c.getRegion(source, null, now_ns);
    }

    /// How loading `region` of `source` (all of it if null) is going,
    /// starting it if it has not been: only that part is decoded (and
    /// kept). Pixels in memory (`.image`) are as they are, all of them.
    pub fn getRegion(c: *Cache, source: Source, region: ?Region, now_ns: u64) Status {
        if (source == .image) return .{ .ready = source.image };
        var key_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const key = keyOf(source, region, &key_buf);
        if (c.entries.get(key)) |e| {
            // Only refresh the liveness timestamp for entries that are actually
            // usable; failed entries must expire so that evict() can remove them.
            if (e.status != .failed) e.last_used_ns = now_ns;
            return switch (e.status) {
                .loading => .loading,
                .ready => .{ .ready = &e.image },
                .failed => .failed,
            };
        }
        const e = c.start(source, region, key, now_ns) catch return .failed;
        return if (e.status == .failed) .failed else .loading;
    }

    fn keyOf(source: Source, region: ?Region, buf: []u8) []const u8 {
        const base = switch (source) {
            .image => unreachable,
            .file => |p| p,
            .url => |u| u,
            // Not a path or URL: those start "/", or a scheme.
            .bytes => |b| std.fmt.bufPrint(buf, ":bytes:{x}:{d}", .{ @intFromPtr(b.ptr), b.len }) catch unreachable,
        };
        const r = region orelse return base;
        // A part: known by what it is of, and where (after a NUL, which
        // paths and URLs do not have).
        var tail: [48]u8 = undefined;
        const where = std.fmt.bufPrint(&tail, "\x00{d},{d},{d},{d}", .{ r.x, r.y, r.w, r.h }) catch unreachable;
        if (source == .bytes) {
            const len = base.len;
            if (len + where.len > buf.len) return base;
            @memcpy(buf[len..][0..where.len], where);
            return buf[0 .. len + where.len];
        }
        return std.fmt.bufPrint(buf, "{s}{s}", .{ base, where }) catch blk: {
            // Key too long for the buffer (e.g. a very long data: URL with a
            // region suffix).  Hash base+region so different regions of the
            // same source still get distinct cache entries.
            var h = std.hash.Wyhash.init(0);
            h.update(base);
            h.update(where);
            break :blk std.fmt.bufPrint(buf, ":h:{x}", .{h.final()}) catch unreachable;
        };
    }

    fn start(c: *Cache, source: Source, region: ?Region, key: []const u8, now_ns: u64) !*Entry {
        const io = c.io orelse return error.NoIo;
        if (c.shared == null) c.shared = try Shared.create(io);
        const e = try alloc.create(Entry);
        errdefer alloc.destroy(e);
        e.* = .{ .key = try alloc.dupe(u8, key), .last_used_ns = now_ns };
        errdefer alloc.free(e.key);
        try c.entries.put(alloc, e.key, e);
        errdefer _ = c.entries.remove(e.key);
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);
        const job_key = try alloc.dupe(u8, key);
        errdefer alloc.free(job_key);
        job.* = .{
            .key = job_key,
            .region = region,
            .what = switch (source) {
                .image => unreachable,
                .file => |p| .{ .file = try alloc.dupe(u8, p) },
                .url => |u| .{ .url = try alloc.dupe(u8, u) },
                .bytes => |b| .{ .bytes = try alloc.dupe(u8, b) },
            },
        };
        c.shared.?.add(job) catch {
            job.deinit();
            e.status = .failed;
        };
        return e;
    }

    /// What is read when a load is done (to wait on with the window's),
    /// once any has started.
    pub fn waitSource(c: *const Cache) ?window.Source {
        return if (c.shared) |s| .ofWake(&s.wake) else null;
    }

    /// Takes the loads that are done; true if there were any.
    pub fn collect(c: *Cache) bool {
        const s = c.shared orelse return false;
        _ = s.wake.drain();
        var any = false;
        while (true) {
            s.lock();
            const job = s.done.pop() orelse {
                s.unlock();
                break;
            };
            s.unlock();
            defer job.deinit();
            any = true;
            const e = c.entries.get(job.key) orelse continue;
            if (job.result) |r| {
                e.pixels = r.pixels;
                e.image = .init(r.pixels, r.width, r.height);
                e.status = .ready;
                job.result = null;
            } else e.status = .failed;
        }
        return any;
    }

    /// Lets go of images not shown for `keep_ns` (not those loading).
    pub fn evict(c: *Cache, now_ns: u64) void {
        var it = c.entries.iterator();
        var stale: [16][]const u8 = undefined;
        var n: usize = 0;
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (e.status == .loading or now_ns -| e.last_used_ns < keep_ns) continue;
            stale[n] = kv.key_ptr.*;
            n += 1;
            if (n == stale.len) break;
        }
        for (stale[0..n]) |key| if (c.entries.fetchRemove(key)) |kv| free(kv.value);
    }
};

/// What a load needs, and what it made.
const Job = struct {
    key: []u8,
    /// The part of the image wanted (all if null).
    region: ?Region = null,
    what: union(enum) { file: []u8, url: []u8, bytes: []u8 },
    result: ?Decoded = null,

    fn deinit(j: *Job) void {
        alloc.free(j.key);
        switch (j.what) {
            inline else => |b| alloc.free(b),
        }
        if (j.result) |r| alloc.free(r.pixels);
        alloc.destroy(j);
    }
};

const Decoded = gfx.png.Decoded;

/// The loads waiting and done, shared by the UI and the workers (tasks
/// in `group`).
const Shared = struct {
    io: std.Io,
    mutex: std.atomic.Mutex = .unlocked,
    pending: std.ArrayList(*Job) = .empty,
    done: std.ArrayList(*Job) = .empty,
    workers: u8 = 0,
    closed: bool = false,
    group: std.Io.Group = .init,
    /// Readable when a load is done.
    wake: sys.Wake,

    fn create(io: std.Io) !*Shared {
        const wake = sys.Wake.create() catch return error.SystemResources;
        errdefer wake.deinit();
        const s = try alloc.create(Shared);
        s.* = .{ .io = io, .wake = wake };
        return s;
    }

    fn lock(s: *Shared) void {
        while (!s.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(s: *Shared) void {
        s.mutex.unlock();
    }

    /// Queues a load, with a worker for it if there are fewer than
    /// `max_workers` (or leaves the job pending for an existing worker if
    /// the `Io` cannot start a new concurrent task). The UI thread is
    /// never used to decode images.
    fn add(s: *Shared, job: *Job) !void {
        s.lock();
        s.pending.append(alloc, job) catch |e| {
            s.unlock();
            return e;
        };
        const start = s.workers < max_workers;
        if (start) s.workers += 1;
        s.unlock();
        if (!start) return;
        s.group.concurrent(s.io, work, .{s}) catch {
            // Cannot start a concurrent task.  Undo the worker-count increment;
            // an already-running worker will pick up the job, or the next
            // successful add() will start one.  The UI thread is never used.
            s.lock();
            s.workers -= 1;
            s.unlock();
        };
    }

    /// The UI lets go of it: what is waiting is dropped, the workers are
    /// stopped (waiting for those in the middle of decoding), and it goes.
    fn close(s: *Shared) void {
        s.lock();
        s.closed = true;
        for (s.pending.items) |j| j.deinit();
        s.pending.clearRetainingCapacity();
        s.unlock();
        s.group.cancel(s.io);
        for (s.done.items) |j| j.deinit();
        s.pending.deinit(alloc);
        s.done.deinit(alloc);
        s.wake.deinit();
        alloc.destroy(s);
    }

    fn work(s: *Shared) void {
        var http: ?std.http.Client = null;
        defer if (http) |*h| h.deinit();
        while (true) {
            s.lock();
            if (s.pending.items.len == 0 or s.closed) {
                s.workers -= 1;
                return s.unlock();
            }
            const job = s.pending.orderedRemove(0);
            s.unlock();
            job.result = load(job, s, &http);
            // Append to the done list under the lock, then signal outside it
            // so the UI wake syscall is never made while the spinlock is held.
            var signal = false;
            s.lock();
            if (s.closed) {
                job.deinit();
            } else if (s.done.append(alloc, job)) {
                signal = true;
            } else |_| {
                job.deinit();
            }
            s.unlock();
            if (signal) s.wake.signal();
        }
    }
};

/// Fetches and decodes a job's image (in a worker).
fn load(job: *const Job, s: *Shared, http: *?std.http.Client) ?Decoded {
    const data: []u8 = switch (job.what) {
        .bytes => |b| return decodeFit(b, job.region),
        .file => |p| readFile(s.io, p) orelse return null,
        .url => |u| fetch(u, s, http) orelse return null,
    };
    defer alloc.free(data);
    return decodeFit(data, job.region);
}

fn fetch(url: []const u8, s: *Shared, http: *?std.http.Client) ?[]u8 {
    if (std.mem.startsWith(u8, url, "file://")) {
        const path = percentDecoded(url["file://".len..]) orelse return null;
        defer alloc.free(path);
        return readFile(s.io, path);
    }
    if (std.mem.startsWith(u8, url, "data:")) return dataUrl(url);
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        if (http.* == null) http.* = .{ .allocator = alloc, .io = s.io };
        return httpGet(&http.*.?, url);
    }
    return null;
}

/// An `http://` or `https://` URL's body (following redirects), or null:
/// as `std.http.Client.fetch` does it, but a read of the body that fails
/// (or is canceled, when the UI goes) is null, where `fetch` (in Zig 0.17)
/// unwraps an error the TLS reader keeps to itself, and panics (until
/// https://codeberg.org/ziglang/zig/issues/36296 is fixed, by
/// https://codeberg.org/ziglang/zig/pulls/36299).
fn httpGet(client: *std.http.Client, url: []const u8) ?[]u8 {
    const uri = std.Uri.parse(url) catch return null;
    var req = client.request(.GET, uri, .{ .redirect_behavior = .init(3) }) catch return null;
    defer req.deinit();
    req.sendBodiless() catch return null;
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return null;
    if (response.head.status != .ok) return null;
    const window_len: usize = switch (response.head.content_encoding) {
        .identity => 0,
        .zstd => std.compress.zstd.default_window_len,
        .deflate, .gzip => std.compress.flate.max_window_len,
        .compress => return null,
    };
    const decompress_buf = alloc.alloc(u8, window_len) catch return null;
    defer alloc.free(decompress_buf);
    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    _ = reader.streamRemaining(&body.writer) catch return null;
    return body.toOwnedSlice() catch null;
}

/// A `data:` URL's bytes: `data:image/png;base64,iVBOR...`.
fn dataUrl(url: []const u8) ?[]u8 {
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return null;
    const meta = url["data:".len..comma];
    const payload = url[comma + 1 ..];
    if (std.mem.endsWith(u8, meta, ";base64")) {
        const trimmed = std.mem.trimEnd(u8, payload, "=");
        const out = alloc.alloc(u8, std.base64.standard_no_pad.Decoder.calcSizeForSlice(trimmed) catch return null) catch return null;
        std.base64.standard_no_pad.Decoder.decode(out, trimmed) catch {
            alloc.free(out);
            return null;
        };
        return out;
    }
    return percentDecoded(payload);
}

/// `%41` → `A`.
fn percentDecoded(s: []const u8) ?[]u8 {
    const out = alloc.alloc(u8, s.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
            out[n] = b;
            n += 1;
            i += 2;
            continue;
        } else |_| {};
        out[n] = s[i];
        n += 1;
    }
    defer alloc.free(out);
    return alloc.dupe(u8, out[0..n]) catch null;
}

fn readFile(io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(256 << 20)) catch null;
}

/// A PNG, JPEG, GIF or WebP decoded (or `region` of it), made smaller if
/// it is bigger than the GPU takes.
fn decodeFit(data: []const u8, region: ?Region) ?Decoded {
    const img = (if (gfx.jpeg.is(data))
        gfx.jpeg.decodeRegion(alloc, data, region)
    else if (gfx.gif.is(data))
        gfx.gif.decodeRegion(alloc, data, region)
    else if (gfx.webp.is(data))
        gfx.webp.decodeRegion(alloc, data, region)
    else
        gfx.png.decodeRegion(alloc, data, region)) catch return null;
    const max = gfx.Image.max_size;
    if (img.width <= max and img.height <= max) return img;
    defer alloc.free(img.pixels);
    return shrink(img, max) catch null;
}

/// `img` made to fit within `max` across and down, each pixel the average
/// of those it covers.
fn shrink(img: Decoded, max: u32) !Decoded {
    const scale = @max(@as(f64, @floatFromInt(img.width)) / @as(f64, @floatFromInt(max)), @as(f64, @floatFromInt(img.height)) / @as(f64, @floatFromInt(max)));
    const w: u32 = @intCast(@max(1, @min(max, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(img.width)) / scale))))));
    const h: u32 = @intCast(@max(1, @min(max, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(img.height)) / scale))))));
    const out = try alloc.alloc(u32, @as(usize, w) * h);
    for (0..h) |y| {
        const y0 = y * img.height / h;
        const y1 = @max(y0 + 1, (y + 1) * img.height / h);
        for (0..w) |x| {
            const x0 = x * img.width / w;
            const x1 = @max(x0 + 1, (x + 1) * img.width / w);
            // Accumulate RGB weighted by alpha so that fully-transparent
            // pixels (0x00000000) do not bleed dark fringes into neighbours.
            var sum_b: u64 = 0;
            var sum_g: u64 = 0;
            var sum_r: u64 = 0;
            var sum_a: u64 = 0;
            for (y0..y1) |sy| for (x0..x1) |sx| {
                const p = img.pixels[sy * img.width + sx];
                const a = (p >> 24) & 0xff;
                sum_b += (p & 0xff) * a;
                sum_g += ((p >> 8) & 0xff) * a;
                sum_r += ((p >> 16) & 0xff) * a;
                sum_a += a;
            };
            const count = (y1 - y0) * (x1 - x0);
            const out_a: u32 = @intCast(sum_a / count);
            out[y * w + x] = if (sum_a == 0) 0 else (out_a << 24) |
                (@as(u32, @intCast(sum_r / sum_a)) << 16) |
                (@as(u32, @intCast(sum_g / sum_a)) << 8) |
                @as(u32, @intCast(sum_b / sum_a));
        }
    }
    return .{ .pixels = out, .width = w, .height = h };
}
