//! Wayland client window (`xdg_toplevel` + `wl_shm` shared-memory buffers)
//! with pointer, touch, keyboard (including key repeat), cursor shapes
//! (`wp_cursor_shape_v1`), clipboard and drag-and-drop (`wl_data_device`),
//! text input (`zwp_text_input_v3`), pointer lock (`zwp_pointer_constraints_v1`),
//! and presentation feedback (`wp_presentation`).

const std = @import("std");
const linux = std.os.linux;
const wayland = @import("wayland");
const gfx = @import("gfx");
const window_mod = @import("window.zig");
const clipboard_mod = @import("clipboard.zig");

const client = wayland.client;
const p = wayland.protocol;
const wire = wayland.wire;

pub const Clipboard = clipboard_mod.Clipboard;
pub const DroppedData = clipboard_mod.DroppedData;
pub const InputEvent = window_mod.InputEvent;
pub const TextInputState = window_mod.TextInputState;
pub const PointerCursor = window_mod.PointerCursor;
const xkb = window_mod.xkb;
const compose = window_mod.compose;

const default_size = [2]u32{ 1280, 720 };

pub const shadow_margin: u32 = 28;
pub const corner_radius: f32 = 12.0;
pub const resize_outset: f32 = 10.0;
pub const resize_border = 6;
pub const resize_corner = 20;

pub const edge_top = 1;
pub const edge_bottom = 2;
pub const edge_left = 4;
pub const edge_right = 8;

const max_buffers = 2;

inline fn sdfRoundedBox(dx: f32, dy: f32, hx: f32, hy: f32, r: f32) f32 {
    const qx = @abs(dx) - hx;
    const qy = @abs(dy) - hy;
    const mx = @max(qx, 0.0);
    const my = @max(qy, 0.0);
    return @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0.0) - r;
}

inline fn shadowAlphaAt(px: f32, py: f32, cx0: f32, cy0: f32, hx: f32, hy: f32, r: f32, sf: f32, d_win: f32) f32 {
    const d_key = sdfRoundedBox(px - cx0, py - (cy0 + 4.0 * sf), hx, hy, r);
    const key_rad = 22.0 * sf;
    const u_key = std.math.clamp(1.0 - @max(d_key, 0.0) / key_rad, 0.0, 1.0);
    const t_key = u_key * u_key * u_key;

    const d_amb = sdfRoundedBox(px - cx0, py - (cy0 + 1.0 * sf), hx, hy, r);
    const amb_rad = 7.0 * sf;
    const u_amb = std.math.clamp(1.0 - @max(d_amb, 0.0) / amb_rad, 0.0, 1.0);
    const t_amb = u_amb * u_amb * (3.0 - 2.0 * u_amb);

    const outline_a = if (d_win >= -0.5 and d_win <= 1.2 * sf)
        0.18 * std.math.clamp(1.0 - @abs(d_win - 0.3 * sf) / (0.9 * sf), 0.0, 1.0)
    else
        0.0;

    return std.math.clamp(0.28 * t_key + 0.14 * t_amb + outline_a, 0.0, 1.0);
}

pub const GbmDevice = opaque {};
pub const GbmBo = opaque {};

pub const DmaBufDevice = struct {
    drm_lib: std.DynLib,
    gbm_lib: std.DynLib,
    drm_fd: linux.fd_t,
    gbm_dev: *GbmDevice,
    drm: DrmProcs,
    gbm: GbmProcs,
    supports_syncobj: bool = false,

    const drm_node_primary = 0;
    const drm_node_render = 2;

    const DrmDevice = extern struct {
        nodes: [*][*:0]u8,
        available_nodes: c_int,
        bustype: c_int,
        businfo: ?*anyopaque,
        deviceinfo: ?*anyopaque,
    };

    pub const DrmProcs = struct {
        GetDevices2: *const fn (u32, ?[*]*DrmDevice, c_int) callconv(.c) c_int,
        FreeDevices: *const fn ([*]*DrmDevice, c_int) callconv(.c) void,
        SyncobjCreate: ?*const fn (c_int, u32, *u32) callconv(.c) c_int = null,
        SyncobjDestroy: ?*const fn (c_int, u32) callconv(.c) c_int = null,
        SyncobjHandleToFD: ?*const fn (c_int, u32, *c_int) callconv(.c) c_int = null,
        SyncobjTimelineSignal: ?*const fn (c_int, *const u32, *const u64, u32) callconv(.c) c_int = null,
        SyncobjTimelineWait: ?*const fn (c_int, *u32, *u64, u32, i64, u32, ?*u32) callconv(.c) c_int = null,

        fn load(lib: *std.DynLib) !DrmProcs {
            return .{
                .GetDevices2 = lib.lookup(*const fn (u32, ?[*]*DrmDevice, c_int) callconv(.c) c_int, "drmGetDevices2") orelse return error.MissingDrmFunction,
                .FreeDevices = lib.lookup(*const fn ([*]*DrmDevice, c_int) callconv(.c) void, "drmFreeDevices") orelse return error.MissingDrmFunction,
                .SyncobjCreate = lib.lookup(*const fn (c_int, u32, *u32) callconv(.c) c_int, "drmSyncobjCreate"),
                .SyncobjDestroy = lib.lookup(*const fn (c_int, u32) callconv(.c) c_int, "drmSyncobjDestroy"),
                .SyncobjHandleToFD = lib.lookup(*const fn (c_int, u32, *c_int) callconv(.c) c_int, "drmSyncobjHandleToFD"),
                .SyncobjTimelineSignal = lib.lookup(*const fn (c_int, *const u32, *const u64, u32) callconv(.c) c_int, "drmSyncobjTimelineSignal"),
                .SyncobjTimelineWait = lib.lookup(*const fn (c_int, *u32, *u64, u32, i64, u32, ?*u32) callconv(.c) c_int, "drmSyncobjTimelineWait"),
            };
        }
    };

    pub const GbmProcs = struct {
        create_device: *const fn (c_int) callconv(.c) ?*GbmDevice,
        device_destroy: *const fn (*GbmDevice) callconv(.c) void,
        bo_create: *const fn (*GbmDevice, u32, u32, u32, u32) callconv(.c) ?*GbmBo,
        bo_destroy: *const fn (*GbmBo) callconv(.c) void,
        bo_map: *const fn (*GbmBo, u32, u32, u32, u32, u32, *u32, *?*anyopaque) callconv(.c) ?[*]u8,
        bo_unmap: *const fn (*GbmBo, ?*anyopaque) callconv(.c) void,
        bo_get_fd: *const fn (*GbmBo) callconv(.c) c_int,
        bo_get_stride: *const fn (*GbmBo) callconv(.c) u32,
        bo_get_offset: *const fn (*GbmBo, c_int) callconv(.c) u32,
        bo_get_modifier: *const fn (*GbmBo) callconv(.c) u64,

        fn load(lib: *std.DynLib) !GbmProcs {
            var procs: GbmProcs = undefined;
            inline for (@typeInfo(GbmProcs).@"struct".field_names) |field_name| {
                const sym_name: [:0]const u8 = "gbm_" ++ field_name;
                @field(procs, field_name) = lib.lookup(@FieldType(GbmProcs, field_name), sym_name) orelse return error.MissingGbmFunction;
            }
            return procs;
        }
    };

    pub const gbm_bo_use_rendering: u32 = 1 << 2;
    pub const gbm_bo_use_write: u32 = 1 << 3;
    pub const gbm_bo_use_linear: u32 = 1 << 4;

    pub const gbm_bo_transfer_read: u32 = 1 << 0;
    pub const gbm_bo_transfer_write: u32 = 1 << 1;
    pub const gbm_bo_transfer_read_write: u32 = gbm_bo_transfer_read | gbm_bo_transfer_write;

    pub const Allocation = struct {
        bo: *GbmBo,
        dmabuf_fd: linux.fd_t,
        stride: u32,
        offset: u32,
        modifier: u64,
    };

    pub fn open() ?DmaBufDevice {
        var drm_lib = std.DynLib.open("libdrm.so.2") catch std.DynLib.open("libdrm.so") catch return null;
        const drm = DrmProcs.load(&drm_lib) catch {
            drm_lib.close();
            return null;
        };

        var gbm_lib = std.DynLib.open("libgbm.so.1") catch std.DynLib.open("libgbm.so") catch {
            drm_lib.close();
            return null;
        };
        const gbm = GbmProcs.load(&gbm_lib) catch {
            gbm_lib.close();
            drm_lib.close();
            return null;
        };

        var devices: [16]*DrmDevice = undefined;
        const count = drm.GetDevices2(0, &devices, devices.len);
        if (count > 0) {
            const n: usize = @intCast(count);
            defer drm.FreeDevices(&devices, count);
            for ([_]u5{ drm_node_render, drm_node_primary }) |node_type| {
                for (devices[0..n]) |dev| {
                    if ((dev.available_nodes & (@as(c_int, 1) << node_type)) == 0) continue;
                    if (tryOpenNode(dev.nodes[node_type], drm_lib, gbm_lib, drm, gbm)) |d| return d;
                }
            }
        }

        gbm_lib.close();
        drm_lib.close();
        return null;
    }

    fn tryOpenNode(path: [*:0]const u8, drm_lib: std.DynLib, gbm_lib: std.DynLib, drm: DrmProcs, gbm: GbmProcs) ?DmaBufDevice {
        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: linux.fd_t = @intCast(rc);
        const gbm_dev = gbm.create_device(fd) orelse {
            _ = linux.close(fd);
            return null;
        };
        var supports_syncobj = false;
        if (drm.SyncobjCreate != null and drm.SyncobjDestroy != null and drm.SyncobjHandleToFD != null and drm.SyncobjTimelineSignal != null and drm.SyncobjTimelineWait != null) {
            var handle: u32 = 0;
            if (drm.SyncobjCreate.?(fd, 0, &handle) == 0) {
                var pt: u64 = 1;
                if (drm.SyncobjTimelineSignal.?(fd, &handle, &pt, 1) == 0) {
                    var obj_fd: c_int = -1;
                    if (drm.SyncobjHandleToFD.?(fd, handle, &obj_fd) == 0 and obj_fd >= 0) {
                        _ = linux.close(obj_fd);
                        supports_syncobj = true;
                    }
                }
                _ = drm.SyncobjDestroy.?(fd, handle);
            }
        }
        const dev: DmaBufDevice = .{
            .drm_lib = drm_lib,
            .gbm_lib = gbm_lib,
            .drm_fd = fd,
            .gbm_dev = gbm_dev,
            .drm = drm,
            .gbm = gbm,
            .supports_syncobj = supports_syncobj,
        };
        if (dev.alloc(4, 4, p.fourcc.argb8888)) |probe| {
            _ = linux.close(probe.dmabuf_fd);
            dev.gbm.bo_destroy(probe.bo);
            return dev;
        } else |_| {
            dev.gbm.device_destroy(gbm_dev);
            _ = linux.close(fd);
            return null;
        }
    }

    pub fn close(dev: *DmaBufDevice) void {
        dev.gbm.device_destroy(dev.gbm_dev);
        if (dev.drm_fd >= 0) _ = linux.close(dev.drm_fd);
        dev.gbm_lib.close();
        dev.drm_lib.close();
    }

    pub fn alloc(dev: *const DmaBufDevice, width: u32, height: u32, format: u32) !Allocation {
        const flags = gbm_bo_use_rendering | gbm_bo_use_linear;
        const bo = dev.gbm.bo_create(dev.gbm_dev, width, height, format, flags) orelse
            dev.gbm.bo_create(dev.gbm_dev, width, height, format, gbm_bo_use_linear) orelse
            dev.gbm.bo_create(dev.gbm_dev, width, height, format, gbm_bo_use_write) orelse
            return error.OutOfMemory;
        errdefer dev.gbm.bo_destroy(bo);

        const fd = dev.gbm.bo_get_fd(bo);
        if (fd < 0) return error.OutOfMemory;
        return .{
            .bo = bo,
            .dmabuf_fd = fd,
            .stride = dev.gbm.bo_get_stride(bo),
            .offset = dev.gbm.bo_get_offset(bo, 0),
            .modifier = dev.gbm.bo_get_modifier(bo),
        };
    }
};

pub const Buffer = struct {
    pub const drm_syncobj_wait_flags_wait_all: u32 = 1 << 0;
    pub const drm_syncobj_wait_flags_wait_for_submit: u32 = 1 << 1;

    drawn: u64 = 0,
    bo: ?*GbmBo = null,
    gbm: ?DmaBufDevice.GbmProcs = null,
    drm_fd: linux.fd_t = -1,
    drm: ?DmaBufDevice.DrmProcs = null,
    syncobj_handle: u32 = 0,
    syncobj_timeline: client.Proxy = .{},
    syncobj_point: u64 = 0,
    release_point: u64 = 0,
    map_data: ?*anyopaque = null,
    pixels: []u8 = &.{},
    /// A dmabuf's identity (for a renderer's import of it), format, layout,
    /// and its fd for the renderer (made when first asked for).
    id: u64 = 0,
    fourcc: u32 = 0,
    modifier: u64 = 0,
    offset: u32 = 0,
    export_fd: linux.fd_t = -1,
    /// The renderer draws the shadow and corners of frames given it to
    /// draw on the GPU (`beginDmabufFrame`), so `finishFrame` need not.
    gpu_frame: bool = false,
    pool: client.Proxy = .{},
    proxy: client.Proxy = .{},
    width: u32,
    height: u32,
    stride_words: u32 = 0,
    content_w: u32 = 0,
    content_h: u32 = 0,
    margin: u32 = 0,
    scale: u32 = 1,
    busy: bool = false,
    shadow_drawn: bool = false,

    pub inline fn rowWords(b: *const Buffer) u32 {
        return if (b.stride_words > 0) b.stride_words else b.width;
    }

    /// True when the compositor has finished reading the buffer (either via
    /// `wp_linux_drm_syncobj_v1` release timeline point or `wl_buffer.release`).
    pub fn isReady(b: *Buffer) bool {
        if (b.release_point > 0) {
            if (b.drm) |drm| if (drm.SyncobjTimelineWait) |wait_fn| {
                var handle = b.syncobj_handle;
                var pt = b.release_point;
                if (wait_fn(b.drm_fd, &handle, &pt, 1, 0, drm_syncobj_wait_flags_wait_all, null) == 0) {
                    b.release_point = 0;
                    b.busy = false;
                    return true;
                }
            };
            return false;
        }
        return !b.busy;
    }

    /// Waits up to `timeout_ns` for the buffer's explicit release timeline point
    /// to signal, returning true once the buffer is ready for reuse.
    pub fn waitReady(b: *Buffer, now_ns: u64, timeout_ns: u64) bool {
        if (b.release_point > 0) {
            if (b.drm) |drm| if (drm.SyncobjTimelineWait) |wait_fn| {
                var handle = b.syncobj_handle;
                var pt = b.release_point;
                const deadline: i64 = @intCast(@min(now_ns +| timeout_ns, @as(u64, std.math.maxInt(i64))));
                const flags = drm_syncobj_wait_flags_wait_all | drm_syncobj_wait_flags_wait_for_submit;
                if (wait_fn(b.drm_fd, &handle, &pt, 1, deadline, flags, null) == 0) {
                    b.release_point = 0;
                    b.busy = false;
                    return true;
                }
            };
            return false;
        }
        return !b.busy;
    }

    pub fn beginCpuAccess(b: *Buffer) !void {
        const bo = b.bo orelse return;
        if (b.map_data != null) return;
        const gbm = b.gbm orelse return error.OutOfMemory;
        var map_stride: u32 = 0;
        var map_data: ?*anyopaque = null;
        const ptr = gbm.bo_map(
            bo,
            0,
            0,
            b.width,
            b.height,
            DmaBufDevice.gbm_bo_transfer_read_write,
            &map_stride,
            &map_data,
        ) orelse return error.OutOfMemory;
        b.map_data = map_data;
        b.stride_words = map_stride / 4;
        b.pixels = ptr[0 .. @as(usize, map_stride) * @as(usize, b.height)];
    }

    pub fn endCpuAccess(b: *Buffer) void {
        const bo = b.bo orelse return;
        if (b.map_data == null) return;
        if (b.gbm) |gbm| {
            gbm.bo_unmap(bo, b.map_data);
        }
        b.map_data = null;
        b.pixels = &.{};
    }

    /// Returns the window content sub-image (inside the shadow margin) with
    /// `stride` set to the full buffer row stride in `u32` words.
    pub fn image(b: *Buffer) gfx.software.Image {
        const cw = if (b.content_w > 0) b.content_w else b.width;
        const ch = if (b.content_h > 0) b.content_h else b.height;
        const sw = b.rowWords();
        const words: [*]u32 = @ptrCast(@alignCast(b.pixels.ptr));
        const total = @as(usize, sw) * @as(usize, b.height);
        const start = @as(usize, b.margin) * @as(usize, sw) + @as(usize, b.margin);
        return .{
            .pixels = words[start..total],
            .stride = sw,
            .width = cw,
            .height = ch,
        };
    }

    /// Renders the drop shadow into the outer margin around the window content.
    pub fn renderShadowMargin(b: *Buffer) void {
        if (b.shadow_drawn or b.margin == 0 or b.content_w == 0 or b.content_h == 0) return;
        const words: [*]u32 = @ptrCast(@alignCast(b.pixels.ptr));
        const m = b.margin;
        const cw = b.content_w;
        const ch = b.content_h;
        const bw = b.width;
        const bh = b.height;
        const sw = b.rowWords();
        const sf: f32 = @floatFromInt(@max(b.scale, 1));
        const r = corner_radius * sf;
        const f_m: f32 = @floatFromInt(m);
        const f_cw: f32 = @floatFromInt(cw);
        const f_ch: f32 = @floatFromInt(ch);
        const cx0 = f_m + f_cw * 0.5;
        const cy0 = f_m + f_ch * 0.5;
        const hx = @max(f_cw * 0.5 - r, 0.0);
        const hy = @max(f_ch * 0.5 - r, 0.0);

        for (0..bh) |by| {
            const py = @as(f32, @floatFromInt(by)) + 0.5;
            const row = words[by * sw ..][0..bw];
            const in_y = by >= m and by < m + ch;
            if (!in_y) {
                for (0..bw) |bx| {
                    const px = @as(f32, @floatFromInt(bx)) + 0.5;
                    const d_win = sdfRoundedBox(px - cx0, py - cy0, hx, hy, r);
                    const sa = shadowAlphaAt(px, py, cx0, cy0, hx, hy, r, sf, d_win);
                    const a_u32: u32 = @intFromFloat(@round(sa * 255.0));
                    row[bx] = a_u32 << 24;
                }
            } else {
                for (0..m) |bx| {
                    const px = @as(f32, @floatFromInt(bx)) + 0.5;
                    const d_win = sdfRoundedBox(px - cx0, py - cy0, hx, hy, r);
                    const sa = shadowAlphaAt(px, py, cx0, cy0, hx, hy, r, sf, d_win);
                    const a_u32: u32 = @intFromFloat(@round(sa * 255.0));
                    row[bx] = a_u32 << 24;
                }
                for (m + cw..bw) |bx| {
                    const px = @as(f32, @floatFromInt(bx)) + 0.5;
                    const d_win = sdfRoundedBox(px - cx0, py - cy0, hx, hy, r);
                    const sa = shadowAlphaAt(px, py, cx0, cy0, hx, hy, r, sf, d_win);
                    const a_u32: u32 = @intFromFloat(@round(sa * 255.0));
                    row[bx] = a_u32 << 24;
                }
            }
        }
        b.shadow_drawn = true;
    }

    /// Rounds the 4 corners of the window content over the drop shadow for any
    /// corner pixels covered by `repainted` (or all 4 corners if `repainted == null`).
    /// Whether the shadow or the rounded corners must be drawn (on the CPU)
    /// for a frame that repainted `repainted` (everything if null).
    pub fn needsCpuFinish(b: *const Buffer, repainted: ?[]const gfx.Viewport) bool {
        if (b.margin == 0) return false;
        if (!b.shadow_drawn) return true;
        const list = repainted orelse return true;
        const cw: i32 = @intCast(b.content_w);
        const ch: i32 = @intCast(b.content_h);
        const r: i32 = @intFromFloat(@ceil(corner_radius * @as(f32, @floatFromInt(@max(b.scale, 1)))));
        const corners = [_]gfx.Viewport{
            .{ .x = 0, .y = 0, .width = @intCast(r), .height = @intCast(r) },
            .{ .x = cw - r, .y = 0, .width = @intCast(r), .height = @intCast(r) },
            .{ .x = 0, .y = ch - r, .width = @intCast(r), .height = @intCast(r) },
            .{ .x = cw - r, .y = ch - r, .width = @intCast(r), .height = @intCast(r) },
        };
        for (list) |v| for (corners) |c| if (v.intersects(c)) return true;
        return false;
    }

    pub fn applyRoundedCorners(b: *Buffer, repainted: ?[]const gfx.Viewport) void {
        if (b.margin == 0 or b.content_w == 0 or b.content_h == 0) return;
        const words: [*]u32 = @ptrCast(@alignCast(b.pixels.ptr));
        const m = b.margin;
        const cw = b.content_w;
        const ch = b.content_h;
        const sw = b.rowWords();
        const sf: f32 = @floatFromInt(@max(b.scale, 1));
        const r = corner_radius * sf;
        const corner_px: u32 = @min(@as(u32, @intFromFloat(@ceil(r))) + 1, @min(cw / 2, ch / 2));
        if (corner_px == 0) return;

        const f_m: f32 = @floatFromInt(m);
        const f_cw: f32 = @floatFromInt(cw);
        const f_ch: f32 = @floatFromInt(ch);
        const cx0 = f_m + f_cw * 0.5;
        const cy0 = f_m + f_ch * 0.5;
        const hx = @max(f_cw * 0.5 - r, 0.0);
        const hy = @max(f_ch * 0.5 - r, 0.0);

        const corners = [4][2]u32{
            .{ 0, 0 },
            .{ cw - corner_px, 0 },
            .{ 0, ch - corner_px },
            .{ cw - corner_px, ch - corner_px },
        };

        for (corners) |c0| {
            var cy: u32 = c0[1];
            while (cy < c0[1] + corner_px) : (cy += 1) {
                var cx: u32 = c0[0];
                while (cx < c0[0] + corner_px) : (cx += 1) {
                    if (repainted) |vps| {
                        var in_vp = false;
                        for (vps) |vp| {
                            if (cx >= @as(u32, @intCast(@max(vp.x, 0))) and
                                cy >= @as(u32, @intCast(@max(vp.y, 0))) and
                                @as(i32, @intCast(cx)) < vp.x + @as(i32, @intCast(vp.width)) and
                                @as(i32, @intCast(cy)) < vp.y + @as(i32, @intCast(vp.height)))
                            {
                                in_vp = true;
                                break;
                            }
                        }
                        if (!in_vp) continue;
                    }

                    const bx = m + cx;
                    const by = m + cy;
                    const px = @as(f32, @floatFromInt(bx)) + 0.5;
                    const py = @as(f32, @floatFromInt(by)) + 0.5;
                    const d_win = sdfRoundedBox(px - cx0, py - cy0, hx, hy, r);
                    if (d_win <= -0.5) continue;

                    const cov = std.math.clamp(0.5 - d_win, 0.0, 1.0);
                    const sa = shadowAlphaAt(px, py, cx0, cy0, hx, hy, r, sf, d_win);
                    const idx = @as(usize, by) * sw + bx;
                    const src = words[idx];
                    const sr: f32 = @floatFromInt((src >> 16) & 0xff);
                    const sg: f32 = @floatFromInt((src >> 8) & 0xff);
                    const sb: f32 = @floatFromInt(src & 0xff);
                    const src_a: f32 = (@as(f32, @floatFromInt((src >> 24) & 0xff)) / 255.0) * cov;
                    const out_a: u32 = @intFromFloat(@round(std.math.clamp(src_a + sa * (1.0 - src_a), 0.0, 1.0) * 255.0));
                    const out_r: u32 = @intFromFloat(@round(sr * cov));
                    const out_g: u32 = @intFromFloat(@round(sg * cov));
                    const out_b: u32 = @intFromFloat(@round(sb * cov));
                    words[idx] = (out_a << 24) | (out_r << 16) | (out_g << 8) | out_b;
                }
            }
        }
    }
};

/// A popup's surface (`WaylandWindow.openPopup`): an `xdg_popup` above the
/// window, drawn in its own `wl_shm` buffers.
const PopupSurface = struct {
    id: u32,
    placement: window_mod.PopupPlacement,
    surface: client.Proxy,
    xdg_surface: client.Proxy,
    popup: client.Proxy,
    scale: u32,
    /// Where the compositor put it, relative to the window's geometry
    /// (from `xdg_popup.configure`), once it has.
    position: ?[2]i32 = null,
    /// It has been configured, so it can be drawn.
    configured: bool = false,
    /// A buffer has been committed to it.
    shown: bool = false,
    buffers: [2]?Buffer = @splat(null),
    back: ?usize = null,
};

pub const max_popups = 4;

/// The app's connection to the compositor, which its windows are opened on
/// (`openWindow`) and wait through together (`wait`, `poll`, `watch`). Each
/// window binds what it needs of the compositor's globals, its seat's
/// pointer and keyboard among them, and heeds only what happens on its own
/// surfaces.
pub const WaylandDisplay = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    conn: *client.Display,
    compose_env: compose.Env = .{},
    /// Its windows, and what they wait on as well as the compositor.
    windows: std.ArrayList(*WaylandWindow) = .empty,
    watched: [8]?window_mod.Source = @splat(null),
    /// A read of the connection, through `io`, that failed.
    read_error: ?wire.Error = null,

    // Shared globals bound once when the first window opens:
    globals: client.Globals = .{},
    compositor: client.Proxy = .{},
    wm_base: client.Proxy = .{},
    shm: ?client.Proxy = null,
    dmabuf: ?client.Proxy = null,
    dmabuf_dev: ?DmaBufDevice = null,
    dmabuf_argb8888: bool = false,
    dmabuf_xrgb8888: bool = false,
    drm_syncobj_manager: ?client.Proxy = null,
    decoration_manager: ?client.Proxy = null,
    cursor_shape_manager: ?client.Proxy = null,
    fifo_manager: ?client.Proxy = null,
    commit_timing_manager: ?client.Proxy = null,
    pointer_constraints: ?client.Proxy = null,
    relative_pointer_manager: ?client.Proxy = null,
    presentation: ?client.Proxy = null,
    presentation_clock_id: u32 = 1,
    text_input_manager: ?client.Proxy = null,
    // Shared seat (one per connection):
    seat: ?client.Proxy = null,
    pointer: ?client.Proxy = null,
    keyboard: ?client.Proxy = null,
    touch: ?client.Proxy = null,
    cursor_device: ?client.Proxy = null,
    relative_pointer: ?client.Proxy = null,
    text_input: ?client.Proxy = null,
    clipboard: Clipboard = undefined,
    clipboard_initialized: bool = false,
    // Shared keyboard/compose/repeat state:
    keymap: ?xkb.Keymap = null,
    xkb_state: xkb.State = .{},
    compose_table: ?compose.Table = null,
    compose_tried: bool = false,
    compose_state: compose.State = .{},
    repeat_rate: u32 = 25,
    repeat_delay_ms: u32 = 600,
    display_repeat: ?struct { code: u32, next_ns: u64 } = null,
    keys_down: std.bit_set.Static(256) = .empty,
    // Input routing:
    pointer_window: ?*WaylandWindow = null,
    keyboard_window: ?*WaylandWindow = null,
    // Shared pointer state:
    pointer_pos: [2]f32 = .{ 0, 0 },
    press_serial: u32 = 0,
    enter_serial: u32 = 0,
    buttons_down: u32 = 0,
    leave_pending: bool = false,
    cursor_shape: ?u32 = null,
    // Touch routing (touch id -> window):
    touch_windows: [8]?struct { id: i32, window: ?*WaylandWindow } = @splat(null),

    pub const platform: window_mod.WindowPlatform = .wayland;

    /// Connects to the compositor named in `environ` (`WAYLAND_DISPLAY`
    /// under `XDG_RUNTIME_DIR`), doing its I/O (and waiting) through `io`.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !*WaylandDisplay {
        var path_buf: [256]u8 = undefined;
        const path = try client.environSocketPath(&path_buf, environ);
        const conn = try client.Display.connect(gpa, io, path);
        errdefer conn.disconnect();
        const d = try gpa.create(WaylandDisplay);
        d.* = .{ .gpa = gpa, .io = io, .conn = conn, .compose_env = .from(environ) };
        return d;
    }

    /// Disconnects (its windows must be closed first).
    pub fn close(d: *WaylandDisplay) void {
        std.debug.assert(d.windows.items.len == 0);
        d.deinitGlobals();
        d.windows.deinit(d.gpa);
        d.conn.disconnect();
        d.gpa.destroy(d);
    }

    /// Opens a window on it (closed with `WaylandWindow.close`).
    pub fn openWindow(d: *WaylandDisplay, options: WaylandWindow.Options) !*WaylandWindow {
        try d.windows.ensureUnusedCapacity(d.gpa, 1);
        if (d.compositor.id == 0) try d.initGlobals();
        const w = try d.createWindowObject(options);
        d.windows.appendAssumeCapacity(w);
        return w;
    }

    /// A window of its is closing.
    fn forget(d: *WaylandDisplay, w: *WaylandWindow) void {
        if (d.pointer_window == w) {
            d.pointer_window = null;
            d.buttons_down = 0;
            d.leave_pending = false;
        }
        if (d.keyboard_window == w) {
            d.keyboard_window = null;
            d.display_repeat = null;
        }
        for (&d.touch_windows) |*slot| if (slot.*) |tw| if (tw.window == w) {
            slot.* = null;
        };
        if (std.mem.indexOfScalar(*WaylandWindow, d.windows.items, w)) |i| _ = d.windows.orderedRemove(i);
    }

    /// Waits on `source` too in `wait` (`on`), or no longer (for as many as
    /// `watched` has room for).
    pub fn watch(d: *WaylandDisplay, source: window_mod.Source, on: bool) void {
        for (&d.watched) |*slot| if (slot.*) |x| if (x.eql(source)) {
            if (!on) slot.* = null;
            return;
        };
        if (!on) return;
        for (&d.watched) |*slot| if (slot.* == null) {
            slot.* = source;
            return;
        };
    }

    /// Handles what has come, without waiting.
    pub fn poll(d: *WaylandDisplay) !void {
        _ = try d.conn.dispatchPending();
        d.service();
    }

    /// Handles what has come, waiting (through `io`, with whatever else
    /// is waiting on it) up to `timeout_ns` for something: an event, a
    /// paste's text, a watched source's read, or a key to repeat.
    pub fn wait(d: *WaylandDisplay, timeout_ns: u64) !void {
        try d.conn.flush();
        if (try d.conn.dispatchPending() == 0) {
            const now_ns = window_mod.nowNs(d.io);
            var ns = timeout_ns;
            var sources: [window_mod.max_sources]window_mod.Source = undefined;
            sources[0] = .{ .ctx = d, .fd = d.conn.conn.fd, .read = connRead, .done = connDone };
            var n: usize = 1;
            for (d.watched) |slot| if (slot) |x| if (n < sources.len) {
                sources[n] = x;
                n += 1;
            };
            if (d.displayRepeatTimeoutMs(now_ns)) |ms| ns = @min(ns, ms *| std.time.ns_per_ms);
            if (d.clipboard_initialized) {
                if (d.clipboard.pasteTimeoutMs()) |ms| ns = @min(ns, ms *| std.time.ns_per_ms);
                if (d.clipboard.pasteFd() != null and n < sources.len) {
                    sources[n] = .{ .ctx = d, .fd = -1, .read = displayPasteRead, .done = displayPasteDone };
                    n += 1;
                }
            }
            for (d.windows.items) |w| {
                if (w.clipboard.pasteTimeoutMs()) |ms| ns = @min(ns, ms *| std.time.ns_per_ms);
                if (w.clipboard.pasteFd() != null and n < sources.len) {
                    sources[n] = .{ .ctx = w, .fd = -1, .read = WaylandWindow.pasteRead, .done = WaylandWindow.pasteDone };
                    n += 1;
                }
            }
            try window_mod.waitSources(d.io, sources[0..n], ns);
            if (d.read_error) |e| {
                d.read_error = null;
                return e;
            }
            _ = try d.conn.dispatchPending();
        }
        d.service();
    }

    /// Reads what has come of pastes, and repeats keys held.
    fn service(d: *WaylandDisplay) void {
        const now_ns = window_mod.nowNs(d.io);
        if (d.keyboard_window) |w| d.displayServiceRepeat(now_ns, w);
        if (d.clipboard_initialized) d.clipboard.service();
        for (d.windows.items) |w| w.clipboard.service();
    }

    fn connRead(ctx: *anyopaque) ?std.Io.Operation {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ctx));
        return d.conn.conn.readOperation() catch |e| {
            d.read_error = e;
            return null;
        };
    }

    fn connDone(ctx: *anyopaque, result: std.Io.Operation.Result) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ctx));
        _ = d.conn.conn.readDone(result) catch |e| {
            d.read_error = e;
        };
    }

    fn displayPasteRead(ctx: *anyopaque) ?std.Io.Operation {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ctx));
        return d.clipboard.readOperation();
    }

    fn displayPasteDone(ctx: *anyopaque, result: std.Io.Operation.Result) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ctx));
        d.clipboard.readDone(result);
    }

    fn windowForSurface(d: *WaylandDisplay, surface_id: u32) ?*WaylandWindow {
        for (d.windows.items) |w| {
            if (w.ownsSurface(surface_id)) return w;
        }
        return null;
    }

    fn touchWindowFor(d: *WaylandDisplay, id: i32) ?*WaylandWindow {
        for (&d.touch_windows) |*slot| if (slot.*) |tw| if (tw.id == id) return tw.window;
        return null;
    }

    fn removeTouchWindow(d: *WaylandDisplay, id: i32) ?*WaylandWindow {
        for (&d.touch_windows) |*slot| if (slot.*) |tw| if (tw.id == id) {
            const w = tw.window;
            slot.* = null;
            return w;
        };
        return null;
    }

    fn flushDisplayPointerLeave(d: *WaylandDisplay) void {
        if (!d.leave_pending) return;
        d.leave_pending = false;
        if (d.pointer_window) |w| {
            d.pointer_window = null;
            d.buttons_down = 0;
            w.pointer_surface = 0;
            w.pointer_pos = .{ 0, 0 };
            w.pushInput(.leave);
        }
    }

    fn updateDisplayCursor(d: *WaylandDisplay) void {
        const w = d.pointer_window orelse return;
        const edges = if (d.buttons_down == 0) w.edgesAt(w.pointer_pos) else 0;
        const sh = p.wp_cursor_shape_device_v1.shape;
        const vertical = edges & (edge_top | edge_bottom);
        const horizontal = edges & (edge_left | edge_right);
        const shape: u32 = if (vertical != 0 and horizontal != 0)
            (if ((vertical == edge_top) == (horizontal == edge_left)) sh.nwse_resize else sh.nesw_resize)
        else if (horizontal != 0)
            sh.ew_resize
        else if (vertical != 0)
            sh.ns_resize
        else
            WaylandWindow.cursorShape(w.app_cursor);
        if (d.cursor_shape == shape) return;
        const device = d.cursor_device orelse return;
        var m = device.request(p.wp_cursor_shape_device_v1.request.set_shape) catch return;
        m.uint(d.enter_serial).uint(shape).end();
        d.cursor_shape = shape;
    }

    fn displayRepeatTimeoutMs(d: *const WaylandDisplay, now_ns: u64) ?u64 {
        const rep = d.display_repeat orelse return null;
        if (d.repeat_rate == 0) return null;
        if (now_ns >= rep.next_ns) return 0;
        return std.math.divCeil(u64, rep.next_ns - now_ns, std.time.ns_per_ms) catch 0;
    }

    fn displayServiceRepeat(d: *WaylandDisplay, now_ns: u64, w: *WaylandWindow) void {
        const rep = &(d.display_repeat orelse return);
        if (d.repeat_rate == 0) {
            d.display_repeat = null;
            return;
        }
        if (now_ns < rep.next_ns) return;
        const step = std.time.ns_per_s / @as(u64, d.repeat_rate);
        rep.next_ns = if (now_ns - rep.next_ns < step) rep.next_ns + step else now_ns + step;
        w.pushKeyViaDisplay(rep.code, true, true, d);
    }

    fn initGlobals(d: *WaylandDisplay) !void {
        const registry = try d.globals.fetch(d.conn);
        d.compositor = (try d.globals.bind(registry, p.wl_compositor.name, 6, null)) orelse return error.NoCompositor;
        d.wm_base = (try d.globals.bind(registry, p.xdg_wm_base.name, 6, .{ .ptr = d, .handler = displayWmBaseEvent })) orelse return error.NoXdgShell;
        if (d.globals.find(p.zwp_linux_dmabuf_v1.name)) |gl| if (gl.version >= 2) {
            if (DmaBufDevice.open()) |dev_val| {
                var dev = dev_val;
                if (try d.globals.bind(registry, p.zwp_linux_dmabuf_v1.name, 3, .{ .ptr = d, .handler = displayDmabufEvent })) |dmabuf_proxy| {
                    d.dmabuf = dmabuf_proxy;
                    d.dmabuf_dev = dev;
                } else {
                    dev.close();
                }
            }
        };
        errdefer if (d.dmabuf_dev) |*dev| {
            dev.close();
            d.dmabuf_dev = null;
        };
        if (try d.globals.bind(registry, p.wl_shm.name, 1, null)) |shm_proxy| {
            d.shm = shm_proxy;
        } else if (d.dmabuf == null or d.dmabuf_dev == null) {
            return error.NoShm;
        }
        if (d.dmabuf != null and d.dmabuf_dev != null and d.dmabuf_dev.?.supports_syncobj) {
            d.drm_syncobj_manager = try d.globals.bind(registry, p.wp_linux_drm_syncobj_manager_v1.name, 1, null);
        }
        d.decoration_manager = try d.globals.bind(registry, p.zxdg_decoration_manager_v1.name, 1, null);
        d.cursor_shape_manager = try d.globals.bind(registry, p.wp_cursor_shape_manager_v1.name, 1, null);
        d.presentation = try d.globals.bind(registry, p.wp_presentation.name, p.wp_presentation.version, .{ .ptr = d, .handler = displayPresentationClockEvent });
        d.fifo_manager = try d.globals.bind(registry, p.wp_fifo_manager_v1.name, 1, null);
        d.commit_timing_manager = try d.globals.bind(registry, p.wp_commit_timing_manager_v1.name, 1, null);
        d.pointer_constraints = try d.globals.bind(registry, p.zwp_pointer_constraints_v1.name, 1, null);
        d.relative_pointer_manager = try d.globals.bind(registry, p.zwp_relative_pointer_manager_v1.name, 1, null);
        d.seat = try d.globals.bind(registry, p.wl_seat.name, 5, .{ .ptr = d, .handler = displaySeatEvent });
        d.clipboard = .{ .gpa = d.gpa, .io = d.io };
        d.clipboard_initialized = true;
        errdefer if (d.clipboard_initialized) {
            d.clipboard.deinit();
            d.clipboard_initialized = false;
        };
        try d.clipboard.attach(d.conn, try d.globals.bind(registry, p.wl_data_device_manager.name, 3, null), d.seat);
        d.text_input_manager = try d.globals.bind(registry, p.zwp_text_input_manager_v3.name, 1, null);
        if (d.text_input_manager) |mgr| if (d.seat) |seat| {
            const ti = try d.conn.newObject(.{ .ptr = d, .handler = displayTextInputEvent });
            var m = try mgr.request(p.zwp_text_input_manager_v3.request.get_text_input);
            m.uint(ti.id).uint(seat.id).end();
            d.text_input = ti;
        };
    }

    fn deinitGlobals(d: *WaylandDisplay) void {
        if (d.compositor.id == 0) return;
        if (d.clipboard_initialized) {
            d.clipboard.deinit();
            d.clipboard_initialized = false;
        }
        if (d.keymap) |*km| {
            km.deinit();
            d.keymap = null;
        }
        if (d.compose_table) |*t| {
            t.deinit();
            d.compose_table = null;
        }
        if (d.dmabuf_dev) |*dev| {
            dev.close();
            d.dmabuf_dev = null;
        }
    }

    /// Creates a window with only per-window objects, using shared display globals.
    fn createWindowObject(d: *WaylandDisplay, options: WaylandWindow.Options) !*WaylandWindow {
        const gpa = d.gpa;
        const conn = d.conn;
        const w = try gpa.create(WaylandWindow);
        errdefer gpa.destroy(w);
        errdefer conn.forgetAll(w);
        const min_size = options.min_size orelse [2]u32{ 0, 0 };
        w.* = WaylandWindow{
            .gpa = gpa,
            .io = conn.conn.io,
            .conn = conn,
            .compositor = d.compositor,
            .wm_base = d.wm_base,
            .shm = d.shm orelse .{},
            .dmabuf = d.dmabuf,
            .dmabuf_argb8888 = d.dmabuf_argb8888,
            .dmabuf_xrgb8888 = d.dmabuf_xrgb8888,
            .drm_syncobj_manager = d.drm_syncobj_manager,
            .decoration_manager = d.decoration_manager,
            .cursor_shape_manager = d.cursor_shape_manager,
            .fifo_manager = d.fifo_manager,
            .commit_timing_manager = d.commit_timing_manager,
            .pointer_constraints = d.pointer_constraints,
            .relative_pointer_manager = d.relative_pointer_manager,
            .presentation = d.presentation,
            .presentation_clock_id = d.presentation_clock_id,
            .text_input_manager = d.text_input_manager,
            .clipboard = .{ .gpa = gpa, .io = conn.conn.io },
            .display = d,
            .compose_env = d.compose_env,
            .width = if (options.maximized) options.size[0] else @max(options.size[0], min_size[0]),
            .height = if (options.maximized) options.size[1] else @max(options.size[1], min_size[1]),
            .min_size = min_size,
            .maximized = options.maximized,
        };
        const tlen = @min(options.title.len, w.title_buf.len);
        @memcpy(w.title_buf[0..tlen], options.title[0..tlen]);
        w.title_len = tlen;
        w.clipboard.drag_callbacks = .{ .ctx = w, .enter = WaylandWindow.onDragEnter, .motion = WaylandWindow.onDragMotion, .leave = WaylandWindow.onDragLeave, .drop = WaylandWindow.onDragDrop };
        w.surface = try conn.newObject(.{ .ptr = w, .handler = WaylandWindow.surfaceEvent });
        var m = try w.compositor.request(p.wl_compositor.request.create_surface);
        m.uint(w.surface.id).end();
        if (d.fifo_manager) |mgr| {
            const fifo = try conn.newObject(null);
            m = try mgr.request(p.wp_fifo_manager_v1.request.get_fifo);
            m.uint(fifo.id).uint(w.surface.id).end();
            w.fifo = fifo;
        }
        if (d.commit_timing_manager) |mgr| {
            const timer = try conn.newObject(null);
            m = try mgr.request(p.wp_commit_timing_manager_v1.request.get_timer);
            m.uint(timer.id).uint(w.surface.id).end();
            w.commit_timer = timer;
        }
        w.xdg_surface = try conn.newObject(.{ .ptr = w, .handler = WaylandWindow.xdgSurfaceEvent });
        m = try w.wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
        m.uint(w.xdg_surface.id).uint(w.surface.id).end();
        w.toplevel = try conn.newObject(.{ .ptr = w, .handler = WaylandWindow.toplevelEvent });
        m = try w.xdg_surface.request(p.xdg_surface.request.get_toplevel);
        m.uint(w.toplevel.id).end();
        if (d.decoration_manager) |mgr| {
            const dec = try conn.newObject(.{ .ptr = w, .handler = WaylandWindow.decorationEvent });
            m = try mgr.request(p.zxdg_decoration_manager_v1.request.get_toplevel_decoration);
            m.uint(dec.id).uint(w.toplevel.id).end();
            w.toplevel_decoration = dec;
            if (options.draw_in_title_bar) {
                m = try dec.request(p.zxdg_toplevel_decoration_v1.request.set_mode);
                m.uint(p.zxdg_toplevel_decoration_v1.mode.client_side).end();
            }
        }
        m = try w.toplevel.request(p.xdg_toplevel.request.set_title);
        m.string(options.title).end();
        if (options.app_id) |app_id| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
            m.string(app_id).end();
        }
        if (options.parent) |parent_win| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_parent);
            m.uint(parent_win.toplevel.id).end();
        }
        if (options.min_size) |ms| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_min_size);
            m.int(@intCast(ms[0])).int(@intCast(ms[1])).end();
        }
        if (options.maximized) {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_maximized);
            m.end();
        }
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        while (w.pending_serial == null) try conn.dispatch();
        _ = try w.applyConfigure();
        w.updateExtensions();
        try conn.flush();
        return w;
    }

    fn displayWmBaseEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.xdg_wm_base.event.ping) return;
        const serial = r.uint() catch return;
        var m = d.wm_base.request(p.xdg_wm_base.request.pong) catch return;
        m.uint(serial).end();
        d.conn.flush() catch {};
    }

    fn displayDmabufEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.zwp_linux_dmabuf_v1.event.format => {
                const fmt = r.uint() catch return;
                if (fmt == p.fourcc.argb8888) d.dmabuf_argb8888 = true;
                if (fmt == p.fourcc.xrgb8888) d.dmabuf_xrgb8888 = true;
            },
            p.zwp_linux_dmabuf_v1.event.modifier => {
                const fmt = r.uint() catch return;
                const mod_hi = r.uint() catch return;
                const mod_lo = r.uint() catch return;
                const mod = (@as(u64, mod_hi) << 32) | mod_lo;
                if (mod == p.modifier.linear or mod == 0x00ffffffffffffff) {
                    if (fmt == p.fourcc.argb8888) d.dmabuf_argb8888 = true;
                    if (fmt == p.fourcc.xrgb8888) d.dmabuf_xrgb8888 = true;
                }
            },
            else => {},
        }
    }

    fn displayPresentationClockEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wp_presentation.event.clock_id) {
            d.presentation_clock_id = r.uint() catch return;
        }
    }

    fn displaySeatEvent(ptr: ?*anyopaque, conn: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.wl_seat.event.capabilities) return;
        const caps = r.uint() catch return;
        if (caps & p.wl_seat.capability.pointer != 0 and d.pointer == null) {
            const pointer = conn.newObject(.{ .ptr = d, .handler = displayPointerEvent }) catch return;
            var m = d.seat.?.request(p.wl_seat.request.get_pointer) catch return;
            m.uint(pointer.id).end();
            d.pointer = pointer;
            if (d.cursor_shape_manager) |manager| {
                const device = conn.newObject(null) catch return;
                m = manager.request(p.wp_cursor_shape_manager_v1.request.get_pointer) catch return;
                m.uint(device.id).uint(pointer.id).end();
                d.cursor_device = device;
            }
            if (d.relative_pointer_manager) |manager| {
                const rel = conn.newObject(.{ .ptr = d, .handler = displayRelativeEvent }) catch return;
                m = manager.request(p.zwp_relative_pointer_manager_v1.request.get_relative_pointer) catch return;
                m.uint(rel.id).uint(pointer.id).end();
                d.relative_pointer = rel;
            }
        }
        if (caps & p.wl_seat.capability.touch != 0 and d.touch == null) {
            const touch = conn.newObject(.{ .ptr = d, .handler = displayTouchEvent }) catch return;
            var m = d.seat.?.request(p.wl_seat.request.get_touch) catch return;
            m.uint(touch.id).end();
            d.touch = touch;
        }
        if (caps & p.wl_seat.capability.keyboard != 0 and d.keyboard == null) {
            const keyboard = conn.newObject(.{ .ptr = d, .handler = displayKeyboardEvent }) catch return;
            var m = d.seat.?.request(p.wl_seat.request.get_keyboard) catch return;
            m.uint(keyboard.id).end();
            d.keyboard = keyboard;
        }
    }

    fn displayRelativeEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ptr.?));
        const w = d.pointer_window orelse return;
        if (opcode != p.zwp_relative_pointer_v1.event.relative_motion) return;
        _ = r.uint() catch return;
        _ = r.uint() catch return;
        const dx: f32 = @floatCast(r.fixed() catch return);
        const dy: f32 = @floatCast(r.fixed() catch return);
        w.pushInput(.{ .relative_motion = .{ dx, dy } });
    }

    fn displayPointerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_pointer.event.enter => {
                const serial = r.uint() catch return;
                const surface_id = r.uint() catch return;
                const x = r.fixed() catch return;
                const y = r.fixed() catch return;
                const next_win = d.windowForSurface(surface_id);
                if (d.pointer_window != null and d.pointer_window != next_win) {
                    d.flushDisplayPointerLeave();
                }
                d.leave_pending = false;
                d.pointer_window = next_win;
                const w = d.pointer_window orelse return;
                d.enter_serial = serial;
                d.cursor_shape = p.wp_cursor_shape_device_v1.shape.default;
                d.buttons_down = 0;
                w.pointer_surface = surface_id;
                w.leave_pending = false;
                w.pointer_pos = w.toWindow(surface_id, .{ @floatCast(x), @floatCast(y) });
                d.updateDisplayCursor();
                w.pushInput(.{ .motion = w.pointer_pos });
            },
            p.wl_pointer.event.motion => {
                _ = r.uint() catch return;
                const x = r.fixed() catch return;
                const y = r.fixed() catch return;
                const w = d.pointer_window orelse return;
                w.pointer_pos = w.toWindow(w.pointer_surface, .{ @floatCast(x), @floatCast(y) });
                d.updateDisplayCursor();
                w.pushInput(.{ .motion = w.pointer_pos });
            },
            p.wl_pointer.event.button => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const button = pointerButtonOf(r.uint() catch return);
                const state = r.uint() catch return;
                const pressed = state == p.wl_pointer.button_state.pressed;
                const w = d.pointer_window orelse return;
                if (pressed) {
                    w.press_serial = serial;
                    w.grab_serial = serial;
                    d.clipboard.serial = serial;
                } else {
                    w.press_serial = 0;
                }
                const on_window = w.pointer_surface == w.surface.id or w.pointer_surface == 0;
                if (pressed and button == .left and on_window) {
                    const edges = w.edgesAt(w.pointer_pos);
                    if (edges != 0) if (d.seat) |seat| {
                        var m = w.toplevel.request(p.xdg_toplevel.request.resize) catch return;
                        m.uint(seat.id).uint(serial).uint(edges).end();
                        w.conn.flush() catch {};
                        return;
                    };
                }
                const bit = @as(u32, 1) << @backingInt(button);
                if (pressed) {
                    if (d.buttons_down == 0 and on_window and !w.isInsideContent(w.pointer_pos)) return;
                    d.buttons_down |= bit;
                } else {
                    d.buttons_down &= ~bit;
                    if (d.buttons_down == 0) d.updateDisplayCursor();
                }
                w.pushInput(.{ .button = .{ .pos = w.pointer_pos, .button = button, .pressed = pressed } });
            },
            p.wl_pointer.event.axis => {
                _ = r.uint() catch return;
                const axis = r.uint() catch return;
                const value: f32 = @floatCast(r.fixed() catch return);
                const w = d.pointer_window orelse return;
                const vertical = axis == p.wl_pointer.axis.vertical_scroll;
                w.pushInput(.{ .scroll = .{ .pos = w.pointer_pos, .dx = if (vertical) 0 else value, .dy = if (vertical) value else 0 } });
            },
            p.wl_pointer.event.leave => {
                _ = r.uint() catch return;
                _ = r.uint() catch return;
                d.leave_pending = true;
            },
            p.wl_pointer.event.frame => d.flushDisplayPointerLeave(),
            else => {},
        }
    }

    fn displayTouchEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_touch.event.down => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const surface_id = r.uint() catch return;
                const id: i32 = @bitCast(r.uint() catch return);
                const x = r.fixed() catch return;
                const y = r.fixed() catch return;
                const w = d.windowForSurface(surface_id);
                for (&d.touch_windows) |*slot| if (slot.* == null) {
                    slot.* = .{ .id = id, .window = w };
                    break;
                };
                const win = w orelse return;
                win.touch_surface = surface_id;
                const pos = win.toWindow(surface_id, .{ @floatCast(x), @floatCast(y) });
                win.press_serial = serial;
                win.grab_serial = serial;
                d.clipboard.serial = serial;
                const on_window = surface_id == win.surface.id;
                const edges = if (on_window) win.edgesAt(pos) else 0;
                if (edges != 0) if (d.seat) |seat| {
                    var m = win.toplevel.request(p.xdg_toplevel.request.resize) catch return;
                    m.uint(seat.id).uint(serial).uint(edges).end();
                    win.conn.flush() catch {};
                    return;
                };
                if (on_window and !win.isInsideContent(pos)) return;
                win.pushInput(.{ .touch_down = .{ .id = id, .pos = pos } });
            },
            p.wl_touch.event.motion => {
                _ = r.uint() catch return;
                const id: i32 = @bitCast(r.uint() catch return);
                const x = r.fixed() catch return;
                const y = r.fixed() catch return;
                const w = d.touchWindowFor(id) orelse return;
                const pos = w.toWindow(w.touch_surface, .{ @floatCast(x), @floatCast(y) });
                w.pushInput(.{ .touch_motion = .{ .id = id, .pos = pos } });
            },
            p.wl_touch.event.up => {
                _ = r.uint() catch return;
                _ = r.uint() catch return;
                const id: i32 = @bitCast(r.uint() catch return);
                const w = d.removeTouchWindow(id) orelse return;
                w.press_serial = 0;
                w.pushInput(.{ .touch_up = id });
            },
            p.wl_touch.event.cancel => {
                for (&d.touch_windows) |*slot| {
                    if (slot.*) |tw| if (tw.window) |win| {
                        win.press_serial = 0;
                        win.pushInput(.touch_cancel);
                    };
                    slot.* = null;
                }
            },
            else => {},
        }
    }

    fn displayKeyboardEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_keyboard.event.keymap => {
                const fd = r.fd() catch return;
                defer _ = linux.close(fd);
                _ = r.uint() catch return;
                const size = r.uint() catch return;
                if (keymapFrom(d.gpa, fd, size)) |km| {
                    if (d.keymap) |*old| old.deinit();
                    d.keymap = km;
                    d.xkb_state = .{};
                    d.compose_state.reset();
                }
            },
            p.wl_keyboard.event.modifiers => {
                _ = r.uint() catch return;
                const depressed = r.uint() catch return;
                const latched = r.uint() catch return;
                const locked = r.uint() catch return;
                const group = r.uint() catch return;
                d.xkb_state = .{ .depressed = depressed, .latched = latched, .locked = locked, .group = group };
            },
            p.wl_keyboard.event.enter => {
                _ = r.uint() catch return;
                const surface_id = r.uint() catch return;
                const next_win = d.windowForSurface(surface_id);
                if (d.keyboard_window != null and d.keyboard_window != next_win) {
                    const old_w = d.keyboard_window.?;
                    d.display_repeat = null;
                    d.compose_state.reset();
                    var it = old_w.keys_down.iterator(.{});
                    while (it.next()) |code| {
                        old_w.pushInput(.{ .key = .{ .key = window_mod.evdev.keyOf(@intCast(code)), .pressed = false } });
                    }
                    old_w.keys_down = .empty;
                }
                d.keyboard_window = next_win;
            },
            p.wl_keyboard.event.key => {
                const w = d.keyboard_window orelse return;
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const code = r.uint() catch return;
                const key_state = r.uint() catch return;
                const pressed = key_state == p.wl_keyboard.key_state.pressed;
                if (pressed) {
                    d.clipboard.serial = serial;
                    w.grab_serial = serial;
                }
                if (code < 256) {
                    d.keys_down.setValue(code, pressed);
                    w.keys_down.setValue(code, pressed);
                }
                if (pressed) {
                    if (!WaylandWindow.isModifierKey(code) and d.repeat_rate > 0) {
                        d.display_repeat = .{
                            .code = code,
                            .next_ns = window_mod.nowNs(d.io) + @as(u64, d.repeat_delay_ms) * std.time.ns_per_ms,
                        };
                    }
                } else if (d.display_repeat) |rep| {
                    if (rep.code == code) d.display_repeat = null;
                }
                w.pushKeyViaDisplay(code, pressed, false, d);
            },
            p.wl_keyboard.event.leave => {
                _ = r.uint() catch return;
                _ = r.uint() catch return;
                const w = d.keyboard_window orelse return;
                d.keyboard_window = null;
                d.display_repeat = null;
                d.compose_state.reset();
                var it = w.keys_down.iterator(.{});
                while (it.next()) |code| {
                    w.pushInput(.{ .key = .{ .key = window_mod.evdev.keyOf(@intCast(code)), .pressed = false } });
                }
                w.keys_down = .empty;
                d.keys_down = .empty;
            },
            p.wl_keyboard.event.repeat_info => {
                const rate = r.int() catch return;
                const delay = r.int() catch return;
                d.repeat_rate = @intCast(@max(rate, 0));
                d.repeat_delay_ms = @intCast(@max(delay, 0));
                if (d.repeat_rate == 0) d.display_repeat = null;
            },
            else => {},
        }
    }

    fn displayTextInputEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const d: *WaylandDisplay = @ptrCast(@alignCast(ptr.?));
        const w = d.keyboard_window orelse return;
        switch (opcode) {
            p.zwp_text_input_v3.event.enter => {
                if (!w.ownsSurface(r.uint() catch return)) return;
                w.text_input_entered = true;
                if (w.text_input_enabled) if (d.text_input) |ti| {
                    w.sendTextInputState(ti, true);
                };
            },
            p.zwp_text_input_v3.event.leave => {
                if (!w.ownsSurface(r.uint() catch return)) return;
                w.text_input_entered = false;
                w.text_input_pending_preedit = null;
                w.text_input_pending_commit = null;
                w.text_input_pending_delete = null;
            },
            p.zwp_text_input_v3.event.preedit_string => {
                const text = (r.string() catch return) orelse "";
                const begin = r.int() catch return;
                const end = r.int() catch return;
                var pre: @TypeOf(w.text_input_pending_preedit.?) = .{ .cursor_begin = begin, .cursor_end = end };
                const n: u8 = @intCast(@min(text.len, pre.buf.len));
                @memcpy(pre.buf[0..n], text[0..n]);
                pre.len = n;
                w.text_input_pending_preedit = pre;
            },
            p.zwp_text_input_v3.event.commit_string => {
                const text = (r.string() catch return) orelse "";
                var com: @TypeOf(w.text_input_pending_commit.?) = .{};
                const n: u8 = @intCast(@min(text.len, com.buf.len));
                @memcpy(com.buf[0..n], text[0..n]);
                com.len = n;
                w.text_input_pending_commit = com;
            },
            p.zwp_text_input_v3.event.delete_surrounding_text => {
                const before = r.uint() catch return;
                const after = r.uint() catch return;
                w.text_input_pending_delete = .{ .before_length = before, .after_length = after };
            },
            p.zwp_text_input_v3.event.done => {
                _ = r.uint() catch return;
                if (w.text_input_pending_delete) |del| {
                    w.text_input_pending_delete = null;
                    w.pushInput(.{ .text_delete_surrounding = .{ .before_length = del.before_length, .after_length = del.after_length } });
                }
                if (w.text_input_pending_commit) |com| {
                    w.text_input_pending_commit = null;
                    if (com.len > 0) {
                        var ev: window_mod.InputEvent = .{ .text_commit = .{ .len = com.len } };
                        @memcpy(ev.text_commit.buf[0..com.len], com.buf[0..com.len]);
                        w.pushInput(ev);
                    }
                }
                if (w.text_input_pending_preedit) |pre| {
                    w.text_input_pending_preedit = null;
                    w.text_input_has_preedit = pre.len > 0;
                    var ev: window_mod.InputEvent = .{ .text_preedit = .{ .len = pre.len, .cursor_begin = pre.cursor_begin, .cursor_end = pre.cursor_end } };
                    @memcpy(ev.text_preedit.buf[0..pre.len], pre.buf[0..pre.len]);
                    w.pushInput(ev);
                } else if (w.text_input_has_preedit) {
                    w.text_input_has_preedit = false;
                    w.pushInput(.{ .text_preedit = .{} });
                }
            },
            else => {},
        }
    }
};

/// The pointer button a Linux button code (linux/input-event-codes.h) is.
fn pointerButtonOf(code: u32) window_mod.PointerButton {
    return switch (code) {
        p.input.btn_left => .left,
        p.input.btn_right => .right,
        p.input.btn_middle => .middle,
        p.input.btn_side, p.input.btn_back => .back,
        p.input.btn_extra, p.input.btn_forward => .forward,
        else => .other,
    };
}

pub const WaylandWindow = struct {
    pub const platform: window_mod.WindowPlatform = .wayland;

    pub fn usingDmabuf(w: *const WaylandWindow) bool {
        const dev_present = if (w.display) |d| d.dmabuf_dev != null else w.dmabuf_dev != null;
        return w.dmabuf != null and dev_present and (w.dmabuf_argb8888 or w.dmabuf_xrgb8888);
    }

    pub fn usingDrmSyncobj(w: *const WaylandWindow) bool {
        if (w.syncobj_surface != null) return true;
        if (!w.usingDmabuf()) return false;
        if (w.drm_syncobj_manager == null) return false;
        const dev = if (w.display) |d| d.dmabuf_dev else w.dmabuf_dev;
        return if (dev) |v| v.supports_syncobj else false;
    }

    /// Stops using explicit synchronization (`wp_linux_drm_syncobj_v1`) for
    /// the window, for good. It is all or nothing: while the surface has a
    /// syncobj surface, every buffer committed must have timeline points,
    /// and must be a dmabuf. Points already committed are still signalled.
    fn stopSyncobj(w: *WaylandWindow) void {
        if (w.syncobj_surface) |ss| {
            if (ss.request(p.wp_linux_drm_syncobj_surface_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(ss.id);
            w.syncobj_surface = null;
        }
        if (w.drm_syncobj_manager) |mgr| {
            if (mgr.request(p.wp_linux_drm_syncobj_manager_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(mgr.id);
            w.drm_syncobj_manager = null;
        }
        w.updateExtensions();
    }

    pub fn bufferTransport(w: *const WaylandWindow) window_mod.WindowBufferTransport {
        return if (w.usingDmabuf()) .linux_dmabuf else .memory;
    }

    pub fn bufferSync(w: *const WaylandWindow) window_mod.WindowBufferSync {
        if (w.usingDrmSyncobj()) return .explicit;
        return if (w.usingDmabuf()) .implicit else .none;
    }

    pub fn frameSync(w: *const WaylandWindow) window_mod.WindowFrameSync {
        return .{
            .vsync = w.vsync,
            .frame_callback = w.vsync,
            .presentation_time = w.presentation != null,
            .fifo = w.fifo != null,
            .timed_presentation = w.commit_timer != null,
        };
    }

    pub fn refreshHz(w: *const WaylandWindow) f32 {
        if (w.refresh_ns == 0) return 0.0;
        return @as(f32, @floatFromInt(std.time.ns_per_s)) / @as(f32, @floatFromInt(w.refresh_ns));
    }

    /// The extensions the compositor offers that kete can use.
    pub fn waylandExtensions(w: *const WaylandWindow) []const []const u8 {
        return w.extensions_buf[0..w.extensions_len];
    }

    pub fn decorations(w: *const WaylandWindow) window_mod.WindowDecorations {
        return if (w.system_decorations) .system else .toolkit;
    }

    pub fn getTitle(w: *const WaylandWindow) []const u8 {
        return w.title_buf[0..w.title_len];
    }

    /// Sets the title the compositor shows (`getTitle` keeps the start of it).
    pub fn setTitle(w: *WaylandWindow, title: []const u8) void {
        const n = @min(title.len, w.title_buf.len);
        @memcpy(w.title_buf[0..n], title[0..n]);
        w.title_len = n;
        var m = w.toplevel.request(p.xdg_toplevel.request.set_title) catch return;
        m.string(title).end();
        w.conn.flush() catch {};
    }

    gpa: std.mem.Allocator,
    /// What it does its I/O, and waits, through.
    io: std.Io,
    conn: *client.Display,
    globals: client.Globals = .{},
    compositor: client.Proxy = .{},
    wm_base: client.Proxy = .{},
    shm: client.Proxy = .{},
    dmabuf: ?client.Proxy = null,
    dmabuf_dev: ?DmaBufDevice = null,
    dmabuf_argb8888: bool = false,
    dmabuf_xrgb8888: bool = false,
    drm_syncobj_manager: ?client.Proxy = null,
    syncobj_surface: ?client.Proxy = null,
    surface: client.Proxy = .{},
    xdg_surface: client.Proxy = .{},
    toplevel: client.Proxy = .{},
    decoration_manager: ?client.Proxy = null,
    toplevel_decoration: ?client.Proxy = null,

    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    width: u32 = default_size[0],
    height: u32 = default_size[1],
    min_size: [2]u32 = .{ 0, 0 },
    scale: u32 = 1,
    system_decorations: bool = false,
    decoration_changed: bool = false,
    last_geometry: ?[3]u32 = null,
    next_size: [2]i32 = .{ 0, 0 },
    pending_serial: ?u32 = null,
    /// The window system asked for it to be closed (taken by the app).
    close_requested: bool = false,
    suspended: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    tiled: bool = false,
    vsync: bool = true,
    /// What the compositor can do to the window (`xdg_toplevel.wm_capabilities`;
    /// everything, if it does not say).
    can_maximize: bool = true,
    can_minimize: bool = true,
    can_fullscreen: bool = true,
    press_serial: u32 = 0,
    buttons_down: u32 = 0,
    enter_serial: u32 = 0,

    cursor_shape_manager: ?client.Proxy = null,
    cursor_device: ?client.Proxy = null,
    cursor_shape: ?u32 = null,
    app_cursor: PointerCursor = .default,

    buffers: [max_buffers]?Buffer = @splat(null),
    back: ?usize = null,
    frame_corners_applied: bool = false,
    frame_pending: bool = false,
    frames: u64 = 0,

    presentation: ?client.Proxy = null,
    presentation_clock_id: u32 = 1,
    presented_ns: u64 = 0,
    refresh_ns: u64 = 0,
    presentation_seq: u64 = 0,
    presentation_flags: u32 = 0,
    presented_frames: u64 = 0,
    discarded_frames: u64 = 0,

    fifo_manager: ?client.Proxy = null,
    fifo: ?client.Proxy = null,
    fifo_barrier_pending: bool = false,
    /// When the next frame shown is drawn for (`setPresentationTime`).
    target_ns: ?u64 = null,

    /// Identifies dmabuf buffers (`gfx.DmabufTarget.id`).
    next_buffer_id: u64 = 1,

    /// Menus and tooltips (`openPopup`).
    popups: [max_popups]?PopupSurface = @splat(null),
    next_popup_id: u32 = 1,
    /// The serial of the last button, key or touch press: a menu's grab
    /// needs one.
    grab_serial: u32 = 0,
    /// The surface the pointer (or the last touch) is on.
    pointer_surface: u32 = 0,
    touch_surface: u32 = 0,
    /// The pointer left a surface; unless it enters another of the
    /// window's in the same frame, it has left the window.
    leave_pending: bool = false,
    /// The display it is on, with others, if it was opened on one (see
    /// `WaylandDisplay`): then each window's seat objects hear of what
    /// happens on all the app's surfaces, and each heeds only its own.
    /// The pointer is on another window's surface; whether the keyboard's
    /// focus is on one of this window's (null until it is said); and the
    /// touches on other windows' surfaces.
    display: ?*WaylandDisplay = null,
    pointer_away: bool = false,
    keyboard_focused: ?bool = null,
    away_touches: [8]?i32 = @splat(null),
    commit_timing_manager: ?client.Proxy = null,
    commit_timer: ?client.Proxy = null,
    extensions_buf: [16][]const u8 = undefined,
    extensions_len: usize = 0,

    seat: ?client.Proxy = null,
    touch: ?client.Proxy = null,
    text_input_manager: ?client.Proxy = null,
    text_input: ?client.Proxy = null,
    text_input_entered: bool = false,
    text_input_enabled: bool = false,
    text_input_has_preedit: bool = false,
    text_input_serial: u32 = 0,
    text_input_state: TextInputState = .{},
    text_input_surrounding_buf: [256]u8 = undefined,
    text_input_pending_preedit: ?struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
        cursor_begin: i32 = 0,
        cursor_end: i32 = 0,
    } = null,
    text_input_pending_commit: ?struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
    } = null,
    text_input_pending_delete: ?struct {
        before_length: u32,
        after_length: u32,
    } = null,

    pointer_constraints: ?client.Proxy = null,
    relative_pointer_manager: ?client.Proxy = null,
    relative_pointer: ?client.Proxy = null,
    locked_pointer: ?client.Proxy = null,
    pointer_locked: bool = false,

    clipboard: Clipboard,
    /// What the keys type (from `wl_keyboard.keymap`), and the modifiers
    /// and layout in effect (from `wl_keyboard.modifiers`).
    keymap: ?xkb.Keymap = null,
    xkb_state: xkb.State = .{},
    /// Dead keys' and the Compose key's sequences (loaded on the first
    /// press of one), where to find them, and how far into one typing is.
    compose_table: ?compose.Table = null,
    compose_tried: bool = false,
    compose_env: compose.Env = .{},
    compose_state: compose.State = .{},
    /// What `wait` waits on as well as the compositor (see `watch`).
    watched: [8]?window_mod.Source = @splat(null),
    /// A read of the connection, through `io`, that failed.
    read_error: ?wire.Error = null,
    pointer: ?client.Proxy = null,
    keyboard: ?client.Proxy = null,

    repeat_rate: u32 = 25,
    repeat_delay_ms: u32 = 600,
    repeat: ?struct { code: u32, next_ns: u64 } = null,
    keys_down: std.bit_set.Static(256) = .empty,
    pointer_pos: [2]f32 = .{ 0, 0 },
    input: [64]InputEvent = undefined,
    input_len: usize = 0,

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = default_size,
        min_size: ?[2]u32 = null,
        maximized: bool = false,
        /// The app draws in the title bar: the compositor is asked to leave
        /// the decorations to the toolkit.
        draw_in_title_bar: bool = false,
        /// A window it belongs to (a dialog's, a tool window's), on the
        /// same display.
        parent: ?*WaylandWindow = null,
    };

    /// Connects to the compositor named in `environ` (`WAYLAND_DISPLAY`
    /// under `XDG_RUNTIME_DIR`) and opens a window, which does its I/O
    /// (and waits) through `io`.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !*WaylandWindow {
        var path_buf: [256]u8 = undefined;
        const path = try client.environSocketPath(&path_buf, environ);
        const w = try openPath(gpa, io, path, options);
        w.compose_env = .from(environ);
        return w;
    }

    /// Connects to the compositor listening on `path` and opens a window.
    pub fn openPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8, options: Options) !*WaylandWindow {
        const conn = try client.Display.connect(gpa, io, path);
        errdefer conn.disconnect();
        return openOn(gpa, conn, options);
    }

    /// Opens a window on an existing connection, which the window then owns
    /// (and whose `std.Io` it uses). Waits for the first configure.
    pub fn openOn(gpa: std.mem.Allocator, conn: *client.Display, options: Options) !*WaylandWindow {
        const w = try gpa.create(WaylandWindow);
        errdefer gpa.destroy(w);
        const min_size = options.min_size orelse [2]u32{ 0, 0 };
        w.* = .{
            .gpa = gpa,
            .io = conn.conn.io,
            .conn = conn,
            .clipboard = .{ .gpa = gpa },
            .width = if (options.maximized) options.size[0] else @max(options.size[0], min_size[0]),
            .height = if (options.maximized) options.size[1] else @max(options.size[1], min_size[1]),
            .min_size = min_size,
            .maximized = options.maximized,
        };
        const tlen = @min(options.title.len, w.title_buf.len);
        @memcpy(w.title_buf[0..tlen], options.title[0..tlen]);
        w.title_len = tlen;
        w.clipboard.drag_callbacks = .{
            .ctx = w,
            .enter = onDragEnter,
            .motion = onDragMotion,
            .leave = onDragLeave,
            .drop = onDragDrop,
        };

        const registry = try w.globals.fetch(conn);
        w.compositor = (try w.globals.bind(registry, p.wl_compositor.name, 6, null)) orelse return error.NoCompositor;
        w.wm_base = (try w.globals.bind(registry, p.xdg_wm_base.name, 6, .{ .ptr = w, .handler = wmBaseEvent })) orelse return error.NoXdgShell;
        if (w.globals.find(p.zwp_linux_dmabuf_v1.name)) |gl| {
            if (gl.version >= 2) {
                if (DmaBufDevice.open()) |dev_val| {
                    var dev = dev_val;
                    errdefer dev.close();
                    if (try w.globals.bind(registry, p.zwp_linux_dmabuf_v1.name, 3, .{ .ptr = w, .handler = dmabufEvent })) |dmabuf_proxy| {
                        w.dmabuf = dmabuf_proxy;
                        w.dmabuf_dev = dev;
                    } else {
                        dev.close();
                    }
                }
            }
        }
        errdefer if (w.dmabuf_dev) |*dev| dev.close();
        if (try w.globals.bind(registry, p.wl_shm.name, 1, null)) |shm_proxy| {
            w.shm = shm_proxy;
        } else if (w.dmabuf == null or w.dmabuf_dev == null) {
            return error.NoShm;
        }

        w.decoration_manager = try w.globals.bind(registry, p.zxdg_decoration_manager_v1.name, 1, null);
        w.cursor_shape_manager = try w.globals.bind(registry, p.wp_cursor_shape_manager_v1.name, 1, null);
        w.presentation = try w.globals.bind(registry, p.wp_presentation.name, p.wp_presentation.version, .{ .ptr = w, .handler = presentationEvent });
        w.fifo_manager = try w.globals.bind(registry, p.wp_fifo_manager_v1.name, 1, null);
        w.commit_timing_manager = try w.globals.bind(registry, p.wp_commit_timing_manager_v1.name, 1, null);
        if (w.dmabuf != null and w.dmabuf_dev != null and w.dmabuf_dev.?.supports_syncobj) {
            w.drm_syncobj_manager = try w.globals.bind(registry, p.wp_linux_drm_syncobj_manager_v1.name, 1, null);
        }
        w.pointer_constraints = try w.globals.bind(registry, p.zwp_pointer_constraints_v1.name, 1, null);
        w.relative_pointer_manager = try w.globals.bind(registry, p.zwp_relative_pointer_manager_v1.name, 1, null);
        w.seat = try w.globals.bind(registry, p.wl_seat.name, 5, .{ .ptr = w, .handler = seatEvent });

        try w.clipboard.attach(conn, try w.globals.bind(registry, p.wl_data_device_manager.name, 3, null), w.seat);

        w.text_input_manager = try w.globals.bind(registry, p.zwp_text_input_manager_v3.name, 1, null);
        if (w.text_input_manager) |mgr| if (w.seat) |seat| {
            const ti = try conn.newObject(.{ .ptr = w, .handler = textInputEvent });
            var m = try mgr.request(p.zwp_text_input_manager_v3.request.get_text_input);
            m.uint(ti.id).uint(seat.id).end();
            w.text_input = ti;
        };

        w.surface = try conn.newObject(.{ .ptr = w, .handler = surfaceEvent });
        var m = try w.compositor.request(p.wl_compositor.request.create_surface);
        m.uint(w.surface.id).end();
        if (w.fifo_manager) |mgr| {
            const fifo = try conn.newObject(null);
            m = try mgr.request(p.wp_fifo_manager_v1.request.get_fifo);
            m.uint(fifo.id).uint(w.surface.id).end();
            w.fifo = fifo;
        }
        if (w.commit_timing_manager) |mgr| {
            const timer = try conn.newObject(null);
            m = try mgr.request(p.wp_commit_timing_manager_v1.request.get_timer);
            m.uint(timer.id).uint(w.surface.id).end();
            w.commit_timer = timer;
        }
        w.xdg_surface = try conn.newObject(.{ .ptr = w, .handler = xdgSurfaceEvent });
        m = try w.wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
        m.uint(w.xdg_surface.id).uint(w.surface.id).end();
        w.toplevel = try conn.newObject(.{ .ptr = w, .handler = toplevelEvent });
        m = try w.xdg_surface.request(p.xdg_surface.request.get_toplevel);
        m.uint(w.toplevel.id).end();
        if (w.decoration_manager) |mgr| {
            const dec = try conn.newObject(.{ .ptr = w, .handler = decorationEvent });
            m = try mgr.request(p.zxdg_decoration_manager_v1.request.get_toplevel_decoration);
            m.uint(dec.id).uint(w.toplevel.id).end();
            w.toplevel_decoration = dec;
            if (options.draw_in_title_bar) {
                m = try dec.request(p.zxdg_toplevel_decoration_v1.request.set_mode);
                m.uint(p.zxdg_toplevel_decoration_v1.mode.client_side).end();
            }
        }
        m = try w.toplevel.request(p.xdg_toplevel.request.set_title);
        m.string(options.title).end();
        if (options.app_id) |app_id| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
            m.string(app_id).end();
        }
        if (options.parent) |parent| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_parent);
            m.uint(parent.toplevel.id).end();
        }
        if (options.min_size) |ms| {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_min_size);
            m.int(@intCast(ms[0])).int(@intCast(ms[1])).end();
        }
        if (options.maximized) {
            m = try w.toplevel.request(p.xdg_toplevel.request.set_maximized);
            m.end();
        }
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        while (w.pending_serial == null) try conn.dispatch();
        _ = try w.applyConfigure();
        w.updateExtensions();
        return w;
    }

    /// The extensions kete uses when the compositor has them.
    const known_extensions = [_][]const u8{
        p.xdg_wm_base.name,
        p.zwp_linux_dmabuf_v1.name,
        p.wp_linux_drm_syncobj_manager_v1.name,
        p.wp_presentation.name,
        p.wp_fifo_manager_v1.name,
        p.wp_commit_timing_manager_v1.name,
        p.zxdg_decoration_manager_v1.name,
        p.wp_cursor_shape_manager_v1.name,
        p.zwp_text_input_manager_v3.name,
        p.zwp_pointer_constraints_v1.name,
        p.zwp_relative_pointer_manager_v1.name,
    };

    /// Notes which of `known_extensions` the compositor announced.
    pub fn updateExtensions(w: *WaylandWindow) void {
        const gl = if (w.display) |d| &d.globals else &w.globals;
        var n: usize = 0;
        for (known_extensions) |name| {
            if (gl.find(name) == null) continue;
            w.extensions_buf[n] = name;
            n += 1;
        }
        w.extensions_len = n;
    }

    pub fn close(w: *WaylandWindow) void {
        var i: usize = w.popups.len;
        while (i > 0) {
            i -= 1;
            if (w.popups[i]) |*pop| w.destroyPopup(pop);
            w.popups[i] = null;
        }
        w.clipboard.deinit();
        if (w.keymap) |*km| km.deinit();
        w.keymap = null;
        if (w.compose_table) |*t| t.deinit();
        w.compose_table = null;
        for (&w.buffers) |*slot| if (slot.*) |*b| w.freeBuffer(b, slot);
        if (w.syncobj_surface) |ss| {
            if (ss.request(p.wp_linux_drm_syncobj_surface_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(ss.id);
        }
        if (w.fifo) |fifo| {
            if (fifo.request(p.wp_fifo_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(fifo.id);
        }
        if (w.commit_timer) |timer| {
            if (timer.request(p.wp_commit_timer_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(timer.id);
        }
        if (w.dmabuf_dev) |*dev| dev.close();
        if (w.display) |d| {
            // The connection stays (the display's), with the other windows
            // on it: this one's surface, decoration, and toplevel go,
            // while shared globals stay with the display.
            for ([_]?client.Proxy{
                w.locked_pointer,
                w.toplevel_decoration,
                w.toplevel,
                w.xdg_surface,
                w.surface,
            }, [_]u16{
                p.zwp_locked_pointer_v1.request.destroy,
                p.zxdg_toplevel_decoration_v1.request.destroy,
                p.xdg_toplevel.request.destroy,
                p.xdg_surface.request.destroy,
                p.wl_surface.request.destroy,
            }) |obj, opcode| if (obj) |o| if (o.id != 0) {
                if (o.request(opcode)) |m0| {
                    var m = m0;
                    m.end();
                } else |_| {}
            };
            w.conn.forgetAll(w);
            w.conn.flush() catch {};
            d.forget(w);
        } else {
            w.conn.flush() catch {};
            w.conn.disconnect();
        }
        w.gpa.destroy(w);
    }

    pub fn interface(w: *WaylandWindow) window_mod.Window {
        return window_mod.Window.of(w);
    }

    pub fn setAppId(w: *WaylandWindow, app_id: []const u8) !void {
        var m = try w.toplevel.request(p.xdg_toplevel.request.set_app_id);
        m.string(app_id).end();
    }

    /// Now, on the clock frames and input are timed on.
    fn now(w: *const WaylandWindow) u64 {
        return window_mod.nowNs(w.io);
    }

    pub fn poll(w: *WaylandWindow) !void {
        if (w.display) |d| return d.poll();
        _ = try w.conn.dispatchPending();
        w.clipboard.service();
        w.serviceRepeat(w.now());
    }

    pub fn setFullscreen(w: *WaylandWindow, on: bool) void {
        var m = w.toplevel.request(if (on) p.xdg_toplevel.request.set_fullscreen else p.xdg_toplevel.request.unset_fullscreen) catch return;
        if (on) _ = m.uint(0);
        m.end();
        w.conn.flush() catch {};
    }

    pub fn lockPointer(w: *WaylandWindow) bool {
        if (w.locked_pointer != null) return true;
        const constraints = if (w.display) |d| (d.pointer_constraints orelse return false) else (w.pointer_constraints orelse return false);
        const pointer = if (w.display) |d| (d.pointer orelse return false) else (w.pointer orelse return false);
        const has_rel = if (w.display) |d| (d.relative_pointer != null) else (w.relative_pointer != null);
        if (!has_rel) return false;
        const lock = w.conn.newObject(.{ .ptr = w, .handler = lockEvent }) catch return false;
        var m = constraints.request(p.zwp_pointer_constraints_v1.request.lock_pointer) catch return false;
        m.uint(lock.id).uint(w.surface.id).uint(pointer.id).uint(0).uint(p.zwp_pointer_constraints_v1.lifetime.persistent).end();
        w.conn.flush() catch {};
        w.locked_pointer = lock;
        return true;
    }

    pub fn unlockPointer(w: *WaylandWindow) void {
        const lock = w.locked_pointer orelse return;
        if (lock.request(p.zwp_locked_pointer_v1.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        w.conn.forget(lock.id);
        w.locked_pointer = null;
        if (w.pointer_locked) {
            w.pointer_locked = false;
            w.pushInput(.{ .pointer_locked = false });
        }
        w.conn.flush() catch {};
    }

    fn lockEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        const locked = opcode == p.zwp_locked_pointer_v1.event.locked;
        if (locked == w.pointer_locked) return;
        w.pointer_locked = locked;
        w.pushInput(.{ .pointer_locked = locked });
    }

    fn relativeEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.zwp_relative_pointer_v1.event.relative_motion) return;
        _ = r.uint() catch return;
        _ = r.uint() catch return;
        const dx: f32 = @floatCast(r.fixed() catch return);
        const dy: f32 = @floatCast(r.fixed() catch return);
        w.pushInput(.{ .relative_motion = .{ dx, dy } });
    }

    fn findPopup(w: *WaylandWindow, id: u32) ?*PopupSurface {
        for (&w.popups) |*slot| if (slot.*) |*pop| if (pop.id == id) return pop;
        return null;
    }

    /// Opens an `xdg_popup` placed as `placement` says, or returns null if
    /// it cannot. A menu takes an explicit grab (with the last press's
    /// serial); a tooltip lets the pointer through.
    pub fn openPopup(w: *WaylandWindow, placement: window_mod.PopupPlacement) ?u32 {
        const slot = for (&w.popups) |*slot| {
            if (slot.* == null) break slot;
        } else return null;
        const pop = w.createPopup(placement) catch return null;
        slot.* = pop;
        return pop.id;
    }

    fn createPopup(w: *WaylandWindow, pl: window_mod.PopupPlacement) !PopupSurface {
        const pos_p = p.xdg_positioner;
        const positioner = try w.conn.newObject(null);
        var m = try w.wm_base.request(p.xdg_wm_base.request.create_positioner);
        m.uint(positioner.id).end();
        // As kete means its placements everywhere (the compositor places
        // it by these here; `Positioner.place` does elsewhere).
        const pos = pl.positioner(.{ w.width, w.height });
        m = try positioner.request(pos_p.request.set_size);
        m.int(pos.size[0]).int(pos.size[1]).end();
        m = try positioner.request(pos_p.request.set_anchor_rect);
        m.int(pos.anchor_rect[0]).int(pos.anchor_rect[1]).int(pos.anchor_rect[2]).int(pos.anchor_rect[3]).end();
        m = try positioner.request(pos_p.request.set_anchor);
        m.uint(@backingInt(pos.anchor)).end();
        m = try positioner.request(pos_p.request.set_gravity);
        m.uint(@backingInt(pos.gravity)).end();
        m = try positioner.request(pos_p.request.set_constraint_adjustment);
        m.uint(@bitCast(pos.adjust)).end();
        m = try positioner.request(pos_p.request.set_offset);
        m.int(pos.offset[0]).int(pos.offset[1]).end();

        const surface = try w.conn.newObject(null);
        m = try w.compositor.request(p.wl_compositor.request.create_surface);
        m.uint(surface.id).end();
        const scale = @max(w.scale, 1);
        m = try surface.request(p.wl_surface.request.set_buffer_scale);
        m.int(@intCast(scale)).end();
        const xdg_surface = try w.conn.newObject(.{ .ptr = w, .handler = popupXdgSurfaceEvent });
        m = try w.wm_base.request(p.xdg_wm_base.request.get_xdg_surface);
        m.uint(xdg_surface.id).uint(surface.id).end();
        const popup = try w.conn.newObject(.{ .ptr = w, .handler = popupEvent });
        m = try xdg_surface.request(p.xdg_surface.request.get_popup);
        m.uint(popup.id).uint(w.xdg_surface.id).uint(positioner.id).end();
        m = try positioner.request(pos_p.request.destroy);
        m.end();
        w.conn.forget(positioner.id);

        switch (pl.kind) {
            .menu => if (if (w.display) |d| d.seat else w.seat) |seat| if (w.grab_serial != 0) {
                m = try popup.request(p.xdg_popup.request.grab);
                m.uint(seat.id).uint(w.grab_serial).end();
            },
            .tooltip => {
                // An empty input region: the pointer goes through it.
                const region = try w.conn.newObject(null);
                m = try w.compositor.request(p.wl_compositor.request.create_region);
                m.uint(region.id).end();
                m = try surface.request(p.wl_surface.request.set_input_region);
                m.uint(region.id).end();
                m = try region.request(p.wl_region.request.destroy);
                m.end();
                w.conn.forget(region.id);
            },
        }
        // The first commit, without a buffer, asks for a configure.
        m = try surface.request(p.wl_surface.request.commit);
        m.end();
        try w.conn.flush();
        const id = w.next_popup_id;
        w.next_popup_id +%= 1;
        return .{ .id = id, .placement = pl, .surface = surface, .xdg_surface = xdg_surface, .popup = popup, .scale = scale };
    }

    pub fn closePopup(w: *WaylandWindow, id: u32) void {
        for (&w.popups) |*slot| if (slot.*) |*pop| if (pop.id == id) {
            w.destroyPopup(pop);
            slot.* = null;
        };
        w.conn.flush() catch {};
    }

    fn destroyPopup(w: *WaylandWindow, pop: *PopupSurface) void {
        for ([_]struct { proxy: client.Proxy, op: u16 }{
            .{ .proxy = pop.popup, .op = p.xdg_popup.request.destroy },
            .{ .proxy = pop.xdg_surface, .op = p.xdg_surface.request.destroy },
            .{ .proxy = pop.surface, .op = p.wl_surface.request.destroy },
        }) |o| {
            if (o.proxy.request(o.op)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(o.proxy.id);
        }
        for (&pop.buffers) |*b| if (b.*) |*buf| w.freeBuffer(buf, b);
        if (w.pointer_surface == pop.surface.id) w.pointer_surface = 0;
        if (w.touch_surface == pop.surface.id) w.touch_surface = 0;
    }

    pub fn popupPosition(w: *WaylandWindow, id: u32) ?[2]i32 {
        const pop = w.findPopup(id) orelse return null;
        return pop.position;
    }

    /// A free buffer the popup's size, once it is configured; null until
    /// then, or while both its buffers are being shown.
    pub fn beginSoftwarePopupFrame(w: *WaylandWindow, id: u32) !?gfx.software.Image {
        const pop = w.findPopup(id) orelse return null;
        if (!pop.configured) return null;
        const bw = @max(pop.placement.size[0], 1) * pop.scale;
        const bh = @max(pop.placement.size[1], 1) * pop.scale;
        const i = for (&pop.buffers, 0..) |*slot, i| {
            if (slot.*) |*b| {
                if (b.busy) continue;
                if (b.width == bw and b.height == bh) break i;
                w.freeBuffer(b, slot);
            }
            slot.* = try w.allocShmBuffer(slot, bw, bh, bw, bh, 0, pop.scale, true);
            break i;
        } else return null;
        pop.back = i;
        return pop.buffers[i].?.image();
    }

    pub fn showPopup(w: *WaylandWindow, id: u32) !void {
        const pop = w.findPopup(id) orelse return;
        const i = pop.back orelse return error.NoFrameBegun;
        pop.back = null;
        const b = &pop.buffers[i].?;
        var m = try pop.surface.request(p.wl_surface.request.attach);
        m.uint(b.proxy.id).int(0).int(0).end();
        m = try pop.surface.request(p.wl_surface.request.damage_buffer);
        m.int(0).int(0).int(@intCast(b.width)).int(@intCast(b.height)).end();
        m = try pop.surface.request(p.wl_surface.request.commit);
        m.end();
        try w.conn.flush();
        b.busy = true;
        pop.shown = true;
    }

    fn popupXdgSurfaceEvent(ptr: ?*anyopaque, _: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.xdg_surface.event.configure) return;
        const serial = r.uint() catch return;
        for (&w.popups) |*slot| if (slot.*) |*pop| if (pop.xdg_surface.id == id) {
            var m = pop.xdg_surface.request(p.xdg_surface.request.ack_configure) catch return;
            m.uint(serial).end();
            pop.configured = true;
            // A configure takes effect when committed. Once it shows, a
            // popup is only drawn again when what it shows changes, so
            // commit what it has.
            if (pop.shown) {
                m = pop.surface.request(p.wl_surface.request.commit) catch return;
                m.end();
                w.conn.flush() catch {};
            }
        };
    }

    fn popupEvent(ptr: ?*anyopaque, _: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        const pop = for (&w.popups) |*slot| {
            if (slot.*) |*pop| if (pop.popup.id == id) break pop;
        } else return;
        switch (opcode) {
            p.xdg_popup.event.configure => {
                const x = r.int() catch return;
                const y = r.int() catch return;
                pop.position = .{ x, y };
            },
            p.xdg_popup.event.popup_done => w.pushInput(.{ .popup_done = pop.id }),
            else => {},
        }
    }

    pub fn setMinimized(w: *WaylandWindow) void {
        var m = w.toplevel.request(p.xdg_toplevel.request.set_minimized) catch return;
        m.end();
        w.conn.flush() catch {};
    }

    pub fn canMaximize(w: *const WaylandWindow) bool {
        return w.can_maximize;
    }

    pub fn canMinimize(w: *const WaylandWindow) bool {
        return w.can_minimize;
    }

    pub fn canFullscreen(w: *const WaylandWindow) bool {
        return w.can_fullscreen;
    }

    pub fn setMaximized(w: *WaylandWindow, on: bool) void {
        var m = w.toplevel.request(if (on) p.xdg_toplevel.request.set_maximized else p.xdg_toplevel.request.unset_maximized) catch return;
        m.end();
        w.conn.flush() catch {};
    }

    pub fn setMinSize(w: *WaylandWindow, width: u32, height: u32) void {
        if (w.isFloating()) {
            if (w.width < width) w.width = width;
            if (w.height < height) w.height = height;
        }
        if (w.min_size[0] == width and w.min_size[1] == height) return;
        w.min_size = .{ width, height };
        var m = w.toplevel.request(p.xdg_toplevel.request.set_min_size) catch return;
        m.int(@intCast(width)).int(@intCast(height)).end();
        w.conn.flush() catch {};
    }

    /// True when the window is neither maximized, fullscreen, nor tiled.
    pub fn isFloating(w: *const WaylandWindow) bool {
        return !w.maximized and !w.fullscreen and !w.tiled;
    }

    /// True when the window is floating and the toolkit draws its drop
    /// shadows, rounded corners, and an outer resize border. False when the
    /// compositor draws the decorations (`zxdg_toplevel_decoration_v1`), or
    /// when maximized, fullscreen, or tiled.
    pub fn hasToolkitDecorations(w: *const WaylandWindow) bool {
        return !w.system_decorations and w.isFloating();
    }

    pub fn frameMargin(w: *const WaylandWindow) u32 {
        return if (w.hasToolkitDecorations()) shadow_margin else 0;
    }

    pub fn edgesAt(w: *const WaylandWindow, pos: [2]f32) u32 {
        if (!w.hasToolkitDecorations()) return 0;
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const x = pos[0];
        const y = pos[1];
        if (x < -resize_outset or y < -resize_outset or x >= width + resize_outset or y >= height + resize_outset) return 0;
        if (w.isInsideContent(pos)) return 0;

        var edges: u32 = 0;
        if (x < 0 or (x < corner_radius and (y < corner_radius or y >= height - corner_radius))) {
            edges |= edge_left;
        } else if (x >= width or (x >= width - corner_radius and (y < corner_radius or y >= height - corner_radius))) {
            edges |= edge_right;
        }
        if (y < 0 or (y < corner_radius and (x < corner_radius or x >= width - corner_radius))) {
            edges |= edge_top;
        } else if (y >= height or (y >= height - corner_radius and (x < corner_radius or x >= width - corner_radius))) {
            edges |= edge_bottom;
        }
        if (edges & (edge_left | edge_right) != 0 and edges & (edge_top | edge_bottom) == 0) {
            if (y < resize_corner) edges |= edge_top else if (y >= height - resize_corner) edges |= edge_bottom;
        }
        if (edges & (edge_top | edge_bottom) != 0 and edges & (edge_left | edge_right) == 0) {
            if (x < resize_corner) edges |= edge_left else if (x >= width - resize_corner) edges |= edge_right;
        }
        return edges;
    }

    pub fn setCursor(w: *WaylandWindow, cursor: PointerCursor) void {
        if (w.app_cursor == cursor) return;
        w.app_cursor = cursor;
        if (w.display) |d| d.updateDisplayCursor() else w.updateCursor();
    }

    /// `cursor`'s `wp_cursor_shape_device_v1.shape` code.
    pub fn cursorShape(cursor: PointerCursor) u32 {
        const sh = p.wp_cursor_shape_device_v1.shape;
        return switch (cursor) {
            inline else => |c| @field(sh, @tagName(c)),
        };
    }

    fn updateCursor(w: *WaylandWindow) void {
        const edges = if (w.buttons_down == 0) w.edgesAt(w.pointer_pos) else 0;
        const sh = p.wp_cursor_shape_device_v1.shape;
        const vertical = edges & (edge_top | edge_bottom);
        const horizontal = edges & (edge_left | edge_right);
        const shape: u32 = if (vertical != 0 and horizontal != 0)
            (if ((vertical == edge_top) == (horizontal == edge_left)) sh.nwse_resize else sh.nesw_resize)
        else if (horizontal != 0) sh.ew_resize else if (vertical != 0) sh.ns_resize else cursorShape(w.app_cursor);
        if (w.cursor_shape == shape) return;
        const device = w.cursor_device orelse return;
        var m = device.request(p.wp_cursor_shape_device_v1.request.set_shape) catch return;
        m.uint(w.enter_serial).uint(shape).end();
        w.cursor_shape = shape;
    }

    pub fn startDrag(w: *WaylandWindow, mime_type: []const u8, bytes: []const u8, actions: window_mod.DragActions) bool {
        // Wayland's `dnd_action`s: copy 1, move 2, ask 4.
        const bits: u32 = @as(u32, @intFromBool(actions.copy)) | @as(u32, @intFromBool(actions.move)) << 1 | @as(u32, @intFromBool(actions.ask)) << 2;
        const cb = if (w.display) |d| &d.clipboard else &w.clipboard;
        return cb.startDrag(w.surface, null, mime_type, bytes, bits);
    }

    pub fn takeDrop(w: *WaylandWindow) ?DroppedData {
        const cb = if (w.display) |d| &d.clipboard else &w.clipboard;
        return cb.takeDrop();
    }

    pub fn hasClipboard(w: *const WaylandWindow) bool {
        const cb = if (w.display) |d| &d.clipboard else &w.clipboard;
        return cb.hasClipboard();
    }

    pub fn copy(w: *WaylandWindow, text: []const u8) void {
        const cb = if (w.display) |d| &d.clipboard else &w.clipboard;
        cb.copy(text);
    }

    pub fn paste(w: *WaylandWindow, sink: clipboard_mod.Sink) void {
        const cb = if (w.display) |d| &d.clipboard else &w.clipboard;
        cb.paste(sink);
    }

    /// The next frame shown is drawn for `target_ns`: with
    /// `wp_commit_timing_v1`, it is not shown before then.
    pub fn setPresentationTime(w: *WaylandWindow, target_ns: u64) void {
        w.target_ns = target_ns;
    }

    pub fn nextPresentationNs(w: *const WaylandWindow, now_ns: u64) u64 {
        if (w.presented_ns == 0 or w.refresh_ns == 0) return now_ns;
        if (now_ns < w.presented_ns) return w.presented_ns + w.refresh_ns;
        const elapsed = now_ns - w.presented_ns;
        const periods = elapsed / w.refresh_ns + 1;
        return w.presented_ns + periods * w.refresh_ns;
    }

    pub fn setTextInput(w: *WaylandWindow, state: ?TextInputState) void {
        const ti = if (w.display) |d| (d.text_input orelse return) else (w.text_input orelse return);
        if (!w.text_input_entered) {
            if (state) |s| {
                w.saveTextInputState(s);
                w.text_input_enabled = true;
            } else {
                w.text_input_enabled = false;
            }
            return;
        }
        if (state) |s| {
            if (w.text_input_enabled and w.text_input_state.eql(s)) return;
            const enabling = !w.text_input_enabled;
            w.saveTextInputState(s);
            w.text_input_enabled = true;
            w.sendTextInputState(ti, enabling);
        } else {
            if (!w.text_input_enabled) return;
            w.text_input_enabled = false;
            var m = ti.request(p.zwp_text_input_v3.request.disable) catch return;
            m.end();
            m = ti.request(p.zwp_text_input_v3.request.commit) catch return;
            m.end();
            w.text_input_serial +%= 1;
            w.conn.flush() catch {};
        }
    }

    fn saveTextInputState(w: *WaylandWindow, s: TextInputState) void {
        const n = @min(s.surrounding_text.len, w.text_input_surrounding_buf.len);
        @memcpy(w.text_input_surrounding_buf[0..n], s.surrounding_text[0..n]);
        w.text_input_state = s;
        w.text_input_state.surrounding_text = w.text_input_surrounding_buf[0..n];
        w.text_input_state.cursor = @min(s.cursor, @as(u32, @intCast(n)));
        w.text_input_state.anchor = @min(s.anchor, @as(u32, @intCast(n)));
    }

    fn sendTextInputState(w: *WaylandWindow, ti: client.Proxy, send_enable: bool) void {
        const s = w.text_input_state;
        const ti_proto = p.zwp_text_input_v3;
        const hint: u32 = if (s.password)
            ti_proto.content_hint.hidden_text | ti_proto.content_hint.sensitive_data
        else if (s.multiline)
            ti_proto.content_hint.multiline
        else
            ti_proto.content_hint.none;
        const purpose: u32 = if (s.password) ti_proto.content_purpose.password else ti_proto.content_purpose.normal;
        const cause: u32 = switch (s.change_cause) {
            .input_method => ti_proto.change_cause.input_method,
            .other => ti_proto.change_cause.other,
        };
        if (send_enable) {
            var m = ti.request(p.zwp_text_input_v3.request.enable) catch return;
            m.end();
        }
        var m = ti.request(p.zwp_text_input_v3.request.set_surrounding_text) catch return;
        m.string(s.surrounding_text).uint(s.cursor).uint(s.anchor).end();
        m = ti.request(p.zwp_text_input_v3.request.set_text_change_cause) catch return;
        m.uint(cause).end();
        m = ti.request(p.zwp_text_input_v3.request.set_content_type) catch return;
        m.uint(hint).uint(purpose).end();
        m = ti.request(p.zwp_text_input_v3.request.set_cursor_rectangle) catch return;
        const m_off: i32 = @intCast(w.frameMargin());
        m.int(s.cursor_rect[0] + m_off).int(s.cursor_rect[1] + m_off).int(s.cursor_rect[2]).int(s.cursor_rect[3]).end();
        m = ti.request(p.zwp_text_input_v3.request.commit) catch return;
        m.end();
        w.text_input_serial +%= 1;
        w.conn.flush() catch {};
    }

    pub fn startMove(w: *WaylandWindow) void {
        if (w.press_serial == 0) return;
        const seat = w.seat orelse return;
        var m = w.toplevel.request(p.xdg_toplevel.request.move) catch return;
        m.uint(seat.id).uint(w.press_serial).end();
        w.conn.flush() catch {};
    }

    /// Waits on `source` too in `wait` (`on`), or no longer (for as many
    /// as `watched` has room for).
    pub fn watch(w: *WaylandWindow, source: window_mod.Source, on: bool) void {
        if (w.display) |d| return d.watch(source, on);
        for (&w.watched) |*slot| if (slot.*) |x| if (x.eql(source)) {
            if (!on) slot.* = null;
            return;
        };
        if (!on) return;
        for (&w.watched) |*slot| if (slot.* == null) {
            slot.* = source;
            return;
        };
    }

    /// Handles what has come, waiting (through `io`, with whatever else
    /// is waiting on it) up to `timeout_ns` for something: an event, a
    /// paste's text, a watched source's read, or a key to repeat.
    pub fn wait(w: *WaylandWindow, timeout_ns: u64) !void {
        if (w.display) |d| return d.wait(timeout_ns);
        try w.conn.flush();
        if (try w.conn.dispatchPending() == 0) {
            const now_ns = w.now();
            var ns = timeout_ns;
            if (w.repeatTimeoutMs(now_ns)) |ms| ns = @min(ns, ms *| std.time.ns_per_ms);
            if (w.clipboard.pasteTimeoutMs()) |ms| ns = @min(ns, ms *| std.time.ns_per_ms);
            var sources: [2 + w.watched.len]window_mod.Source = undefined;
            sources[0] = .{ .ctx = w, .fd = w.conn.conn.fd, .read = connRead, .done = connDone };
            sources[1] = .{ .ctx = w, .fd = -1, .read = pasteRead, .done = pasteDone };
            var n: usize = 2;
            for (w.watched) |slot| if (slot) |x| {
                sources[n] = x;
                n += 1;
            };
            try window_mod.waitSources(w.io, sources[0..n], ns);
            if (w.read_error) |e| {
                w.read_error = null;
                return e;
            }
            _ = try w.conn.dispatchPending();
        }
        w.clipboard.service();
        w.serviceRepeat(w.now());
    }

    fn connRead(ctx: *anyopaque) ?std.Io.Operation {
        const w: *WaylandWindow = @ptrCast(@alignCast(ctx));
        return w.conn.conn.readOperation() catch |e| {
            w.read_error = e;
            return null;
        };
    }

    fn connDone(ctx: *anyopaque, result: std.Io.Operation.Result) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ctx));
        _ = w.conn.conn.readDone(result) catch |e| {
            w.read_error = e;
        };
    }

    fn pasteRead(ctx: *anyopaque) ?std.Io.Operation {
        const w: *WaylandWindow = @ptrCast(@alignCast(ctx));
        return w.clipboard.readOperation();
    }

    fn pasteDone(ctx: *anyopaque, result: std.Io.Operation.Result) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ctx));
        w.clipboard.readDone(result);
    }

    fn repeatTimeoutMs(w: *const WaylandWindow, now_ns: u64) ?u64 {
        const rep = w.repeat orelse return null;
        if (w.repeat_rate == 0) return null;
        if (now_ns >= rep.next_ns) return 0;
        return std.math.divCeil(u64, rep.next_ns - now_ns, std.time.ns_per_ms) catch 0;
    }

    pub fn serviceRepeat(w: *WaylandWindow, now_ns: u64) void {
        const rep = &(w.repeat orelse return);
        if (w.repeat_rate == 0) {
            w.repeat = null;
            return;
        }
        if (now_ns < rep.next_ns) return;
        const step = std.time.ns_per_s / @as(u64, w.repeat_rate);
        rep.next_ns = if (now_ns - rep.next_ns < step) rep.next_ns + step else now_ns + step;
        w.pushKey(rep.code, true, true);
    }

    /// Passes on a key going down or up (or repeating), composing it with
    /// the keys before it where they are a dead key or Compose.
    fn pushKey(w: *WaylandWindow, code: u32, pressed: bool, repeat: bool) void {
        var ev = w.keyInput(code, pressed);
        const km = &(w.keymap orelse return w.pushInput(ev));
        if (!pressed) return w.pushInput(ev);
        const sym = km.keysym(code, w.xkb_state);
        if (repeat) {
            // A dead key, Compose, or a key in a sequence does not repeat.
            if (w.compose_state.composing() or compose.starts(sym)) ev.key.char = null;
            return w.pushInput(ev);
        }
        const table = w.composeTable(sym) orelse return w.pushInput(ev);
        switch (w.compose_state.feed(table, sym)) {
            .none => w.pushInput(ev),
            .composing, .cancelled => {
                ev.key.char = null;
                w.pushInput(ev);
            },
            .composed => |r| {
                // One character comes with the key; more as text.
                const view = std.unicode.Utf8View.init(r.text) catch {
                    ev.key.char = null;
                    return w.pushInput(ev);
                };
                var it = view.iterator();
                const first = it.nextCodepoint();
                const one = first != null and it.nextCodepoint() == null;
                ev.key.char = if (one) first else null;
                w.pushInput(ev);
                if (!one and r.text.len > 0) {
                    var commit: window_mod.InputEvent = .{ .text_commit = .{} };
                    const n: u8 = @intCast(@min(r.text.len, commit.text_commit.buf.len));
                    @memcpy(commit.text_commit.buf[0..n], r.text[0..n]);
                    commit.text_commit.len = n;
                    w.pushInput(commit);
                }
            },
        }
    }

    /// The Compose sequences, once a key that starts one is pressed: the
    /// user's or the locale's, or the built-in dead keys if neither can be
    /// read.
    fn composeTable(w: *WaylandWindow, sym: u32) ?*const compose.Table {
        if (w.compose_table) |*t| return t;
        if (w.compose_tried or !compose.starts(sym)) return null;
        w.compose_tried = true;
        w.compose_table = compose.Table.load(w.gpa, w.io, w.compose_env) orelse compose.Table.builtin(w.gpa) catch null;
        return if (w.compose_table) |*t| t else null;
    }

    /// A key going down or up, with what it types and the modifiers held
    /// (by the keymap and the modifiers now: so in order with the
    /// compositor's changes to them).
    fn keyInput(w: *const WaylandWindow, code: u32, pressed: bool) window_mod.InputEvent {
        const key = window_mod.evdev.keyOf(code);
        const km = &(w.keymap orelse return .{ .key = .{ .key = key, .pressed = pressed } });
        const mods = w.xkb_state.mods();
        return .{ .key = .{
            .key = key,
            .pressed = pressed,
            .char = if (pressed) km.char(code, w.xkb_state) else null,
            .shift = mods & xkb.shift_mask != 0,
            .ctrl = mods & xkb.control_mask != 0,
        } };
    }

    fn pushKeyViaDisplay(w: *WaylandWindow, code: u32, pressed: bool, repeat: bool, d: *WaylandDisplay) void {
        var ev = w.keyInputViaDisplay(code, pressed, d);
        const km = &(d.keymap orelse return w.pushInput(ev));
        if (!pressed) return w.pushInput(ev);
        const sym = km.keysym(code, d.xkb_state);
        if (repeat) {
            // A dead key, Compose, or a key in a sequence does not repeat.
            if (d.compose_state.composing() or compose.starts(sym)) ev.key.char = null;
            return w.pushInput(ev);
        }
        const table = w.composeTableViaDisplay(sym, d) orelse return w.pushInput(ev);
        switch (d.compose_state.feed(table, sym)) {
            .none => w.pushInput(ev),
            .composing, .cancelled => {
                ev.key.char = null;
                w.pushInput(ev);
            },
            .composed => |r| {
                // One character comes with the key; more as text.
                const view = std.unicode.Utf8View.init(r.text) catch {
                    ev.key.char = null;
                    return w.pushInput(ev);
                };
                var it = view.iterator();
                const first = it.nextCodepoint();
                const one = first != null and it.nextCodepoint() == null;
                ev.key.char = if (one) first else null;
                w.pushInput(ev);
                if (!one and r.text.len > 0) {
                    var commit: window_mod.InputEvent = .{ .text_commit = .{} };
                    const n: u8 = @intCast(@min(r.text.len, commit.text_commit.buf.len));
                    @memcpy(commit.text_commit.buf[0..n], r.text[0..n]);
                    commit.text_commit.len = n;
                    w.pushInput(commit);
                }
            },
        }
    }

    fn composeTableViaDisplay(w: *WaylandWindow, sym: u32, d: *WaylandDisplay) ?*const compose.Table {
        _ = w;
        if (d.compose_table) |*t| return t;
        if (d.compose_tried or !compose.starts(sym)) return null;
        d.compose_tried = true;
        d.compose_table = compose.Table.load(d.gpa, d.io, d.compose_env) orelse compose.Table.builtin(d.gpa) catch null;
        return if (d.compose_table) |*t| t else null;
    }

    fn keyInputViaDisplay(w: *const WaylandWindow, code: u32, pressed: bool, d: *const WaylandDisplay) window_mod.InputEvent {
        _ = w;
        const key = window_mod.evdev.keyOf(code);
        const km = &(d.keymap orelse return .{ .key = .{ .key = key, .pressed = pressed } });
        const mods = d.xkb_state.mods();
        return .{ .key = .{
            .key = key,
            .pressed = pressed,
            .char = if (pressed) km.char(code, d.xkb_state) else null,
            .shift = mods & xkb.shift_mask != 0,
            .ctrl = mods & xkb.control_mask != 0,
        } };
    }

    /// The keyboard layout in use.
    pub fn layout(w: *const WaylandWindow) window_mod.KeyboardLayout {
        const km = if (w.display) |d| &(d.keymap orelse return .{}) else &(w.keymap orelse return .{});
        const xkb_state = if (w.display) |d| d.xkb_state else w.xkb_state;
        return .init(km.layoutName(xkb_state), km.layoutCode(xkb_state));
    }

    pub fn applyConfigure(w: *WaylandWindow) !?[2]u32 {
        const serial = w.pending_serial orelse return null;
        w.pending_serial = null;
        const dec_changed = w.decoration_changed;
        w.decoration_changed = false;
        var size = [2]u32{
            if (w.next_size[0] > 0) @intCast(w.next_size[0]) else w.width,
            if (w.next_size[1] > 0) @intCast(w.next_size[1]) else w.height,
        };
        if (w.isFloating()) {
            size[0] = @max(size[0], w.min_size[0]);
            size[1] = @max(size[1], w.min_size[1]);
        }
        var m = try w.xdg_surface.request(p.xdg_surface.request.ack_configure);
        m.uint(serial).end();
        if (size[0] == w.width and size[1] == w.height and !dec_changed) return null;
        w.width = size[0];
        w.height = size[1];
        return size;
    }

    /// Acquires a free `linux_dmabuf` (or `wl_shm` fallback) buffer of the
    /// window's current size and returns its inner content CPU pixel slice as
    /// a `gfx.software.Image`.
    pub fn beginSoftwareFrame(w: *WaylandWindow) !gfx.software.Image {
        const i = w.back orelse try w.pickBack();
        w.back = i;
        w.frame_corners_applied = false;
        w.buffers[i].?.gpu_frame = false;
        try w.buffers[i].?.beginCpuAccess();
        return w.buffers[i].?.image();
    }

    /// The next frame's buffer as a dmabuf, unmapped, for the GPU to draw
    /// into (see `gfx.Renderer.renderDmabuf`); null for a `wl_shm` buffer.
    pub fn beginDmabufFrame(w: *WaylandWindow) ?gfx.DmabufTarget {
        if (!w.usingDmabuf()) return null;
        const i = w.back orelse (w.pickBack() catch return null);
        w.back = i;
        w.frame_corners_applied = false;
        const b = &w.buffers[i].?;
        const bo = b.bo orelse return null;
        if (b.export_fd < 0) {
            const fd = b.gbm.?.bo_get_fd(bo);
            if (fd < 0) return null;
            b.export_fd = fd;
        }
        return .{
            .id = b.id,
            .fd = b.export_fd,
            .fourcc = b.fourcc,
            .modifier = b.modifier,
            .offset = b.offset,
            .stride = b.rowWords() * 4,
            .width = b.width,
            .height = b.height,
            .origin = .{ b.margin, b.margin },
            .content = .{ if (b.content_w > 0) b.content_w else b.width, if (b.content_h > 0) b.content_h else b.height },
            .cpu = .{ .ctx = b, .begin = cpuBegin, .end = cpuEnd },
            .frame = if (b.margin > 0) frame: {
                const s: f32 = @floatFromInt(@max(b.scale, 1));
                b.gpu_frame = true;
                break :frame .{ .radius = corner_radius * s, .scale = s };
            } else null,
        };
    }

    fn cpuBegin(ctx: *anyopaque) anyerror!gfx.software.Image {
        const b: *Buffer = @ptrCast(@alignCast(ctx));
        try b.beginCpuAccess();
        return b.image();
    }

    fn cpuEnd(ctx: *anyopaque) void {
        const b: *Buffer = @ptrCast(@alignCast(ctx));
        b.endCpuAccess();
    }

    /// Applies rounded window corners and drop-shadow margin to the current
    /// back buffer for the `repainted` viewports (or the entire window if `null`).
    pub fn finishFrame(w: *WaylandWindow, repainted: ?[]const gfx.Viewport) void {
        const i = w.back orelse return;
        const b = &w.buffers[i].?;
        if (b.gpu_frame) {
            // Drawn with the frame on the GPU.
            b.shadow_drawn = true;
        } else if (b.margin > 0 and b.needsCpuFinish(if (b.drawn == 0) null else repainted)) {
            // Drawn on the GPU, it is mapped only for this.
            b.beginCpuAccess() catch return;
            b.renderShadowMargin();
            b.applyRoundedCorners(if (b.drawn == 0) null else repainted);
        }
        w.frame_corners_applied = true;
    }

    /// How many frames ago the buffer `beginSoftwareFrame` gave was last drawn: 1
    /// if in the frame before, 0 if never.
    pub fn bufferAge(w: *const WaylandWindow) u32 {
        const i = w.back orelse return 0;
        const b = &w.buffers[i].?;
        if (b.drawn == 0) return 0;
        return @intCast(@min(w.frames + 1 - b.drawn, std.math.maxInt(u32)));
    }

    pub fn show(w: *WaylandWindow) !void {
        return w.showDamaged(null);
    }

    pub fn showDamaged(w: *WaylandWindow, damage: ?[]const gfx.Viewport) !void {
        const i = w.back orelse return error.NoFrameBegun;
        try w.showBuffer(i, damage);
        w.back = null;
    }

    fn showBuffer(w: *WaylandWindow, i: usize, damage: ?[]const gfx.Viewport) !void {
        while (w.vsync and w.frame_pending) {
            try w.conn.dispatch();
            if (w.suspended) w.releaseSpareBuffers();
        }
        const b = &w.buffers[i].?;
        if (!w.frame_corners_applied and !b.gpu_frame) {
            if (b.margin > 0 and b.needsCpuFinish(if (b.drawn == 0) null else damage)) {
                if (b.beginCpuAccess()) {
                    b.renderShadowMargin();
                    b.applyRoundedCorners(if (b.drawn == 0) null else damage);
                } else |_| {}
            }
            w.frame_corners_applied = true;
        }
        b.endCpuAccess();
        const s = @max(b.scale, 1);
        const m_logical = b.margin / s;
        const cw_logical = (if (b.content_w > 0) b.content_w else b.width) / s;
        const ch_logical = (if (b.content_h > 0) b.content_h else b.height) / s;
        const geom_key = [3]u32{ m_logical, cw_logical, ch_logical };
        if (w.last_geometry == null or !std.meta.eql(w.last_geometry.?, geom_key)) {
            w.last_geometry = geom_key;
            var gm = try w.xdg_surface.request(p.xdg_surface.request.set_window_geometry);
            gm.int(@intCast(m_logical)).int(@intCast(m_logical)).int(@intCast(cw_logical)).int(@intCast(ch_logical)).end();
            if (m_logical > 0) {
                const outset: i32 = @intFromFloat(resize_outset);
                const rx: i32 = @as(i32, @intCast(m_logical)) - outset;
                const ry: i32 = @as(i32, @intCast(m_logical)) - outset;
                const rw: i32 = @as(i32, @intCast(cw_logical)) + 2 * outset;
                const rh: i32 = @as(i32, @intCast(ch_logical)) + 2 * outset;
                const in_reg = try w.conn.newObject(null);
                var rm = try w.compositor.request(p.wl_compositor.request.create_region);
                rm.uint(in_reg.id).end();
                rm = try in_reg.request(p.wl_region.request.add);
                rm.int(rx).int(ry).int(rw).int(rh).end();
                rm = try w.surface.request(p.wl_surface.request.set_input_region);
                rm.uint(in_reg.id).end();
                rm = try in_reg.request(p.wl_region.request.destroy);
                rm.end();
                w.conn.forget(in_reg.id);

                const r_i: i32 = @intFromFloat(@ceil(corner_radius));
                const cw_i: i32 = @intCast(cw_logical);
                const ch_i: i32 = @intCast(ch_logical);
                const m_i: i32 = @intCast(m_logical);
                if (cw_i > 2 * r_i and ch_i > 2 * r_i) {
                    const op_reg = try w.conn.newObject(null);
                    rm = try w.compositor.request(p.wl_compositor.request.create_region);
                    rm.uint(op_reg.id).end();
                    rm = try op_reg.request(p.wl_region.request.add);
                    rm.int(m_i + r_i).int(m_i).int(cw_i - 2 * r_i).int(ch_i).end();
                    rm = try op_reg.request(p.wl_region.request.add);
                    rm.int(m_i).int(m_i + r_i).int(cw_i).int(ch_i - 2 * r_i).end();
                    rm = try w.surface.request(p.wl_surface.request.set_opaque_region);
                    rm.uint(op_reg.id).end();
                    rm = try op_reg.request(p.wl_region.request.destroy);
                    rm.end();
                    w.conn.forget(op_reg.id);
                } else {
                    rm = try w.surface.request(p.wl_surface.request.set_opaque_region);
                    rm.uint(0).end();
                }
            } else {
                var rm = try w.surface.request(p.wl_surface.request.set_input_region);
                rm.uint(0).end();
                const op_reg = try w.conn.newObject(null);
                rm = try w.compositor.request(p.wl_compositor.request.create_region);
                rm.uint(op_reg.id).end();
                rm = try op_reg.request(p.wl_region.request.add);
                rm.int(0).int(0).int(@intCast(cw_logical)).int(@intCast(ch_logical)).end();
                rm = try w.surface.request(p.wl_surface.request.set_opaque_region);
                rm.uint(op_reg.id).end();
                rm = try op_reg.request(p.wl_region.request.destroy);
                rm.end();
                w.conn.forget(op_reg.id);
            }
        }
        var m = try w.surface.request(p.wl_surface.request.set_buffer_scale);
        m.int(@intCast(b.scale)).end();
        m = try w.surface.request(p.wl_surface.request.attach);
        m.uint(b.proxy.id).int(0).int(0).end();
        const m_px: i32 = @intCast(b.margin);
        if (b.drawn == 0 or damage == null) {
            m = try w.surface.request(p.wl_surface.request.damage_buffer);
            m.int(0).int(0).int(@intCast(b.width)).int(@intCast(b.height)).end();
        } else if (damage) |rects| {
            for (rects) |r| {
                m = try w.surface.request(p.wl_surface.request.damage_buffer);
                m.int(r.x + m_px).int(r.y + m_px).int(@intCast(r.width)).int(@intCast(r.height)).end();
            }
        }
        if (b.syncobj_timeline.id != 0) {
            if (w.syncobj_surface == null) if (w.drm_syncobj_manager) |mgr| {
                const ss = try w.conn.newObject(null);
                var sm = try mgr.request(p.wp_linux_drm_syncobj_manager_v1.request.get_surface);
                sm.uint(ss.id).uint(w.surface.id).end();
                w.syncobj_surface = ss;
            };
            if (w.syncobj_surface != null) {
                // The CPU has finished drawing: the buffer can be read now.
                var handle = b.syncobj_handle;
                var pt = b.syncobj_point + 1;
                if (b.drm.?.SyncobjTimelineSignal.?(b.drm_fd, &handle, &pt, 1) != 0) {
                    // An acquire point that is never signalled would hang
                    // the surface: go without explicit synchronization.
                    w.stopSyncobj();
                }
            }
            if (w.syncobj_surface) |ss| {
                const acquire_pt = b.syncobj_point + 1;
                const release_pt = acquire_pt + 1;
                b.syncobj_point = release_pt;
                b.release_point = release_pt;

                var sm = try ss.request(p.wp_linux_drm_syncobj_surface_v1.request.set_acquire_point);
                sm.uint(b.syncobj_timeline.id).uint(@intCast(acquire_pt >> 32)).uint(@truncate(acquire_pt)).end();
                sm = try ss.request(p.wp_linux_drm_syncobj_surface_v1.request.set_release_point);
                sm.uint(b.syncobj_timeline.id).uint(@intCast(release_pt >> 32)).uint(@truncate(release_pt)).end();
            }
        }
        if (w.vsync) {
            const cb = try w.conn.newObject(.{ .ptr = w, .handler = frameDone });
            m = try w.surface.request(p.wl_surface.request.frame);
            m.uint(cb.id).end();
            if (w.fifo) |fifo| {
                if (w.fifo_barrier_pending) {
                    m = try fifo.request(p.wp_fifo_v1.request.wait_barrier);
                    m.end();
                }
                m = try fifo.request(p.wp_fifo_v1.request.set_barrier);
                m.end();
                w.fifo_barrier_pending = true;
            }
        }
        if (w.commit_timer) |timer| if (w.target_ns) |target_ns| {
            // Not before half a refresh ahead of the time it is drawn
            // for, so that it shows at the refresh nearest that time
            // (not the one after, if the time is a little late).
            if (w.refresh_ns > 0 and w.presentation_clock_id == p.wp_presentation.clock.monotonic) {
                const earliest_ns = target_ns -| w.refresh_ns / 2;
                if (w.now() < earliest_ns) {
                    const secs = earliest_ns / std.time.ns_per_s;
                    const nsec: u32 = @intCast(earliest_ns % std.time.ns_per_s);
                    m = try timer.request(p.wp_commit_timer_v1.request.set_timestamp);
                    m.uint(@intCast(secs >> 32)).uint(@truncate(secs)).uint(nsec).end();
                }
            }
        };
        w.target_ns = null;
        if (w.presentation) |pres| {
            const fb = try w.conn.newObject(.{ .ptr = w, .handler = feedbackEvent });
            m = try pres.request(p.wp_presentation.request.feedback);
            m.uint(w.surface.id).uint(fb.id).end();
        }
        m = try w.surface.request(p.wl_surface.request.commit);
        m.end();
        try w.conn.flush();
        b.busy = true;
        w.frames += 1;
        b.drawn = w.frames;
        if (w.vsync) w.frame_pending = true;
    }

    pub fn takeInput(w: *WaylandWindow) []const InputEvent {
        w.flushLeave();
        defer w.input_len = 0;
        return w.input[0..w.input_len];
    }

    fn pickBack(w: *WaylandWindow) !usize {
        const s = @max(w.scale, 1);
        const m_logical = w.frameMargin();
        const cw = w.width * s;
        const ch = w.height * s;
        const m_px = m_logical * s;
        const bw = cw + 2 * m_px;
        const bh = ch + 2 * m_px;
        while (true) {
            var empty: ?usize = null;
            var stale: ?usize = null;
            var syncobj_wait_idx: ?usize = null;
            for (&w.buffers, 0..) |*slot, i| {
                if (slot.*) |*b| {
                    if (!b.isReady()) {
                        if (b.release_point > 0) {
                            if (syncobj_wait_idx == null or b.drawn < w.buffers[syncobj_wait_idx.?].?.drawn) {
                                syncobj_wait_idx = i;
                            }
                        }
                        continue;
                    }
                    if (b.width == bw and b.height == bh and b.content_w == cw and b.content_h == ch and b.margin == m_px and b.scale == s) return i;
                    stale = i;
                } else empty = i;
            }
            if (stale) |i| {
                w.freeBuffer(&w.buffers[i].?, &w.buffers[i]);
                empty = i;
            }
            if (empty) |i| {
                w.buffers[i] = try w.allocBuffer(i);
                return i;
            }
            if (syncobj_wait_idx) |i| {
                _ = w.buffers[i].?.waitReady(w.now(), 16 * std.time.ns_per_ms);
                _ = try w.conn.dispatchPending();
            } else {
                try w.conn.dispatch();
            }
        }
    }

    pub fn releaseSpareBuffers(w: *WaylandWindow) void {
        for (&w.buffers, 0..) |*slot, i| if (slot.*) |*b| {
            if (!b.isReady() or w.back == i) continue;
            w.freeBuffer(b, slot);
        };
    }

    fn allocBuffer(w: *WaylandWindow, slot: usize) !Buffer {
        const s = @max(w.scale, 1);
        const m_logical = w.frameMargin();
        const cw = w.width * s;
        const ch = w.height * s;
        const m_px = m_logical * s;
        const bw = cw + 2 * m_px;
        const bh = ch + 2 * m_px;
        if (w.usingDmabuf()) {
            if (w.allocDmabufBuffer(slot, bw, bh, cw, ch, m_px, s)) |buf| {
                return buf;
            } else |err| {
                if (w.shm.id == 0) return err;
                // wl_shm buffers cannot be explicitly synchronized, and the
                // dmabuf buffers belong to the device being closed.
                w.stopSyncobj();
                for (&w.buffers, 0..) |*other, i| if (i != slot) if (other.*) |*b| if (b.bo != null) w.freeBuffer(b, other);
                if (w.display == null) {
                    if (w.dmabuf_dev) |*dev| dev.close();
                    w.dmabuf_dev = null;
                }
                w.updateExtensions();
            }
        }
        return w.allocShmBuffer(&w.buffers[slot], bw, bh, cw, ch, m_px, s, m_px > 0);
    }

    fn allocDmabufBuffer(w: *WaylandWindow, slot: usize, bw: u32, bh: u32, cw: u32, ch: u32, m_px: u32, s: u32) !Buffer {
        const dmabuf = w.dmabuf orelse return error.NoDmabuf;
        const dev = if (w.display) |d| &(d.dmabuf_dev orelse return error.NoDmabuf) else &(w.dmabuf_dev orelse return error.NoDmabuf);
        const fmt: u32 = if ((m_px > 0 and w.dmabuf_argb8888) or !w.dmabuf_xrgb8888)
            p.fourcc.argb8888
        else
            p.fourcc.xrgb8888;
        const alloc = try dev.alloc(bw, bh, fmt);
        errdefer dev.gbm.bo_destroy(alloc.bo);
        var fd_sent = false;
        errdefer if (!fd_sent) {
            _ = linux.close(alloc.dmabuf_fd);
        };

        const params = try w.conn.newObject(null);
        var m = try dmabuf.request(p.zwp_linux_dmabuf_v1.request.create_params);
        m.uint(params.id).end();

        const mod = if (alloc.modifier != 0x00ffffffffffffff) alloc.modifier else p.modifier.linear;
        m = try params.request(p.zwp_linux_buffer_params_v1.request.add);
        m.fd(alloc.dmabuf_fd).uint(0).uint(alloc.offset).uint(alloc.stride).uint(@intCast(mod >> 32)).uint(@truncate(mod)).end();
        fd_sent = true;

        const proxy = try w.conn.newObject(.{ .ptr = &w.buffers[slot], .handler = bufferEvent });
        m = try params.request(p.zwp_linux_buffer_params_v1.request.create_immed);
        m.uint(proxy.id).int(@intCast(bw)).int(@intCast(bh)).uint(fmt).uint(0).end();

        m = try params.request(p.zwp_linux_buffer_params_v1.request.destroy);
        m.end();
        w.conn.forget(params.id);

        var syncobj_handle: u32 = 0;
        var syncobj_timeline: client.Proxy = .{};
        defer if (syncobj_timeline.id == 0 and w.usingDrmSyncobj()) {
            // Every buffer needs a timeline while explicit synchronization
            // is on (or committing it is a protocol error).
            w.stopSyncobj();
        };
        if (w.usingDrmSyncobj()) if (w.drm_syncobj_manager) |mgr| {
            var handle: u32 = 0;
            if (dev.drm.SyncobjCreate.?(dev.drm_fd, 0, &handle) == 0) {
                var obj_fd: c_int = -1;
                if (dev.drm.SyncobjHandleToFD.?(dev.drm_fd, handle, &obj_fd) == 0 and obj_fd >= 0) {
                    if (w.conn.newObject(null)) |tl| {
                        if (mgr.request(p.wp_linux_drm_syncobj_manager_v1.request.import_timeline)) |tm0| {
                            var tm = tm0;
                            tm.uint(tl.id).fd(obj_fd).end();
                            syncobj_handle = handle;
                            syncobj_timeline = tl;
                        } else |_| {
                            w.conn.forget(tl.id);
                            _ = linux.close(obj_fd);
                            _ = dev.drm.SyncobjDestroy.?(dev.drm_fd, handle);
                        }
                    } else |_| {
                        _ = linux.close(obj_fd);
                        _ = dev.drm.SyncobjDestroy.?(dev.drm_fd, handle);
                    }
                } else {
                    _ = dev.drm.SyncobjDestroy.?(dev.drm_fd, handle);
                }
            }
        };

        return .{
            .bo = alloc.bo,
            .gbm = dev.gbm,
            .drm_fd = dev.drm_fd,
            .drm = dev.drm,
            .syncobj_handle = syncobj_handle,
            .syncobj_timeline = syncobj_timeline,
            .proxy = proxy,
            .width = bw,
            .height = bh,
            .stride_words = alloc.stride / 4,
            .content_w = cw,
            .content_h = ch,
            .margin = m_px,
            .scale = s,
            .id = id: {
                w.next_buffer_id += 1;
                break :id w.next_buffer_id - 1;
            },
            .fourcc = fmt,
            .modifier = mod,
            .offset = alloc.offset,
        };
    }

    fn allocShmBuffer(w: *WaylandWindow, slot: *?Buffer, bw: u32, bh: u32, cw: u32, ch: u32, m_px: u32, s: u32, alpha: bool) !Buffer {
        const stride = bw * 4;
        const size: usize = @as(usize, stride) * @as(usize, bh);
        const rc = linux.memfd_create("kete-shm", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.OutOfMemory;
        const fd: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.OutOfMemory;
        const map_rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(map_rc) != .SUCCESS) return error.OutOfMemory;
        const pixels: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(map_rc))[0..size];
        errdefer _ = linux.munmap(pixels.ptr, size);

        const pool = try w.conn.newObject(null);
        var m = try w.shm.request(p.wl_shm.request.create_pool);
        m.uint(pool.id).fd(fd).int(@intCast(size)).end();

        const proxy = try w.conn.newObject(.{ .ptr = slot, .handler = bufferEvent });
        m = try pool.request(p.wl_shm_pool.request.create_buffer);
        const fmt: u32 = if (alpha) p.wl_shm.format.argb8888 else p.wl_shm.format.xrgb8888;
        m.uint(proxy.id).int(0).int(@intCast(bw)).int(@intCast(bh)).int(@intCast(stride)).uint(fmt).end();

        return .{
            .pixels = pixels,
            .pool = pool,
            .proxy = proxy,
            .width = bw,
            .height = bh,
            .stride_words = bw,
            .content_w = cw,
            .content_h = ch,
            .margin = m_px,
            .scale = s,
        };
    }

    /// Frees the buffer. The compositor may still be reading it: it keeps
    /// its own reference to the memory, and the timeline's points stay set.
    fn freeBuffer(w: *WaylandWindow, b: *Buffer, slot: *?Buffer) void {
        b.endCpuAccess();
        if (b.export_fd >= 0) _ = linux.close(b.export_fd);
        if (b.syncobj_timeline.id != 0) {
            if (b.syncobj_timeline.request(p.wp_linux_drm_syncobj_timeline_v1.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(b.syncobj_timeline.id);
            if (b.drm) |drm| if (drm.SyncobjDestroy) |destroy_fn| {
                _ = destroy_fn(b.drm_fd, b.syncobj_handle);
            };
        }
        if (b.proxy.request(p.wl_buffer.request.destroy)) |m0| {
            var m = m0;
            m.end();
        } else |_| {}
        w.conn.forget(b.proxy.id);
        if (b.pool.id != 0) {
            if (b.pool.request(p.wl_shm_pool.request.destroy)) |m0| {
                var m = m0;
                m.end();
            } else |_| {}
            w.conn.forget(b.pool.id);
        }
        if (b.bo) |bo| {
            if (b.gbm) |gbm| gbm.bo_destroy(bo);
        } else if (b.pixels.len > 0) {
            _ = linux.munmap(@alignCast(b.pixels.ptr), b.pixels.len);
        }
        slot.* = null;
    }

    fn bufferEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *wire.Reader) void {
        const slot: *?Buffer = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_buffer.event.release) if (slot.*) |*b| {
            b.busy = false;
        };
    }

    fn frameDone(ptr: ?*anyopaque, d: *client.Display, id: u32, _: u16, _: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        d.forget(id);
        w.frame_pending = false;
    }

    fn surfaceEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wl_surface.event.preferred_buffer_scale) {
            const factor = r.int() catch return;
            if (factor > 0) {
                const new_scale: u32 = @intCast(factor);
                w.scale = new_scale;
            }
        }
    }

    fn presentationEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.wp_presentation.event.clock_id) {
            w.presentation_clock_id = r.uint() catch return;
        }
    }

    fn feedbackEvent(ptr: ?*anyopaque, d: *client.Display, id: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wp_presentation_feedback.event.sync_output => {
                _ = r.uint() catch return;
            },
            p.wp_presentation_feedback.event.presented => {
                defer d.forget(id);
                const tv_sec_hi = r.uint() catch return;
                const tv_sec_lo = r.uint() catch return;
                const tv_nsec = r.uint() catch return;
                const refresh = r.uint() catch return;
                const seq_hi = r.uint() catch return;
                const seq_lo = r.uint() catch return;
                const flags = r.uint() catch return;
                const secs = (@as(u64, tv_sec_hi) << 32) | tv_sec_lo;
                w.presented_ns = secs * std.time.ns_per_s + tv_nsec;
                if (refresh > 0) w.refresh_ns = refresh;
                w.presentation_seq = (@as(u64, seq_hi) << 32) | seq_lo;
                w.presentation_flags = flags;
                w.presented_frames += 1;
            },
            p.wp_presentation_feedback.event.discarded => {
                d.forget(id);
                w.discarded_frames += 1;
            },
            else => {},
        }
    }

    /// A position on `surface` (the window's, or a popup's) in the window's
    /// coordinates.
    /// Whether `surface` is one of this window's (its own, or a popup's).
    fn ownsSurface(w: *const WaylandWindow, surface: u32) bool {
        if (surface == w.surface.id) return true;
        for (&w.popups) |*slot| if (slot.*) |*pop| if (pop.surface.id == surface) return true;
        return false;
    }

    /// Whether touch `id` is on another window's surface (and, if `ending`,
    /// forgets it).
    fn touchAway(w: *WaylandWindow, id: i32, ending: bool) bool {
        for (&w.away_touches) |*slot| if (slot.* == id) {
            if (ending) slot.* = null;
            return true;
        };
        return false;
    }

    fn toWindow(w: *const WaylandWindow, surface: u32, pos: [2]f32) [2]f32 {
        for (&w.popups) |*slot| if (slot.*) |*pop| if (pop.surface.id == surface) {
            const at = pop.position orelse return pos;
            return .{ pos[0] + @as(f32, @floatFromInt(at[0])), pos[1] + @as(f32, @floatFromInt(at[1])) };
        };
        return w.surfaceToContent(pos);
    }

    /// The pointer left the window's surfaces (and entered none of them).
    fn flushLeave(w: *WaylandWindow) void {
        if (!w.leave_pending) return;
        w.leave_pending = false;
        w.buttons_down = 0;
        w.pointer_surface = 0;
        w.pushInput(.leave);
    }

    fn surfaceToContent(w: *const WaylandWindow, pos: [2]f32) [2]f32 {
        const m: f32 = @floatFromInt(w.frameMargin());
        return .{ pos[0] - m, pos[1] - m };
    }

    fn isInsideContent(w: *const WaylandWindow, pos: [2]f32) bool {
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        if (pos[0] < 0 or pos[1] < 0 or pos[0] >= width or pos[1] >= height) return false;
        if (w.hasToolkitDecorations()) {
            const hx = @max(width * 0.5 - corner_radius, 0.0);
            const hy = @max(height * 0.5 - corner_radius, 0.0);
            if (sdfRoundedBox(pos[0] - width * 0.5, pos[1] - height * 0.5, hx, hy, corner_radius) > 0.0) return false;
        }
        return true;
    }

    fn onDragEnter(ptr: ?*anyopaque, pos: [2]f32, _: ?[]const u8) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.{ .drag_enter = w.surfaceToContent(pos) });
    }

    fn onDragMotion(ptr: ?*anyopaque, pos: [2]f32) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        const cpos = w.surfaceToContent(pos);
        if (w.input_len > 0 and w.input[w.input_len - 1] == .drag_motion) {
            w.input[w.input_len - 1] = .{ .drag_motion = cpos };
            return;
        }
        w.pushInput(.{ .drag_motion = cpos });
    }

    fn onDragLeave(ptr: ?*anyopaque) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.drag_leave);
    }

    fn onDragDrop(ptr: ?*anyopaque, pos: [2]f32, _: []const u8, _: []const u8, _: u32) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        w.pushInput(.{ .drop = w.surfaceToContent(pos) });
    }

    fn textInputEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.zwp_text_input_v3.event.enter => {
                if (!w.ownsSurface(r.uint() catch return)) return;
                w.text_input_entered = true;
                if (w.text_input_enabled) if (w.text_input) |ti| {
                    w.sendTextInputState(ti, true);
                };
            },
            p.zwp_text_input_v3.event.leave => {
                if (!w.ownsSurface(r.uint() catch return)) return;
                w.text_input_entered = false;
                w.text_input_pending_preedit = null;
                w.text_input_pending_commit = null;
                w.text_input_pending_delete = null;
            },
            p.zwp_text_input_v3.event.preedit_string => {
                const text = (r.string() catch return) orelse "";
                const begin = r.int() catch return;
                const end = r.int() catch return;
                var pre: @TypeOf(w.text_input_pending_preedit.?) = .{ .cursor_begin = begin, .cursor_end = end };
                const n: u8 = @intCast(@min(text.len, pre.buf.len));
                @memcpy(pre.buf[0..n], text[0..n]);
                pre.len = n;
                w.text_input_pending_preedit = pre;
            },
            p.zwp_text_input_v3.event.commit_string => {
                const text = (r.string() catch return) orelse "";
                var com: @TypeOf(w.text_input_pending_commit.?) = .{};
                const n: u8 = @intCast(@min(text.len, com.buf.len));
                @memcpy(com.buf[0..n], text[0..n]);
                com.len = n;
                w.text_input_pending_commit = com;
            },
            p.zwp_text_input_v3.event.delete_surrounding_text => {
                const before = r.uint() catch return;
                const after = r.uint() catch return;
                w.text_input_pending_delete = .{ .before_length = before, .after_length = after };
            },
            p.zwp_text_input_v3.event.done => {
                _ = r.uint() catch return;
                if (w.text_input_pending_delete) |del| {
                    w.text_input_pending_delete = null;
                    w.pushInput(.{ .text_delete_surrounding = .{ .before_length = del.before_length, .after_length = del.after_length } });
                }
                if (w.text_input_pending_commit) |com| {
                    w.text_input_pending_commit = null;
                    if (com.len > 0) {
                        var ev: InputEvent = .{ .text_commit = .{ .len = com.len } };
                        @memcpy(ev.text_commit.buf[0..com.len], com.buf[0..com.len]);
                        w.pushInput(ev);
                    }
                }
                if (w.text_input_pending_preedit) |pre| {
                    w.text_input_pending_preedit = null;
                    w.text_input_has_preedit = pre.len > 0;
                    var ev: InputEvent = .{ .text_preedit = .{ .len = pre.len, .cursor_begin = pre.cursor_begin, .cursor_end = pre.cursor_end } };
                    @memcpy(ev.text_preedit.buf[0..pre.len], pre.buf[0..pre.len]);
                    w.pushInput(ev);
                } else if (w.text_input_has_preedit) {
                    w.text_input_has_preedit = false;
                    w.pushInput(.{ .text_preedit = .{} });
                }
            },
            else => {},
        }
    }

    fn pushInput(w: *WaylandWindow, e: InputEvent) void {
        if (e == .motion and w.input_len > 0 and w.input[w.input_len - 1] == .motion) {
            w.input[w.input_len - 1] = e;
            return;
        }
        if (e == .touch_motion and w.input_len > 0) switch (w.input[w.input_len - 1]) {
            .touch_motion => |last| if (last.id == e.touch_motion.id) {
                w.input[w.input_len - 1] = e;
                return;
            },
            else => {},
        };
        if (w.input_len == w.input.len) return;
        w.input[w.input_len] = e;
        w.input_len += 1;
    }

    fn seatEvent(ptr: ?*anyopaque, d: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.wl_seat.event.capabilities) return;
        const caps = r.uint() catch return;
        if (caps & p.wl_seat.capability.pointer != 0 and w.pointer == null) {
            const pointer = d.newObject(.{ .ptr = w, .handler = pointerEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_pointer) catch return;
            m.uint(pointer.id).end();
            w.pointer = pointer;
            if (w.cursor_shape_manager) |manager| {
                const device = d.newObject(null) catch return;
                m = manager.request(p.wp_cursor_shape_manager_v1.request.get_pointer) catch return;
                m.uint(device.id).uint(pointer.id).end();
                w.cursor_device = device;
            }
            if (w.relative_pointer_manager) |manager| {
                const rel = d.newObject(.{ .ptr = w, .handler = relativeEvent }) catch return;
                m = manager.request(p.zwp_relative_pointer_manager_v1.request.get_relative_pointer) catch return;
                m.uint(rel.id).uint(pointer.id).end();
                w.relative_pointer = rel;
            }
        }
        if (caps & p.wl_seat.capability.touch != 0 and w.touch == null) {
            const touch = d.newObject(.{ .ptr = w, .handler = touchEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_touch) catch return;
            m.uint(touch.id).end();
            w.touch = touch;
        }
        if (caps & p.wl_seat.capability.keyboard != 0 and w.keyboard == null) {
            const keyboard = d.newObject(.{ .ptr = w, .handler = keyboardEvent }) catch return;
            var m = w.seat.?.request(p.wl_seat.request.get_keyboard) catch return;
            m.uint(keyboard.id).end();
            w.keyboard = keyboard;
        }
    }

    fn pointerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        // On another window's surface: for it.
        if (w.pointer_away and opcode != p.wl_pointer.event.enter) {
            if (opcode == p.wl_pointer.event.leave) w.pointer_away = false;
            return;
        }
        switch (opcode) {
            p.wl_pointer.event.enter, p.wl_pointer.event.motion => {
                const first = r.uint() catch return;
                if (opcode == p.wl_pointer.event.enter) {
                    const surface = r.uint() catch return;
                    // Another window's.
                    w.pointer_away = !w.ownsSurface(surface);
                    if (w.pointer_away) return;
                    w.enter_serial = first;
                    w.cursor_shape = p.wp_cursor_shape_device_v1.shape.default;
                    // Moving between the window's surfaces is not leaving.
                    if (!w.leave_pending) w.buttons_down = 0;
                    w.leave_pending = false;
                    w.pointer_surface = surface;
                }
                const x = r.fixed() catch return;
                const y = r.fixed() catch return;
                w.pointer_pos = w.toWindow(w.pointer_surface, .{ @floatCast(x), @floatCast(y) });
                w.updateCursor();
                w.pushInput(.{ .motion = w.pointer_pos });
            },
            p.wl_pointer.event.button => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const button = pointerButtonOf(r.uint() catch return);
                const state = r.uint() catch return;
                const pressed = state == p.wl_pointer.button_state.pressed;
                if (pressed) {
                    w.press_serial = serial;
                    w.grab_serial = serial;
                    w.clipboard.serial = serial;
                } else {
                    w.press_serial = 0;
                }
                const on_window = w.pointer_surface == w.surface.id or w.pointer_surface == 0;
                if (pressed and button == .left and on_window) {
                    const edges = w.edgesAt(w.pointer_pos);
                    if (edges != 0) if (w.seat) |seat| {
                        var m = w.toplevel.request(p.xdg_toplevel.request.resize) catch return;
                        m.uint(seat.id).uint(serial).uint(edges).end();
                        w.conn.flush() catch {};
                        return;
                    };
                }
                if (pressed and w.buttons_down == 0 and on_window and !w.isInsideContent(w.pointer_pos)) return;
                const bit = @as(u32, 1) << @backingInt(button);
                w.buttons_down = if (pressed) w.buttons_down | bit else w.buttons_down & ~bit;
                if (!pressed and w.buttons_down == 0) w.updateCursor();
                w.pushInput(.{ .button = .{ .pos = w.pointer_pos, .button = button, .pressed = pressed } });
            },
            p.wl_pointer.event.axis => {
                _ = r.uint() catch return;
                const axis = r.uint() catch return;
                const value: f32 = @floatCast(r.fixed() catch return);
                const vertical = axis == p.wl_pointer.axis.vertical_scroll;
                w.pushInput(.{ .scroll = .{ .pos = w.pointer_pos, .dx = if (vertical) 0 else value, .dy = if (vertical) value else 0 } });
            },
            p.wl_pointer.event.leave => {
                w.press_serial = 0;
                w.cursor_shape = null;
                // Sent with the next frame, unless the pointer enters
                // another of the window's surfaces first.
                w.leave_pending = true;
            },
            p.wl_pointer.event.frame => w.flushLeave(),
            else => {},
        }
    }

    fn touchEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_touch.event.down => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const surface = r.uint() catch return;
                const id: i32 = @bitCast(r.uint() catch return);
                if (!w.ownsSurface(surface)) {
                    for (&w.away_touches) |*slot| if (slot.* == null) {
                        slot.* = id;
                        break;
                    };
                    return;
                }
                w.touch_surface = surface;
                const pos = w.toWindow(w.touch_surface, .{ @floatCast(r.fixed() catch return), @floatCast(r.fixed() catch return) });
                w.press_serial = serial;
                w.grab_serial = serial;
                w.clipboard.serial = serial;
                const on_window = w.touch_surface == w.surface.id;
                const edges = if (on_window) w.edgesAt(pos) else 0;
                if (edges != 0) if (w.seat) |seat| {
                    var m = w.toplevel.request(p.xdg_toplevel.request.resize) catch return;
                    m.uint(seat.id).uint(serial).uint(edges).end();
                    w.conn.flush() catch {};
                    return;
                };
                if (on_window and !w.isInsideContent(pos)) return;
                w.pushInput(.{ .touch_down = .{ .id = id, .pos = pos } });
            },
            p.wl_touch.event.motion => {
                _ = r.uint() catch return;
                const id: i32 = @bitCast(r.uint() catch return);
                if (w.touchAway(id, false)) return;
                const pos = w.toWindow(w.touch_surface, .{ @floatCast(r.fixed() catch return), @floatCast(r.fixed() catch return) });
                w.pushInput(.{ .touch_motion = .{ .id = id, .pos = pos } });
            },
            p.wl_touch.event.up => {
                _ = r.uint() catch return;
                _ = r.uint() catch return;
                const id: i32 = @bitCast(r.uint() catch return);
                if (w.touchAway(id, true)) return;
                w.press_serial = 0;
                w.pushInput(.{ .touch_up = id });
            },
            p.wl_touch.event.cancel => {
                w.away_touches = @splat(null);
                w.press_serial = 0;
                w.pushInput(.touch_cancel);
            },
            else => {},
        }
    }

    fn drainKeyboardEvent(_: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        if (opcode == p.wl_keyboard.event.keymap) {
            if (r.fd() catch null) |fd| _ = linux.close(fd);
        }
    }

    pub fn keyboardEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.wl_keyboard.event.keymap => {
                const fd = r.fd() catch return;
                defer _ = linux.close(fd);
                _ = r.uint() catch return;
                const size = r.uint() catch return;
                if (keymapFrom(w.gpa, fd, size)) |km| {
                    if (w.keymap) |*old| old.deinit();
                    w.keymap = km;
                    w.xkb_state = .{};
                    w.compose_state.reset();
                }
            },
            p.wl_keyboard.event.modifiers => {
                _ = r.uint() catch return;
                const depressed = r.uint() catch return;
                const latched = r.uint() catch return;
                const locked = r.uint() catch return;
                const group = r.uint() catch return;
                w.xkb_state = .{ .depressed = depressed, .latched = latched, .locked = locked, .group = group };
            },
            p.wl_keyboard.event.enter => {
                _ = r.uint() catch return;
                w.keyboard_focused = w.ownsSurface(r.uint() catch return);
            },
            p.wl_keyboard.event.key => {
                // Typed in another window.
                if (w.keyboard_focused == false) return;
                const serial = r.uint() catch return;
                _ = r.uint() catch return;
                const code = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = state == p.wl_keyboard.key_state.pressed;
                if (pressed) {
                    w.clipboard.serial = serial;
                    w.grab_serial = serial;
                }
                if (code < 256) w.keys_down.setValue(code, pressed);
                if (pressed) {
                    if (!isModifierKey(code) and w.repeat_rate > 0) {
                        w.repeat = .{
                            .code = code,
                            .next_ns = w.now() + @as(u64, w.repeat_delay_ms) * std.time.ns_per_ms,
                        };
                    }
                } else if (w.repeat) |rep| {
                    if (rep.code == code) w.repeat = null;
                }
                w.pushKey(code, pressed, false);
            },
            p.wl_keyboard.event.leave => {
                _ = r.uint() catch return;
                const surface = r.uint() catch return;
                if (!w.ownsSurface(surface)) return;
                w.keyboard_focused = false;
                w.repeat = null;
                w.compose_state.reset();
                var it = w.keys_down.iterator(.{});
                while (it.next()) |code| {
                    w.pushInput(.{ .key = .{ .key = window_mod.evdev.keyOf(@intCast(code)), .pressed = false } });
                }
                w.keys_down = .empty;
            },
            p.wl_keyboard.event.repeat_info => {
                const rate = r.int() catch return;
                const delay = r.int() catch return;
                w.repeat_rate = @intCast(@max(rate, 0));
                w.repeat_delay_ms = @intCast(@max(delay, 0));
                if (w.repeat_rate == 0) w.repeat = null;
            },
            else => {},
        }
    }

    pub fn isModifierKey(code: u32) bool {
        return switch (code) {
            29, 42, 54, 56, 58, 97, 100, 125, 126 => true,
            else => false,
        };
    }

    fn wmBaseEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode != p.xdg_wm_base.event.ping) return;
        const serial = r.uint() catch return;
        var m = w.wm_base.request(p.xdg_wm_base.request.pong) catch return;
        m.uint(serial).end();
    }

    fn xdgSurfaceEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.xdg_surface.event.configure) w.pending_serial = r.uint() catch return;
    }

    fn toplevelEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.xdg_toplevel.event.configure => {
                w.next_size = .{ r.int() catch 0, r.int() catch 0 };
                const states = r.array() catch &.{};
                var suspended = false;
                var maximized = false;
                var fullscreen = false;
                var tiled = false;
                var i: usize = 0;
                while (i + 4 <= states.len) : (i += 4) switch (std.mem.readInt(u32, states[i..][0..4], .little)) {
                    p.xdg_toplevel.state.suspended => suspended = true,
                    p.xdg_toplevel.state.maximized => maximized = true,
                    p.xdg_toplevel.state.fullscreen => fullscreen = true,
                    p.xdg_toplevel.state.tiled_left,
                    p.xdg_toplevel.state.tiled_right,
                    p.xdg_toplevel.state.tiled_top,
                    p.xdg_toplevel.state.tiled_bottom,
                    => tiled = true,
                    else => {},
                };
                if (suspended) w.repeat = null;
                if (w.maximized != maximized or w.fullscreen != fullscreen or w.tiled != tiled) {
                    w.decoration_changed = true;
                }
                w.suspended = suspended;
                w.maximized = maximized;
                w.fullscreen = fullscreen;
                w.tiled = tiled;
            },
            p.xdg_toplevel.event.close => w.close_requested = true,
            p.xdg_toplevel.event.wm_capabilities => {
                const caps = r.array() catch return;
                w.can_maximize = false;
                w.can_minimize = false;
                w.can_fullscreen = false;
                var i: usize = 0;
                while (i + 4 <= caps.len) : (i += 4) switch (std.mem.readInt(u32, caps[i..][0..4], .little)) {
                    p.xdg_toplevel.wm_capabilities.maximize => w.can_maximize = true,
                    p.xdg_toplevel.wm_capabilities.minimize => w.can_minimize = true,
                    p.xdg_toplevel.wm_capabilities.fullscreen => w.can_fullscreen = true,
                    else => {},
                };
            },
            else => {},
        }
    }

    pub fn decorationEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == p.zxdg_toplevel_decoration_v1.event.configure) {
            const mode = r.uint() catch return;
            const ssd = mode == p.zxdg_toplevel_decoration_v1.mode.server_side;
            if (w.system_decorations != ssd) {
                w.system_decorations = ssd;
                w.decoration_changed = true;
            }
        }
    }

    pub fn dmabufEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *wire.Reader) void {
        const w: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        switch (opcode) {
            p.zwp_linux_dmabuf_v1.event.format => {
                const fmt = r.uint() catch return;
                if (fmt == p.fourcc.argb8888) w.dmabuf_argb8888 = true;
                if (fmt == p.fourcc.xrgb8888) w.dmabuf_xrgb8888 = true;
            },
            p.zwp_linux_dmabuf_v1.event.modifier => {
                const fmt = r.uint() catch return;
                const mod_hi = r.uint() catch return;
                const mod_lo = r.uint() catch return;
                const mod = (@as(u64, mod_hi) << 32) | mod_lo;
                if (mod == p.modifier.linear or mod == 0x00ffffffffffffff) {
                    if (fmt == p.fourcc.argb8888) w.dmabuf_argb8888 = true;
                    if (fmt == p.fourcc.xrgb8888) w.dmabuf_xrgb8888 = true;
                }
            },
            else => {},
        }
    }
};

/// The keymap the compositor sent in `fd` (`size` bytes of text, ending in
/// a nul), if it can be read.
fn keymapFrom(gpa: std.mem.Allocator, fd: linux.fd_t, size: u32) ?xkb.Keymap {
    if (size == 0 or size > 16 << 20) return null;
    const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const text = @as([*]const u8, @ptrFromInt(rc))[0..size];
    defer _ = linux.munmap(text.ptr, size);
    const end = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
    return xkb.Keymap.parse(gpa, text[0..end]) catch null;
}

test "held keys repeat after the delay, except modifiers, and stop on release or leave" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
    };
    var disp: client.Display = undefined;

    const repeat_msg = [_]u32{ 25, 200 };
    var r_info = wire.Reader{ .data = std.mem.sliceAsBytes(&repeat_msg), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.repeat_info, &r_info);
    try std.testing.expectEqual(@as(u32, 25), win.repeat_rate);
    try std.testing.expectEqual(@as(u32, 200), win.repeat_delay_ms);

    const shift_down = [_]u32{ 1, 0, 42, p.wl_keyboard.key_state.pressed };
    var r_shift = wire.Reader{ .data = std.mem.sliceAsBytes(&shift_down), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_shift);
    try std.testing.expect(win.repeat == null);
    _ = win.takeInput();

    const a_down = [_]u32{ 2, 0, 30, p.wl_keyboard.key_state.pressed };
    var r_a_down = wire.Reader{ .data = std.mem.sliceAsBytes(&a_down), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_a_down);
    try std.testing.expectEqual(@as(u32, 30), win.repeat.?.code);
    try std.testing.expectEqual(@as(usize, 1), win.takeInput().len);

    const first_due = win.repeat.?.next_ns;
    win.serviceRepeat(first_due - 1);
    try std.testing.expectEqual(@as(usize, 0), win.takeInput().len);
    try std.testing.expectEqual(@as(?u64, 1), win.repeatTimeoutMs(first_due - 1));

    win.serviceRepeat(first_due);
    const rep1 = win.takeInput();
    try std.testing.expectEqual(@as(usize, 1), rep1.len);
    try std.testing.expectEqual(window_mod.KeyboardKey.a, rep1[0].key.key);
    try std.testing.expect(rep1[0].key.pressed);
    try std.testing.expectEqual(first_due + 40 * std.time.ns_per_ms, win.repeat.?.next_ns);

    const a_up = [_]u32{ 3, 0, 30, p.wl_keyboard.key_state.released };
    var r_a_up = wire.Reader{ .data = std.mem.sliceAsBytes(&a_up), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.key, &r_a_up);
    try std.testing.expect(win.repeat == null);
    _ = win.takeInput();

    const leave_msg = [_]u32{ 4, win.surface.id };
    var r_leave = wire.Reader{ .data = std.mem.sliceAsBytes(&leave_msg), .c = undefined };
    WaylandWindow.keyboardEvent(&win, &disp, 1, p.wl_keyboard.event.leave, &r_leave);
    const left = win.takeInput();
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqual(window_mod.KeyboardKey.left_shift, left[0].key.key);
    try std.testing.expect(!left[0].key.pressed);
}

test "windows on one display heed only what happens on their own surfaces" {
    var disp: client.Display = undefined;
    var wins: [2]WaylandWindow = undefined;
    for (&wins, [_]u32{ 10, 20 }) |*w, id| w.* = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .conn = &disp,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
        .surface = .{ .id = id },
    };
    const send = struct {
        fn f(ws: *[2]WaylandWindow, d: *client.Display, comptime handler: anytype, opcode: u16, words: []const u32) void {
            for (ws) |*w| {
                var r = wire.Reader{ .data = std.mem.sliceAsBytes(words), .c = undefined };
                handler(w, d, 1, opcode, &r);
            }
        }
    }.f;
    // The pointer enters the first window, and moves: only it is told.
    send(&wins, &disp, WaylandWindow.pointerEvent, p.wl_pointer.event.enter, &.{ 1, 10, 5 << 8, 5 << 8 });
    send(&wins, &disp, WaylandWindow.pointerEvent, p.wl_pointer.event.motion, &.{ 2, 6 << 8, 6 << 8 });
    try std.testing.expect(wins[0].takeInput().len > 0);
    try std.testing.expectEqual(@as(usize, 0), wins[1].takeInput().len);
    // The keyboard's focus goes to the second: only it hears the key.
    send(&wins, &disp, WaylandWindow.keyboardEvent, p.wl_keyboard.event.enter, &.{ 3, 20, 0 });
    send(&wins, &disp, WaylandWindow.keyboardEvent, p.wl_keyboard.event.key, &.{ 4, 0, 30, p.wl_keyboard.key_state.pressed });
    try std.testing.expectEqual(@as(usize, 0), wins[0].takeInput().len);
    try std.testing.expectEqual(@as(usize, 1), wins[1].takeInput().len);
    // A touch on the first is not the second's.
    send(&wins, &disp, WaylandWindow.touchEvent, p.wl_touch.event.down, &.{ 5, 0, 10, 7, 1 << 8, 1 << 8 });
    send(&wins, &disp, WaylandWindow.touchEvent, p.wl_touch.event.up, &.{ 6, 0, 7 });
    try std.testing.expectEqual(@as(usize, 0), wins[1].takeInput().len);
}

test "WaylandDisplay routes pointer, keyboard, and touch events to the appropriate window" {
    var disp_conn: client.Display = undefined;
    var d: WaylandDisplay = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .conn = &disp_conn,
    };
    var wins: [2]WaylandWindow = undefined;
    for (&wins, [_]u32{ 10, 20 }) |*w, id| {
        w.* = .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .conn = &disp_conn,
            .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
            .surface = .{ .id = id },
            .display = &d,
            .width = 100,
            .height = 100,
            .system_decorations = true,
        };
        try d.windows.append(std.testing.allocator, w);
    }
    defer d.windows.deinit(std.testing.allocator);

    // Test pointer enter and motion routing:
    var r_enter = wire.Reader{ .data = std.mem.sliceAsBytes(&[_]u32{ 1, 10, 5 << 8, 5 << 8 }), .c = undefined };
    WaylandDisplay.displayPointerEvent(&d, &disp_conn, 1, p.wl_pointer.event.enter, &r_enter);
    try std.testing.expectEqual(&wins[0], d.pointer_window);
    try std.testing.expect(wins[0].takeInput().len > 0);
    try std.testing.expectEqual(@as(usize, 0), wins[1].takeInput().len);

    // Test pointer motion:
    var r_motion = wire.Reader{ .data = std.mem.sliceAsBytes(&[_]u32{ 2, 6 << 8, 6 << 8 }), .c = undefined };
    WaylandDisplay.displayPointerEvent(&d, &disp_conn, 1, p.wl_pointer.event.motion, &r_motion);
    try std.testing.expect(wins[0].takeInput().len > 0);
    try std.testing.expectEqual(@as(usize, 0), wins[1].takeInput().len);

    // Test pointer leave:
    var r_leave = wire.Reader{ .data = std.mem.sliceAsBytes(&[_]u32{ 3, 10 }), .c = undefined };
    WaylandDisplay.displayPointerEvent(&d, &disp_conn, 1, p.wl_pointer.event.leave, &r_leave);
    var r_frame = wire.Reader{ .data = &.{}, .c = undefined };
    WaylandDisplay.displayPointerEvent(&d, &disp_conn, 1, p.wl_pointer.event.frame, &r_frame);
    try std.testing.expectEqual(@as(?*WaylandWindow, null), d.pointer_window);
    const left_events = wins[0].takeInput();
    try std.testing.expectEqual(@as(usize, 1), left_events.len);
    try std.testing.expectEqual(window_mod.InputEvent.leave, left_events[0]);

    // Test keyboard enter and key routing:
    var r_kb_enter = wire.Reader{ .data = std.mem.sliceAsBytes(&[_]u32{ 4, 20 }), .c = undefined };
    WaylandDisplay.displayKeyboardEvent(&d, &disp_conn, 1, p.wl_keyboard.event.enter, &r_kb_enter);
    try std.testing.expectEqual(&wins[1], d.keyboard_window);

    var r_key = wire.Reader{ .data = std.mem.sliceAsBytes(&[_]u32{ 5, 0, 30, p.wl_keyboard.key_state.pressed }), .c = undefined };
    WaylandDisplay.displayKeyboardEvent(&d, &disp_conn, 1, p.wl_keyboard.event.key, &r_key);
    try std.testing.expectEqual(@as(usize, 0), wins[0].takeInput().len);
    const kb_events = wins[1].takeInput();
    try std.testing.expectEqual(@as(usize, 1), kb_events.len);
    try std.testing.expect(kb_events[0].key.pressed);

    // Test touch down and up routing:
    var r_touch_down = wire.Reader{ .data = std.mem.sliceAsBytes(&[_]u32{ 6, 0, 10, 7, 30 << 8, 30 << 8 }), .c = undefined };
    WaylandDisplay.displayTouchEvent(&d, &disp_conn, 1, p.wl_touch.event.down, &r_touch_down);
    try std.testing.expectEqual(@as(usize, 1), wins[0].takeInput().len);
    try std.testing.expectEqual(@as(usize, 0), wins[1].takeInput().len);

    var r_touch_up = wire.Reader{ .data = std.mem.sliceAsBytes(&[_]u32{ 7, 0, 7 }), .c = undefined };
    WaylandDisplay.displayTouchEvent(&d, &disp_conn, 1, p.wl_touch.event.up, &r_touch_up);
    try std.testing.expectEqual(@as(usize, 1), wins[0].takeInput().len);
    try std.testing.expectEqual(@as(usize, 0), wins[1].takeInput().len);
}

test "setMinSize clamps non-maximized window dimensions" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
        .width = 400,
        .height = 300,
        .maximized = false,
        .fullscreen = false,
    };
    // Pre-populate min_size so setMinSize returns before touching the wire connection.
    win.min_size = .{ 640, 480 };
    win.setMinSize(640, 480);
    try std.testing.expectEqual(@as(u32, 640), win.width);
    try std.testing.expectEqual(@as(u32, 480), win.height);
}

test "edgesAt detects resize edges only outside the window content and respects maximized state" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
        .width = 400,
        .height = 300,
        .maximized = false,
        .fullscreen = false,
    };
    // Outer band outside the edges triggers resize.
    try std.testing.expectEqual(@as(u32, edge_left), win.edgesAt(.{ -5, 150 }));
    try std.testing.expectEqual(@as(u32, edge_right), win.edgesAt(.{ 405, 150 }));
    try std.testing.expectEqual(@as(u32, edge_top), win.edgesAt(.{ 200, -5 }));
    try std.testing.expectEqual(@as(u32, edge_bottom), win.edgesAt(.{ 200, 305 }));
    try std.testing.expectEqual(@as(u32, edge_top | edge_left), win.edgesAt(.{ -4, -4 }));
    try std.testing.expectEqual(@as(u32, edge_top | edge_left), win.edgesAt(.{ -4, 10 }));
    // Outside the rounded corner arc at (1, 1) triggers corner resize.
    try std.testing.expectEqual(@as(u32, edge_top | edge_left), win.edgesAt(.{ 1, 1 }));
    // Inside the window content (including 1px inside the border) never triggers resize.
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ 1, 150 }));
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ 398, 150 }));
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ 200, 1 }));
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ 200, 298 }));
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ 200, 150 }));
    // Beyond resize_outset does not trigger resize.
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ -15, 150 }));
    // Maximized, fullscreen, or tiled window has no resize edges and zero frame margin.
    win.maximized = true;
    try std.testing.expect(!win.hasToolkitDecorations());
    try std.testing.expectEqual(@as(u32, 0), win.frameMargin());
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ -5, 150 }));
    win.maximized = false;
    win.tiled = true;
    try std.testing.expect(!win.hasToolkitDecorations());
    try std.testing.expectEqual(@as(u32, 0), win.frameMargin());
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ -5, 150 }));
    // Decorations by the compositor disable the toolkit shadow margin and outer resize edges even when floating.
    win.tiled = false;
    var disp: client.Display = undefined;
    const ssd_msg = [_]u32{p.zxdg_toplevel_decoration_v1.mode.server_side};
    var r_ssd = wire.Reader{ .data = std.mem.sliceAsBytes(&ssd_msg), .c = undefined };
    WaylandWindow.decorationEvent(&win, &disp, 1, p.zxdg_toplevel_decoration_v1.event.configure, &r_ssd);
    try std.testing.expect(win.system_decorations);
    try std.testing.expect(win.decoration_changed);
    try std.testing.expectEqual(window_mod.WindowDecorations.system, win.decorations());
    try std.testing.expect(!win.hasToolkitDecorations());
    try std.testing.expectEqual(@as(u32, 0), win.frameMargin());
    try std.testing.expectEqual(@as(u32, 0), win.edgesAt(.{ -5, 150 }));
}

test "Buffer renders drop shadow margin and rounds window corners while exposing inner content Image" {
    const cw: u32 = 80;
    const ch: u32 = 60;
    const m: u32 = shadow_margin;
    const bw: u32 = cw + 2 * m;
    const bh: u32 = ch + 2 * m;
    const bytes = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), @as(usize, bw) * @as(usize, bh) * 4);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);

    var buf: Buffer = .{
        .pixels = bytes,
        .width = bw,
        .height = bh,
        .content_w = cw,
        .content_h = ch,
        .margin = m,
        .scale = 1,
    };

    var img = buf.image();
    try std.testing.expectEqual(cw, img.width);
    try std.testing.expectEqual(ch, img.height);
    try std.testing.expectEqual(bw, img.rowStride());

    // Clear the content image to opaque white.
    img.clear(0xffffffff);
    buf.renderShadowMargin();
    buf.applyRoundedCorners(null);

    const words = std.mem.bytesAsSlice(u32, bytes);
    // Center of the content area remains opaque white.
    const center = words[@as(usize, m + ch / 2) * bw + (m + cw / 2)];
    try std.testing.expectEqual(@as(u32, 0xffffffff), center);

    // Extreme top-left corner of the content box (outside the 12px radius arc) is clipped to shadow (not white).
    const corner_px = words[@as(usize, m) * bw + m];
    try std.testing.expect((corner_px & 0x00ffffff) == 0);

    // Just below the bottom edge of the window has non-zero drop shadow alpha.
    const shadow_below = words[@as(usize, m + ch + 3) * bw + (m + cw / 2)];
    try std.testing.expect((shadow_below >> 24) > 0);
    try std.testing.expect((shadow_below & 0x00ffffff) == 0);
}

test "WaylandWindow prefers linux_dmabuf over wl_shm when zwp_linux_dmabuf_v1 and DmaBufDevice are available" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
    };
    try std.testing.expectEqual(window_mod.WindowBufferTransport.memory, win.bufferTransport());

    var disp: client.Display = undefined;
    const mod_msg = [_]u32{ p.fourcc.argb8888, 0, 0 };
    var r_mod = wire.Reader{ .data = std.mem.sliceAsBytes(&mod_msg), .c = undefined };
    WaylandWindow.dmabufEvent(&win, &disp, 1, p.zwp_linux_dmabuf_v1.event.modifier, &r_mod);
    try std.testing.expect(win.dmabuf_argb8888);

    const fmt_msg = [_]u32{p.fourcc.xrgb8888};
    var r_fmt = wire.Reader{ .data = std.mem.sliceAsBytes(&fmt_msg), .c = undefined };
    WaylandWindow.dmabufEvent(&win, &disp, 1, p.zwp_linux_dmabuf_v1.event.format, &r_fmt);
    try std.testing.expect(win.dmabuf_xrgb8888);

    if (DmaBufDevice.open()) |dev_val| {
        var dev = dev_val;
        defer dev.close();
        win.dmabuf = .{ .id = 10 };
        win.dmabuf_dev = dev;
        try std.testing.expectEqual(window_mod.WindowBufferTransport.linux_dmabuf, win.bufferTransport());

        const alloc = try dev.alloc(64, 48, p.fourcc.argb8888);
        defer {
            _ = linux.close(alloc.dmabuf_fd);
            dev.gbm.bo_destroy(alloc.bo);
        }
        try std.testing.expect(alloc.dmabuf_fd >= 0);
        try std.testing.expect(alloc.stride >= 64 * 4);
        var buf: Buffer = .{
            .bo = alloc.bo,
            .gbm = dev.gbm,
            .width = 64,
            .height = 48,
            .stride_words = alloc.stride / 4,
        };
        try buf.beginCpuAccess();
        var img = buf.image();
        img.clear(0xff112233);
        try std.testing.expectEqual(@as(u32, 0xff112233), img.at(0, 0));
        buf.endCpuAccess();
    }
}

test "WaylandWindow reports the Wayland extensions offered, synchronization protocols, and presentation refresh rate" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
        .compositor = .{ .id = 2 },
        .shm = .{ .id = 3 },
        .wm_base = .{ .id = 4 },
        .presentation = .{ .id = 5 },
        .fifo_manager = .{ .id = 6 },
        .fifo = .{ .id = 7 },
        .commit_timing_manager = .{ .id = 8 },
        .commit_timer = .{ .id = 9 },
        .drm_syncobj_manager = .{ .id = 10 },
        .syncobj_surface = .{ .id = 11 },
    };
    for ([_][]const u8{ p.xdg_wm_base.name, p.wp_presentation.name, p.wp_fifo_manager_v1.name, p.wp_commit_timing_manager_v1.name, p.wp_linux_drm_syncobj_manager_v1.name }, 1..) |name, id| win.globals.add(@intCast(id), name, 1);
    win.updateExtensions();

    try std.testing.expect(win.vsync);
    try std.testing.expectEqual(window_mod.WindowBufferSync.explicit, win.bufferSync());
    const fs = win.frameSync();
    try std.testing.expect(fs.vsync);
    try std.testing.expect(fs.frame_callback);
    try std.testing.expect(fs.presentation_time);
    try std.testing.expect(fs.fifo);
    try std.testing.expect(fs.timed_presentation);

    const exts = win.waylandExtensions();
    try std.testing.expectEqual(@as(usize, 5), exts.len);
    var has_fifo = false;
    var has_commit_timing = false;
    var has_syncobj = false;
    var has_presentation = false;
    for (exts) |ext| {
        if (std.mem.eql(u8, ext, p.wp_fifo_manager_v1.name)) has_fifo = true;
        if (std.mem.eql(u8, ext, p.wp_commit_timing_manager_v1.name)) has_commit_timing = true;
        if (std.mem.eql(u8, ext, p.wp_linux_drm_syncobj_manager_v1.name)) has_syncobj = true;
        if (std.mem.eql(u8, ext, p.wp_presentation.name)) has_presentation = true;
    }
    try std.testing.expect(has_fifo);
    try std.testing.expect(has_commit_timing);
    try std.testing.expect(has_syncobj);
    try std.testing.expect(has_presentation);

    var disp: client.Display = .{ .gpa = std.testing.allocator, .conn = undefined };
    // Simulate wp_presentation_feedback.presented with 16_666_666 ns refresh (~60 Hz)
    const presented_msg = [_]u32{ 0, 1, 500_000_000, 16_666_666, 0, 1, p.wp_presentation_feedback.kind.vsync };
    var r_pres = wire.Reader{ .data = std.mem.sliceAsBytes(&presented_msg), .c = undefined };
    WaylandWindow.feedbackEvent(&win, &disp, 0, p.wp_presentation_feedback.event.presented, &r_pres);
    try std.testing.expectEqual(@as(u64, 16_666_666), win.refresh_ns);
    const hz = win.refreshHz();
    try std.testing.expect(@abs(hz - 60.0) < 0.1);
}

test "WaylandWindow reports no buffer sync for wl_shm and explicit sync only while it has a syncobj surface" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
    };
    try std.testing.expectEqual(window_mod.WindowBufferSync.none, win.bufferSync());
    win.vsync = false;
    try std.testing.expect(!win.frameSync().vsync);
    try std.testing.expect(!win.frameSync().frame_callback);
    win.syncobj_surface = .{ .id = 11 };
    try std.testing.expectEqual(window_mod.WindowBufferSync.explicit, win.bufferSync());
}

test "xdg_toplevel.wm_capabilities says whether the window can be minimized, maximized and made fullscreen" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
    };
    // Until the compositor says otherwise, it can do everything.
    try std.testing.expect(win.canMinimize() and win.canMaximize() and win.canFullscreen());
    var disp: client.Display = .{ .gpa = std.testing.allocator, .conn = undefined };
    // An array of one capability (fullscreen): 4 bytes long.
    const msg = [_]u32{ 4, p.xdg_toplevel.wm_capabilities.fullscreen };
    var r = wire.Reader{ .data = std.mem.sliceAsBytes(&msg), .c = undefined };
    WaylandWindow.toplevelEvent(&win, &disp, 0, p.xdg_toplevel.event.wm_capabilities, &r);
    try std.testing.expect(!win.canMinimize() and !win.canMaximize());
    try std.testing.expect(win.canFullscreen());
    const both = [_]u32{ 8, p.xdg_toplevel.wm_capabilities.maximize, p.xdg_toplevel.wm_capabilities.minimize };
    r = .{ .data = std.mem.sliceAsBytes(&both), .c = undefined };
    WaylandWindow.toplevelEvent(&win, &disp, 0, p.xdg_toplevel.event.wm_capabilities, &r);
    try std.testing.expect(win.canMinimize() and win.canMaximize());
    try std.testing.expect(!win.canFullscreen());
}

test "a popup's configure places it, input on it is in window coordinates, and popup_done is passed on" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
        .surface = .{ .id = 3 },
    };
    win.popups[0] = .{
        .id = 7,
        .placement = .{ .kind = .menu, .anchor = .{ 10, 10, 1, 1 }, .size = .{ 100, 50 }, .side = .below_right },
        .surface = .{ .id = 20 },
        .xdg_surface = .{ .id = 21 },
        .popup = .{ .id = 22 },
        .scale = 1,
    };
    var disp: client.Display = .{ .gpa = std.testing.allocator, .conn = undefined };
    try std.testing.expect(win.popupPosition(7) == null);
    const configure = [_]u32{ 300, 40, 100, 50 };
    var r = wire.Reader{ .data = std.mem.sliceAsBytes(&configure), .c = undefined };
    WaylandWindow.popupEvent(&win, &disp, 22, p.xdg_popup.event.configure, &r);
    try std.testing.expectEqual([2]i32{ 300, 40 }, win.popupPosition(7).?);
    // On the popup, a position is offset by where the popup is; on the
    // window, by its shadow margin.
    try std.testing.expectEqual([2]f32{ 305, 46 }, win.toWindow(20, .{ 5, 6 }));
    try std.testing.expectEqual(win.surfaceToContent(.{ 5, 6 }), win.toWindow(3, .{ 5, 6 }));
    r = .{ .data = &.{}, .c = undefined };
    WaylandWindow.popupEvent(&win, &disp, 22, p.xdg_popup.event.popup_done, &r);
    const events = win.takeInput();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(u32, 7), events[0].popup_done);
}

test "the window waits through io for the compositor and the sources it watches" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)));
    defer _ = linux.close(fds[1]);
    const disp = try client.Display.fromFd(std.testing.allocator, io, fds[0]);
    defer disp.disconnect();
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = disp,
        .io = io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = io },
    };
    const Got = struct {
        var events: u32 = 0;
        fn handler(_: ?*anyopaque, _: *client.Display, _: u32, _: u16, _: *wire.Reader) void {
            events += 1;
        }
    };
    try disp.setListener(5, .{ .ptr = null, .handler = Got.handler });
    var wake = try window_mod.sys.Wake.create();
    defer wake.deinit();
    win.watch(.ofWake(&wake), true);
    const start = window_mod.nowNs(io);

    // Nothing comes: it waits out the time.
    try win.wait(20 * std.time.ns_per_ms);
    try std.testing.expect(window_mod.nowNs(io) - start >= 15 * std.time.ns_per_ms);
    // A watched source is woken: it returns at once, having read it.
    wake.signal();
    try win.wait(5 * std.time.ns_per_s);
    try std.testing.expect(!wake.drain());
    try std.testing.expectEqual(@as(u32, 0), Got.events);
    // An event comes: it is read and handled.
    const event = [_]u32{ 5, (8 << 16) | 0 };
    try std.testing.expectEqual(@as(usize, 8), linux.write(fds[1], @ptrCast(&event), 8));
    try win.wait(5 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), Got.events);
    try std.testing.expect(window_mod.nowNs(io) - start < std.time.ns_per_s);
    // No longer watched, a wake does not end the wait.
    win.watch(.ofWake(&wake), false);
    wake.signal();
    const later = window_mod.nowNs(io);
    try win.wait(20 * std.time.ns_per_ms);
    try std.testing.expect(window_mod.nowNs(io) - later >= 15 * std.time.ns_per_ms);
}

test "a popup acks each configure, and commits again for one after it shows" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &fds)));
    defer _ = linux.close(fds[1]);
    const disp = try client.Display.fromFd(std.testing.allocator, std.testing.io, fds[0]);
    defer disp.disconnect();
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = disp,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
    };
    win.popups[0] = .{
        .id = 7,
        .placement = .{ .kind = .menu, .anchor = .{ 10, 10, 1, 1 }, .size = .{ 100, 50 }, .side = .below_right },
        .surface = .{ .display = disp, .id = 20 },
        .xdg_surface = .{ .display = disp, .id = 21 },
        .popup = .{ .display = disp, .id = 22 },
        .scale = 1,
    };
    // The requests sent: each an object and opcode (none sent is an error,
    // not a wait).
    const Sent = struct {
        fn read(fd: i32) ![]const [2]u32 {
            const S = struct {
                var buf: [64]u32 = undefined;
                var out: [16][2]u32 = undefined;
            };
            const n = linux.read(fd, @ptrCast(&S.buf), @sizeOf(@TypeOf(S.buf)));
            if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
            const words = S.buf[0 .. n / 4];
            var i: usize = 0;
            var count: usize = 0;
            while (i + 2 <= words.len) : (count += 1) {
                S.out[count] = .{ words[i], words[i + 1] & 0xffff };
                i += (words[i + 1] >> 16) / 4;
            }
            return S.out[0..count];
        }
    };
    const serial = [_]u32{5};
    var r = wire.Reader{ .data = std.mem.sliceAsBytes(&serial), .c = undefined };
    WaylandWindow.popupXdgSurfaceEvent(&win, disp, 21, p.xdg_surface.event.configure, &r);
    try std.testing.expect(win.popups[0].?.configured);
    try disp.flush();
    // Before it shows, a configure is acked, and committed with its first
    // buffer when drawn.
    try std.testing.expectEqualSlices([2]u32, &.{.{ 21, p.xdg_surface.request.ack_configure }}, try Sent.read(fds[1]));
    // Once it shows, it commits again for a later configure, even if
    // nothing it shows changes.
    win.popups[0].?.shown = true;
    r = .{ .data = std.mem.sliceAsBytes(&serial), .c = undefined };
    WaylandWindow.popupXdgSurfaceEvent(&win, disp, 21, p.xdg_surface.event.configure, &r);
    try std.testing.expectEqualSlices([2]u32, &.{ .{ 21, p.xdg_surface.request.ack_configure }, .{ 20, p.wl_surface.request.commit } }, try Sent.read(fds[1]));
}

test "keys type what the keymap says, with the compositor's modifiers at the time" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
    };
    defer win.clipboard.deinit();
    try std.testing.expectEqualStrings("", win.layout().name());
    win.keymap = try xkb.Keymap.parse(std.testing.allocator, xkb.testdata.gb_ru);
    defer win.keymap.?.deinit();
    var disp: client.Display = undefined;
    const send = struct {
        fn f(w: *WaylandWindow, d: *client.Display, opcode: u16, args: []const u32) void {
            var r = wire.Reader{ .data = std.mem.sliceAsBytes(args), .c = undefined };
            WaylandWindow.keyboardEvent(w, d, 0, opcode, &r);
        }
    }.f;
    const ev = p.wl_keyboard.event;
    const pressed = p.wl_keyboard.key_state.pressed;
    const released = p.wl_keyboard.key_state.released;
    // Shift+3 types £: the key comes after the compositor says Shift is
    // down, and the next 3 after it says it is up.
    send(&win, &disp, ev.key, &.{ 1, 0, 42, pressed });
    send(&win, &disp, ev.modifiers, &.{ 2, xkb.shift_mask, 0, 0, 0 });
    send(&win, &disp, ev.key, &.{ 3, 0, 4, pressed });
    send(&win, &disp, ev.key, &.{ 4, 0, 4, released });
    send(&win, &disp, ev.key, &.{ 5, 0, 42, released });
    send(&win, &disp, ev.modifiers, &.{ 6, 0, 0, 0, 0 });
    send(&win, &disp, ev.key, &.{ 7, 0, 4, pressed });
    // The second layout (group), Russian.
    send(&win, &disp, ev.modifiers, &.{ 8, 0, 0, 0, 1 });
    send(&win, &disp, ev.key, &.{ 9, 0, 30, pressed });
    const events = win.takeInput();
    try std.testing.expectEqual(@as(usize, 6), events.len);
    try std.testing.expectEqual(@as(?u21, null), events[0].key.char);
    try std.testing.expectEqual(@as(?u21, '£'), events[1].key.char);
    try std.testing.expect(events[1].key.shift);
    try std.testing.expectEqual(@as(?u21, null), events[2].key.char);
    try std.testing.expectEqual(@as(?u21, '3'), events[4].key.char);
    try std.testing.expect(!events[4].key.shift);
    try std.testing.expectEqual(@as(?u21, 'ф'), events[5].key.char);
    try std.testing.expectEqualStrings("Russian", win.layout().name());
    try std.testing.expectEqualStrings("ru", win.layout().code());
}

test "dead keys and Compose combine with the keys after them" {
    var win: WaylandWindow = .{
        .gpa = std.testing.allocator,
        .conn = undefined,
        .io = std.testing.io,
        .clipboard = .{ .gpa = std.testing.allocator, .io = std.testing.io },
    };
    defer win.clipboard.deinit();
    win.keymap = try xkb.Keymap.parse(std.testing.allocator, xkb.testdata.gb_ru);
    defer win.keymap.?.deinit();
    win.compose_table = try compose.Table.parse(std.testing.allocator,
        \\<dead_grave> <a> : "à"
        \\<Multi_key> <c> <o> : "©"
        \\<Multi_key> <f> <f> : "ff!"
    , .{});
    win.compose_tried = true;
    defer win.compose_table.?.deinit();
    var disp: client.Display = undefined;
    const send = struct {
        fn f(w: *WaylandWindow, d: *client.Display, opcode: u16, args: []const u32) void {
            var r = wire.Reader{ .data = std.mem.sliceAsBytes(args), .c = undefined };
            WaylandWindow.keyboardEvent(w, d, 0, opcode, &r);
        }
    }.f;
    const ev = p.wl_keyboard.event;
    const down = p.wl_keyboard.key_state.pressed;
    const up = p.wl_keyboard.key_state.released;
    const mod5: u32 = 1 << 7;
    // AltGr+# is the UK's dead grave: it types nothing, nor when it
    // repeats, and then a is à.
    send(&win, &disp, ev.modifiers, &.{ 1, mod5, 0, 0, 0 });
    send(&win, &disp, ev.key, &.{ 2, 0, 43, down });
    win.serviceRepeat(window_mod.nowNs(std.testing.io) + 10 * std.time.ns_per_s);
    send(&win, &disp, ev.key, &.{ 3, 0, 43, up });
    send(&win, &disp, ev.modifiers, &.{ 4, 0, 0, 0, 0 });
    send(&win, &disp, ev.key, &.{ 5, 0, 30, down });
    var events = win.takeInput();
    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expectEqual(@as(?u21, null), events[0].key.char);
    try std.testing.expectEqual(@as(?u21, null), events[1].key.char);
    try std.testing.expectEqual(@as(?u21, 'à'), events[3].key.char);
    // A dead key and a key it does not go with: nothing, and the next key
    // types as usual.
    send(&win, &disp, ev.modifiers, &.{ 6, mod5, 0, 0, 0 });
    send(&win, &disp, ev.key, &.{ 7, 0, 43, down });
    send(&win, &disp, ev.modifiers, &.{ 8, 0, 0, 0, 0 });
    send(&win, &disp, ev.key, &.{ 9, 0, 48, down });
    send(&win, &disp, ev.key, &.{ 10, 0, 48, down });
    events = win.takeInput();
    try std.testing.expectEqual(@as(?u21, null), events[1].key.char);
    try std.testing.expectEqual(@as(?u21, 'b'), events[2].key.char);
    // Several characters come as text after the key. (Compose is fed as a
    // keysym here: the UK keymap has no Compose key.)
    _ = win.compose_state.feed(&win.compose_table.?, compose.multi_key);
    send(&win, &disp, ev.key, &.{ 11, 0, 33, down });
    send(&win, &disp, ev.key, &.{ 12, 0, 33, down });
    events = win.takeInput();
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(@as(?u21, null), events[1].key.char);
    try std.testing.expectEqualStrings("ff!", events[2].text_commit.slice());
    // Leaving the window ends a sequence.
    _ = win.compose_state.feed(&win.compose_table.?, compose.multi_key);
    send(&win, &disp, ev.leave, &.{ 13, 0 });
    try std.testing.expect(!win.compose_state.composing());
}

test "Linux button codes are the pointer buttons" {
    const PointerButton = window_mod.PointerButton;
    try std.testing.expectEqual(PointerButton.left, pointerButtonOf(p.input.btn_left));
    try std.testing.expectEqual(PointerButton.right, pointerButtonOf(p.input.btn_right));
    try std.testing.expectEqual(PointerButton.middle, pointerButtonOf(p.input.btn_middle));
    // Both codes a mouse's side buttons are known by.
    try std.testing.expectEqual(PointerButton.back, pointerButtonOf(p.input.btn_side));
    try std.testing.expectEqual(PointerButton.back, pointerButtonOf(p.input.btn_back));
    try std.testing.expectEqual(PointerButton.forward, pointerButtonOf(p.input.btn_extra));
    try std.testing.expectEqual(PointerButton.forward, pointerButtonOf(p.input.btn_forward));
    try std.testing.expectEqual(PointerButton.other, pointerButtonOf(0x117));
}
