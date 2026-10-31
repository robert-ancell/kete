//! Metal rendering backend for Kete's 2D `Canvas`, on macOS: the canvas's
//! batches drawn on the GPU with the shaders in `shaders/canvas.metal`
//! (compiled when the renderer starts), its glyph atlas and images in
//! textures.
//!
//! In a window (`renderMetal`) a frame is drawn into a texture the renderer
//! keeps, only where it changed, and then copied into the next drawable of
//! the window's `CAMetalLayer` and presented: no copy through the CPU. It
//! can also draw into an image on the CPU (`record`, as the OpenGL and
//! Vulkan renderers do), by way of a texture.
//!
//! `OffscreenContext` draws 3D scenes (for `MetalArea`): with pipelines of
//! the scene's own shaders, vertex and index buffers, and uniforms, into
//! the renderer's frame on the GPU when it shares the renderer's device,
//! or else into an image on the CPU.
//!
//! Metal is loaded at run time (with the Objective-C runtime, `objc.zig`),
//! so nothing is needed to build it.
//!
//!     var mtl = try gfx.MetalRenderer.initDefault(gpa);
//!     defer mtl.deinit();
//!     ui.attachRenderer(mtl.renderer(), false);

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");
const atlas_mod = @import("atlas.zig");
const renderer_mod = @import("renderer.zig");
const software = @import("software.zig");

const Id = objc.Id;
const msg = objc.msg;
const Canvas = canvas_mod.Canvas;
const Viewport = renderer_mod.Viewport;
const Segment = renderer_mod.Segment;
const MetalTarget = renderer_mod.MetalTarget;
const GpuArea = renderer_mod.GpuArea;
const Color = canvas_mod.Color;

// Metal's constants.
const format_r8: u64 = 10; // MTLPixelFormatR8Unorm
const format_bgra8: u64 = 80; // MTLPixelFormatBGRA8Unorm
const usage_read: u64 = 1; // MTLTextureUsageShaderRead
const usage_render: u64 = 4; // MTLTextureUsageRenderTarget
const format_depth: u64 = 252; // MTLPixelFormatDepth32Float
const storage_private: u64 = 2;
/// Where textures the CPU reads or writes are kept: in memory both share
/// on Apple's GPUs; on others, a copy on each (kept in step by Metal).
const storage_cpu: u64 = if (builtin.cpu.arch == .aarch64) 0 else 1; // Shared, Managed
const managed = storage_cpu == 1;
/// Vertex buffers, written by the CPU only.
const buffer_options: u64 = 1; // MTLResourceCPUCacheModeWriteCombined (shared)
const load_load: u64 = 1;
const store_store: u64 = 1;
const triangles: u64 = 3;

const Origin = extern struct { x: u64, y: u64, z: u64 = 0 };
const Size = extern struct { width: u64, height: u64, depth: u64 = 1 };
const Region = extern struct { origin: Origin, size: Size };
const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
const ScissorRect = extern struct { x: u64, y: u64, width: u64, height: u64 };
const MtlViewport = extern struct { x: f64, y: f64, width: f64, height: f64, znear: f64, zfar: f64 };

fn regionOf(v: Viewport) Region {
    return .{ .origin = .{ .x = @intCast(v.x), .y = @intCast(v.y) }, .size = .{ .width = v.width, .height = v.height } };
}

/// Room in each frame's vertex buffer for the quads that clear.
const clear_bytes = renderer_mod.max_uncovered * 6 * shaders.solid_floats * 4 + 16;

pub const MetalRenderer = struct {
    gpa: std.mem.Allocator,
    device: Id,
    queue: Id,
    pipelines: Pipelines = .{},
    nearest: Id = null,
    linear: Id = null,
    /// A vertex buffer for each frame that may be on the GPU at once, and
    /// the work drawing it (waited for before it is written again).
    slots: [3]Slot = @splat(.{}),
    slot: usize = 0,
    cursor: usize = 0,
    atlas_tex: Id = null,
    atlas: ?*atlas_mod.Atlas = null,
    atlas_stale: ?atlas_mod.Rect = null,
    images: std.AutoHashMapUnmanaged(u64, Id) = .empty,
    image_use: renderer_mod.ImageUse = .{},
    /// The windows' frames (each kept from one to the next, so only what
    /// changed is drawn), by the layer each is shown in, and the texture
    /// `record` draws in for the CPU.
    screens: [renderer_mod.max_screens]Screen = @splat(.{}),
    screens_used: u64 = 0,
    offscreen: Frame = .{},
    /// A frame's pixels on the CPU, for GPU draws of widgets drawn there.
    scratch: std.ArrayList(u32) = .empty,

    const Pipelines = struct {
        shape: Id = null,
        solid: Id = null,
        @"opaque": Id = null,
        text: Id = null,
        image: Id = null,
    };

    const Slot = struct {
        buffer: Id = null,
        capacity: usize = 0,
        cmd: Id = null,
    };

    const Frame = struct {
        tex: Id = null,
        width: u32 = 0,
        height: u32 = 0,
    };

    /// A window's frame, and when it was last drawn (`screens_used`).
    const Screen = struct {
        key: ?*anyopaque = null,
        frame: Frame = .{},
        used: u64 = 0,
    };

    pub const backend: renderer_mod.RenderBackend = .metal;

    /// The system's default GPU, its shaders compiled; an error if there
    /// is none (or this is not macOS).
    pub fn initDefault(gpa: std.mem.Allocator) !MetalRenderer {
        if (builtin.os.tag != .macos) return error.Unsupported;
        try objc.load();
        const pool = objc.push();
        defer objc.pop(pool);
        const create = objc.symbol(*const fn () callconv(.c) Id, "MTLCreateSystemDefaultDevice") orelse return error.NoMetal;
        const device = create() orelse return error.NoMetalDevice;
        var r: MetalRenderer = .{ .gpa = gpa, .device = device, .queue = msg(Id, device, "newCommandQueue", .{}) };
        errdefer r.deinit();
        if (r.queue == null) return error.NoMetalQueue;

        var err: Id = null;
        const lib = msg(Id, device, "newLibraryWithSource:options:error:", .{ objc.nsString(shaders.msl), @as(Id, null), &err });
        if (lib == null) {
            logError("compiling the shaders", err);
            return error.MetalShaderFailed;
        }
        defer objc.release(lib);
        r.pipelines = .{
            .shape = try r.pipeline(lib, "shape_vs", "shape_fs", true),
            .solid = try r.pipeline(lib, "solid_vs", "solid_fs", true),
            .@"opaque" = try r.pipeline(lib, "solid_vs", "solid_fs", false),
            .text = try r.pipeline(lib, "text_vs", "text_fs", true),
            .image = try r.pipeline(lib, "text_vs", "image_fs", true),
        };
        r.nearest = r.sampler(0);
        r.linear = r.sampler(1);
        if (r.nearest == null or r.linear == null) return error.MetalSamplerFailed;
        return r;
    }

    pub fn deinit(r: *MetalRenderer) void {
        if (r.device == null) return;
        const pool = objc.push();
        defer objc.pop(pool);
        r.waitIdle();
        for (&r.slots) |*s| objc.release(s.buffer);
        var it = r.images.valueIterator();
        while (it.next()) |tex| objc.release(tex.*);
        r.images.deinit(r.gpa);
        r.image_use.deinit(r.gpa);
        r.scratch.deinit(r.gpa);
        inline for (@typeInfo(Pipelines).@"struct".field_names) |name| objc.release(@field(r.pipelines, name));
        for (&r.screens) |*sc| objc.release(sc.frame.tex);
        for ([_]Id{ r.nearest, r.linear, r.atlas_tex, r.offscreen.tex, r.queue, r.device }) |o| objc.release(o);
        r.device = null;
    }

    pub fn renderer(r: *MetalRenderer) renderer_mod.Renderer {
        return .of(r);
    }

    /// The renderer's GPU, for 3D scenes drawn straight into its frames
    /// (`OffscreenContext.initShared`).
    pub fn sharedDevice(r: *const MetalRenderer) SharedDevice {
        return .{ .device = r.device, .queue = r.queue };
    }

    fn logError(what: []const u8, err: Id) void {
        const text = if (err == null) "" else objc.utf8(msg(Id, err, "localizedDescription", .{}));
        std.log.scoped(.metal).warn("{s}: {s}", .{ what, text });
    }

    fn pipeline(r: *MetalRenderer, lib: Id, vs: [:0]const u8, fs: [:0]const u8, blend: bool) !Id {
        const desc = objc.new(objc.class("MTLRenderPipelineDescriptor"));
        defer objc.release(desc);
        const v = msg(Id, lib, "newFunctionWithName:", .{objc.nsString(vs)});
        defer objc.release(v);
        const f = msg(Id, lib, "newFunctionWithName:", .{objc.nsString(fs)});
        defer objc.release(f);
        if (v == null or f == null) return error.MetalShaderFailed;
        msg(void, desc, "setVertexFunction:", .{v});
        msg(void, desc, "setFragmentFunction:", .{f});
        const att = msg(Id, msg(Id, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(u64, 0)});
        msg(void, att, "setPixelFormat:", .{format_bgra8});
        if (blend) {
            // Source over, as the other renderers: colours not
            // premultiplied, the alpha kept for what is drawn over.
            msg(void, att, "setBlendingEnabled:", .{objc.yes});
            msg(void, att, "setSourceRGBBlendFactor:", .{@as(u64, 4)}); // SourceAlpha
            msg(void, att, "setDestinationRGBBlendFactor:", .{@as(u64, 5)}); // OneMinusSourceAlpha
            msg(void, att, "setSourceAlphaBlendFactor:", .{@as(u64, 1)}); // One
            msg(void, att, "setDestinationAlphaBlendFactor:", .{@as(u64, 5)});
        }
        var err: Id = null;
        const p = msg(Id, r.device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err });
        if (p == null) {
            logError("making a pipeline", err);
            return error.MetalPipelineFailed;
        }
        return p;
    }

    /// A sampler, nearest (0) or linear (1), clamped to the edges.
    fn sampler(r: *MetalRenderer, filter: u64) Id {
        const desc = objc.new(objc.class("MTLSamplerDescriptor"));
        defer objc.release(desc);
        msg(void, desc, "setMinFilter:", .{filter});
        msg(void, desc, "setMagFilter:", .{filter});
        msg(void, desc, "setSAddressMode:", .{@as(u64, 0)});
        msg(void, desc, "setTAddressMode:", .{@as(u64, 0)});
        return msg(Id, r.device, "newSamplerStateWithDescriptor:", .{desc});
    }

    fn texture(r: *MetalRenderer, format: u64, width: u32, height: u32, usage: u64) !Id {
        const desc = msg(Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ format, @as(u64, width), @as(u64, height), objc.no });
        msg(void, desc, "setUsage:", .{usage});
        msg(void, desc, "setStorageMode:", .{storage_cpu});
        return msg(Id, r.device, "newTextureWithDescriptor:", .{desc}) orelse error.MetalTextureFailed;
    }

    // --- Work on the GPU ------------------------------------------------------------

    fn waitSlot(s: *Slot) void {
        const cmd = s.cmd orelse return;
        msg(void, cmd, "waitUntilCompleted", .{});
        objc.release(cmd);
        s.cmd = null;
    }

    /// Waits until the GPU has done all it was given.
    fn waitIdle(r: *MetalRenderer) void {
        for (&r.slots) |*s| waitSlot(s);
    }

    fn commandBuffer(r: *MetalRenderer) !Id {
        return msg(Id, r.queue, "commandBuffer", .{}) orelse error.MetalCommandBufferFailed;
    }

    /// A render pass drawing over what `tex` has.
    fn beginPass(cmd: Id, tex: Id, width: u32, height: u32) !Id {
        const pass = msg(Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const att = msg(Id, msg(Id, pass, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(u64, 0)});
        msg(void, att, "setTexture:", .{tex});
        msg(void, att, "setLoadAction:", .{load_load});
        msg(void, att, "setStoreAction:", .{store_store});
        const enc = msg(Id, cmd, "renderCommandEncoderWithDescriptor:", .{pass}) orelse return error.MetalEncoderFailed;
        msg(void, enc, "setViewport:", .{MtlViewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .znear = 0, .zfar = 1 }});
        return enc;
    }

    /// Commits `cmd` and waits for it, `frame`'s texture then readable on
    /// the CPU.
    fn finishForCpu(cmd: Id, frame: *const Frame) void {
        if (managed) {
            const blit = msg(Id, cmd, "blitCommandEncoder", .{});
            msg(void, blit, "synchronizeResource:", .{frame.tex});
            msg(void, blit, "endEncoding", .{});
        }
        msg(void, cmd, "commit", .{});
        msg(void, cmd, "waitUntilCompleted", .{});
    }

    /// Makes `frame` `width` by `height`; true if it is new (and so has
    /// nothing in it yet).
    /// The frame kept for the window shown in `layer` (the longest unused
    /// window's let go, for one new).
    fn screenOf(r: *MetalRenderer, layer: *anyopaque) *Frame {
        r.screens_used += 1;
        var pick = &r.screens[0];
        for (&r.screens) |*sc| {
            if (sc.key == layer) {
                sc.used = r.screens_used;
                return &sc.frame;
            }
            if (sc.used < pick.used) pick = sc;
        }
        objc.release(pick.frame.tex);
        pick.* = .{ .key = layer, .used = r.screens_used };
        return &pick.frame;
    }

    fn ensureFrame(r: *MetalRenderer, frame: *Frame, width: u32, height: u32) !bool {
        if (frame.tex != null and frame.width == width and frame.height == height) return false;
        objc.release(frame.tex);
        frame.* = .{};
        frame.tex = try r.texture(format_bgra8, width, height, usage_read | usage_render);
        frame.width = width;
        frame.height = height;
        return true;
    }

    // --- Preparing a frame ------------------------------------------------------------

    /// Makes room for the frame's vertices (in a buffer the GPU has done
    /// with), and uploads the glyph atlas's new rows and new images.
    pub fn prepare(r: *MetalRenderer, canvases: []const *const Canvas) !void {
        const pool = objc.push();
        defer objc.pop(pool);
        r.slot = (r.slot + 1) % r.slots.len;
        const s = &r.slots[r.slot];
        waitSlot(s);
        var bytes: usize = clear_bytes;
        for (canvases) |c| for (c.batches.items) |*b| {
            bytes += std.mem.alignForward(usize, b.floats.items.len * 4, 16);
        };
        if (bytes > s.capacity) {
            objc.release(s.buffer);
            s.* = .{};
            const capacity = std.mem.alignForward(usize, bytes * 2, 64 * 1024);
            s.buffer = msg(Id, r.device, "newBufferWithLength:options:", .{ @as(u64, capacity), buffer_options }) orelse return error.MetalBufferFailed;
            s.capacity = capacity;
        }
        r.cursor = 0;
        for (canvases) |c| if (c.atlas) |a| try r.uploadAtlas(a);
        try r.uploadImages(canvases);
    }

    fn uploadAtlas(r: *MetalRenderer, a: *atlas_mod.Atlas) !void {
        const w = atlas_mod.width;
        const h = atlas_mod.height;
        const all: atlas_mod.Rect = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
        if (r.atlas_tex == null) {
            r.atlas_tex = try r.texture(format_r8, w, h, usage_read);
            r.atlas_stale = all;
        }
        if (r.atlas != a) {
            r.atlas = a;
            a.dirty = all;
        }
        if (a.dirty) |d| {
            r.atlas_stale = if (r.atlas_stale) |old|
                .{ .x0 = @min(old.x0, d.x0), .y0 = @min(old.y0, d.y0), .x1 = @max(old.x1, d.x1), .y1 = @max(old.y1, d.y1) }
            else
                d;
            a.dirty = null;
        }
        const d = r.atlas_stale orelse return;
        r.atlas_stale = null;
        const y0: u32 = d.y0;
        const y1: u32 = @min(d.y1, h);
        if (y1 <= y0) return;
        // Not while a frame drawing with it is on the GPU.
        r.waitIdle();
        const region = regionOf(.{ .x = 0, .y = @intCast(y0), .width = w, .height = y1 - y0 });
        msg(void, r.atlas_tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ region, @as(u64, 0), a.pixels[y0 * w ..].ptr, @as(u64, w) });
    }

    fn uploadImages(r: *MetalRenderer, canvases: []const *const Canvas) !void {
        // Those no window draws any more go (the GPU keeps them while it uses them).
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(r.gpa);
        try r.image_use.update(r.gpa, canvases, &stale);
        for (stale.items) |id| if (r.images.fetchRemove(id)) |e| objc.release(e.value);

        for (canvases) |c| for (c.batches.items) |*b| {
            const img = b.image orelse continue;
            if (r.images.contains(img.id) or img.width == 0 or img.height == 0) continue;
            // 0xAARRGGBB, little-endian: BGRA in memory, as the texture is.
            const tex = try r.texture(format_bgra8, img.width, img.height, usage_read);
            const region = regionOf(.{ .width = img.width, .height = img.height });
            msg(void, tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ region, @as(u64, 0), img.pixels.ptr, @as(u64, img.width) * 4 });
            try r.images.put(r.gpa, img.id, tex);
        };
    }

    // --- Drawing ----------------------------------------------------------------------

    /// Room for `len` bytes of vertices in this frame's buffer: where they
    /// go, and their offset in it.
    fn vertices(r: *MetalRenderer, len: usize) !struct { bytes: []u8, offset: u64 } {
        const s = &r.slots[r.slot];
        if (s.buffer == null or r.cursor + len > s.capacity) return error.NotPrepared;
        const base: [*]u8 = @ptrCast(msg(?*anyopaque, s.buffer, "contents", .{}) orelse return error.NotPrepared);
        const offset = r.cursor;
        r.cursor += std.mem.alignForward(usize, len, 16);
        return .{ .bytes = base[offset..][0..len], .offset = offset };
    }

    fn scissor(enc: Id, v: Viewport) void {
        msg(void, enc, "setScissorRect:", .{ScissorRect{ .x = @intCast(v.x), .y = @intCast(v.y), .width = v.width, .height = v.height }});
    }

    /// Fills `rects` (within `full`) with `color` (ARGB), as they are.
    fn encodeClear(r: *MetalRenderer, enc: Id, full: Viewport, color: u32, rects: []const Viewport) !void {
        var n: usize = 0;
        for (rects) |cr| {
            if (full.intersect(cr) != null) n += 1;
        }
        if (n == 0) return;
        n = @min(n, renderer_mod.max_uncovered);
        const per_rect = 6 * shaders.solid_floats;
        const v = try r.vertices(n * per_rect * 4);
        const floats: []align(1) f32 = std.mem.bytesAsSlice(f32, v.bytes);
        const rgba: [4]f32 = .{
            @as(f32, @floatFromInt((color >> 16) & 0xff)) / 255,
            @as(f32, @floatFromInt((color >> 8) & 0xff)) / 255,
            @as(f32, @floatFromInt(color & 0xff)) / 255,
            @as(f32, @floatFromInt(color >> 24)) / 255,
        };
        const fw: f32 = @floatFromInt(full.width);
        const fh: f32 = @floatFromInt(full.height);
        var i: usize = 0;
        for (rects) |cr| {
            const c = full.intersect(cr) orelse continue;
            if (i == n) break;
            const x0 = @as(f32, @floatFromInt(c.x)) / fw * 2 - 1;
            const x1 = @as(f32, @floatFromInt(c.x + @as(i32, @intCast(c.width)))) / fw * 2 - 1;
            const y0 = 1 - @as(f32, @floatFromInt(c.y)) / fh * 2;
            const y1 = 1 - @as(f32, @floatFromInt(c.y + @as(i32, @intCast(c.height)))) / fh * 2;
            const corners = [6][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y0 }, .{ x1, y1 }, .{ x0, y1 } };
            for (corners, 0..) |p, k| {
                const at = i * per_rect + k * shaders.solid_floats;
                floats[at + 0] = p[0];
                floats[at + 1] = p[1];
                for (rgba, 0..) |ch, j| floats[at + 2 + j] = ch;
            }
            i += 1;
        }
        msg(void, enc, "setRenderPipelineState:", .{r.pipelines.@"opaque"});
        msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ r.slots[r.slot].buffer, v.offset, @as(u64, 0) });
        scissor(enc, full);
        msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ triangles, @as(u64, 0), @as(u64, n * 6) });
    }

    /// Draws a prepared canvas's batches with `enc` (into a target `full`
    /// in size), within `damage` (all of it if null).
    fn encode(r: *MetalRenderer, enc: Id, c: *const Canvas, full: Viewport, damage: ?[]const Viewport) !void {
        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            if (!renderer_mod.covers(damage, renderer_mod.scissor(area))) continue;
            const clip_vp = (if (b.clip) |clip| renderer_mod.scissor(clip) else full).intersect(full) orelse continue;

            const pipe = switch (b.kind) {
                .shape => r.pipelines.shape,
                .solid => r.pipelines.solid,
                .@"opaque" => r.pipelines.@"opaque",
                .text => r.pipelines.text,
                .image => r.pipelines.image,
            };
            const tex: Id, const smp: Id = switch (b.kind) {
                .text => .{ r.atlas_tex orelse continue, r.nearest },
                .image => .{ r.images.get((b.image orelse continue).id) orelse return error.NotPrepared, r.linear },
                else => .{ null, null },
            };

            const v = try r.vertices(data.len);
            @memcpy(v.bytes, data);
            msg(void, enc, "setRenderPipelineState:", .{pipe});
            msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ r.slots[r.slot].buffer, v.offset, @as(u64, 0) });
            if (tex != null) {
                msg(void, enc, "setFragmentTexture:atIndex:", .{ tex, @as(u64, 0) });
                msg(void, enc, "setFragmentSamplerState:atIndex:", .{ smp, @as(u64, 0) });
            }
            const count: u64 = b.vertexCount();
            if (damage) |list| {
                for (list) |d| {
                    const sc = clip_vp.intersect(d) orelse continue;
                    scissor(enc, sc);
                    msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ triangles, @as(u64, 0), count });
                }
            } else {
                scissor(enc, clip_vp);
                msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ triangles, @as(u64, 0), count });
            }
        }
    }

    /// Copies `region` of `img` into `frame`'s texture.
    fn upload(frame: *const Frame, img: software.Image, region: Viewport) void {
        const stride = img.rowStride();
        const at = @as(usize, @intCast(region.y)) * stride + @as(usize, @intCast(region.x));
        msg(void, frame.tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ regionOf(region), @as(u64, 0), img.pixels[at..].ptr, @as(u64, stride) * 4 });
    }

    /// Copies `region` of `frame`'s texture into `img` (the GPU done with
    /// it, see `finishForCpu`).
    fn download(frame: *const Frame, img: software.Image, region: Viewport) void {
        const stride = img.rowStride();
        const at = @as(usize, @intCast(region.y)) * stride + @as(usize, @intCast(region.x));
        msg(void, frame.tex, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{ img.pixels[at..].ptr, @as(u64, stride) * 4, regionOf(region), @as(u64, 0) });
    }

    /// Renders a prepared 2D `Canvas` into `target: *software.Image`,
    /// keeping what is there and clipping to `damage` viewports when
    /// provided (by way of a texture: copied in, drawn on, copied back).
    pub fn record(r: *MetalRenderer, c: *const Canvas, target: *software.Image, damage: ?[]const Viewport) !void {
        if (target.width == 0 or target.height == 0) return;
        var has_work = false;
        for (c.batches.items) |*b| {
            if (b.floats.items.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            if (renderer_mod.covers(damage, renderer_mod.scissor(area))) {
                has_work = true;
                break;
            }
        }
        if (!has_work) return;
        const pool = objc.push();
        defer objc.pop(pool);
        _ = try r.ensureFrame(&r.offscreen, target.width, target.height);
        const full: Viewport = .{ .width = target.width, .height = target.height };
        const all = [1]Viewport{full};
        const regions = damage orelse &all;
        for (regions) |reg| if (full.intersect(reg)) |sc| upload(&r.offscreen, target.*, sc);
        const cmd = try r.commandBuffer();
        const enc = try beginPass(cmd, r.offscreen.tex, target.width, target.height);
        try r.encode(enc, c, full, damage);
        msg(void, enc, "endEncoding", .{});
        finishForCpu(cmd, &r.offscreen);
        for (regions) |reg| if (full.intersect(reg)) |sc| download(&r.offscreen, target.*, sc);
    }

    /// Renders a frame into the window's Metal layer (see
    /// `Renderer.renderMetal`): into the frame kept from the last, only
    /// within `damage` (all of it, if the frame is new), and that copied
    /// into the layer's next drawable and presented.
    pub fn renderMetal(r: *MetalRenderer, canvases: []const *const Canvas, segments: []const Segment, t: *const MetalTarget, clear: u32, clear_rects: []const Viewport, damage: []const Viewport) !void {
        if (t.width == 0 or t.height == 0) return;
        const pool = objc.push();
        defer objc.pop(pool);
        const layer: Id = t.layer;
        if (msg(Id, layer, "device", .{}) != r.device) {
            msg(void, layer, "setDevice:", .{r.device});
            msg(void, layer, "setPixelFormat:", .{format_bgra8});
            // Copied into, not only drawn in.
            msg(void, layer, "setFramebufferOnly:", .{objc.no});
        }
        try r.prepare(canvases);
        const screen = r.screenOf(t.layer);
        const fresh = try r.ensureFrame(screen, t.width, t.height);
        const full: Viewport = .{ .width = t.width, .height = t.height };
        const all = [1]Viewport{full};
        var clear_buf: [2][renderer_mod.max_uncovered]Viewport = undefined;
        const dmg: []const Viewport = if (fresh) &all else damage;
        const clears = if (fresh) renderer_mod.uncovered(&clear_buf, &all, segments) else clear_rects;

        var cmd = try r.commandBuffer();
        var enc = try beginPass(cmd, screen.tex, t.width, t.height);
        try r.encodeClear(enc, full, clear, clears);
        var buf: [2][renderer_mod.max_uncovered]Viewport = undefined;
        for (segments, 0..) |seg, i| switch (seg) {
            .canvas => |c| {
                // Not under a GPU draw that covers it (as `Renderer.render`).
                const d = renderer_mod.uncovered(&buf, dmg, segments[i + 1 ..]);
                if (d.len == 0) continue;
                try r.encode(enc, c, full, d);
            },
            .gpu => |g| {
                const area = full.intersect(g.area.scissor orelse g.area.viewport) orelse continue;
                if (!renderer_mod.covers(dmg, area)) continue;
                if (g.direct) |direct| {
                    // Drawn into this frame, on this GPU: no copy through
                    // the CPU.
                    msg(void, enc, "endEncoding", .{});
                    const frame: DirectFrame = .{ .device = r.device, .cmd = cmd, .texture = screen.tex, .width = t.width, .height = t.height };
                    const drawn = try direct(g.ctx, .metal, &frame, g.area);
                    enc = try beginPass(cmd, screen.tex, t.width, t.height);
                    if (drawn) continue;
                }
                // Drawn on the CPU: what is under it is finished first, and
                // what is over it drawn after.
                msg(void, enc, "endEncoding", .{});
                finishForCpu(cmd, screen);
                try r.scratch.resize(r.gpa, @as(usize, t.width) * t.height);
                var img: software.Image = .{ .pixels = r.scratch.items, .width = t.width, .height = t.height };
                download(screen, img, area);
                try g.f(g.ctx, @ptrCast(&img), g.area);
                upload(screen, img, area);
                cmd = try r.commandBuffer();
                enc = try beginPass(cmd, screen.tex, t.width, t.height);
            },
        };
        msg(void, enc, "endEncoding", .{});

        // Into the window. If there is no drawable to be had, the frame is
        // kept, and shown with the next.
        if (msg(Id, layer, "nextDrawable", .{})) |drawable| {
            const dst = msg(Id, drawable, "texture", .{});
            const w = @min(t.width, msg(u64, dst, "width", .{}));
            const h = @min(t.height, msg(u64, dst, "height", .{}));
            const blit = msg(Id, cmd, "blitCommandEncoder", .{});
            msg(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
                screen.tex, @as(u64, 0), @as(u64, 0), Origin{ .x = 0, .y = 0 }, Size{ .width = w, .height = h }, dst, @as(u64, 0), @as(u64, 0), Origin{ .x = 0, .y = 0 },
            });
            msg(void, blit, "endEncoding", .{});
            if (msg(objc.Bool, layer, "presentsWithTransaction", .{}) != 0) {
                // Shown in the window's transaction (as it is resized):
                // once the GPU has it.
                msg(void, cmd, "commit", .{});
                msg(void, cmd, "waitUntilScheduled", .{});
                msg(void, drawable, "present", .{});
                r.slots[r.slot].cmd = objc.retain(cmd);
                return;
            }
            msg(void, cmd, "presentDrawable:", .{drawable});
        }
        msg(void, cmd, "commit", .{});
        r.slots[r.slot].cmd = objc.retain(cmd);
    }
};

/// The GPU (and its queue) of a `MetalRenderer`, to draw scenes on.
pub const SharedDevice = struct {
    device: Id,
    queue: Id,
};

/// A frame the Metal renderer is drawing into a window, given to a 3D
/// scene's `GpuDraw.direct` (with `.metal`) to draw into on the GPU.
pub const DirectFrame = struct {
    device: Id,
    /// The command buffer the frame is drawn with: what is encoded into it
    /// is drawn after what is under it, and before what is over it.
    cmd: Id,
    /// The frame's texture (BGRA8), `width` by `height`.
    texture: Id,
    width: u32,
    height: u32,
};

/// Draws 3D scenes with Metal (for `MetalArea`): into a multisampled
/// colour texture with depth, resolved and copied into the renderer's frame
/// on the GPU (`renderToFrame`), or into an image on the CPU
/// (`renderToImage`). A scene makes pipelines of its own shaders in the
/// Metal Shading Language (`createPipeline`), and buffers, and draws with
/// them in its `render`:
///
///     ctx.bindPipeline(s.pipeline);
///     ctx.setUniforms(Uniforms, &uniforms);
///     ctx.bindVertexBuffer(s.vbo);
///     ctx.bindIndexBuffer16(s.ibo);
///     ctx.drawIndexed(36);
/// GPU work that a scene waits for before it is drawn (as its `wait`): done
/// once `event`, an `MTLEvent` or `MTLSharedEvent` of the scene's device
/// (signalled by a command buffer of the app's, say), reaches `value`.
pub const Wait = struct {
    event: Id,
    value: u64,
};

pub const OffscreenContext = struct {
    gpa: std.mem.Allocator,
    device: Id,
    queue: Id,
    /// Whether the device and queue are its own (not the renderer's).
    owned: bool,
    depth_on: Id = null,
    depth_off: Id = null,
    /// What a scene is drawn in: the multisampled colour (if more than one
    /// sample) and depth, and the colour resolved; their size and samples.
    msaa_tex: Id = null,
    depth_tex: Id = null,
    resolve: MetalRenderer.Frame = .{},
    samples: u8 = 0,
    /// The size of what is being drawn (for `aspect`), and the encoder and
    /// index buffer being drawn with.
    width: u32 = 0,
    height: u32 = 0,
    enc: Id = null,
    index_buffer: Id = null,

    pub const Buffer = struct {
        buf: Id = null,
    };

    pub const PipelineDesc = struct {
        /// Metal Shading Language source with the vertex and fragment
        /// functions. Vertex attributes are read with `[[stage_in]]`
        /// (`[[attribute(location)]]`), the uniforms are `buffer(1)` (in
        /// both).
        source: [:0]const u8,
        vertex: [:0]const u8 = "vertex_main",
        fragment: [:0]const u8 = "fragment_main",
        vertex_stride: u32,
        /// Each attribute's floats (1 to 4).
        attributes: []const shaders.Attribute,
        cull_back: bool = true,
        front_ccw: bool = true,
        depth_test: bool = true,
        blend: bool = false,
    };

    pub const Pipeline = struct {
        /// One for each sample count (1, 2, 4, 8) the GPU can draw with.
        states: [4]Id = @splat(null),
        cull_back: bool = true,
        front_ccw: bool = true,
        depth_test: bool = true,
    };

    pub const sample_counts = [4]u8{ 1, 2, 4, 8 };

    /// On the system's default GPU, its own.
    pub fn init(gpa: std.mem.Allocator) !OffscreenContext {
        if (builtin.os.tag != .macos) return error.Unsupported;
        try objc.load();
        const create = objc.symbol(*const fn () callconv(.c) Id, "MTLCreateSystemDefaultDevice") orelse return error.NoMetal;
        const device = create() orelse return error.NoMetalDevice;
        const queue = msg(Id, device, "newCommandQueue", .{});
        if (queue == null) {
            objc.release(device);
            return error.NoMetalQueue;
        }
        return initWith(gpa, device, queue, true);
    }

    /// On a renderer's GPU (`MetalRenderer.sharedDevice`), so that scenes
    /// are drawn straight into its frames.
    pub fn initShared(gpa: std.mem.Allocator, shared: SharedDevice) !OffscreenContext {
        if (builtin.os.tag != .macos) return error.Unsupported;
        return initWith(gpa, shared.device, shared.queue, false);
    }

    fn initWith(gpa: std.mem.Allocator, device: Id, queue: Id, owned: bool) !OffscreenContext {
        var self: OffscreenContext = .{ .gpa = gpa, .device = device, .queue = queue, .owned = owned };
        errdefer self.deinit();
        self.depth_on = self.depthState(1, true); // Less
        self.depth_off = self.depthState(7, false); // Always
        if (self.depth_on == null or self.depth_off == null) return error.MetalDepthFailed;
        return self;
    }

    pub fn deinit(self: *OffscreenContext) void {
        if (self.device == null) return;
        self.waitIdle();
        for ([_]Id{ self.depth_on, self.depth_off, self.msaa_tex, self.depth_tex, self.resolve.tex }) |o| objc.release(o);
        if (self.owned) {
            objc.release(self.queue);
            objc.release(self.device);
        }
        self.device = null;
    }

    /// Waits until the GPU has done all it was given on the queue.
    pub fn waitIdle(self: *OffscreenContext) void {
        const pool = objc.push();
        defer objc.pop(pool);
        const cmd = msg(Id, self.queue, "commandBuffer", .{}) orelse return;
        msg(void, cmd, "commit", .{});
        msg(void, cmd, "waitUntilCompleted", .{});
    }

    pub fn aspect(self: *const OffscreenContext) f32 {
        if (self.height == 0) return 1;
        return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
    }

    fn depthState(self: *OffscreenContext, compare: u64, write: bool) Id {
        const desc = objc.new(objc.class("MTLDepthStencilDescriptor"));
        defer objc.release(desc);
        msg(void, desc, "setDepthCompareFunction:", .{compare});
        msg(void, desc, "setDepthWriteEnabled:", .{if (write) objc.yes else objc.no});
        return msg(Id, self.device, "newDepthStencilStateWithDescriptor:", .{desc});
    }

    fn supportsSamples(self: *const OffscreenContext, count: u8) bool {
        return count == 1 or msg(objc.Bool, self.device, "supportsTextureSampleCount:", .{@as(u64, count)}) != 0;
    }

    /// Compiles the pipeline's shaders, and makes a pipeline of them for
    /// each sample count the GPU can draw with.
    pub fn createPipeline(self: *OffscreenContext, desc: PipelineDesc) !Pipeline {
        const pool = objc.push();
        defer objc.pop(pool);
        var err: Id = null;
        const lib = msg(Id, self.device, "newLibraryWithSource:options:error:", .{ objc.nsString(desc.source), @as(Id, null), &err });
        if (lib == null) {
            MetalRenderer.logError("compiling a scene's shaders", err);
            return error.MetalShaderFailed;
        }
        defer objc.release(lib);
        const vs = msg(Id, lib, "newFunctionWithName:", .{objc.nsString(desc.vertex)});
        defer objc.release(vs);
        const fs = msg(Id, lib, "newFunctionWithName:", .{objc.nsString(desc.fragment)});
        defer objc.release(fs);
        if (vs == null or fs == null) return error.MetalShaderFailed;

        const vdesc = msg(Id, objc.class("MTLVertexDescriptor"), "vertexDescriptor", .{});
        const attrs = msg(Id, vdesc, "attributes", .{});
        for (desc.attributes) |a| {
            const at = msg(Id, attrs, "objectAtIndexedSubscript:", .{@as(u64, a.location)});
            // MTLVertexFormatFloat, Float2, Float3, Float4.
            msg(void, at, "setFormat:", .{@as(u64, 27) + std.math.clamp(a.components, 1, 4)});
            msg(void, at, "setOffset:", .{@as(u64, a.offset)});
            msg(void, at, "setBufferIndex:", .{@as(u64, 0)});
        }
        const layout0 = msg(Id, msg(Id, vdesc, "layouts", .{}), "objectAtIndexedSubscript:", .{@as(u64, 0)});
        msg(void, layout0, "setStride:", .{@as(u64, desc.vertex_stride)});

        var p: Pipeline = .{ .cull_back = desc.cull_back, .front_ccw = desc.front_ccw, .depth_test = desc.depth_test };
        errdefer self.destroyPipeline(p);
        for (sample_counts, 0..) |count, i| {
            if (!self.supportsSamples(count)) continue;
            const pd = objc.new(objc.class("MTLRenderPipelineDescriptor"));
            defer objc.release(pd);
            msg(void, pd, "setVertexFunction:", .{vs});
            msg(void, pd, "setFragmentFunction:", .{fs});
            msg(void, pd, "setVertexDescriptor:", .{vdesc});
            msg(void, pd, "setRasterSampleCount:", .{@as(u64, count)});
            msg(void, pd, "setDepthAttachmentPixelFormat:", .{format_depth});
            const att = msg(Id, msg(Id, pd, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(u64, 0)});
            msg(void, att, "setPixelFormat:", .{format_bgra8});
            if (desc.blend) {
                msg(void, att, "setBlendingEnabled:", .{objc.yes});
                msg(void, att, "setSourceRGBBlendFactor:", .{@as(u64, 4)});
                msg(void, att, "setDestinationRGBBlendFactor:", .{@as(u64, 5)});
                msg(void, att, "setSourceAlphaBlendFactor:", .{@as(u64, 1)});
                msg(void, att, "setDestinationAlphaBlendFactor:", .{@as(u64, 5)});
            }
            err = null;
            p.states[i] = msg(Id, self.device, "newRenderPipelineStateWithDescriptor:error:", .{ pd, &err });
            if (p.states[i] == null) {
                MetalRenderer.logError("making a scene's pipeline", err);
                return error.MetalPipelineFailed;
            }
        }
        return p;
    }

    pub fn destroyPipeline(_: *const OffscreenContext, p: Pipeline) void {
        for (p.states) |s| objc.release(s);
    }

    pub fn createVertexBuffer(self: *const OffscreenContext, comptime T: type, items: []const T) !Buffer {
        return self.createBuffer(std.mem.sliceAsBytes(items));
    }

    pub fn createIndexBuffer(self: *const OffscreenContext, indices: []const u16) !Buffer {
        return self.createBuffer(std.mem.sliceAsBytes(indices));
    }

    fn createBuffer(self: *const OffscreenContext, bytes: []const u8) !Buffer {
        if (bytes.len == 0) return .{};
        const buf = msg(Id, self.device, "newBufferWithBytes:length:options:", .{ bytes.ptr, @as(u64, bytes.len), @as(u64, 0) });
        return .{ .buf = buf orelse return error.MetalBufferFailed };
    }

    pub fn destroyBuffer(_: *const OffscreenContext, buf: Buffer) void {
        objc.release(buf.buf);
    }

    /// Draws with `p` from now on (in `render`).
    pub fn bindPipeline(self: *OffscreenContext, p: Pipeline) void {
        const enc = self.enc orelse return;
        // The pipeline for the samples drawn with (or the most there are
        // fewer than).
        var i = sampleIndex(self.samples);
        while (p.states[i] == null and i > 0) i -= 1;
        msg(void, enc, "setRenderPipelineState:", .{p.states[i]});
        msg(void, enc, "setDepthStencilState:", .{if (p.depth_test) self.depth_on else self.depth_off});
        msg(void, enc, "setCullMode:", .{@as(u64, if (p.cull_back) 2 else 0)});
        msg(void, enc, "setFrontFacingWinding:", .{@as(u64, if (p.front_ccw) 1 else 0)});
    }

    /// The uniforms the shaders have as `buffer(1)` (a small struct,
    /// under 4 KiB).
    pub fn setUniforms(self: *OffscreenContext, comptime T: type, value: *const T) void {
        const enc = self.enc orelse return;
        msg(void, enc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, value), @as(u64, @sizeOf(T)), @as(u64, 1) });
        msg(void, enc, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, value), @as(u64, @sizeOf(T)), @as(u64, 1) });
    }

    pub fn bindVertexBuffer(self: *OffscreenContext, buf: Buffer) void {
        const enc = self.enc orelse return;
        msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ buf.buf, @as(u64, 0), @as(u64, 0) });
    }

    pub fn bindIndexBuffer16(self: *OffscreenContext, buf: Buffer) void {
        self.index_buffer = buf.buf;
    }

    pub fn draw(self: *OffscreenContext, vertex_count: u32) void {
        const enc = self.enc orelse return;
        msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ triangles, @as(u64, 0), @as(u64, vertex_count) });
    }

    pub fn drawIndexed(self: *OffscreenContext, index_count: u32) void {
        const enc = self.enc orelse return;
        const ib = self.index_buffer orelse return;
        msg(void, enc, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", .{ triangles, @as(u64, index_count), @as(u64, 0), ib, @as(u64, 0) });
    }

    fn sampleIndex(samples: u8) usize {
        return switch (samples) {
            0, 1 => 0,
            2, 3 => 1,
            4...7 => 2,
            else => 3,
        };
    }

    /// Makes what a scene is drawn in `width` by `height`, with as many
    /// samples as asked (or the most the GPU has, fewer).
    fn ensureTargets(self: *OffscreenContext, width: u32, height: u32, samples: u8) !void {
        var count = sample_counts[sampleIndex(samples)];
        while (count > 1 and !self.supportsSamples(count)) count /= 2;
        if (self.resolve.tex != null and self.resolve.width == width and self.resolve.height == height and self.samples == count) return;
        for ([_]Id{ self.msaa_tex, self.depth_tex, self.resolve.tex }) |o| objc.release(o);
        self.msaa_tex = null;
        self.depth_tex = null;
        self.resolve = .{};
        self.samples = count;
        self.resolve.tex = try self.makeTarget(format_bgra8, width, height, 1, usage_read | usage_render, storage_cpu);
        self.resolve.width = width;
        self.resolve.height = height;
        if (count > 1) self.msaa_tex = try self.makeTarget(format_bgra8, width, height, count, usage_render, storage_private);
        self.depth_tex = try self.makeTarget(format_depth, width, height, count, usage_render, storage_private);
    }

    fn makeTarget(self: *OffscreenContext, format: u64, width: u32, height: u32, count: u8, usage: u64, storage: u64) !Id {
        const desc = objc.new(objc.class("MTLTextureDescriptor"));
        defer objc.release(desc);
        msg(void, desc, "setTextureType:", .{@as(u64, if (count > 1) 4 else 2)}); // 2DMultisample, 2D
        msg(void, desc, "setPixelFormat:", .{format});
        msg(void, desc, "setWidth:", .{@as(u64, width)});
        msg(void, desc, "setHeight:", .{@as(u64, height)});
        msg(void, desc, "setSampleCount:", .{@as(u64, count)});
        msg(void, desc, "setUsage:", .{usage});
        msg(void, desc, "setStorageMode:", .{storage});
        return msg(Id, self.device, "newTextureWithDescriptor:", .{desc}) orelse error.MetalTextureFailed;
    }

    /// Encodes into `cmd` the scene drawn over `clear_color`, resolved
    /// into `resolve` (`width` by `height`), once `wait` (if given) is done.
    fn encodeScene(self: *OffscreenContext, cmd: Id, width: u32, height: u32, clear_color: ?Color, samples: u8, wait: ?Wait, user_ctx: anytype, comptime render_fn: anytype) !void {
        try self.ensureTargets(width, height, samples);
        if (wait) |w| msg(void, cmd, "encodeWaitForEvent:value:", .{ w.event, w.value });
        self.width = width;
        self.height = height;
        const pass = msg(Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const att = msg(Id, msg(Id, pass, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(u64, 0)});
        if (self.msaa_tex != null) {
            msg(void, att, "setTexture:", .{self.msaa_tex});
            msg(void, att, "setResolveTexture:", .{self.resolve.tex});
            msg(void, att, "setStoreAction:", .{@as(u64, 2)}); // MultisampleResolve
        } else {
            msg(void, att, "setTexture:", .{self.resolve.tex});
            msg(void, att, "setStoreAction:", .{store_store});
        }
        if (clear_color) |c| {
            msg(void, att, "setLoadAction:", .{@as(u64, 2)}); // Clear
            msg(void, att, "setClearColor:", .{ClearColor{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }});
        } else msg(void, att, "setLoadAction:", .{@as(u64, 0)}); // DontCare
        const depth = msg(Id, pass, "depthAttachment", .{});
        msg(void, depth, "setTexture:", .{self.depth_tex});
        msg(void, depth, "setLoadAction:", .{@as(u64, 2)});
        msg(void, depth, "setClearDepth:", .{@as(f64, 1)});
        msg(void, depth, "setStoreAction:", .{@as(u64, 0)});
        const enc = msg(Id, cmd, "renderCommandEncoderWithDescriptor:", .{pass}) orelse return error.MetalEncoderFailed;
        msg(void, enc, "setViewport:", .{MtlViewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .znear = 0, .zfar = 1 }});
        self.enc = enc;
        self.index_buffer = null;
        defer {
            msg(void, enc, "endEncoding", .{});
            self.enc = null;
        }
        try render_fn(user_ctx, self);
    }

    /// Draws the scene over `area`'s viewport into `frame` on the GPU,
    /// within its scissor, once `wait` (if given) is done; false if `frame`
    /// is on another GPU (draw with `renderToImage`).
    pub fn renderToFrame(self: *OffscreenContext, frame: *const DirectFrame, area: GpuArea, clear_color: ?Color, samples: u8, wait: ?Wait, user_ctx: anytype, comptime render_fn: anytype) !bool {
        if (frame.device != self.device) return false;
        const vp = area.viewport;
        if (vp.width == 0 or vp.height == 0) return true;
        const full: Viewport = .{ .width = frame.width, .height = frame.height };
        const sc = full.intersect(if (area.scissor) |s| vp.intersect(s) orelse return true else vp) orelse return true;
        try self.encodeScene(frame.cmd, vp.width, vp.height, clear_color, samples, wait, user_ctx, render_fn);
        const blit = msg(Id, frame.cmd, "blitCommandEncoder", .{});
        msg(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
            self.resolve.tex,                                                 @as(u64, 0),                                    @as(u64, 0),
            Origin{ .x = @intCast(sc.x - vp.x), .y = @intCast(sc.y - vp.y) }, Size{ .width = sc.width, .height = sc.height }, frame.texture,
            @as(u64, 0),                                                      @as(u64, 0),                                    Origin{ .x = @intCast(sc.x), .y = @intCast(sc.y) },
        });
        msg(void, blit, "endEncoding", .{});
        return true;
    }

    /// Draws the scene over `area`'s viewport into `target` on the CPU,
    /// within its scissor, once `wait` (if given) is done.
    pub fn renderToImage(self: *OffscreenContext, target: *software.Image, area: GpuArea, clear_color: ?Color, samples: u8, wait: ?Wait, user_ctx: anytype, comptime render_fn: anytype) !void {
        const vp = area.viewport;
        if (vp.width == 0 or vp.height == 0) return;
        const full: Viewport = .{ .width = target.width, .height = target.height };
        const sc = full.intersect(if (area.scissor) |s| vp.intersect(s) orelse return else vp) orelse return;
        const pool = objc.push();
        defer objc.pop(pool);
        const cmd = msg(Id, self.queue, "commandBuffer", .{}) orelse return error.MetalCommandBufferFailed;
        try self.encodeScene(cmd, vp.width, vp.height, clear_color, samples, wait, user_ctx, render_fn);
        MetalRenderer.finishForCpu(cmd, &self.resolve);
        const stride = target.rowStride();
        const at = @as(usize, @intCast(sc.y)) * stride + @as(usize, @intCast(sc.x));
        const local: Viewport = .{ .x = sc.x - vp.x, .y = sc.y - vp.y, .width = sc.width, .height = sc.height };
        msg(void, self.resolve.tex, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{ target.pixels[at..].ptr, @as(u64, stride) * 4, regionOf(local), @as(u64, 0) });
    }
};

test "regions are Metal's, a pixel rectangle's origin and size" {
    const reg = regionOf(.{ .x = 3, .y = 4, .width = 5, .height = 6 });
    try std.testing.expectEqual(@as(u64, 3), reg.origin.x);
    try std.testing.expectEqual(@as(u64, 4), reg.origin.y);
    try std.testing.expectEqual(@as(u64, 5), reg.size.width);
    try std.testing.expectEqual(@as(u64, 6), reg.size.height);
    try std.testing.expectEqual(@as(u64, 1), reg.size.depth);
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Region));
    if (builtin.os.tag != .macos) try std.testing.expectError(error.Unsupported, MetalRenderer.initDefault(std.testing.allocator));
}
