//! Animation: widgets made afresh each frame from how far through their time
//! they are, eased by the easing functions, and widgets transformed as they
//! go (shaken, pulsed, spun).

const std = @import("std");
const kete = @import("kete");
const common = @import("common.zig");

pub const State = struct {
    plays: u64 = 0,
    shakes: u64 = 0,
    spins: u64 = 0,

    fn play(s: *State) void {
        s.plays += 1;
    }

    fn shake(s: *State) void {
        s.shakes += 1;
    }

    fn spin(s: *State) void {
        s.spins += 1;
    }
};

pub fn build(cx: *kete.BuildContext, s: *State) kete.Widget {
    const anim = common.section(cx, "Animation", "A widget made afresh each frame from how far through its time it is, eased by a tweening function", animation(cx, s));
    const moved = common.section(cx, "Transform", "Drawn moved, scaled or turned, laid out as if not", transforms(cx, s));
    return common.page(cx, &.{ anim, moved });
}

fn transforms(cx: *kete.BuildContext, s: *State) []const kete.Widget {
    return cx.makeAll(.{kete.Row{ .spacing = 24, .cross_axis_alignment = .center, .children = cx.makeAll(.{
        kete.AnimatedWidget{ .duration_ns = 500 * std.time.ns_per_ms, .restart = s.shakes, .builder = .of(s, shaking) },
        kete.AnimatedWidget{ .duration_ns = 800 * std.time.ns_per_ms, .repeat = .reverse, .builder = .func(pulsing) },
        kete.AnimatedWidget{ .duration_ns = 600 * std.time.ns_per_ms, .restart = s.spins, .builder = .of(s, spinning) },
    }) }});
}

/// A button shaken side to side, less and less.
fn shaking(s: *State, cx: *kete.BuildContext, t: f32) kete.Widget {
    const x = 8 * @sin(t * 6 * std.math.pi) * (1 - t);
    return cx.make(kete.Transform.translate(x, 0, cx.make(kete.OutlinedButton{ .label = "Shake", .on_press = .of(s, State.shake) })));
}

/// A badge growing a little and back, over and over.
fn pulsing(cx: *kete.BuildContext, t: f32) kete.Widget {
    const th = cx.theme();
    return cx.make(kete.Transform.scale(kete.Easing.inOutSine.lerp(@as(f32, 1), 1.15, t), cx.make(kete.RoundedBox{
        .color = th.@"error",
        .radius = .all(14),
        .child = cx.make(kete.Padding{ .padding = .symmetric(14, 6), .child = cx.make(kete.Text{
            .text = "Live",
            .style = .{ .color = th.on_error },
            .wrap = false,
        }) }),
    })));
}

/// A button turned once round.
fn spinning(s: *State, cx: *kete.BuildContext, t: f32) kete.Widget {
    // Back upright at the end, exactly.
    const turn = if (t >= 1) 0 else kete.Easing.inOutCubic.lerp(@as(f32, 0), 2 * std.math.pi, t);
    return cx.make(kete.Transform.rotate(turn, cx.make(kete.FilledButton{ .label = "Spin", .icon = .refresh, .on_press = .of(s, State.spin) })));
}

const Named = struct { []const u8, kete.Easing };

const easings = [_]Named{
    .{ "linear", .linear },
    .{ "inOutCubic", .inOutCubic },
    .{ "outBack", .outBack },
    .{ "outBounce", .outBounce },
    .{ "standard", .standard },
    .{ "emphasized", .emphasized_decelerate },
    .{ "steps(5)", kete.Easing.steps(5) },
};

fn animation(cx: *kete.BuildContext, s: *State) []const kete.Widget {
    const t = cx.theme();
    const rows = cx.arena.alloc(kete.Widget, easings.len + 2) catch return &.{};
    rows[0] = cx.make(kete.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = cx.makeAll(.{
        kete.FilledButton{ .label = "Play", .icon = .bolt, .on_press = .of(s, State.play) },
        common.status(cx, "Each dot crosses in a second, eased differently"),
    }) });
    for (rows[1..][0..easings.len], &easings) |*row, *e| {
        row.* = common.labelled(cx, e[0], cx.makeAll(.{kete.Expanded{ .child = cx.make(kete.RoundedBox{
            .color = t.surface_container,
            .radius = .all(14),
            .child = cx.make(kete.SizedBox{ .height = 28, .child = cx.make(kete.Padding{
                .padding = .all(4),
                .child = cx.make(kete.AnimatedWidget{
                    .duration_ns = std.time.ns_per_s,
                    .restart = s.plays,
                    .builder = .of(e, dot),
                }),
            }) }),
        }) }}));
    }
    rows[easings.len + 1] = common.labelled(cx, "Back and forth", cx.makeAll(.{kete.Expanded{ .child = cx.make(kete.SizedBox{
        .height = 28,
        .child = cx.make(kete.AnimatedWidget{
            .duration_ns = 1500 * std.time.ns_per_ms,
            .repeat = .reverse,
            .builder = .func(pulse),
        }),
    }) }}));
    return rows;
}

/// A dot across its track, eased `t` of the way along (inset a little,
/// for easings that overshoot).
fn dot(e: *const Named, cx: *kete.BuildContext, t: f32) kete.Widget {
    return cx.make(kete.Align{
        .alignment = .{ .x = e[1].lerp(@as(f32, -0.8), 0.8, t), .y = 0 },
        .child = cx.make(kete.SizedBox{ .width = 20, .height = 20, .child = cx.make(kete.RoundedBox{
            .color = cx.theme().primary,
            .radius = .all(10),
        }) }),
    });
}

/// A bar growing and changing colour, and back.
fn pulse(cx: *kete.BuildContext, t: f32) kete.Widget {
    const th = cx.theme();
    const ease = kete.Easing.inOutSine;
    return cx.make(kete.Align{
        .alignment = .center_left,
        .child = cx.make(kete.SizedBox{ .width = ease.lerp(@as(f32, 40), 240, t), .height = 28, .child = cx.make(kete.RoundedBox{
            .color = ease.lerp(th.primary, th.@"error", t),
            .radius = .all(14),
        }) }),
    });
}
