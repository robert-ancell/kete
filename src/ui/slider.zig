//! Slider: a continuous or discrete slider for choosing a number
//! from a range by pressing or dragging along a track.

const focus = @import("focus.zig");
const a11y = @import("accessibility.zig");
const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter = @import("painter.zig");
const control = @import("control.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Node = widget.WidgetNode;
const Event = widget.Event;
const ValueCallback = widget.ValueCallback;
const Painter = painter.Painter;

/// A slider: a handle on a track, that is dragged (or moved with the
/// arrow keys) to choose a value from `min` to `max`.
///
/// ![The Slider example](images/Slider.png)
///
/// ```zig
/// return cx.make(kete.SizedBox{ .width = 240, .child = cx.make(kete.Slider{ .value = 0.4, .on_changed = .of(state, State.setAmount) }) });
/// ```
pub const Slider = struct {
    /// Where the handle is, from `min` to `max`.
    value: f32,
    /// The value at the start of the track.
    min: f32 = 0,
    /// The value at the end of the track.
    max: f32 = 1,
    /// When set and greater than 0, snaps to `divisions` equal steps and
    /// draws tick marks along the track.
    divisions: ?u32 = null,
    /// Without it the slider is disabled.
    on_changed: ?ValueCallback(f32) = null,

    pub const height = control.target;
    pub const track_height = 6;
    pub const thumb_radius = 10;
    pub const halo_radius = 20;

    pub const State = struct {
        hovered: bool = false,
        pressed: bool = false,
    };

    pub fn focusable(self: *const Slider, _: *Node) bool {
        return self.on_changed != null;
    }

    pub fn paintOver(_: *const Slider, n: *Node, p: *Painter) void {
        focus.ring(n, p, null, false);
    }

    /// How far a key moves it: a division, or a twentieth of the way
    /// (Page Up and Down: ten times as far).
    fn keyStep(self: *const Slider) f32 {
        const d = self.divisions orelse 20;
        return (self.max - self.min) / @as(f32, @floatFromInt(@max(d, 1)));
    }

    pub fn accessible(self: *const Slider, n: *Node) ?a11y.Info {
        return .{ .role = .slider, .orientation = .horizontal, .valuenow = self.value, .valuemin = self.min, .valuemax = self.max, .set_value = a11y.setterOf(n, self.on_changed, self.min, self.max), .disabled = self.on_changed == null };
    }

    pub fn layout(_: *const Slider, _: *Node, c: Constraints) Size {
        return c.constrain(.{
            .w = if (std.math.isFinite(c.max_w)) c.max_w else 200,
            .h = height,
        });
    }

    pub fn minSize(_: *const Slider, _: *Node, c: Constraints) Size {
        return c.constrain(.{
            .w = 100,
            .h = height,
        });
    }

    fn trackEnds(w: f32) [2]f32 {
        const inset = @min(@as(f32, halo_radius), w / 2);
        return .{ inset, @max(inset, w - inset) };
    }

    fn normalized(self: *const Slider) f32 {
        const span = self.max - self.min;
        if (!(span > 0) or !std.math.isFinite(self.value)) return 0;
        return std.math.clamp((self.value - self.min) / span, 0, 1);
    }

    fn valueAt(self: *const Slider, w: f32, x: f32) f32 {
        const ends = trackEnds(w);
        const track_w = ends[1] - ends[0];
        var k: f32 = if (track_w > 0) std.math.clamp((x - ends[0]) / track_w, 0, 1) else 0;
        if (self.divisions) |d| if (d > 0 and d <= 1000) {
            const steps: f32 = @floatFromInt(d);
            k = @round(k * steps) / steps;
        };
        return self.min + k * (self.max - self.min);
    }

    pub fn paint(self: *const Slider, n: *Node, p: *Painter) void {
        const t = n.theme();
        const c = p.canvas();
        const st = n.state(State);
        const enabled = self.on_changed != null;
        const ends = trackEnds(n.size.w);
        const track_w = ends[1] - ends[0];
        const cy = n.size.h / 2;
        const track_y = cy - track_height / 2;
        const k = self.normalized();
        const thumb_x = ends[0] + k * track_w;
        const r: gfx.CornerRadii = .all(track_height / 2);

        const active_color = if (enabled) t.primary else t.on_surface.withAlpha(0.38);
        const inactive_color = if (enabled) t.surface_container_highest else t.on_surface.withAlpha(0.12);

        if (track_w > 0) {
            c.fillRoundedRect(.{ .x = ends[0], .y = track_y, .w = track_w, .h = track_height }, r, inactive_color);
            if (thumb_x > ends[0]) {
                c.fillRoundedRect(.{ .x = ends[0], .y = track_y, .w = thumb_x - ends[0], .h = track_height }, r, active_color);
            }
            if (self.divisions) |d| if (d > 0 and d <= 64) {
                const steps: f32 = @floatFromInt(d);
                var i: u32 = 0;
                while (i <= d) : (i += 1) {
                    const tx = ends[0] + (@as(f32, @floatFromInt(i)) / steps) * track_w;
                    const on_active = tx <= thumb_x;
                    const dot_color = if (on_active) t.on_primary.withAlpha(if (enabled) 0.7 else 0.38) else t.on_surface_variant.withAlpha(if (enabled) 0.6 else 0.38);
                    c.fillCircle(.{ tx, cy }, 2, dot_color);
                }
            };
        }

        if (enabled and (st.hovered or st.pressed)) {
            const alpha: f32 = if (st.pressed) 0.12 else 0.08;
            c.fillCircle(.{ thumb_x, cy }, halo_radius, t.primary.withAlpha(alpha));
        }
        c.fillCircle(.{ thumb_x, cy }, if (enabled and st.pressed) thumb_radius + 1 else thumb_radius, active_color);
    }

    pub fn cursor(self: *const Slider, n: *Node, _: geometry.Point) ?widget.PointerCursor {
        if (self.on_changed == null) return null;
        return if (n.state(State).pressed) .grabbing else .pointer;
    }

    pub fn event(self: *const Slider, n: *Node, e: Event) bool {
        const st = n.state(State);
        switch (e) {
            .enter, .leave => {
                const hovered = e == .enter;
                if (st.hovered != hovered) n.ui.needs_frame = true;
                st.hovered = hovered;
                return false;
            },
            .press => |pr| {
                if (pr.button != .left) return false;
                const on_changed = self.on_changed orelse return false;
                st.pressed = true;
                on_changed.call(self.valueAt(n.size.w, pr.pos[0]));
                n.ui.needs_frame = true;
                return true;
            },
            .motion => |pos| {
                if (!st.pressed) return false;
                if (self.on_changed) |on_changed| on_changed.call(self.valueAt(n.size.w, pos[0]));
                n.ui.needs_frame = true;
                return true;
            },
            .key => |k| {
                const on_changed = self.on_changed orelse return false;
                const step = self.keyStep();
                const v: f32 = switch (k.key) {
                    .left, .down => self.value - step,
                    .right, .up => self.value + step,
                    .page_down => self.value - step * 10,
                    .page_up => self.value + step * 10,
                    .home => self.min,
                    .end => self.max,
                    else => return false,
                };
                if (k.pressed) {
                    on_changed.call(std.math.clamp(v, self.min, self.max));
                    n.ui.needs_frame = true;
                }
                return true;
            },
            .release => |rel| {
                if (rel.button == .left and st.pressed) {
                    st.pressed = false;
                    n.ui.needs_frame = true;
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }
};
