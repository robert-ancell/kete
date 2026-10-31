//! OpenGL 3.3+ Core / OpenGL 4.6 SPIR-V rendering backend for Kete's 2D `Canvas`
//! and `OpenGlArea` offscreen 3D widget.
//!
//! Uses a runtime `GetProcAddress` loader (compatible with `eglGetProcAddress`,
//! `glXGetProcAddress`, `wglGetProcAddress`, SDL, or GLFW) so no C headers or
//! system OpenGL libraries are required at compile time.
//!
//!     var gl = try gfx.opengl.OpenGlRenderer.init(gpa, eglGetProcAddress);
//!     defer gl.deinit();
//!     const target: gfx.opengl.Target = .{ .width = win_w, .height = win_h };
//!     try ui.renderWith(gl.renderer(), &target, null);

const std = @import("std");
const shaders = @import("shaders.zig");
const canvas_mod = @import("canvas.zig");
const atlas_mod = @import("atlas.zig");
const renderer_mod = @import("renderer.zig");

const software = @import("software.zig");

const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;
const Viewport = renderer_mod.Viewport;
const DmabufImage = renderer_mod.DmabufImage;
const DmabufTarget = renderer_mod.DmabufTarget;
const Segment = renderer_mod.Segment;
const GpuArea = renderer_mod.GpuArea;
const DrmNode = renderer_mod.DrmNode;

pub const GLenum = c_uint;
pub const GLboolean = u8;
pub const GLbitfield = c_uint;
pub const GLint = c_int;
pub const GLuint = c_uint;
pub const GLsizei = c_int;
pub const GLfloat = f32;
pub const GLsizeiptr = isize;
pub const GLintptr = isize;

pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;
pub const GL_DEPTH_BUFFER_BIT: GLbitfield = 0x00000100;
pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
pub const GL_TRIANGLES: GLenum = 0x0004;
pub const GL_LESS: GLenum = 0x0201;
pub const GL_SRC_ALPHA: GLenum = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_ONE: GLenum = 1;
pub const GL_FRONT: GLenum = 0x0404;
pub const GL_BACK: GLenum = 0x0405;
pub const GL_CW: GLenum = 0x0900;
pub const GL_CCW: GLenum = 0x0901;
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_SCISSOR_TEST: GLenum = 0x0C11;
pub const GL_DEPTH_TEST: GLenum = 0x0B71;
pub const GL_CULL_FACE: GLenum = 0x0B44;
pub const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;
pub const GL_PACK_ALIGNMENT: GLenum = 0x0D05;
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_UNSIGNED_SHORT: GLenum = 0x1403;
pub const GL_UNSIGNED_INT: GLenum = 0x1405;
pub const GL_FLOAT: GLenum = 0x1406;
pub const GL_RED: GLenum = 0x1903;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_EXTENSIONS: GLenum = 0x1F03;
pub const GL_BGRA: GLenum = 0x80E1;
pub const GL_NEAREST: GLint = 0x2600;
pub const GL_LINEAR: GLint = 0x2601;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_CLAMP_TO_EDGE: GLint = 0x812F;
pub const GL_MAJOR_VERSION: GLenum = 0x821B;
pub const GL_MINOR_VERSION: GLenum = 0x821C;
pub const GL_NUM_EXTENSIONS: GLenum = 0x821D;
pub const GL_R8: GLint = 0x8229;
pub const GL_RGBA8: GLint = 0x8058;
pub const GL_DEPTH_COMPONENT24: GLenum = 0x81A6;
pub const GL_TEXTURE0: GLenum = 0x84C0;
pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_ELEMENT_ARRAY_BUFFER: GLenum = 0x8893;
pub const GL_STREAM_DRAW: GLenum = 0x88E0;
pub const GL_STATIC_DRAW: GLenum = 0x88E4;
pub const GL_DYNAMIC_DRAW: GLenum = 0x88E8;
pub const GL_UNIFORM_BUFFER: GLenum = 0x8A11;
pub const GL_INVALID_INDEX: GLuint = 0xFFFFFFFF;
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;
pub const GL_READ_FRAMEBUFFER: GLenum = 0x8CA8;
pub const GL_DRAW_FRAMEBUFFER: GLenum = 0x8CA9;
pub const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;
pub const GL_DEPTH_ATTACHMENT: GLenum = 0x8D00;
pub const GL_FRAMEBUFFER: GLenum = 0x8D40;
pub const GL_RENDERBUFFER: GLenum = 0x8D41;
pub const GL_TEXTURE_SWIZZLE_A: GLenum = 0x8E45;
pub const GL_SHADER_BINARY_FORMAT_SPIR_V: GLenum = 0x9551;

pub const GetProcAddress = *const fn (name: [*:0]const u8) callconv(.c) ?*const anyopaque;
pub const ShaderBinaryFn = *const fn (GLsizei, [*]const GLuint, GLenum, *const anyopaque, GLsizei) callconv(.c) void;
pub const SpecializeShaderFn = *const fn (GLuint, [*:0]const u8, GLuint, ?[*]const GLuint, ?[*]const GLuint) callconv(.c) void;
pub const GetIntegervFn = *const fn (GLenum, *GLint) callconv(.c) void;
pub const GetStringiFn = *const fn (GLenum, GLuint) callconv(.c) ?[*:0]const u8;

fn querySpirvSupport(
    get_int: ?GetIntegervFn,
    get_str: ?GetStringiFn,
    shader_bin: ?ShaderBinaryFn,
    spec_shader: ?SpecializeShaderFn,
) bool {
    if (shader_bin == null or spec_shader == null) return false;
    const gi = get_int orelse return false;
    var major: GLint = 0;
    var minor: GLint = 0;
    gi(GL_MAJOR_VERSION, &major);
    gi(GL_MINOR_VERSION, &minor);
    if (major > 4 or (major == 4 and minor >= 6)) return true;
    const gs = get_str orelse return false;
    var num_ext: GLint = 0;
    gi(GL_NUM_EXTENSIONS, &num_ext);
    if (num_ext <= 0) return false;
    for (0..@intCast(num_ext)) |i| {
        const ext_ptr = gs(GL_EXTENSIONS, @intCast(i)) orelse continue;
        if (std.mem.eql(u8, std.mem.span(ext_ptr), "GL_ARB_gl_spirv")) return true;
    }
    return false;
}

/// Whether the current context is OpenGL `major`.`minor` or later, or has
/// extension `name`.
fn hasGlVersionOrExtension(get_int: ?GetIntegervFn, get_str: ?GetStringiFn, major: GLint, minor: GLint, name: []const u8) bool {
    const gi = get_int orelse return false;
    var have_major: GLint = 0;
    var have_minor: GLint = 0;
    gi(GL_MAJOR_VERSION, &have_major);
    gi(GL_MINOR_VERSION, &have_minor);
    if (have_major > major or (have_major == major and have_minor >= minor)) return true;
    const gs = get_str orelse return false;
    var num_ext: GLint = 0;
    gi(GL_NUM_EXTENSIONS, &num_ext);
    for (0..@intCast(@max(num_ext, 0))) |i| {
        const ext = gs(GL_EXTENSIONS, @intCast(i)) orelse continue;
        if (std.mem.eql(u8, std.mem.span(ext), name)) return true;
    }
    return false;
}

const GL_ZERO: GLenum = 0;
const GL_ONE_MINUS_DST_ALPHA: GLenum = 0x0305;
const GL_LOWER_LEFT: GLenum = 0x8CA1;
const GL_UPPER_LEFT: GLenum = 0x8CA2;
const GL_NEGATIVE_ONE_TO_ONE: GLenum = 0x935E;

/// What drawing straight into window buffers (`renderDmabuf`) needs beyond
/// 2D drawing: importing dmabufs as images (`EGL_EXT_image_dma_buf_import`,
/// with modifiers if EGL has them) and textures of them
/// (`GL_OES_EGL_image`), drawing with rows top down (`glClipControl`, from
/// OpenGL 4.5), and clearing, copying and finishing.
const DirectProcs = struct {
    CreateImageKHR: *const fn (EGLDisplay, EGLContext, EGLenum, ?*anyopaque, [*]const EGLint) callconv(.c) EGLImageKHR,
    DestroyImageKHR: *const fn (EGLDisplay, EGLImageKHR) callconv(.c) EGLBoolean,
    EGLImageTargetTexture2DOES: *const fn (GLenum, EGLImageKHR) callconv(.c) void,
    ClipControl: *const fn (GLenum, GLenum) callconv(.c) void,
    ClearColor: *const fn (GLfloat, GLfloat, GLfloat, GLfloat) callconv(.c) void,
    Clear: *const fn (GLbitfield) callconv(.c) void,
    BlitFramebuffer: *const fn (GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum) callconv(.c) void,
    Finish: *const fn () callconv(.c) void,
    /// Whether dmabufs can be imported with their modifiers.
    modifiers: bool = false,

    /// What the display and the current context have, or null if they
    /// lack any of it.
    fn load(lib: *std.DynLib, egl: *const EglProcs, dpy: EGLDisplay, gl: Procs) ?DirectProcs {
        const extensions = eglExtensions(lib, dpy) orelse return null;
        if (!hasExtension(extensions, "EGL_EXT_image_dma_buf_import")) return null;
        if (!hasGlVersionOrExtension(gl.GetIntegerv, gl.GetStringi, 4, 5, "GL_ARB_clip_control")) return null;
        var p: DirectProcs = undefined;
        inline for (@typeInfo(DirectProcs).@"struct".field_names) |field_name| {
            if (comptime std.mem.eql(u8, field_name, "modifiers")) continue;
            const prefix = if (comptime std.mem.endsWith(u8, field_name, "KHR")) "egl" else "gl";
            const sym = egl.GetProcAddress(prefix ++ field_name) orelse return null;
            @field(p, field_name) = @ptrCast(@alignCast(sym));
        }
        p.modifiers = hasExtension(extensions, "EGL_EXT_image_dma_buf_import_modifiers");
        return p;
    }
};

/// The OpenGL renderer's EGL display and context
/// (`OpenGlRenderer.sharedDisplay`), for a context sharing what is made on
/// it with the renderer's (`OffscreenContext.initShared`); and its GPU, if
/// EGL says.
pub const SharedDisplay = struct {
    display: ?*anyopaque,
    context: ?*anyopaque,
    drm: ?DrmNode = null,
};

const EGLDeviceEXT = ?*anyopaque;
const EGLAttrib = isize;
const EGL_DEVICE_EXT: EGLint = 0x322C;
const EGL_DRM_RENDER_NODE_FILE_EXT: EGLint = 0x3377;
const EGL_PLATFORM_DEVICE_EXT: EGLenum = 0x313F;

/// EGL's GPUs (`EGL_EXT_device_enumeration`, `EGL_EXT_device_query`), a
/// display on one (`EGL_EXT_platform_device`), and their DRM render nodes
/// (`EGL_EXT_device_drm_render_node`), if EGL has them.
const DeviceProcs = struct {
    QueryDevicesEXT: *const fn (EGLint, ?[*]EGLDeviceEXT, *EGLint) callconv(.c) EGLBoolean,
    QueryDeviceStringEXT: *const fn (EGLDeviceEXT, EGLint) callconv(.c) ?[*:0]const u8,
    QueryDisplayAttribEXT: *const fn (EGLDisplay, EGLint, *EGLAttrib) callconv(.c) EGLBoolean,
    GetPlatformDisplayEXT: *const fn (EGLenum, ?*anyopaque, ?[*]const EGLint) callconv(.c) EGLDisplay,

    fn load(lib: *std.DynLib, egl: *const EglProcs) ?DeviceProcs {
        // The client extensions (of no display).
        const extensions = eglExtensions(lib, EGL_NO_DISPLAY) orelse return null;
        const base = hasExtension(extensions, "EGL_EXT_device_base");
        if (!base and !(hasExtension(extensions, "EGL_EXT_device_enumeration") and hasExtension(extensions, "EGL_EXT_device_query"))) return null;
        if (!hasExtension(extensions, "EGL_EXT_platform_device")) return null;
        var p: DeviceProcs = undefined;
        inline for (@typeInfo(DeviceProcs).@"struct".field_names) |field_name| {
            const sym = egl.GetProcAddress("egl" ++ field_name) orelse return null;
            @field(p, field_name) = @ptrCast(@alignCast(sym));
        }
        return p;
    }

    fn nodeOf(x: DeviceProcs, dev: EGLDeviceEXT) ?DrmNode {
        return DrmNode.ofPath(x.QueryDeviceStringEXT(dev, EGL_DRM_RENDER_NODE_FILE_EXT) orelse return null);
    }
};

/// The DRM render node of `dpy`'s GPU, or null if EGL cannot say.
fn displayNode(lib: *std.DynLib, egl: *const EglProcs, dpy: EGLDisplay) ?DrmNode {
    const x = DeviceProcs.load(lib, egl) orelse return null;
    var attr: EGLAttrib = 0;
    // Mesa may not say, giving no device.
    if (x.QueryDisplayAttribEXT(dpy, EGL_DEVICE_EXT, &attr) == EGL_FALSE or attr == 0) return null;
    return x.nodeOf(@ptrFromInt(@as(usize, @bitCast(attr))));
}

/// A display on the GPU of `node`, or null if EGL has none (or cannot say).
fn deviceDisplay(lib: *std.DynLib, egl: *const EglProcs, node: DrmNode) EGLDisplay {
    const x = DeviceProcs.load(lib, egl) orelse return null;
    var devices: [16]EGLDeviceEXT = undefined;
    var count: EGLint = 0;
    if (x.QueryDevicesEXT(devices.len, &devices, &count) == EGL_FALSE) return null;
    for (devices[0..@intCast(count)]) |dev| {
        const n = x.nodeOf(dev) orelse continue;
        if (n.major == node.major and n.minor == node.minor) return x.GetPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT, dev, null);
    }
    return null;
}

/// A frame the OpenGL renderer is drawing straight into a window's buffer,
/// given to a widget's GPU draw (`GpuDraw.direct`, with `.opengl`). The
/// renderer's context is current, with `fbo` bound and drawn with rows top
/// down (`glClipControl`'s upper left origin).
pub const DirectFrame = struct {
    /// The framebuffer of the window's buffer.
    fbo: GLuint,
    /// Where the frame's top left is in it (inside the shadow), and its size.
    origin: [2]i32,
    width: u32,
    height: u32,
    /// For draws on other contexts: copies the part of `src` (a picture of
    /// `area`'s viewport) within `area` into the frame, or returns false if
    /// it cannot be imported. It takes `src.ready_fd`, and leaves the
    /// renderer's context current.
    copy_ctx: *anyopaque,
    copy_dmabuf: *const fn (ctx: *anyopaque, frame: *const DirectFrame, src: *const DmabufImage, area: GpuArea) anyerror!bool,
};

pub const Procs = struct {
    Enable: *const fn (GLenum) callconv(.c) void,
    Disable: *const fn (GLenum) callconv(.c) void,
    BlendFuncSeparate: *const fn (GLenum, GLenum, GLenum, GLenum) callconv(.c) void,
    Viewport: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void,
    Scissor: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void,
    BindFramebuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    GenFramebuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteFramebuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    FramebufferTexture2D: *const fn (GLenum, GLenum, GLenum, GLuint, GLint) callconv(.c) void,
    ReadPixels: *const fn (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, *anyopaque) callconv(.c) void,
    GenBuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteBuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    BindBuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    BufferData: *const fn (GLenum, GLsizeiptr, ?*const anyopaque, GLenum) callconv(.c) void,
    BufferSubData: *const fn (GLenum, GLintptr, GLsizeiptr, ?*const anyopaque) callconv(.c) void,
    GenVertexArrays: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteVertexArrays: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    BindVertexArray: *const fn (GLuint) callconv(.c) void,
    EnableVertexAttribArray: *const fn (GLuint) callconv(.c) void,
    VertexAttribPointer: *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) callconv(.c) void,
    CreateShader: *const fn (GLenum) callconv(.c) GLuint,
    DeleteShader: *const fn (GLuint) callconv(.c) void,
    ShaderSource: *const fn (GLuint, GLsizei, [*]const [*:0]const u8, ?[*]const GLint) callconv(.c) void,
    CompileShader: *const fn (GLuint) callconv(.c) void,
    GetShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    CreateProgram: *const fn () callconv(.c) GLuint,
    DeleteProgram: *const fn (GLuint) callconv(.c) void,
    AttachShader: *const fn (GLuint, GLuint) callconv(.c) void,
    LinkProgram: *const fn (GLuint) callconv(.c) void,
    GetProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    UseProgram: *const fn (GLuint) callconv(.c) void,
    GetUniformLocation: *const fn (GLuint, [*:0]const u8) callconv(.c) GLint,
    Uniform1i: *const fn (GLint, GLint) callconv(.c) void,
    GenTextures: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteTextures: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    ActiveTexture: *const fn (GLenum) callconv(.c) void,
    BindTexture: *const fn (GLenum, GLuint) callconv(.c) void,
    PixelStorei: *const fn (GLenum, GLint) callconv(.c) void,
    TexParameteri: *const fn (GLenum, GLenum, GLint) callconv(.c) void,
    TexImage2D: *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    TexSubImage2D: *const fn (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    DrawArrays: *const fn (GLenum, GLint, GLsizei) callconv(.c) void,

    // Optional OpenGL 4.6 / GL_ARB_gl_spirv entry points
    GetIntegerv: ?GetIntegervFn = null,
    GetStringi: ?GetStringiFn = null,
    ShaderBinary: ?ShaderBinaryFn = null,
    SpecializeShader: ?SpecializeShaderFn = null,

    pub fn load(get_proc: GetProcAddress) !Procs {
        var p: Procs = undefined;
        const info = @typeInfo(Procs).@"struct";
        inline for (info.field_names, info.field_types) |field_name, FieldType| {
            if (@typeInfo(FieldType) == .optional) {
                @field(p, field_name) = null;
            } else {
                const name: [*:0]const u8 = "gl" ++ field_name;
                const sym = get_proc(name) orelse return error.MissingGlFunction;
                @field(p, field_name) = @ptrCast(@alignCast(sym));
            }
        }
        if (get_proc("glGetIntegerv")) |sym| p.GetIntegerv = @ptrCast(@alignCast(sym));
        if (get_proc("glGetStringi")) |sym| p.GetStringi = @ptrCast(@alignCast(sym));
        if (get_proc("glShaderBinary")) |sym| p.ShaderBinary = @ptrCast(@alignCast(sym));
        if (get_proc("glSpecializeShader")) |sym| {
            p.SpecializeShader = @ptrCast(@alignCast(sym));
        } else if (get_proc("glSpecializeShaderARB")) |sym| {
            p.SpecializeShader = @ptrCast(@alignCast(sym));
        }
        return p;
    }
};

/// Framebuffer target for `OpenGlRenderer.recordTarget`.
pub const Target = struct {
    width: u32,
    height: u32,
    /// OpenGL framebuffer object ID (0 for the default window framebuffer).
    fbo: GLuint = 0,
    /// Its rows run top down (drawn with `glClipControl`'s upper left
    /// origin), and where its top left is in the framebuffer.
    top_down: bool = false,
    origin: [2]i32 = .{ 0, 0 },
};

pub const OpenGlRenderer = struct {
    gpa: std.mem.Allocator,
    gl: Procs,
    egl_lib: ?std.DynLib = null,
    egl: ?EglProcs = null,
    dpy: EGLDisplay = null,
    surf: EGLSurface = null,
    ctx: EGLContext = null,
    /// Its GPU's DRM render node, if EGL says.
    drm: ?DrmNode = null,
    spirv_supported: bool = false,
    shape_prog: GLuint = 0,
    solid_prog: GLuint = 0,
    text_prog: GLuint = 0,
    image_prog: GLuint = 0,
    shape_vao: GLuint = 0,
    solid_vao: GLuint = 0,
    text_vao: GLuint = 0,
    vbo: GLuint = 0,
    vbo_capacity: usize = 0,
    cursor: usize = 0,
    atlas_tex: GLuint = 0,
    atlas: ?*atlas_mod.Atlas = null,
    atlas_stale: ?atlas_mod.Rect = null,
    images: std.AutoHashMapUnmanaged(u64, GLuint) = .empty,
    image_use: renderer_mod.ImageUse = .{},
    rgba_scratch: std.ArrayList(u8) = .empty,
    fbo: GLuint = 0,
    fbo_tex: GLuint = 0,
    fbo_w: u32 = 0,
    fbo_h: u32 = 0,
    pixel_scratch: std.ArrayList(u32) = .empty,
    /// Drawing straight into window buffers (`renderDmabuf`), once it is
    /// known whether it can (`direct_known`): the window buffers drawn
    /// into, and pictures of other contexts copied in, by when each was
    /// last used (`import_clock`); fences (for a picture's `ready_fd`); and
    /// what draws a window's frame (`drawFrame`).
    direct: ?DirectProcs = null,
    direct_known: bool = false,
    sync: ?SyncProcs = null,
    targets: [max_imports]?Import = @splat(null),
    sources: [max_imports]?Import = @splat(null),
    import_clock: u64 = 0,
    window_prog: GLuint = 0,
    window_vao: GLuint = 0,
    window_vbo: GLuint = 0,

    const max_imports = 8;
    /// Vertices of a window's frame: its margin's (shadow), and each
    /// corner's twice (rounding, then shadow).
    const frame_vertices = (4 + 4 * 2) * 6;

    /// A dmabuf imported as a texture, with a framebuffer of it.
    const Import = struct {
        id: u64,
        width: u32,
        height: u32,
        image: EGLImageKHR,
        tex: GLuint,
        fbo: GLuint,
        used: u64 = 0,
        /// For a window buffer: the shadow in its margin is drawn (it
        /// stays, as the margin is not drawn again).
        frame_drawn: bool = false,
    };

    /// Initializes a self-contained headless EGL + OpenGL 3.3+/4.6 Core 2D
    /// renderer that renders `Canvas` batches into `*software.Image`.
    pub fn initDefault(gpa: std.mem.Allocator) !OpenGlRenderer {
        var egl_lib = std.DynLib.open("libEGL.so.1") catch try std.DynLib.open("libEGL.so");
        errdefer egl_lib.close();
        const egl = try EglProcs.load(&egl_lib);

        const dpy = egl.GetDisplay(EGL_DEFAULT_DISPLAY);
        if (dpy == EGL_NO_DISPLAY) return error.NoEglDisplay;
        if (egl.Initialize(dpy, null, null) == EGL_FALSE) return error.EglInitFailed;

        if (egl.BindAPI(EGL_OPENGL_API) == EGL_FALSE) return error.EglBindApiFailed;

        const cfg_attribs = [_]EGLint{
            EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
            EGL_RED_SIZE,        8,
            EGL_GREEN_SIZE,      8,
            EGL_BLUE_SIZE,       8,
            EGL_ALPHA_SIZE,      8,
            EGL_NONE,
        };
        var config: EGLConfig = null;
        var num_configs: EGLint = 0;
        if (egl.ChooseConfig(dpy, &cfg_attribs, @ptrCast(&config), 1, &num_configs) == EGL_FALSE or num_configs == 0) {
            return error.EglChooseConfigFailed;
        }

        const pbuf_attribs = [_]EGLint{ EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
        const surf = egl.CreatePbufferSurface(dpy, config, &pbuf_attribs);
        errdefer if (surf != EGL_NO_SURFACE) {
            _ = egl.DestroySurface(dpy, surf);
        };

        const versions = [_][2]EGLint{ .{ 4, 6 }, .{ 4, 5 }, .{ 3, 3 } };
        var ctx: EGLContext = EGL_NO_CONTEXT;
        for (versions) |ver| {
            const ctx_attribs = [_]EGLint{
                EGL_CONTEXT_MAJOR_VERSION,       ver[0],
                EGL_CONTEXT_MINOR_VERSION,       ver[1],
                EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
                EGL_NONE,
            };
            ctx = egl.CreateContext(dpy, config, EGL_NO_CONTEXT, &ctx_attribs);
            if (ctx != EGL_NO_CONTEXT) break;
        }
        if (ctx == EGL_NO_CONTEXT) return error.EglCreateContextFailed;
        errdefer _ = egl.DestroyContext(dpy, ctx);

        if (egl.MakeCurrent(dpy, surf, surf, ctx) == EGL_FALSE) return error.EglMakeCurrentFailed;

        var r = try init(gpa, egl.GetProcAddress);
        r.drm = displayNode(&egl_lib, &egl, dpy);
        r.egl_lib = egl_lib;
        r.egl = egl;
        r.dpy = dpy;
        r.surf = surf;
        r.ctx = ctx;
        return r;
    }

    /// Its EGL display and context, and GPU, for contexts sharing what is
    /// made on them with its own (`OffscreenContext.initShared`); null if
    /// it was made on a context of the app's (`init`).
    pub fn sharedDisplay(r: *const OpenGlRenderer) ?SharedDisplay {
        if (r.egl == null) return null;
        return .{ .display = r.dpy, .context = r.ctx, .drm = r.drm };
    }

    pub fn init(gpa: std.mem.Allocator, get_proc: GetProcAddress) !OpenGlRenderer {
        const gl = try Procs.load(get_proc);
        return initWithProcs(gpa, gl);
    }

    pub fn initWithProcs(gpa: std.mem.Allocator, gl: Procs) !OpenGlRenderer {
        var r: OpenGlRenderer = .{
            .gpa = gpa,
            .gl = gl,
            .spirv_supported = querySpirvSupport(gl.GetIntegerv, gl.GetStringi, gl.ShaderBinary, gl.SpecializeShader),
        };
        errdefer r.deinit();

        r.shape_prog = r.compileSpirvOrGlsl(&shaders.shape_gl_spv, shaders.glsl_shape_vs, shaders.glsl_shape_fs) catch
            try r.compileProgram(shaders.glsl_shape_vs, shaders.glsl_shape_fs);
        r.solid_prog = r.compileSpirvOrGlsl(&shaders.solid_gl_spv, shaders.glsl_solid_vs, shaders.glsl_solid_fs) catch
            try r.compileProgram(shaders.glsl_solid_vs, shaders.glsl_solid_fs);
        r.text_prog = r.compileSpirvOrGlsl(&shaders.text_gl_spv, shaders.glsl_text_vs, shaders.glsl_text_fs) catch
            try r.compileProgram(shaders.glsl_text_vs, shaders.glsl_text_fs);
        r.image_prog = r.compileSpirvOrGlsl(&shaders.image_gl_spv, shaders.glsl_text_vs, shaders.glsl_image_fs) catch
            try r.compileProgram(shaders.glsl_text_vs, shaders.glsl_image_fs);

        for ([_]GLuint{ r.text_prog, r.image_prog }) |prog| {
            r.gl.UseProgram(prog);
            const loc = r.gl.GetUniformLocation(prog, "u_tex");
            if (loc >= 0) r.gl.Uniform1i(loc, 0);
        }
        r.gl.UseProgram(0);

        var vaos: [3]GLuint = undefined;
        r.gl.GenVertexArrays(3, &vaos);
        r.shape_vao = vaos[0];
        r.solid_vao = vaos[1];
        r.text_vao = vaos[2];

        var vbo_id: [1]GLuint = undefined;
        r.gl.GenBuffers(1, &vbo_id);
        r.vbo = vbo_id[0];

        return r;
    }

    /// Makes its context the calling thread's (if it has one of its own:
    /// `initDefault`). It fails if the context is another thread's.
    fn makeCurrent(r: *const OpenGlRenderer) !void {
        const egl = r.egl orelse return;
        if (r.dpy == EGL_NO_DISPLAY) return;
        if (egl.MakeCurrent(r.dpy, r.surf, r.surf, r.ctx) == EGL_FALSE) return error.EglMakeCurrentFailed;
    }

    pub fn deinit(r: *OpenGlRenderer) void {
        r.deleteGlObjects();
        r.images.deinit(r.gpa);
        r.image_use.deinit(r.gpa);
        r.rgba_scratch.deinit(r.gpa);
        r.pixel_scratch.deinit(r.gpa);
        r.deinitEgl();
    }

    /// Deletes what it made in its context, if that can be current here (or
    /// else it goes with the context).
    fn deleteGlObjects(r: *OpenGlRenderer) void {
        r.makeCurrent() catch return;
        if (r.direct) |d| {
            for (&r.targets) |*slot| if (slot.*) |*im| r.dropImport(d, im);
            for (&r.sources) |*slot| if (slot.*) |*im| r.dropImport(d, im);
        }
        if (r.window_vbo != 0) r.gl.DeleteBuffers(1, &[1]GLuint{r.window_vbo});
        if (r.window_vao != 0) r.gl.DeleteVertexArrays(1, &[1]GLuint{r.window_vao});
        if (r.window_prog != 0) r.gl.DeleteProgram(r.window_prog);
        var it = r.images.valueIterator();
        while (it.next()) |tex| {
            const t = [1]GLuint{tex.*};
            r.gl.DeleteTextures(1, &t);
        }
        if (r.fbo != 0) {
            const fbos = [1]GLuint{r.fbo};
            r.gl.DeleteFramebuffers(1, &fbos);
        }
        if (r.fbo_tex != 0) {
            const t = [1]GLuint{r.fbo_tex};
            r.gl.DeleteTextures(1, &t);
        }
        if (r.atlas_tex != 0) {
            const t = [1]GLuint{r.atlas_tex};
            r.gl.DeleteTextures(1, &t);
        }
        if (r.vbo != 0) {
            const b = [1]GLuint{r.vbo};
            r.gl.DeleteBuffers(1, &b);
        }
        const vaos = [3]GLuint{ r.shape_vao, r.solid_vao, r.text_vao };
        if (r.shape_vao != 0) r.gl.DeleteVertexArrays(3, &vaos);
        for ([_]GLuint{ r.shape_prog, r.solid_prog, r.text_prog, r.image_prog }) |prog| {
            if (prog != 0) r.gl.DeleteProgram(prog);
        }
    }

    /// Lets its EGL context (and surface, and library) go.
    fn deinitEgl(r: *OpenGlRenderer) void {
        if (r.egl) |egl| {
            if (r.dpy != EGL_NO_DISPLAY) {
                _ = egl.MakeCurrent(r.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
                if (r.ctx != EGL_NO_CONTEXT) _ = egl.DestroyContext(r.dpy, r.ctx);
                if (r.surf != EGL_NO_SURFACE) _ = egl.DestroySurface(r.dpy, r.surf);
                // Not terminated: the display is shared (see
                // `OffscreenContext.deinit`).
                r.dpy = EGL_NO_DISPLAY;
            }
        }
        if (r.egl_lib) |*lib| {
            lib.close();
            r.egl_lib = null;
        }
    }

    pub const backend: renderer_mod.RenderBackend = .opengl;

    pub fn supportsSpirv(r: *const OpenGlRenderer) bool {
        return r.spirv_supported;
    }

    pub fn renderer(r: *OpenGlRenderer) renderer_mod.Renderer {
        return .of(r);
    }

    fn compileSpirvOrGlsl(r: *OpenGlRenderer, spv: []align(4) const u8, vs_src: [:0]const u8, fs_src: [:0]const u8) !GLuint {
        if (r.spirv_supported) {
            if (r.compileSpirvProgram(spv)) |prog| {
                return prog;
            } else |_| {
                r.spirv_supported = false;
            }
        }
        return r.compileProgram(vs_src, fs_src);
    }

    fn compileSpirvProgram(r: *const OpenGlRenderer, spv: []align(4) const u8) !GLuint {
        const vs = try r.compileSpirvShader(GL_VERTEX_SHADER, spv, "vertex");
        defer r.gl.DeleteShader(vs);
        const fs = try r.compileSpirvShader(GL_FRAGMENT_SHADER, spv, "fragment");
        defer r.gl.DeleteShader(fs);
        const prog = r.gl.CreateProgram();
        if (prog == 0) return error.GlCreateProgramFailed;
        errdefer r.gl.DeleteProgram(prog);
        r.gl.AttachShader(prog, vs);
        r.gl.AttachShader(prog, fs);
        r.gl.LinkProgram(prog);
        var ok: GLint = 0;
        r.gl.GetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.GlShaderLinkFailed;
        return prog;
    }

    fn compileSpirvShader(r: *const OpenGlRenderer, kind: GLenum, spv: []align(4) const u8, entry: [*:0]const u8) !GLuint {
        const shader_bin = r.gl.ShaderBinary orelse return error.SpirvNotSupported;
        const spec_shader = r.gl.SpecializeShader orelse return error.SpirvNotSupported;
        const sh = r.gl.CreateShader(kind);
        if (sh == 0) return error.GlCreateShaderFailed;
        errdefer r.gl.DeleteShader(sh);
        const shaders_arr = [1]GLuint{sh};
        shader_bin(1, &shaders_arr, GL_SHADER_BINARY_FORMAT_SPIR_V, spv.ptr, @intCast(spv.len));
        spec_shader(sh, entry, 0, null, null);
        var ok: GLint = 0;
        r.gl.GetShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (ok == 0) return error.GlShaderCompileFailed;
        return sh;
    }

    fn compileProgram(r: *const OpenGlRenderer, vs_src: [:0]const u8, fs_src: [:0]const u8) !GLuint {
        const vs = try r.compileShader(GL_VERTEX_SHADER, vs_src);
        defer r.gl.DeleteShader(vs);
        const fs = try r.compileShader(GL_FRAGMENT_SHADER, fs_src);
        defer r.gl.DeleteShader(fs);
        const prog = r.gl.CreateProgram();
        if (prog == 0) return error.GlCreateProgramFailed;
        errdefer r.gl.DeleteProgram(prog);
        r.gl.AttachShader(prog, vs);
        r.gl.AttachShader(prog, fs);
        r.gl.LinkProgram(prog);
        var ok: GLint = 0;
        r.gl.GetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.GlShaderLinkFailed;
        return prog;
    }

    fn compileShader(r: *const OpenGlRenderer, kind: GLenum, src: [:0]const u8) !GLuint {
        const sh = r.gl.CreateShader(kind);
        if (sh == 0) return error.GlCreateShaderFailed;
        errdefer r.gl.DeleteShader(sh);
        const ptrs = [1][*:0]const u8{src.ptr};
        r.gl.ShaderSource(sh, 1, &ptrs, null);
        r.gl.CompileShader(sh);
        var ok: GLint = 0;
        r.gl.GetShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (ok == 0) return error.GlShaderCompileFailed;
        return sh;
    }

    pub fn prepare(r: *OpenGlRenderer, canvases: []const *const Canvas) !void {
        try r.makeCurrent();
        var bytes: usize = 0;
        for (canvases) |c| for (c.batches.items) |*b| {
            bytes += std.mem.alignForward(usize, b.floats.items.len * 4, 16);
        };
        r.cursor = 0;
        if (bytes > 0) {
            r.gl.BindBuffer(GL_ARRAY_BUFFER, r.vbo);
            if (bytes > r.vbo_capacity) {
                r.vbo_capacity = std.mem.alignForward(usize, bytes * 2, 64 * 1024);
                r.gl.BufferData(GL_ARRAY_BUFFER, @intCast(r.vbo_capacity), null, GL_STREAM_DRAW);
            } else {
                // Orphan the previous frame's buffer storage
                r.gl.BufferData(GL_ARRAY_BUFFER, @intCast(r.vbo_capacity), null, GL_STREAM_DRAW);
            }
        }
        for (canvases) |c| if (c.atlas) |a| r.uploadAtlas(a);
        try r.uploadImages(canvases);
    }

    fn uploadAtlas(r: *OpenGlRenderer, a: *atlas_mod.Atlas) void {
        const w = atlas_mod.width;
        const h = atlas_mod.height;
        const all: atlas_mod.Rect = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
        r.gl.ActiveTexture(GL_TEXTURE0);
        if (r.atlas_tex == 0) {
            var tex: [1]GLuint = undefined;
            r.gl.GenTextures(1, &tex);
            r.atlas_tex = tex[0];
            r.gl.BindTexture(GL_TEXTURE_2D, r.atlas_tex);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, @intCast(GL_RED));
            r.gl.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
            r.gl.TexImage2D(GL_TEXTURE_2D, 0, GL_R8, w, h, 0, GL_RED, GL_UNSIGNED_BYTE, null);
            r.atlas_stale = all;
        } else {
            r.gl.BindTexture(GL_TEXTURE_2D, r.atlas_tex);
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
        const y0: u32 = d.y0;
        const y1: u32 = @min(d.y1, h);
        if (y1 > y0) {
            r.gl.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
            r.gl.TexSubImage2D(
                GL_TEXTURE_2D,
                0,
                0,
                @intCast(y0),
                w,
                @intCast(y1 - y0),
                GL_RED,
                GL_UNSIGNED_BYTE,
                a.pixels[y0 * w .. y1 * w].ptr,
            );
        }
        r.atlas_stale = null;
    }

    fn uploadImages(r: *OpenGlRenderer, canvases: []const *const Canvas) !void {
        // Those no window draws any more go.
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(r.gpa);
        try r.image_use.update(r.gpa, canvases, &stale);
        for (stale.items) |id| {
            const tex = (r.images.fetchRemove(id) orelse continue).value;
            const arr = [1]GLuint{tex};
            r.gl.DeleteTextures(1, &arr);
        }

        for (canvases) |c| for (c.batches.items) |*b| {
            const img = b.image orelse continue;
            if (r.images.contains(img.id)) continue;
            const byte_count = @as(usize, img.width) * img.height * 4;
            try r.rgba_scratch.resize(r.gpa, byte_count);
            const out = r.rgba_scratch.items;
            for (img.pixels, 0..) |px, i| {
                out[i * 4 + 0] = @truncate(px >> 16);
                out[i * 4 + 1] = @truncate(px >> 8);
                out[i * 4 + 2] = @truncate(px);
                out[i * 4 + 3] = @truncate(px >> 24);
            }
            var tex: [1]GLuint = undefined;
            r.gl.GenTextures(1, &tex);
            r.gl.ActiveTexture(GL_TEXTURE0);
            r.gl.BindTexture(GL_TEXTURE_2D, tex[0]);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            r.gl.PixelStorei(GL_UNPACK_ALIGNMENT, 4);
            r.gl.TexImage2D(
                GL_TEXTURE_2D,
                0,
                GL_RGBA8,
                @intCast(img.width),
                @intCast(img.height),
                0,
                GL_RGBA,
                GL_UNSIGNED_BYTE,
                out.ptr,
            );
            try r.images.put(r.gpa, img.id, tex[0]);
        };
    }

    fn ensureFbo(r: *OpenGlRenderer, w: u32, h: u32) void {
        if (r.fbo != 0 and r.fbo_w == w and r.fbo_h == h) return;
        if (r.fbo == 0) {
            var fbos: [1]GLuint = undefined;
            r.gl.GenFramebuffers(1, &fbos);
            r.fbo = fbos[0];
            var tex: [1]GLuint = undefined;
            r.gl.GenTextures(1, &tex);
            r.fbo_tex = tex[0];
        }
        r.gl.ActiveTexture(GL_TEXTURE0);
        r.gl.BindTexture(GL_TEXTURE_2D, r.fbo_tex);
        r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        r.gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, @intCast(w), @intCast(h), 0, GL_BGRA, GL_UNSIGNED_BYTE, null);

        r.gl.BindFramebuffer(GL_FRAMEBUFFER, r.fbo);
        r.gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, r.fbo_tex, 0);
        r.fbo_w = w;
        r.fbo_h = h;
    }

    /// Renders a prepared 2D `Canvas` into `target: *software.Image`, preserving
    /// existing background pixels and clipping to `damage` viewports when provided.
    pub fn record(r: *OpenGlRenderer, c: *const Canvas, target: *software.Image, damage: ?[]const Viewport) !void {
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

        try r.makeCurrent();
        r.ensureFbo(target.width, target.height);

        const full_vp: Viewport = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };
        const fallback_regions = [1]Viewport{full_vp};
        const regions = damage orelse &fallback_regions;
        const stride = target.rowStride();

        // Upload active regions from `target` into `r.fbo_tex` (flipping top-down rows to OpenGL bottom-up rows).
        r.gl.ActiveTexture(GL_TEXTURE0);
        r.gl.BindTexture(GL_TEXTURE_2D, r.fbo_tex);
        r.gl.PixelStorei(GL_UNPACK_ALIGNMENT, 4);
        for (regions) |reg| {
            const sc = full_vp.intersect(reg) orelse continue;
            const count = @as(usize, sc.width) * sc.height;
            try r.pixel_scratch.resize(r.gpa, count);
            const sx: usize = @intCast(sc.x);
            const sy: usize = @intCast(sc.y);
            for (0..sc.height) |row| {
                const gl_row = sc.height - 1 - row;
                const src = target.pixels[(sy + row) * stride + sx ..][0..sc.width];
                @memcpy(r.pixel_scratch.items[gl_row * sc.width ..][0..sc.width], src);
            }
            const gl_y: GLint = @as(i32, @intCast(target.height)) - (sc.y + @as(i32, @intCast(sc.height)));
            r.gl.TexSubImage2D(
                GL_TEXTURE_2D,
                0,
                sc.x,
                gl_y,
                @intCast(sc.width),
                @intCast(sc.height),
                GL_BGRA,
                GL_UNSIGNED_BYTE,
                r.pixel_scratch.items.ptr,
            );
        }

        const fbo_target: Target = .{ .width = target.width, .height = target.height, .fbo = r.fbo };
        try r.recordTarget(c, &fbo_target, damage);

        // Read back active regions from `r.fbo` into `target` (flipping OpenGL bottom-up rows to top-down rows).
        r.gl.BindFramebuffer(GL_FRAMEBUFFER, r.fbo);
        r.gl.PixelStorei(GL_PACK_ALIGNMENT, 4);
        for (regions) |reg| {
            const sc = full_vp.intersect(reg) orelse continue;
            const count = @as(usize, sc.width) * sc.height;
            try r.pixel_scratch.resize(r.gpa, count);
            const gl_y: GLint = @as(i32, @intCast(target.height)) - (sc.y + @as(i32, @intCast(sc.height)));
            r.gl.ReadPixels(
                sc.x,
                gl_y,
                @intCast(sc.width),
                @intCast(sc.height),
                GL_BGRA,
                GL_UNSIGNED_BYTE,
                r.pixel_scratch.items.ptr,
            );
            const dx: usize = @intCast(sc.x);
            const dy: usize = @intCast(sc.y);
            for (0..sc.height) |row| {
                const gl_row = sc.height - 1 - row;
                const src = r.pixel_scratch.items[gl_row * sc.width ..][0..sc.width];
                @memcpy(target.pixels[(dy + row) * stride + dx ..][0..sc.width], src);
            }
        }
    }

    pub fn recordTarget(r: *OpenGlRenderer, c: *const Canvas, target: *const Target, damage: ?[]const Viewport) !void {
        if (target.width == 0 or target.height == 0) return;
        r.gl.BindFramebuffer(GL_FRAMEBUFFER, target.fbo);
        r.gl.Viewport(target.origin[0], target.origin[1], @intCast(target.width), @intCast(target.height));
        r.gl.Disable(GL_DEPTH_TEST);
        r.gl.Disable(GL_CULL_FACE);
        r.gl.Enable(GL_SCISSOR_TEST);
        r.gl.BindBuffer(GL_ARRAY_BUFFER, r.vbo);

        const full_vp: Viewport = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };

        for (c.batches.items) |*b| {
            const data = std.mem.sliceAsBytes(b.floats.items);
            if (data.len == 0) continue;
            const area = if (b.clip) |clip| b.bounds.intersect(clip) orelse continue else b.bounds;
            const batch_vp = renderer_mod.scissor(area);
            if (!renderer_mod.covers(damage, batch_vp)) continue;
            if (r.cursor + data.len > r.vbo_capacity) return error.NotPrepared;

            r.gl.BufferSubData(GL_ARRAY_BUFFER, @intCast(r.cursor), @intCast(data.len), data.ptr);
            const byte_offset = r.cursor;
            r.cursor += std.mem.alignForward(usize, data.len, 16);

            switch (b.kind) {
                .@"opaque" => r.gl.Disable(GL_BLEND),
                else => {
                    r.gl.Enable(GL_BLEND);
                    r.gl.BlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                },
            }

            const prog: GLuint, const vao: GLuint, const layout: shaders.Layout = switch (b.kind) {
                .shape => .{ r.shape_prog, r.shape_vao, shaders.shape_layout },
                .solid, .@"opaque" => .{ r.solid_prog, r.solid_vao, shaders.solid_layout },
                .text => .{ r.text_prog, r.text_vao, shaders.text_layout },
                .image => .{ r.image_prog, r.text_vao, shaders.text_layout },
            };

            r.gl.UseProgram(prog);
            r.gl.BindVertexArray(vao);
            for (layout.attributes) |attr| {
                r.gl.EnableVertexAttribArray(attr.location);
                r.gl.VertexAttribPointer(
                    attr.location,
                    @intCast(attr.components),
                    GL_FLOAT,
                    GL_FALSE,
                    @intCast(layout.vertex_stride),
                    @ptrFromInt(byte_offset + attr.offset),
                );
            }

            switch (b.kind) {
                .text => {
                    r.gl.ActiveTexture(GL_TEXTURE0);
                    r.gl.BindTexture(GL_TEXTURE_2D, r.atlas_tex);
                },
                .image => {
                    const img = b.image orelse continue;
                    const tex = r.images.get(img.id) orelse return error.NotPrepared;
                    r.gl.ActiveTexture(GL_TEXTURE0);
                    r.gl.BindTexture(GL_TEXTURE_2D, tex);
                },
                else => {},
            }

            const clip_vp = if (b.clip) |clip| renderer_mod.scissor(clip) else full_vp;
            const count: GLsizei = @intCast(b.vertexCount());
            if (damage) |dmg_list| {
                for (dmg_list) |dmg| {
                    const sc = clip_vp.intersect(dmg) orelse continue;
                    r.setGlScissor(target, sc);
                    r.gl.DrawArrays(GL_TRIANGLES, 0, count);
                }
            } else {
                r.setGlScissor(target, clip_vp);
                r.gl.DrawArrays(GL_TRIANGLES, 0, count);
            }
        }
        r.gl.Disable(GL_SCISSOR_TEST);
    }

    fn setGlScissor(r: *const OpenGlRenderer, target: *const Target, vp: Viewport) void {
        if (target.top_down) {
            r.gl.Scissor(vp.x + target.origin[0], vp.y + target.origin[1], @intCast(vp.width), @intCast(vp.height));
            return;
        }
        const y_bottom = @as(i32, @intCast(target.height)) - (vp.y + @as(i32, @intCast(vp.height)));
        r.gl.Scissor(vp.x + target.origin[0], y_bottom + target.origin[1], @intCast(vp.width), @intCast(vp.height));
    }

    /// Renders a frame straight into a window's dmabuf on the GPU (see
    /// `Renderer.renderDmabuf`): only for a renderer with its own EGL
    /// context (`initDefault`) that can import dmabufs.
    pub fn renderDmabuf(r: *OpenGlRenderer, canvases: []const *const Canvas, segments: []const Segment, t: *const DmabufTarget, clear: u32, clear_rects: []const Viewport, damage: []const Viewport) !void {
        if (t.content[0] == 0 or t.content[1] == 0) return;
        const d = r.directProcs() orelse return error.Unsupported;
        // A frame needs its program (or it is drawn the CPU way).
        if (t.frame != null and r.window_prog == 0) return error.Unsupported;
        try r.prepare(canvases);
        const im = try r.importDmabuf(d, &r.targets, .{ .id = t.id, .fd = t.fd, .fourcc = t.fourcc, .modifier = t.modifier, .offset = t.offset, .stride = t.stride, .width = t.width, .height = t.height });
        const origin: [2]i32 = .{ @intCast(t.origin[0]), @intCast(t.origin[1]) };
        // The buffer's first row is the top of the window, so it is drawn
        // into top down.
        d.ClipControl(GL_UPPER_LEFT, GL_NEGATIVE_ONE_TO_ONE);
        defer d.ClipControl(GL_LOWER_LEFT, GL_NEGATIVE_ONE_TO_ONE);
        const target: Target = .{ .width = t.content[0], .height = t.content[1], .fbo = im.fbo, .top_down = true, .origin = origin };

        if (clear_rects.len > 0) {
            r.gl.BindFramebuffer(GL_FRAMEBUFFER, im.fbo);
            r.gl.Enable(GL_SCISSOR_TEST);
            const c = Color.argb(clear);
            d.ClearColor(c.r, c.g, c.b, c.a);
            const full: Viewport = .{ .width = t.content[0], .height = t.content[1] };
            for (clear_rects) |cr| {
                r.setGlScissor(&target, full.intersect(cr) orelse continue);
                d.Clear(GL_COLOR_BUFFER_BIT);
            }
            r.gl.Disable(GL_SCISSOR_TEST);
        }
        var buf: [2][renderer_mod.max_uncovered]Viewport = undefined;
        for (segments, 0..) |seg, i| switch (seg) {
            .canvas => |c| {
                // Not under a GPU draw that covers it (as `Renderer.render`).
                const dmg = renderer_mod.uncovered(&buf, damage, segments[i + 1 ..]);
                if (dmg.len == 0) continue;
                try r.recordTarget(c, &target, dmg);
            },
            .gpu => |g| {
                const area = g.area.scissor orelse g.area.viewport;
                if (!renderer_mod.covers(damage, area)) continue;
                if (g.direct) |direct| {
                    // Drawn into this frame on the GPU: no copy through the CPU.
                    const frame: DirectFrame = .{ .fbo = im.fbo, .origin = origin, .width = t.content[0], .height = t.content[1], .copy_ctx = r, .copy_dmabuf = copyDmabuf };
                    r.gl.BindFramebuffer(GL_FRAMEBUFFER, im.fbo);
                    const drawn = try direct(g.ctx, .opengl, &frame, g.area);
                    // It may have drawn with a context of its own.
                    try r.makeCurrent();
                    if (drawn) continue;
                }
                // Drawn on the CPU: what is under it is finished first, and
                // what is over it drawn after.
                d.Finish();
                var img = try t.cpu.begin(t.cpu.ctx);
                const drawn = g.f(g.ctx, @ptrCast(&img), g.area);
                t.cpu.end(t.cpu.ctx);
                try r.makeCurrent();
                try drawn;
            },
        };
        if (t.frame) |frame| r.drawFrame(d, im, t, frame, damage);
        // Drawn before the compositor shows it.
        d.Finish();
    }

    /// What drawing straight into window buffers needs, or null if it
    /// cannot (found out the first time).
    fn directProcs(r: *OpenGlRenderer) ?DirectProcs {
        if (r.direct_known) return r.direct;
        r.direct_known = true;
        const egl = r.egl orelse return null;
        const lib = if (r.egl_lib) |*l| l else return null;
        r.makeCurrent() catch return null;
        const d = DirectProcs.load(lib, &egl, r.dpy, r.gl) orelse return null;
        r.sync = SyncProcs.load(lib, &egl, r.dpy);
        r.window_prog = r.compileSpirvOrGlsl(&shaders.window_gl_spv, shaders.glsl_window_vs, shaders.glsl_window_fs) catch
            r.compileProgram(shaders.glsl_window_vs, shaders.glsl_window_fs) catch 0;
        if (r.window_prog != 0) {
            var vao: [1]GLuint = undefined;
            r.gl.GenVertexArrays(1, &vao);
            r.window_vao = vao[0];
            var vbo: [1]GLuint = undefined;
            r.gl.GenBuffers(1, &vbo);
            r.window_vbo = vbo[0];
        }
        r.direct = d;
        return d;
    }

    /// A dmabuf to import (a window's buffer, or another context's picture).
    const DmabufDesc = struct {
        id: u64,
        fd: i32,
        fourcc: u32,
        modifier: u64,
        offset: u32,
        stride: u32,
        width: u32,
        height: u32,
    };

    /// `desc` as a texture with a framebuffer, imported into `list` (made
    /// again if its size changed, in the place of the one least recently
    /// used if it is full).
    fn importDmabuf(r: *OpenGlRenderer, d: DirectProcs, list: *[max_imports]?Import, desc: DmabufDesc) !*Import {
        r.import_clock += 1;
        for (list) |*slot| if (slot.*) |*im| if (im.id == desc.id and im.width == desc.width and im.height == desc.height) {
            im.used = r.import_clock;
            return im;
        };
        var pick: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (list, 0..) |slot, i| {
            const used = if (slot) |im| im.used else 0;
            if (used < oldest) {
                oldest = used;
                pick = i;
            }
        }
        if (list[pick]) |*old| r.dropImport(d, old);
        list[pick] = null;

        const invalid_modifier: u64 = 0x00ffffffffffffff;
        const with_modifier = desc.modifier != invalid_modifier and (desc.modifier != 0 or d.modifiers);
        if (with_modifier and !d.modifiers) return error.Unsupported;
        var attribs: [17]EGLint = undefined;
        var n: usize = 0;
        for ([_]EGLint{
            EGL_WIDTH,                     @intCast(desc.width),
            EGL_HEIGHT,                    @intCast(desc.height),
            EGL_LINUX_DRM_FOURCC_EXT,      @bitCast(desc.fourcc),
            EGL_DMA_BUF_PLANE0_FD_EXT,     desc.fd,
            EGL_DMA_BUF_PLANE0_OFFSET_EXT, @intCast(desc.offset),
            EGL_DMA_BUF_PLANE0_PITCH_EXT,  @intCast(desc.stride),
        }) |a| {
            attribs[n] = a;
            n += 1;
        }
        if (with_modifier) {
            for ([_]EGLint{
                EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, @bitCast(@as(u32, @truncate(desc.modifier))),
                EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, @bitCast(@as(u32, @truncate(desc.modifier >> 32))),
            }) |a| {
                attribs[n] = a;
                n += 1;
            }
        }
        attribs[n] = EGL_NONE;
        const image = d.CreateImageKHR(r.dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, null, &attribs);
        if (image == null) return error.EglImportFailed;

        var tex: [1]GLuint = undefined;
        r.gl.GenTextures(1, &tex);
        r.gl.BindTexture(GL_TEXTURE_2D, tex[0]);
        d.EGLImageTargetTexture2DOES(GL_TEXTURE_2D, image);
        r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        r.gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        var fbo: [1]GLuint = undefined;
        r.gl.GenFramebuffers(1, &fbo);
        r.gl.BindFramebuffer(GL_FRAMEBUFFER, fbo[0]);
        r.gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex[0], 0);
        list[pick] = .{ .id = desc.id, .width = desc.width, .height = desc.height, .image = image, .tex = tex[0], .fbo = fbo[0], .used = r.import_clock };
        return &list[pick].?;
    }

    fn dropImport(r: *OpenGlRenderer, d: DirectProcs, im: *Import) void {
        r.gl.DeleteFramebuffers(1, &[1]GLuint{im.fbo});
        r.gl.DeleteTextures(1, &[1]GLuint{im.tex});
        _ = d.DestroyImageKHR(r.dpy, im.image);
    }

    /// `DirectFrame.copy_dmabuf`: blits the picture in (turning it the
    /// right way up).
    fn copyDmabuf(ctx: *anyopaque, frame: *const DirectFrame, src: *const DmabufImage, area: GpuArea) anyerror!bool {
        const r: *OpenGlRenderer = @ptrCast(@alignCast(ctx));
        r.makeCurrent() catch {
            if (src.ready_fd >= 0) renderer_mod.waitFd(src.ready_fd);
            return false;
        };
        if (src.ready_fd >= 0) r.waitSyncFile(src.ready_fd);
        const d = r.direct orelse return false;
        const s = r.importDmabuf(d, &r.sources, .{ .id = src.id, .fd = src.fd, .fourcc = src.fourcc, .modifier = src.modifier, .offset = src.offset, .stride = src.stride, .width = src.width, .height = src.height }) catch return false;
        const vp = area.viewport;
        const clipped = if (area.scissor) |c| vp.intersect(c) orelse return true else vp;
        const sc = (Viewport{ .width = frame.width, .height = frame.height }).intersect(clipped) orelse return true;
        const lx = sc.x - vp.x;
        const ly = sc.y - vp.y;
        const w: i32 = @intCast(sc.width);
        const h: i32 = @intCast(sc.height);
        const sh: i32 = @intCast(src.height);
        const src_y0 = if (src.bottom_up) sh - ly else ly;
        const src_y1 = if (src.bottom_up) sh - (ly + h) else ly + h;
        const dx = sc.x + frame.origin[0];
        const dy = sc.y + frame.origin[1];
        r.gl.Disable(GL_SCISSOR_TEST);
        r.gl.BindFramebuffer(GL_READ_FRAMEBUFFER, s.fbo);
        r.gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, frame.fbo);
        d.BlitFramebuffer(lx, src_y0, lx + w, src_y1, dx, dy, dx + w, dy + h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        r.gl.BindFramebuffer(GL_FRAMEBUFFER, frame.fbo);
        return true;
    }

    /// Takes `fd`, a sync file signalled once a picture is drawn, and has
    /// what is drawn next wait for it on the GPU; or, if it cannot, waits
    /// for it here.
    fn waitSyncFile(r: *OpenGlRenderer, fd: i32) void {
        if (r.sync) |x| if (x.WaitSyncKHR) |wait| if (x.DupNativeFenceFDANDROID != null) {
            const attribs = [_]EGLint{ EGL_SYNC_NATIVE_FENCE_FD_ANDROID, fd, EGL_NONE };
            const sync = x.CreateSyncKHR(r.dpy, EGL_SYNC_NATIVE_FENCE_ANDROID, &attribs);
            // Made, the fence has the fd.
            if (sync != null) {
                _ = wait(r.dpy, sync, 0);
                _ = x.DestroySyncKHR(r.dpy, sync);
                return;
            }
        };
        renderer_mod.waitFd(fd);
    }

    /// Draws the window's frame around the content of `im`: the shadow in
    /// the margin (once for each buffer, as it stays), and each corner,
    /// where it was repainted, rounded with the shadow under it. As the
    /// Vulkan renderer's `drawFrame`, with rows top down.
    fn drawFrame(r: *OpenGlRenderer, d: DirectProcs, im: *Import, t: *const DmabufTarget, frame: renderer_mod.WindowFrame, damage: []const Viewport) void {
        const bw: f32 = @floatFromInt(t.width);
        const bh: f32 = @floatFromInt(t.height);
        const m: f32 = @floatFromInt(t.origin[0]);
        const cw: f32 = @floatFromInt(t.content[0]);
        const ch: f32 = @floatFromInt(t.content[1]);
        const radius = frame.radius;
        const box = [4]f32{ m + cw / 2, m + ch / 2, @max(cw / 2 - radius, 0), @max(ch / 2 - radius, 0) };
        // The corners' squares, in the content's pixels.
        const corner: u32 = @min(@as(u32, @intFromFloat(@ceil(radius))) + 1, @min(t.content[0] / 2, t.content[1] / 2));
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
        var vertices: [frame_vertices * shaders.window_floats]f32 = undefined;
        var n: usize = 0;
        const quad = struct {
            fn f(out: []f32, at: *usize, v: Viewport, w: f32, h: f32, b: [4]f32, params: [4]f32) void {
                const x0: f32 = @floatFromInt(v.x);
                const y0: f32 = @floatFromInt(v.y);
                const x1 = x0 + @as(f32, @floatFromInt(v.width));
                const y1 = y0 + @as(f32, @floatFromInt(v.height));
                for ([6][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } }) |p| {
                    const o = out[at.* * shaders.window_floats ..][0..shaders.window_floats];
                    // Clip y up, as OpenGL's (the top row is +1 here).
                    o.* = .{ p[0] / w * 2 - 1, 1 - p[1] / h * 2, p[0], p[1], b[0], b[1], b[2], b[3], params[0], params[1], params[2], params[3] };
                    at.* += 1;
                }
            }
        }.f;
        const shadow_params = [4]f32{ radius, frame.scale, 1, 0 };
        const mask_params = [4]f32{ radius, frame.scale, 0, 0 };
        for (margin) |v| quad(&vertices, &n, v, bw, bh, box, shadow_params);
        for (corners) |v| {
            const bv: Viewport = .{ .x = v.x + @as(i32, @intCast(om)), .y = v.y + @as(i32, @intCast(om)), .width = v.width, .height = v.height };
            quad(&vertices, &n, bv, bw, bh, box, mask_params);
            quad(&vertices, &n, bv, bw, bh, box, shadow_params);
        }

        r.gl.BindFramebuffer(GL_FRAMEBUFFER, im.fbo);
        r.gl.Viewport(0, 0, @intCast(t.width), @intCast(t.height));
        r.gl.UseProgram(r.window_prog);
        r.gl.BindVertexArray(r.window_vao);
        r.gl.BindBuffer(GL_ARRAY_BUFFER, r.window_vbo);
        r.gl.BufferData(GL_ARRAY_BUFFER, @intCast(n * shaders.window_floats * 4), &vertices, GL_STREAM_DRAW);
        for (shaders.window_layout.attributes) |attr| {
            r.gl.EnableVertexAttribArray(attr.location);
            r.gl.VertexAttribPointer(attr.location, @intCast(attr.components), GL_FLOAT, GL_FALSE, @intCast(shaders.window_layout.vertex_stride), @ptrFromInt(attr.offset));
        }
        r.gl.Enable(GL_SCISSOR_TEST);
        r.gl.Enable(GL_BLEND);
        // Under what is there: its alpha's remainder of the shadow.
        const under = struct {
            fn f(gl: Procs) void {
                gl.BlendFuncSeparate(GL_ONE_MINUS_DST_ALPHA, GL_ONE, GL_ONE_MINUS_DST_ALPHA, GL_ONE);
            }
        }.f;
        if (!im.frame_drawn) {
            // The margin, cleared, then its shadow.
            d.ClearColor(0, 0, 0, 0);
            for (margin) |v| if (v.width > 0 and v.height > 0) {
                r.gl.Scissor(v.x, v.y, @intCast(v.width), @intCast(v.height));
                d.Clear(GL_COLOR_BUFFER_BIT);
            };
            r.gl.Scissor(0, 0, @intCast(t.width), @intCast(t.height));
            under(r.gl);
            r.gl.DrawArrays(GL_TRIANGLES, 0, 4 * 6);
            im.frame_drawn = true;
        }
        // Each corner where it was repainted: rounded (what is there times
        // its coverage), then the shadow under.
        for (corners, 0..) |c, i| for (damage) |dmg| {
            const part = c.intersect(dmg) orelse continue;
            r.gl.Scissor(part.x + @as(i32, @intCast(om)), part.y + @as(i32, @intCast(om)), @intCast(part.width), @intCast(part.height));
            const first: GLint = @intCast(4 * 6 + i * 12);
            r.gl.BlendFuncSeparate(GL_ZERO, GL_SRC_ALPHA, GL_ZERO, GL_SRC_ALPHA);
            r.gl.DrawArrays(GL_TRIANGLES, first, 6);
            under(r.gl);
            r.gl.DrawArrays(GL_TRIANGLES, first + 6, 6);
        };
        r.gl.Disable(GL_SCISSOR_TEST);
        r.gl.Disable(GL_BLEND);
    }
};

// --- Offscreen EGL + OpenGL Context for `OpenGlArea` -------------------------

const EGLDisplay = ?*anyopaque;
const EGLConfig = ?*anyopaque;
const EGLContext = ?*anyopaque;
const EGLSurface = ?*anyopaque;
const EGLNativeDisplayType = ?*anyopaque;
const EGLint = i32;
const EGLenum = c_uint;
const EGLBoolean = c_uint;

const EGL_FALSE: EGLBoolean = 0;
const EGL_DEFAULT_DISPLAY: EGLNativeDisplayType = null;
const EGL_NO_CONTEXT: EGLContext = null;
const EGL_NO_DISPLAY: EGLDisplay = null;
const EGL_NO_SURFACE: EGLSurface = null;

const EGL_ALPHA_SIZE: EGLint = 0x3021;
const EGL_BLUE_SIZE: EGLint = 0x3022;
const EGL_GREEN_SIZE: EGLint = 0x3023;
const EGL_RED_SIZE: EGLint = 0x3024;
const EGL_DEPTH_SIZE: EGLint = 0x3025;
const EGL_NONE: EGLint = 0x3038;
const EGL_SURFACE_TYPE: EGLint = 0x3033;
const EGL_PBUFFER_BIT: EGLint = 0x0001;
const EGL_RENDERABLE_TYPE: EGLint = 0x3040;
const EGL_OPENGL_BIT: EGLint = 0x0008;
const EGL_WIDTH: EGLint = 0x3057;
const EGL_HEIGHT: EGLint = 0x3056;
const EGL_CONTEXT_MAJOR_VERSION: EGLint = 0x3098;
const EGL_CONTEXT_MINOR_VERSION: EGLint = 0x30FB;
const EGL_CONTEXT_OPENGL_PROFILE_MASK: EGLint = 0x30FD;
const EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT: EGLint = 0x00000001;
const EGL_OPENGL_API: EGLenum = 0x30A2;

const EglProcs = struct {
    GetDisplay: *const fn (EGLNativeDisplayType) callconv(.c) EGLDisplay,
    Initialize: *const fn (EGLDisplay, ?*EGLint, ?*EGLint) callconv(.c) EGLBoolean,
    Terminate: *const fn (EGLDisplay) callconv(.c) EGLBoolean,
    BindAPI: *const fn (EGLenum) callconv(.c) EGLBoolean,
    ChooseConfig: *const fn (EGLDisplay, [*]const EGLint, [*]EGLConfig, EGLint, *EGLint) callconv(.c) EGLBoolean,
    CreatePbufferSurface: *const fn (EGLDisplay, EGLConfig, [*]const EGLint) callconv(.c) EGLSurface,
    DestroySurface: *const fn (EGLDisplay, EGLSurface) callconv(.c) EGLBoolean,
    CreateContext: *const fn (EGLDisplay, EGLConfig, EGLContext, [*]const EGLint) callconv(.c) EGLContext,
    DestroyContext: *const fn (EGLDisplay, EGLContext) callconv(.c) EGLBoolean,
    MakeCurrent: *const fn (EGLDisplay, EGLSurface, EGLSurface, EGLContext) callconv(.c) EGLBoolean,
    GetProcAddress: *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque,

    fn load(lib: *std.DynLib) !EglProcs {
        var p: EglProcs = undefined;
        inline for (@typeInfo(EglProcs).@"struct".field_names) |field_name| {
            const name: [:0]const u8 = "egl" ++ field_name;
            @field(p, field_name) = lib.lookup(@FieldType(EglProcs, field_name), name) orelse return error.MissingEglFunction;
        }
        return p;
    }
};

const EGLImageKHR = ?*anyopaque;
const EGL_GL_RENDERBUFFER_KHR: EGLenum = 0x30B9;
const EGL_LINUX_DMA_BUF_EXT: EGLenum = 0x3270;
const EGL_LINUX_DRM_FOURCC_EXT: EGLint = 0x3271;
const EGL_DMA_BUF_PLANE0_FD_EXT: EGLint = 0x3272;
const EGL_DMA_BUF_PLANE0_OFFSET_EXT: EGLint = 0x3273;
const EGL_DMA_BUF_PLANE0_PITCH_EXT: EGLint = 0x3274;
const EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT: EGLint = 0x3443;
const EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT: EGLint = 0x3444;

/// The display's EGL extensions, or null if they cannot be had.
fn eglExtensions(lib: *std.DynLib, dpy: EGLDisplay) ?[]const u8 {
    const query = lib.lookup(*const fn (EGLDisplay, EGLint) callconv(.c) ?[*:0]const u8, "eglQueryString") orelse return null;
    return std.mem.span(query(dpy, EGL_EXTENSIONS) orelse return null);
}

/// Whether `name` is in `list`, a space separated list of extensions.
fn hasExtension(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |e| if (std.mem.eql(u8, e, name)) return true;
    return false;
}

const EGLSyncKHR = ?*anyopaque;
const EGLTimeKHR = u64;
const EGL_EXTENSIONS: EGLint = 0x3055;
const EGL_SYNC_FENCE_KHR: EGLenum = 0x30F9;
const EGL_SYNC_NATIVE_FENCE_ANDROID: EGLenum = 0x3144;
const EGL_SYNC_NATIVE_FENCE_FD_ANDROID: EGLint = 0x3145;
const EGL_NO_NATIVE_FENCE_FD_ANDROID: EGLint = -1;
const EGL_SYNC_FLUSH_COMMANDS_BIT_KHR: EGLint = 0x0001;
const EGL_FOREVER_KHR: EGLTimeKHR = std.math.maxInt(u64);

/// GPU work that a scene waits for before it is drawn (as its `wait`): done
/// once `sync`, an EGL fence on the same display, is signalled. It is made
/// after the work, on the context that did it (`OffscreenContext.createFence`),
/// and must stay until the scene has been drawn.
pub const Wait = struct {
    sync: ?*anyopaque,
};

/// EGL fences (`EGL_KHR_fence_sync`), waited for on the GPU if EGL can
/// (`EGL_KHR_wait_sync`), and given as sync files if it can
/// (`EGL_ANDROID_native_fence_sync`).
const SyncProcs = struct {
    CreateSyncKHR: *const fn (EGLDisplay, EGLenum, ?[*]const EGLint) callconv(.c) EGLSyncKHR,
    DestroySyncKHR: *const fn (EGLDisplay, EGLSyncKHR) callconv(.c) EGLBoolean,
    ClientWaitSyncKHR: *const fn (EGLDisplay, EGLSyncKHR, EGLint, EGLTimeKHR) callconv(.c) EGLint,
    WaitSyncKHR: ?*const fn (EGLDisplay, EGLSyncKHR, EGLint) callconv(.c) EGLint,
    DupNativeFenceFDANDROID: ?*const fn (EGLDisplay, EGLSyncKHR) callconv(.c) EGLint,

    /// What `dpy` has, or null without fences.
    fn load(lib: *std.DynLib, egl: *const EglProcs, dpy: EGLDisplay) ?SyncProcs {
        const extensions = eglExtensions(lib, dpy) orelse return null;
        if (!hasExtension(extensions, "EGL_KHR_fence_sync")) return null;
        var p: SyncProcs = .{
            .CreateSyncKHR = @ptrCast(@alignCast(egl.GetProcAddress("eglCreateSyncKHR") orelse return null)),
            .DestroySyncKHR = @ptrCast(@alignCast(egl.GetProcAddress("eglDestroySyncKHR") orelse return null)),
            .ClientWaitSyncKHR = @ptrCast(@alignCast(egl.GetProcAddress("eglClientWaitSyncKHR") orelse return null)),
            .WaitSyncKHR = null,
            .DupNativeFenceFDANDROID = null,
        };
        if (hasExtension(extensions, "EGL_KHR_wait_sync")) p.WaitSyncKHR = @ptrCast(@alignCast(egl.GetProcAddress("eglWaitSyncKHR")));
        if (hasExtension(extensions, "EGL_ANDROID_native_fence_sync")) p.DupNativeFenceFDANDROID = @ptrCast(@alignCast(egl.GetProcAddress("eglDupNativeFenceFDANDROID")));
        return p;
    }
};

/// Exporting a renderbuffer as a dmabuf (`EGL_KHR_gl_renderbuffer_image`,
/// `EGL_MESA_image_dma_buf_export`), if EGL has them.
const ExportProcs = struct {
    CreateImageKHR: *const fn (EGLDisplay, EGLContext, EGLenum, ?*anyopaque, [*]const EGLint) callconv(.c) EGLImageKHR,
    DestroyImageKHR: *const fn (EGLDisplay, EGLImageKHR) callconv(.c) EGLBoolean,
    ExportDMABUFImageQueryMESA: *const fn (EGLDisplay, EGLImageKHR, *c_int, *c_int, *u64) callconv(.c) EGLBoolean,
    ExportDMABUFImageMESA: *const fn (EGLDisplay, EGLImageKHR, *c_int, *EGLint, *EGLint) callconv(.c) EGLBoolean,

    fn load(egl: *const EglProcs) ?ExportProcs {
        var x: ExportProcs = undefined;
        inline for (@typeInfo(ExportProcs).@"struct".field_names) |field_name| {
            const sym = egl.GetProcAddress("egl" ++ field_name) orelse return null;
            @field(x, field_name) = @ptrCast(@alignCast(sym));
        }
        return x;
    }
};

/// Full OpenGL 3.3+ / 4.6 Core function table available on `OpenGlContext.gl`.
pub const ContextProcs = struct {
    GetIntegerv: GetIntegervFn,
    GetStringi: GetStringiFn,
    Enable: *const fn (GLenum) callconv(.c) void,
    Disable: *const fn (GLenum) callconv(.c) void,
    BlendFuncSeparate: *const fn (GLenum, GLenum, GLenum, GLenum) callconv(.c) void,
    Viewport: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void,
    Scissor: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void,
    ClearColor: *const fn (GLfloat, GLfloat, GLfloat, GLfloat) callconv(.c) void,
    Clear: *const fn (GLbitfield) callconv(.c) void,
    DepthFunc: *const fn (GLenum) callconv(.c) void,
    CullFace: *const fn (GLenum) callconv(.c) void,
    FrontFace: *const fn (GLenum) callconv(.c) void,
    BindFramebuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    GenFramebuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteFramebuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    GenRenderbuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteRenderbuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    BindRenderbuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    RenderbufferStorage: *const fn (GLenum, GLenum, GLsizei, GLsizei) callconv(.c) void,
    RenderbufferStorageMultisample: *const fn (GLenum, GLsizei, GLenum, GLsizei, GLsizei) callconv(.c) void,
    FramebufferRenderbuffer: *const fn (GLenum, GLenum, GLenum, GLuint) callconv(.c) void,
    BlitFramebuffer: *const fn (GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum) callconv(.c) void,
    Finish: *const fn () callconv(.c) void,
    Flush: *const fn () callconv(.c) void,
    ReadPixels: *const fn (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, *anyopaque) callconv(.c) void,
    GenBuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteBuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    BindBuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    BindBufferBase: *const fn (GLenum, GLuint, GLuint) callconv(.c) void,
    BufferData: *const fn (GLenum, GLsizeiptr, ?*const anyopaque, GLenum) callconv(.c) void,
    BufferSubData: *const fn (GLenum, GLintptr, GLsizeiptr, ?*const anyopaque) callconv(.c) void,
    GenVertexArrays: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteVertexArrays: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    BindVertexArray: *const fn (GLuint) callconv(.c) void,
    EnableVertexAttribArray: *const fn (GLuint) callconv(.c) void,
    VertexAttribPointer: *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) callconv(.c) void,
    CreateShader: *const fn (GLenum) callconv(.c) GLuint,
    DeleteShader: *const fn (GLuint) callconv(.c) void,
    ShaderSource: *const fn (GLuint, GLsizei, [*]const [*:0]const u8, ?[*]const GLint) callconv(.c) void,
    CompileShader: *const fn (GLuint) callconv(.c) void,
    GetShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    CreateProgram: *const fn () callconv(.c) GLuint,
    DeleteProgram: *const fn (GLuint) callconv(.c) void,
    AttachShader: *const fn (GLuint, GLuint) callconv(.c) void,
    LinkProgram: *const fn (GLuint) callconv(.c) void,
    GetProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    UseProgram: *const fn (GLuint) callconv(.c) void,
    GetUniformLocation: *const fn (GLuint, [*:0]const u8) callconv(.c) GLint,
    GetUniformBlockIndex: *const fn (GLuint, [*:0]const u8) callconv(.c) GLuint,
    UniformBlockBinding: *const fn (GLuint, GLuint, GLuint) callconv(.c) void,
    Uniform1i: *const fn (GLint, GLint) callconv(.c) void,
    Uniform1f: *const fn (GLint, GLfloat) callconv(.c) void,
    Uniform2f: *const fn (GLint, GLfloat, GLfloat) callconv(.c) void,
    Uniform3f: *const fn (GLint, GLfloat, GLfloat, GLfloat) callconv(.c) void,
    Uniform4f: *const fn (GLint, GLfloat, GLfloat, GLfloat, GLfloat) callconv(.c) void,
    Uniform4fv: *const fn (GLint, GLsizei, [*]const GLfloat) callconv(.c) void,
    UniformMatrix4fv: *const fn (GLint, GLsizei, GLboolean, [*]const GLfloat) callconv(.c) void,
    GenTextures: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    DeleteTextures: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    ActiveTexture: *const fn (GLenum) callconv(.c) void,
    BindTexture: *const fn (GLenum, GLuint) callconv(.c) void,
    PixelStorei: *const fn (GLenum, GLint) callconv(.c) void,
    TexParameteri: *const fn (GLenum, GLenum, GLint) callconv(.c) void,
    TexImage2D: *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    TexSubImage2D: *const fn (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    DrawArrays: *const fn (GLenum, GLint, GLsizei) callconv(.c) void,
    DrawElements: *const fn (GLenum, GLsizei, GLenum, ?*const anyopaque) callconv(.c) void,

    // Optional OpenGL 4.6 / GL_ARB_gl_spirv entry points
    ShaderBinary: ?ShaderBinaryFn = null,
    SpecializeShader: ?SpecializeShaderFn = null,

    pub fn load(get_proc: GetProcAddress) !ContextProcs {
        var p: ContextProcs = undefined;
        const info = @typeInfo(ContextProcs).@"struct";
        inline for (info.field_names, info.field_types) |field_name, FieldType| {
            if (@typeInfo(FieldType) == .optional) {
                @field(p, field_name) = null;
            } else {
                const name: [*:0]const u8 = "gl" ++ field_name;
                const sym = get_proc(name) orelse return error.MissingGlFunction;
                @field(p, field_name) = @ptrCast(@alignCast(sym));
            }
        }
        if (get_proc("glShaderBinary")) |sym| p.ShaderBinary = @ptrCast(@alignCast(sym));
        if (get_proc("glSpecializeShader")) |sym| {
            p.SpecializeShader = @ptrCast(@alignCast(sym));
        } else if (get_proc("glSpecializeShaderARB")) |sym| {
            p.SpecializeShader = @ptrCast(@alignCast(sym));
        }
        return p;
    }
};

/// Managed offscreen OpenGL Core context with configurable MSAA framebuffer,
/// native OpenGL 4.6 / `GL_ARB_gl_spirv` support (with GLSL fallback), and
/// automatic resolve/readback for `OpenGlArea`.
pub const OffscreenContext = struct {
    gpa: std.mem.Allocator,
    egl_lib: std.DynLib,
    egl: EglProcs,
    dpy: EGLDisplay = null,
    surf: EGLSurface = null,
    ctx: EGLContext = null,
    gl: ContextProcs = undefined,
    spirv_supported: bool = false,
    ubo: GLuint = 0,
    width: u32 = 0,
    height: u32 = 0,
    msaa_fbo: GLuint = 0,
    msaa_color_rb: GLuint = 0,
    msaa_depth_rb: GLuint = 0,
    resolve_fbo: GLuint = 0,
    resolve_color_rb: GLuint = 0,
    fbo_w: u32 = 0,
    fbo_h: u32 = 0,
    fbo_samples: u8 = 0,
    active_pipeline: Pipeline = .{},
    scratch: std.ArrayList(u32) = .empty,
    /// The resolved scene exported as a dmabuf (`renderToDmabuf`), and
    /// what that needs; `export_failed` once it cannot be.
    export_procs: ?ExportProcs = null,
    export_image: EGLImageKHR = null,
    exported: ?DmabufImage = null,
    export_id: u64 = 0,
    export_failed: bool = false,
    /// Fences, if EGL has them (for `Wait`, `createFence`, and a dmabuf's
    /// `ready_fd`).
    sync: ?SyncProcs = null,
    /// Its GPU's DRM render node, if EGL says.
    drm: ?DrmNode = null,

    pub const ubo_capacity: usize = 256;

    pub const Buffer = struct {
        id: GLuint = 0,
    };

    pub const PipelineDesc = struct {
        /// Optional SPIR-V binary (`vertex` + `fragment` entry points). Used when `supportsSpirv()` is true.
        shader_spv: ?[]align(4) const u8 = null,
        /// Optional GLSL fallback vertex shader source.
        vs_source: ?[:0]const u8 = null,
        /// Optional GLSL fallback fragment shader source.
        fs_source: ?[:0]const u8 = null,
        vertex_stride: u32,
        attributes: []const shaders.Attribute,
        cull_back: bool = true,
        front_ccw: bool = true,
        depth_test: bool = true,
        blend: bool = false,
    };

    pub const Pipeline = struct {
        prog: GLuint = 0,
        vao: GLuint = 0,
        vertex_stride: u32 = 0,
        attrs: [8]shaders.Attribute = undefined,
        attr_count: usize = 0,
        cull_back: bool = true,
        front_ccw: bool = true,
        depth_test: bool = true,
        blend: bool = false,
    };

    /// A context of its own. It is current on the calling thread.
    pub fn init(gpa: std.mem.Allocator) !OffscreenContext {
        return initWith(gpa, null, EGL_NO_CONTEXT);
    }

    /// A context sharing what is made on it (textures, buffers) with
    /// `share`'s: for drawing on another thread (a context is current on
    /// one thread at a time) what a scene drawn with `share` shows. It is
    /// current on the calling thread.
    pub fn initSharing(gpa: std.mem.Allocator, share: *const OffscreenContext) !OffscreenContext {
        return initWith(gpa, null, share.ctx);
    }

    /// A context sharing what is made on it with the OpenGL renderer's
    /// (`OpenGlRenderer.sharedDisplay`). It is current on the calling thread.
    pub fn initShared(gpa: std.mem.Allocator, shared: SharedDisplay) !OffscreenContext {
        return initWith(gpa, null, shared.context);
    }

    /// A context of its own on the GPU of `node` (another API's, as the
    /// Vulkan renderer's `SharedDevice.drm`), if EGL can choose one; or else
    /// (or if `node` is null) on the default display's. It is current on the
    /// calling thread.
    pub fn initOnDevice(gpa: std.mem.Allocator, node: ?DrmNode) !OffscreenContext {
        return initWith(gpa, node, EGL_NO_CONTEXT);
    }

    fn initWith(gpa: std.mem.Allocator, node: ?DrmNode, share_ctx: EGLContext) !OffscreenContext {
        var egl_lib = std.DynLib.open("libEGL.so.1") catch try std.DynLib.open("libEGL.so");
        errdefer egl_lib.close();
        const egl = try EglProcs.load(&egl_lib);

        // A GPU's display has no surfaces: its contexts are made current
        // without one.
        const device_dpy: EGLDisplay = if (node) |n| deviceDisplay(&egl_lib, &egl, n) else null;
        const surfaceless = device_dpy != null;
        const dpy = if (surfaceless) device_dpy else egl.GetDisplay(EGL_DEFAULT_DISPLAY);
        if (dpy == EGL_NO_DISPLAY) return error.NoEglDisplay;
        if (egl.Initialize(dpy, null, null) == EGL_FALSE) return error.EglInitFailed;
        const drm = displayNode(&egl_lib, &egl, dpy);

        if (egl.BindAPI(EGL_OPENGL_API) == EGL_FALSE) return error.EglBindApiFailed;

        const cfg_attribs = [_]EGLint{
            EGL_SURFACE_TYPE,    if (surfaceless) 0 else EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
            EGL_RED_SIZE,        8,
            EGL_GREEN_SIZE,      8,
            EGL_BLUE_SIZE,       8,
            EGL_ALPHA_SIZE,      8,
            EGL_DEPTH_SIZE,      24,
            EGL_NONE,
        };
        var config: EGLConfig = null;
        var num_configs: EGLint = 0;
        if (egl.ChooseConfig(dpy, &cfg_attribs, @ptrCast(&config), 1, &num_configs) == EGL_FALSE or num_configs == 0) {
            return error.EglChooseConfigFailed;
        }

        const pbuf_attribs = [_]EGLint{ EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
        const surf = if (surfaceless) EGL_NO_SURFACE else egl.CreatePbufferSurface(dpy, config, &pbuf_attribs);
        errdefer if (surf != EGL_NO_SURFACE) {
            _ = egl.DestroySurface(dpy, surf);
        };

        // Request OpenGL 4.6 Core first (native SPIR-V support), falling back to 4.5 and 3.3 Core.
        const versions = [_][2]EGLint{ .{ 4, 6 }, .{ 4, 5 }, .{ 3, 3 } };
        var ctx: EGLContext = EGL_NO_CONTEXT;
        for (versions) |ver| {
            const ctx_attribs = [_]EGLint{
                EGL_CONTEXT_MAJOR_VERSION,       ver[0],
                EGL_CONTEXT_MINOR_VERSION,       ver[1],
                EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
                EGL_NONE,
            };
            ctx = egl.CreateContext(dpy, config, share_ctx, &ctx_attribs);
            if (ctx != EGL_NO_CONTEXT) break;
        }
        if (ctx == EGL_NO_CONTEXT) return error.EglCreateContextFailed;
        errdefer _ = egl.DestroyContext(dpy, ctx);

        if (egl.MakeCurrent(dpy, surf, surf, ctx) == EGL_FALSE) return error.EglMakeCurrentFailed;

        const gl = try ContextProcs.load(egl.GetProcAddress);
        const spirv_supported = querySpirvSupport(gl.GetIntegerv, gl.GetStringi, gl.ShaderBinary, gl.SpecializeShader);

        var ubo: [1]GLuint = undefined;
        gl.GenBuffers(1, &ubo);
        gl.BindBuffer(GL_UNIFORM_BUFFER, ubo[0]);
        gl.BufferData(GL_UNIFORM_BUFFER, ubo_capacity, null, GL_DYNAMIC_DRAW);
        gl.BindBufferBase(GL_UNIFORM_BUFFER, 0, ubo[0]);

        return .{
            .gpa = gpa,
            .egl_lib = egl_lib,
            .egl = egl,
            .dpy = dpy,
            .surf = surf,
            .ctx = ctx,
            .gl = gl,
            .spirv_supported = spirv_supported,
            .ubo = ubo[0],
            .sync = SyncProcs.load(&egl_lib, &egl, dpy),
            .drm = drm,
        };
    }

    pub fn deinit(self: *OffscreenContext) void {
        self.scratch.deinit(self.gpa);
        self.dropExport();
        if (self.dpy != EGL_NO_DISPLAY) {
            // What it made is deleted in it, if it can be current here (if it
            // is another thread's, it goes with it once that lets it go).
            if (self.egl.MakeCurrent(self.dpy, self.surf, self.surf, self.ctx) != EGL_FALSE) {
                if (self.ubo != 0) {
                    const bufs = [1]GLuint{self.ubo};
                    self.gl.DeleteBuffers(1, &bufs);
                }
                if (self.msaa_fbo != 0) {
                    const fbos = [2]GLuint{ self.msaa_fbo, self.resolve_fbo };
                    self.gl.DeleteFramebuffers(2, &fbos);
                    const rbs = [3]GLuint{ self.msaa_color_rb, self.msaa_depth_rb, self.resolve_color_rb };
                    self.gl.DeleteRenderbuffers(3, &rbs);
                }
                _ = self.egl.MakeCurrent(self.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            }
            if (self.ctx != EGL_NO_CONTEXT) _ = self.egl.DestroyContext(self.dpy, self.ctx);
            if (self.surf != EGL_NO_SURFACE) _ = self.egl.DestroySurface(self.dpy, self.surf);
            // Not terminated: the display is the process's, shared with
            // the renderer and any other context on it, which terminating
            // it would end too.
            self.dpy = EGL_NO_DISPLAY;
        }
        self.egl_lib.close();
    }

    /// Makes it the calling thread's context. It fails if it is another
    /// thread's: a context is current on one thread at a time (for drawing
    /// on another, make one sharing with it: `initSharing`).
    pub fn makeCurrent(self: *const OffscreenContext) !void {
        if (self.egl.MakeCurrent(self.dpy, self.surf, self.surf, self.ctx) == EGL_FALSE) return error.EglMakeCurrentFailed;
    }

    /// Lets the calling thread's context go (this one, if it is current
    /// here), so that another thread can make it current.
    pub fn release(self: *const OffscreenContext) void {
        _ = self.egl.MakeCurrent(self.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }

    /// The DRM render node of its GPU, or null if EGL cannot say.
    pub fn drmNode(self: *const OffscreenContext) ?DrmNode {
        return self.drm;
    }

    /// A fence after what was drawn with it so far, for a scene drawn on
    /// another context to wait for (its `wait`). The context must be the
    /// calling thread's. Destroy it (`destroyFence`) once the scene has
    /// been drawn.
    pub fn createFence(self: *const OffscreenContext) !Wait {
        const x = self.sync orelse return error.Unsupported;
        try self.makeCurrent();
        const sync = x.CreateSyncKHR(self.dpy, EGL_SYNC_FENCE_KHR, null);
        if (sync == null) return error.EglCreateSyncFailed;
        // Sent to the GPU, so that another context's wait for it ends.
        self.gl.Flush();
        return .{ .sync = sync };
    }

    pub fn destroyFence(self: *const OffscreenContext, w: Wait) void {
        if (self.sync) |x| _ = x.DestroySyncKHR(self.dpy, w.sync);
    }

    /// Has what is drawn next wait for `w`: on the GPU if EGL can, or else
    /// here.
    fn waitFor(self: *const OffscreenContext, w: Wait) !void {
        const x = self.sync orelse return error.Unsupported;
        if (x.WaitSyncKHR) |wait| {
            if (wait(self.dpy, w.sync, 0) != EGL_FALSE) return;
        }
        _ = x.ClientWaitSyncKHR(self.dpy, w.sync, EGL_SYNC_FLUSH_COMMANDS_BIT_KHR, EGL_FOREVER_KHR);
    }

    /// A sync file signalled once what was drawn so far is done, or -1 if
    /// EGL cannot make one.
    fn fenceFd(self: *const OffscreenContext) i32 {
        const x = self.sync orelse return -1;
        const dup = x.DupNativeFenceFDANDROID orelse return -1;
        const attribs = [_]EGLint{ EGL_SYNC_NATIVE_FENCE_FD_ANDROID, EGL_NO_NATIVE_FENCE_FD_ANDROID, EGL_NONE };
        const sync = x.CreateSyncKHR(self.dpy, EGL_SYNC_NATIVE_FENCE_ANDROID, &attribs);
        if (sync == null) return -1;
        defer _ = x.DestroySyncKHR(self.dpy, sync);
        // The fence has a sync file once it is sent to the GPU.
        self.gl.Flush();
        const fd = dup(self.dpy, sync);
        return if (fd >= 0) fd else -1;
    }

    /// Returns true when the active OpenGL context supports SPIR-V shaders
    /// natively (OpenGL 4.6 Core or `GL_ARB_gl_spirv`).
    pub fn supportsSpirv(self: *const OffscreenContext) bool {
        return self.spirv_supported;
    }

    pub fn aspect(self: *const OffscreenContext) f32 {
        if (self.height == 0) return 1.0;
        return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
    }

    /// Creates a graphics pipeline using native SPIR-V (`glShaderBinary` +
    /// `glSpecializeShader`) when `supportsSpirv()` is true and `shader_spv` is
    /// provided, falling back to `vs_source` / `fs_source` GLSL shaders.
    pub fn createPipeline(self: *OffscreenContext, desc: PipelineDesc) !Pipeline {
        try self.makeCurrent();
        const prog: GLuint = blk: {
            if (self.spirv_supported) {
                if (desc.shader_spv) |spv| {
                    if (self.compileSpirvProgram(spv)) |p| {
                        break :blk p;
                    } else |_| {
                        self.spirv_supported = false;
                    }
                }
            }
            if (desc.vs_source != null and desc.fs_source != null) {
                break :blk try self.compileProgram(desc.vs_source.?, desc.fs_source.?);
            }
            return error.GlShaderCompileFailed;
        };
        errdefer self.gl.DeleteProgram(prog);

        var vao: [1]GLuint = undefined;
        self.gl.GenVertexArrays(1, &vao);

        var p: Pipeline = .{
            .prog = prog,
            .vao = vao[0],
            .vertex_stride = desc.vertex_stride,
            .attr_count = @min(desc.attributes.len, 8),
            .cull_back = desc.cull_back,
            .front_ccw = desc.front_ccw,
            .depth_test = desc.depth_test,
            .blend = desc.blend,
        };
        for (desc.attributes[0..p.attr_count], 0..) |a, i| p.attrs[i] = a;
        return p;
    }

    pub fn destroyPipeline(self: *const OffscreenContext, p: Pipeline) void {
        // Another thread's context: it goes with it.
        self.makeCurrent() catch return;
        if (p.vao != 0) {
            const vaos = [1]GLuint{p.vao};
            self.gl.DeleteVertexArrays(1, &vaos);
        }
        if (p.prog != 0) self.gl.DeleteProgram(p.prog);
    }

    pub fn createVertexBuffer(self: *const OffscreenContext, comptime T: type, items: []const T) !Buffer {
        try self.makeCurrent();
        var id: [1]GLuint = undefined;
        self.gl.GenBuffers(1, &id);
        self.gl.BindBuffer(GL_ARRAY_BUFFER, id[0]);
        self.gl.BufferData(GL_ARRAY_BUFFER, @intCast(items.len * @sizeOf(T)), items.ptr, GL_STATIC_DRAW);
        return .{ .id = id[0] };
    }

    pub fn createIndexBuffer(self: *const OffscreenContext, indices: []const u16) !Buffer {
        try self.makeCurrent();
        var id: [1]GLuint = undefined;
        self.gl.GenBuffers(1, &id);
        self.gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, id[0]);
        self.gl.BufferData(GL_ELEMENT_ARRAY_BUFFER, @intCast(indices.len * @sizeOf(u16)), indices.ptr, GL_STATIC_DRAW);
        return .{ .id = id[0] };
    }

    pub fn destroyBuffer(self: *const OffscreenContext, buf: Buffer) void {
        // Another thread's context: it goes with it.
        self.makeCurrent() catch return;
        if (buf.id != 0) {
            const ids = [1]GLuint{buf.id};
            self.gl.DeleteBuffers(1, &ids);
        }
    }

    pub fn bindPipeline(self: *OffscreenContext, p: Pipeline) void {
        self.active_pipeline = p;
        self.gl.UseProgram(p.prog);
        self.gl.BindVertexArray(p.vao);
        self.gl.BindBufferBase(GL_UNIFORM_BUFFER, 0, self.ubo);
        if (p.depth_test) self.gl.Enable(GL_DEPTH_TEST) else self.gl.Disable(GL_DEPTH_TEST);
        if (p.cull_back) {
            self.gl.Enable(GL_CULL_FACE);
            self.gl.CullFace(GL_BACK);
        } else {
            self.gl.Disable(GL_CULL_FACE);
        }
        self.gl.FrontFace(if (p.front_ccw) GL_CCW else GL_CW);
        if (p.blend) {
            self.gl.Enable(GL_BLEND);
            self.gl.BlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        } else {
            self.gl.Disable(GL_BLEND);
        }
    }

    pub fn setUniforms(self: *const OffscreenContext, comptime T: type, value: *const T) void {
        std.debug.assert(@sizeOf(T) <= ubo_capacity);
        self.gl.BindBuffer(GL_UNIFORM_BUFFER, self.ubo);
        self.gl.BufferSubData(GL_UNIFORM_BUFFER, 0, @sizeOf(T), value);
    }

    pub fn bindVertexBuffer(self: *const OffscreenContext, buf: Buffer) void {
        const p = &self.active_pipeline;
        self.gl.BindBuffer(GL_ARRAY_BUFFER, buf.id);
        for (p.attrs[0..p.attr_count]) |attr| {
            self.gl.EnableVertexAttribArray(attr.location);
            self.gl.VertexAttribPointer(
                attr.location,
                @intCast(attr.components),
                GL_FLOAT,
                GL_FALSE,
                @intCast(p.vertex_stride),
                @ptrFromInt(attr.offset),
            );
        }
    }

    pub fn bindIndexBuffer16(self: *const OffscreenContext, buf: Buffer) void {
        self.gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, buf.id);
    }

    pub fn drawIndexed(self: *const OffscreenContext, index_count: u32) void {
        self.gl.DrawElements(GL_TRIANGLES, @intCast(index_count), GL_UNSIGNED_SHORT, null);
    }

    pub fn compileSpirvProgram(self: *const OffscreenContext, spv: []align(4) const u8) !GLuint {
        const vs = try self.compileSpirvShader(GL_VERTEX_SHADER, spv, "vertex");
        defer self.gl.DeleteShader(vs);
        const fs = try self.compileSpirvShader(GL_FRAGMENT_SHADER, spv, "fragment");
        defer self.gl.DeleteShader(fs);
        const prog = self.gl.CreateProgram();
        if (prog == 0) return error.GlCreateProgramFailed;
        errdefer self.gl.DeleteProgram(prog);
        self.gl.AttachShader(prog, vs);
        self.gl.AttachShader(prog, fs);
        self.gl.LinkProgram(prog);
        var ok: GLint = 0;
        self.gl.GetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.GlShaderLinkFailed;
        return prog;
    }

    pub fn compileSpirvShader(self: *const OffscreenContext, kind: GLenum, spv: []align(4) const u8, entry: [*:0]const u8) !GLuint {
        const shader_bin = self.gl.ShaderBinary orelse return error.SpirvNotSupported;
        const spec_shader = self.gl.SpecializeShader orelse return error.SpirvNotSupported;
        const sh = self.gl.CreateShader(kind);
        if (sh == 0) return error.GlCreateShaderFailed;
        errdefer self.gl.DeleteShader(sh);
        const shaders_arr = [1]GLuint{sh};
        shader_bin(1, &shaders_arr, GL_SHADER_BINARY_FORMAT_SPIR_V, spv.ptr, @intCast(spv.len));
        spec_shader(sh, entry, 0, null, null);
        var ok: GLint = 0;
        self.gl.GetShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (ok == 0) return error.GlShaderCompileFailed;
        return sh;
    }

    pub fn compileProgram(self: *const OffscreenContext, vs_src: [:0]const u8, fs_src: [:0]const u8) !GLuint {
        const vs = try self.compileShader(GL_VERTEX_SHADER, vs_src);
        defer self.gl.DeleteShader(vs);
        const fs = try self.compileShader(GL_FRAGMENT_SHADER, fs_src);
        defer self.gl.DeleteShader(fs);
        const prog = self.gl.CreateProgram();
        if (prog == 0) return error.GlCreateProgramFailed;
        errdefer self.gl.DeleteProgram(prog);
        self.gl.AttachShader(prog, vs);
        self.gl.AttachShader(prog, fs);
        self.gl.LinkProgram(prog);
        var ok: GLint = 0;
        self.gl.GetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.GlShaderLinkFailed;
        const blk_idx = self.gl.GetUniformBlockIndex(prog, "Uniforms");
        if (blk_idx != GL_INVALID_INDEX) {
            self.gl.UniformBlockBinding(prog, blk_idx, 0);
        }
        return prog;
    }

    pub fn compileShader(self: *const OffscreenContext, kind: GLenum, src: [:0]const u8) !GLuint {
        const sh = self.gl.CreateShader(kind);
        if (sh == 0) return error.GlCreateShaderFailed;
        errdefer self.gl.DeleteShader(sh);
        const ptrs = [1][*:0]const u8{src.ptr};
        self.gl.ShaderSource(sh, 1, &ptrs, null);
        self.gl.CompileShader(sh);
        var ok: GLint = 0;
        self.gl.GetShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (ok == 0) return error.GlShaderCompileFailed;
        return sh;
    }

    fn ensureFbo(self: *OffscreenContext, w: u32, h: u32, samples: u8) void {
        const clamped_samples: u8 = switch (samples) {
            0, 1 => 1,
            2, 3 => 2,
            4...7 => 4,
            else => 8,
        };
        if (self.fbo_w == w and self.fbo_h == h and self.fbo_samples == clamped_samples and self.msaa_fbo != 0) return;
        if (self.msaa_fbo == 0) {
            var fbos: [2]GLuint = undefined;
            self.gl.GenFramebuffers(2, &fbos);
            self.msaa_fbo = fbos[0];
            self.resolve_fbo = fbos[1];
            var rbs: [3]GLuint = undefined;
            self.gl.GenRenderbuffers(3, &rbs);
            self.msaa_color_rb = rbs[0];
            self.msaa_depth_rb = rbs[1];
            self.resolve_color_rb = rbs[2];
        }
        const sw: GLsizei = @intCast(w);
        const sh: GLsizei = @intCast(h);

        self.gl.BindFramebuffer(GL_FRAMEBUFFER, self.msaa_fbo);
        self.gl.BindRenderbuffer(GL_RENDERBUFFER, self.msaa_color_rb);
        if (clamped_samples <= 1) {
            self.gl.RenderbufferStorage(GL_RENDERBUFFER, @intCast(GL_RGBA8), sw, sh);
        } else {
            self.gl.RenderbufferStorageMultisample(GL_RENDERBUFFER, @intCast(clamped_samples), @intCast(GL_RGBA8), sw, sh);
        }
        self.gl.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, self.msaa_color_rb);

        self.gl.BindRenderbuffer(GL_RENDERBUFFER, self.msaa_depth_rb);
        if (clamped_samples <= 1) {
            self.gl.RenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, sw, sh);
        } else {
            self.gl.RenderbufferStorageMultisample(GL_RENDERBUFFER, @intCast(clamped_samples), GL_DEPTH_COMPONENT24, sw, sh);
        }
        self.gl.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, self.msaa_depth_rb);

        self.gl.BindFramebuffer(GL_FRAMEBUFFER, self.resolve_fbo);
        self.gl.BindRenderbuffer(GL_RENDERBUFFER, self.resolve_color_rb);
        self.gl.RenderbufferStorage(GL_RENDERBUFFER, @intCast(GL_RGBA8), sw, sh);
        self.gl.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, self.resolve_color_rb);

        self.fbo_w = w;
        self.fbo_h = h;
        self.fbo_samples = clamped_samples;
    }

    /// Draws the scene over a clear in the multisampled framebuffer, once
    /// `wait` (if given) is done, and resolves it into `resolve_color_rb`.
    fn drawResolved(self: *OffscreenContext, vp: Viewport, clear_color: ?Color, samples: u8, wait: ?Wait, user_ctx: anytype, comptime render_fn: anytype) !void {
        try self.makeCurrent();
        if (wait) |w| try self.waitFor(w);
        self.ensureFbo(vp.width, vp.height, samples);
        self.width = vp.width;
        self.height = vp.height;

        self.gl.BindFramebuffer(GL_FRAMEBUFFER, self.msaa_fbo);
        self.gl.Viewport(0, 0, @intCast(vp.width), @intCast(vp.height));
        self.gl.Disable(GL_SCISSOR_TEST);
        self.gl.Enable(GL_DEPTH_TEST);
        self.gl.DepthFunc(GL_LESS);
        self.gl.Enable(GL_CULL_FACE);
        self.gl.CullFace(GL_BACK);
        self.gl.FrontFace(GL_CCW);

        if (clear_color) |bg| {
            self.gl.ClearColor(bg.r, bg.g, bg.b, bg.a);
            self.gl.Clear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        }

        try render_fn(user_ctx, self);

        self.gl.BindFramebuffer(GL_READ_FRAMEBUFFER, self.msaa_fbo);
        self.gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, self.resolve_fbo);
        self.gl.BlitFramebuffer(
            0,
            0,
            @intCast(vp.width),
            @intCast(vp.height),
            0,
            0,
            @intCast(vp.width),
            @intCast(vp.height),
            GL_COLOR_BUFFER_BIT,
            @intCast(GL_NEAREST),
        );
    }

    /// As `renderToImage`, but with the resolved scene left on the GPU and
    /// exported as a dmabuf (bottom row first) for the 2D renderer to copy
    /// into its frame; null if it cannot be exported (draw it with
    /// `renderToImage`).
    pub fn renderToDmabuf(self: *OffscreenContext, area: GpuArea, clear_color: ?Color, samples: u8, wait: ?Wait, user_ctx: anytype, comptime render_fn: anytype) !?DmabufImage {
        if (self.export_failed) return null;
        const vp = area.viewport;
        if (vp.width == 0 or vp.height == 0) return null;
        try self.drawResolved(vp, clear_color, samples, wait, user_ctx, render_fn);
        var image = self.exportResolved() orelse {
            self.export_failed = true;
            return null;
        };
        // The 2D renderer reads it once the GPU has drawn it: it waits for
        // the sync file (on its GPU, if it can), or else it is drawn here.
        image.ready_fd = self.fenceFd();
        if (image.ready_fd < 0) self.gl.Finish();
        return image;
    }

    /// `resolve_color_rb` as a dmabuf (made again when its size changes).
    fn exportResolved(self: *OffscreenContext) ?DmabufImage {
        if (self.exported) |e| if (e.width == self.fbo_w and e.height == self.fbo_h) return e;
        self.dropExport();
        const x = self.export_procs orelse ExportProcs.load(&self.egl) orelse return null;
        self.export_procs = x;
        const no_attribs = [1]EGLint{EGL_NONE};
        const img = x.CreateImageKHR(self.dpy, self.ctx, EGL_GL_RENDERBUFFER_KHR, @ptrFromInt(self.resolve_color_rb), &no_attribs);
        if (img == null) return null;
        var fourcc: c_int = 0;
        var planes: c_int = 0;
        var modifier: u64 = 0;
        if (x.ExportDMABUFImageQueryMESA(self.dpy, img, &fourcc, &planes, &modifier) == EGL_FALSE or planes != 1) {
            _ = x.DestroyImageKHR(self.dpy, img);
            return null;
        }
        var fd: c_int = -1;
        var stride: EGLint = 0;
        var offset: EGLint = 0;
        if (x.ExportDMABUFImageMESA(self.dpy, img, &fd, &stride, &offset) == EGL_FALSE or fd < 0) {
            _ = x.DestroyImageKHR(self.dpy, img);
            return null;
        }
        self.export_image = img;
        self.export_id += 1;
        self.exported = .{
            .id = (@as(u64, @intFromPtr(self)) << 16) ^ self.export_id,
            .fd = fd,
            .fourcc = @bitCast(fourcc),
            .modifier = modifier,
            .offset = @intCast(offset),
            .stride = @intCast(stride),
            .width = self.fbo_w,
            .height = self.fbo_h,
            .bottom_up = true,
        };
        return self.exported;
    }

    fn dropExport(self: *OffscreenContext) void {
        if (self.exported) |e| _ = std.posix.system.close(e.fd);
        self.exported = null;
        if (self.export_image) |img| if (self.export_procs) |x| {
            _ = x.DestroyImageKHR(self.dpy, img);
        };
        self.export_image = null;
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

        try self.drawResolved(vp, clear_color, samples, wait, user_ctx, render_fn);

        self.gl.BindFramebuffer(GL_FRAMEBUFFER, self.resolve_fbo);
        const local_x: GLint = sc.x - vp.x;
        // OpenGL FBO row 0 is at the bottom; flip Y when reading and copying into top-down `Image`.
        const local_y: GLint = @as(i32, @intCast(vp.height)) - (sc.y - vp.y + @as(i32, @intCast(sc.height)));
        const count = @as(usize, sc.width) * sc.height;
        try self.scratch.resize(self.gpa, count);
        self.gl.PixelStorei(GL_PACK_ALIGNMENT, 4);
        self.gl.ReadPixels(
            local_x,
            local_y,
            @intCast(sc.width),
            @intCast(sc.height),
            GL_BGRA,
            GL_UNSIGNED_BYTE,
            self.scratch.items.ptr,
        );

        const dst_stride = target.rowStride();
        const dst_x: usize = @intCast(sc.x);
        for (0..sc.height) |row| {
            const dst_y: usize = @intCast(sc.y + @as(i32, @intCast(row)));
            const gl_row = sc.height - 1 - row;
            const src_row = self.scratch.items[gl_row * sc.width ..][0..sc.width];
            @memcpy(target.pixels[dst_y * dst_stride + dst_x ..][0..sc.width], src_row);
        }
    }
};

/// An OpenGL that does nothing, for tests without a GPU.
const MockGl = struct {
    var next_id: GLuint = 1;
    var draws: usize = 0;
    var last_scissor: [4]GLint = .{ 0, 0, 0, 0 };
    /// Textures there are, and made in all.
    var textures: usize = 0;
    var made_textures: usize = 0;

    fn enable(_: GLenum) callconv(.c) void {}
    fn disable(_: GLenum) callconv(.c) void {}
    fn blendFuncSeparate(_: GLenum, _: GLenum, _: GLenum, _: GLenum) callconv(.c) void {}
    fn viewport(_: GLint, _: GLint, _: GLsizei, _: GLsizei) callconv(.c) void {}
    fn scissor(x: GLint, y: GLint, w: GLsizei, h: GLsizei) callconv(.c) void {
        last_scissor = .{ x, y, w, h };
    }
    fn bindFramebuffer(_: GLenum, _: GLuint) callconv(.c) void {}
    fn genFramebuffers(n: GLsizei, out: [*]GLuint) callconv(.c) void {
        for (0..@intCast(n)) |i| {
            out[i] = next_id;
            next_id += 1;
        }
    }
    fn deleteFramebuffers(_: GLsizei, _: [*]const GLuint) callconv(.c) void {}
    fn framebufferTexture2D(_: GLenum, _: GLenum, _: GLenum, _: GLuint, _: GLint) callconv(.c) void {}
    fn readPixels(_: GLint, _: GLint, _: GLsizei, _: GLsizei, _: GLenum, _: GLenum, _: *anyopaque) callconv(.c) void {}
    fn genBuffers(n: GLsizei, out: [*]GLuint) callconv(.c) void {
        for (0..@intCast(n)) |i| {
            out[i] = next_id;
            next_id += 1;
        }
    }
    fn deleteBuffers(_: GLsizei, _: [*]const GLuint) callconv(.c) void {}
    fn bindBuffer(_: GLenum, _: GLuint) callconv(.c) void {}
    fn bufferData(_: GLenum, _: GLsizeiptr, _: ?*const anyopaque, _: GLenum) callconv(.c) void {}
    fn bufferSubData(_: GLenum, _: GLintptr, _: GLsizeiptr, _: ?*const anyopaque) callconv(.c) void {}
    fn genVertexArrays(n: GLsizei, out: [*]GLuint) callconv(.c) void {
        for (0..@intCast(n)) |i| {
            out[i] = next_id;
            next_id += 1;
        }
    }
    fn deleteVertexArrays(_: GLsizei, _: [*]const GLuint) callconv(.c) void {}
    fn bindVertexArray(_: GLuint) callconv(.c) void {}
    fn enableVertexAttribArray(_: GLuint) callconv(.c) void {}
    fn vertexAttribPointer(_: GLuint, _: GLint, _: GLenum, _: GLboolean, _: GLsizei, _: ?*const anyopaque) callconv(.c) void {}
    fn createShader(_: GLenum) callconv(.c) GLuint {
        defer next_id += 1;
        return next_id;
    }
    fn deleteShader(_: GLuint) callconv(.c) void {}
    fn shaderSource(_: GLuint, _: GLsizei, _: [*]const [*:0]const u8, _: ?[*]const GLint) callconv(.c) void {}
    fn compileShader(_: GLuint) callconv(.c) void {}
    fn getShaderiv(_: GLuint, _: GLenum, out: *GLint) callconv(.c) void {
        out.* = 1;
    }
    fn createProgram() callconv(.c) GLuint {
        defer next_id += 1;
        return next_id;
    }
    fn deleteProgram(_: GLuint) callconv(.c) void {}
    fn attachShader(_: GLuint, _: GLuint) callconv(.c) void {}
    fn linkProgram(_: GLuint) callconv(.c) void {}
    fn getProgramiv(_: GLuint, _: GLenum, out: *GLint) callconv(.c) void {
        out.* = 1;
    }
    fn useProgram(_: GLuint) callconv(.c) void {}
    fn getUniformLocation(_: GLuint, _: [*:0]const u8) callconv(.c) GLint {
        return 0;
    }
    fn uniform1i(_: GLint, _: GLint) callconv(.c) void {}
    fn genTextures(n: GLsizei, out: [*]GLuint) callconv(.c) void {
        textures += @intCast(n);
        made_textures += @intCast(n);
        for (0..@intCast(n)) |i| {
            out[i] = next_id;
            next_id += 1;
        }
    }
    fn deleteTextures(n: GLsizei, _: [*]const GLuint) callconv(.c) void {
        textures -= @intCast(n);
    }
    fn activeTexture(_: GLenum) callconv(.c) void {}
    fn bindTexture(_: GLenum, _: GLuint) callconv(.c) void {}
    fn pixelStorei(_: GLenum, _: GLint) callconv(.c) void {}
    fn texParameteri(_: GLenum, _: GLenum, _: GLint) callconv(.c) void {}
    fn texImage2D(_: GLenum, _: GLint, _: GLint, _: GLsizei, _: GLsizei, _: GLint, _: GLenum, _: GLenum, _: ?*const anyopaque) callconv(.c) void {}
    fn texSubImage2D(_: GLenum, _: GLint, _: GLint, _: GLint, _: GLsizei, _: GLsizei, _: GLenum, _: GLenum, _: ?*const anyopaque) callconv(.c) void {}
    fn drawArrays(_: GLenum, _: GLint, _: GLsizei) callconv(.c) void {
        draws += 1;
    }

    fn procs() Procs {
        return .{
            .Enable = MockGl.enable,
            .Disable = MockGl.disable,
            .BlendFuncSeparate = MockGl.blendFuncSeparate,
            .Viewport = MockGl.viewport,
            .Scissor = MockGl.scissor,
            .BindFramebuffer = MockGl.bindFramebuffer,
            .GenFramebuffers = MockGl.genFramebuffers,
            .DeleteFramebuffers = MockGl.deleteFramebuffers,
            .FramebufferTexture2D = MockGl.framebufferTexture2D,
            .ReadPixels = MockGl.readPixels,
            .GenBuffers = MockGl.genBuffers,
            .DeleteBuffers = MockGl.deleteBuffers,
            .BindBuffer = MockGl.bindBuffer,
            .BufferData = MockGl.bufferData,
            .BufferSubData = MockGl.bufferSubData,
            .GenVertexArrays = MockGl.genVertexArrays,
            .DeleteVertexArrays = MockGl.deleteVertexArrays,
            .BindVertexArray = MockGl.bindVertexArray,
            .EnableVertexAttribArray = MockGl.enableVertexAttribArray,
            .VertexAttribPointer = MockGl.vertexAttribPointer,
            .CreateShader = MockGl.createShader,
            .DeleteShader = MockGl.deleteShader,
            .ShaderSource = MockGl.shaderSource,
            .CompileShader = MockGl.compileShader,
            .GetShaderiv = MockGl.getShaderiv,
            .CreateProgram = MockGl.createProgram,
            .DeleteProgram = MockGl.deleteProgram,
            .AttachShader = MockGl.attachShader,
            .LinkProgram = MockGl.linkProgram,
            .GetProgramiv = MockGl.getProgramiv,
            .UseProgram = MockGl.useProgram,
            .GetUniformLocation = MockGl.getUniformLocation,
            .Uniform1i = MockGl.uniform1i,
            .GenTextures = MockGl.genTextures,
            .DeleteTextures = MockGl.deleteTextures,
            .ActiveTexture = MockGl.activeTexture,
            .BindTexture = MockGl.bindTexture,
            .PixelStorei = MockGl.pixelStorei,
            .TexParameteri = MockGl.texParameteri,
            .TexImage2D = MockGl.texImage2D,
            .TexSubImage2D = MockGl.texSubImage2D,
            .DrawArrays = MockGl.drawArrays,
        };
    }
};

test "OpenGlRenderer prepares batches, uploads atlas and images, and records draws" {
    MockGl.draws = 0;
    var gl_renderer = try OpenGlRenderer.initWithProcs(std.testing.allocator, MockGl.procs());
    defer gl_renderer.deinit();

    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    c.begin(200, 100);
    c.setClip(.{ .x = 10, .y = 20, .w = 50, .h = 30 });
    c.fillRoundedRect(.{ .x = 10, .y = 20, .w = 50, .h = 30 }, .all(6), .rgb(0x6750a4));

    const pixels = try std.testing.allocator.alloc(u32, 200 * 100);
    defer std.testing.allocator.free(pixels);
    var target: software.Image = .{ .pixels = pixels, .width = 200, .height = 100 };
    target.clear(0xff000000);
    try gl_renderer.renderer().draw(&c, &target);
    try std.testing.expectEqual(@as(usize, 3), MockGl.draws);
    // OpenGL scissor flips Y: 100 - (20 + 30) = 50
    try std.testing.expectEqual([4]GLint{ 10, 50, 50, 30 }, MockGl.last_scissor);
}

test "OpenGlRenderer keeps the images of every window it draws" {
    var gl_renderer = try OpenGlRenderer.initWithProcs(std.testing.allocator, MockGl.procs());
    defer gl_renderer.deinit();
    const px = [_]u32{ 0xff00ff00, 0xff00ff00, 0xff00ff00, 0xff00ff00 };
    const pic_a = canvas_mod.Image.init(&px, 2, 2);
    const pic_b = canvas_mod.Image.init(&px, 2, 2);
    var a = Canvas.init(std.testing.allocator);
    defer a.deinit();
    a.begin(100, 100);
    a.drawImage(&pic_a, .{ .x = 0, .y = 0, .w = 20, .h = 20 }, 1.0);
    var b = Canvas.init(std.testing.allocator);
    defer b.deinit();
    b.begin(100, 100);
    b.drawImage(&pic_b, .{ .x = 0, .y = 0, .w = 20, .h = 20 }, 1.0);

    // Two windows drawing in turn, each its own image: each is uploaded once.
    const made = MockGl.made_textures;
    for (0..10) |_| {
        try gl_renderer.prepare(&.{&a});
        try gl_renderer.prepare(&.{&b});
    }
    try std.testing.expectEqual(made + 2, MockGl.made_textures);
    try std.testing.expectEqual(2, gl_renderer.images.count());

    // One no window draws goes, after a while (b drew last, a frame without it).
    const textures = MockGl.textures;
    for (1..renderer_mod.image_keep_frames) |_| try gl_renderer.prepare(&.{&b});
    try std.testing.expectEqual(2, gl_renderer.images.count());
    try gl_renderer.prepare(&.{&b});
    try std.testing.expectEqual(1, gl_renderer.images.count());
    try std.testing.expect(gl_renderer.images.contains(pic_b.id));
    try std.testing.expectEqual(textures - 1, MockGl.textures);
}

test "OpenGlRenderer.initDefault renders 2D Canvas shapes and images into software.Image" {
    var gl_renderer = OpenGlRenderer.initDefault(std.testing.allocator) catch return;
    defer gl_renderer.deinit();

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

    try gl_renderer.renderer().draw(&c, &img);
    try std.testing.expectEqual(@as(u32, 0xff112233), img.pixels[2 * w + 2]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), img.pixels[25 * w + 30]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), img.pixels[20 * w + 70]);
}

test "OpenGlContext gives an exported scene with a sync file signalled once it is drawn" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var ctx = OffscreenContext.init(std.testing.allocator) catch return error.SkipZigTest;
    defer ctx.deinit();
    const Scene = struct {
        fn render(_: void, _: *OffscreenContext) !void {}
    };
    const area: GpuArea = .{ .viewport = .{ .width = 8, .height = 8 } };
    const image = (try ctx.renderToDmabuf(area, Color.rgb(0xff0000), 1, null, {}, Scene.render)) orelse return error.SkipZigTest;
    // Without EGL_ANDROID_native_fence_sync it was drawn before it was given.
    if (image.ready_fd < 0) return;
    const linux = std.os.linux;
    defer _ = linux.close(image.ready_fd);
    var fds = [1]linux.pollfd{.{ .fd = image.ready_fd, .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), linux.poll(&fds, 1, 5000));
}
