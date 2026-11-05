//! Buttons: `FilledButton` (high emphasis), `TonalButton`
//! (medium emphasis), `OutlinedButton` (medium emphasis, with an outline)
//! and `TextButton` (low emphasis). Each is a pill with a label, an icon or
//! both, and differs from the others only in its colours.

const a11y = @import("accessibility.zig");
const Node = @import("widget.zig").WidgetNode;
const gfx = @import("gfx");
const widget = @import("widget.zig");
const Align = @import("align.zig").Align;
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const rounded_box = @import("rounded_box.zig");
const PointerInteraction = @import("pressable.zig").PointerInteraction;
const Padding = @import("padding.zig").Padding;
const Pressable = @import("pressable.zig").Pressable;
const Row = @import("flex.zig").Row;
const Text = @import("text.zig").Text;
const Icon = @import("icon.zig").Icon;
const Theme = @import("theme.zig").Theme;
const icons = @import("icons");

const Widget = widget.Widget;
const Context = widget.BuildContext;
const Callback = widget.Callback;
const Color = gfx.Color;
const RoundedBox = rounded_box.RoundedBox;

/// Every button's height, and the size of its icons.
pub const height = 40;
pub const icon_size = 18;

/// A filled button: a pill button in the primary colour for the main action on
/// a page or in a dialog.
///
/// ![The FilledButton example](images/FilledButton.png)
///
/// ```zig
/// return cx.make(kete.FilledButton{ .label = "Save", .icon = .check, .on_press = .of(state, State.save) });
/// ```
pub const FilledButton = struct {
    /// The label (or give a `child` instead).
    label: []const u8 = "",
    /// An icon before the label (or alone, without one).
    icon: ?icons.IconName = null,
    /// An icon after the label (for menu or forward buttons).
    trailing_icon: ?icons.IconName = null,
    /// Used in place of the label and icons, if given.
    child: ?Widget = null,
    /// Without it the button is disabled.
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: PointerInteraction = .{},
    };

    pub fn accessible(self: *const FilledButton, _: *Node) ?a11y.Info {
        return .{ .role = .button, .label = self.label, .activate = self.on_press, .disabled = self.on_press == null };
    }

    pub fn build(self: *const FilledButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const layer = stateLayer(self.on_press, state.interaction, 0.12);
        return buildButton(cx, state, self, if (self.on_press != null) .{
            .fg = t.on_primary,
            .bg = blendOver(t.primary, t.on_primary.withAlpha(layer)),
        } else disabledFilled(t));
    }
};

/// A tonal button: a pill button in a softer colour, with
/// medium emphasis between `FilledButton` and `OutlinedButton`.
///
/// ![The TonalButton example](images/TonalButton.png)
///
/// ```zig
/// return cx.make(kete.TonalButton{ .label = "Add to cart", .icon = .shopping_cart, .on_press = .of(state, State.save) });
/// ```
pub const TonalButton = struct {
    /// The text of the button (or give a `child` instead).
    label: []const u8 = "",
    /// An icon before the label (or alone, without one).
    icon: ?icons.IconName = null,
    /// An icon after the label (for menu or forward buttons).
    trailing_icon: ?icons.IconName = null,
    /// Used in place of the label and icons, if given.
    child: ?Widget = null,
    /// Without it the button is disabled.
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: PointerInteraction = .{},
    };

    pub fn accessible(self: *const TonalButton, _: *Node) ?a11y.Info {
        return .{ .role = .button, .label = self.label, .activate = self.on_press, .disabled = self.on_press == null };
    }

    pub fn build(self: *const TonalButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const layer = stateLayer(self.on_press, state.interaction, 0.12);
        return buildButton(cx, state, self, if (self.on_press != null) .{
            .fg = t.on_surface,
            .bg = blendOver(t.secondary_container, t.on_surface.withAlpha(layer)),
        } else disabledFilled(t));
    }
};

/// An outlined button: a pill with an outline, for important
/// actions that are not the main one.
///
/// ![The OutlinedButton example](images/OutlinedButton.png)
///
/// ```zig
/// return cx.make(kete.OutlinedButton{ .label = "Cancel", .on_press = .of(state, State.save) });
/// ```
pub const OutlinedButton = struct {
    /// The text of the button (or give a `child` instead).
    label: []const u8 = "",
    /// An icon before the label (or alone, without one).
    icon: ?icons.IconName = null,
    /// An icon after the label (for menu or forward buttons).
    trailing_icon: ?icons.IconName = null,
    /// Used in place of the label and icons, if given.
    child: ?Widget = null,
    /// Destructive action (e.g. delete or remove): shown in the theme's
    /// error colour when enabled.
    destructive: bool = false,
    /// Without it the button is disabled.
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: PointerInteraction = .{},
    };

    pub fn accessible(self: *const OutlinedButton, _: *Node) ?a11y.Info {
        return .{ .role = .button, .label = self.label, .activate = self.on_press, .disabled = self.on_press == null };
    }

    pub fn build(self: *const OutlinedButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const enabled = self.on_press != null;
        // State layers: the label's colour over the button.
        const layer = stateLayer(self.on_press, state.interaction, 0.10);
        const accent = if (self.destructive) t.@"error" else t.primary;
        return buildButton(cx, state, self, .{
            .fg = if (enabled) accent else t.on_surface.withAlpha(0.38),
            .bg = if (layer > 0) accent.withAlpha(layer) else null,
            .border = if (enabled) t.outline else t.on_surface.withAlpha(0.12),
        });
    }
};

/// A text button: a low-emphasis button without an outline or
/// background until hovered or pressed, for secondary dialog actions.
///
/// ![The TextButton example](images/TextButton.png)
///
/// ```zig
/// return cx.make(kete.TextButton{ .label = "Learn more", .trailing_icon = .arrow_forward, .on_press = .of(state, State.save) });
/// ```
pub const TextButton = struct {
    /// The text of the button (or give a `child` instead).
    label: []const u8 = "",
    /// An icon before the label (or alone, without one).
    icon: ?icons.IconName = null,
    /// An icon after the label (for menu or forward buttons).
    trailing_icon: ?icons.IconName = null,
    /// Used in place of the label and icons, if given.
    child: ?Widget = null,
    /// Without it the button is disabled.
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: PointerInteraction = .{},
    };

    pub fn accessible(self: *const TextButton, _: *Node) ?a11y.Info {
        return .{ .role = .button, .label = self.label, .activate = self.on_press, .disabled = self.on_press == null };
    }

    pub fn build(self: *const TextButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const layer = stateLayer(self.on_press, state.interaction, 0.12);
        return buildButton(cx, state, self, .{
            .fg = if (self.on_press != null) t.primary else t.on_surface.withAlpha(0.38),
            .bg = if (layer > 0) t.primary.withAlpha(layer) else null,
            .padding = 16,
        });
    }
};

/// How a button looks.
const Look = struct {
    fg: Color,
    bg: ?Color = null,
    border: ?Color = null,
    /// Either side of the label.
    padding: f32 = 24,
};

/// How strongly the button is tinted while hovered
/// or pressed.
fn stateLayer(on_press: ?Callback, i: PointerInteraction, pressed: f32) f32 {
    if (on_press == null) return 0;
    return if (i.pressed) pressed else if (i.hovered) 0.08 else 0;
}

fn disabledFilled(t: *const Theme) Look {
    return .{ .fg = t.on_surface.withAlpha(0.38), .bg = t.on_surface.withAlpha(0.12) };
}

/// The button `b` (any of the button types) drawn as `look` says.
fn buildButton(cx: *Context, state: anytype, b: anytype, look: Look) Widget {
    const label = cx.make(Text{
        .text = b.label,
        .style = .{ .size = cx.theme().label_size, .color = look.fg },
        .wrap = false,
    });
    var parts: [3]Widget = undefined;
    var n: usize = 0;
    if (b.icon) |which| {
        parts[n] = cx.make(Icon{ .icon = which, .size = icon_size, .color = look.fg });
        n += 1;
    }
    if (b.label.len > 0) {
        parts[n] = label;
        n += 1;
    }
    if (b.trailing_icon) |which| {
        parts[n] = cx.make(Icon{ .icon = which, .size = icon_size, .color = look.fg });
        n += 1;
    }
    const content = b.child orelse switch (n) {
        0 => label,
        1 => parts[0],
        else => cx.make(Row{ .spacing = 8, .fill = false, .cross_axis_alignment = .center, .children = parts[0..n] }),
    };
    // Icons without a label (one, or one and a trailing arrow, say) are as
    // compact as an icon button.
    const icon_only = b.child == null and b.label.len == 0 and n > 0;
    const h_pad: f32 = if (icon_only) (height - icon_size) / 2 else look.padding;
    return cx.make(Pressable{
        .on_press = b.on_press,
        .interaction = &state.interaction,
        .child = cx.make(RoundedBox{
            .color = look.bg,
            .border_color = look.border,
            .radius = .all(height / 2),
            .child = cx.make(ConstrainedBox{
                .constraints = .{ .min_w = if (icon_only) height else 48, .min_h = height },
                .child = cx.make(Padding{
                    .padding = .symmetric(h_pad, 0),
                    .child = cx.make(Align{ .width_factor = 1, .height_factor = 1, .child = content }),
                }),
            }),
        }),
    });
}

fn blendOver(base: Color, top: Color) Color {
    const a = top.a;
    return .{
        .r = base.r * (1 - a) + top.r * a,
        .g = base.g * (1 - a) + top.g * a,
        .b = base.b * (1 - a) + top.b * a,
        .a = base.a,
    };
}
