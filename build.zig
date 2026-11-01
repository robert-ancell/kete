const std = @import("std");

/// A subsetted Material Icons font together with the `IconName` source that
/// defines which icons it contains.  Pass to `createModules`.
pub const IconFont = struct {
    ttf: std.Build.LazyPath,
    codepoints: std.Build.LazyPath,
    /// Source file that defines `pub const IconName = enum { ... }`.
    /// Used as the `icon_names` module import by the `icons` module.
    names: std.Build.LazyPath,
};

/// Builds and runs `subset_icons` compiled against the given `names` source.
fn runSubsetIcons(b: *std.Build, names: std.Build.LazyPath) struct {
    ttf: std.Build.LazyPath,
    codepoints: std.Build.LazyPath,
} {
    const host_font = b.createModule(.{
        .root_source_file = b.path("src/font/font.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    host_font.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    host_font.addAnonymousImport("TwemojiMozilla.ttf", .{ .root_source_file = b.path("fonts/TwemojiMozilla.ttf") });
    const tool = b.addExecutable(.{
        .name = "subset_icons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/subset_icons.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    tool.root_module.addImport("font", host_font);
    tool.root_module.addImport("icon_names", b.createModule(.{
        .root_source_file = names,
        .target = b.graph.host,
        .optimize = .safe,
    }));
    const run = b.addRunArtifact(tool);
    run.addFileArg(b.path("fonts/MaterialIcons-Regular.ttf"));
    run.addFileArg(b.path("fonts/MaterialIcons-Regular.codepoints"));
    return .{
        .ttf = run.addOutputFileArg("MaterialIcons.ttf"),
        .codepoints = run.addOutputFileArg("icon_codepoints.zig"),
    };
}

/// Returns an `IconFont` containing all icons in `src/icons/names.zig`.
pub fn addIconFont(b: *std.Build) IconFont {
    const names = b.path("src/icons/names.zig");
    const out = runSubsetIcons(b, names);
    return .{ .ttf = out.ttf, .codepoints = out.codepoints, .names = names };
}

/// Returns an `IconFont` subsetted to only the icons referenced in the given
/// source directories, by scanning for two unambiguous patterns:
///
///   1. `IconName.name` — explicit type qualification.
///   2. `.icon = .name`, `.leading_icon = .name`, `.trailing_icon = .name` —
///      enum inference on known `IconName`-typed fields.
///
/// Kete's own `src/` directory is always scanned in addition to `scan_dirs`,
/// so icons used internally by kete (e.g. `.expand_more` in the dropdown) are
/// always included.
///
/// For icons chosen dynamically at runtime, add a no-op anywhere in your source:
///
///     comptime { _ = &[_]kete.IconName{ .cloud, .download }; }
///
pub fn addIconFontScanned(b: *std.Build, scan_dirs: []const std.Build.LazyPath) IconFont {
    const scanner = b.addExecutable(.{
        .name = "scan_icons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scan_icons.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const scan = b.addRunArtifact(scanner);
    scan.addFileArg(b.path("fonts/MaterialIcons-Regular.codepoints"));
    const names = scan.addOutputFileArg("names.zig");
    scan.addDirectoryArg(b.path("src")); // kete's own icons (e.g. .expand_more)
    for (scan_dirs) |dir| scan.addDirectoryArg(dir);
    const out = runSubsetIcons(b, names);
    return .{ .ttf = out.ttf, .codepoints = out.codepoints, .names = names };
}

fn addSpirv(b: *std.Build, name: []const u8, source: []const u8, os_tag: std.Target.Os.Tag) std.Build.LazyPath {
    const spirv_target = b.resolveTargetQuery(.{ .cpu_arch = .spirv64, .os_tag = os_tag, .ofmt = .spirv });
    const gpu = b.createModule(.{
        .root_source_file = b.path("src/gfx/shaders/gpu.zig"),
        .target = spirv_target,
        .optimize = .fast,
    });
    const obj = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = spirv_target,
            .optimize = .fast,
            .imports = &.{.{ .name = "gpu", .module = gpu }},
        }),
        .use_llvm = false,
    });
    return obj.getEmittedBin();
}

/// The Direct3D 11 renderer's shaders (`src/gfx/shaders/canvas.hlsl`),
/// compiled to DXBC by fxc and embedded in `gfx` as `<entry>.dxbc`.
fn addCanvasDxbc(b: *std.Build, gfx: *std.Build.Module) void {
    const shaders = [_]struct { entry: []const u8, profile: []const u8 }{
        .{ .entry = "shape_vs", .profile = "vs_5_0" },
        .{ .entry = "solid_vs", .profile = "vs_5_0" },
        .{ .entry = "text_vs", .profile = "vs_5_0" },
        .{ .entry = "shape_ps", .profile = "ps_5_0" },
        .{ .entry = "solid_ps", .profile = "ps_5_0" },
        .{ .entry = "text_ps", .profile = "ps_5_0" },
        .{ .entry = "image_ps", .profile = "ps_5_0" },
    };
    for (shaders) |s| {
        const out = addDxbc(b, b.fmt("{s}.dxbc", .{s.entry}), "src/gfx/shaders/canvas.hlsl", s.entry, s.profile);
        gfx.addAnonymousImport(b.fmt("{s}.dxbc", .{s.entry}), .{ .root_source_file = out });
    }
}

/// A 3D scene's HLSL (`vertex_main` and `pixel_main`), compiled to DXBC and
/// embedded in `mod` as `<name>_vs.dxbc` and `<name>_ps.dxbc`.
fn addSceneDxbc(b: *std.Build, mod: *std.Build.Module, name: []const u8, source: []const u8) void {
    const vs = b.fmt("{s}_vs.dxbc", .{name});
    const ps = b.fmt("{s}_ps.dxbc", .{name});
    mod.addAnonymousImport(vs, .{ .root_source_file = addDxbc(b, vs, source, "vertex_main", "vs_5_0") });
    mod.addAnonymousImport(ps, .{ .root_source_file = addDxbc(b, ps, source, "pixel_main", "ps_5_0") });
}

/// HLSL compiled to DXBC (shader model 5.0, for Direct3D 11) by fxc, the
/// Windows SDK's compiler, when building on Windows (`-Dfxc=` says where it
/// is, if it is not on PATH or in the SDK). Kete is built for Windows on
/// Windows: without fxc the build fails. `-Dwindows-check` gives empty
/// shaders instead, only to check that the code compiles elsewhere (the
/// renderer then refuses to start).
pub fn addDxbc(b: *std.Build, name: []const u8, source: []const u8, entry: []const u8, profile: []const u8) std.Build.LazyPath {
    if (windowsCheck(b)) return b.addWriteFiles().add(name, "");
    const fxc = findFxc(b) orelse {
        const fail = b.addFail("fxc (the Windows SDK's HLSL compiler) was not found on PATH or in C:\\Program Files (x86)\\Windows Kits\\10\\bin: install the Windows SDK, or say where fxc.exe is with -Dfxc=");
        const wf = b.addWriteFiles();
        wf.step.dependOn(&fail.step);
        return wf.add(name, "");
    };
    const run = b.addSystemCommand(&.{ fxc, "/nologo", "/O3", "/T", profile, "/E", entry, "/Fo" });
    const out = run.addOutputFileArg(name);
    run.addFileArg(b.path(source));
    return out;
}

fn windowsCheck(b: *std.Build) bool {
    const S = struct {
        var looked = false;
        var on = false;
    };
    if (!S.looked) {
        S.looked = true;
        S.on = b.option(bool, "windows-check", "Only check that the Windows code compiles (empty D3D11 shaders, no fxc)") orelse false;
    }
    return S.on;
}

/// Where fxc is: `-Dfxc=`, on PATH, or in the newest Windows 10/11 SDK.
fn findFxc(b: *std.Build) ?[]const u8 {
    const S = struct {
        var looked = false;
        var found: ?[]const u8 = null;
    };
    if (S.looked) return S.found;
    S.looked = true;
    if (b.option([]const u8, "fxc", "Path to fxc.exe, the Windows SDK's HLSL compiler (for the D3D11 shaders)")) |p| {
        S.found = p;
        return p;
    }
    var names: std.ArrayList([]const u8) = .empty;
    names.append(b.allocator, "fxc") catch return null;
    if (b.graph.host.result.os.tag == .windows) sdk: {
        const io = b.graph.io;
        const bin = "C:\\Program Files (x86)\\Windows Kits\\10\\bin";
        var dir = std.Io.Dir.openDirAbsolute(io, bin, .{ .iterate = true }) catch break :sdk;
        defer dir.close(io);
        var versions: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind == .directory and std.mem.startsWith(u8, e.name, "10.")) versions.append(b.allocator, b.dupe(e.name)) catch {};
        }
        // The newest first.
        std.mem.sort([]const u8, versions.items, {}, struct {
            fn newer(_: void, a: []const u8, c: []const u8) bool {
                return std.mem.order(u8, a, c) == .gt;
            }
        }.newer);
        for (versions.items) |v| names.append(b.allocator, b.pathJoin(&.{ bin, v, "x64", "fxc.exe" })) catch {};
    }
    S.found = b.findProgram(.{ .names = names.items });
    return S.found;
}

pub const Modules = struct {
    kete: *std.Build.Module,
    ui: *std.Build.Module,
    gfx: *std.Build.Module,
    font: *std.Build.Module,
    icons: *std.Build.Module,
    window: *std.Build.Module,
    wayland: *std.Build.Module,
};

pub fn createModules(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    icon_font: IconFont,
) Modules {
    const wayland = b.createModule(.{
        .root_source_file = b.path("src/wayland/wayland.zig"),
        .target = target,
        .optimize = optimize,
    });

    const font = b.createModule(.{
        .root_source_file = b.path("src/font/font.zig"),
        .target = target,
        .optimize = optimize,
    });
    font.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    font.addAnonymousImport("TwemojiMozilla.ttf", .{ .root_source_file = b.path("fonts/TwemojiMozilla.ttf") });

    const icons = b.createModule(.{
        .root_source_file = b.path("src/icons/icons.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "font", .module = font },
            .{ .name = "icon_names", .module = b.createModule(.{
                .root_source_file = icon_font.names,
                .target = target,
                .optimize = optimize,
            }) },
            .{ .name = "icon_codepoints", .module = b.createModule(.{
                .root_source_file = icon_font.codepoints,
                .target = target,
                .optimize = optimize,
            }) },
        },
    });
    icons.addAnonymousImport("MaterialIcons.ttf", .{ .root_source_file = icon_font.ttf });

    const gfx = b.createModule(.{
        .root_source_file = b.path("src/gfx/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "font", .module = font },
        },
    });
    if (target.result.os.tag == .windows) addCanvasDxbc(b, gfx);
    for ([_][]const u8{ "shape", "solid", "text", "image", "window" }) |shader_name| {
        const spv = addSpirv(b, shader_name, b.fmt("src/gfx/shaders/{s}.zig", .{shader_name}), .vulkan);
        gfx.addAnonymousImport(b.fmt("{s}.spv", .{shader_name}), .{ .root_source_file = spv });
        const gl_spv = addSpirv(b, b.fmt("{s}_gl", .{shader_name}), b.fmt("src/gfx/shaders/{s}.zig", .{shader_name}), .opengl);
        gfx.addAnonymousImport(b.fmt("{s}_gl.spv", .{shader_name}), .{ .root_source_file = gl_spv });
    }

    const window = b.createModule(.{
        .root_source_file = b.path("src/window/window.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "gfx", .module = gfx },
        },
    });

    const ui = b.createModule(.{
        .root_source_file = b.path("src/ui/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gfx", .module = gfx },
            .{ .name = "font", .module = font },
            .{ .name = "icons", .module = icons },
            .{ .name = "window", .module = window },
        },
    });

    const kete = b.addModule(name, .{
        .root_source_file = b.path("src/kete.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ui", .module = ui },
            .{ .name = "gfx", .module = gfx },
            .{ .name = "font", .module = font },
            .{ .name = "window", .module = window },
        },
    });

    return .{
        .kete = kete,
        .ui = ui,
        .gfx = gfx,
        .font = font,
        .icons = icons,
        .window = window,
        .wayland = wayland,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const icon_font = addIconFont(b);
    const mods = createModules(b, "kete", target, optimize, icon_font);
    const polyhedron_gl_spv = addSpirv(b, "polyhedron_gl", "examples/shaders/polyhedron.zig", .opengl);
    const polyhedron_vk_spv = addSpirv(b, "polyhedron_vk", "examples/shaders/polyhedron.zig", .vulkan);

    const examples = [_]struct {
        name: []const u8,
        source: []const u8,
        desc: []const u8,
        polyhedron_spv: ?std.Build.LazyPath = null,
        /// Not built for Windows (it uses an API kete has only elsewhere),
        /// or built only for it.
        not_windows: bool = false,
        only_windows: bool = false,
        /// HLSL compiled to DXBC (on Windows), embedded as `<name>_vs.dxbc`
        /// and `<name>_ps.dxbc`: its source, and its two entry points.
        hlsl: ?struct { name: []const u8, source: []const u8 } = null,
    }{
        .{ .name = "hello", .source = "examples/hello.zig", .desc = "Run the interactive counter example" },
        .{ .name = "navigation", .source = "examples/navigation.zig", .desc = "Run the inbox navigation, dialog, and snackbar example" },
        .{ .name = "lists", .source = "examples/lists_and_drag.zig", .desc = "Run the 500-item grid and drag-and-drop example" },
        .{ .name = "editor", .source = "examples/editor.zig", .desc = "Run the syntax-highlighted code editor example" },
        .{ .name = "canvas", .source = "examples/canvas_and_qr.zig", .desc = "Run the animated wave viewer and QR code generator example" },
        .{ .name = "fetch", .source = "examples/fetch.zig", .desc = "Run the example fetching over HTTP in the background on the app's std.Io" },
        .{ .name = "windows", .source = "examples/windows.zig", .desc = "Run the example with more than one window" },
        .{ .name = "opengl", .source = "examples/opengl.zig", .desc = "Run the OpenGL 3D Platonic solid viewer example", .polyhedron_spv = polyhedron_gl_spv, .not_windows = true },
        .{ .name = "vulkan", .source = "examples/vulkan.zig", .desc = "Run the Vulkan 3D Platonic solid viewer example", .polyhedron_spv = polyhedron_vk_spv, .not_windows = true },
        .{ .name = "metal", .source = "examples/metal.zig", .desc = "Run the Metal 3D Platonic solid viewer example (macOS)", .not_windows = true },
        .{ .name = "d3d11", .source = "examples/d3d11.zig", .desc = "Run the Direct3D 11 3D Platonic solid viewer example (Windows)", .only_windows = true, .hlsl = .{ .name = "polyhedron", .source = "examples/shaders/polyhedron.hlsl" } },
    };

    const examples_step = b.step("examples", "Build all example applications");
    const test_step = b.step("test", "Run all unit tests");

    for (examples) |ex| {
        const windows = target.result.os.tag == .windows;
        if (ex.not_windows and windows or ex.only_windows and !windows) continue;
        const mod = b.createModule(.{
            .root_source_file = b.path(ex.source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kete", .module = mods.kete }},
        });
        if (ex.polyhedron_spv) |spv| {
            mod.addAnonymousImport("polyhedron.spv", .{ .root_source_file = spv });
        }
        if (ex.hlsl) |h| addSceneDxbc(b, mod, h.name, h.source);
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = mod,
        });
        const install_exe = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install_exe.step);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{ex.name}), ex.desc);
        run_step.dependOn(&run_cmd.step);

        const ex_test = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(ex_test).step);
    }

    // Tools: one reporting the backends kete picks on this system, and a
    // tour of every widget.
    const tools = [_]struct {
        name: []const u8,
        step: []const u8,
        source: []const u8,
        desc: []const u8,
        cube: bool = false,
    }{
        .{ .name = "kete-info", .step = "info", .source = "tools/info.zig", .desc = "Show the windowing, buffer, sync and rendering backends in use" },
        .{ .name = "kete-showcase", .step = "showcase", .source = "tools/showcase.zig", .desc = "Run the tour of every widget", .cube = true },
    };
    const cube_vulkan_spv = addSpirv(b, "cube_vulkan", "tools/showcase/shaders/cube.zig", .vulkan);
    const cube_opengl_spv = addSpirv(b, "cube_opengl", "tools/showcase/shaders/cube.zig", .opengl);
    for (tools) |tool| {
        const mod = b.createModule(.{
            .root_source_file = b.path(tool.source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kete", .module = mods.kete }},
        });
        if (tool.cube) {
            mod.addAnonymousImport("cube_vulkan.spv", .{ .root_source_file = cube_vulkan_spv });
            mod.addAnonymousImport("cube_opengl.spv", .{ .root_source_file = cube_opengl_spv });
            if (target.result.os.tag == .windows) addSceneDxbc(b, mod, "cube", "tools/showcase/shaders/cube.hlsl");
        }
        const exe = b.addExecutable(.{
            .name = tool.name,
            .root_module = mod,
        });
        b.installArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{tool.step}), tool.desc);
        run_step.dependOn(&b.addRunArtifact(exe).step);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }

    // API reference generated from the doc comments, installed to zig-out/docs.
    const docs_lib = b.addLibrary(.{ .name = "kete", .root_module = mods.kete });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    // The images in it: each widget's example, drawn on the CPU.
    const images_exe = b.addExecutable(.{
        .name = "docs-images",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_images.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kete", .module = mods.kete }},
        }),
    });
    const images_run = b.addRunArtifact(images_exe);
    const install_images = b.addInstallDirectory(.{
        .source_dir = images_run.addOutputDirectoryArg("images"),
        .install_dir = .prefix,
        .install_subdir = "docs/images",
    });
    install_images.step.dependOn(&install_docs.step);
    b.step("docs", "Generate the API reference into zig-out/docs").dependOn(&install_images.step);

    // The project's website: its page, images of the example apps (the
    // showcase and two examples, drawn on the CPU), and the API reference.
    const site_mod = b.createModule(.{
        .root_source_file = b.path("tools/site_images.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "kete", .module = mods.kete }},
    });
    const showcase_mod = b.createModule(.{
        .root_source_file = b.path("tools/showcase.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "kete", .module = mods.kete }},
    });
    showcase_mod.addAnonymousImport("cube_vulkan.spv", .{ .root_source_file = cube_vulkan_spv });
    showcase_mod.addAnonymousImport("cube_opengl.spv", .{ .root_source_file = cube_opengl_spv });
    if (target.result.os.tag == .windows) addSceneDxbc(b, showcase_mod, "cube", "tools/showcase/shaders/cube.hlsl");
    site_mod.addImport("showcase", showcase_mod);
    for ([_][]const u8{ "navigation", "editor" }) |example| {
        site_mod.addImport(example, b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kete", .module = mods.kete }},
        }));
    }
    const site_exe = b.addExecutable(.{ .name = "site-images", .root_module = site_mod });
    const site_run = b.addRunArtifact(site_exe);
    const install_site_images = b.addInstallDirectory(.{
        .source_dir = site_run.addOutputDirectoryArg("images"),
        .install_dir = .prefix,
        .install_subdir = "images",
    });
    const install_page = b.addInstallDirectory(.{
        .source_dir = b.path("website"),
        .install_dir = .prefix,
        .install_subdir = "",
    });
    const site_step = b.step("site", "Build the website (its page, images and the API reference) into the install prefix");
    site_step.dependOn(&install_page.step);
    site_step.dependOn(&install_site_images.step);
    site_step.dependOn(&install_images.step);

    for ([_]*std.Build.Module{
        mods.font,
        mods.icons,
        mods.wayland,
        mods.gfx,
        mods.window,
        mods.ui,
        mods.kete,
    }) |m| {
        // Wayland's wire protocol has no use (or fds) on Windows.
        if (m == mods.wayland and target.result.os.tag == .windows) continue;
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
