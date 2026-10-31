//! Direct3D 11 rendering backend for Kete's 2D `Canvas`, on Windows: the
//! canvas's batches drawn on the GPU with the shaders in
//! `shaders/canvas.hlsl` (compiled to DXBC by fxc when kete is built, so
//! nothing is compiled when it starts), its glyph atlas and images in
//! textures.
//!
//! In a window (`renderD3D11`) a frame is drawn into a texture the renderer
//! keeps, only where it changed, and then copied into the window's swap
//! chain's back buffer for the window to present: no copy through the CPU.
//! Nothing on that path waits for the GPU: vertices go into a dynamic
//! buffer mapped without waiting (`WRITE_DISCARD` for a frame's first,
//! `WRITE_NO_OVERWRITE` after), and the atlas and images are updated with
//! `UpdateSubresource`, which the driver queues. It can also draw into an
//! image on the CPU (`record`, as the other renderers do), by way of a
//! texture.
//!
//! Direct3D is loaded at run time (`winapi.zig`), so nothing is needed to
//! build it but the shaders.
//!
//!     var dx = try gfx.D3D11Renderer.initDefault(gpa);
//!     defer dx.deinit();
//!     try dx.renderer().draw(&canvas, &img);

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("winapi.zig");
const canvas_mod = @import("canvas.zig");
const renderer_mod = @import("renderer.zig");
const shaders = @import("shaders.zig");
const software = @import("software.zig");
const atlas_mod = @import("atlas.zig");

const Canvas = canvas_mod.Canvas;
const Viewport = renderer_mod.Viewport;
const Segment = renderer_mod.Segment;
const D3D11Target = renderer_mod.D3D11Target;
const GpuArea = renderer_mod.GpuArea;
const cc = w32.cc;
const HRESULT = w32.HRESULT;
const Obj = *anyopaque;

// --- Direct3D 11's types -------------------------------------------------------------

pub const format_bgra8: u32 = 87; // DXGI_FORMAT_B8G8R8A8_UNORM
pub const format_r8: u32 = 61; // DXGI_FORMAT_R8_UNORM
pub const format_d24s8: u32 = 45; // DXGI_FORMAT_D24_UNORM_S8_UINT
pub const format_r32: u32 = 41;
pub const format_rg32: u32 = 16;
pub const format_rgb32: u32 = 6;
pub const format_rgba32: u32 = 2;
pub const format_r16_uint: u32 = 57; // DXGI_FORMAT_R16_UINT

const usage_default: u32 = 0;
const usage_immutable: u32 = 1;
const usage_dynamic: u32 = 2;
const usage_staging: u32 = 3;
pub const bind_vertex: u32 = 0x1;
pub const bind_index: u32 = 0x2;
pub const bind_constant: u32 = 0x4;
pub const bind_shader_resource: u32 = 0x8;
pub const bind_render_target: u32 = 0x20;
pub const bind_depth_stencil: u32 = 0x40;
const cpu_write: u32 = 0x10000;
const cpu_read: u32 = 0x20000;
const map_read: u32 = 1;
const map_write_discard: u32 = 4;
const map_write_no_overwrite: u32 = 5;
const topology_triangles: u32 = 4;

pub const BufferDesc = extern struct {
    ByteWidth: u32,
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
    StructureByteStride: u32 = 0,
};

pub const Texture2DDesc = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32 = 1,
    ArraySize: u32 = 1,
    Format: u32,
    SampleCount: u32 = 1,
    SampleQuality: u32 = 0,
    Usage: u32 = usage_default,
    BindFlags: u32 = 0,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
};

pub const SubresourceData = extern struct {
    pSysMem: *const anyopaque,
    SysMemPitch: u32 = 0,
    SysMemSlicePitch: u32 = 0,
};

pub const MappedSubresource = extern struct {
    pData: ?*anyopaque = null,
    RowPitch: u32 = 0,
    DepthPitch: u32 = 0,
};

pub const InputElementDesc = extern struct {
    SemanticName: [*:0]const u8,
    SemanticIndex: u32 = 0,
    Format: u32,
    InputSlot: u32 = 0,
    AlignedByteOffset: u32,
    InputSlotClass: u32 = 0,
    InstanceDataStepRate: u32 = 0,
};

const RenderTargetBlendDesc = extern struct {
    BlendEnable: w32.BOOL = w32.FALSE,
    SrcBlend: u32 = 2,
    DestBlend: u32 = 1,
    BlendOp: u32 = 1,
    SrcBlendAlpha: u32 = 2,
    DestBlendAlpha: u32 = 1,
    BlendOpAlpha: u32 = 1,
    RenderTargetWriteMask: u8 = 0xf,
};

const BlendDesc = extern struct {
    AlphaToCoverageEnable: w32.BOOL = w32.FALSE,
    IndependentBlendEnable: w32.BOOL = w32.FALSE,
    RenderTarget: [8]RenderTargetBlendDesc = @splat(.{}),
};

pub const RasterizerDesc = extern struct {
    FillMode: u32 = 3, // SOLID
    CullMode: u32 = 1, // NONE
    FrontCounterClockwise: w32.BOOL = w32.FALSE,
    DepthBias: i32 = 0,
    DepthBiasClamp: f32 = 0,
    SlopeScaledDepthBias: f32 = 0,
    DepthClipEnable: w32.BOOL = w32.TRUE,
    ScissorEnable: w32.BOOL = w32.FALSE,
    MultisampleEnable: w32.BOOL = w32.FALSE,
    AntialiasedLineEnable: w32.BOOL = w32.FALSE,
};

const SamplerDesc = extern struct {
    Filter: u32,
    AddressU: u32 = 3, // CLAMP
    AddressV: u32 = 3,
    AddressW: u32 = 3,
    MipLODBias: f32 = 0,
    MaxAnisotropy: u32 = 1,
    ComparisonFunc: u32 = 1, // NEVER
    BorderColor: [4]f32 = .{ 0, 0, 0, 0 },
    MinLOD: f32 = 0,
    MaxLOD: f32 = std.math.floatMax(f32),
};

pub const DepthStencilDesc = extern struct {
    DepthEnable: w32.BOOL,
    DepthWriteMask: u32, // 0 ZERO, 1 ALL
    DepthFunc: u32, // 2 LESS, 8 ALWAYS
    StencilEnable: w32.BOOL = w32.FALSE,
    StencilReadMask: u8 = 0xff,
    StencilWriteMask: u8 = 0xff,
    FrontFace: [4]u32 = .{ 1, 1, 1, 8 },
    BackFace: [4]u32 = .{ 1, 1, 1, 8 },
};

pub const D3DViewport = extern struct {
    TopLeftX: f32,
    TopLeftY: f32,
    Width: f32,
    Height: f32,
    MinDepth: f32 = 0,
    MaxDepth: f32 = 1,
};

pub const Box = extern struct {
    left: u32,
    top: u32,
    front: u32 = 0,
    right: u32,
    bottom: u32,
    back: u32 = 1,
};

fn boxOf(v: Viewport) Box {
    return .{ .left = @intCast(v.x), .top = @intCast(v.y), .right = @intCast(v.x + @as(i32, @intCast(v.width))), .bottom = @intCast(v.y + @as(i32, @intCast(v.height))) };
}

/// ID3D11Device's methods (by their slots in its vtable).
pub const Device = struct {
    pub const CreateBuffer = fn (Obj, *const BufferDesc, ?*const SubresourceData, *?Obj) callconv(cc) HRESULT;
    pub const CreateTexture2D = fn (Obj, *const Texture2DDesc, ?*const SubresourceData, *?Obj) callconv(cc) HRESULT;
    pub const CreateView = fn (Obj, Obj, ?*const anyopaque, *?Obj) callconv(cc) HRESULT;
    pub const CreateInputLayout = fn (Obj, [*]const InputElementDesc, u32, [*]const u8, usize, *?Obj) callconv(cc) HRESULT;
    pub const CreateShader = fn (Obj, [*]const u8, usize, ?Obj, *?Obj) callconv(cc) HRESULT;
    pub const CreateState = fn (Obj, *const anyopaque, *?Obj) callconv(cc) HRESULT;
    pub const CheckMultisampleQualityLevels = fn (Obj, u32, u32, *u32) callconv(cc) HRESULT;

    pub fn createBuffer(d: Obj, desc: BufferDesc, init: ?*const SubresourceData) !Obj {
        var out: ?Obj = null;
        if (!w32.succeeded(w32.call(d, 3, CreateBuffer, .{ &desc, init, &out }))) return error.D3D11BufferFailed;
        return out orelse error.D3D11BufferFailed;
    }
    pub fn createTexture2D(d: Obj, desc: Texture2DDesc, init: ?*const SubresourceData) !Obj {
        var out: ?Obj = null;
        if (!w32.succeeded(w32.call(d, 5, CreateTexture2D, .{ &desc, init, &out }))) return error.D3D11TextureFailed;
        return out orelse error.D3D11TextureFailed;
    }
    pub fn createShaderResourceView(d: Obj, res: Obj) !Obj {
        var out: ?Obj = null;
        if (!w32.succeeded(w32.call(d, 7, CreateView, .{ res, null, &out }))) return error.D3D11ViewFailed;
        return out orelse error.D3D11ViewFailed;
    }
    pub fn createRenderTargetView(d: Obj, res: Obj) !Obj {
        var out: ?Obj = null;
        if (!w32.succeeded(w32.call(d, 9, CreateView, .{ res, null, &out }))) return error.D3D11ViewFailed;
        return out orelse error.D3D11ViewFailed;
    }
    pub fn createDepthStencilView(d: Obj, res: Obj) !Obj {
        var out: ?Obj = null;
        if (!w32.succeeded(w32.call(d, 10, CreateView, .{ res, null, &out }))) return error.D3D11ViewFailed;
        return out orelse error.D3D11ViewFailed;
    }
    pub fn createInputLayout(d: Obj, elements: []const InputElementDesc, vs_code: []const u8) !Obj {
        var out: ?Obj = null;
        if (!w32.succeeded(w32.call(d, 11, CreateInputLayout, .{ elements.ptr, @as(u32, @intCast(elements.len)), vs_code.ptr, vs_code.len, &out }))) return error.D3D11InputLayoutFailed;
        return out orelse error.D3D11InputLayoutFailed;
    }
    pub fn createVertexShader(d: Obj, code: []const u8) !Obj {
        var out: ?Obj = null;
        if (!w32.succeeded(w32.call(d, 12, CreateShader, .{ code.ptr, code.len, null, &out }))) return error.D3D11ShaderFailed;
        return out orelse error.D3D11ShaderFailed;
    }
    pub fn createPixelShader(d: Obj, code: []const u8) !Obj {
        var out: ?Obj = null;
        if (!w32.succeeded(w32.call(d, 15, CreateShader, .{ code.ptr, code.len, null, &out }))) return error.D3D11ShaderFailed;
        return out orelse error.D3D11ShaderFailed;
    }
    fn createState(d: Obj, comptime slot: usize, desc: *const anyopaque) !Obj {
        var out: ?Obj = null;
        if (!w32.succeeded(w32.call(d, slot, CreateState, .{ desc, &out }))) return error.D3D11StateFailed;
        return out orelse error.D3D11StateFailed;
    }
    pub fn createBlendState(d: Obj, desc: *const BlendDesc) !Obj {
        return createState(d, 20, desc);
    }
    pub fn createDepthStencilState(d: Obj, desc: *const DepthStencilDesc) !Obj {
        return createState(d, 21, desc);
    }
    pub fn createRasterizerState(d: Obj, desc: *const RasterizerDesc) !Obj {
        return createState(d, 22, desc);
    }
    pub fn createSamplerState(d: Obj, desc: *const SamplerDesc) !Obj {
        return createState(d, 23, desc);
    }
    /// Whether textures of `format` can be drawn with `count` samples.
    pub fn supportsSamples(d: Obj, format: u32, count: u32) bool {
        var levels: u32 = 0;
        if (!w32.succeeded(w32.call(d, 30, CheckMultisampleQualityLevels, .{ format, count, &levels }))) return false;
        return levels > 0;
    }
};

/// ID3D11DeviceContext's methods (by their slots in its vtable).
pub const Context = struct {
    const SetBuffers = fn (Obj, u32, u32, [*]const ?Obj) callconv(cc) void;
    const SetShader = fn (Obj, ?Obj, ?*const anyopaque, u32) callconv(cc) void;
    const Draw = fn (Obj, u32, u32) callconv(cc) void;
    const DrawIndexed = fn (Obj, u32, u32, i32) callconv(cc) void;
    const Map = fn (Obj, Obj, u32, u32, u32, *MappedSubresource) callconv(cc) HRESULT;
    const Unmap = fn (Obj, Obj, u32) callconv(cc) void;
    const SetOne = fn (Obj, ?Obj) callconv(cc) void;
    const SetVertexBuffers = fn (Obj, u32, u32, [*]const ?Obj, [*]const u32, [*]const u32) callconv(cc) void;
    const SetIndexBuffer = fn (Obj, ?Obj, u32, u32) callconv(cc) void;
    const SetTopology = fn (Obj, u32) callconv(cc) void;
    const SetRenderTargets = fn (Obj, u32, [*]const ?Obj, ?Obj) callconv(cc) void;
    const SetBlendState = fn (Obj, ?Obj, ?*const [4]f32, u32) callconv(cc) void;
    const SetDepthStencilState = fn (Obj, ?Obj, u32) callconv(cc) void;
    const SetViewports = fn (Obj, u32, [*]const D3DViewport) callconv(cc) void;
    const SetScissorRects = fn (Obj, u32, [*]const w32.RECT) callconv(cc) void;
    const CopySubresourceRegion = fn (Obj, Obj, u32, u32, u32, u32, Obj, u32, ?*const Box) callconv(cc) void;
    const CopyResource = fn (Obj, Obj, Obj) callconv(cc) void;
    const UpdateSubresource = fn (Obj, Obj, u32, ?*const Box, *const anyopaque, u32, u32) callconv(cc) void;
    const ClearRenderTargetView = fn (Obj, Obj, *const [4]f32) callconv(cc) void;
    const ClearDepthStencilView = fn (Obj, Obj, u32, f32, u8) callconv(cc) void;
    const ResolveSubresource = fn (Obj, Obj, u32, Obj, u32, u32) callconv(cc) void;
    const NoArgs = fn (Obj) callconv(cc) void;

    pub fn vsSetConstantBuffer(c: Obj, buf: ?Obj) void {
        w32.call(c, 7, SetBuffers, .{ 0, 1, &[1]?Obj{buf} });
    }
    pub fn psSetShaderResource(c: Obj, view: ?Obj) void {
        w32.call(c, 8, SetBuffers, .{ 0, 1, &[1]?Obj{view} });
    }
    pub fn psSetShader(c: Obj, s: ?Obj) void {
        w32.call(c, 9, SetShader, .{ s, null, 0 });
    }
    pub fn psSetSampler(c: Obj, s: ?Obj) void {
        w32.call(c, 10, SetBuffers, .{ 0, 1, &[1]?Obj{s} });
    }
    pub fn vsSetShader(c: Obj, s: ?Obj) void {
        w32.call(c, 11, SetShader, .{ s, null, 0 });
    }
    pub fn drawIndexed(c: Obj, count: u32) void {
        w32.call(c, 12, DrawIndexed, .{ count, 0, 0 });
    }
    pub fn draw(c: Obj, count: u32, start: u32) void {
        w32.call(c, 13, Draw, .{ count, start });
    }
    pub fn map(c: Obj, res: Obj, kind: u32) !MappedSubresource {
        var m: MappedSubresource = .{};
        if (!w32.succeeded(w32.call(c, 14, Map, .{ res, 0, kind, 0, &m }))) return error.D3D11MapFailed;
        if (m.pData == null) return error.D3D11MapFailed;
        return m;
    }
    pub fn unmap(c: Obj, res: Obj) void {
        w32.call(c, 15, Unmap, .{ res, 0 });
    }
    pub fn psSetConstantBuffer(c: Obj, buf: ?Obj) void {
        w32.call(c, 16, SetBuffers, .{ 0, 1, &[1]?Obj{buf} });
    }
    pub fn iaSetInputLayout(c: Obj, l: ?Obj) void {
        w32.call(c, 17, SetOne, .{l});
    }
    pub fn iaSetVertexBuffer(c: Obj, buf: ?Obj, stride: u32, offset: u32) void {
        w32.call(c, 18, SetVertexBuffers, .{ 0, 1, &[1]?Obj{buf}, &[1]u32{stride}, &[1]u32{offset} });
    }
    pub fn iaSetIndexBuffer16(c: Obj, buf: ?Obj) void {
        w32.call(c, 19, SetIndexBuffer, .{ buf, format_r16_uint, 0 });
    }
    pub fn iaSetTriangles(c: Obj) void {
        w32.call(c, 24, SetTopology, .{topology_triangles});
    }
    pub fn omSetRenderTarget(c: Obj, rtv: ?Obj, dsv: ?Obj) void {
        w32.call(c, 33, SetRenderTargets, .{ 1, &[1]?Obj{rtv}, dsv });
    }
    pub fn omSetBlendState(c: Obj, s: ?Obj) void {
        w32.call(c, 35, SetBlendState, .{ s, null, 0xffffffff });
    }
    pub fn omSetDepthStencilState(c: Obj, s: ?Obj) void {
        w32.call(c, 36, SetDepthStencilState, .{ s, 0 });
    }
    pub fn rsSetState(c: Obj, s: ?Obj) void {
        w32.call(c, 43, SetOne, .{s});
    }
    pub fn rsSetViewport(c: Obj, x: f32, y: f32, width: f32, height: f32) void {
        w32.call(c, 44, SetViewports, .{ 1, &[1]D3DViewport{.{ .TopLeftX = x, .TopLeftY = y, .Width = width, .Height = height }} });
    }
    pub fn rsSetScissor(c: Obj, v: Viewport) void {
        const r: w32.RECT = .{ .left = v.x, .top = v.y, .right = v.x + @as(i32, @intCast(v.width)), .bottom = v.y + @as(i32, @intCast(v.height)) };
        w32.call(c, 45, SetScissorRects, .{ 1, &[1]w32.RECT{r} });
    }
    pub fn copySubresourceRegion(c: Obj, dst: Obj, x: u32, y: u32, src: Obj, box: *const Box) void {
        w32.call(c, 46, CopySubresourceRegion, .{ dst, 0, x, y, 0, src, 0, box });
    }
    pub fn copyResource(c: Obj, dst: Obj, src: Obj) void {
        w32.call(c, 47, CopyResource, .{ dst, src });
    }
    pub fn updateSubresource(c: Obj, dst: Obj, box: ?*const Box, src: *const anyopaque, row_pitch: u32) void {
        w32.call(c, 48, UpdateSubresource, .{ dst, 0, box, src, row_pitch, 0 });
    }
    pub fn clearRenderTargetView(c: Obj, rtv: Obj, color: [4]f32) void {
        w32.call(c, 50, ClearRenderTargetView, .{ rtv, &color });
    }
    pub fn clearDepth(c: Obj, dsv: Obj) void {
        w32.call(c, 53, ClearDepthStencilView, .{ dsv, 1, 1.0, 0 }); // D3D11_CLEAR_DEPTH
    }
    pub fn resolve(c: Obj, dst: Obj, src: Obj, format: u32) void {
        w32.call(c, 57, ResolveSubresource, .{ dst, 0, src, 0, format });
    }
    pub fn clearState(c: Obj) void {
        w32.call(c, 110, NoArgs, .{});
    }
    pub fn flush(c: Obj) void {
        w32.call(c, 111, NoArgs, .{});
    }
};

const CreateDeviceFn = fn (?Obj, u32, ?Obj, u32, ?[*]const u32, u32, u32, *?Obj, ?*u32, *?Obj) callconv(cc) HRESULT;
const driver_hardware: u32 = 1;
const driver_warp: u32 = 5;
const create_bgra_support: u32 = 0x20;
const sdk_version: u32 = 7;
const feature_levels = [_]u32{ 0xb100, 0xb000 }; // 11_1, 11_0

/// A device and its immediate context: on the system's GPU, or (`warp`) on
/// WARP, Direct3D's own on the CPU (for tests).
pub fn createDevice(warp: bool) !struct { device: Obj, context: Obj } {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const create = w32.proc(*const CreateDeviceFn, "d3d11.dll", "D3D11CreateDevice") orelse return error.NoD3D11;
    var device: ?Obj = null;
    var context: ?Obj = null;
    var hr = create(null, if (warp) driver_warp else driver_hardware, null, create_bgra_support, &feature_levels, feature_levels.len, sdk_version, &device, null, &context);
    // Without 11_1 (Windows 7's runtime), 11_0 alone.
    if (!w32.succeeded(hr)) hr = create(null, if (warp) driver_warp else driver_hardware, null, create_bgra_support, feature_levels[1..].ptr, 1, sdk_version, &device, null, &context);
    if (!w32.succeeded(hr)) return error.NoD3D11Device;
    return .{ .device = device orelse return error.NoD3D11Device, .context = context orelse return error.NoD3D11Device };
}

/// The GPU (and its context) of a `D3D11Renderer`, to draw scenes on.
pub const SharedDevice = struct {
    device: Obj,
    context: Obj,
    /// The adapter's LUID, if DXGI says: for a device of the app's on the
    /// same GPU.
    luid: ?Luid = null,
};

/// An adapter's locally unique id (`DXGI_ADAPTER_DESC.AdapterLuid`): two
/// devices are on the same GPU if their adapters' are the same.
pub const Luid = extern struct {
    low: u32,
    high: i32,
};

/// `DXGI_ADAPTER_DESC`, as `IDXGIAdapter::GetDesc` (slot 8) gives it.
const AdapterDesc = extern struct {
    Description: [128]u16,
    VendorId: u32,
    DeviceId: u32,
    SubSysId: u32,
    Revision: u32,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: Luid,
};
const GetDesc = fn (Obj, *AdapterDesc) callconv(cc) HRESULT;

/// The LUID of the adapter `device` is on, or null if DXGI cannot say.
fn adapterLuid(device: Obj) ?Luid {
    const dxgi_device = w32.query(device, &iid_dxgi_device) orelse return null;
    defer w32.release(dxgi_device);
    var adapter: ?Obj = null;
    if (!w32.succeeded(w32.call(dxgi_device, 7, GetAdapter, .{&adapter}))) return null;
    defer w32.release(adapter);
    var desc: AdapterDesc = undefined;
    if (!w32.succeeded(w32.call(adapter.?, 8, GetDesc, .{&desc}))) return null;
    return desc.AdapterLuid;
}

/// A frame the Direct3D 11 renderer is drawing into a window, given to a 3D
/// scene's `GpuDraw.direct` (with `.d3d11`) to draw into on the GPU.
pub const DirectFrame = struct {
    device: Obj,
    context: Obj,
    /// The frame's texture (BGRA8), `width` by `height`.
    texture: Obj,
    width: u32,
    height: u32,
};

// --- DXGI: a window's swap chain ------------------------------------------------------

const iid_dxgi_device = w32.GUID.parse("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
const iid_dxgi_factory2 = w32.GUID.parse("50c83a1c-e072-4c48-87b0-3630fa36a6d0");
const iid_swap_chain2 = w32.GUID.parse("a8be2ac4-199f-4946-b331-79599fb98de7");
const iid_texture2d = w32.GUID.parse("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
const iid_device_context4 = w32.GUID.parse("917600da-f58c-4c33-98d8-3e15b390fa24");

const SwapChainDesc1 = extern struct {
    Width: u32,
    Height: u32,
    Format: u32 = format_bgra8,
    Stereo: w32.BOOL = w32.FALSE,
    SampleCount: u32 = 1,
    SampleQuality: u32 = 0,
    BufferUsage: u32 = 0x20, // DXGI_USAGE_RENDER_TARGET_OUTPUT
    BufferCount: u32 = 2,
    Scaling: u32 = 1, // DXGI_SCALING_NONE
    SwapEffect: u32 = 3, // DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL
    AlphaMode: u32 = 3, // DXGI_ALPHA_MODE_IGNORE
    Flags: u32 = swap_flags,
};

const PresentParameters = extern struct {
    DirtyRectsCount: u32,
    pDirtyRects: ?[*]const w32.RECT,
    pScrollRect: ?*const w32.RECT = null,
    pScrollOffset: ?*const w32.POINT = null,
};

/// DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT.
const swap_flags: u32 = 0x40;
const dxgi_status_occluded: HRESULT = 0x087a0001;
const present_test: u32 = 0x1;
const mwa_no_alt_enter: u32 = 0x2;

const GetParent = fn (Obj, *const w32.GUID, *?Obj) callconv(cc) HRESULT;
const GetAdapter = fn (Obj, *?Obj) callconv(cc) HRESULT;
const CreateSwapChainForHwnd = fn (Obj, Obj, w32.HWND, *const SwapChainDesc1, ?*const anyopaque, ?Obj, *?Obj) callconv(cc) HRESULT;
const MakeWindowAssociation = fn (Obj, w32.HWND, u32) callconv(cc) HRESULT;
const Present = fn (Obj, u32, u32) callconv(cc) HRESULT;
const Present1 = fn (Obj, u32, u32, *const PresentParameters) callconv(cc) HRESULT;
const GetBuffer = fn (Obj, u32, *const w32.GUID, *?Obj) callconv(cc) HRESULT;
const ResizeBuffers = fn (Obj, u32, u32, u32, u32, u32) callconv(cc) HRESULT;
const SetMaximumFrameLatency = fn (Obj, u32) callconv(cc) HRESULT;
const GetFrameLatencyWaitableObject = fn (Obj) callconv(cc) ?w32.HANDLE;

/// A window's flip-model swap chain: two BGRA8 buffers, never stretched
/// (`DXGI_SCALING_NONE`), with a frame-latency waitable object and a latency
/// of one. The object (`waitable`) is signalled when a buffer is free: a
/// frame drawn then is presented without `Present` blocking, and shown at
/// the next refresh, so a window that waits on it (with its messages)
/// draws each frame as late as it can, with its input read just before.
pub const SwapChain = struct {
    swap: Obj,
    waitable: w32.HANDLE,
    width: u32,
    height: u32,
    device: Obj,
    /// Whether a frame has been presented at this size (DXGI requires the
    /// first present after creation or resize to present the whole buffer,
    /// with `DirtyRectsCount = 0`).
    presented: bool = false,

    pub const Shown = enum { shown, occluded, failed };

    pub fn create(device: Obj, hwnd: w32.HWND, width: u32, height: u32) !SwapChain {
        const dxgi_device = w32.query(device, &iid_dxgi_device) orelse return error.NoDxgi;
        defer w32.release(dxgi_device);
        var adapter: ?Obj = null;
        if (!w32.succeeded(w32.call(dxgi_device, 7, GetAdapter, .{&adapter}))) return error.NoDxgi;
        defer w32.release(adapter);
        var factory: ?Obj = null;
        if (!w32.succeeded(w32.call(adapter.?, 6, GetParent, .{ &iid_dxgi_factory2, &factory }))) return error.NoDxgiFactory2;
        defer w32.release(factory);
        const desc: SwapChainDesc1 = .{ .Width = width, .Height = height };
        var swap1: ?Obj = null;
        if (!w32.succeeded(w32.call(factory.?, 15, CreateSwapChainForHwnd, .{ device, hwnd, &desc, null, null, &swap1 }))) return error.SwapChainFailed;
        defer w32.release(swap1);
        // Alt+Enter is the app's (its full screen is borderless).
        _ = w32.call(factory.?, 8, MakeWindowAssociation, .{ hwnd, mwa_no_alt_enter });
        const swap = w32.query(swap1.?, &iid_swap_chain2) orelse return error.SwapChainFailed;
        errdefer w32.release(swap);
        _ = w32.call(swap, 31, SetMaximumFrameLatency, .{@as(u32, 1)});
        const waitable = w32.call(swap, 33, GetFrameLatencyWaitableObject, .{}) orelse return error.SwapChainFailed;
        w32.addRef(device);
        return .{ .swap = swap, .waitable = waitable, .width = width, .height = height, .device = device };
    }

    pub fn deinit(sc: *SwapChain) void {
        _ = w32.CloseHandle(sc.waitable);
        w32.release(sc.swap);
        w32.release(sc.device);
    }

    /// Makes its buffers `width` by `height` (none may be held).
    pub fn resize(sc: *SwapChain, width: u32, height: u32) !void {
        if (sc.width == width and sc.height == height) return;
        if (!w32.succeeded(w32.call(sc.swap, 13, ResizeBuffers, .{ @as(u32, 0), width, height, @as(u32, 0), swap_flags }))) return error.SwapChainFailed;
        sc.width = width;
        sc.height = height;
        sc.presented = false;
    }

    /// The buffer to draw the next frame in (an `ID3D11Texture2D`, released
    /// once presented).
    pub fn backBuffer(sc: *const SwapChain) !Obj {
        var tex: ?Obj = null;
        if (!w32.succeeded(w32.call(sc.swap, 9, GetBuffer, .{ @as(u32, 0), &iid_texture2d, &tex }))) return error.SwapChainFailed;
        return tex orelse error.SwapChainFailed;
    }

    /// Presents the frame drawn, at the next refresh, saying what changed
    /// (`dirty`, in pixels; null: all of it) so that DWM composes only that.
    pub fn present(sc: *SwapChain, dirty: ?[]const Viewport) Shown {
        var rects: [16]w32.RECT = undefined;
        var n: u32 = 0;
        if (sc.presented) if (dirty) |list| for (list) |d| {
            if (n == rects.len) {
                n = 0;
                break;
            }
            const v = d.intersect(.{ .width = sc.width, .height = sc.height }) orelse continue;
            if (v.x == 0 and v.y == 0 and v.width == sc.width and v.height == sc.height) {
                n = 0;
                break;
            }
            rects[n] = .{ .left = v.x, .top = v.y, .right = v.x + @as(i32, @intCast(v.width)), .bottom = v.y + @as(i32, @intCast(v.height)) };
            n += 1;
        };
        const params: PresentParameters = .{ .DirtyRectsCount = n, .pDirtyRects = if (n == 0) null else &rects };
        const hr = w32.call(sc.swap, 22, Present1, .{ @as(u32, 1), @as(u32, 0), &params });
        if (hr == dxgi_status_occluded) return .occluded;
        if (!w32.succeeded(hr)) return .failed;
        sc.presented = true;
        return .shown;
    }

    /// Whether the window is still covered or out of sight (frames would
    /// not be seen), asked without presenting.
    pub fn occluded(sc: *const SwapChain) bool {
        return w32.call(sc.swap, 8, Present, .{ @as(u32, 0), present_test }) == dxgi_status_occluded;
    }
};

pub const D3D11Renderer = struct {
    gpa: std.mem.Allocator,
    device: ?Obj,
    context: Obj,
    /// The shaders (vertex shaders and their input layouts for the shape,
    /// solid and text layouts; pixel shaders for shape, solid, text and
    /// image), and the states drawn with.
    vs: [3]?Obj = @splat(null),
    layouts: [3]?Obj = @splat(null),
    ps: [4]?Obj = @splat(null),
    blend: ?Obj = null,
    raster: ?Obj = null,
    nearest: ?Obj = null,
    linear: ?Obj = null,
    /// The frame's vertices, and where the next go; the first written of a
    /// frame discards what was there (the GPU keeps what it still draws).
    vbuf: ?Obj = null,
    vcap: usize = 0,
    vcursor: usize = 0,
    vdiscard: bool = true,
    atlas_tex: ?Obj = null,
    atlas_srv: ?Obj = null,
    atlas: ?*atlas_mod.Atlas = null,
    atlas_stale: ?atlas_mod.Rect = null,
    images: std.AutoHashMapUnmanaged(u64, ImageTex) = .empty,
    image_use: renderer_mod.ImageUse = .{},
    /// The window's frame (kept from one to the next, so only what changed
    /// is drawn), the texture `record` draws in for the CPU, and what
    /// either is read back to the CPU through.
    /// The windows' frames (each kept from one to the next, so only what
    /// changed is drawn), by the window each is shown in.
    screens: [renderer_mod.max_screens]Screen = @splat(.{}),
    screens_used: u64 = 0,
    offscreen: Frame = .{},
    staging: ?Obj = null,
    staging_size: [2]u32 = .{ 0, 0 },
    /// A frame's pixels on the CPU, for GPU draws of widgets drawn there.
    scratch: std.ArrayList(u32) = .empty,

    const ImageTex = struct { tex: Obj, srv: Obj };

    const Frame = struct {
        tex: ?Obj = null,
        rtv: ?Obj = null,
        width: u32 = 0,
        height: u32 = 0,
    };

    /// A window's frame, and when it was last drawn (`screens_used`).
    const Screen = struct {
        key: ?*anyopaque = null,
        frame: Frame = .{},
        used: u64 = 0,
    };

    const Layout = enum(u2) { shape, solid, text };
    const Pixel = enum(u2) { shape, solid, text, image };

    pub const backend: renderer_mod.RenderBackend = .d3d11;

    /// The system's GPU; an error if there is none (or this is not
    /// Windows, or kete was built without its shaders).
    pub fn initDefault(gpa: std.mem.Allocator) !D3D11Renderer {
        return init(gpa, false);
    }

    /// On WARP, Direct3D's own on the CPU (for tests).
    pub fn initWarp(gpa: std.mem.Allocator) !D3D11Renderer {
        return init(gpa, true);
    }

    fn init(gpa: std.mem.Allocator, warp: bool) !D3D11Renderer {
        if (builtin.os.tag != .windows) return error.Unsupported;
        const code = shaders.dxbc;
        inline for (.{ code.shape_vs, code.solid_vs, code.text_vs, code.shape_ps, code.solid_ps, code.text_ps, code.image_ps }) |c| {
            if (c.len == 0) return error.NoShaders;
        }
        const dev = try createDevice(warp);
        var r: D3D11Renderer = .{ .gpa = gpa, .device = dev.device, .context = dev.context };
        errdefer r.deinit();
        const d = dev.device;

        const pos: InputElementDesc = .{ .SemanticName = "POSITION", .Format = format_rg32, .AlignedByteOffset = 0 };
        r.vs[0] = try Device.createVertexShader(d, code.shape_vs);
        r.layouts[0] = try Device.createInputLayout(d, &.{
            pos,
            .{ .SemanticName = "TEXCOORD", .SemanticIndex = 0, .Format = format_rgba32, .AlignedByteOffset = 8 },
            .{ .SemanticName = "TEXCOORD", .SemanticIndex = 1, .Format = format_rg32, .AlignedByteOffset = 24 },
            .{ .SemanticName = "COLOR", .Format = format_rgba32, .AlignedByteOffset = 32 },
        }, code.shape_vs);
        r.vs[1] = try Device.createVertexShader(d, code.solid_vs);
        r.layouts[1] = try Device.createInputLayout(d, &.{
            pos,
            .{ .SemanticName = "COLOR", .Format = format_rgba32, .AlignedByteOffset = 8 },
        }, code.solid_vs);
        r.vs[2] = try Device.createVertexShader(d, code.text_vs);
        r.layouts[2] = try Device.createInputLayout(d, &.{
            pos,
            .{ .SemanticName = "TEXCOORD", .Format = format_rg32, .AlignedByteOffset = 8 },
            .{ .SemanticName = "COLOR", .Format = format_rgba32, .AlignedByteOffset = 16 },
        }, code.text_vs);
        r.ps = .{
            try Device.createPixelShader(d, code.shape_ps),
            try Device.createPixelShader(d, code.solid_ps),
            try Device.createPixelShader(d, code.text_ps),
            try Device.createPixelShader(d, code.image_ps),
        };

        // Source over, as the other renderers: colours not premultiplied,
        // the alpha kept for what is drawn over.
        var blend: BlendDesc = .{};
        blend.RenderTarget[0] = .{ .BlendEnable = w32.TRUE, .SrcBlend = 5, .DestBlend = 6, .SrcBlendAlpha = 2, .DestBlendAlpha = 6 };
        r.blend = try Device.createBlendState(d, &blend);
        r.raster = try Device.createRasterizerState(d, &.{ .ScissorEnable = w32.TRUE });
        r.nearest = try Device.createSamplerState(d, &.{ .Filter = 0 }); // MIN_MAG_MIP_POINT
        r.linear = try Device.createSamplerState(d, &.{ .Filter = 0x15 }); // MIN_MAG_MIP_LINEAR
        return r;
    }

    pub fn deinit(r: *D3D11Renderer) void {
        if (r.device == null) return;
        var it = r.images.valueIterator();
        while (it.next()) |img| {
            w32.release(img.srv);
            w32.release(img.tex);
        }
        r.images.deinit(r.gpa);
        r.image_use.deinit(r.gpa);
        r.scratch.deinit(r.gpa);
        for (r.vs ++ r.layouts) |o| w32.release(o);
        for (r.ps) |o| w32.release(o);
        for (&r.screens) |*sc| for ([_]?Obj{ sc.frame.rtv, sc.frame.tex }) |o| w32.release(o);
        for ([_]?Obj{ r.blend, r.raster, r.nearest, r.linear, r.vbuf, r.atlas_srv, r.atlas_tex, r.offscreen.rtv, r.offscreen.tex, r.staging }) |o| w32.release(o);
        w32.release(r.context);
        w32.release(r.device);
        r.device = null;
    }

    pub fn renderer(r: *D3D11Renderer) renderer_mod.Renderer {
        return .of(r);
    }

    /// Its `ID3D11Device`, for a window's swap chain.
    pub fn d3d11Device(r: *D3D11Renderer) *anyopaque {
        return r.device.?;
    }

    /// The renderer's GPU, for 3D scenes drawn straight into its frames
    /// (`OffscreenContext.initShared`), and for windows to make their swap
    /// chains on.
    pub fn sharedDevice(r: *const D3D11Renderer) SharedDevice {
        return .{ .device = r.device.?, .context = r.context, .luid = adapterLuid(r.device.?) };
    }

    // --- Textures ---------------------------------------------------------------------

    /// The frame kept for the window `key` (the longest unused window's
    /// let go, for one new).
    fn screenOf(r: *D3D11Renderer, key: *anyopaque) *Frame {
        r.screens_used += 1;
        var pick = &r.screens[0];
        for (&r.screens) |*sc| {
            if (sc.key == key) {
                sc.used = r.screens_used;
                return &sc.frame;
            }
            if (sc.used < pick.used) pick = sc;
        }
        w32.release(pick.frame.rtv);
        w32.release(pick.frame.tex);
        pick.* = .{ .key = key, .used = r.screens_used };
        return &pick.frame;
    }

    /// Makes `frame` `width` by `height`; true if it is new (and so has
    /// nothing in it yet).
    fn ensureFrame(r: *D3D11Renderer, frame: *Frame, width: u32, height: u32) !bool {
        if (frame.tex != null and frame.width == width and frame.height == height) return false;
        w32.release(frame.rtv);
        w32.release(frame.tex);
        frame.* = .{};
        const tex = try Device.createTexture2D(r.device.?, .{ .Width = width, .Height = height, .Format = format_bgra8, .BindFlags = bind_render_target | bind_shader_resource }, null);
        frame.* = .{ .tex = tex, .width = width, .height = height };
        frame.rtv = try Device.createRenderTargetView(r.device.?, tex);
        return true;
    }

    /// A texture to read `width` by `height` of a frame back on the CPU
    /// through.
    fn stagingFor(r: *D3D11Renderer, width: u32, height: u32) !Obj {
        if (r.staging) |s| if (r.staging_size[0] >= width and r.staging_size[1] >= height) return s;
        w32.release(r.staging);
        r.staging = null;
        const w = @max(width, r.staging_size[0]);
        const h = @max(height, r.staging_size[1]);
        r.staging = try Device.createTexture2D(r.device.?, .{ .Width = w, .Height = h, .Format = format_bgra8, .Usage = usage_staging, .CPUAccessFlags = cpu_read }, null);
        r.staging_size = .{ w, h };
        return r.staging.?;
    }

    /// Copies `region` of `img` into `frame`'s texture.
    fn upload(r: *D3D11Renderer, frame: *const Frame, img: software.Image, region: Viewport) void {
        const stride = img.rowStride();
        const at = @as(usize, @intCast(region.y)) * stride + @as(usize, @intCast(region.x));
        const box = boxOf(region);
        Context.updateSubresource(r.context, frame.tex.?, &box, img.pixels[at..].ptr, @intCast(stride * 4));
    }

    /// Copies `region` of `frame`'s texture into `img` (waiting for the
    /// GPU to have drawn it).
    fn download(r: *D3D11Renderer, frame: *const Frame, img: software.Image, region: Viewport) !void {
        const staging = try r.stagingFor(frame.width, frame.height);
        const box = boxOf(region);
        Context.copySubresourceRegion(r.context, staging, box.left, box.top, frame.tex.?, &box);
        const m = try Context.map(r.context, staging, map_read);
        defer Context.unmap(r.context, staging);
        const base: [*]const u8 = @ptrCast(m.pData.?);
        const stride = img.rowStride();
        for (0..region.height) |row| {
            const y = @as(usize, @intCast(region.y)) + row;
            const src: [*]const u32 = @ptrCast(@alignCast(base + y * m.RowPitch + @as(usize, @intCast(region.x)) * 4));
            @memcpy(img.pixels[y * stride + @as(usize, @intCast(region.x)) ..][0..region.width], src[0..region.width]);
        }
    }

    // --- Preparing a frame ------------------------------------------------------------

    /// Makes room for the frame's vertices, and uploads the glyph atlas's
    /// new rows and new images.
    pub fn prepare(r: *D3D11Renderer, canvases: []const *const Canvas) !void {
        var bytes: usize = clear_bytes;
        for (canvases) |c| for (c.batches.items) |*b| {
            bytes += std.mem.alignForward(usize, b.floats.items.len * 4, 16);
        };
        if (bytes > r.vcap) {
            w32.release(r.vbuf);
            r.vbuf = null;
            r.vcap = 0;
            const capacity = std.mem.alignForward(usize, bytes * 2, 64 * 1024);
            r.vbuf = try Device.createBuffer(r.device.?, .{ .ByteWidth = @intCast(capacity), .Usage = usage_dynamic, .BindFlags = bind_vertex, .CPUAccessFlags = cpu_write }, null);
            r.vcap = capacity;
        }
        r.vcursor = 0;
        r.vdiscard = true;
        for (canvases) |c| if (c.atlas) |a| try r.uploadAtlas(a);
        try r.uploadImages(canvases);
    }

    fn uploadAtlas(r: *D3D11Renderer, a: *atlas_mod.Atlas) !void {
        const w = atlas_mod.width;
        const h = atlas_mod.height;
        const all: atlas_mod.Rect = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
        if (r.atlas_tex == null) {
            r.atlas_tex = try Device.createTexture2D(r.device.?, .{ .Width = w, .Height = h, .Format = format_r8, .BindFlags = bind_shader_resource }, null);
            r.atlas_srv = try Device.createShaderResourceView(r.device.?, r.atlas_tex.?);
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
        // Queued by the driver (frames on the GPU keep what they drew with).
        const box: Box = .{ .left = 0, .top = y0, .right = w, .bottom = y1 };
        Context.updateSubresource(r.context, r.atlas_tex.?, &box, a.pixels[y0 * w ..].ptr, w);
    }

    fn uploadImages(r: *D3D11Renderer, canvases: []const *const Canvas) !void {
        // Those no window draws any more go (the GPU keeps them while it uses them).
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(r.gpa);
        try r.image_use.update(r.gpa, canvases, &stale);
        for (stale.items) |id| {
            const t = (r.images.fetchRemove(id) orelse continue).value;
            w32.release(t.srv);
            w32.release(t.tex);
        }

        for (canvases) |c| for (c.batches.items) |*b| {
            const img = b.image orelse continue;
            if (r.images.contains(img.id) or img.width == 0 or img.height == 0) continue;
            // 0xAARRGGBB, little-endian: BGRA in memory, as the texture is.
            const init_data: SubresourceData = .{ .pSysMem = img.pixels.ptr, .SysMemPitch = img.width * 4 };
            const tex = try Device.createTexture2D(r.device.?, .{ .Width = img.width, .Height = img.height, .Format = format_bgra8, .Usage = usage_immutable, .BindFlags = bind_shader_resource }, &init_data);
            const srv = Device.createShaderResourceView(r.device.?, tex) catch |e| {
                w32.release(tex);
                return e;
            };
            try r.images.put(r.gpa, img.id, .{ .tex = tex, .srv = srv });
        };
    }

    // --- Drawing ----------------------------------------------------------------------

    /// Room in each frame's vertex buffer for the quads that clear.
    const clear_bytes = renderer_mod.max_uncovered * 6 * shaders.solid_floats * 4 + 16;

    /// Puts `data` in this frame's vertex buffer: its offset there.
    fn vertices(r: *D3D11Renderer, data: []const u8) !u32 {
        const buf = r.vbuf orelse return error.NotPrepared;
        if (r.vcursor + data.len > r.vcap) return error.NotPrepared;
        // Never waiting for the GPU: a frame's first discards (the GPU keeps
        // the frames it still draws), the rest are after what it uses.
        const m = try Context.map(r.context, buf, if (r.vdiscard) map_write_discard else map_write_no_overwrite);
        r.vdiscard = false;
        const base: [*]u8 = @ptrCast(m.pData.?);
        @memcpy(base[r.vcursor..][0..data.len], data);
        Context.unmap(r.context, buf);
        const offset = r.vcursor;
        r.vcursor += std.mem.alignForward(usize, data.len, 16);
        return @intCast(offset);
    }

    /// Draws into `rtv` (`width` by `height`) from now on.
    fn beginPass(r: *D3D11Renderer, rtv: Obj, width: u32, height: u32) void {
        const c = r.context;
        Context.omSetRenderTarget(c, rtv, null);
        Context.omSetDepthStencilState(c, null);
        Context.rsSetViewport(c, 0, 0, @floatFromInt(width), @floatFromInt(height));
        Context.rsSetState(c, r.raster);
        Context.iaSetTriangles(c);
    }

    fn usePipeline(r: *D3D11Renderer, layout: Layout, pixel: Pixel, blend: bool) void {
        const c = r.context;
        Context.iaSetInputLayout(c, r.layouts[@backingInt(layout)]);
        Context.vsSetShader(c, r.vs[@backingInt(layout)]);
        Context.psSetShader(c, r.ps[@backingInt(pixel)]);
        Context.omSetBlendState(c, if (blend) r.blend else null);
    }

    /// Fills `rects` (within `full`) with `color` (ARGB), as they are.
    fn encodeClear(r: *D3D11Renderer, full: Viewport, color: u32, rects: []const Viewport) !void {
        var floats: [renderer_mod.max_uncovered * 6 * shaders.solid_floats]f32 = undefined;
        const rgba: [4]f32 = .{
            @as(f32, @floatFromInt((color >> 16) & 0xff)) / 255,
            @as(f32, @floatFromInt((color >> 8) & 0xff)) / 255,
            @as(f32, @floatFromInt(color & 0xff)) / 255,
            @as(f32, @floatFromInt(color >> 24)) / 255,
        };
        const fw: f32 = @floatFromInt(full.width);
        const fh: f32 = @floatFromInt(full.height);
        const per_rect = 6 * shaders.solid_floats;
        var n: usize = 0;
        for (rects) |cr| {
            const c = full.intersect(cr) orelse continue;
            if (n == renderer_mod.max_uncovered) break;
            const x0 = @as(f32, @floatFromInt(c.x)) / fw * 2 - 1;
            const x1 = @as(f32, @floatFromInt(c.x + @as(i32, @intCast(c.width)))) / fw * 2 - 1;
            const y0 = 1 - @as(f32, @floatFromInt(c.y)) / fh * 2;
            const y1 = 1 - @as(f32, @floatFromInt(c.y + @as(i32, @intCast(c.height)))) / fh * 2;
            const corners = [6][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y0 }, .{ x1, y1 }, .{ x0, y1 } };
            for (corners, 0..) |p, k| {
                const at = n * per_rect + k * shaders.solid_floats;
                floats[at + 0] = p[0];
                floats[at + 1] = p[1];
                for (rgba, 0..) |ch, j| floats[at + 2 + j] = ch;
            }
            n += 1;
        }
        if (n == 0) return;
        const offset = try r.vertices(std.mem.sliceAsBytes(floats[0 .. n * per_rect]));
        r.usePipeline(.solid, .solid, false);
        Context.iaSetVertexBuffer(r.context, r.vbuf, shaders.solid_floats * 4, offset);
        Context.rsSetScissor(r.context, full);
        Context.draw(r.context, @intCast(n * 6), 0);
    }

    /// Draws a prepared canvas's batches (into a target `full` in size),
    /// within `damage` (all of it if null).
    fn encode(r: *D3D11Renderer, c: *const Canvas, full: Viewport, damage: ?[]const Viewport) !void {
        const ctx = r.context;
        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            if (!renderer_mod.covers(damage, renderer_mod.scissor(area))) continue;
            const clip_vp = (if (b.clip) |clip| renderer_mod.scissor(clip) else full).intersect(full) orelse continue;

            const layout: Layout, const pixel: Pixel, const blend: bool, const stride: u32 = switch (b.kind) {
                .shape => .{ .shape, .shape, true, shaders.shape_floats * 4 },
                .solid => .{ .solid, .solid, true, shaders.solid_floats * 4 },
                .@"opaque" => .{ .solid, .solid, false, shaders.solid_floats * 4 },
                .text => .{ .text, .text, true, shaders.text_floats * 4 },
                .image => .{ .text, .image, true, shaders.text_floats * 4 },
            };
            const srv: ?Obj, const smp: ?Obj = switch (b.kind) {
                .text => .{ r.atlas_srv orelse continue, r.nearest },
                .image => .{ (r.images.get((b.image orelse continue).id) orelse return error.NotPrepared).srv, r.linear },
                else => .{ null, null },
            };
            const offset = try r.vertices(data);
            r.usePipeline(layout, pixel, blend);
            Context.iaSetVertexBuffer(ctx, r.vbuf, stride, offset);
            if (srv != null) {
                Context.psSetShaderResource(ctx, srv);
                Context.psSetSampler(ctx, smp);
            }
            const count: u32 = @intCast(b.vertexCount());
            if (damage) |list| {
                for (list) |d| {
                    const sc = clip_vp.intersect(d) orelse continue;
                    Context.rsSetScissor(ctx, sc);
                    Context.draw(ctx, count, 0);
                }
            } else {
                Context.rsSetScissor(ctx, clip_vp);
                Context.draw(ctx, count, 0);
            }
        }
    }

    /// Renders a prepared 2D `Canvas` into `target: *software.Image`,
    /// keeping what is there and clipping to `damage` viewports when
    /// provided (by way of a texture: copied in, drawn on, copied back).
    pub fn record(r: *D3D11Renderer, c: *const Canvas, target: *software.Image, damage: ?[]const Viewport) !void {
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
        _ = try r.ensureFrame(&r.offscreen, target.width, target.height);
        const full: Viewport = .{ .width = target.width, .height = target.height };
        const all = [1]Viewport{full};
        const regions = damage orelse &all;
        for (regions) |reg| if (full.intersect(reg)) |sc| r.upload(&r.offscreen, target.*, sc);
        r.beginPass(r.offscreen.rtv.?, target.width, target.height);
        try r.encode(c, full, damage);
        for (regions) |reg| if (full.intersect(reg)) |sc| try r.download(&r.offscreen, target.*, sc);
    }

    /// Renders a frame into a window's swap chain's back buffer (see
    /// `Renderer.renderD3D11`): into the frame kept from the last, only
    /// within `damage` (all of it, if the frame is new), and that copied
    /// into the back buffer, for the window to present.
    pub fn renderD3D11(r: *D3D11Renderer, canvases: []const *const Canvas, segments: []const Segment, t: *const D3D11Target, clear: u32, clear_rects: []const Viewport, damage: []const Viewport) !void {
        if (t.width == 0 or t.height == 0) return;
        try r.prepare(canvases);
        const screen = r.screenOf(t.window orelse t.texture);
        const fresh = try r.ensureFrame(screen, t.width, t.height);
        const full: Viewport = .{ .width = t.width, .height = t.height };
        const all = [1]Viewport{full};
        var clear_buf: [2][renderer_mod.max_uncovered]Viewport = undefined;
        const dmg: []const Viewport = if (fresh) &all else damage;
        const clears = if (fresh) renderer_mod.uncovered(&clear_buf, &all, segments) else clear_rects;

        r.beginPass(screen.rtv.?, t.width, t.height);
        try r.encodeClear(full, clear, clears);
        var buf: [2][renderer_mod.max_uncovered]Viewport = undefined;
        for (segments, 0..) |seg, i| switch (seg) {
            .canvas => |c| {
                // Not under a GPU draw that covers it (as `Renderer.render`).
                const d = renderer_mod.uncovered(&buf, dmg, segments[i + 1 ..]);
                if (d.len == 0) continue;
                try r.encode(c, full, d);
            },
            .gpu => |g| {
                const area = full.intersect(g.area.scissor orelse g.area.viewport) orelse continue;
                if (!renderer_mod.covers(dmg, area)) continue;
                if (g.direct) |direct| {
                    // Drawn into this frame, on this GPU: no copy through
                    // the CPU.
                    const frame: DirectFrame = .{ .device = r.device.?, .context = r.context, .texture = screen.tex.?, .width = t.width, .height = t.height };
                    const drawn = try direct(g.ctx, .d3d11, &frame, g.area);
                    r.beginPass(screen.rtv.?, t.width, t.height);
                    if (drawn) continue;
                }
                // Drawn on the CPU: what is under it is read back first, and
                // what is over it drawn after.
                try r.scratch.resize(r.gpa, @as(usize, t.width) * t.height);
                var img: software.Image = .{ .pixels = r.scratch.items, .width = t.width, .height = t.height };
                try r.download(screen, img, area);
                try g.f(g.ctx, @ptrCast(&img), g.area);
                r.upload(screen, img, area);
                r.beginPass(screen.rtv.?, t.width, t.height);
            },
        };

        // Into the window's back buffer, as big as the frame.
        const back: Obj = t.texture;
        if (t.width == screen.width and t.height == screen.height) {
            Context.copyResource(r.context, back, screen.tex.?);
        } else {
            const box = boxOf(.{ .width = @min(t.width, screen.width), .height = @min(t.height, screen.height) });
            Context.copySubresourceRegion(r.context, back, 0, 0, screen.tex.?, &box);
        }
        // Nothing stays bound to what the window resizes.
        Context.omSetRenderTarget(r.context, null, null);
    }
};

test "a canvas is drawn by D3D11 (WARP) as the software renderer draws it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var dx = D3D11Renderer.initWarp(std.testing.allocator) catch |e| {
        if (e == error.NoShaders) return error.SkipZigTest;
        return e;
    };
    defer dx.deinit();

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
    c.fillRect(.{ .x = 10, .y = 50, .w = 80, .h = 20 }, .rgb(0x0000ff));

    try dx.renderer().draw(&c, &img);
    try std.testing.expectEqual(@as(u32, 0xff112233), img.pixels[2 * w + 2]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), img.pixels[25 * w + 30]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), img.pixels[20 * w + 70]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), img.pixels[60 * w + 50]);

    // As the software renderer draws it, to within a little at the edges
    // (anti-aliasing is computed alike, rounded apart).
    const expected = try std.testing.allocator.alloc(u32, w * h);
    defer std.testing.allocator.free(expected);
    var want: software.Image = .{ .pixels = expected, .width = w, .height = h };
    want.clear(0xff112233);
    var sw: software.SoftwareRenderer = .{};
    try sw.renderer().draw(&c, &want);
    var off: usize = 0;
    for (pixels, expected) |got, exp| {
        inline for (.{ 0, 8, 16, 24 }) |shift| {
            const a: i32 = @intCast((got >> shift) & 0xff);
            const b: i32 = @intCast((exp >> shift) & 0xff);
            if (@abs(a - b) > 8) {
                off += 1;
                break;
            }
        }
    }
    try std.testing.expect(off <= w * h / 100);
}

test "a frame drawn only where it changed keeps the rest" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var dx = D3D11Renderer.initWarp(std.testing.allocator) catch |e| {
        if (e == error.NoShaders) return error.SkipZigTest;
        return e;
    };
    defer dx.deinit();
    const w: u32 = 40;
    const h: u32 = 20;
    var pixels: [w * h]u32 = undefined;
    var img: software.Image = .{ .pixels = &pixels, .width = w, .height = h };
    img.clear(0xff000000);
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    c.begin(w, h);
    c.fillRect(.{ .x = 0, .y = 0, .w = w, .h = h }, .rgb(0xffffff));
    // Only the left half is drawn.
    try dx.prepare(&.{&c});
    try dx.record(&c, &img, &.{.{ .width = w / 2, .height = h }});
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[5 * w + 5]);
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[5 * w + 30]);
}

// --- 3D scenes ---------------------------------------------------------------------

/// GPU work that a scene waits for before it is drawn (as its `wait`).
pub const Wait = union(enum) {
    /// Done once `fence`, an `ID3D11Fence` of the scene's device (one shared
    /// with another device, opened with `ID3D11Device5::OpenSharedFence`,
    /// say), reaches `value`. It needs Windows 10 1703 or later.
    fence: struct { fence: Obj, value: u64 },
    /// Holding `mutex`, the `IDXGIKeyedMutex` of a texture shared with
    /// another device: acquired with `acquire_key` before the scene is
    /// drawn, and released with `release_key` after it.
    keyed_mutex: struct { mutex: Obj, acquire_key: u64, release_key: u64 },
};

/// `ID3D11DeviceContext4::Wait` (slot 148), and `IDXGIKeyedMutex`'s
/// `AcquireSync` and `ReleaseSync` (slots 8 and 9).
const FenceWait = fn (Obj, Obj, u64) callconv(cc) HRESULT;
const AcquireSync = fn (Obj, u64, u32) callconv(cc) HRESULT;
const ReleaseSync = fn (Obj, u64) callconv(cc) HRESULT;

/// Has `context` wait for `w` before what it draws next: queued on the GPU
/// for a fence, or acquired now for a keyed mutex (to be released with
/// `endWait`).
fn beginWait(context: Obj, w: Wait) !void {
    switch (w) {
        .fence => |f| {
            const ctx4 = w32.query(context, &iid_device_context4) orelse return error.D3D11FenceUnsupported;
            defer w32.release(ctx4);
            if (!w32.succeeded(w32.call(ctx4, 148, FenceWait, .{ f.fence, f.value }))) return error.D3D11WaitFailed;
        },
        .keyed_mutex => |k| if (!w32.succeeded(w32.call(k.mutex, 8, AcquireSync, .{ k.acquire_key, 0xffffffff }))) return error.D3D11AcquireSyncFailed,
    }
}

/// Lets go of what `beginWait` acquired.
fn endWait(w: Wait) void {
    switch (w) {
        .fence => {},
        .keyed_mutex => |k| _ = w32.call(k.mutex, 9, ReleaseSync, .{k.release_key}),
    }
}

/// Draws 3D scenes with Direct3D 11 (for `D3D11Area`): into a multisampled
/// colour texture with depth, resolved and copied into the renderer's frame
/// on the GPU (`renderToFrame`), or into an image on the CPU
/// (`renderToImage`). A scene makes pipelines of its own shaders (DXBC,
/// compiled by fxc when it is built), and buffers, and draws with them in
/// its `render`:
///
///     ctx.bindPipeline(s.pipeline);
///     ctx.setUniforms(Uniforms, &uniforms);
///     ctx.bindVertexBuffer(s.vbo);
///     ctx.bindIndexBuffer16(s.ibo);
///     ctx.drawIndexed(36);
///
/// Its vertex shader reads attribute `location` as `TEXCOORD<location>`,
/// and the uniforms are the constant buffer in register b0 (of both
/// shaders), a matrix in it as column-major as Zig's `[4][4]f32` of columns
/// (HLSL's default), so that `mul(m, v)` is `m` times `v`.
pub const OffscreenContext = struct {
    gpa: std.mem.Allocator,
    device: Obj,
    context: Obj,
    /// Whether the device is its own (not the renderer's).
    owned: bool,
    depth_on: ?Obj = null,
    depth_off: ?Obj = null,
    /// What a scene is drawn in: the multisampled colour (if more than one
    /// sample) and depth, and the colour resolved; their size and samples.
    msaa_tex: ?Obj = null,
    msaa_rtv: ?Obj = null,
    depth_tex: ?Obj = null,
    depth_dsv: ?Obj = null,
    resolve: ?Obj = null,
    resolve_rtv: ?Obj = null,
    target_size: [2]u32 = .{ 0, 0 },
    samples: u8 = 0,
    staging: ?Obj = null,
    staging_w: u32 = 0,
    staging_h: u32 = 0,
    /// The size of what is being drawn (for `aspect`), the uniforms'
    /// buffer, and the vertices' stride (the bound pipeline's).
    width: u32 = 0,
    height: u32 = 0,
    uniforms: ?Obj = null,
    uniforms_size: usize = 0,
    stride: u32 = 0,

    pub const Buffer = struct {
        buf: ?Obj = null,
    };

    pub const PipelineDesc = struct {
        /// The vertex and pixel shaders, as DXBC.
        vertex: []const u8,
        pixel: []const u8,
        vertex_stride: u32,
        /// Each attribute's floats (1 to 4), read as `TEXCOORD<location>`.
        attributes: []const shaders.Attribute,
        cull_back: bool = true,
        front_ccw: bool = true,
        depth_test: bool = true,
        blend: bool = false,
    };

    pub const Pipeline = struct {
        vs: ?Obj = null,
        ps: ?Obj = null,
        layout: ?Obj = null,
        raster: ?Obj = null,
        blend: ?Obj = null,
        stride: u32 = 0,
        depth_test: bool = true,
    };

    pub const sample_counts = [4]u8{ 1, 2, 4, 8 };

    /// On the system's GPU, its own.
    pub fn init(gpa: std.mem.Allocator) !OffscreenContext {
        const dev = try createDevice(false);
        return initWith(gpa, dev.device, dev.context, true);
    }

    /// On a renderer's GPU (`D3D11Renderer.sharedDevice`), so that scenes
    /// are drawn straight into its frames.
    pub fn initShared(gpa: std.mem.Allocator, shared: SharedDevice) !OffscreenContext {
        if (builtin.os.tag != .windows) return error.Unsupported;
        return initWith(gpa, shared.device, shared.context, false);
    }

    fn initWith(gpa: std.mem.Allocator, device: Obj, context: Obj, owned: bool) !OffscreenContext {
        var self: OffscreenContext = .{ .gpa = gpa, .device = device, .context = context, .owned = owned };
        errdefer self.deinit();
        self.depth_on = try Device.createDepthStencilState(device, &.{ .DepthEnable = w32.TRUE, .DepthWriteMask = 1, .DepthFunc = 2 }); // LESS
        self.depth_off = try Device.createDepthStencilState(device, &.{ .DepthEnable = w32.FALSE, .DepthWriteMask = 0, .DepthFunc = 8 }); // ALWAYS
        return self;
    }

    pub fn deinit(self: *OffscreenContext) void {
        for ([_]?Obj{ self.depth_on, self.depth_off, self.msaa_rtv, self.msaa_tex, self.depth_dsv, self.depth_tex, self.resolve_rtv, self.resolve, self.staging, self.uniforms }) |o| w32.release(o);
        if (self.owned) {
            w32.release(self.context);
            w32.release(self.device);
        }
        self.* = undefined;
    }

    /// Lets what it gave the GPU go (Direct3D keeps what is still drawn).
    pub fn waitIdle(self: *OffscreenContext) void {
        Context.flush(self.context);
    }

    pub fn aspect(self: *const OffscreenContext) f32 {
        if (self.height == 0) return 1;
        return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
    }

    pub fn createPipeline(self: *OffscreenContext, desc: PipelineDesc) !Pipeline {
        if (desc.vertex.len == 0 or desc.pixel.len == 0) return error.NoShaders;
        var p: Pipeline = .{ .stride = desc.vertex_stride, .depth_test = desc.depth_test };
        errdefer self.destroyPipeline(p);
        p.vs = try Device.createVertexShader(self.device, desc.vertex);
        p.ps = try Device.createPixelShader(self.device, desc.pixel);
        var elements: [16]InputElementDesc = undefined;
        if (desc.attributes.len > elements.len) return error.TooManyAttributes;
        for (desc.attributes, 0..) |a, i| {
            elements[i] = .{
                .SemanticName = "TEXCOORD",
                .SemanticIndex = a.location,
                .Format = switch (a.components) {
                    1 => format_r32,
                    2 => format_rg32,
                    3 => format_rgb32,
                    else => format_rgba32,
                },
                .AlignedByteOffset = a.offset,
            };
        }
        p.layout = try Device.createInputLayout(self.device, elements[0..desc.attributes.len], desc.vertex);
        p.raster = try Device.createRasterizerState(self.device, &.{
            .CullMode = if (desc.cull_back) 3 else 1, // BACK, NONE
            .FrontCounterClockwise = if (desc.front_ccw) w32.TRUE else w32.FALSE,
            .MultisampleEnable = w32.TRUE,
        });
        if (desc.blend) {
            var blend: BlendDesc = .{};
            blend.RenderTarget[0] = .{ .BlendEnable = w32.TRUE, .SrcBlend = 5, .DestBlend = 6, .SrcBlendAlpha = 2, .DestBlendAlpha = 6 };
            p.blend = try Device.createBlendState(self.device, &blend);
        }
        return p;
    }

    pub fn destroyPipeline(_: *const OffscreenContext, p: Pipeline) void {
        for ([_]?Obj{ p.vs, p.ps, p.layout, p.raster, p.blend }) |o| w32.release(o);
    }

    pub fn createVertexBuffer(self: *const OffscreenContext, comptime T: type, items: []const T) !Buffer {
        return self.buffer(std.mem.sliceAsBytes(items), bind_vertex);
    }

    pub fn createIndexBuffer(self: *const OffscreenContext, indices: []const u16) !Buffer {
        return self.buffer(std.mem.sliceAsBytes(indices), bind_index);
    }

    fn buffer(self: *const OffscreenContext, bytes: []const u8, bind: u32) !Buffer {
        if (bytes.len == 0) return .{};
        const init_data: SubresourceData = .{ .pSysMem = bytes.ptr };
        return .{ .buf = try Device.createBuffer(self.device, .{ .ByteWidth = @intCast(bytes.len), .Usage = usage_immutable, .BindFlags = bind }, &init_data) };
    }

    pub fn destroyBuffer(_: *const OffscreenContext, buf: Buffer) void {
        w32.release(buf.buf);
    }

    pub fn bindPipeline(self: *OffscreenContext, p: Pipeline) void {
        const c = self.context;
        Context.iaSetInputLayout(c, p.layout);
        Context.iaSetTriangles(c);
        Context.vsSetShader(c, p.vs);
        Context.psSetShader(c, p.ps);
        Context.rsSetState(c, p.raster);
        Context.omSetBlendState(c, p.blend);
        Context.omSetDepthStencilState(c, if (p.depth_test) self.depth_on else self.depth_off);
        self.stride = p.stride;
    }

    /// The uniforms both shaders read (their constant buffer, b0).
    pub fn setUniforms(self: *OffscreenContext, comptime T: type, value: *const T) void {
        const len = std.mem.alignForward(usize, @sizeOf(T), 16);
        if (self.uniforms == null or self.uniforms_size < len) {
            w32.release(self.uniforms);
            self.uniforms = Device.createBuffer(self.device, .{ .ByteWidth = @intCast(len), .Usage = usage_dynamic, .BindFlags = bind_constant, .CPUAccessFlags = cpu_write }, null) catch null;
            self.uniforms_size = if (self.uniforms == null) 0 else len;
        }
        const buf = self.uniforms orelse return;
        const m = Context.map(self.context, buf, map_write_discard) catch return;
        @memcpy(@as([*]u8, @ptrCast(m.pData.?))[0..@sizeOf(T)], std.mem.asBytes(value));
        Context.unmap(self.context, buf);
        Context.vsSetConstantBuffer(self.context, buf);
        Context.psSetConstantBuffer(self.context, buf);
    }

    pub fn bindVertexBuffer(self: *OffscreenContext, buf: Buffer) void {
        Context.iaSetVertexBuffer(self.context, buf.buf, self.stride, 0);
    }

    pub fn bindIndexBuffer16(self: *OffscreenContext, buf: Buffer) void {
        Context.iaSetIndexBuffer16(self.context, buf.buf);
    }

    pub fn draw(self: *OffscreenContext, vertex_count: u32) void {
        Context.draw(self.context, vertex_count, 0);
    }

    pub fn drawIndexed(self: *OffscreenContext, index_count: u32) void {
        Context.drawIndexed(self.context, index_count);
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
        while (count > 1 and !Device.supportsSamples(self.device, format_bgra8, count)) count /= 2;
        if (self.resolve != null and self.target_size[0] == width and self.target_size[1] == height and self.samples == count) return;
        for ([_]?Obj{ self.msaa_rtv, self.msaa_tex, self.depth_dsv, self.depth_tex, self.resolve_rtv, self.resolve }) |o| w32.release(o);
        self.msaa_rtv = null;
        self.msaa_tex = null;
        self.depth_dsv = null;
        self.depth_tex = null;
        self.resolve_rtv = null;
        self.resolve = null;
        self.samples = count;
        self.target_size = .{ width, height };
        self.resolve = try Device.createTexture2D(self.device, .{ .Width = width, .Height = height, .Format = format_bgra8, .BindFlags = bind_render_target | bind_shader_resource }, null);
        self.resolve_rtv = try Device.createRenderTargetView(self.device, self.resolve.?);
        if (count > 1) {
            self.msaa_tex = try Device.createTexture2D(self.device, .{ .Width = width, .Height = height, .Format = format_bgra8, .SampleCount = count, .BindFlags = bind_render_target }, null);
            self.msaa_rtv = try Device.createRenderTargetView(self.device, self.msaa_tex.?);
        }
        self.depth_tex = try Device.createTexture2D(self.device, .{ .Width = width, .Height = height, .Format = format_d24s8, .SampleCount = count, .BindFlags = bind_depth_stencil }, null);
        self.depth_dsv = try Device.createDepthStencilView(self.device, self.depth_tex.?);
    }

    /// Draws the scene (`width` by `height`) over `clear_color` into
    /// `resolve`, once `wait` (if given) is done.
    fn encodeScene(self: *OffscreenContext, width: u32, height: u32, clear_color: ?canvas_mod.Color, samples: u8, wait: ?Wait, user_ctx: anytype, comptime render_fn: anytype) !void {
        try self.ensureTargets(width, height, samples);
        if (wait) |w| try beginWait(self.context, w);
        defer if (wait) |w| endWait(w);
        self.width = width;
        self.height = height;
        const c = self.context;
        const rtv = self.msaa_rtv orelse self.resolve_rtv.?;
        Context.omSetRenderTarget(c, rtv, self.depth_dsv);
        Context.rsSetViewport(c, 0, 0, @floatFromInt(width), @floatFromInt(height));
        if (clear_color) |col| Context.clearRenderTargetView(c, rtv, .{ col.r, col.g, col.b, col.a });
        Context.clearDepth(c, self.depth_dsv.?);
        try render_fn(user_ctx, self);
        if (self.msaa_tex) |m| Context.resolve(c, self.resolve.?, m, format_bgra8);
        Context.omSetRenderTarget(c, null, null);
    }

    /// Draws the scene over `area`'s viewport into `frame` on the GPU,
    /// within its scissor, once `wait` (if given) is done; false if `frame`
    /// is on another GPU (draw with `renderToImage`).
    pub fn renderToFrame(self: *OffscreenContext, frame: *const DirectFrame, area: GpuArea, clear_color: ?canvas_mod.Color, samples: u8, wait: ?Wait, user_ctx: anytype, comptime render_fn: anytype) !bool {
        if (frame.device != self.device) return false;
        const vp = area.viewport;
        if (vp.width == 0 or vp.height == 0) return true;
        const full: Viewport = .{ .width = frame.width, .height = frame.height };
        const sc = full.intersect(if (area.scissor) |s| vp.intersect(s) orelse return true else vp) orelse return true;
        try self.encodeScene(vp.width, vp.height, clear_color, samples, wait, user_ctx, render_fn);
        const box = boxOf(.{ .x = sc.x - vp.x, .y = sc.y - vp.y, .width = sc.width, .height = sc.height });
        Context.copySubresourceRegion(self.context, frame.texture, @intCast(sc.x), @intCast(sc.y), self.resolve.?, &box);
        return true;
    }

    /// Draws the scene over `area`'s viewport into `target` on the CPU,
    /// within its scissor, once `wait` (if given) is done.
    pub fn renderToImage(self: *OffscreenContext, target: *software.Image, area: GpuArea, clear_color: ?canvas_mod.Color, samples: u8, wait: ?Wait, user_ctx: anytype, comptime render_fn: anytype) !void {
        const vp = area.viewport;
        if (vp.width == 0 or vp.height == 0) return;
        const full: Viewport = .{ .width = target.width, .height = target.height };
        const sc = full.intersect(if (area.scissor) |s| vp.intersect(s) orelse return else vp) orelse return;
        try self.encodeScene(vp.width, vp.height, clear_color, samples, wait, user_ctx, render_fn);
        if (self.staging == null or self.staging_w < vp.width or self.staging_h < vp.height) {
            w32.release(self.staging);
            self.staging = null;
            self.staging = try Device.createTexture2D(self.device, .{ .Width = vp.width, .Height = vp.height, .Format = format_bgra8, .Usage = usage_staging, .CPUAccessFlags = cpu_read }, null);
            self.staging_w = vp.width;
            self.staging_h = vp.height;
        }
        const local: Viewport = .{ .x = sc.x - vp.x, .y = sc.y - vp.y, .width = sc.width, .height = sc.height };
        const box = boxOf(local);
        Context.copySubresourceRegion(self.context, self.staging.?, box.left, box.top, self.resolve.?, &box);
        const m = try Context.map(self.context, self.staging.?, map_read);
        defer Context.unmap(self.context, self.staging.?);
        const base: [*]const u8 = @ptrCast(m.pData.?);
        const stride = target.rowStride();
        for (0..sc.height) |row| {
            const src: [*]const u32 = @ptrCast(@alignCast(base + (@as(usize, @intCast(local.y)) + row) * m.RowPitch + @as(usize, @intCast(local.x)) * 4));
            const dst_at = (@as(usize, @intCast(sc.y)) + row) * stride + @as(usize, @intCast(sc.x));
            @memcpy(target.pixels[dst_at..][0..sc.width], src[0..sc.width]);
        }
    }
};
