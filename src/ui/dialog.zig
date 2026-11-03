//! Dialog: a modal dialog, shown centered over a dimmed scrim
//! backdrop with an optional icon, title, description, custom content and
//! action buttons.

const a11y = @import("accessibility.zig");
const gfx = @import("gfx");
const icons = @import("icons");
const widget = @import("widget.zig");
const Align = @import("align.zig").Align;
const Column = @import("flex.zig").Column;
const RoundedBox = @import("rounded_box.zig").RoundedBox;
const FilledButton = @import("button.zig").FilledButton;
const TextButton = @import("button.zig").TextButton;
const Icon = @import("icon.zig").Icon;
const Overlay = @import("overlay.zig").Overlay;
const Padding = @import("padding.zig").Padding;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;

const Widget = widget.Widget;
const Context = widget.BuildContext;
const Node = widget.WidgetNode;
const Event = widget.Event;
const Callback = widget.Callback;

/// A dialog: a card over a dimmed scrim, to ask or tell the user
/// something before going on.
///
/// ![The Dialog example](images/Dialog.png)
///
/// ```zig
/// return cx.make(kete.Dialog{
///     .icon = .delete,
///     .title = "Delete the file?",
///     .description = "It will be removed from every device.",
///     .confirm_label = "Delete",
///     .on_confirm = .of(state, State.save),
///     .dismiss_label = "Cancel",
///     .on_dismiss = .of(state, State.save),
///     .child = cx.make(kete.SizedBox{}),
/// });
/// ```
pub const Dialog = struct {
    /// Whether the dialog is shown over its `child`.
    open: bool = true,
    /// An icon above the title.
    icon: ?icons.IconName = null,
    /// The dialog's title.
    title: []const u8,
    /// Text under the title.
    description: []const u8 = "",
    /// A widget under the description.
    content: ?Widget = null,
    /// The text of the confirming button.
    confirm_label: []const u8 = "OK",
    /// Called when the confirming button is pressed.
    on_confirm: ?Callback = null,
    /// The text of the button that dismisses the dialog (none, if empty).
    dismiss_label: []const u8 = "",
    /// Called when the dialog is dismissed: its dismissing button, Escape, or a press outside it.
    on_dismiss: ?Callback = null,
    /// The dialog's width, in pixels.
    width: f32 = 360,
    /// Optional underlying content; when given, the dialog overlays it
    /// when `open` is true.
    child: ?Widget = null,

    pub fn accessible(self: *const Dialog, _: *Node) ?a11y.Info {
        if (!self.open) return null;
        return .{ .role = .dialog, .label = self.title, .description = self.description, .modal = true };
    }

    pub fn build(self: *const Dialog, cx: *Context) Widget {
        if (!self.open) return self.child orelse cx.make(SizedBox.empty);
        const t = cx.theme();

        var items: [5]Widget = undefined;
        var count: usize = 0;

        if (self.icon) |ic| {
            items[count] = cx.make(Align{ .height_factor = 1, .child = cx.make(Icon{ .icon = ic, .size = 28, .color = t.primary }) });
            count += 1;
        }

        if (self.title.len > 0) {
            items[count] = cx.make(Text{
                .text = self.title,
                .style = .{ .size = t.title_size, .color = t.on_surface },
                .text_align = if (self.icon != null) .center else .start,
            });
            count += 1;
        }

        if (self.description.len > 0) {
            items[count] = cx.make(Text{
                .text = self.description,
                .style = .{ .size = t.body_size, .color = t.on_surface_variant },
            });
            count += 1;
        }

        if (self.content) |body| {
            items[count] = body;
            count += 1;
        }

        var actions: [2]Widget = undefined;
        var action_count: usize = 0;
        if (self.dismiss_label.len > 0) {
            actions[action_count] = cx.make(TextButton{
                .label = self.dismiss_label,
                .on_press = self.on_dismiss,
            });
            action_count += 1;
        }
        if (self.confirm_label.len > 0) {
            actions[action_count] = cx.make(FilledButton{
                .label = self.confirm_label,
                .on_press = self.on_confirm,
            });
            action_count += 1;
        }
        if (action_count > 0) {
            items[count] = cx.make(Padding{
                .padding = .{ .top = 8 },
                .child = cx.make(Row{
                    .main_axis_alignment = .end,
                    .spacing = 8,
                    .children = actions[0..action_count],
                }),
            });
            count += 1;
        }

        const card = cx.make(SurfaceBlocker{
            .child = cx.make(RoundedBox{
                .color = t.surface_container_highest,
                .border_color = t.outline_variant,
                .radius = .all(20),
                .child = cx.make(SizedBox{
                    .width = self.width,
                    .child = cx.make(Padding{
                        .padding = .all(24),
                        .child = cx.make(Column{
                            .fill = false,
                            .cross_axis_alignment = .stretch,
                            .spacing = 14,
                            .children = items[0..count],
                        }),
                    }),
                }),
            }),
        });

        const modal = cx.make(Overlay{
            .children = cx.makeAll(.{
                Scrim{
                    .on_dismiss = self.on_dismiss,
                    .child = cx.make(RoundedBox{ .color = gfx.Color.argb(0x88000000) }),
                },
                Align.center(card),
            }),
        });

        if (self.child) |under| {
            return cx.make(Overlay{ .children = &.{ under, modal } });
        }
        return modal;
    }
};

/// Absorbs pointer events on the backdrop and calls `on_dismiss` when clicked.
const Scrim = struct {
    on_dismiss: ?Callback = null,
    child: ?Widget = null,

    pub fn cursor(_: *const Scrim, _: *Node, _: @import("geometry.zig").Point) ?widget.PointerCursor {
        return .default;
    }

    pub fn event(self: *const Scrim, n: *Node, e: Event) bool {
        switch (e) {
            .press => |pr| return pr.button == .left,
            .release => |rel| {
                if (rel.button == .left and rel.inside) {
                    if (self.on_dismiss) |cb| {
                        cb.call();
                        n.ui.needs_frame = true;
                    }
                }
                return true;
            },
            .scroll => return true,
            else => return false,
        }
    }
};

/// Stops clicks inside the dialog surface from falling through to the scrim.
pub const SurfaceBlocker = struct {
    child: ?Widget = null,

    pub fn cursor(_: *const SurfaceBlocker, _: *Node, _: @import("geometry.zig").Point) ?widget.PointerCursor {
        return .default;
    }

    pub fn event(_: *const SurfaceBlocker, _: *Node, e: Event) bool {
        return switch (e) {
            .press, .release, .scroll => true,
            else => false,
        };
    }
};
