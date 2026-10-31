//! Vulkan 1.1+ rendering backend for Kete's 2D `Canvas`.
//!
//! Uses a runtime `GetDeviceProcAddr` loader and the SPIR-V shaders compiled
//! at build time from `src/gfx/shaders/*.zig` (`shaders.shape_spv`,
//! `shaders.solid_spv`, `shaders.text_spv`, `shaders.image_spv`), so no
//! Vulkan SDK headers or link libraries are required at compile time.
//!
//!     var vk = try gfx.vulkan.VulkanRenderer.init(gpa, device, get_device_proc, options);
//!     defer vk.deinit();
//!     const target: gfx.vulkan.Target = .{ .cmd = cmd_buf, .width = w, .height = h };
//!     try ui.renderWith(vk.renderer(), &target, null);

const std = @import("std");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");
const atlas_mod = @import("atlas.zig");
const renderer_mod = @import("renderer.zig");
const software = @import("software.zig");

const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;
const Viewport = renderer_mod.Viewport;
const Segment = renderer_mod.Segment;
const DmabufTarget = renderer_mod.DmabufTarget;
const DmabufImage = renderer_mod.DmabufImage;
const GpuArea = renderer_mod.GpuArea;

pub const VkFlags = u32;
pub const VkBool32 = u32;
pub const VkDeviceSize = u64;
pub const VK_TRUE: VkBool32 = 1;
pub const VK_FALSE: VkBool32 = 0;

pub const VkResult = enum(i32) {
    success = 0,
    _,
};

pub const VkInstance = *opaque {};
pub const VkPhysicalDevice = *opaque {};
pub const VkDevice = *opaque {};
pub const VkQueue = *opaque {};
pub const VkCommandBuffer = *opaque {};
pub const VkCommandPool = u64;
pub const VkRenderPass = u64;
pub const VkFramebuffer = u64;
pub const VkImage = u64;
pub const VkImageView = u64;
pub const VkPipeline = u64;
pub const VkPipelineCache = u64;
pub const VkPipelineLayout = u64;
pub const VkShaderModule = u64;
pub const VkBuffer = u64;
pub const VkDeviceMemory = u64;
pub const VkDescriptorSetLayout = u64;
pub const VkDescriptorPool = u64;
pub const VkDescriptorSet = u64;
pub const VkSampler = u64;
pub const VkFence = u64;
pub const VkSemaphore = u64;

pub const VK_NULL_HANDLE: u64 = 0;

pub const VkStructureType = enum(u32) {
    application_info = 0,
    instance_create_info = 1,
    device_queue_create_info = 2,
    device_create_info = 3,
    submit_info = 4,
    memory_allocate_info = 5,
    buffer_create_info = 12,
    image_create_info = 14,
    image_view_create_info = 15,
    shader_module_create_info = 16,
    pipeline_shader_stage_create_info = 18,
    pipeline_vertex_input_state_create_info = 19,
    pipeline_input_assembly_state_create_info = 20,
    pipeline_viewport_state_create_info = 22,
    pipeline_rasterization_state_create_info = 23,
    pipeline_multisample_state_create_info = 24,
    pipeline_depth_stencil_state_create_info = 25,
    pipeline_color_blend_state_create_info = 26,
    pipeline_dynamic_state_create_info = 27,
    graphics_pipeline_create_info = 28,
    pipeline_layout_create_info = 30,
    sampler_create_info = 31,
    descriptor_set_layout_create_info = 32,
    descriptor_pool_create_info = 33,
    descriptor_set_allocate_info = 34,
    write_descriptor_set = 35,
    framebuffer_create_info = 37,
    render_pass_create_info = 38,
    command_pool_create_info = 39,
    command_buffer_allocate_info = 40,
    command_buffer_begin_info = 42,
    render_pass_begin_info = 43,
    image_memory_barrier = 45,
    fence_create_info = 8,
    semaphore_create_info = 9,
    import_semaphore_fd_info_khr = 1000079000,
    physical_device_timeline_semaphore_features = 1000207000,
    semaphore_type_create_info = 1000207002,
    timeline_semaphore_submit_info = 1000207003,
    semaphore_wait_info = 1000207004,
    semaphore_signal_info = 1000207005,
    external_memory_image_create_info = 1000072001,
    import_memory_fd_info_khr = 1000074000,
    memory_fd_properties_khr = 1000074001,
    memory_dedicated_allocate_info = 1000127001,
    image_drm_format_modifier_explicit_create_info_ext = 1000158004,
    _,
};

pub const VkBufferUsageFlags = VkFlags;
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT: VkBufferUsageFlags = 0x00000001;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT: VkBufferUsageFlags = 0x00000002;
pub const VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT: VkBufferUsageFlags = 0x00000010;
pub const VK_BUFFER_USAGE_INDEX_BUFFER_BIT: VkBufferUsageFlags = 0x00000040;
pub const VK_BUFFER_USAGE_VERTEX_BUFFER_BIT: VkBufferUsageFlags = 0x00000080;

pub const VkShaderModuleCreateInfo = extern struct {
    sType: VkStructureType = .shader_module_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    codeSize: usize,
    pCode: [*]const u32,
};

pub const VkBufferCreateInfo = extern struct {
    sType: VkStructureType = .buffer_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    size: VkDeviceSize,
    usage: VkBufferUsageFlags,
    sharingMode: u32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
};

pub const VkMemoryRequirements = extern struct {
    size: VkDeviceSize,
    alignment: VkDeviceSize,
    memoryTypeBits: u32,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: VkStructureType = .memory_allocate_info,
    pNext: ?*const anyopaque = null,
    allocationSize: VkDeviceSize,
    memoryTypeIndex: u32,
};

pub const VkViewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    minDepth: f32 = 0.0,
    maxDepth: f32 = 1.0,
};

pub const VkOffset2D = extern struct {
    x: i32,
    y: i32,
};

pub const VkExtent2D = extern struct {
    width: u32,
    height: u32,
};

pub const VkRect2D = extern struct {
    offset: VkOffset2D,
    extent: VkExtent2D,
};

pub const VK_PIPELINE_BIND_POINT_GRAPHICS: u32 = 0;

pub const GetDeviceProcAddr = *const fn (device: VkDevice, name: [*:0]const u8) callconv(.c) ?*const anyopaque;

pub const DeviceProcs = struct {
    CreateShaderModule: *const fn (VkDevice, *const VkShaderModuleCreateInfo, ?*const anyopaque, *VkShaderModule) callconv(.c) VkResult,
    DestroyShaderModule: *const fn (VkDevice, VkShaderModule, ?*const anyopaque) callconv(.c) void,
    CreateBuffer: *const fn (VkDevice, *const VkBufferCreateInfo, ?*const anyopaque, *VkBuffer) callconv(.c) VkResult,
    DestroyBuffer: *const fn (VkDevice, VkBuffer, ?*const anyopaque) callconv(.c) void,
    GetBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, *VkMemoryRequirements) callconv(.c) void,
    AllocateMemory: *const fn (VkDevice, *const VkMemoryAllocateInfo, ?*const anyopaque, *VkDeviceMemory) callconv(.c) VkResult,
    FreeMemory: *const fn (VkDevice, VkDeviceMemory, ?*const anyopaque) callconv(.c) void,
    BindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize) callconv(.c) VkResult,
    MapMemory: *const fn (VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkFlags, *?*anyopaque) callconv(.c) VkResult,
    UnmapMemory: *const fn (VkDevice, VkDeviceMemory) callconv(.c) void,
    CmdBindPipeline: *const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void,
    CmdSetViewport: *const fn (VkCommandBuffer, u32, u32, [*]const VkViewport) callconv(.c) void,
    CmdSetScissor: *const fn (VkCommandBuffer, u32, u32, [*]const VkRect2D) callconv(.c) void,
    CmdBindVertexBuffers: *const fn (VkCommandBuffer, u32, u32, [*]const VkBuffer, [*]const VkDeviceSize) callconv(.c) void,
    CmdBindDescriptorSets: *const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, [*]const VkDescriptorSet, u32, ?[*]const u32) callconv(.c) void,
    CmdDraw: *const fn (VkCommandBuffer, u32, u32, u32, u32) callconv(.c) void,

    pub fn load(device: VkDevice, get_proc: GetDeviceProcAddr) !DeviceProcs {
        var p: DeviceProcs = undefined;
        inline for (@typeInfo(DeviceProcs).@"struct".field_names) |field_name| {
            const name: [*:0]const u8 = "vk" ++ field_name;
            const sym = get_proc(device, name) orelse return error.MissingVulkanFunction;
            @field(p, field_name) = @ptrCast(@alignCast(sym));
        }
        return p;
    }
};

/// Pipelines and descriptor callbacks configured by the host Vulkan setup.
pub const Pipelines = struct {
    layout: VkPipelineLayout = VK_NULL_HANDLE,
    shape: VkPipeline = VK_NULL_HANDLE,
    solid: VkPipeline = VK_NULL_HANDLE,
    @"opaque": VkPipeline = VK_NULL_HANDLE,
    text: VkPipeline = VK_NULL_HANDLE,
    image: VkPipeline = VK_NULL_HANDLE,
};

/// Optional texture upload hooks for the host Vulkan memory/descriptor manager.
pub const TextureHooks = struct {
    ctx: ?*anyopaque = null,
    /// Uploads dirty rows `[y0..y1)` of the 8-bit `atlas` and returns the
    /// descriptor set to bind for `.text` draws.
    uploadAtlas: ?*const fn (ctx: ?*anyopaque, pixels: []const u8, width: u32, height: u32, y0: u32, y1: u32) anyerror!VkDescriptorSet = null,
    /// Uploads or looks up an `0xAARRGGBB` `Image` and returns the descriptor
    /// set to bind for `.image` draws.
    acquireImage: ?*const fn (ctx: ?*anyopaque, id: u64, pixels: []const u32, width: u32, height: u32) anyerror!VkDescriptorSet = null,
    /// Releases an image texture no longer drawn.
    releaseImage: ?*const fn (ctx: ?*anyopaque, id: u64) void = null,
};

pub const Options = struct {
    /// Host-visible coherent memory type index for streaming vertex buffers.
    host_visible_memory_type: u32 = 0,
    pipelines: Pipelines = .{},
    textures: TextureHooks = .{},
};

/// Active Vulkan command buffer target for `VulkanRenderer.recordTarget`.
pub const Target = struct {
    cmd: VkCommandBuffer,
    width: u32,
    height: u32,
    /// When true (default, Vulkan 1.1+ / `VK_KHR_maintenance1`), uses a negative
    /// viewport height so clip-space Y matches OpenGL/Canvas (+1 at top).
    flip_viewport_y: bool = true,
    /// Where the canvas's top left goes in the attachment (for a window
    /// buffer, inside its shadow); damage and clips are relative to it.
    origin: [2]i32 = .{ 0, 0 },
};

pub const ShaderModules = struct {
    shape: VkShaderModule,
    solid: VkShaderModule,
    text: VkShaderModule,
    image: VkShaderModule,

    pub fn deinit(m: ShaderModules, device: VkDevice, vk: *const DeviceProcs) void {
        vk.DestroyShaderModule(device, m.shape, null);
        vk.DestroyShaderModule(device, m.solid, null);
        vk.DestroyShaderModule(device, m.text, null);
        vk.DestroyShaderModule(device, m.image, null);
    }
};

pub const VulkanRenderer = struct {
    gpa: std.mem.Allocator,
    device: VkDevice,
    vk: DeviceProcs,
    shader_modules: ShaderModules,
    pipelines: Pipelines,
    textures: TextureHooks,
    host_memory_type: u32,
    owned: ?*Owned2DContext = null,

    vbo: VkBuffer = VK_NULL_HANDLE,
    vbo_mem: VkDeviceMemory = VK_NULL_HANDLE,
    vbo_map: []u8 = &.{},
    cursor: usize = 0,

    atlas: ?*atlas_mod.Atlas = null,
    atlas_stale: ?atlas_mod.Rect = null,
    atlas_set: VkDescriptorSet = VK_NULL_HANDLE,
    images: std.AutoHashMapUnmanaged(u64, VkDescriptorSet) = .empty,
    image_use: renderer_mod.ImageUse = .{},

    /// Initializes a self-contained Vulkan 1.1+ 2D renderer that compiles SPIR-V
    /// pipelines (`shape`, `solid`, `opaque`, `text`, `image`), manages glyph
    /// atlas and image textures, and renders `Canvas` batches into `*software.Image`.
    pub fn initDefault(gpa: std.mem.Allocator) !VulkanRenderer {
        const owned = try Owned2DContext.create(gpa);
        errdefer owned.destroy();

        const dev_procs = try DeviceProcs.load(owned.device, owned.inst_procs.GetDeviceProcAddr);
        var r = try initWithProcs(gpa, owned.device, dev_procs, .{
            .host_visible_memory_type = owned.host_mem_type,
            .pipelines = .{},
            .textures = owned.textureHooks(),
        });
        errdefer r.deinit();

        try owned.initPipelines(r.shader_modules);
        r.pipelines = owned.pipelines;
        r.owned = owned;
        return r;
    }

    pub fn init(gpa: std.mem.Allocator, device: VkDevice, get_proc: GetDeviceProcAddr, options: Options) !VulkanRenderer {
        const vk = try DeviceProcs.load(device, get_proc);
        return initWithProcs(gpa, device, vk, options);
    }

    pub fn initWithProcs(gpa: std.mem.Allocator, device: VkDevice, vk: DeviceProcs, options: Options) !VulkanRenderer {
        const shape_mod = try createShaderModule(device, &vk, &shaders.shape_spv);
        errdefer vk.DestroyShaderModule(device, shape_mod, null);
        const solid_mod = try createShaderModule(device, &vk, &shaders.solid_spv);
        errdefer vk.DestroyShaderModule(device, solid_mod, null);
        const text_mod = try createShaderModule(device, &vk, &shaders.text_spv);
        errdefer vk.DestroyShaderModule(device, text_mod, null);
        const image_mod = try createShaderModule(device, &vk, &shaders.image_spv);
        errdefer vk.DestroyShaderModule(device, image_mod, null);

        return .{
            .gpa = gpa,
            .device = device,
            .vk = vk,
            .shader_modules = .{
                .shape = shape_mod,
                .solid = solid_mod,
                .text = text_mod,
                .image = image_mod,
            },
            .pipelines = options.pipelines,
            .textures = options.textures,
            .host_memory_type = options.host_visible_memory_type,
        };
    }

    pub fn deinit(r: *VulkanRenderer) void {
        if (r.owned) |owned| {
            _ = owned.vk.DeviceWaitIdle(owned.device);
        }
        if (r.textures.releaseImage) |rel| {
            var it = r.images.keyIterator();
            while (it.next()) |id| rel(r.textures.ctx, id.*);
        }
        r.images.deinit(r.gpa);
        r.image_use.deinit(r.gpa);
        r.destroyVbo();
        r.shader_modules.deinit(r.device, &r.vk);
        if (r.owned) |owned| {
            owned.destroy();
            r.owned = null;
        }
    }

    pub const backend: renderer_mod.RenderBackend = .vulkan;

    pub fn renderer(r: *VulkanRenderer) renderer_mod.Renderer {
        return .of(r);
    }

    fn createShaderModule(device: VkDevice, vk: *const DeviceProcs, code: []align(4) const u8) !VkShaderModule {
        var info: VkShaderModuleCreateInfo = .{
            .codeSize = code.len,
            .pCode = @ptrCast(code.ptr),
        };
        var out: VkShaderModule = VK_NULL_HANDLE;
        if (vk.CreateShaderModule(device, &info, null, &out) != .success) {
            return error.VkCreateShaderModuleFailed;
        }
        return out;
    }

    fn destroyVbo(r: *VulkanRenderer) void {
        if (r.vbo_map.len > 0) {
            r.vk.UnmapMemory(r.device, r.vbo_mem);
            r.vbo_map = &.{};
        }
        if (r.vbo != VK_NULL_HANDLE) {
            r.vk.DestroyBuffer(r.device, r.vbo, null);
            r.vbo = VK_NULL_HANDLE;
        }
        if (r.vbo_mem != VK_NULL_HANDLE) {
            r.vk.FreeMemory(r.device, r.vbo_mem, null);
            r.vbo_mem = VK_NULL_HANDLE;
        }
    }

    fn ensureVbo(r: *VulkanRenderer, min_bytes: usize) !void {
        if (r.vbo_map.len >= min_bytes) return;
        r.destroyVbo();
        const cap = std.mem.alignForward(usize, min_bytes * 2, 64 * 1024);
        var buf_info: VkBufferCreateInfo = .{
            .size = cap,
            .usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        };
        var buf: VkBuffer = VK_NULL_HANDLE;
        if (r.vk.CreateBuffer(r.device, &buf_info, null, &buf) != .success) return error.VkCreateBufferFailed;
        errdefer r.vk.DestroyBuffer(r.device, buf, null);

        var req: VkMemoryRequirements = undefined;
        r.vk.GetBufferMemoryRequirements(r.device, buf, &req);
        var alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = @max(req.size, cap),
            .memoryTypeIndex = r.host_memory_type,
        };
        var mem: VkDeviceMemory = VK_NULL_HANDLE;
        if (r.vk.AllocateMemory(r.device, &alloc_info, null, &mem) != .success) return error.VkAllocateMemoryFailed;
        errdefer r.vk.FreeMemory(r.device, mem, null);

        if (r.vk.BindBufferMemory(r.device, buf, mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        var ptr: ?*anyopaque = null;
        if (r.vk.MapMemory(r.device, mem, 0, cap, 0, &ptr) != .success or ptr == null) return error.VkMapMemoryFailed;

        r.vbo = buf;
        r.vbo_mem = mem;
        r.vbo_map = @as([*]u8, @ptrCast(ptr.?))[0..cap];
    }

    pub fn prepare(r: *VulkanRenderer, canvases: []const *const Canvas) !void {
        var bytes: usize = 0;
        for (canvases) |c| for (c.batches.items) |*b| {
            bytes += std.mem.alignForward(usize, b.floats.items.len * 4, 16);
        };
        r.cursor = 0;
        if (bytes > 0) try r.ensureVbo(bytes);
        for (canvases) |c| if (c.atlas) |a| try r.uploadAtlas(a);
        try r.uploadImages(canvases);
    }

    fn uploadAtlas(r: *VulkanRenderer, a: *atlas_mod.Atlas) !void {
        const w = atlas_mod.width;
        const h = atlas_mod.height;
        const all: atlas_mod.Rect = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
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
        if (r.textures.uploadAtlas) |upload| {
            r.atlas_set = try upload(r.textures.ctx, a.pixels, w, h, d.y0, @min(d.y1, h));
        }
        r.atlas_stale = null;
    }

    fn uploadImages(r: *VulkanRenderer, canvases: []const *const Canvas) !void {
        // Those no window draws any more go.
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(r.gpa);
        try r.image_use.update(r.gpa, canvases, &stale);
        for (stale.items) |id| {
            if (!r.images.remove(id)) continue;
            if (r.textures.releaseImage) |rel| rel(r.textures.ctx, id);
        }

        if (r.textures.acquireImage) |acq| {
            for (canvases) |c| for (c.batches.items) |*b| {
                const img = b.image orelse continue;
                if (r.images.contains(img.id)) continue;
                const set = try acq(r.textures.ctx, img.id, img.pixels, img.width, img.height);
                try r.images.put(r.gpa, img.id, set);
            };
        }
    }

    /// The renderer's own device, for 3D widgets to draw on so that they go
    /// straight into its frames (`VulkanContext.initShared`); null if it has
    /// none of its own (`initWithProcs`).
    pub fn sharedDevice(r: *const VulkanRenderer) ?SharedDevice {
        const ctx = r.owned orelse return null;
        return .{
            .instance = ctx.instance,
            .inst_procs = ctx.inst_procs,
            .phys_dev = ctx.phys_dev,
            .mem_props = ctx.mem_props,
            .device = ctx.device,
            .vk = ctx.vk,
            .queue = ctx.queue,
            .queue_family = ctx.queue_family,
            .timelines = ctx.timelines != null,
        };
    }

    /// Renders a frame straight into a window's dmabuf (see
    /// `Renderer.renderDmabuf`): only for the renderer's own device
    /// (`initDefault`), and if it can import dmabufs.
    pub fn renderDmabuf(r: *VulkanRenderer, canvases: []const *const Canvas, segments: []const Segment, target: *const DmabufTarget, clear: u32, clear_rects: []const Viewport, damage: []const Viewport) !void {
        const ctx = r.owned orelse return error.Unsupported;
        if (ctx.dmabuf == null) return error.Unsupported;
        try r.prepare(canvases);
        try ctx.renderDirect(r, segments, target, clear, clear_rects, damage);
    }

    /// Renders a prepared 2D `Canvas` into `target: *software.Image`, preserving
    /// existing background pixels and clipping to `damage` viewports when provided.
    pub fn record(r: *VulkanRenderer, c: *const Canvas, target: *software.Image, damage: ?[]const Viewport) !void {
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

        if (r.owned) |ctx| {
            try ctx.renderCanvasToImage(r, c, target, damage);
        } else {
            var dummy_cmd: u8 = 0;
            const cmd_target: Target = .{
                .cmd = @ptrCast(&dummy_cmd),
                .width = target.width,
                .height = target.height,
            };
            try r.recordTarget(c, &cmd_target, damage);
        }
    }

    pub fn recordTarget(r: *VulkanRenderer, c: *const Canvas, target: *const Target, damage: ?[]const Viewport) !void {
        if (target.width == 0 or target.height == 0) return;
        const w_f: f32 = @floatFromInt(target.width);
        const h_f: f32 = @floatFromInt(target.height);
        const ox: f32 = @floatFromInt(target.origin[0]);
        const oy: f32 = @floatFromInt(target.origin[1]);
        const vp = [1]VkViewport{if (target.flip_viewport_y) .{
            .x = ox,
            .y = oy + h_f,
            .width = w_f,
            .height = -h_f,
        } else .{
            .x = ox,
            .y = oy,
            .width = w_f,
            .height = h_f,
        }};
        r.vk.CmdSetViewport(target.cmd, 0, 1, &vp);

        const full_vp: Viewport = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };

        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            const batch_vp = renderer_mod.scissor(area);
            if (!renderer_mod.covers(damage, batch_vp)) continue;
            if (r.cursor + data.len > r.vbo_map.len) return error.NotPrepared;

            @memcpy(r.vbo_map[r.cursor..][0..data.len], data);
            const byte_offset: VkDeviceSize = @intCast(r.cursor);
            r.cursor += std.mem.alignForward(usize, data.len, 16);

            const pipeline: VkPipeline = switch (b.kind) {
                .shape => r.pipelines.shape,
                .solid => r.pipelines.solid,
                .@"opaque" => if (r.pipelines.@"opaque" != VK_NULL_HANDLE) r.pipelines.@"opaque" else r.pipelines.solid,
                .text => r.pipelines.text,
                .image => r.pipelines.image,
            };
            r.vk.CmdBindPipeline(target.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);

            const bufs = [1]VkBuffer{r.vbo};
            const offs = [1]VkDeviceSize{byte_offset};
            r.vk.CmdBindVertexBuffers(target.cmd, 0, 1, &bufs, &offs);

            switch (b.kind) {
                .text => if (r.atlas_set != VK_NULL_HANDLE) {
                    const sets = [1]VkDescriptorSet{r.atlas_set};
                    r.vk.CmdBindDescriptorSets(target.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, r.pipelines.layout, 0, 1, &sets, 0, null);
                },
                .image => {
                    const img = b.image orelse continue;
                    if (r.images.get(img.id)) |set| {
                        const sets = [1]VkDescriptorSet{set};
                        r.vk.CmdBindDescriptorSets(target.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, r.pipelines.layout, 0, 1, &sets, 0, null);
                    }
                },
                else => {},
            }

            const clip_vp = if (b.clip) |clip| renderer_mod.scissor(clip) else full_vp;
            const count = b.vertexCount();
            if (damage) |dmg_list| {
                for (dmg_list) |dmg| {
                    const sc = clip_vp.intersect(dmg) orelse continue;
                    const rect = [1]VkRect2D{.{
                        .offset = .{ .x = sc.x + target.origin[0], .y = sc.y + target.origin[1] },
                        .extent = .{ .width = sc.width, .height = sc.height },
                    }};
                    r.vk.CmdSetScissor(target.cmd, 0, 1, &rect);
                    r.vk.CmdDraw(target.cmd, count, 1, 0, 0);
                }
            } else {
                const rect = [1]VkRect2D{.{
                    .offset = .{ .x = clip_vp.x + target.origin[0], .y = clip_vp.y + target.origin[1] },
                    .extent = .{ .width = clip_vp.width, .height = clip_vp.height },
                }};
                r.vk.CmdSetScissor(target.cmd, 0, 1, &rect);
                r.vk.CmdDraw(target.cmd, count, 1, 0, 0);
            }
        }
    }
};

// --- Offscreen Vulkan 1.1+ Context for `VulkanRenderer` and `VulkanArea` -----

pub const VK_FORMAT_R8_UNORM: u32 = 9;
pub const VK_FORMAT_R8G8B8A8_UNORM: u32 = 37;
pub const VK_FORMAT_B8G8R8A8_UNORM: u32 = 44;
pub const VK_FORMAT_R32_SFLOAT: u32 = 100;
pub const VK_FORMAT_R32G32_SFLOAT: u32 = 103;
pub const VK_FORMAT_R32G32B32_SFLOAT: u32 = 106;
pub const VK_FORMAT_R32G32B32A32_SFLOAT: u32 = 109;
pub const VK_FORMAT_D32_SFLOAT: u32 = 126;

pub const VK_COMPONENT_SWIZZLE_R: u32 = 3;

pub const VK_IMAGE_LAYOUT_UNDEFINED: u32 = 0;
pub const VK_IMAGE_LAYOUT_GENERAL: u32 = 1;
pub const VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: u32 = 2;
pub const VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL: u32 = 3;
pub const VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: u32 = 5;
pub const VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: u32 = 6;
pub const VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: u32 = 7;

pub const VK_ATTACHMENT_LOAD_OP_LOAD: u32 = 0;
pub const VK_ATTACHMENT_LOAD_OP_CLEAR: u32 = 1;
pub const VK_ATTACHMENT_LOAD_OP_DONT_CARE: u32 = 2;
pub const VK_ATTACHMENT_STORE_OP_STORE: u32 = 0;
pub const VK_ATTACHMENT_STORE_OP_DONT_CARE: u32 = 1;

pub const VK_IMAGE_USAGE_TRANSFER_SRC_BIT: VkFlags = 0x00000001;
pub const VK_IMAGE_USAGE_TRANSFER_DST_BIT: VkFlags = 0x00000002;
pub const VK_IMAGE_USAGE_SAMPLED_BIT: VkFlags = 0x00000004;
pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT: VkFlags = 0x00000010;
pub const VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT: VkFlags = 0x00000020;

pub const VK_IMAGE_ASPECT_COLOR_BIT: VkFlags = 0x00000001;
pub const VK_IMAGE_ASPECT_DEPTH_BIT: VkFlags = 0x00000002;

pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: VkFlags = 0x00000001;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: VkFlags = 0x00000002;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: VkFlags = 0x00000004;
pub const VK_MEMORY_PROPERTY_HOST_CACHED_BIT: VkFlags = 0x00000008;

pub const VK_SHADER_STAGE_VERTEX_BIT: VkFlags = 0x00000001;
pub const VK_SHADER_STAGE_FRAGMENT_BIT: VkFlags = 0x00000010;
pub const VK_SHADER_STAGE_ALL_GRAPHICS: VkFlags = 0x0000001F;

pub const VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT: VkFlags = 0x00000001;
pub const VK_PIPELINE_STAGE_ALL_COMMANDS_BIT: VkFlags = 0x00010000;
pub const VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT: VkFlags = 0x00002000;
pub const VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT: VkFlags = 0x00000080;
pub const VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT: VkFlags = 0x00000400;
pub const VK_PIPELINE_STAGE_TRANSFER_BIT: VkFlags = 0x00001000;

pub const VK_ACCESS_SHADER_READ_BIT: VkFlags = 0x00000020;
pub const VK_ACCESS_COLOR_ATTACHMENT_READ_BIT: VkFlags = 0x00000080;
pub const VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT: VkFlags = 0x00000100;
pub const VK_ACCESS_TRANSFER_READ_BIT: VkFlags = 0x00000800;
pub const VK_ACCESS_TRANSFER_WRITE_BIT: VkFlags = 0x00001000;

pub const VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: u32 = 1;
pub const VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC: u32 = 8;
pub const VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT: VkFlags = 0x00000001;
pub const VK_INDEX_TYPE_UINT16: u32 = 0;
pub const VK_INDEX_TYPE_UINT32: u32 = 1;

pub const VK_CULL_MODE_NONE: VkFlags = 0;
pub const VK_CULL_MODE_FRONT_BIT: VkFlags = 1;
pub const VK_CULL_MODE_BACK_BIT: VkFlags = 2;
pub const VK_FRONT_FACE_COUNTER_CLOCKWISE: u32 = 0;
pub const VK_FRONT_FACE_CLOCKWISE: u32 = 1;

pub const VkOffset3D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
};

pub const VkExtent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32 = 1,
};

// --- Importing dmabufs (`VK_EXT_external_memory_dma_buf`, `VK_EXT_image_drm_format_modifier`) --

pub const VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT: u32 = 0x00000200;
pub const VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT: u32 = 1000158000;
pub const VK_QUEUE_FAMILY_EXTERNAL: u32 = 0xFFFFFFFE;
const VK_IMAGE_ASPECT_COLOR: VkFlags = 0x00000001;

/// The device extensions a dmabuf import needs (on Vulkan 1.1).
const dmabuf_extensions = [_][*:0]const u8{
    "VK_KHR_external_memory_fd",
    "VK_EXT_external_memory_dma_buf",
    "VK_KHR_image_format_list",
    "VK_EXT_image_drm_format_modifier",
};

/// Device extensions for waiting on GPU work done elsewhere: on timeline
/// semaphores (`Wait`), and on sync files another API signals when it has
/// drawn a picture (`DmabufImage.ready_fd`). Each is turned on when the
/// device has it.
const timeline_extension: [*:0]const u8 = "VK_KHR_timeline_semaphore";
const sync_fd_extension: [*:0]const u8 = "VK_KHR_external_semaphore_fd";
const VK_SEMAPHORE_TYPE_TIMELINE: u32 = 1;
const VK_SEMAPHORE_IMPORT_TEMPORARY_BIT: VkFlags = 0x00000001;
const VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT: u32 = 0x00000010;

const VkSemaphoreCreateInfo = extern struct {
    sType: VkStructureType = .semaphore_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
};

const VkSemaphoreTypeCreateInfo = extern struct {
    sType: VkStructureType = .semaphore_type_create_info,
    pNext: ?*const anyopaque = null,
    semaphoreType: u32 = VK_SEMAPHORE_TYPE_TIMELINE,
    initialValue: u64 = 0,
};

const VkTimelineSemaphoreSubmitInfo = extern struct {
    sType: VkStructureType = .timeline_semaphore_submit_info,
    pNext: ?*const anyopaque = null,
    waitSemaphoreValueCount: u32 = 0,
    pWaitSemaphoreValues: ?[*]const u64 = null,
    signalSemaphoreValueCount: u32 = 0,
    pSignalSemaphoreValues: ?[*]const u64 = null,
};

const VkSemaphoreWaitInfo = extern struct {
    sType: VkStructureType = .semaphore_wait_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    semaphoreCount: u32 = 1,
    pSemaphores: [*]const VkSemaphore,
    pValues: [*]const u64,
};

const VkSemaphoreSignalInfo = extern struct {
    sType: VkStructureType = .semaphore_signal_info,
    pNext: ?*const anyopaque = null,
    semaphore: VkSemaphore,
    value: u64,
};

const VkPhysicalDeviceTimelineSemaphoreFeatures = extern struct {
    sType: VkStructureType = .physical_device_timeline_semaphore_features,
    pNext: ?*anyopaque = null,
    timelineSemaphore: VkBool32 = VK_TRUE,
};

const VkImportSemaphoreFdInfoKHR = extern struct {
    sType: VkStructureType = .import_semaphore_fd_info_khr,
    pNext: ?*const anyopaque = null,
    semaphore: VkSemaphore,
    flags: VkFlags = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT,
    handleType: u32 = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    fd: c_int,
};

/// GPU work that a scene waits for before it is drawn (as its `wait`): done
/// once `semaphore`, a timeline semaphore on the scene's device
/// (`OffscreenContext.createTimeline`), reaches `value`.
pub const Wait = struct {
    semaphore: VkSemaphore,
    value: u64,
};

/// What making, signalling and waiting on timeline semaphores needs
/// (`VK_KHR_timeline_semaphore`).
const TimelineProcs = struct {
    CreateSemaphore: *const fn (VkDevice, *const VkSemaphoreCreateInfo, ?*const anyopaque, *VkSemaphore) callconv(.c) VkResult,
    DestroySemaphore: *const fn (VkDevice, VkSemaphore, ?*const anyopaque) callconv(.c) void,
    SignalSemaphoreKHR: *const fn (VkDevice, *const VkSemaphoreSignalInfo) callconv(.c) VkResult,
    WaitSemaphoresKHR: *const fn (VkDevice, *const VkSemaphoreWaitInfo, u64) callconv(.c) VkResult,
};

/// What waiting on a sync file needs (`VK_KHR_external_semaphore_fd`).
const SyncFdProcs = struct {
    CreateSemaphore: *const fn (VkDevice, *const VkSemaphoreCreateInfo, ?*const anyopaque, *VkSemaphore) callconv(.c) VkResult,
    DestroySemaphore: *const fn (VkDevice, VkSemaphore, ?*const anyopaque) callconv(.c) void,
    ImportSemaphoreFdKHR: *const fn (VkDevice, *const VkImportSemaphoreFdInfoKHR) callconv(.c) VkResult,
};

/// The procs of `T` (its fields named as Vulkan's, without `vk`), or null
/// if the device lacks any of them.
fn loadProcs(comptime T: type, device: VkDevice, get_proc: GetDeviceProcAddr) ?T {
    var p: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        const sym = get_proc(device, "vk" ++ field_name) orelse return null;
        @field(p, field_name) = @ptrCast(@alignCast(sym));
    }
    return p;
}

/// The semaphores a submission waits on: the values of those that are
/// timelines (ignored for the others), and whether each is the
/// submitter's to destroy once the submission is done (a sync file's).
const SubmitWaits = struct {
    const max = 8;
    semaphores: [max]VkSemaphore = undefined,
    values: [max]u64 = undefined,
    stages: [max]VkFlags = undefined,
    owned: [max]bool = undefined,
    len: u32 = 0,
    timeline: VkTimelineSemaphoreSubmitInfo = .{},

    /// False if there are as many as it holds.
    fn add(w: *SubmitWaits, semaphore: VkSemaphore, value: u64, owned: bool) bool {
        if (w.len == max) return false;
        w.semaphores[w.len] = semaphore;
        w.values[w.len] = value;
        w.stages[w.len] = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        w.owned[w.len] = owned;
        w.len += 1;
        return true;
    }

    /// Makes `info` wait on them. It points into `w`, which must stay put
    /// until `info` is submitted.
    fn apply(w: *SubmitWaits, info: *VkSubmitInfo) void {
        if (w.len == 0) return;
        w.timeline = .{ .waitSemaphoreValueCount = w.len, .pWaitSemaphoreValues = &w.values };
        info.pNext = &w.timeline;
        info.waitSemaphoreCount = w.len;
        info.pWaitSemaphores = &w.semaphores;
        info.pWaitDstStageMask = &w.stages[0];
    }

    /// Forgets them, destroying those that are its own.
    fn clear(w: *SubmitWaits, device: VkDevice, destroy: ?*const fn (VkDevice, VkSemaphore, ?*const anyopaque) callconv(.c) void) void {
        for (w.semaphores[0..w.len], w.owned[0..w.len]) |sem, owned| {
            if (owned) if (destroy) |d| d(device, sem, null);
        }
        w.len = 0;
    }
};

/// The device extensions to turn on: those required, and those for waits
/// (`timeline_extension`, `sync_fd_extension`) if the device has them.
const DeviceExtensions = struct {
    names: [12][*:0]const u8 = undefined,
    len: u32 = 0,
    timelines: bool = false,
    sync_fd: bool = false,
    timeline_features: VkPhysicalDeviceTimelineSemaphoreFeatures = .{},

    fn init(procs: InstanceProcs, phys: VkPhysicalDevice, required: []const [*:0]const u8) DeviceExtensions {
        var x: DeviceExtensions = .{};
        for (required) |name| x.append(name);
        // A device with the extension has the feature (the Vulkan spec's
        // feature requirements), so it need not be asked.
        x.timelines = Owned2DContext.hasExtensions(procs, phys, &.{timeline_extension});
        if (x.timelines) x.append(timeline_extension);
        x.sync_fd = Owned2DContext.hasExtensions(procs, phys, &.{sync_fd_extension});
        if (x.sync_fd) x.append(sync_fd_extension);
        return x;
    }

    fn append(x: *DeviceExtensions, name: [*:0]const u8) void {
        x.names[x.len] = name;
        x.len += 1;
    }

    /// The device to make, with one queue (`q_info`). It points into `x`.
    fn createInfo(x: *const DeviceExtensions, q_info: [*]const VkDeviceQueueCreateInfo) VkDeviceCreateInfo {
        return .{
            .pNext = if (x.timelines) &x.timeline_features else null,
            .pQueueCreateInfos = q_info,
            .enabledExtensionCount = x.len,
            .ppEnabledExtensionNames = if (x.len > 0) &x.names else null,
        };
    }
};

const VkExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};

const VkSubresourceLayout = extern struct {
    offset: VkDeviceSize,
    size: VkDeviceSize,
    rowPitch: VkDeviceSize,
    arrayPitch: VkDeviceSize,
    depthPitch: VkDeviceSize,
};

const VkImageDrmFormatModifierExplicitCreateInfoEXT = extern struct {
    sType: VkStructureType = .image_drm_format_modifier_explicit_create_info_ext,
    pNext: ?*const anyopaque = null,
    drmFormatModifier: u64,
    drmFormatModifierPlaneCount: u32 = 1,
    pPlaneLayouts: [*]const VkSubresourceLayout,
};

const VkExternalMemoryImageCreateInfo = extern struct {
    sType: VkStructureType = .external_memory_image_create_info,
    pNext: ?*const anyopaque = null,
    handleTypes: VkFlags,
};

const VkImportMemoryFdInfoKHR = extern struct {
    sType: VkStructureType = .import_memory_fd_info_khr,
    pNext: ?*const anyopaque = null,
    handleType: u32,
    fd: c_int,
};

const VkMemoryFdPropertiesKHR = extern struct {
    sType: VkStructureType = .memory_fd_properties_khr,
    pNext: ?*anyopaque = null,
    memoryTypeBits: u32 = 0,
};

const VkMemoryDedicatedAllocateInfo = extern struct {
    sType: VkStructureType = .memory_dedicated_allocate_info,
    pNext: ?*const anyopaque = null,
    image: VkImage = VK_NULL_HANDLE,
    buffer: VkBuffer = VK_NULL_HANDLE,
};

const VkFenceCreateInfo = extern struct {
    sType: VkStructureType = .fence_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
};

const VkClearAttachment = extern struct {
    aspectMask: VkFlags,
    colorAttachment: u32,
    clearValue: VkClearValue,
};

const VkClearRect = extern struct {
    rect: VkRect2D,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 1,
};

/// What drawing straight into dmabufs needs beyond `ContextProcs` (loaded
/// only when the extensions are there).
const DmabufProcs = struct {
    GetMemoryFdPropertiesKHR: *const fn (VkDevice, u32, c_int, *VkMemoryFdPropertiesKHR) callconv(.c) VkResult,
    CmdClearAttachments: *const fn (VkCommandBuffer, u32, [*]const VkClearAttachment, u32, [*]const VkClearRect) callconv(.c) void,
    CreateFence: *const fn (VkDevice, *const VkFenceCreateInfo, ?*const anyopaque, *VkFence) callconv(.c) VkResult,
    DestroyFence: *const fn (VkDevice, VkFence, ?*const anyopaque) callconv(.c) void,
    WaitForFences: *const fn (VkDevice, u32, [*]const VkFence, u32, u64) callconv(.c) VkResult,
    ResetFences: *const fn (VkDevice, u32, [*]const VkFence) callconv(.c) VkResult,

    fn load(device: VkDevice, get_proc: GetDeviceProcAddr) ?DmabufProcs {
        var p: DmabufProcs = undefined;
        inline for (@typeInfo(DmabufProcs).@"struct".field_names) |field_name| {
            const name: [*:0]const u8 = "vk" ++ field_name;
            const sym = get_proc(device, name) orelse return null;
            @field(p, field_name) = @ptrCast(@alignCast(sym));
        }
        return p;
    }
};

const VkApplicationInfo = extern struct {
    sType: VkStructureType = .application_info,
    pNext: ?*const anyopaque = null,
    pApplicationName: ?[*:0]const u8 = "Kete",
    applicationVersion: u32 = 1,
    pEngineName: ?[*:0]const u8 = "Kete",
    engineVersion: u32 = 1,
    apiVersion: u32 = (1 << 22) | (1 << 12), // Vulkan 1.1
};

const VkInstanceCreateInfo = extern struct {
    sType: VkStructureType = .instance_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    pApplicationInfo: ?*const VkApplicationInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
};

const VkQueueFamilyProperties = extern struct {
    queueFlags: VkFlags,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

const VkMemoryType = extern struct {
    propertyFlags: VkFlags,
    heapIndex: u32,
};

const VkMemoryHeap = extern struct {
    size: VkDeviceSize,
    flags: VkFlags,
};

const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};

const VkDeviceQueueCreateInfo = extern struct {
    sType: VkStructureType = .device_queue_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    queueFamilyIndex: u32,
    queueCount: u32 = 1,
    pQueuePriorities: [*]const f32,
};

const VkDeviceCreateInfo = extern struct {
    sType: VkStructureType = .device_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    queueCreateInfoCount: u32 = 1,
    pQueueCreateInfos: [*]const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
    pEnabledFeatures: ?*const anyopaque = null,
};

const VkCommandPoolCreateInfo = extern struct {
    sType: VkStructureType = .command_pool_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0x00000002, // VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
    queueFamilyIndex: u32,
};

const VkCommandBufferAllocateInfo = extern struct {
    sType: VkStructureType = .command_buffer_allocate_info,
    pNext: ?*const anyopaque = null,
    commandPool: VkCommandPool,
    level: u32 = 0, // PRIMARY
    commandBufferCount: u32 = 1,
};

const VkCommandBufferBeginInfo = extern struct {
    sType: VkStructureType = .command_buffer_begin_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0x00000001, // ONE_TIME_SUBMIT_BIT
    pInheritanceInfo: ?*const anyopaque = null,
};

const VkSubmitInfo = extern struct {
    sType: VkStructureType = .submit_info,
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 0,
    pWaitSemaphores: ?*const anyopaque = null,
    pWaitDstStageMask: ?*const u32 = null,
    commandBufferCount: u32 = 1,
    pCommandBuffers: [*]const VkCommandBuffer,
    signalSemaphoreCount: u32 = 0,
    pSignalSemaphores: ?*const anyopaque = null,
};

const VkAttachmentDescription = extern struct {
    flags: VkFlags = 0,
    format: u32,
    samples: u32,
    loadOp: u32,
    storeOp: u32,
    stencilLoadOp: u32 = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
    stencilStoreOp: u32 = VK_ATTACHMENT_STORE_OP_DONT_CARE,
    initialLayout: u32 = VK_IMAGE_LAYOUT_UNDEFINED,
    finalLayout: u32,
};

const VkAttachmentReference = extern struct {
    attachment: u32,
    layout: u32,
};

const VkSubpassDescription = extern struct {
    flags: VkFlags = 0,
    pipelineBindPoint: u32 = VK_PIPELINE_BIND_POINT_GRAPHICS,
    inputAttachmentCount: u32 = 0,
    pInputAttachments: ?*const anyopaque = null,
    colorAttachmentCount: u32 = 1,
    pColorAttachments: [*]const VkAttachmentReference,
    pResolveAttachments: ?[*]const VkAttachmentReference = null,
    pDepthStencilAttachment: ?*const VkAttachmentReference = null,
    preserveAttachmentCount: u32 = 0,
    pPreserveAttachments: ?*const u32 = null,
};

const VkSubpassDependency = extern struct {
    srcSubpass: u32,
    dstSubpass: u32,
    srcStageMask: VkFlags,
    dstStageMask: VkFlags,
    srcAccessMask: VkFlags,
    dstAccessMask: VkFlags,
    dependencyFlags: VkFlags = 0,
};

const VkRenderPassCreateInfo = extern struct {
    sType: VkStructureType = .render_pass_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    attachmentCount: u32,
    pAttachments: [*]const VkAttachmentDescription,
    subpassCount: u32 = 1,
    pSubpasses: [*]const VkSubpassDescription,
    dependencyCount: u32 = 0,
    pDependencies: ?[*]const VkSubpassDependency = null,
};

const VkImageCreateInfo = extern struct {
    sType: VkStructureType = .image_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    imageType: u32 = 1, // 2D
    format: u32,
    extent: VkExtent3D,
    mipLevels: u32 = 1,
    arrayLayers: u32 = 1,
    samples: u32,
    tiling: u32 = 0, // OPTIMAL
    usage: VkFlags,
    sharingMode: u32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueQueueFamilyIndices: ?*const u32 = null,
    initialLayout: u32 = VK_IMAGE_LAYOUT_UNDEFINED,
};

const VkComponentMapping = extern struct {
    r: u32 = 0,
    g: u32 = 0,
    b: u32 = 0,
    a: u32 = 0,
};

const VkImageSubresourceRange = extern struct {
    aspectMask: VkFlags,
    baseMipLevel: u32 = 0,
    levelCount: u32 = 1,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 1,
};

const VkImageViewCreateInfo = extern struct {
    sType: VkStructureType = .image_view_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    image: VkImage,
    viewType: u32 = 1, // 2D
    format: u32,
    components: VkComponentMapping = .{},
    subresourceRange: VkImageSubresourceRange,
};

const VkFramebufferCreateInfo = extern struct {
    sType: VkStructureType = .framebuffer_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    renderPass: VkRenderPass,
    attachmentCount: u32,
    pAttachments: [*]const VkImageView,
    width: u32,
    height: u32,
    layers: u32 = 1,
};

const VkClearValue = extern union {
    color: [4]f32,
    depth_stencil: extern struct {
        depth: f32,
        stencil: u32,
    },
};

const VkRenderPassBeginInfo = extern struct {
    sType: VkStructureType = .render_pass_begin_info,
    pNext: ?*const anyopaque = null,
    renderPass: VkRenderPass,
    framebuffer: VkFramebuffer,
    renderArea: VkRect2D,
    clearValueCount: u32,
    pClearValues: [*]const VkClearValue,
};

const VkImageSubresourceLayers = extern struct {
    aspectMask: VkFlags = VK_IMAGE_ASPECT_COLOR_BIT,
    mipLevel: u32 = 0,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 1,
};

const VkImageCopy = extern struct {
    srcSubresource: VkImageSubresourceLayers = .{},
    srcOffset: VkOffset3D = .{},
    dstSubresource: VkImageSubresourceLayers = .{},
    dstOffset: VkOffset3D = .{},
    extent: VkExtent3D,
};

const VkBufferImageCopy = extern struct {
    bufferOffset: VkDeviceSize = 0,
    bufferRowLength: u32 = 0,
    bufferImageHeight: u32 = 0,
    imageSubresource: VkImageSubresourceLayers = .{},
    imageOffset: VkOffset3D = .{},
    imageExtent: VkExtent3D,
};

const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: u32,
    descriptorCount: u32 = 1,
    stageFlags: VkFlags,
    pImmutableSamplers: ?*const anyopaque = null,
};

const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: VkStructureType = .descriptor_set_layout_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    bindingCount: u32,
    pBindings: [*]const VkDescriptorSetLayoutBinding,
};

const VkDescriptorPoolSize = extern struct {
    type: u32,
    descriptorCount: u32,
};

const VkDescriptorPoolCreateInfo = extern struct {
    sType: VkStructureType = .descriptor_pool_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: [*]const VkDescriptorPoolSize,
};

const VkDescriptorSetAllocateInfo = extern struct {
    sType: VkStructureType = .descriptor_set_allocate_info,
    pNext: ?*const anyopaque = null,
    descriptorPool: VkDescriptorPool,
    descriptorSetCount: u32 = 1,
    pSetLayouts: [*]const VkDescriptorSetLayout,
};

const VkSamplerCreateInfo = extern struct {
    sType: VkStructureType = .sampler_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    magFilter: u32,
    minFilter: u32,
    mipmapMode: u32 = 0,
    addressModeU: u32 = 2, // CLAMP_TO_EDGE
    addressModeV: u32 = 2, // CLAMP_TO_EDGE
    addressModeW: u32 = 2, // CLAMP_TO_EDGE
    mipLodBias: f32 = 0.0,
    anisotropyEnable: VkBool32 = VK_FALSE,
    maxAnisotropy: f32 = 1.0,
    compareEnable: VkBool32 = VK_FALSE,
    compareOp: u32 = 0,
    minLod: f32 = 0.0,
    maxLod: f32 = 0.0,
    borderColor: u32 = 0,
    unnormalizedCoordinates: VkBool32 = VK_FALSE,
};

const VkDescriptorImageInfo = extern struct {
    sampler: VkSampler,
    imageView: VkImageView,
    imageLayout: u32,
};

const VkImageMemoryBarrier = extern struct {
    sType: VkStructureType = .image_memory_barrier,
    pNext: ?*const anyopaque = null,
    srcAccessMask: VkFlags,
    dstAccessMask: VkFlags,
    oldLayout: u32,
    newLayout: u32,
    srcQueueFamilyIndex: u32 = 0xFFFFFFFF,
    dstQueueFamilyIndex: u32 = 0xFFFFFFFF,
    image: VkImage,
    subresourceRange: VkImageSubresourceRange,
};

const VkDescriptorBufferInfo = extern struct {
    buffer: VkBuffer,
    offset: VkDeviceSize,
    range: VkDeviceSize,
};

const VkWriteDescriptorSet = extern struct {
    sType: VkStructureType = .write_descriptor_set,
    pNext: ?*const anyopaque = null,
    dstSet: VkDescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32 = 0,
    descriptorCount: u32 = 1,
    descriptorType: u32,
    pImageInfo: ?*const VkDescriptorImageInfo = null,
    pBufferInfo: ?*const VkDescriptorBufferInfo = null,
    pTexelBufferView: ?*const anyopaque = null,
};

const VkPipelineShaderStageCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_shader_stage_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    stage: VkFlags,
    module: VkShaderModule,
    pName: [*:0]const u8,
    pSpecializationInfo: ?*const anyopaque = null,
};

const VkVertexInputBindingDescription = extern struct {
    binding: u32 = 0,
    stride: u32,
    inputRate: u32 = 0, // VERTEX
};

const VkVertexInputAttributeDescription = extern struct {
    location: u32,
    binding: u32 = 0,
    format: u32,
    offset: u32,
};

const VkPipelineVertexInputStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_vertex_input_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    vertexBindingDescriptionCount: u32,
    pVertexBindingDescriptions: ?[*]const VkVertexInputBindingDescription,
    vertexAttributeDescriptionCount: u32,
    pVertexAttributeDescriptions: ?[*]const VkVertexInputAttributeDescription,
};

const VkPipelineInputAssemblyStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_input_assembly_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    topology: u32 = 3, // TRIANGLE_LIST
    primitiveRestartEnable: VkBool32 = VK_FALSE,
};

const VkPipelineViewportStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_viewport_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    viewportCount: u32 = 1,
    pViewports: ?*const VkViewport = null,
    scissorCount: u32 = 1,
    pScissors: ?*const VkRect2D = null,
};

const VkPipelineRasterizationStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_rasterization_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    depthClampEnable: VkBool32 = VK_FALSE,
    rasterizerDiscardEnable: VkBool32 = VK_FALSE,
    polygonMode: u32 = 0, // FILL
    cullMode: VkFlags = VK_CULL_MODE_BACK_BIT,
    frontFace: u32 = VK_FRONT_FACE_COUNTER_CLOCKWISE,
    depthBiasEnable: VkBool32 = VK_FALSE,
    depthBiasConstantFactor: f32 = 0,
    depthBiasClamp: f32 = 0,
    depthBiasSlopeFactor: f32 = 0,
    lineWidth: f32 = 1.0,
};

const VkPipelineMultisampleStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_multisample_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    rasterizationSamples: u32 = 4,
    sampleShadingEnable: VkBool32 = VK_FALSE,
    minSampleShading: f32 = 1.0,
    pSampleMask: ?*const u32 = null,
    alphaToCoverageEnable: VkBool32 = VK_FALSE,
    alphaToOneEnable: VkBool32 = VK_FALSE,
};

const VkStencilOpState = extern struct {
    failOp: u32 = 0,
    passOp: u32 = 0,
    depthFailOp: u32 = 0,
    compareOp: u32 = 0,
    compareMask: u32 = 0,
    writeMask: u32 = 0,
    reference: u32 = 0,
};

const VkPipelineDepthStencilStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_depth_stencil_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    depthTestEnable: VkBool32 = VK_TRUE,
    depthWriteEnable: VkBool32 = VK_TRUE,
    depthCompareOp: u32 = 3, // LESS_OR_EQUAL
    depthBoundsTestEnable: VkBool32 = VK_FALSE,
    stencilTestEnable: VkBool32 = VK_FALSE,
    front: VkStencilOpState = .{},
    back: VkStencilOpState = .{},
    minDepthBounds: f32 = 0.0,
    maxDepthBounds: f32 = 1.0,
};

const VkPipelineColorBlendAttachmentState = extern struct {
    blendEnable: VkBool32 = VK_FALSE,
    srcColorBlendFactor: u32 = 1,
    dstColorBlendFactor: u32 = 0,
    colorBlendOp: u32 = 0,
    srcAlphaBlendFactor: u32 = 1,
    dstAlphaBlendFactor: u32 = 0,
    alphaBlendOp: u32 = 0,
    colorWriteMask: VkFlags = 0xF,
};

const VkPipelineColorBlendStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_color_blend_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    logicOpEnable: VkBool32 = VK_FALSE,
    logicOp: u32 = 0,
    attachmentCount: u32 = 1,
    pAttachments: [*]const VkPipelineColorBlendAttachmentState,
    blendConstants: [4]f32 = .{ 0, 0, 0, 0 },
};

const VkPipelineDynamicStateCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_dynamic_state_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    dynamicStateCount: u32,
    pDynamicStates: [*]const u32,
};

const VkPushConstantRange = extern struct {
    stageFlags: VkFlags,
    offset: u32 = 0,
    size: u32,
};

const VkPipelineLayoutCreateInfo = extern struct {
    sType: VkStructureType = .pipeline_layout_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    setLayoutCount: u32,
    pSetLayouts: ?[*]const VkDescriptorSetLayout,
    pushConstantRangeCount: u32 = 0,
    pPushConstantRanges: ?[*]const VkPushConstantRange = null,
};

const VkGraphicsPipelineCreateInfo = extern struct {
    sType: VkStructureType = .graphics_pipeline_create_info,
    pNext: ?*const anyopaque = null,
    flags: VkFlags = 0,
    stageCount: u32 = 2,
    pStages: [*]const VkPipelineShaderStageCreateInfo,
    pVertexInputState: *const VkPipelineVertexInputStateCreateInfo,
    pInputAssemblyState: *const VkPipelineInputAssemblyStateCreateInfo,
    pTessellationState: ?*const anyopaque = null,
    pViewportState: *const VkPipelineViewportStateCreateInfo,
    pRasterizationState: *const VkPipelineRasterizationStateCreateInfo,
    pMultisampleState: *const VkPipelineMultisampleStateCreateInfo,
    pDepthStencilState: *const VkPipelineDepthStencilStateCreateInfo,
    pColorBlendState: *const VkPipelineColorBlendStateCreateInfo,
    pDynamicState: *const VkPipelineDynamicStateCreateInfo,
    layout: VkPipelineLayout,
    renderPass: VkRenderPass,
    subpass: u32 = 0,
    basePipelineHandle: VkPipeline = VK_NULL_HANDLE,
    basePipelineIndex: i32 = -1,
};

const GetInstanceProcAddr = *const fn (?VkInstance, [*:0]const u8) callconv(.c) ?*const anyopaque;

const InstanceProcs = struct {
    DestroyInstance: *const fn (VkInstance, ?*const anyopaque) callconv(.c) void,
    EnumeratePhysicalDevices: *const fn (VkInstance, *u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult,
    GetPhysicalDeviceQueueFamilyProperties: *const fn (VkPhysicalDevice, *u32, ?[*]VkQueueFamilyProperties) callconv(.c) void,
    GetPhysicalDeviceMemoryProperties: *const fn (VkPhysicalDevice, *VkPhysicalDeviceMemoryProperties) callconv(.c) void,
    CreateDevice: *const fn (VkPhysicalDevice, *const VkDeviceCreateInfo, ?*const anyopaque, *VkDevice) callconv(.c) VkResult,
    EnumerateDeviceExtensionProperties: *const fn (VkPhysicalDevice, ?[*:0]const u8, *u32, ?[*]VkExtensionProperties) callconv(.c) VkResult,
    GetDeviceProcAddr: GetDeviceProcAddr,

    fn load(instance: VkInstance, get_proc: GetInstanceProcAddr) !InstanceProcs {
        var p: InstanceProcs = undefined;
        inline for (@typeInfo(InstanceProcs).@"struct".field_names) |field_name| {
            const name: [*:0]const u8 = "vk" ++ field_name;
            const sym = get_proc(instance, name) orelse return error.MissingVulkanFunction;
            @field(p, field_name) = @ptrCast(@alignCast(sym));
        }
        return p;
    }
};

/// Full Vulkan device function table available on `VulkanContext.vk`.
pub const ContextProcs = struct {
    DestroyDevice: *const fn (VkDevice, ?*const anyopaque) callconv(.c) void,
    GetDeviceQueue: *const fn (VkDevice, u32, u32, *VkQueue) callconv(.c) void,
    CreateCommandPool: *const fn (VkDevice, *const VkCommandPoolCreateInfo, ?*const anyopaque, *VkCommandPool) callconv(.c) VkResult,
    DestroyCommandPool: *const fn (VkDevice, VkCommandPool, ?*const anyopaque) callconv(.c) void,
    AllocateCommandBuffers: *const fn (VkDevice, *const VkCommandBufferAllocateInfo, [*]VkCommandBuffer) callconv(.c) VkResult,
    ResetCommandBuffer: *const fn (VkCommandBuffer, VkFlags) callconv(.c) VkResult,
    BeginCommandBuffer: *const fn (VkCommandBuffer, *const VkCommandBufferBeginInfo) callconv(.c) VkResult,
    EndCommandBuffer: *const fn (VkCommandBuffer) callconv(.c) VkResult,
    QueueSubmit: *const fn (VkQueue, u32, [*]const VkSubmitInfo, VkFence) callconv(.c) VkResult,
    QueueWaitIdle: *const fn (VkQueue) callconv(.c) VkResult,
    DeviceWaitIdle: *const fn (VkDevice) callconv(.c) VkResult,
    CreateRenderPass: *const fn (VkDevice, *const VkRenderPassCreateInfo, ?*const anyopaque, *VkRenderPass) callconv(.c) VkResult,
    DestroyRenderPass: *const fn (VkDevice, VkRenderPass, ?*const anyopaque) callconv(.c) void,
    CreateFramebuffer: *const fn (VkDevice, *const VkFramebufferCreateInfo, ?*const anyopaque, *VkFramebuffer) callconv(.c) VkResult,
    DestroyFramebuffer: *const fn (VkDevice, VkFramebuffer, ?*const anyopaque) callconv(.c) void,
    CreateImage: *const fn (VkDevice, *const VkImageCreateInfo, ?*const anyopaque, *VkImage) callconv(.c) VkResult,
    DestroyImage: *const fn (VkDevice, VkImage, ?*const anyopaque) callconv(.c) void,
    GetImageMemoryRequirements: *const fn (VkDevice, VkImage, *VkMemoryRequirements) callconv(.c) void,
    BindImageMemory: *const fn (VkDevice, VkImage, VkDeviceMemory, VkDeviceSize) callconv(.c) VkResult,
    CreateImageView: *const fn (VkDevice, *const VkImageViewCreateInfo, ?*const anyopaque, *VkImageView) callconv(.c) VkResult,
    DestroyImageView: *const fn (VkDevice, VkImageView, ?*const anyopaque) callconv(.c) void,
    CreateShaderModule: *const fn (VkDevice, *const VkShaderModuleCreateInfo, ?*const anyopaque, *VkShaderModule) callconv(.c) VkResult,
    DestroyShaderModule: *const fn (VkDevice, VkShaderModule, ?*const anyopaque) callconv(.c) void,
    CreateDescriptorSetLayout: *const fn (VkDevice, *const VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, *VkDescriptorSetLayout) callconv(.c) VkResult,
    DestroyDescriptorSetLayout: *const fn (VkDevice, VkDescriptorSetLayout, ?*const anyopaque) callconv(.c) void,
    CreateDescriptorPool: *const fn (VkDevice, *const VkDescriptorPoolCreateInfo, ?*const anyopaque, *VkDescriptorPool) callconv(.c) VkResult,
    DestroyDescriptorPool: *const fn (VkDevice, VkDescriptorPool, ?*const anyopaque) callconv(.c) void,
    AllocateDescriptorSets: *const fn (VkDevice, *const VkDescriptorSetAllocateInfo, [*]VkDescriptorSet) callconv(.c) VkResult,
    FreeDescriptorSets: *const fn (VkDevice, VkDescriptorPool, u32, [*]const VkDescriptorSet) callconv(.c) VkResult,
    UpdateDescriptorSets: *const fn (VkDevice, u32, [*]const VkWriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void,
    CreateSampler: *const fn (VkDevice, *const VkSamplerCreateInfo, ?*const anyopaque, *VkSampler) callconv(.c) VkResult,
    DestroySampler: *const fn (VkDevice, VkSampler, ?*const anyopaque) callconv(.c) void,
    CreatePipelineLayout: *const fn (VkDevice, *const VkPipelineLayoutCreateInfo, ?*const anyopaque, *VkPipelineLayout) callconv(.c) VkResult,
    DestroyPipelineLayout: *const fn (VkDevice, VkPipelineLayout, ?*const anyopaque) callconv(.c) void,
    CreateGraphicsPipelines: *const fn (VkDevice, VkPipelineCache, u32, [*]const VkGraphicsPipelineCreateInfo, ?*const anyopaque, [*]VkPipeline) callconv(.c) VkResult,
    DestroyPipeline: *const fn (VkDevice, VkPipeline, ?*const anyopaque) callconv(.c) void,
    CreateBuffer: *const fn (VkDevice, *const VkBufferCreateInfo, ?*const anyopaque, *VkBuffer) callconv(.c) VkResult,
    DestroyBuffer: *const fn (VkDevice, VkBuffer, ?*const anyopaque) callconv(.c) void,
    GetBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, *VkMemoryRequirements) callconv(.c) void,
    AllocateMemory: *const fn (VkDevice, *const VkMemoryAllocateInfo, ?*const anyopaque, *VkDeviceMemory) callconv(.c) VkResult,
    FreeMemory: *const fn (VkDevice, VkDeviceMemory, ?*const anyopaque) callconv(.c) void,
    BindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize) callconv(.c) VkResult,
    MapMemory: *const fn (VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkFlags, *?*anyopaque) callconv(.c) VkResult,
    UnmapMemory: *const fn (VkDevice, VkDeviceMemory) callconv(.c) void,
    CmdBeginRenderPass: *const fn (VkCommandBuffer, *const VkRenderPassBeginInfo, u32) callconv(.c) void,
    CmdEndRenderPass: *const fn (VkCommandBuffer) callconv(.c) void,
    CmdBindPipeline: *const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void,
    CmdSetViewport: *const fn (VkCommandBuffer, u32, u32, [*]const VkViewport) callconv(.c) void,
    CmdSetScissor: *const fn (VkCommandBuffer, u32, u32, [*]const VkRect2D) callconv(.c) void,
    CmdBindVertexBuffers: *const fn (VkCommandBuffer, u32, u32, [*]const VkBuffer, [*]const VkDeviceSize) callconv(.c) void,
    CmdBindIndexBuffer: *const fn (VkCommandBuffer, VkBuffer, VkDeviceSize, u32) callconv(.c) void,
    CmdBindDescriptorSets: *const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, [*]const VkDescriptorSet, u32, ?[*]const u32) callconv(.c) void,
    CmdPushConstants: *const fn (VkCommandBuffer, VkPipelineLayout, VkFlags, u32, u32, *const anyopaque) callconv(.c) void,
    CmdDraw: *const fn (VkCommandBuffer, u32, u32, u32, u32) callconv(.c) void,
    CmdDrawIndexed: *const fn (VkCommandBuffer, u32, u32, u32, i32, u32) callconv(.c) void,
    CmdCopyBufferToImage: *const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, [*]const VkBufferImageCopy) callconv(.c) void,
    CmdCopyImageToBuffer: *const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, [*]const VkBufferImageCopy) callconv(.c) void,
    CmdCopyImage: *const fn (VkCommandBuffer, VkImage, u32, VkImage, u32, u32, [*]const VkImageCopy) callconv(.c) void,
    CmdBlitImage: *const fn (VkCommandBuffer, VkImage, u32, VkImage, u32, u32, [*]const VkImageBlit, u32) callconv(.c) void,
    CmdPipelineBarrier: *const fn (VkCommandBuffer, VkFlags, VkFlags, VkFlags, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?[*]const VkImageMemoryBarrier) callconv(.c) void,

    pub fn load(device: VkDevice, get_proc: GetDeviceProcAddr) !ContextProcs {
        var p: ContextProcs = undefined;
        inline for (@typeInfo(ContextProcs).@"struct".field_names) |field_name| {
            const name: [*:0]const u8 = "vk" ++ field_name;
            const sym = get_proc(device, name) orelse return error.MissingVulkanFunction;
            @field(p, field_name) = @ptrCast(@alignCast(sym));
        }
        return p;
    }
};

const Owned2DContext = struct {
    const GpuTexture = struct {
        img: VkImage,
        mem: VkDeviceMemory,
        view: VkImageView,
        set: VkDescriptorSet,
    };

    gpa: std.mem.Allocator,
    vk_lib: std.DynLib,
    instance: VkInstance,
    inst_procs: InstanceProcs,
    phys_dev: VkPhysicalDevice,
    mem_props: VkPhysicalDeviceMemoryProperties,
    host_mem_type: u32,
    device: VkDevice,
    vk: ContextProcs,
    queue: VkQueue,
    cmd_pool: VkCommandPool = VK_NULL_HANDLE,
    cmd: VkCommandBuffer = undefined,
    upload_cmd: VkCommandBuffer = undefined,
    render_pass: VkRenderPass = VK_NULL_HANDLE,
    set_layout: VkDescriptorSetLayout = VK_NULL_HANDLE,
    desc_pool: VkDescriptorPool = VK_NULL_HANDLE,
    nearest_sampler: VkSampler = VK_NULL_HANDLE,
    linear_sampler: VkSampler = VK_NULL_HANDLE,
    pipelines: Pipelines = .{},

    atlas_img: VkImage = VK_NULL_HANDLE,
    atlas_mem: VkDeviceMemory = VK_NULL_HANDLE,
    atlas_view: VkImageView = VK_NULL_HANDLE,
    atlas_set: VkDescriptorSet = VK_NULL_HANDLE,
    atlas_initialized: bool = false,

    upload_buf: VkBuffer = VK_NULL_HANDLE,
    upload_mem: VkDeviceMemory = VK_NULL_HANDLE,
    upload_map: []u8 = &.{},

    textures: std.AutoHashMapUnmanaged(u64, GpuTexture) = .empty,

    fb_w: u32 = 0,
    fb_h: u32 = 0,
    color_img: VkImage = VK_NULL_HANDLE,
    color_mem: VkDeviceMemory = VK_NULL_HANDLE,
    color_view: VkImageView = VK_NULL_HANDLE,
    framebuffer: VkFramebuffer = VK_NULL_HANDLE,
    staging_buf: VkBuffer = VK_NULL_HANDLE,
    staging_mem: VkDeviceMemory = VK_NULL_HANDLE,
    staging_map: []u32 = &.{},

    queue_family: u32 = 0,
    /// Drawing straight into window buffers (`renderDirect`), when the
    /// device can import dmabufs: a render pass that keeps what is there,
    /// a fence to wait for a frame, and the buffers imported.
    dmabuf: ?DmabufProcs = null,
    direct_pass: VkRenderPass = VK_NULL_HANDLE,
    fence: VkFence = VK_NULL_HANDLE,
    imports: [max_imports]?DmabufImport = @splat(null),
    import_clock: u64 = 0,
    /// Pictures drawn on other APIs (OpenGL), imported to copy in.
    sources: [max_imports]?SourceImport = @splat(null),
    /// Waiting on GPU work done elsewhere, if the device can: on timeline
    /// semaphores (`DirectFrame.wait`), and on sync files (a picture's
    /// `ready_fd`); and what the frame being drawn waits on.
    timelines: ?TimelineProcs = null,
    sync_fd: ?SyncFdProcs = null,
    frame_waits: SubmitWaits = .{},
    retired_sources: std.ArrayList(RetiredSource) = .empty,
    /// Drawing a window's frame (`drawFrame`): the shader, pipelines that
    /// round its corners (`mask`) and put its shadow under it (`under`),
    /// and the vertices.
    frame_module: VkShaderModule = VK_NULL_HANDLE,
    frame_mask: VkPipeline = VK_NULL_HANDLE,
    frame_under: VkPipeline = VK_NULL_HANDLE,
    frame_vbo: VkBuffer = VK_NULL_HANDLE,
    frame_mem: VkDeviceMemory = VK_NULL_HANDLE,
    frame_map: []f32 = &.{},

    /// The margin's 4 quads, and each corner's 2.
    const frame_vertices = (4 + 4 * 2) * 6;

    const max_imports = 8;

    const RetiredSource = struct {
        img: VkImage,
        mem: VkDeviceMemory,
    };

    const SourceImport = struct {
        id: u64,
        width: u32,
        height: u32,
        img: VkImage,
        mem: VkDeviceMemory,
        used: u64 = 0,
    };

    /// A window buffer imported as an image to draw into.
    const DmabufImport = struct {
        id: u64,
        width: u32,
        height: u32,
        img: VkImage,
        mem: VkDeviceMemory,
        view: VkImageView,
        framebuffer: VkFramebuffer,
        /// When it was last drawn into (`import_clock`), to free the
        /// longest unused when another is needed.
        used: u64 = 0,
        /// It has been drawn into, so its layout is `GENERAL`.
        initialized: bool = false,
        /// The window's shadow has been drawn in its margin.
        frame_drawn: bool = false,
    };

    fn hasExtensions(procs: InstanceProcs, phys: VkPhysicalDevice, names: []const [*:0]const u8) bool {
        var count: u32 = 0;
        if (procs.EnumerateDeviceExtensionProperties(phys, null, &count, null) != .success) return false;
        var props: [512]VkExtensionProperties = undefined;
        count = @min(count, props.len);
        if (procs.EnumerateDeviceExtensionProperties(phys, null, &count, &props) != .success) return false;
        for (names) |name| {
            const want = std.mem.span(name);
            const found = for (props[0..count]) |e| {
                if (std.mem.eql(u8, std.mem.sliceTo(&e.extensionName, 0), want)) break true;
            } else false;
            if (!found) return false;
        }
        return true;
    }

    fn create(gpa: std.mem.Allocator) !*Owned2DContext {
        var vk_lib = std.DynLib.open("libvulkan.so.1") catch try std.DynLib.open("libvulkan.so");
        errdefer vk_lib.close();

        const get_inst_proc = vk_lib.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.MissingVkGetInstanceProcAddr;
        const create_instance: *const fn (*const VkInstanceCreateInfo, ?*const anyopaque, *VkInstance) callconv(.c) VkResult =
            @ptrCast(@alignCast(get_inst_proc(null, "vkCreateInstance") orelse return error.MissingVkCreateInstance));

        const app_info: VkApplicationInfo = .{};
        const inst_info: VkInstanceCreateInfo = .{ .pApplicationInfo = &app_info };
        var instance: VkInstance = undefined;
        if (create_instance(&inst_info, null, &instance) != .success) return error.VkCreateInstanceFailed;

        const inst_procs = try InstanceProcs.load(instance, get_inst_proc);
        errdefer inst_procs.DestroyInstance(instance, null);

        var dev_count: u32 = 0;
        if (inst_procs.EnumeratePhysicalDevices(instance, &dev_count, null) != .success or dev_count == 0) {
            return error.NoVulkanPhysicalDevice;
        }
        var phys_devs: [16]VkPhysicalDevice = undefined;
        var count: u32 = @min(dev_count, phys_devs.len);
        _ = inst_procs.EnumeratePhysicalDevices(instance, &count, &phys_devs);

        var chosen_phys: ?VkPhysicalDevice = null;
        var chosen_qfam: u32 = 0;
        outer: for (phys_devs[0..count]) |pd| {
            var qf_count: u32 = 0;
            inst_procs.GetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, null);
            var qfs: [16]VkQueueFamilyProperties = undefined;
            var qc: u32 = @min(qf_count, qfs.len);
            inst_procs.GetPhysicalDeviceQueueFamilyProperties(pd, &qc, &qfs);
            for (qfs[0..qc], 0..) |qf, qi| {
                if ((qf.queueFlags & 0x00000001) != 0) {
                    chosen_phys = pd;
                    chosen_qfam = @intCast(qi);
                    break :outer;
                }
            }
        }
        const phys_dev = chosen_phys orelse return error.NoVulkanGraphicsQueue;

        var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
        inst_procs.GetPhysicalDeviceMemoryProperties(phys_dev, &mem_props);

        var host_mem_type: ?u32 = null;
        const req_host = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        for (0..mem_props.memoryTypeCount) |i| {
            if ((mem_props.memoryTypes[i].propertyFlags & req_host) == req_host) {
                host_mem_type = @intCast(i);
                break;
            }
        }
        const host_mt = host_mem_type orelse return error.NoSuitableVulkanMemoryType;

        const prio = [1]f32{1.0};
        const q_info = [1]VkDeviceQueueCreateInfo{.{
            .queueFamilyIndex = chosen_qfam,
            .pQueuePriorities = &prio,
        }};
        // With dmabuf import if it can, to draw straight into window buffers.
        var with_dmabuf = hasExtensions(inst_procs, phys_dev, &dmabuf_extensions);
        var device: VkDevice = undefined;
        var extensions: DeviceExtensions = undefined;
        if (with_dmabuf) {
            extensions = .init(inst_procs, phys_dev, &dmabuf_extensions);
            const dev_info = extensions.createInfo(&q_info);
            if (inst_procs.CreateDevice(phys_dev, &dev_info, null, &device) != .success) with_dmabuf = false;
        }
        if (!with_dmabuf) {
            extensions = .init(inst_procs, phys_dev, &.{});
            const dev_info = extensions.createInfo(&q_info);
            if (inst_procs.CreateDevice(phys_dev, &dev_info, null, &device) != .success) return error.VkCreateDeviceFailed;
        }

        const vk = try ContextProcs.load(device, inst_procs.GetDeviceProcAddr);
        var queue: VkQueue = undefined;
        vk.GetDeviceQueue(device, chosen_qfam, 0, &queue);

        const self = try gpa.create(Owned2DContext);
        self.* = .{
            .gpa = gpa,
            .vk_lib = vk_lib,
            .instance = instance,
            .inst_procs = inst_procs,
            .phys_dev = phys_dev,
            .mem_props = mem_props,
            .host_mem_type = host_mt,
            .device = device,
            .vk = vk,
            .queue = queue,
            .queue_family = chosen_qfam,
        };
        errdefer self.destroy();
        if (extensions.timelines) self.timelines = loadProcs(TimelineProcs, device, inst_procs.GetDeviceProcAddr);
        if (extensions.sync_fd) self.sync_fd = loadProcs(SyncFdProcs, device, inst_procs.GetDeviceProcAddr);
        if (with_dmabuf) self.initDirect(inst_procs.GetDeviceProcAddr);

        const pool_info: VkCommandPoolCreateInfo = .{ .queueFamilyIndex = chosen_qfam };
        if (self.vk.CreateCommandPool(device, &pool_info, null, &self.cmd_pool) != .success) return error.VkCreateCommandPoolFailed;

        const cb_info: VkCommandBufferAllocateInfo = .{ .commandPool = self.cmd_pool, .commandBufferCount = 2 };
        var cmds: [2]VkCommandBuffer = undefined;
        if (self.vk.AllocateCommandBuffers(device, &cb_info, &cmds) != .success) return error.VkAllocateCommandBufferFailed;
        self.cmd = cmds[0];
        self.upload_cmd = cmds[1];

        const attachments = [1]VkAttachmentDescription{.{
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .samples = 1,
            .loadOp = VK_ATTACHMENT_LOAD_OP_LOAD,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        }};
        const color_ref = [1]VkAttachmentReference{.{
            .attachment = 0,
            .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        }};
        const subpass = [1]VkSubpassDescription{.{
            .pColorAttachments = &color_ref,
        }};
        const rp_info: VkRenderPassCreateInfo = .{
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .pSubpasses = &subpass,
        };
        if (self.vk.CreateRenderPass(device, &rp_info, null, &self.render_pass) != .success) return error.VkCreateRenderPassFailed;

        const bindings = [1]VkDescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        }};
        const dsl_info: VkDescriptorSetLayoutCreateInfo = .{
            .bindingCount = 1,
            .pBindings = &bindings,
        };
        if (self.vk.CreateDescriptorSetLayout(device, &dsl_info, null, &self.set_layout) != .success) return error.VkCreateDescriptorSetLayoutFailed;

        const pool_sizes = [1]VkDescriptorPoolSize{.{
            .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 256,
        }};
        const dp_info: VkDescriptorPoolCreateInfo = .{
            .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
            .maxSets = 256,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_sizes,
        };
        if (self.vk.CreateDescriptorPool(device, &dp_info, null, &self.desc_pool) != .success) return error.VkCreateDescriptorPoolFailed;

        const nearest_info: VkSamplerCreateInfo = .{ .magFilter = 0, .minFilter = 0 };
        if (self.vk.CreateSampler(device, &nearest_info, null, &self.nearest_sampler) != .success) return error.VkCreateSamplerFailed;

        const linear_info: VkSamplerCreateInfo = .{ .magFilter = 1, .minFilter = 1 };
        if (self.vk.CreateSampler(device, &linear_info, null, &self.linear_sampler) != .success) return error.VkCreateSamplerFailed;

        return self;
    }

    fn initPipelines(self: *Owned2DContext, mods: ShaderModules) !void {
        const set_layouts = [1]VkDescriptorSetLayout{self.set_layout};
        const pl_info: VkPipelineLayoutCreateInfo = .{
            .setLayoutCount = 1,
            .pSetLayouts = &set_layouts,
        };
        if (self.vk.CreatePipelineLayout(self.device, &pl_info, null, &self.pipelines.layout) != .success) {
            return error.VkCreatePipelineLayoutFailed;
        }
        self.pipelines.shape = try self.create2DPipeline(mods.shape, shaders.shape_layout, .over);
        self.pipelines.solid = try self.create2DPipeline(mods.solid, shaders.solid_layout, .over);
        self.pipelines.@"opaque" = try self.create2DPipeline(mods.solid, shaders.solid_layout, .none);
        self.pipelines.text = try self.create2DPipeline(mods.text, shaders.text_layout, .over);
        self.pipelines.image = try self.create2DPipeline(mods.image, shaders.text_layout, .over);
        if (self.dmabuf != null) self.initFrame();
    }

    /// How a pipeline's output goes with what is there: replacing it,
    /// source-over, multiplying it by the output's alpha (`mask`), or under
    /// it (`under`, premultiplied).
    const Blend = enum { none, over, mask, under };

    fn create2DPipeline(self: *Owned2DContext, shader_mod: VkShaderModule, layout: shaders.Layout, blend: Blend) !VkPipeline {
        const stages = [2]VkPipelineShaderStageCreateInfo{
            .{ .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = shader_mod, .pName = "vertex" },
            .{ .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = shader_mod, .pName = "fragment" },
        };
        const binding = [1]VkVertexInputBindingDescription{.{ .stride = layout.vertex_stride }};
        var attrs: [8]VkVertexInputAttributeDescription = undefined;
        const attr_count = @min(layout.attributes.len, attrs.len);
        for (layout.attributes[0..attr_count], attrs[0..attr_count]) |a, *out| {
            out.* = .{
                .location = a.location,
                .format = switch (a.components) {
                    1 => VK_FORMAT_R32_SFLOAT,
                    2 => VK_FORMAT_R32G32_SFLOAT,
                    3 => VK_FORMAT_R32G32B32_SFLOAT,
                    else => VK_FORMAT_R32G32B32A32_SFLOAT,
                },
                .offset = a.offset,
            };
        }
        const vertex_input: VkPipelineVertexInputStateCreateInfo = .{
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding,
            .vertexAttributeDescriptionCount = @intCast(attr_count),
            .pVertexAttributeDescriptions = &attrs,
        };
        const input_assembly: VkPipelineInputAssemblyStateCreateInfo = .{};
        const viewport_state: VkPipelineViewportStateCreateInfo = .{};
        const raster: VkPipelineRasterizationStateCreateInfo = .{
            .cullMode = VK_CULL_MODE_NONE,
            .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
        };
        const multisample: VkPipelineMultisampleStateCreateInfo = .{
            .rasterizationSamples = 1,
        };
        const depth_stencil: VkPipelineDepthStencilStateCreateInfo = .{
            .depthTestEnable = VK_FALSE,
            .depthWriteEnable = VK_FALSE,
        };
        // VK_BLEND_FACTOR_ZERO 0, ONE 1, SRC_ALPHA 6, ONE_MINUS_SRC_ALPHA 7,
        // ONE_MINUS_DST_ALPHA 9; VK_BLEND_OP_ADD 0.
        const blend_att = [1]VkPipelineColorBlendAttachmentState{switch (blend) {
            .none => .{ .blendEnable = VK_FALSE, .colorWriteMask = 0xF },
            .over => .{ .blendEnable = VK_TRUE, .srcColorBlendFactor = 6, .dstColorBlendFactor = 7, .colorBlendOp = 0, .srcAlphaBlendFactor = 1, .dstAlphaBlendFactor = 7, .alphaBlendOp = 0, .colorWriteMask = 0xF },
            .mask => .{ .blendEnable = VK_TRUE, .srcColorBlendFactor = 0, .dstColorBlendFactor = 6, .colorBlendOp = 0, .srcAlphaBlendFactor = 0, .dstAlphaBlendFactor = 6, .alphaBlendOp = 0, .colorWriteMask = 0xF },
            .under => .{ .blendEnable = VK_TRUE, .srcColorBlendFactor = 9, .dstColorBlendFactor = 1, .colorBlendOp = 0, .srcAlphaBlendFactor = 9, .dstAlphaBlendFactor = 1, .alphaBlendOp = 0, .colorWriteMask = 0xF },
        }};
        const color_blend: VkPipelineColorBlendStateCreateInfo = .{ .pAttachments = &blend_att };
        const dyn_states = [2]u32{ 0, 1 }; // VIEWPORT, SCISSOR
        const dynamic_state: VkPipelineDynamicStateCreateInfo = .{
            .dynamicStateCount = dyn_states.len,
            .pDynamicStates = &dyn_states,
        };
        const gp_info = [1]VkGraphicsPipelineCreateInfo{.{
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pViewportState = &viewport_state,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blend,
            .pDynamicState = &dynamic_state,
            .layout = self.pipelines.layout,
            .renderPass = self.render_pass,
        }};
        var out_pipe: [1]VkPipeline = undefined;
        if (self.vk.CreateGraphicsPipelines(self.device, VK_NULL_HANDLE, 1, &gp_info, null, &out_pipe) != .success) {
            return error.VkCreateGraphicsPipelineFailed;
        }
        return out_pipe[0];
    }

    fn destroy(self: *Owned2DContext) void {
        _ = self.vk.DeviceWaitIdle(self.device);
        self.destroyTarget();
        for (&self.imports) |*slot| if (slot.*) |*im| {
            self.destroyImport(im);
            slot.* = null;
        };
        for (&self.sources) |*slot| if (slot.*) |*src| {
            self.vk.DestroyImage(self.device, src.img, null);
            self.vk.FreeMemory(self.device, src.mem, null);
            slot.* = null;
        };
        for (self.retired_sources.items) |src| {
            self.vk.DestroyImage(self.device, src.img, null);
            self.vk.FreeMemory(self.device, src.mem, null);
        }
        self.retired_sources.deinit(self.gpa);
        self.clearFrameWaits();
        if (self.dmabuf) |d| if (self.fence != VK_NULL_HANDLE) d.DestroyFence(self.device, self.fence, null);
        self.destroyFrame();
        if (self.direct_pass != VK_NULL_HANDLE) self.vk.DestroyRenderPass(self.device, self.direct_pass, null);
        if (self.upload_map.len > 0) self.vk.UnmapMemory(self.device, self.upload_mem);
        if (self.upload_buf != VK_NULL_HANDLE) self.vk.DestroyBuffer(self.device, self.upload_buf, null);
        if (self.upload_mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, self.upload_mem, null);

        var it = self.textures.valueIterator();
        while (it.next()) |t| {
            if (t.view != VK_NULL_HANDLE) self.vk.DestroyImageView(self.device, t.view, null);
            if (t.img != VK_NULL_HANDLE) self.vk.DestroyImage(self.device, t.img, null);
            if (t.mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, t.mem, null);
        }
        self.textures.deinit(self.gpa);

        if (self.atlas_view != VK_NULL_HANDLE) self.vk.DestroyImageView(self.device, self.atlas_view, null);
        if (self.atlas_img != VK_NULL_HANDLE) self.vk.DestroyImage(self.device, self.atlas_img, null);
        if (self.atlas_mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, self.atlas_mem, null);

        for ([_]VkPipeline{
            self.pipelines.shape,
            self.pipelines.solid,
            self.pipelines.@"opaque",
            self.pipelines.text,
            self.pipelines.image,
        }) |p| {
            if (p != VK_NULL_HANDLE) self.vk.DestroyPipeline(self.device, p, null);
        }
        if (self.pipelines.layout != VK_NULL_HANDLE) self.vk.DestroyPipelineLayout(self.device, self.pipelines.layout, null);
        if (self.nearest_sampler != VK_NULL_HANDLE) self.vk.DestroySampler(self.device, self.nearest_sampler, null);
        if (self.linear_sampler != VK_NULL_HANDLE) self.vk.DestroySampler(self.device, self.linear_sampler, null);
        if (self.desc_pool != VK_NULL_HANDLE) self.vk.DestroyDescriptorPool(self.device, self.desc_pool, null);
        if (self.set_layout != VK_NULL_HANDLE) self.vk.DestroyDescriptorSetLayout(self.device, self.set_layout, null);
        if (self.render_pass != VK_NULL_HANDLE) self.vk.DestroyRenderPass(self.device, self.render_pass, null);
        if (self.cmd_pool != VK_NULL_HANDLE) self.vk.DestroyCommandPool(self.device, self.cmd_pool, null);
        self.vk.DestroyDevice(self.device, null);
        self.inst_procs.DestroyInstance(self.instance, null);
        self.vk_lib.close();
        self.gpa.destroy(self);
    }

    fn findMemoryType(self: *const Owned2DContext, type_bits: u32, req_flags: VkFlags) !u32 {
        for (0..self.mem_props.memoryTypeCount) |i| {
            const bit = @as(u32, 1) << @intCast(i);
            if ((type_bits & bit) != 0 and (self.mem_props.memoryTypes[i].propertyFlags & req_flags) == req_flags) {
                return @intCast(i);
            }
        }
        return error.NoSuitableVulkanMemoryType;
    }

    fn ensureUploadBuf(self: *Owned2DContext, min_bytes: usize) !void {
        if (self.upload_map.len >= min_bytes) return;
        if (self.upload_map.len > 0) {
            self.vk.UnmapMemory(self.device, self.upload_mem);
            self.upload_map = &.{};
        }
        if (self.upload_buf != VK_NULL_HANDLE) {
            self.vk.DestroyBuffer(self.device, self.upload_buf, null);
            self.upload_buf = VK_NULL_HANDLE;
        }
        if (self.upload_mem != VK_NULL_HANDLE) {
            self.vk.FreeMemory(self.device, self.upload_mem, null);
            self.upload_mem = VK_NULL_HANDLE;
        }
        const cap = std.mem.alignForward(usize, min_bytes, 64 * 1024);
        const buf_info: VkBufferCreateInfo = .{
            .size = cap,
            .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        };
        if (self.vk.CreateBuffer(self.device, &buf_info, null, &self.upload_buf) != .success) return error.VkCreateBufferFailed;
        var req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(self.device, self.upload_buf, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = @max(req.size, cap),
            .memoryTypeIndex = mem_type,
        };
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &self.upload_mem) != .success) return error.VkAllocateMemoryFailed;
        if (self.vk.BindBufferMemory(self.device, self.upload_buf, self.upload_mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        var ptr: ?*anyopaque = null;
        if (self.vk.MapMemory(self.device, self.upload_mem, 0, cap, 0, &ptr) != .success or ptr == null) return error.VkMapMemoryFailed;
        self.upload_map = @as([*]u8, @ptrCast(ptr.?))[0..cap];
    }

    fn textureHooks(self: *Owned2DContext) TextureHooks {
        return .{
            .ctx = self,
            .uploadAtlas = uploadAtlasHook,
            .acquireImage = acquireImageHook,
            .releaseImage = releaseImageHook,
        };
    }

    fn uploadAtlasHook(raw: ?*anyopaque, pixels: []const u8, width: u32, height: u32, y0: u32, y1: u32) anyerror!VkDescriptorSet {
        const self: *Owned2DContext = @ptrCast(@alignCast(raw.?));
        if (self.atlas_img == VK_NULL_HANDLE) {
            const img_info: VkImageCreateInfo = .{
                .format = VK_FORMAT_R8_UNORM,
                .extent = .{ .width = width, .height = height },
                .samples = 1,
                .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            };
            if (self.vk.CreateImage(self.device, &img_info, null, &self.atlas_img) != .success) return error.VkCreateImageFailed;
            var req: VkMemoryRequirements = undefined;
            self.vk.GetImageMemoryRequirements(self.device, self.atlas_img, &req);
            const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
            const alloc_info: VkMemoryAllocateInfo = .{ .allocationSize = req.size, .memoryTypeIndex = mem_type };
            if (self.vk.AllocateMemory(self.device, &alloc_info, null, &self.atlas_mem) != .success) return error.VkAllocateMemoryFailed;
            if (self.vk.BindImageMemory(self.device, self.atlas_img, self.atlas_mem, 0) != .success) return error.VkBindImageMemoryFailed;

            const view_info: VkImageViewCreateInfo = .{
                .image = self.atlas_img,
                .format = VK_FORMAT_R8_UNORM,
                .components = .{
                    .r = VK_COMPONENT_SWIZZLE_R,
                    .g = VK_COMPONENT_SWIZZLE_R,
                    .b = VK_COMPONENT_SWIZZLE_R,
                    .a = VK_COMPONENT_SWIZZLE_R,
                },
                .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
            };
            if (self.vk.CreateImageView(self.device, &view_info, null, &self.atlas_view) != .success) return error.VkCreateImageViewFailed;

            const layouts = [1]VkDescriptorSetLayout{self.set_layout};
            const dsa_info: VkDescriptorSetAllocateInfo = .{
                .descriptorPool = self.desc_pool,
                .pSetLayouts = &layouts,
            };
            var sets: [1]VkDescriptorSet = undefined;
            if (self.vk.AllocateDescriptorSets(self.device, &dsa_info, &sets) != .success) return error.VkAllocateDescriptorSetsFailed;
            self.atlas_set = sets[0];

            const img_desc: VkDescriptorImageInfo = .{
                .sampler = self.nearest_sampler,
                .imageView = self.atlas_view,
                .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            const write = [1]VkWriteDescriptorSet{.{
                .dstSet = self.atlas_set,
                .dstBinding = 0,
                .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &img_desc,
            }};
            self.vk.UpdateDescriptorSets(self.device, 1, &write, 0, null);
            self.atlas_initialized = false;
        }

        if (y1 > y0) {
            const row_h = y1 - y0;
            const byte_len = @as(usize, width) * row_h;
            try self.ensureUploadBuf(byte_len);
            const src = pixels[@as(usize, y0) * width ..][0..byte_len];
            @memcpy(self.upload_map[0..byte_len], src);

            _ = self.vk.ResetCommandBuffer(self.upload_cmd, 0);
            const begin_info: VkCommandBufferBeginInfo = .{};
            if (self.vk.BeginCommandBuffer(self.upload_cmd, &begin_info) != .success) return error.VkBeginCommandBufferFailed;

            const to_dst = [1]VkImageMemoryBarrier{.{
                .srcAccessMask = if (self.atlas_initialized) VK_ACCESS_SHADER_READ_BIT else 0,
                .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                .oldLayout = if (self.atlas_initialized) VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .image = self.atlas_img,
                .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
            }};
            self.vk.CmdPipelineBarrier(
                self.upload_cmd,
                if (self.atlas_initialized) VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT else VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT,
                0,
                0,
                null,
                0,
                null,
                1,
                &to_dst,
            );

            const region = [1]VkBufferImageCopy{.{
                .bufferOffset = 0,
                .bufferRowLength = width,
                .bufferImageHeight = row_h,
                .imageOffset = .{ .x = 0, .y = @intCast(y0), .z = 0 },
                .imageExtent = .{ .width = width, .height = row_h, .depth = 1 },
            }};
            self.vk.CmdCopyBufferToImage(self.upload_cmd, self.upload_buf, self.atlas_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

            const to_read = [1]VkImageMemoryBarrier{.{
                .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
                .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .image = self.atlas_img,
                .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
            }};
            self.vk.CmdPipelineBarrier(
                self.upload_cmd,
                VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                0,
                0,
                null,
                0,
                null,
                1,
                &to_read,
            );

            if (self.vk.EndCommandBuffer(self.upload_cmd) != .success) return error.VkEndCommandBufferFailed;
            const cmds = [1]VkCommandBuffer{self.upload_cmd};
            const submits = [1]VkSubmitInfo{.{ .pCommandBuffers = &cmds }};
            if (self.vk.QueueSubmit(self.queue, 1, &submits, VK_NULL_HANDLE) != .success) return error.VkQueueSubmitFailed;
            _ = self.vk.QueueWaitIdle(self.queue);
            self.atlas_initialized = true;
        }
        return self.atlas_set;
    }

    fn acquireImageHook(raw: ?*anyopaque, id: u64, pixels: []const u32, width: u32, height: u32) anyerror!VkDescriptorSet {
        const self: *Owned2DContext = @ptrCast(@alignCast(raw.?));
        if (self.textures.get(id)) |existing| return existing.set;

        const img_info: VkImageCreateInfo = .{
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .extent = .{ .width = width, .height = height },
            .samples = 1,
            .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        };
        var img: VkImage = VK_NULL_HANDLE;
        if (self.vk.CreateImage(self.device, &img_info, null, &img) != .success) return error.VkCreateImageFailed;
        errdefer self.vk.DestroyImage(self.device, img, null);

        var req: VkMemoryRequirements = undefined;
        self.vk.GetImageMemoryRequirements(self.device, img, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{ .allocationSize = req.size, .memoryTypeIndex = mem_type };
        var mem: VkDeviceMemory = VK_NULL_HANDLE;
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &mem) != .success) return error.VkAllocateMemoryFailed;
        errdefer self.vk.FreeMemory(self.device, mem, null);

        if (self.vk.BindImageMemory(self.device, img, mem, 0) != .success) return error.VkBindImageMemoryFailed;

        const view_info: VkImageViewCreateInfo = .{
            .image = img,
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        };
        var view: VkImageView = VK_NULL_HANDLE;
        if (self.vk.CreateImageView(self.device, &view_info, null, &view) != .success) return error.VkCreateImageViewFailed;
        errdefer self.vk.DestroyImageView(self.device, view, null);

        const layouts = [1]VkDescriptorSetLayout{self.set_layout};
        const dsa_info: VkDescriptorSetAllocateInfo = .{
            .descriptorPool = self.desc_pool,
            .pSetLayouts = &layouts,
        };
        var sets: [1]VkDescriptorSet = undefined;
        if (self.vk.AllocateDescriptorSets(self.device, &dsa_info, &sets) != .success) return error.VkAllocateDescriptorSetsFailed;
        const set = sets[0];

        const img_desc: VkDescriptorImageInfo = .{
            .sampler = self.linear_sampler,
            .imageView = view,
            .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const write = [1]VkWriteDescriptorSet{.{
            .dstSet = set,
            .dstBinding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &img_desc,
        }};
        self.vk.UpdateDescriptorSets(self.device, 1, &write, 0, null);

        const bytes = std.mem.sliceAsBytes(pixels);
        try self.ensureUploadBuf(bytes.len);
        @memcpy(self.upload_map[0..bytes.len], bytes);

        _ = self.vk.ResetCommandBuffer(self.upload_cmd, 0);
        const begin_info: VkCommandBufferBeginInfo = .{};
        if (self.vk.BeginCommandBuffer(self.upload_cmd, &begin_info) != .success) return error.VkBeginCommandBufferFailed;

        const to_dst = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = 0,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .image = img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        }};
        self.vk.CmdPipelineBarrier(self.upload_cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_dst);

        const region = [1]VkBufferImageCopy{.{
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        }};
        self.vk.CmdCopyBufferToImage(self.upload_cmd, self.upload_buf, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        const to_read = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .image = img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        }};
        self.vk.CmdPipelineBarrier(self.upload_cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &to_read);

        if (self.vk.EndCommandBuffer(self.upload_cmd) != .success) return error.VkEndCommandBufferFailed;
        const cmds = [1]VkCommandBuffer{self.upload_cmd};
        const submits = [1]VkSubmitInfo{.{ .pCommandBuffers = &cmds }};
        if (self.vk.QueueSubmit(self.queue, 1, &submits, VK_NULL_HANDLE) != .success) return error.VkQueueSubmitFailed;
        _ = self.vk.QueueWaitIdle(self.queue);

        try self.textures.put(self.gpa, id, .{ .img = img, .mem = mem, .view = view, .set = set });
        return set;
    }

    fn releaseImageHook(raw: ?*anyopaque, id: u64) void {
        const self: *Owned2DContext = @ptrCast(@alignCast(raw.?));
        if (self.textures.fetchRemove(id)) |kv| {
            _ = self.vk.DeviceWaitIdle(self.device);
            const t = kv.value;
            if (t.view != VK_NULL_HANDLE) self.vk.DestroyImageView(self.device, t.view, null);
            if (t.img != VK_NULL_HANDLE) self.vk.DestroyImage(self.device, t.img, null);
            if (t.mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, t.mem, null);
            if (t.set != VK_NULL_HANDLE) {
                const sets = [1]VkDescriptorSet{t.set};
                _ = self.vk.FreeDescriptorSets(self.device, self.desc_pool, 1, &sets);
            }
        }
    }

    fn destroyTarget(self: *Owned2DContext) void {
        if (self.staging_map.len > 0) {
            self.vk.UnmapMemory(self.device, self.staging_mem);
            self.staging_map = &.{};
        }
        if (self.staging_buf != VK_NULL_HANDLE) {
            self.vk.DestroyBuffer(self.device, self.staging_buf, null);
            self.staging_buf = VK_NULL_HANDLE;
        }
        if (self.staging_mem != VK_NULL_HANDLE) {
            self.vk.FreeMemory(self.device, self.staging_mem, null);
            self.staging_mem = VK_NULL_HANDLE;
        }
        if (self.framebuffer != VK_NULL_HANDLE) {
            self.vk.DestroyFramebuffer(self.device, self.framebuffer, null);
            self.framebuffer = VK_NULL_HANDLE;
        }
        if (self.color_view != VK_NULL_HANDLE) {
            self.vk.DestroyImageView(self.device, self.color_view, null);
            self.color_view = VK_NULL_HANDLE;
        }
        if (self.color_img != VK_NULL_HANDLE) {
            self.vk.DestroyImage(self.device, self.color_img, null);
            self.color_img = VK_NULL_HANDLE;
        }
        if (self.color_mem != VK_NULL_HANDLE) {
            self.vk.FreeMemory(self.device, self.color_mem, null);
            self.color_mem = VK_NULL_HANDLE;
        }
        self.fb_w = 0;
        self.fb_h = 0;
    }

    fn ensureTarget(self: *Owned2DContext, w: u32, h: u32) !void {
        if (self.fb_w == w and self.fb_h == h and self.framebuffer != VK_NULL_HANDLE) return;
        self.destroyTarget();
        errdefer self.destroyTarget();

        const img_info: VkImageCreateInfo = .{
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .extent = .{ .width = w, .height = h },
            .samples = 1,
            .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        };
        if (self.vk.CreateImage(self.device, &img_info, null, &self.color_img) != .success) return error.VkCreateImageFailed;

        var req: VkMemoryRequirements = undefined;
        self.vk.GetImageMemoryRequirements(self.device, self.color_img, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{ .allocationSize = req.size, .memoryTypeIndex = mem_type };
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &self.color_mem) != .success) return error.VkAllocateMemoryFailed;
        if (self.vk.BindImageMemory(self.device, self.color_img, self.color_mem, 0) != .success) return error.VkBindImageMemoryFailed;

        const view_info: VkImageViewCreateInfo = .{
            .image = self.color_img,
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        };
        if (self.vk.CreateImageView(self.device, &view_info, null, &self.color_view) != .success) return error.VkCreateImageViewFailed;

        const views = [1]VkImageView{self.color_view};
        const fb_info: VkFramebufferCreateInfo = .{
            .renderPass = self.render_pass,
            .attachmentCount = 1,
            .pAttachments = &views,
            .width = w,
            .height = h,
        };
        if (self.vk.CreateFramebuffer(self.device, &fb_info, null, &self.framebuffer) != .success) return error.VkCreateFramebufferFailed;

        const pixel_count = @as(usize, w) * h;
        const byte_size: VkDeviceSize = pixel_count * 4;
        const buf_info: VkBufferCreateInfo = .{
            .size = byte_size,
            .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        };
        if (self.vk.CreateBuffer(self.device, &buf_info, null, &self.staging_buf) != .success) return error.VkCreateBufferFailed;
        var buf_req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(self.device, self.staging_buf, &buf_req);
        const buf_mt = try readbackMemoryType(self, buf_req.memoryTypeBits);
        const buf_alloc: VkMemoryAllocateInfo = .{
            .allocationSize = @max(buf_req.size, byte_size),
            .memoryTypeIndex = buf_mt,
        };
        if (self.vk.AllocateMemory(self.device, &buf_alloc, null, &self.staging_mem) != .success) return error.VkAllocateMemoryFailed;
        if (self.vk.BindBufferMemory(self.device, self.staging_buf, self.staging_mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        var ptr: ?*anyopaque = null;
        if (self.vk.MapMemory(self.device, self.staging_mem, 0, byte_size, 0, &ptr) != .success or ptr == null) return error.VkMapMemoryFailed;
        self.staging_map = @as([*]u32, @ptrCast(@alignCast(ptr.?)))[0..pixel_count];

        self.fb_w = w;
        self.fb_h = h;
    }

    /// Gets ready to draw straight into window buffers: the procs, a render
    /// pass that keeps the buffer's pixels (in `GENERAL` layout, as it is
    /// shared with the compositor), and a fence. Without them, `dmabuf`
    /// stays null and frames are drawn the CPU way.
    fn initDirect(self: *Owned2DContext, get_proc: GetDeviceProcAddr) void {
        const d = DmabufProcs.load(self.device, get_proc) orelse return;
        const attachments = [1]VkAttachmentDescription{.{
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .samples = 1,
            .loadOp = VK_ATTACHMENT_LOAD_OP_LOAD,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .initialLayout = VK_IMAGE_LAYOUT_GENERAL,
            .finalLayout = VK_IMAGE_LAYOUT_GENERAL,
        }};
        const color_ref = [1]VkAttachmentReference{.{ .attachment = 0, .layout = VK_IMAGE_LAYOUT_GENERAL }};
        const subpass = [1]VkSubpassDescription{.{ .pColorAttachments = &color_ref }};
        const rp_info: VkRenderPassCreateInfo = .{ .attachmentCount = 1, .pAttachments = &attachments, .pSubpasses = &subpass };
        if (self.vk.CreateRenderPass(self.device, &rp_info, null, &self.direct_pass) != .success) return;
        if (d.CreateFence(self.device, &.{}, null, &self.fence) != .success) {
            self.vk.DestroyRenderPass(self.device, self.direct_pass, null);
            self.direct_pass = VK_NULL_HANDLE;
            return;
        }
        self.dmabuf = d;
    }

    fn destroyImport(self: *Owned2DContext, im: *DmabufImport) void {
        self.vk.DestroyFramebuffer(self.device, im.framebuffer, null);
        self.vk.DestroyImageView(self.device, im.view, null);
        self.vk.DestroyImage(self.device, im.img, null);
        self.vk.FreeMemory(self.device, im.mem, null);
    }

    /// The window buffer `t` as an image to draw into: imported the first
    /// time (freeing the longest unused import if there is no room).
    fn importTarget(self: *Owned2DContext, t: *const DmabufTarget) !*DmabufImport {
        const d = self.dmabuf orelse return error.Unsupported;
        self.import_clock += 1;
        var free: ?*?DmabufImport = null;
        var oldest: ?*?DmabufImport = null;
        for (&self.imports) |*slot| {
            if (slot.*) |*im| {
                if (im.id == t.id and im.width == t.width and im.height == t.height) {
                    im.used = self.import_clock;
                    return im;
                }
                if (oldest == null or im.used < oldest.?.*.?.used) oldest = slot;
            } else free = slot;
        }
        const slot = free orelse blk: {
            const o = oldest.?;
            self.destroyImport(&o.*.?);
            o.* = null;
            break :blk o;
        };

        const plane = [1]VkSubresourceLayout{.{ .offset = t.offset, .size = 0, .rowPitch = t.stride, .arrayPitch = 0, .depthPitch = 0 }};
        const mod_info: VkImageDrmFormatModifierExplicitCreateInfoEXT = .{ .drmFormatModifier = t.modifier, .pPlaneLayouts = &plane };
        const ext_info: VkExternalMemoryImageCreateInfo = .{ .pNext = &mod_info, .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
        const img_info: VkImageCreateInfo = .{
            .pNext = &ext_info,
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .extent = .{ .width = t.width, .height = t.height },
            .samples = 1,
            .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        };
        var img: VkImage = VK_NULL_HANDLE;
        if (self.vk.CreateImage(self.device, &img_info, null, &img) != .success) return error.Unsupported;
        errdefer self.vk.DestroyImage(self.device, img, null);

        // Vulkan takes the fd it imports: give it a copy.
        const fd_rc = std.posix.system.dup(t.fd);
        if (std.posix.errno(fd_rc) != .SUCCESS) return error.Unsupported;
        const fd: c_int = @intCast(fd_rc);
        var imported = false;
        defer if (!imported) {
            _ = std.posix.system.close(fd);
        };
        var fd_props: VkMemoryFdPropertiesKHR = .{};
        if (d.GetMemoryFdPropertiesKHR(self.device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, fd, &fd_props) != .success) return error.Unsupported;
        var req: VkMemoryRequirements = undefined;
        self.vk.GetImageMemoryRequirements(self.device, img, &req);
        const bits = req.memoryTypeBits & fd_props.memoryTypeBits;
        if (bits == 0) return error.Unsupported;
        const dedicated: VkMemoryDedicatedAllocateInfo = .{ .image = img };
        const import_info: VkImportMemoryFdInfoKHR = .{ .pNext = &dedicated, .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, .fd = fd };
        const alloc_info: VkMemoryAllocateInfo = .{ .pNext = &import_info, .allocationSize = req.size, .memoryTypeIndex = @ctz(bits) };
        var mem: VkDeviceMemory = VK_NULL_HANDLE;
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &mem) != .success) return error.Unsupported;
        imported = true;
        errdefer self.vk.FreeMemory(self.device, mem, null);
        if (self.vk.BindImageMemory(self.device, img, mem, 0) != .success) return error.Unsupported;

        const view_info: VkImageViewCreateInfo = .{
            .image = img,
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR },
        };
        var view: VkImageView = VK_NULL_HANDLE;
        if (self.vk.CreateImageView(self.device, &view_info, null, &view) != .success) return error.Unsupported;
        errdefer self.vk.DestroyImageView(self.device, view, null);
        const views = [1]VkImageView{view};
        const fb_info: VkFramebufferCreateInfo = .{ .renderPass = self.direct_pass, .attachmentCount = 1, .pAttachments = &views, .width = t.width, .height = t.height };
        var fb: VkFramebuffer = VK_NULL_HANDLE;
        if (self.vk.CreateFramebuffer(self.device, &fb_info, null, &fb) != .success) return error.Unsupported;

        slot.* = .{ .id = t.id, .width = t.width, .height = t.height, .img = img, .mem = mem, .view = view, .framebuffer = fb, .used = self.import_clock };
        return &slot.*.?;
    }

    /// Starts drawing into `im`: takes it from the compositor (the
    /// external queue family) and begins the render pass over the frame.
    fn beginDirect(self: *Owned2DContext, im: *DmabufImport, t: *const DmabufTarget) !void {
        try self.beginDirectCmd(im);
        self.beginDirectPass(im, t);
    }

    fn beginDirectCmd(self: *Owned2DContext, im: *DmabufImport) !void {
        _ = self.vk.ResetCommandBuffer(self.cmd, 0);
        if (self.vk.BeginCommandBuffer(self.cmd, &.{}) != .success) return error.VkBeginCommandBufferFailed;
        const acquire = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = 0,
            .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = if (im.initialized) VK_IMAGE_LAYOUT_GENERAL else VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_GENERAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL,
            .dstQueueFamilyIndex = self.queue_family,
            .image = im.img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &acquire);
        im.initialized = true;
    }

    fn beginDirectPass(self: *Owned2DContext, im: *DmabufImport, t: *const DmabufTarget) void {
        const no_clear = [1]VkClearValue{.{ .color = .{ 0, 0, 0, 0 } }};
        const rp_begin: VkRenderPassBeginInfo = .{
            .renderPass = self.direct_pass,
            .framebuffer = im.framebuffer,
            .renderArea = .{
                .offset = .{ .x = @intCast(t.origin[0]), .y = @intCast(t.origin[1]) },
                .extent = .{ .width = t.content[0], .height = t.content[1] },
            },
            .clearValueCount = 0,
            .pClearValues = &no_clear,
        };
        self.vk.CmdBeginRenderPass(self.cmd, &rp_begin, 0);
    }

    /// Finishes drawing into `im`: gives it back to the compositor and
    /// waits for the GPU (so the frame is complete when it is shown, and
    /// the CPU may draw in it).
    fn endDirect(self: *Owned2DContext, im: *DmabufImport) !void {
        self.vk.CmdEndRenderPass(self.cmd);
        try self.submitDirect(im);
    }

    /// Gives `im` back to the compositor, submits the frame and waits for it.
    fn submitDirect(self: *Owned2DContext, im: *DmabufImport) !void {
        const d = self.dmabuf.?;
        const release = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = 0,
            .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
            .newLayout = VK_IMAGE_LAYOUT_GENERAL,
            .srcQueueFamilyIndex = self.queue_family,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL,
            .image = im.img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, &release);
        if (self.vk.EndCommandBuffer(self.cmd) != .success) return error.VkEndCommandBufferFailed;
        const cmds = [1]VkCommandBuffer{self.cmd};
        // After the GPU work the frame's draws wait for (`DirectFrame.wait`).
        var submits = [1]VkSubmitInfo{.{ .pCommandBuffers = &cmds }};
        self.frame_waits.apply(&submits[0]);
        if (self.vk.QueueSubmit(self.queue, 1, &submits, self.fence) != .success) return error.VkQueueSubmitFailed;
        const fences = [1]VkFence{self.fence};
        const waited = d.WaitForFences(self.device, 1, &fences, 1, std.time.ns_per_s);
        _ = d.ResetFences(self.device, 1, &fences);
        self.clearFrameWaits();
        for (self.retired_sources.items) |src| {
            self.vk.DestroyImage(self.device, src.img, null);
            self.vk.FreeMemory(self.device, src.mem, null);
        }
        self.retired_sources.clearRetainingCapacity();
        if (waited != .success) return error.VkWaitForFencesFailed;
    }

    /// Draws a frame straight into the window buffer `t`, with no copy
    /// through the CPU (see `Renderer.renderDmabuf`).
    fn renderDirect(self: *Owned2DContext, r: *VulkanRenderer, segments: []const Segment, t: *const DmabufTarget, clear: u32, clear_rects: []const Viewport, damage: []const Viewport) !void {
        const d = self.dmabuf orelse return error.Unsupported;
        if (t.content[0] == 0 or t.content[1] == 0) return;
        // A frame needs its pipelines (or it is drawn the CPU way).
        if (t.frame != null and self.frame_map.len == 0) return error.Unsupported;
        const im = try self.importTarget(t);
        const origin: [2]i32 = .{ @intCast(t.origin[0]), @intCast(t.origin[1]) };
        // Waits of a frame that failed before it was submitted.
        self.clearFrameWaits();
        try self.beginDirect(im, t);
        if (clear_rects.len > 0) {
            const color: [4]f32 = .{
                @as(f32, @floatFromInt((clear >> 16) & 0xff)) / 255,
                @as(f32, @floatFromInt((clear >> 8) & 0xff)) / 255,
                @as(f32, @floatFromInt(clear & 0xff)) / 255,
                @as(f32, @floatFromInt(clear >> 24)) / 255,
            };
            const att = [1]VkClearAttachment{.{ .aspectMask = VK_IMAGE_ASPECT_COLOR, .colorAttachment = 0, .clearValue = .{ .color = color } }};
            var rects: [renderer_mod.max_uncovered]VkClearRect = undefined;
            var n: u32 = 0;
            const full: Viewport = .{ .x = 0, .y = 0, .width = t.content[0], .height = t.content[1] };
            for (clear_rects) |cr| {
                const c = full.intersect(cr) orelse continue;
                if (n == rects.len) break;
                rects[n] = .{ .rect = .{ .offset = .{ .x = c.x + origin[0], .y = c.y + origin[1] }, .extent = .{ .width = c.width, .height = c.height } } };
                n += 1;
            }
            if (n > 0) d.CmdClearAttachments(self.cmd, 1, &att, n, &rects);
        }
        var buf: [2][renderer_mod.max_uncovered]Viewport = undefined;
        for (segments, 0..) |seg, i| switch (seg) {
            .canvas => |c| {
                // Not under a GPU draw that covers it (as `Renderer.render`).
                const dmg = renderer_mod.uncovered(&buf, damage, segments[i + 1 ..]);
                if (dmg.len == 0) continue;
                const target: Target = .{ .cmd = self.cmd, .width = t.content[0], .height = t.content[1], .origin = origin };
                try r.recordTarget(c, &target, dmg);
            },
            .gpu => |g| {
                const area = g.area.scissor orelse g.area.viewport;
                if (!renderer_mod.covers(damage, area)) continue;
                if (g.direct) |direct| {
                    // Recorded into this frame (outside the render pass), on
                    // this device: no copy through the CPU.
                    self.vk.CmdEndRenderPass(self.cmd);
                    const frame: DirectFrame = .{ .device = self.device, .cmd = self.cmd, .image = im.img, .origin = origin, .width = t.content[0], .height = t.content[1], .copy_ctx = self, .copy_dmabuf = copyDmabuf, .wait = frameWait };
                    const drawn = try direct(g.ctx, .vulkan, &frame, g.area);
                    self.beginDirectPass(im, t);
                    if (drawn) continue;
                }
                // Drawn on the CPU (on its own device): what is under it is
                // finished first, and what is over it drawn after.
                try self.endDirect(im);
                var img = try t.cpu.begin(t.cpu.ctx);
                const drawn = g.f(g.ctx, @ptrCast(&img), g.area);
                t.cpu.end(t.cpu.ctx);
                try drawn;
                try self.beginDirect(im, t);
            },
        };
        if (t.frame) |frame| {
            self.vk.CmdEndRenderPass(self.cmd);
            self.drawFrame(im, t, frame, damage);
            try self.submitDirect(im);
        } else try self.endDirect(im);
    }

    /// Imports a one-plane dmabuf as an image of `format`, for `usage`.
    fn importImage(self: *Owned2DContext, desc: DmabufImage, format: u32, usage: VkFlags) !struct { img: VkImage, mem: VkDeviceMemory } {
        const d = self.dmabuf orelse return error.Unsupported;
        const plane = [1]VkSubresourceLayout{.{ .offset = desc.offset, .size = 0, .rowPitch = desc.stride, .arrayPitch = 0, .depthPitch = 0 }};
        const mod_info: VkImageDrmFormatModifierExplicitCreateInfoEXT = .{ .drmFormatModifier = desc.modifier, .pPlaneLayouts = &plane };
        const ext_info: VkExternalMemoryImageCreateInfo = .{ .pNext = &mod_info, .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
        const img_info: VkImageCreateInfo = .{
            .pNext = &ext_info,
            .format = format,
            .extent = .{ .width = desc.width, .height = desc.height },
            .samples = 1,
            .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            .usage = usage,
        };
        var img: VkImage = VK_NULL_HANDLE;
        if (self.vk.CreateImage(self.device, &img_info, null, &img) != .success) return error.Unsupported;
        errdefer self.vk.DestroyImage(self.device, img, null);
        // Vulkan takes the fd it imports: give it a copy.
        const fd_rc = std.posix.system.dup(desc.fd);
        if (std.posix.errno(fd_rc) != .SUCCESS) return error.Unsupported;
        const fd: c_int = @intCast(fd_rc);
        var imported = false;
        defer if (!imported) {
            _ = std.posix.system.close(fd);
        };
        var fd_props: VkMemoryFdPropertiesKHR = .{};
        if (d.GetMemoryFdPropertiesKHR(self.device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, fd, &fd_props) != .success) return error.Unsupported;
        var req: VkMemoryRequirements = undefined;
        self.vk.GetImageMemoryRequirements(self.device, img, &req);
        const bits = req.memoryTypeBits & fd_props.memoryTypeBits;
        if (bits == 0) return error.Unsupported;
        const dedicated: VkMemoryDedicatedAllocateInfo = .{ .image = img };
        const import_info: VkImportMemoryFdInfoKHR = .{ .pNext = &dedicated, .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, .fd = fd };
        const alloc_info: VkMemoryAllocateInfo = .{ .pNext = &import_info, .allocationSize = req.size, .memoryTypeIndex = @ctz(bits) };
        var mem: VkDeviceMemory = VK_NULL_HANDLE;
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &mem) != .success) return error.Unsupported;
        imported = true;
        errdefer self.vk.FreeMemory(self.device, mem, null);
        if (self.vk.BindImageMemory(self.device, img, mem, 0) != .success) return error.Unsupported;
        return .{ .img = img, .mem = mem };
    }

    /// A picture drawn on another API as an image to copy from: imported
    /// the first time (freeing the longest unused if there is no room).
    fn importSource(self: *Owned2DContext, src: *const DmabufImage) !*SourceImport {
        self.import_clock += 1;
        var free: ?*?SourceImport = null;
        var oldest: ?*?SourceImport = null;
        for (&self.sources) |*slot| {
            if (slot.*) |*s| {
                if (s.id == src.id and s.width == src.width and s.height == src.height) {
                    s.used = self.import_clock;
                    return s;
                }
                if (oldest == null or s.used < oldest.?.*.?.used) oldest = slot;
            } else free = slot;
        }
        const slot = free orelse blk: {
            const o = oldest.?;
            try self.retired_sources.append(self.gpa, .{ .img = o.*.?.img, .mem = o.*.?.mem });
            o.* = null;
            break :blk o;
        };
        const format = fourccFormat(src.fourcc) orelse return error.Unsupported;
        const im = try self.importImage(src.*, format, VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        slot.* = .{ .id = src.id, .width = src.width, .height = src.height, .img = im.img, .mem = im.mem, .used = self.import_clock };
        return &slot.*.?;
    }

    /// `DirectFrame.copy_dmabuf`: blits the picture in (converting its
    /// format, and turning it the right way up).
    fn copyDmabuf(ctx: *anyopaque, frame: *const DirectFrame, src: *const DmabufImage, area: GpuArea) anyerror!bool {
        const self: *Owned2DContext = @ptrCast(@alignCast(ctx));
        if (src.ready_fd >= 0) self.waitSyncFile(src.ready_fd);
        const s = self.importSource(src) catch return false;
        const vp = area.viewport;
        const clipped = if (area.scissor) |c| vp.intersect(c) orelse return true else vp;
        const sc = if (frame.width > 0 and frame.height > 0)
            (Viewport{ .width = frame.width, .height = frame.height }).intersect(clipped) orelse return true
        else
            clipped;
        const color = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        const range: VkImageSubresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR };
        const before = [2]VkImageMemoryBarrier{
            // The picture, from the API that drew it.
            .{ .srcAccessMask = 0, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .oldLayout = VK_IMAGE_LAYOUT_GENERAL, .newLayout = VK_IMAGE_LAYOUT_GENERAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL, .dstQueueFamilyIndex = self.queue_family, .image = s.img, .subresourceRange = range },
            .{ .srcAccessMask = color, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_GENERAL, .newLayout = VK_IMAGE_LAYOUT_GENERAL, .image = frame.image, .subresourceRange = range },
        };
        self.vk.CmdPipelineBarrier(frame.cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 2, &before);
        const lx = sc.x - vp.x;
        const ly = sc.y - vp.y;
        const w: i32 = @intCast(sc.width);
        const h: i32 = @intCast(sc.height);
        const sh: i32 = @intCast(src.height);
        const src_y0 = if (src.bottom_up) sh - ly else ly;
        const src_y1 = if (src.bottom_up) sh - (ly + h) else ly + h;
        const dx = sc.x + frame.origin[0];
        const dy = sc.y + frame.origin[1];
        const region = [1]VkImageBlit{.{
            .srcOffsets = .{ .{ .x = lx, .y = src_y0, .z = 0 }, .{ .x = lx + w, .y = src_y1, .z = 1 } },
            .dstOffsets = .{ .{ .x = dx, .y = dy, .z = 0 }, .{ .x = dx + w, .y = dy + h, .z = 1 } },
        }};
        self.vk.CmdBlitImage(frame.cmd, s.img, VK_IMAGE_LAYOUT_GENERAL, frame.image, VK_IMAGE_LAYOUT_GENERAL, 1, &region, 0);
        const after = [2]VkImageMemoryBarrier{
            .{ .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .dstAccessMask = 0, .oldLayout = VK_IMAGE_LAYOUT_GENERAL, .newLayout = VK_IMAGE_LAYOUT_GENERAL, .srcQueueFamilyIndex = self.queue_family, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL, .image = s.img, .subresourceRange = range },
            .{ .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = color, .oldLayout = VK_IMAGE_LAYOUT_GENERAL, .newLayout = VK_IMAGE_LAYOUT_GENERAL, .image = frame.image, .subresourceRange = range },
        };
        self.vk.CmdPipelineBarrier(frame.cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 2, &after);
        return true;
    }

    /// `DirectFrame.wait`: the frame's submission waits for `w`; false if
    /// it cannot (the device has no timeline semaphores, or the frame
    /// waits on as many as it can).
    fn frameWait(ctx: *anyopaque, w: Wait) bool {
        const self: *Owned2DContext = @ptrCast(@alignCast(ctx));
        if (self.timelines == null) return false;
        return self.frame_waits.add(w.semaphore, w.value, false);
    }

    /// Takes `fd`, a sync file signalled when a picture another API drew
    /// is done, and has the frame's submission wait for it on the GPU; or,
    /// if it cannot, waits for it here.
    fn waitSyncFile(self: *Owned2DContext, fd: i32) void {
        if (self.sync_fd) |x| import: {
            var sem: VkSemaphore = VK_NULL_HANDLE;
            if (x.CreateSemaphore(self.device, &.{}, null, &sem) != .success) break :import;
            // Imported, the semaphore has the fd.
            if (x.ImportSemaphoreFdKHR(self.device, &.{ .semaphore = sem, .fd = fd }) != .success or !self.frame_waits.add(sem, 0, true)) {
                x.DestroySemaphore(self.device, sem, null);
                break :import;
            }
            return;
        }
        renderer_mod.waitFd(fd);
    }

    /// Forgets what the frame waits on, destroying the semaphores of sync files.
    fn clearFrameWaits(self: *Owned2DContext) void {
        self.frame_waits.clear(self.device, if (self.sync_fd) |x| x.DestroySemaphore else null);
    }

    /// Makes what the window's frame is drawn with (`drawFrame`): its
    /// pipelines and a buffer for its vertices. Without them, frames that
    /// need one are drawn the CPU way.
    fn initFrame(self: *Owned2DContext) void {
        const mod_info: VkShaderModuleCreateInfo = .{ .codeSize = shaders.window_spv.len, .pCode = @ptrCast(&shaders.window_spv) };
        if (self.vk.CreateShaderModule(self.device, &mod_info, null, &self.frame_module) != .success) return;
        self.frame_mask = self.create2DPipeline(self.frame_module, shaders.window_layout, .mask) catch return;
        self.frame_under = self.create2DPipeline(self.frame_module, shaders.window_layout, .under) catch return;
        const size = frame_vertices * shaders.window_floats * 4;
        const buf_info: VkBufferCreateInfo = .{ .size = size, .usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT };
        if (self.vk.CreateBuffer(self.device, &buf_info, null, &self.frame_vbo) != .success) return;
        var req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(self.device, self.frame_vbo, &req);
        const mem_type = self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) catch return;
        const alloc_info: VkMemoryAllocateInfo = .{ .allocationSize = @max(req.size, size), .memoryTypeIndex = mem_type };
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &self.frame_mem) != .success) return;
        if (self.vk.BindBufferMemory(self.device, self.frame_vbo, self.frame_mem, 0) != .success) return;
        var ptr: ?*anyopaque = null;
        if (self.vk.MapMemory(self.device, self.frame_mem, 0, size, 0, &ptr) != .success or ptr == null) return;
        self.frame_map = @as([*]f32, @ptrCast(@alignCast(ptr.?)))[0 .. frame_vertices * shaders.window_floats];
    }

    fn destroyFrame(self: *Owned2DContext) void {
        if (self.frame_map.len > 0) self.vk.UnmapMemory(self.device, self.frame_mem);
        if (self.frame_vbo != VK_NULL_HANDLE) self.vk.DestroyBuffer(self.device, self.frame_vbo, null);
        if (self.frame_mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, self.frame_mem, null);
        for ([_]VkPipeline{ self.frame_mask, self.frame_under }) |p| if (p != VK_NULL_HANDLE) self.vk.DestroyPipeline(self.device, p, null);
        if (self.frame_module != VK_NULL_HANDLE) self.vk.DestroyShaderModule(self.device, self.frame_module, null);
    }

    /// Draws the window's frame (`t.frame`) after its content: the shadow in
    /// the margin the first time the buffer is drawn into, and the rounded
    /// corners (with the shadow under them) where `damage` repainted them.
    /// The content's render pass has ended.
    fn drawFrame(self: *Owned2DContext, im: *DmabufImport, t: *const DmabufTarget, frame: renderer_mod.WindowFrame, damage: []const Viewport) void {
        const d = self.dmabuf.?;
        const bw: f32 = @floatFromInt(t.width);
        const bh: f32 = @floatFromInt(t.height);
        const m: f32 = @floatFromInt(t.origin[0]);
        const cw: f32 = @floatFromInt(t.content[0]);
        const ch: f32 = @floatFromInt(t.content[1]);
        const r = frame.radius;
        const box = [4]f32{ m + cw / 2, m + ch / 2, @max(cw / 2 - r, 0), @max(ch / 2 - r, 0) };
        // The corners' squares, in the content's pixels.
        const corner: u32 = @min(@as(u32, @intFromFloat(@ceil(r))) + 1, @min(t.content[0] / 2, t.content[1] / 2));
        const corners = [4]Viewport{
            .{ .x = 0, .y = 0, .width = corner, .height = corner },
            .{ .x = @intCast(t.content[0] - corner), .y = 0, .width = corner, .height = corner },
            .{ .x = 0, .y = @intCast(t.content[1] - corner), .width = corner, .height = corner },
            .{ .x = @intCast(t.content[0] - corner), .y = @intCast(t.content[1] - corner), .width = corner, .height = corner },
        };
        // The margin around the content, in the buffer's pixels.
        const om: u32 = t.origin[0];
        const margin = [4]Viewport{
            .{ .x = 0, .y = 0, .width = t.width, .height = om },
            .{ .x = 0, .y = @intCast(om + t.content[1]), .width = t.width, .height = t.height - om - t.content[1] },
            .{ .x = 0, .y = @intCast(om), .width = om, .height = t.content[1] },
            .{ .x = @intCast(om + t.content[0]), .y = @intCast(om), .width = t.width - om - t.content[0], .height = t.content[1] },
        };
        // Quads: the margin's (shadow), then each corner's twice (rounding,
        // then shadow).
        var n: usize = 0;
        const quad = struct {
            fn f(out: []f32, at: *usize, v: Viewport, w: f32, h: f32, b: [4]f32, params: [4]f32) void {
                const x0: f32 = @floatFromInt(v.x);
                const y0: f32 = @floatFromInt(v.y);
                const x1 = x0 + @as(f32, @floatFromInt(v.width));
                const y1 = y0 + @as(f32, @floatFromInt(v.height));
                for ([6][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } }) |p| {
                    const o = out[at.* * shaders.window_floats ..][0..shaders.window_floats];
                    o.* = .{ p[0] / w * 2 - 1, p[1] / h * 2 - 1, p[0], p[1], b[0], b[1], b[2], b[3], params[0], params[1], params[2], params[3] };
                    at.* += 1;
                }
            }
        }.f;
        const shadow_params = [4]f32{ r, frame.scale, 1, 0 };
        const mask_params = [4]f32{ r, frame.scale, 0, 0 };
        for (margin) |v| quad(self.frame_map, &n, v, bw, bh, box, shadow_params);
        for (corners) |v| {
            const bv: Viewport = .{ .x = v.x + @as(i32, @intCast(om)), .y = v.y + @as(i32, @intCast(om)), .width = v.width, .height = v.height };
            quad(self.frame_map, &n, bv, bw, bh, box, mask_params);
            quad(self.frame_map, &n, bv, bw, bh, box, shadow_params);
        }

        const no_clear = [1]VkClearValue{.{ .color = .{ 0, 0, 0, 0 } }};
        const rp_begin: VkRenderPassBeginInfo = .{
            .renderPass = self.direct_pass,
            .framebuffer = im.framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = t.width, .height = t.height } },
            .clearValueCount = 0,
            .pClearValues = &no_clear,
        };
        self.vk.CmdBeginRenderPass(self.cmd, &rp_begin, 0);
        defer self.vk.CmdEndRenderPass(self.cmd);
        const vp = [1]VkViewport{.{ .x = 0, .y = 0, .width = bw, .height = bh }};
        self.vk.CmdSetViewport(self.cmd, 0, 1, &vp);
        const bufs = [1]VkBuffer{self.frame_vbo};
        const offs = [1]VkDeviceSize{0};
        self.vk.CmdBindVertexBuffers(self.cmd, 0, 1, &bufs, &offs);
        const scissor = struct {
            fn f(o: *Owned2DContext, v: Viewport) void {
                const rect = [1]VkRect2D{.{ .offset = .{ .x = v.x, .y = v.y }, .extent = .{ .width = v.width, .height = v.height } }};
                o.vk.CmdSetScissor(o.cmd, 0, 1, &rect);
            }
        }.f;
        if (!im.frame_drawn) {
            // The margin, cleared, then its shadow.
            var rects: [4]VkClearRect = undefined;
            var count: u32 = 0;
            for (margin) |v| if (v.width > 0 and v.height > 0) {
                rects[count] = .{ .rect = .{ .offset = .{ .x = v.x, .y = v.y }, .extent = .{ .width = v.width, .height = v.height } } };
                count += 1;
            };
            const att = [1]VkClearAttachment{.{ .aspectMask = VK_IMAGE_ASPECT_COLOR, .colorAttachment = 0, .clearValue = .{ .color = .{ 0, 0, 0, 0 } } }};
            if (count > 0) d.CmdClearAttachments(self.cmd, 1, &att, count, &rects);
            scissor(self, .{ .x = 0, .y = 0, .width = t.width, .height = t.height });
            self.vk.CmdBindPipeline(self.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, self.frame_under);
            self.vk.CmdDraw(self.cmd, 4 * 6, 1, 0, 0);
            im.frame_drawn = true;
        }
        // Each corner where it was repainted: rounded, then the shadow under.
        for (corners, 0..) |c, i| for (damage) |dmg| {
            const part = c.intersect(dmg) orelse continue;
            scissor(self, .{ .x = part.x + @as(i32, @intCast(om)), .y = part.y + @as(i32, @intCast(om)), .width = part.width, .height = part.height });
            const first: u32 = @intCast(4 * 6 + i * 12);
            self.vk.CmdBindPipeline(self.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, self.frame_mask);
            self.vk.CmdDraw(self.cmd, 6, 1, first, 0);
            self.vk.CmdBindPipeline(self.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, self.frame_under);
            self.vk.CmdDraw(self.cmd, 6, 1, first + 6, 0);
        };
    }

    fn renderCanvasToImage(self: *Owned2DContext, r: *VulkanRenderer, c: *const Canvas, target: *software.Image, damage: ?[]const Viewport) !void {
        const w = target.width;
        const h = target.height;
        try self.ensureTarget(w, h);

        const full_vp: Viewport = .{ .x = 0, .y = 0, .width = w, .height = h };
        const fallback_regions = [1]Viewport{full_vp};
        const regions = if (damage) |d| (if (d.len <= 16) d else &fallback_regions) else &fallback_regions;
        const stride = target.rowStride();

        var copy_regions: [16]VkBufferImageCopy = undefined;
        var copy_count: u32 = 0;
        for (regions) |reg| {
            const sc = full_vp.intersect(reg) orelse continue;
            const sx: usize = @intCast(sc.x);
            const sy: usize = @intCast(sc.y);
            for (0..sc.height) |row| {
                const src = target.pixels[(sy + row) * stride + sx ..][0..sc.width];
                @memcpy(self.staging_map[(sy + row) * w + sx ..][0..sc.width], src);
            }
            copy_regions[copy_count] = .{
                .bufferOffset = (@as(VkDeviceSize, @intCast(sy)) * w + @as(VkDeviceSize, @intCast(sx))) * 4,
                .bufferRowLength = w,
                .bufferImageHeight = h,
                .imageOffset = .{ .x = sc.x, .y = sc.y, .z = 0 },
                .imageExtent = .{ .width = sc.width, .height = sc.height, .depth = 1 },
            };
            copy_count += 1;
        }
        if (copy_count == 0) return;

        _ = self.vk.ResetCommandBuffer(self.cmd, 0);
        const begin_info: VkCommandBufferBeginInfo = .{};
        if (self.vk.BeginCommandBuffer(self.cmd, &begin_info) != .success) return error.VkBeginCommandBufferFailed;

        const to_dst = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = 0,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .image = self.color_img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_dst);

        self.vk.CmdCopyBufferToImage(self.cmd, self.staging_buf, self.color_img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, copy_count, &copy_regions);

        const to_color = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .image = self.color_img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &to_color);

        const dummy_clear = [1]VkClearValue{.{ .color = .{ 0, 0, 0, 0 } }};
        const rp_begin: VkRenderPassBeginInfo = .{
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = w, .height = h },
            },
            .clearValueCount = 0,
            .pClearValues = &dummy_clear,
        };
        self.vk.CmdBeginRenderPass(self.cmd, &rp_begin, 0);

        const cmd_target: Target = .{ .cmd = self.cmd, .width = w, .height = h, .flip_viewport_y = true };
        try r.recordTarget(c, &cmd_target, damage);

        self.vk.CmdEndRenderPass(self.cmd);

        const to_readback = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .image = self.color_img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_readback);

        self.vk.CmdCopyImageToBuffer(self.cmd, self.color_img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.staging_buf, copy_count, &copy_regions);

        if (self.vk.EndCommandBuffer(self.cmd) != .success) return error.VkEndCommandBufferFailed;
        const cmds = [1]VkCommandBuffer{self.cmd};
        const submits = [1]VkSubmitInfo{.{ .pCommandBuffers = &cmds }};
        if (self.vk.QueueSubmit(self.queue, 1, &submits, VK_NULL_HANDLE) != .success) return error.VkQueueSubmitFailed;
        _ = self.vk.QueueWaitIdle(self.queue);

        for (regions) |reg| {
            const sc = full_vp.intersect(reg) orelse continue;
            const dx: usize = @intCast(sc.x);
            const dy: usize = @intCast(sc.y);
            for (0..sc.height) |row| {
                const src = self.staging_map[(dy + row) * w + dx ..][0..sc.width];
                @memcpy(target.pixels[(dy + row) * stride + dx ..][0..sc.width], src);
            }
        }
    }
};

/// A host-visible memory type for a buffer the CPU reads back from: a
/// cached one if there is one, since reading uncached memory is many times
/// slower (10 ms instead of 0.25 ms for a 1.3 megapixel frame).
fn readbackMemoryType(ctx: anytype, type_bits: u32) !u32 {
    const host = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    return ctx.findMemoryType(type_bits, host | VK_MEMORY_PROPERTY_HOST_CACHED_BIT) catch ctx.findMemoryType(type_bits, host);
}

/// Managed offscreen Vulkan 1.1+ context with configurable MSAA (`1`, `2`, `4`, `8` samples)
/// render passes, dynamic uniform buffer (`gpu.uniforms`), pipeline builder, and
/// automatic readback for `VulkanArea`.
/// The 2D renderer's device, for a `VulkanContext` on it (`initShared`).
pub const SharedDevice = struct {
    instance: VkInstance,
    inst_procs: InstanceProcs,
    phys_dev: VkPhysicalDevice,
    mem_props: VkPhysicalDeviceMemoryProperties,
    device: VkDevice,
    vk: ContextProcs,
    queue: VkQueue,
    queue_family: u32,
    /// Whether the device has timeline semaphores turned on.
    timelines: bool = false,
};

/// A frame being drawn straight into a window buffer on the 2D renderer's
/// device: what a widget's GPU draw (`GpuDraw.direct`) records into. The
/// window image is in `GENERAL` layout, and outside a render pass.
pub const DirectFrame = struct {
    device: VkDevice,
    cmd: VkCommandBuffer,
    image: VkImage,
    /// Where the frame's top left is in the image (inside the shadow).
    origin: [2]i32,
    width: u32 = 0,
    height: u32 = 0,
    /// For draws on another API: copies the part of `src` (a picture of
    /// `area`'s viewport) within `area` into the frame, or returns false if
    /// it cannot be imported.
    copy_ctx: *anyopaque,
    copy_dmabuf: *const fn (ctx: *anyopaque, frame: *const DirectFrame, src: *const DmabufImage, area: GpuArea) anyerror!bool,
    /// Has the frame's submission wait for `w` (on its device) before what
    /// is drawn into it runs, with `copy_ctx`; false if it cannot (wait for
    /// it on the CPU then).
    wait: *const fn (ctx: *anyopaque, w: Wait) bool,
};

/// The Vulkan format of a DRM fourcc a picture can come in.
fn fourccFormat(fourcc: u32) ?u32 {
    const code = struct {
        fn f(s: *const [4]u8) u32 {
            return std.mem.readInt(u32, s, .little);
        }
    }.f;
    if (fourcc == code("AR24") or fourcc == code("XR24")) return VK_FORMAT_B8G8R8A8_UNORM;
    if (fourcc == code("AB24") or fourcc == code("XB24")) return VK_FORMAT_R8G8B8A8_UNORM;
    return null;
}

const VkImageBlit = extern struct {
    srcSubresource: VkImageSubresourceLayers = .{},
    srcOffsets: [2]VkOffset3D,
    dstSubresource: VkImageSubresourceLayers = .{},
    dstOffsets: [2]VkOffset3D,
};

pub const OffscreenContext = struct {
    pub const sample_counts = [4]u32{ 1, 2, 4, 8 };

    pub fn sampleIndex(samples: u8) u2 {
        return switch (samples) {
            0, 1 => 0,
            2, 3 => 1,
            4...7 => 2,
            else => 3,
        };
    }

    pub const Buffer = struct {
        buffer: VkBuffer = VK_NULL_HANDLE,
        memory: VkDeviceMemory = VK_NULL_HANDLE,
        size: VkDeviceSize = 0,
    };

    pub const Pipeline = struct {
        layout: VkPipelineLayout = VK_NULL_HANDLE,
        pipelines: [sample_counts.len]VkPipeline = @splat(VK_NULL_HANDLE),
    };

    pub const PipelineDesc = struct {
        /// Combined SPIR-V module containing `vertex` and `fragment` entry points.
        shader_spv: []align(4) const u8,
        vertex_stride: u32,
        attributes: []const shaders.Attribute,
        push_constant_size: u32 = 0,
        cull_mode: VkFlags = VK_CULL_MODE_BACK_BIT,
        front_face: u32 = VK_FRONT_FACE_COUNTER_CLOCKWISE,
        depth_test: bool = true,
    };

    const ubo_slot_size: usize = 256;
    const ubo_max_draws: usize = 64;
    const ubo_total_size: usize = ubo_slot_size * ubo_max_draws;

    gpa: std.mem.Allocator,
    vk_lib: std.DynLib,
    instance: VkInstance,
    inst_procs: InstanceProcs,
    phys_dev: VkPhysicalDevice,
    mem_props: VkPhysicalDeviceMemoryProperties,
    device: VkDevice,
    vk: ContextProcs,
    queue: VkQueue,
    cmd_pool: VkCommandPool = VK_NULL_HANDLE,
    cmd: VkCommandBuffer = undefined,
    render_passes: [sample_counts.len]VkRenderPass = @splat(VK_NULL_HANDLE),
    set_layout: VkDescriptorSetLayout = VK_NULL_HANDLE,
    desc_pool: VkDescriptorPool = VK_NULL_HANDLE,
    desc_set: VkDescriptorSet = VK_NULL_HANDLE,
    ubo_buf: VkBuffer = VK_NULL_HANDLE,
    ubo_mem: VkDeviceMemory = VK_NULL_HANDLE,
    ubo_map: []u8 = &.{},
    ubo_cursor: u32 = 0,
    active_layout: VkPipelineLayout = VK_NULL_HANDLE,

    width: u32 = 0,
    height: u32 = 0,
    fb_w: u32 = 0,
    fb_h: u32 = 0,
    fb_sample_idx: u2 = 2,
    msaa_color_img: VkImage = VK_NULL_HANDLE,
    msaa_color_mem: VkDeviceMemory = VK_NULL_HANDLE,
    msaa_color_view: VkImageView = VK_NULL_HANDLE,
    msaa_depth_img: VkImage = VK_NULL_HANDLE,
    msaa_depth_mem: VkDeviceMemory = VK_NULL_HANDLE,
    msaa_depth_view: VkImageView = VK_NULL_HANDLE,
    resolve_img: VkImage = VK_NULL_HANDLE,
    resolve_mem: VkDeviceMemory = VK_NULL_HANDLE,
    resolve_view: VkImageView = VK_NULL_HANDLE,
    framebuffer: VkFramebuffer = VK_NULL_HANDLE,
    readback_buf: VkBuffer = VK_NULL_HANDLE,
    readback_mem: VkDeviceMemory = VK_NULL_HANDLE,
    readback_map: []u32 = &.{},
    /// It is on another's device (`initShared`), which it does not destroy.
    shared: bool = false,
    /// Making and waiting on timeline semaphores, if the device can.
    timelines: ?TimelineProcs = null,

    pub fn init(gpa: std.mem.Allocator) !OffscreenContext {
        var vk_lib = std.DynLib.open("libvulkan.so.1") catch try std.DynLib.open("libvulkan.so");
        errdefer vk_lib.close();

        const get_inst_proc = vk_lib.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.MissingVkGetInstanceProcAddr;
        const create_instance: *const fn (*const VkInstanceCreateInfo, ?*const anyopaque, *VkInstance) callconv(.c) VkResult =
            @ptrCast(@alignCast(get_inst_proc(null, "vkCreateInstance") orelse return error.MissingVkCreateInstance));

        const app_info: VkApplicationInfo = .{};
        const inst_info: VkInstanceCreateInfo = .{ .pApplicationInfo = &app_info };
        var instance: VkInstance = undefined;
        if (create_instance(&inst_info, null, &instance) != .success) return error.VkCreateInstanceFailed;

        const inst_procs = try InstanceProcs.load(instance, get_inst_proc);
        errdefer inst_procs.DestroyInstance(instance, null);

        var dev_count: u32 = 0;
        if (inst_procs.EnumeratePhysicalDevices(instance, &dev_count, null) != .success or dev_count == 0) {
            return error.NoVulkanPhysicalDevice;
        }
        var phys_devs: [16]VkPhysicalDevice = undefined;
        var count: u32 = @min(dev_count, phys_devs.len);
        _ = inst_procs.EnumeratePhysicalDevices(instance, &count, &phys_devs);

        var chosen_phys: ?VkPhysicalDevice = null;
        var chosen_qfam: u32 = 0;
        outer: for (phys_devs[0..count]) |pd| {
            var qf_count: u32 = 0;
            inst_procs.GetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, null);
            var qfs: [16]VkQueueFamilyProperties = undefined;
            var qc: u32 = @min(qf_count, qfs.len);
            inst_procs.GetPhysicalDeviceQueueFamilyProperties(pd, &qc, &qfs);
            for (qfs[0..qc], 0..) |qf, qi| {
                if ((qf.queueFlags & 0x00000001) != 0) { // VK_QUEUE_GRAPHICS_BIT
                    chosen_phys = pd;
                    chosen_qfam = @intCast(qi);
                    break :outer;
                }
            }
        }
        const phys_dev = chosen_phys orelse return error.NoVulkanGraphicsQueue;

        var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
        inst_procs.GetPhysicalDeviceMemoryProperties(phys_dev, &mem_props);

        const prio = [1]f32{1.0};
        const q_info = [1]VkDeviceQueueCreateInfo{.{
            .queueFamilyIndex = chosen_qfam,
            .pQueuePriorities = &prio,
        }};
        // With timeline semaphores if it has them, to wait for work of the app's.
        const extensions: DeviceExtensions = .init(inst_procs, phys_dev, &.{});
        const dev_info = extensions.createInfo(&q_info);
        var device: VkDevice = undefined;
        if (inst_procs.CreateDevice(phys_dev, &dev_info, null, &device) != .success) return error.VkCreateDeviceFailed;

        const vk = try ContextProcs.load(device, inst_procs.GetDeviceProcAddr);
        var queue: VkQueue = undefined;
        vk.GetDeviceQueue(device, chosen_qfam, 0, &queue);

        var self: OffscreenContext = .{
            .gpa = gpa,
            .vk_lib = vk_lib,
            .instance = instance,
            .inst_procs = inst_procs,
            .phys_dev = phys_dev,
            .mem_props = mem_props,
            .device = device,
            .vk = vk,
            .queue = queue,
            .timelines = if (extensions.timelines) loadProcs(TimelineProcs, device, inst_procs.GetDeviceProcAddr) else null,
        };
        errdefer self.deinit();
        try self.initObjects(chosen_qfam);
        return self;
    }

    /// A context on the 2D renderer's device (`VulkanRenderer.sharedDevice`),
    /// so that what it draws can go straight into the renderer's frames
    /// (`renderToFrame`). It does not own the device, which must outlive it.
    pub fn initShared(gpa: std.mem.Allocator, dev: SharedDevice) !OffscreenContext {
        var self: OffscreenContext = .{
            .gpa = gpa,
            .vk_lib = undefined,
            .instance = dev.instance,
            .inst_procs = dev.inst_procs,
            .phys_dev = dev.phys_dev,
            .mem_props = dev.mem_props,
            .device = dev.device,
            .vk = dev.vk,
            .queue = dev.queue,
            .shared = true,
            .timelines = if (dev.timelines) loadProcs(TimelineProcs, dev.device, dev.inst_procs.GetDeviceProcAddr) else null,
        };
        errdefer self.deinit();
        try self.initObjects(dev.queue_family);
        return self;
    }

    /// Makes the command buffer, render passes, uniforms and samplers.
    fn initObjects(self: *OffscreenContext, queue_family: u32) !void {
        const pool_info: VkCommandPoolCreateInfo = .{ .queueFamilyIndex = queue_family };
        if (self.vk.CreateCommandPool(self.device, &pool_info, null, &self.cmd_pool) != .success) return error.VkCreateCommandPoolFailed;

        const cb_info: VkCommandBufferAllocateInfo = .{ .commandPool = self.cmd_pool };
        var cmds: [1]VkCommandBuffer = undefined;
        if (self.vk.AllocateCommandBuffers(self.device, &cb_info, &cmds) != .success) return error.VkAllocateCommandBufferFailed;
        self.cmd = cmds[0];

        // Create render passes for 1× (direct) and 2×/4×/8× MSAA (resolving to 1× B8G8R8A8_UNORM in TRANSFER_SRC_OPTIMAL)
        for (sample_counts, 0..) |sc, idx| {
            if (sc == 1) {
                const attachments = [2]VkAttachmentDescription{
                    .{
                        .format = VK_FORMAT_B8G8R8A8_UNORM,
                        .samples = 1,
                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                        .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    },
                    .{
                        .format = VK_FORMAT_D32_SFLOAT,
                        .samples = 1,
                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                        .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                        .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    },
                };
                const color_ref = [1]VkAttachmentReference{.{ .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL }};
                const depth_ref: VkAttachmentReference = .{ .attachment = 1, .layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
                const subpass = [1]VkSubpassDescription{.{
                    .pColorAttachments = &color_ref,
                    .pResolveAttachments = null,
                    .pDepthStencilAttachment = &depth_ref,
                }};
                const rp_info: VkRenderPassCreateInfo = .{
                    .attachmentCount = attachments.len,
                    .pAttachments = &attachments,
                    .pSubpasses = &subpass,
                };
                if (self.vk.CreateRenderPass(self.device, &rp_info, null, &self.render_passes[idx]) != .success) return error.VkCreateRenderPassFailed;
            } else {
                const attachments = [3]VkAttachmentDescription{
                    .{
                        .format = VK_FORMAT_B8G8R8A8_UNORM,
                        .samples = sc,
                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                        .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                        .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    },
                    .{
                        .format = VK_FORMAT_D32_SFLOAT,
                        .samples = sc,
                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                        .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                        .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    },
                    .{
                        .format = VK_FORMAT_B8G8R8A8_UNORM,
                        .samples = 1,
                        .loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                        .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    },
                };
                const color_ref = [1]VkAttachmentReference{.{ .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL }};
                const depth_ref: VkAttachmentReference = .{ .attachment = 1, .layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
                const resolve_ref = [1]VkAttachmentReference{.{ .attachment = 2, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL }};
                const subpass = [1]VkSubpassDescription{.{
                    .pColorAttachments = &color_ref,
                    .pResolveAttachments = &resolve_ref,
                    .pDepthStencilAttachment = &depth_ref,
                }};
                const rp_info: VkRenderPassCreateInfo = .{
                    .attachmentCount = attachments.len,
                    .pAttachments = &attachments,
                    .pSubpasses = &subpass,
                };
                if (self.vk.CreateRenderPass(self.device, &rp_info, null, &self.render_passes[idx]) != .success) return error.VkCreateRenderPassFailed;
            }
        }

        // Descriptor set layout and dynamic uniform buffer for `gpu.uniforms(T)` at set=0, binding=0
        const bindings = [1]VkDescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .stageFlags = VK_SHADER_STAGE_ALL_GRAPHICS,
        }};
        const dsl_info: VkDescriptorSetLayoutCreateInfo = .{
            .bindingCount = 1,
            .pBindings = &bindings,
        };
        if (self.vk.CreateDescriptorSetLayout(self.device, &dsl_info, null, &self.set_layout) != .success) return error.VkCreateDescriptorSetLayoutFailed;

        const pool_sizes = [1]VkDescriptorPoolSize{.{
            .type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .descriptorCount = 1,
        }};
        const dp_info: VkDescriptorPoolCreateInfo = .{
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_sizes,
        };
        if (self.vk.CreateDescriptorPool(self.device, &dp_info, null, &self.desc_pool) != .success) return error.VkCreateDescriptorPoolFailed;

        const layouts = [1]VkDescriptorSetLayout{self.set_layout};
        const dsa_info: VkDescriptorSetAllocateInfo = .{
            .descriptorPool = self.desc_pool,
            .pSetLayouts = &layouts,
        };
        var sets: [1]VkDescriptorSet = undefined;
        if (self.vk.AllocateDescriptorSets(self.device, &dsa_info, &sets) != .success) return error.VkAllocateDescriptorSetsFailed;
        self.desc_set = sets[0];

        const ubo_info: VkBufferCreateInfo = .{
            .size = ubo_total_size,
            .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        };
        if (self.vk.CreateBuffer(self.device, &ubo_info, null, &self.ubo_buf) != .success) return error.VkCreateBufferFailed;
        var req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(self.device, self.ubo_buf, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = @max(req.size, ubo_total_size),
            .memoryTypeIndex = mem_type,
        };
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &self.ubo_mem) != .success) return error.VkAllocateMemoryFailed;
        if (self.vk.BindBufferMemory(self.device, self.ubo_buf, self.ubo_mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        var ubo_ptr: ?*anyopaque = null;
        if (self.vk.MapMemory(self.device, self.ubo_mem, 0, ubo_total_size, 0, &ubo_ptr) != .success or ubo_ptr == null) return error.VkMapMemoryFailed;
        self.ubo_map = @as([*]u8, @ptrCast(ubo_ptr.?))[0..ubo_total_size];

        const buf_desc: VkDescriptorBufferInfo = .{
            .buffer = self.ubo_buf,
            .offset = 0,
            .range = ubo_slot_size,
        };
        const write = [1]VkWriteDescriptorSet{.{
            .dstSet = self.desc_set,
            .dstBinding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .pBufferInfo = &buf_desc,
        }};
        self.vk.UpdateDescriptorSets(self.device, 1, &write, 0, null);
    }

    pub fn deinit(self: *OffscreenContext) void {
        _ = self.vk.DeviceWaitIdle(self.device);
        self.destroyTargets();
        if (self.ubo_map.len > 0) self.vk.UnmapMemory(self.device, self.ubo_mem);
        if (self.ubo_buf != VK_NULL_HANDLE) self.vk.DestroyBuffer(self.device, self.ubo_buf, null);
        if (self.ubo_mem != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, self.ubo_mem, null);
        if (self.desc_pool != VK_NULL_HANDLE) self.vk.DestroyDescriptorPool(self.device, self.desc_pool, null);
        if (self.set_layout != VK_NULL_HANDLE) self.vk.DestroyDescriptorSetLayout(self.device, self.set_layout, null);
        for (self.render_passes) |rp| {
            if (rp != VK_NULL_HANDLE) self.vk.DestroyRenderPass(self.device, rp, null);
        }
        if (self.cmd_pool != VK_NULL_HANDLE) self.vk.DestroyCommandPool(self.device, self.cmd_pool, null);
        if (self.shared) return;
        self.vk.DestroyDevice(self.device, null);
        self.inst_procs.DestroyInstance(self.instance, null);
        self.vk_lib.close();
    }

    /// Whether it can make timeline semaphores (`createTimeline`), for
    /// scenes to wait for GPU work done elsewhere (`Wait`).
    pub fn supportsTimelines(self: *const OffscreenContext) bool {
        return self.timelines != null;
    }

    /// Makes a timeline semaphore on its device starting at `initial_value`,
    /// for work on the GPU to signal and scenes to wait for (`Wait`).
    pub fn createTimeline(self: *const OffscreenContext, initial_value: u64) !VkSemaphore {
        const t = self.timelines orelse return error.Unsupported;
        const type_info: VkSemaphoreTypeCreateInfo = .{ .initialValue = initial_value };
        var sem: VkSemaphore = VK_NULL_HANDLE;
        if (t.CreateSemaphore(self.device, &.{ .pNext = &type_info }, null, &sem) != .success) return error.VkCreateSemaphoreFailed;
        return sem;
    }

    pub fn destroyTimeline(self: *const OffscreenContext, semaphore: VkSemaphore) void {
        if (self.timelines) |t| t.DestroySemaphore(self.device, semaphore, null);
    }

    /// Sets `semaphore` to `value` from the CPU. (Work on the GPU signals it
    /// in its submission instead.)
    pub fn signalTimeline(self: *const OffscreenContext, semaphore: VkSemaphore, value: u64) !void {
        const t = self.timelines orelse return error.Unsupported;
        if (t.SignalSemaphoreKHR(self.device, &.{ .semaphore = semaphore, .value = value }) != .success) return error.VkSignalSemaphoreFailed;
    }

    /// Waits on the CPU until `w` is done.
    pub fn waitTimeline(self: *const OffscreenContext, w: Wait) !void {
        const t = self.timelines orelse return error.Unsupported;
        const sems = [1]VkSemaphore{w.semaphore};
        const values = [1]u64{w.value};
        if (t.WaitSemaphoresKHR(self.device, &.{ .pSemaphores = &sems, .pValues = &values }, std.math.maxInt(u64)) != .success) return error.VkWaitSemaphoresFailed;
    }

    pub fn aspect(self: *const OffscreenContext) f32 {
        if (self.height == 0) return 1.0;
        return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
    }

    fn findMemoryType(self: *const OffscreenContext, type_bits: u32, req_flags: VkFlags) !u32 {
        for (0..self.mem_props.memoryTypeCount) |i| {
            const bit = @as(u32, 1) << @intCast(i);
            if ((type_bits & bit) != 0 and (self.mem_props.memoryTypes[i].propertyFlags & req_flags) == req_flags) {
                return @intCast(i);
            }
        }
        return error.NoSuitableVulkanMemoryType;
    }

    pub fn createBuffer(self: *const OffscreenContext, usage: VkBufferUsageFlags, bytes: []const u8) !Buffer {
        const size: VkDeviceSize = @max(bytes.len, 16);
        const buf_info: VkBufferCreateInfo = .{ .size = size, .usage = usage };
        var buf: VkBuffer = VK_NULL_HANDLE;
        if (self.vk.CreateBuffer(self.device, &buf_info, null, &buf) != .success) return error.VkCreateBufferFailed;
        errdefer self.vk.DestroyBuffer(self.device, buf, null);

        var req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(self.device, buf, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = @max(req.size, size),
            .memoryTypeIndex = mem_type,
        };
        var mem: VkDeviceMemory = VK_NULL_HANDLE;
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &mem) != .success) return error.VkAllocateMemoryFailed;
        errdefer self.vk.FreeMemory(self.device, mem, null);

        if (self.vk.BindBufferMemory(self.device, buf, mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        if (bytes.len > 0) {
            var ptr: ?*anyopaque = null;
            if (self.vk.MapMemory(self.device, mem, 0, size, 0, &ptr) != .success or ptr == null) return error.VkMapMemoryFailed;
            @memcpy(@as([*]u8, @ptrCast(ptr.?))[0..bytes.len], bytes);
            self.vk.UnmapMemory(self.device, mem);
        }
        return .{ .buffer = buf, .memory = mem, .size = size };
    }

    pub fn createVertexBuffer(self: *const OffscreenContext, comptime T: type, items: []const T) !Buffer {
        return self.createBuffer(VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, std.mem.sliceAsBytes(items));
    }

    pub fn createIndexBuffer(self: *const OffscreenContext, indices: []const u16) !Buffer {
        return self.createBuffer(VK_BUFFER_USAGE_INDEX_BUFFER_BIT, std.mem.sliceAsBytes(indices));
    }

    pub fn destroyBuffer(self: *const OffscreenContext, buf: Buffer) void {
        if (buf.buffer != VK_NULL_HANDLE) self.vk.DestroyBuffer(self.device, buf.buffer, null);
        if (buf.memory != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, buf.memory, null);
    }

    pub fn createPipeline(self: *const OffscreenContext, desc: PipelineDesc) !Pipeline {
        const sm_info: VkShaderModuleCreateInfo = .{
            .codeSize = desc.shader_spv.len,
            .pCode = @ptrCast(desc.shader_spv.ptr),
        };
        var shader_mod: VkShaderModule = VK_NULL_HANDLE;
        if (self.vk.CreateShaderModule(self.device, &sm_info, null, &shader_mod) != .success) return error.VkCreateShaderModuleFailed;
        defer self.vk.DestroyShaderModule(self.device, shader_mod, null);

        const set_layouts = [1]VkDescriptorSetLayout{self.set_layout};
        const pc_range = [1]VkPushConstantRange{.{
            .stageFlags = VK_SHADER_STAGE_ALL_GRAPHICS,
            .size = desc.push_constant_size,
        }};
        const pl_info: VkPipelineLayoutCreateInfo = .{
            .setLayoutCount = 1,
            .pSetLayouts = &set_layouts,
            .pushConstantRangeCount = if (desc.push_constant_size > 0) 1 else 0,
            .pPushConstantRanges = if (desc.push_constant_size > 0) &pc_range else null,
        };
        var layout: VkPipelineLayout = VK_NULL_HANDLE;
        if (self.vk.CreatePipelineLayout(self.device, &pl_info, null, &layout) != .success) return error.VkCreatePipelineLayoutFailed;

        var p: Pipeline = .{ .layout = layout };
        errdefer self.destroyPipeline(p);

        const stages = [2]VkPipelineShaderStageCreateInfo{
            .{ .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = shader_mod, .pName = "vertex" },
            .{ .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = shader_mod, .pName = "fragment" },
        };

        const binding = [1]VkVertexInputBindingDescription{.{ .stride = desc.vertex_stride }};
        var attrs: [8]VkVertexInputAttributeDescription = undefined;
        const attr_count = @min(desc.attributes.len, attrs.len);
        for (desc.attributes[0..attr_count], attrs[0..attr_count]) |a, *out| {
            out.* = .{
                .location = a.location,
                .format = switch (a.components) {
                    1 => VK_FORMAT_R32_SFLOAT,
                    2 => VK_FORMAT_R32G32_SFLOAT,
                    3 => VK_FORMAT_R32G32B32_SFLOAT,
                    else => VK_FORMAT_R32G32B32A32_SFLOAT,
                },
                .offset = a.offset,
            };
        }
        const vertex_input: VkPipelineVertexInputStateCreateInfo = .{
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding,
            .vertexAttributeDescriptionCount = @intCast(attr_count),
            .pVertexAttributeDescriptions = &attrs,
        };
        const input_assembly: VkPipelineInputAssemblyStateCreateInfo = .{};
        const viewport_state: VkPipelineViewportStateCreateInfo = .{};
        const raster: VkPipelineRasterizationStateCreateInfo = .{
            .cullMode = desc.cull_mode,
            .frontFace = desc.front_face,
        };
        const depth_stencil: VkPipelineDepthStencilStateCreateInfo = .{
            .depthTestEnable = if (desc.depth_test) VK_TRUE else VK_FALSE,
            .depthWriteEnable = if (desc.depth_test) VK_TRUE else VK_FALSE,
        };
        const blend_att = [1]VkPipelineColorBlendAttachmentState{.{}};
        const color_blend: VkPipelineColorBlendStateCreateInfo = .{ .pAttachments = &blend_att };
        const dyn_states = [2]u32{ 0, 1 }; // VIEWPORT, SCISSOR
        const dynamic_state: VkPipelineDynamicStateCreateInfo = .{
            .dynamicStateCount = dyn_states.len,
            .pDynamicStates = &dyn_states,
        };

        for (sample_counts, 0..) |sc, idx| {
            const multisample: VkPipelineMultisampleStateCreateInfo = .{
                .rasterizationSamples = sc,
            };
            const gp_info = [1]VkGraphicsPipelineCreateInfo{.{
                .pStages = &stages,
                .pVertexInputState = &vertex_input,
                .pInputAssemblyState = &input_assembly,
                .pViewportState = &viewport_state,
                .pRasterizationState = &raster,
                .pMultisampleState = &multisample,
                .pDepthStencilState = &depth_stencil,
                .pColorBlendState = &color_blend,
                .pDynamicState = &dynamic_state,
                .layout = layout,
                .renderPass = self.render_passes[idx],
            }};
            var out_pipe: [1]VkPipeline = undefined;
            if (self.vk.CreateGraphicsPipelines(self.device, VK_NULL_HANDLE, 1, &gp_info, null, &out_pipe) != .success) {
                return error.VkCreateGraphicsPipelineFailed;
            }
            p.pipelines[idx] = out_pipe[0];
        }
        return p;
    }

    pub fn destroyPipeline(self: *const OffscreenContext, p: Pipeline) void {
        for (p.pipelines) |pipe| {
            if (pipe != VK_NULL_HANDLE) self.vk.DestroyPipeline(self.device, pipe, null);
        }
        if (p.layout != VK_NULL_HANDLE) self.vk.DestroyPipelineLayout(self.device, p.layout, null);
    }

    pub fn bindPipeline(self: *OffscreenContext, p: Pipeline) void {
        self.active_layout = p.layout;
        self.vk.CmdBindPipeline(self.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p.pipelines[self.fb_sample_idx]);
    }

    pub fn setUniforms(self: *OffscreenContext, comptime T: type, value: *const T) void {
        std.debug.assert(@sizeOf(T) <= ubo_slot_size);
        if (self.ubo_cursor >= ubo_max_draws) return;
        const offset: u32 = self.ubo_cursor * @as(u32, @intCast(ubo_slot_size));
        self.ubo_cursor += 1;
        @memcpy(self.ubo_map[offset..][0..@sizeOf(T)], std.mem.asBytes(value));
        const sets = [1]VkDescriptorSet{self.desc_set};
        const dyn_offsets = [1]u32{offset};
        self.vk.CmdBindDescriptorSets(
            self.cmd,
            VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.active_layout,
            0,
            1,
            &sets,
            1,
            &dyn_offsets,
        );
    }

    pub fn bindVertexBuffer(self: *const OffscreenContext, buf: Buffer) void {
        const bufs = [1]VkBuffer{buf.buffer};
        const offs = [1]VkDeviceSize{0};
        self.vk.CmdBindVertexBuffers(self.cmd, 0, 1, &bufs, &offs);
    }

    pub fn bindIndexBuffer16(self: *const OffscreenContext, buf: Buffer) void {
        self.vk.CmdBindIndexBuffer(self.cmd, buf.buffer, 0, VK_INDEX_TYPE_UINT16);
    }

    pub fn drawIndexed(self: *const OffscreenContext, index_count: u32) void {
        self.vk.CmdDrawIndexed(self.cmd, index_count, 1, 0, 0, 0);
    }

    fn createAttachmentImage(
        self: *const OffscreenContext,
        w: u32,
        h: u32,
        format: u32,
        samples: u32,
        usage: VkFlags,
        aspect_mask: VkFlags,
    ) !struct { img: VkImage, mem: VkDeviceMemory, view: VkImageView } {
        const img_info: VkImageCreateInfo = .{
            .format = format,
            .extent = .{ .width = w, .height = h },
            .samples = samples,
            .usage = usage,
        };
        var img: VkImage = VK_NULL_HANDLE;
        if (self.vk.CreateImage(self.device, &img_info, null, &img) != .success) return error.VkCreateImageFailed;
        errdefer self.vk.DestroyImage(self.device, img, null);

        var req: VkMemoryRequirements = undefined;
        self.vk.GetImageMemoryRequirements(self.device, img, &req);
        const mem_type = try self.findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        const alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = req.size,
            .memoryTypeIndex = mem_type,
        };
        var mem: VkDeviceMemory = VK_NULL_HANDLE;
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &mem) != .success) return error.VkAllocateMemoryFailed;
        errdefer self.vk.FreeMemory(self.device, mem, null);

        if (self.vk.BindImageMemory(self.device, img, mem, 0) != .success) return error.VkBindImageMemoryFailed;

        const view_info: VkImageViewCreateInfo = .{
            .image = img,
            .format = format,
            .subresourceRange = .{ .aspectMask = aspect_mask },
        };
        var view: VkImageView = VK_NULL_HANDLE;
        if (self.vk.CreateImageView(self.device, &view_info, null, &view) != .success) return error.VkCreateImageViewFailed;

        return .{ .img = img, .mem = mem, .view = view };
    }

    fn destroyTargets(self: *OffscreenContext) void {
        if (self.readback_map.len > 0) {
            self.vk.UnmapMemory(self.device, self.readback_mem);
            self.readback_map = &.{};
        }
        if (self.readback_buf != VK_NULL_HANDLE) {
            self.vk.DestroyBuffer(self.device, self.readback_buf, null);
            self.readback_buf = VK_NULL_HANDLE;
        }
        if (self.readback_mem != VK_NULL_HANDLE) {
            self.vk.FreeMemory(self.device, self.readback_mem, null);
            self.readback_mem = VK_NULL_HANDLE;
        }
        if (self.framebuffer != VK_NULL_HANDLE) {
            self.vk.DestroyFramebuffer(self.device, self.framebuffer, null);
            self.framebuffer = VK_NULL_HANDLE;
        }
        for ([_]VkImageView{ self.msaa_color_view, self.msaa_depth_view, self.resolve_view }) |v| {
            if (v != VK_NULL_HANDLE) self.vk.DestroyImageView(self.device, v, null);
        }
        for ([_]VkImage{ self.msaa_color_img, self.msaa_depth_img, self.resolve_img }) |img| {
            if (img != VK_NULL_HANDLE) self.vk.DestroyImage(self.device, img, null);
        }
        for ([_]VkDeviceMemory{ self.msaa_color_mem, self.msaa_depth_mem, self.resolve_mem }) |m| {
            if (m != VK_NULL_HANDLE) self.vk.FreeMemory(self.device, m, null);
        }
        self.msaa_color_view = VK_NULL_HANDLE;
        self.msaa_depth_view = VK_NULL_HANDLE;
        self.resolve_view = VK_NULL_HANDLE;
        self.msaa_color_img = VK_NULL_HANDLE;
        self.msaa_depth_img = VK_NULL_HANDLE;
        self.resolve_img = VK_NULL_HANDLE;
        self.msaa_color_mem = VK_NULL_HANDLE;
        self.msaa_depth_mem = VK_NULL_HANDLE;
        self.resolve_mem = VK_NULL_HANDLE;
        self.fb_w = 0;
        self.fb_h = 0;
    }

    fn ensureTargets(self: *OffscreenContext, w: u32, h: u32, samples: u8) !void {
        const s_idx = sampleIndex(samples);
        const sc = sample_counts[s_idx];
        if (self.fb_w == w and self.fb_h == h and self.fb_sample_idx == s_idx and self.framebuffer != VK_NULL_HANDLE) return;
        self.destroyTargets();
        errdefer self.destroyTargets();

        const res_c = try self.createAttachmentImage(w, h, VK_FORMAT_B8G8R8A8_UNORM, 1, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_IMAGE_ASPECT_COLOR_BIT);
        self.resolve_img = res_c.img;
        self.resolve_mem = res_c.mem;
        self.resolve_view = res_c.view;

        const msaa_d = try self.createAttachmentImage(w, h, VK_FORMAT_D32_SFLOAT, sc, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, VK_IMAGE_ASPECT_DEPTH_BIT);
        self.msaa_depth_img = msaa_d.img;
        self.msaa_depth_mem = msaa_d.mem;
        self.msaa_depth_view = msaa_d.view;

        if (sc == 1) {
            const views = [2]VkImageView{ self.resolve_view, self.msaa_depth_view };
            const fb_info: VkFramebufferCreateInfo = .{
                .renderPass = self.render_passes[s_idx],
                .attachmentCount = views.len,
                .pAttachments = &views,
                .width = w,
                .height = h,
            };
            if (self.vk.CreateFramebuffer(self.device, &fb_info, null, &self.framebuffer) != .success) return error.VkCreateFramebufferFailed;
        } else {
            const msaa_c = try self.createAttachmentImage(w, h, VK_FORMAT_B8G8R8A8_UNORM, sc, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, VK_IMAGE_ASPECT_COLOR_BIT);
            self.msaa_color_img = msaa_c.img;
            self.msaa_color_mem = msaa_c.mem;
            self.msaa_color_view = msaa_c.view;

            const views = [3]VkImageView{ self.msaa_color_view, self.msaa_depth_view, self.resolve_view };
            const fb_info: VkFramebufferCreateInfo = .{
                .renderPass = self.render_passes[s_idx],
                .attachmentCount = views.len,
                .pAttachments = &views,
                .width = w,
                .height = h,
            };
            if (self.vk.CreateFramebuffer(self.device, &fb_info, null, &self.framebuffer) != .success) return error.VkCreateFramebufferFailed;
        }

        const pixel_count = @as(usize, w) * h;
        const byte_size: VkDeviceSize = pixel_count * 4;
        const buf_info: VkBufferCreateInfo = .{
            .size = byte_size,
            .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        };
        if (self.vk.CreateBuffer(self.device, &buf_info, null, &self.readback_buf) != .success) return error.VkCreateBufferFailed;
        var req: VkMemoryRequirements = undefined;
        self.vk.GetBufferMemoryRequirements(self.device, self.readback_buf, &req);
        const mem_type = try readbackMemoryType(self, req.memoryTypeBits);
        const alloc_info: VkMemoryAllocateInfo = .{
            .allocationSize = @max(req.size, byte_size),
            .memoryTypeIndex = mem_type,
        };
        if (self.vk.AllocateMemory(self.device, &alloc_info, null, &self.readback_mem) != .success) return error.VkAllocateMemoryFailed;
        if (self.vk.BindBufferMemory(self.device, self.readback_buf, self.readback_mem, 0) != .success) return error.VkBindBufferMemoryFailed;
        var ptr: ?*anyopaque = null;
        if (self.vk.MapMemory(self.device, self.readback_mem, 0, byte_size, 0, &ptr) != .success or ptr == null) return error.VkMapMemoryFailed;
        self.readback_map = @as([*]u32, @ptrCast(@alignCast(ptr.?)))[0..pixel_count];

        self.fb_w = w;
        self.fb_h = h;
        self.fb_sample_idx = s_idx;
    }

    /// Draws the scene over `area`'s viewport into `target` on the CPU,
    /// within its scissor, once `wait` (if given) is done.
    pub fn renderToImage(
        self: *OffscreenContext,
        target: *software.Image,
        area: GpuArea,
        clear_color: ?Color,
        samples: u8,
        wait: ?Wait,
        user_ctx: anytype,
        comptime render_fn: anytype,
    ) !void {
        const vp = area.viewport;
        if (vp.width == 0 or vp.height == 0) return;
        const full: Viewport = .{ .width = target.width, .height = target.height };
        const sc = full.intersect(if (area.scissor) |s| vp.intersect(s) orelse return else vp) orelse return;
        var waits: SubmitWaits = .{};
        if (wait) |w| {
            if (self.timelines == null) return error.Unsupported;
            _ = waits.add(w.semaphore, w.value, false);
        }

        try self.ensureTargets(vp.width, vp.height, samples);
        self.width = vp.width;
        self.height = vp.height;
        self.ubo_cursor = 0;

        _ = self.vk.ResetCommandBuffer(self.cmd, 0);
        const begin_info: VkCommandBufferBeginInfo = .{};
        if (self.vk.BeginCommandBuffer(self.cmd, &begin_info) != .success) return error.VkBeginCommandBufferFailed;

        const bg = clear_color orelse Color.argb(0xff000000);
        const clears = [2]VkClearValue{
            .{ .color = .{ bg.r, bg.g, bg.b, bg.a } },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        const rp_begin: VkRenderPassBeginInfo = .{
            .renderPass = self.render_passes[self.fb_sample_idx],
            .framebuffer = self.framebuffer,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = vp.width, .height = vp.height },
            },
            .clearValueCount = clears.len,
            .pClearValues = &clears,
        };
        self.vk.CmdBeginRenderPass(self.cmd, &rp_begin, 0);

        const wf: f32 = @floatFromInt(vp.width);
        const hf: f32 = @floatFromInt(vp.height);
        // Negative viewport height (Vulkan 1.1+) makes clip-space +Y point up, matching OpenGL.
        const vk_vp = [1]VkViewport{.{ .x = 0, .y = hf, .width = wf, .height = -hf, .minDepth = 0.0, .maxDepth = 1.0 }};
        const vk_sc = [1]VkRect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = vp.width, .height = vp.height } }};
        self.vk.CmdSetViewport(self.cmd, 0, 1, &vk_vp);
        self.vk.CmdSetScissor(self.cmd, 0, 1, &vk_sc);

        try render_fn(user_ctx, self);

        self.vk.CmdEndRenderPass(self.cmd);

        // Barrier: the render pass's finalLayout transitions resolve_img to
        // TRANSFER_SRC_OPTIMAL, but its COLOR_ATTACHMENT write must be visible
        // to the TRANSFER read below.  Without this barrier the copy may race
        // the rasteriser on tiling GPUs (and triggers Vulkan validation errors).
        const resolve_barrier = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .image = self.resolve_img,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &resolve_barrier);

        const copy_region = [1]VkBufferImageCopy{.{
            .imageExtent = .{ .width = vp.width, .height = vp.height, .depth = 1 },
        }};
        self.vk.CmdCopyImageToBuffer(
            self.cmd,
            self.resolve_img,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            self.readback_buf,
            1,
            &copy_region,
        );

        if (self.vk.EndCommandBuffer(self.cmd) != .success) return error.VkEndCommandBufferFailed;

        const cmds = [1]VkCommandBuffer{self.cmd};
        var submits = [1]VkSubmitInfo{.{ .pCommandBuffers = &cmds }};
        waits.apply(&submits[0]);
        if (self.vk.QueueSubmit(self.queue, 1, &submits, VK_NULL_HANDLE) != .success) return error.VkQueueSubmitFailed;
        _ = self.vk.QueueWaitIdle(self.queue);

        const local_x: usize = @intCast(sc.x - vp.x);
        const local_y: usize = @intCast(sc.y - vp.y);
        const dst_stride = target.rowStride();
        const dst_x: usize = @intCast(sc.x);
        for (0..sc.height) |row| {
            const dst_y: usize = @intCast(sc.y + @as(i32, @intCast(row)));
            const src_row = self.readback_map[(local_y + row) * vp.width + local_x ..][0..sc.width];
            @memcpy(target.pixels[dst_y * dst_stride + dst_x ..][0..sc.width], src_row);
        }
    }

    /// As `renderToImage`, but recorded into a frame the 2D renderer is
    /// drawing straight into a window buffer, and copied into it on the GPU.
    /// False if the frame is not on this context's device (draw it with
    /// `renderToImage`).
    pub fn renderToFrame(
        self: *OffscreenContext,
        frame: *const DirectFrame,
        area: GpuArea,
        clear_color: ?Color,
        samples: u8,
        wait: ?Wait,
        user_ctx: anytype,
        comptime render_fn: anytype,
    ) !bool {
        if (frame.device != self.device) return false;
        // The frame's submission waits for it, or else the CPU does.
        if (wait) |w| if (!frame.wait(frame.copy_ctx, w)) try self.waitTimeline(w);
        const vp = area.viewport;
        if (vp.width == 0 or vp.height == 0) return true;
        const clipped = if (area.scissor) |s| vp.intersect(s) orelse return true else vp;
        const sc = if (frame.width > 0 and frame.height > 0)
            (Viewport{ .width = frame.width, .height = frame.height }).intersect(clipped) orelse return true
        else
            clipped;

        try self.ensureTargets(vp.width, vp.height, samples);
        self.width = vp.width;
        self.height = vp.height;
        self.ubo_cursor = 0;
        // The scene's draws go into the frame's command buffer.
        const own_cmd = self.cmd;
        self.cmd = frame.cmd;
        defer self.cmd = own_cmd;

        const bg = clear_color orelse Color.argb(0xff000000);
        const clears = [2]VkClearValue{
            .{ .color = .{ bg.r, bg.g, bg.b, bg.a } },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        const rp_begin: VkRenderPassBeginInfo = .{
            .renderPass = self.render_passes[self.fb_sample_idx],
            .framebuffer = self.framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = vp.width, .height = vp.height } },
            .clearValueCount = clears.len,
            .pClearValues = &clears,
        };
        self.vk.CmdBeginRenderPass(self.cmd, &rp_begin, 0);
        const wf: f32 = @floatFromInt(vp.width);
        const hf: f32 = @floatFromInt(vp.height);
        const vk_vp = [1]VkViewport{.{ .x = 0, .y = hf, .width = wf, .height = -hf, .minDepth = 0.0, .maxDepth = 1.0 }};
        const vk_sc = [1]VkRect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = vp.width, .height = vp.height } }};
        self.vk.CmdSetViewport(self.cmd, 0, 1, &vk_vp);
        self.vk.CmdSetScissor(self.cmd, 0, 1, &vk_sc);
        try render_fn(user_ctx, self);
        self.vk.CmdEndRenderPass(self.cmd);

        // The resolved scene (in TRANSFER_SRC_OPTIMAL, from the render pass)
        // into the window image, after what the 2D renderer drew there and
        // before what it draws over it.
        const color = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        const to_copy = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = color,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
            .newLayout = VK_IMAGE_LAYOUT_GENERAL,
            .image = frame.image,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_copy);
        const region = [1]VkImageCopy{.{
            .srcOffset = .{ .x = sc.x - vp.x, .y = sc.y - vp.y, .z = 0 },
            .dstOffset = .{ .x = sc.x + frame.origin[0], .y = sc.y + frame.origin[1], .z = 0 },
            .extent = .{ .width = sc.width, .height = sc.height, .depth = 1 },
        }};
        self.vk.CmdCopyImage(self.cmd, self.resolve_img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, frame.image, VK_IMAGE_LAYOUT_GENERAL, 1, &region);
        const after_copy = [1]VkImageMemoryBarrier{.{
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = color,
            .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
            .newLayout = VK_IMAGE_LAYOUT_GENERAL,
            .image = frame.image,
            .subresourceRange = .{ .aspectMask = VK_IMAGE_ASPECT_COLOR },
        }};
        self.vk.CmdPipelineBarrier(self.cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &after_copy);
        return true;
    }
};

test "VulkanRenderer creates SPIR-V shader modules, prepares vertex buffers, and records draws" {
    const MockVk = struct {
        var next_handle: u64 = 1;
        var draws: usize = 0;
        var last_scissor: VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 0, .height = 0 } };
        var backing_mem: [128 * 1024]u8 = undefined;

        fn createShaderModule(_: VkDevice, info: *const VkShaderModuleCreateInfo, _: ?*const anyopaque, out: *VkShaderModule) callconv(.c) VkResult {
            // Verify SPIR-V magic number (0x07230203)
            if (info.codeSize < 4 or info.pCode[0] != 0x07230203) return @fromBackingInt(-1);
            out.* = next_handle;
            next_handle += 1;
            return .success;
        }
        fn destroyShaderModule(_: VkDevice, _: VkShaderModule, _: ?*const anyopaque) callconv(.c) void {}
        fn createBuffer(_: VkDevice, _: *const VkBufferCreateInfo, _: ?*const anyopaque, out: *VkBuffer) callconv(.c) VkResult {
            out.* = next_handle;
            next_handle += 1;
            return .success;
        }
        fn destroyBuffer(_: VkDevice, _: VkBuffer, _: ?*const anyopaque) callconv(.c) void {}
        fn getBufferMemoryRequirements(_: VkDevice, _: VkBuffer, req: *VkMemoryRequirements) callconv(.c) void {
            req.* = .{ .size = backing_mem.len, .alignment = 16, .memoryTypeBits = 1 };
        }
        fn allocateMemory(_: VkDevice, _: *const VkMemoryAllocateInfo, _: ?*const anyopaque, out: *VkDeviceMemory) callconv(.c) VkResult {
            out.* = next_handle;
            next_handle += 1;
            return .success;
        }
        fn freeMemory(_: VkDevice, _: VkDeviceMemory, _: ?*const anyopaque) callconv(.c) void {}
        fn bindBufferMemory(_: VkDevice, _: VkBuffer, _: VkDeviceMemory, _: VkDeviceSize) callconv(.c) VkResult {
            return .success;
        }
        fn mapMemory(_: VkDevice, _: VkDeviceMemory, _: VkDeviceSize, _: VkDeviceSize, _: VkFlags, out: *?*anyopaque) callconv(.c) VkResult {
            out.* = &backing_mem;
            return .success;
        }
        fn unmapMemory(_: VkDevice, _: VkDeviceMemory) callconv(.c) void {}
        fn cmdBindPipeline(_: VkCommandBuffer, _: u32, _: VkPipeline) callconv(.c) void {}
        fn cmdSetViewport(_: VkCommandBuffer, _: u32, _: u32, _: [*]const VkViewport) callconv(.c) void {}
        fn cmdSetScissor(_: VkCommandBuffer, _: u32, _: u32, rects: [*]const VkRect2D) callconv(.c) void {
            last_scissor = rects[0];
        }
        fn cmdBindVertexBuffers(_: VkCommandBuffer, _: u32, _: u32, _: [*]const VkBuffer, _: [*]const VkDeviceSize) callconv(.c) void {}
        fn cmdBindDescriptorSets(_: VkCommandBuffer, _: u32, _: VkPipelineLayout, _: u32, _: u32, _: [*]const VkDescriptorSet, _: u32, _: ?[*]const u32) callconv(.c) void {}
        fn cmdDraw(_: VkCommandBuffer, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {
            draws += 1;
        }
    };

    var dummy_dev: u8 = 0;
    var vk_renderer = try VulkanRenderer.initWithProcs(
        std.testing.allocator,
        @ptrCast(&dummy_dev),
        .{
            .CreateShaderModule = MockVk.createShaderModule,
            .DestroyShaderModule = MockVk.destroyShaderModule,
            .CreateBuffer = MockVk.createBuffer,
            .DestroyBuffer = MockVk.destroyBuffer,
            .GetBufferMemoryRequirements = MockVk.getBufferMemoryRequirements,
            .AllocateMemory = MockVk.allocateMemory,
            .FreeMemory = MockVk.freeMemory,
            .BindBufferMemory = MockVk.bindBufferMemory,
            .MapMemory = MockVk.mapMemory,
            .UnmapMemory = MockVk.unmapMemory,
            .CmdBindPipeline = MockVk.cmdBindPipeline,
            .CmdSetViewport = MockVk.cmdSetViewport,
            .CmdSetScissor = MockVk.cmdSetScissor,
            .CmdBindVertexBuffers = MockVk.cmdBindVertexBuffers,
            .CmdBindDescriptorSets = MockVk.cmdBindDescriptorSets,
            .CmdDraw = MockVk.cmdDraw,
        },
        .{},
    );
    defer vk_renderer.deinit();

    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    c.begin(200, 100);
    c.setClip(.{ .x = 12, .y = 18, .w = 60, .h = 40 });
    c.fillRoundedRect(.{ .x = 12, .y = 18, .w = 60, .h = 40 }, .all(8), .rgb(0x6750a4));

    const pixels = try std.testing.allocator.alloc(u32, 200 * 100);
    defer std.testing.allocator.free(pixels);
    var target: software.Image = .{ .pixels = pixels, .width = 200, .height = 100 };
    target.clear(0xff000000);
    try vk_renderer.renderer().draw(&c, &target);
    try std.testing.expectEqual(@as(usize, 3), MockVk.draws);
    try std.testing.expectEqual(@as(i32, 12), MockVk.last_scissor.offset.x);
    try std.testing.expectEqual(@as(i32, 18), MockVk.last_scissor.offset.y);
    try std.testing.expectEqual(@as(u32, 60), MockVk.last_scissor.extent.width);
    try std.testing.expectEqual(@as(u32, 40), MockVk.last_scissor.extent.height);
}

test "VulkanRenderer.initDefault renders 2D Canvas shapes and images into software.Image" {
    var vk_renderer = VulkanRenderer.initDefault(std.testing.allocator) catch return;
    defer vk_renderer.deinit();

    const w: u32 = 100;
    const h: u32 = 80;
    const pixels = try std.testing.allocator.alloc(u32, w * h);
    defer std.testing.allocator.free(pixels);
    var img: software.Image = .{ .pixels = pixels, .width = w, .height = h };
    img.clear(0xff112233);

    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    c.begin(w, h);
    c.fillRoundedRect(.{ .x = 10, .y = 10, .w = 40, .h = 30 }, .all(4), .rgb(0xff0000));
    const tex_px = [_]u32{ 0xff00ff00, 0xff00ff00, 0xff00ff00, 0xff00ff00 };
    const pic = canvas_mod.Image.init(&tex_px, 2, 2);
    c.drawImage(&pic, .{ .x = 60, .y = 10, .w = 20, .h = 20 }, 1.0);

    try vk_renderer.renderer().draw(&c, &img);
    try std.testing.expectEqual(@as(u32, 0xff112233), img.pixels[2 * w + 2]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), img.pixels[25 * w + 30]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), img.pixels[20 * w + 70]);
}
