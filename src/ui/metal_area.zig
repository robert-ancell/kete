//! MetalArea: a widget that draws a 3D scene with Metal (on macOS): a
//! multisampled colour and depth target, resolved and drawn straight into
//! the Metal renderer's frame on its GPU (or else copied in through the
//! CPU), so an application only needs to write its `Scene` (`State.init`,
//! `State.deinit`, and `render`), its shaders in the Metal Shading
//! Language (see `gfx.MetalContext`).

const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Painter = @import("painter.zig").Painter;

const Size = geometry.Size;
const Point = geometry.Point;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;
const Event = widget.Event;
const PointerCursor = widget.PointerCursor;
const ValueCallback = widget.ValueCallback;

/// A widget that draws a scene of the app's with a Metal context into the area it takes.
pub fn MetalArea(comptime Scene: type) type {
    return struct {
        const Self = @This();
        const HasState = @hasDecl(Scene, "State");

        /// The app's scene: what draws (its `render`), and its state (see the top of this file).
        scene: Scene,
        /// How many samples per pixel are used to smooth edges (multisampling).
        samples: u8 = 4,
        /// The colour the area is cleared to before the scene is drawn (the
        /// theme's surface container if not given).
        clear_color: ?gfx.Color = null,
        /// Called with how far the pointer moved while it is dragged over the
        /// area; without it the area is not draggable.
        on_drag: ?ValueCallback(Point) = null,
        /// The narrowest it can be, in pixels.
        min_width: f32 = 280,
        /// The shortest it can be, in pixels.
        min_height: f32 = 260,
        /// Identifies what is drawn: the same key as in the last frame means
        /// the same picture, so it is not drawn again. Without one, the scene's
        /// bytes, the clear colour and the samples decide.
        key: ?u64 = null,
        /// A widget drawn over the area.
        child: ?Widget = null,
        /// A context of the app's to draw the scene with, instead of one the
        /// area makes and owns: so that the scene can use what the app made
        /// on it (its textures and buffers, say). It must outlive the area.
        context: ?*gfx.MetalContext = null,
        /// GPU work of the app's done elsewhere (on another thread, say) that
        /// the scene waits for before it is drawn: drawing a picture it
        /// shows, say. A new picture is a new `wait`, which draws the scene
        /// again.
        wait: ?gfx.metal.Wait = null,

        pub const State = struct {
            gpa: ?std.mem.Allocator = null,
            /// The context drawn with: the app's (`context`), or its own.
            app_ctx: ?*gfx.MetalContext = null,
            own_ctx: ?gfx.MetalContext = null,
            /// The app's context it was made for (null for its own).
            made_for: ?*gfx.MetalContext = null,
            scene_state: if (HasState) ?Scene.State else void = if (HasState) null else {},
            init_failed: bool = false,
            dragging: bool = false,
            last_pos: Point = .{ 0, 0 },

            fn ctx(st: *State) ?*gfx.MetalContext {
                if (st.app_ctx) |c| return c;
                return if (st.own_ctx) |*c| c else null;
            }

            pub fn deinit(st: *State) void {
                const c = st.ctx() orelse return;
                c.waitIdle();
                if (HasState) {
                    if (st.scene_state) |*ss| {
                        if (@hasDecl(Scene.State, "deinit")) {
                            const params = @typeInfo(@TypeOf(Scene.State.deinit)).@"fn".param_types;
                            if (params.len == 3) {
                                ss.deinit(c, st.gpa.?);
                            } else if (params.len == 2) {
                                ss.deinit(c);
                            } else {
                                ss.deinit();
                            }
                        }
                    }
                }
                if (st.own_ctx) |*own| own.deinit();
                st.own_ctx = null;
                st.app_ctx = null;
                if (HasState) st.scene_state = null;
            }
        };

        const DrawPayload = struct {
            mtl_ctx: *gfx.MetalContext,
            wait: ?gfx.metal.Wait,
            scene: Scene,
            scene_state: if (HasState) *Scene.State else void,
            clear_color: gfx.Color,
            samples: u8,
        };

        pub fn layout(self: *const Self, n: *Node, c: Constraints) Size {
            const size = c.constrain(.{
                .w = if (c.boundedWidth()) c.max_w else @max(self.min_width, 460),
                .h = if (c.boundedHeight()) c.max_h else @max(self.min_height, 380),
            });
            for (n.children.items) |ch| _ = ch.layout(.tight(size));
            return size;
        }

        pub fn minSize(self: *const Self, _: *Node, c: Constraints) Size {
            return c.constrain(.{ .w = self.min_width, .h = self.min_height });
        }

        pub fn cursor(self: *const Self, n: *Node, _: Point) ?PointerCursor {
            if (self.on_drag == null) return null;
            return if (n.state(State).dragging) .grabbing else .grab;
        }

        pub fn event(self: *const Self, n: *Node, e: Event) bool {
            const cb = self.on_drag orelse return false;
            const st = n.state(State);
            switch (e) {
                .press => |pr| {
                    if (pr.button != .left) return false;
                    st.dragging = true;
                    st.last_pos = pr.pos;
                    n.ui.needs_frame = true;
                    return true;
                },
                .motion => |pos| if (st.dragging) {
                    const dx = pos[0] - st.last_pos[0];
                    const dy = pos[1] - st.last_pos[1];
                    st.last_pos = pos;
                    cb.call(.{ dx, dy });
                    n.ui.needs_frame = true;
                    return true;
                },
                .release => if (st.dragging) {
                    st.dragging = false;
                    n.ui.needs_frame = true;
                    return true;
                },
                else => {},
            }
            return false;
        }

        pub fn paint(self: *const Self, n: *Node, p: *Painter) void {
            const st = n.state(State);
            const t = n.theme();
            const bg = self.clear_color orelse t.surface_container;

            // Given another context of the app's (or none): what the scene
            // made on the last one goes, and it is made again on this.
            if (self.context != st.made_for) {
                st.deinit();
                st.init_failed = false;
                st.made_for = self.context;
            }
            if (!st.init_failed and st.ctx() == null) {
                st.gpa = n.ui.gpa;
                if (self.context) |app| {
                    st.app_ctx = app;
                } else {
                    // On the UI's Metal renderer's device if it has one, so
                    // that the scene is drawn straight into its frames; or
                    // else on a device of its own, and copied in.
                    const shared: ?gfx.MetalContext = if (sharedDevice(n)) |dev| gfx.MetalContext.initShared(n.ui.gpa, dev) catch null else null;
                    if (if (shared) |c| c else gfx.MetalContext.init(n.ui.gpa)) |c| {
                        st.own_ctx = c;
                    } else |_| {
                        st.init_failed = true;
                    }
                }
                if (HasState) if (st.ctx()) |c| {
                    const params = @typeInfo(@TypeOf(Scene.State.init)).@"fn".param_types;
                    const init_res = if (params.len == 2)
                        Scene.State.init(c, n.ui.gpa)
                    else
                        Scene.State.init(c);
                    if (init_res) |ss| {
                        st.scene_state = ss;
                    } else |_| {
                        if (st.own_ctx) |*own| own.deinit();
                        st.own_ctx = null;
                        st.app_ctx = null;
                        st.init_failed = true;
                    }
                };
            }

            const ctx = st.ctx() orelse {
                const c = p.canvas();
                c.fillRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, bg);
                return;
            };

            const payload = n.ui.arena().create(DrawPayload) catch return;
            payload.* = .{
                .mtl_ctx = ctx,
                .wait = self.wait,
                .scene = self.scene,
                .scene_state = if (HasState) &st.scene_state.? else {},
                .clear_color = bg,
                .samples = self.samples,
            };

            const draw_key = self.key orelse blk: {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(std.mem.asBytes(&self.scene));
                hasher.update(std.mem.asBytes(&bg));
                hasher.update(&.{self.samples});
                std.hash.autoHashStrat(&hasher, self.wait, .Shallow);
                break :blk hasher.final();
            };

            // The scene is drawn over a clear and copied in, replacing every
            // pixel of the box.
            p.gpuWithDirect(.{ .key = draw_key, .fills = true }, payload, drawGpu, drawDirect);
        }

        /// The device of the UI's renderer, if it is the Metal one.
        fn sharedDevice(n: *Node) ?gfx.metal.SharedDevice {
            const dev = n.ui.shared.gpuDevice() orelse return null;
            return switch (dev) {
                .metal => |d| d,
                else => null,
            };
        }

        fn drawDirect(payload: *const DrawPayload, backend: gfx.RenderBackend, frame: *const anyopaque, area: gfx.GpuArea) anyerror!bool {
            if (backend != .metal) return false;
            const f: *const gfx.metal.DirectFrame = @ptrCast(@alignCast(frame));
            return payload.mtl_ctx.renderToFrame(f, area, payload.clear_color, payload.samples, payload.wait, payload, renderScene);
        }

        fn drawGpu(payload: *const DrawPayload, target: *gfx.software.Image, area: gfx.GpuArea) anyerror!void {
            try payload.mtl_ctx.renderToImage(target, area, payload.clear_color, payload.samples, payload.wait, payload, renderScene);
        }

        fn renderScene(payload: *const DrawPayload, ctx: *gfx.MetalContext) anyerror!void {
            if (HasState) {
                try payload.scene.render(payload.scene_state, ctx);
            } else {
                try payload.scene.render(ctx);
            }
        }
    };
}
