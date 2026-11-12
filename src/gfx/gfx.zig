//! 2D graphics for Kete's widget toolkit: anti-aliased rectangles with
//! rounded corners (and circles), polygons and polylines, filled or stroked,
//! paths with holes, text from a glyph `Atlas`, and images (stretched to a
//! rectangle, or bent onto triangles), blended source-over.
//!
//! A `Canvas` records shapes and text into batches on the CPU, independent of
//! the rendering backend. A `Renderer` draws those batches using one of the
//! built-in backends (`software`, `opengl`, `vulkan`, and `metal` on macOS)
//! or a custom backend
//! implementing `Renderer.of(&my_backend)`.
//!
//!     canvas.begin(width, height);
//!     canvas.fillRoundedRect(.{ .x = 16, .y = 16, .w = 200, .h = 56 }, .all(28), .rgb(0x6750a4));
//!     canvas.strokePolyline(&points, false, 2, .rgb(0x1d1b20));
//!     _ = canvas.drawText(&atlas, .{ .font = &fira, .size = 16 }, 16, 120, "Hello", .rgb(0x1d1b20));
//!     try software.render(&canvas, img);

/// Whether kete was built with its own backends (`-Dbackends`, on by
/// default): without them, the GPU renderers here (`VulkanRenderer`,
/// `OpenGlRenderer`, `MetalRenderer`, `D3D11Renderer` and their contexts)
/// are not, and frames are drawn by `SoftwareRenderer` or a `Renderer` of
/// the app's own.
pub const has_backends = @import("kete_options").backends;

/// A backend kete was built without (`-Dbackends=false`): naming it is an
/// error.
pub fn Unbuilt(comptime name: []const u8) type {
    @compileError(name ++ " is one of kete's own backends, which it was built without (-Dbackends=false)");
}

pub const geometry = @import("geometry.zig");
pub const dash = @import("dash.zig");
pub const Dash = dash.Dash;
pub const atlas = @import("atlas.zig");
pub const shaders = @import("shaders.zig");
pub const canvas = @import("canvas.zig");
pub const renderer = @import("renderer.zig");
pub const frame = @import("frame.zig");
pub const software = @import("software.zig");
pub const opengl = @import("opengl.zig");
pub const vulkan = @import("vulkan.zig");
pub const metal = @import("metal.zig");
/// Objective-C and Apple's frameworks, loaded at run time (for the Metal
/// renderer, and macOS windows).
pub const objc = @import("objc.zig");
/// The Windows API, its DLLs loaded when first used (as `objc` is on macOS).
pub const winapi = @import("winapi.zig");
pub const d3d11 = @import("d3d11.zig");
pub const png = @import("png.zig");
pub const jpeg = @import("jpeg.zig");
pub const gif = @import("gif.zig");
pub const webp = @import("webp.zig");

pub const Canvas = canvas.Canvas;
pub const Image = canvas.Image;
pub const Color = canvas.Color;
pub const Rect = canvas.Rect;
pub const CornerRadii = canvas.CornerRadii;
pub const Point = canvas.Point;
pub const Affine = canvas.Affine;
pub const Atlas = atlas.Atlas;
pub const Record = canvas.Record;

pub const Viewport = renderer.Viewport;
pub const GpuArea = renderer.GpuArea;
pub const GpuDraw = renderer.GpuDraw;
pub const Segment = renderer.Segment;
pub const DmabufTarget = renderer.DmabufTarget;
pub const DmabufImage = renderer.DmabufImage;
pub const MetalTarget = renderer.MetalTarget;
pub const RenderBackend = renderer.RenderBackend;
pub const Renderer = renderer.Renderer;
pub const Frame = frame.Frame;
pub const SoftwareRenderer = software.SoftwareRenderer;
pub const OpenGlRenderer = if (has_backends) opengl.OpenGlRenderer else Unbuilt("OpenGlRenderer");
pub const OpenGlContext = if (has_backends) opengl.OffscreenContext else Unbuilt("OpenGlContext");
pub const VulkanRenderer = if (has_backends) vulkan.VulkanRenderer else Unbuilt("VulkanRenderer");
pub const VulkanContext = if (has_backends) vulkan.OffscreenContext else Unbuilt("VulkanContext");
pub const MetalRenderer = if (has_backends) metal.MetalRenderer else Unbuilt("MetalRenderer");
pub const MetalContext = if (has_backends) metal.OffscreenContext else Unbuilt("MetalContext");
pub const D3D11Renderer = if (has_backends) d3d11.D3D11Renderer else Unbuilt("D3D11Renderer");
pub const D3D11Context = if (has_backends) d3d11.OffscreenContext else Unbuilt("D3D11Context");
pub const D3D11Target = renderer.D3D11Target;
pub const DrmNode = renderer.DrmNode;

/// The GPU device a renderer draws with (`ui.SharedResources.gpuDevice`), for
/// an app to draw on too: with a context on it (`VulkanContext.initShared`,
/// `OpenGlContext.initShared`, `MetalContext.initShared`,
/// `D3D11Context.initShared`), so that what it draws goes into the windows'
/// frames with no copy through the CPU; or with an API of its own on the same
/// GPU (`drmNode`, `adapterLuid`).
pub const GpuDevice = union(enum) {
    vulkan: vulkan.SharedDevice,
    opengl: opengl.SharedDisplay,
    metal: metal.SharedDevice,
    d3d11: d3d11.SharedDevice,

    /// The GPU's DRM render node (on Linux), if its API says: for an OpenGL
    /// context on it (`OpenGlContext.initOnDevice`).
    pub fn drmNode(d: GpuDevice) ?DrmNode {
        return switch (d) {
            .vulkan => |v| v.drm,
            .opengl => |o| o.drm,
            .metal, .d3d11 => null,
        };
    }

    /// The GPU's adapter (on Windows), if DXGI says: for a Direct3D device
    /// on it.
    pub fn adapterLuid(d: GpuDevice) ?d3d11.Luid {
        return switch (d) {
            .d3d11 => |x| x.luid,
            else => null,
        };
    }
};

test {
    _ = geometry;
    _ = dash;
    _ = atlas;
    _ = shaders;
    _ = canvas;
    _ = renderer;
    _ = frame;
    _ = software;
    // Vulkan and OpenGL are Linux's (and macOS's, for its tests), Metal
    // macOS's.
    if (@import("builtin").os.tag != .windows) {
        _ = opengl;
        _ = vulkan;
        _ = metal;
    }
    _ = objc;
    _ = winapi;
    _ = d3d11;
    _ = png;
    _ = jpeg;
    _ = gif;
    _ = webp;
}
