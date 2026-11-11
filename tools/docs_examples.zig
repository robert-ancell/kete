//! The examples in the API reference: each widget's doc comment shows one
//! (its code, and the image `docs_images.zig` draws from it). An example
//! is a function that makes the widget, written as an app would: the
//! comment holds a copy of its body, so keep the two the same.

const std = @import("std");
const kete = @import("kete");

const Widget = kete.Widget;
const BuildContext = kete.BuildContext;
const Ui = kete.ui.WindowUi;

/// What the examples' callbacks are: they do nothing.
const State = struct {
    fn save(_: *State) void {}
    fn setOn(_: *State, _: bool) void {}
    fn setAmount(_: *State, _: f32) void {}
    fn select(_: *State, _: usize) void {}
    fn setText(_: *State, _: []const u8) void {}
    fn setQuality(_: *State, _: Quality) void {}
};
var demo_state: State = .{};
const state = &demo_state;

const Quality = enum { low, medium, high };

/// The pixels `photo` is: a gradient.
var photo_pixels: []u32 = &.{};
var photo: kete.gfx.Image = undefined;
var document: kete.TextDocument = undefined;

pub fn init(gpa: std.mem.Allocator) !void {
    const w = 160;
    const h = 100;
    photo_pixels = try gpa.alloc(u32, w * h);
    for (photo_pixels, 0..) |*px, i| {
        const x: u32 = @intCast(i % w);
        const y: u32 = @intCast(i / w);
        px.* = 0xff000000 | ((x * 255 / w) << 16) | ((y * 200 / h) << 8) | 0x90;
    }
    photo = kete.gfx.Image.init(photo_pixels, w, h);
    document = try kete.TextDocument.init(gpa, "const answer = 42;\n\nfn main() void {}");
}

pub fn deinit(gpa: std.mem.Allocator) void {
    gpa.free(photo_pixels);
    document.deinit();
}

/// An example: the widget `name`, from `build`, centred in an image
/// `width` by `height` logical pixels (just big enough for it, if not
/// given).
fn Example(comptime name_: []const u8, comptime build_: fn (*BuildContext) Widget, comptime options: struct {
    width: ?u32 = null,
    height: ?u32 = null,
    /// Done after the first frame (to open a menu, or hover).
    after: ?*const fn (*Ui) void = null,
}) type {
    return struct {
        pub const name = name_;
        pub const width = options.width;
        pub const height = options.height;
        pub const after: ?*const fn (*Ui) void = options.after;
        pub const Root = struct {
            /// Whether it is only to be measured (at its natural size, at
            /// the top left).
            measure: bool = false,

            pub fn build(self: *const Root, cx: *BuildContext) Widget {
                const widget = build_(cx);
                if (self.measure) return cx.make(kete.Align{ .alignment = .top_left, .child = cx.make(kete.Padding{ .padding = .all(16), .child = widget }) });
                return cx.make(kete.Align.center(widget));
            }
        };
    };
}

fn box(cx: *BuildContext, label: []const u8, w: f32, h: f32) Widget {
    const t = cx.theme();
    return cx.make(kete.RoundedBox{
        .color = t.primary_container,
        .radius = .all(8),
        .child = cx.make(kete.SizedBox{ .width = w, .height = h, .child = cx.make(kete.Align.center(cx.make(kete.Text{
            .text = label,
            .style = .{ .color = t.on_primary_container },
            .wrap = false,
        }))) }),
    });
}

// --- Buttons -----------------------------------------------------------------

fn filledButton(cx: *BuildContext) Widget {
    return cx.make(kete.FilledButton{ .label = "Save", .icon = .check, .on_press = .of(state, State.save) });
}

fn tonalButton(cx: *BuildContext) Widget {
    return cx.make(kete.TonalButton{ .label = "Add to cart", .icon = .shopping_cart, .on_press = .of(state, State.save) });
}

fn outlinedButton(cx: *BuildContext) Widget {
    return cx.make(kete.OutlinedButton{ .label = "Cancel", .on_press = .of(state, State.save) });
}

fn textButton(cx: *BuildContext) Widget {
    return cx.make(kete.TextButton{ .label = "Learn more", .trailing_icon = .arrow_forward, .on_press = .of(state, State.save) });
}

fn iconButton(cx: *BuildContext) Widget {
    return cx.make(kete.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
        kete.IconButton{ .icon = .favorite, .on_press = .of(state, State.save) },
        kete.IconButton{ .icon = .favorite, .variant = .filled, .on_press = .of(state, State.save) },
        kete.IconButton{ .icon = .favorite, .variant = .tonal, .on_press = .of(state, State.save) },
        kete.IconButton{ .icon = .favorite, .variant = .outlined, .selected = true, .on_press = .of(state, State.save) },
    }) });
}

fn pillBar(cx: *BuildContext) Widget {
    return cx.make(kete.PillBar{ .children = cx.makeAll(.{
        kete.PillButton{ .label = "Day", .selected = true, .first = true, .on_press = .of(state, State.save) },
        kete.PillButton{ .label = "Week", .selected = false, .on_press = .of(state, State.save) },
        kete.PillButton{ .label = "Month", .selected = false, .last = true, .on_press = .of(state, State.save) },
    }) });
}

// --- Selection ---------------------------------------------------------------

fn checkbox(cx: *BuildContext) Widget {
    return cx.make(kete.Row{ .fill = false, .spacing = 16, .children = cx.makeAll(.{
        kete.Checkbox{ .value = true, .on_changed = .of(state, State.setOn) },
        kete.Checkbox{ .value = false, .on_changed = .of(state, State.setOn) },
    }) });
}

fn checkboxRow(cx: *BuildContext) Widget {
    return cx.make(kete.CheckboxRow{ .value = true, .label = "Send me updates", .on_changed = .of(state, State.setOn) });
}

fn radio(cx: *BuildContext) Widget {
    return cx.make(kete.Row{ .fill = false, .spacing = 16, .children = cx.makeAll(.{
        kete.Radio(Quality){ .value = .low, .group_value = .low, .on_changed = .of(state, State.setQuality) },
        kete.Radio(Quality){ .value = .high, .group_value = .low, .on_changed = .of(state, State.setQuality) },
    }) });
}

fn radioRow(cx: *BuildContext) Widget {
    return cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .start, .children = cx.makeAll(.{
        kete.RadioRow(Quality){ .value = .low, .group_value = .medium, .label = "Low", .on_changed = .of(state, State.setQuality) },
        kete.RadioRow(Quality){ .value = .medium, .group_value = .medium, .label = "Medium", .on_changed = .of(state, State.setQuality) },
        kete.RadioRow(Quality){ .value = .high, .group_value = .medium, .label = "High", .on_changed = .of(state, State.setQuality) },
    }) });
}

fn switchWidget(cx: *BuildContext) Widget {
    return cx.make(kete.Row{ .fill = false, .spacing = 16, .children = cx.makeAll(.{
        kete.Switch{ .value = true, .on_changed = .of(state, State.setOn) },
        kete.Switch{ .value = false, .on_changed = .of(state, State.setOn) },
    }) });
}

fn switchRow(cx: *BuildContext) Widget {
    return cx.make(kete.SwitchRow{ .value = true, .label = "Wi-Fi", .on_changed = .of(state, State.setOn) });
}

fn slider(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 240, .child = cx.make(kete.Slider{ .value = 0.4, .on_changed = .of(state, State.setAmount) }) });
}

fn dropdownMenu(cx: *BuildContext) Widget {
    return cx.make(kete.DropdownMenu{
        .options = &.{
            .{ .label = "Light", .leading_icon = .light_mode },
            .{ .label = "Dark", .leading_icon = .dark_mode },
            .{ .label = "Automatic", .leading_icon = .settings },
        },
        .selected = 1,
        .on_selected = .of(state, State.select),
        .width = 180,
    });
}

fn select(cx: *BuildContext) Widget {
    return cx.make(kete.Select(Quality){
        .options = &.{
            .labeled(.low, "Low"),
            .labeled(.medium, "Medium"),
            .labeled(.high, "High"),
        },
        .value = .medium,
        .on_changed = .of(state, State.setQuality),
        .width = 180,
    });
}

// --- Text --------------------------------------------------------------------

fn text(cx: *BuildContext) Widget {
    const t = cx.theme();
    return cx.make(kete.SizedBox{ .width = 280, .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .start, .spacing = 8, .children = cx.makeAll(.{
        kete.Text{ .text = "Headline", .style = .{ .size = 28, .color = t.primary }, .wrap = false },
        kete.Text{ .text = "Text wraps to the width it is given, and can be aligned in it." },
    }) }) });
}

fn textField(cx: *BuildContext) Widget {
    return cx.make(kete.Column{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
        kete.TextField{ .placeholder = "Search", .on_changed = .of(state, State.setText) },
        kete.TextField{ .initial = "Ada Lovelace", .on_changed = .of(state, State.setText) },
    }) });
}

fn textArea(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 320, .height = 96, .child = cx.make(kete.TextArea{ .doc = &document }) });
}

fn icon(cx: *BuildContext) Widget {
    return cx.make(kete.Row{ .fill = false, .spacing = 16, .children = cx.makeAll(.{
        kete.Icon{ .icon = .home },
        kete.Icon{ .icon = .settings, .size = 32 },
        kete.Icon{ .icon = .favorite, .size = 40, .color = cx.theme().primary },
    }) });
}

fn image(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 160, .height = 100, .child = cx.make(kete.Image{ .source = .{ .image = &photo } }) });
}

fn qrCode(cx: *BuildContext) Widget {
    return cx.make(kete.QrCode{ .text = "https://example.com", .size = 120 });
}

// --- Content -----------------------------------------------------------------

fn card(cx: *BuildContext) Widget {
    return cx.make(kete.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
        kete.Card{ .child = cx.make(kete.Text{ .text = "Filled", .wrap = false }) },
        kete.Card{ .variant = .elevated, .child = cx.make(kete.Text{ .text = "Elevated", .wrap = false }) },
        kete.Card{ .variant = .outlined, .child = cx.make(kete.Text{ .text = "Outlined", .wrap = false }) },
    }) });
}

fn listItem(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 320, .child = cx.make(kete.Column{ .fill = false, .children = cx.makeAll(.{
        kete.ListItem{ .headline = "Photos", .supporting_text = "Jan 9, 2026", .leading_icon = .image, .trailing_icon = .chevron_right, .on_press = .of(state, State.save) },
        kete.ListItem{ .headline = "Documents", .supporting_text = "Updated yesterday", .leading_icon = .folder, .trailing_text = "12 items", .selected = true, .on_press = .of(state, State.save) },
    }) }) });
}

fn chip(cx: *BuildContext) Widget {
    return cx.make(kete.Row{ .fill = false, .spacing = 8, .children = cx.makeAll(.{
        kete.Chip{ .label = "Filter", .on_press = .of(state, State.save) },
        kete.Chip{ .label = "Selected", .selected = true, .on_press = .of(state, State.save) },
        kete.Chip{ .label = "Remove", .icon = .tag, .on_remove = .of(state, State.save) },
    }) });
}

fn badge(cx: *BuildContext) Widget {
    return cx.make(kete.Row{ .fill = false, .spacing = 24, .children = cx.makeAll(.{
        kete.Badge{ .count = 3, .child = cx.make(kete.Icon{ .icon = .mail }) },
        kete.Badge{ .count = 128, .child = cx.make(kete.Icon{ .icon = .notifications }) },
        kete.Badge{ .label = "", .child = cx.make(kete.Icon{ .icon = .chat }) },
    }) });
}

fn progressBar(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 240, .child = cx.make(kete.ProgressBar{ .value = 0.6 }) });
}

fn spinner(cx: *BuildContext) Widget {
    return cx.make(kete.Spinner{ .size = 40 });
}

fn horizontalDivider(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 240, .child = cx.make(kete.Column{ .fill = false, .spacing = 8, .children = cx.makeAll(.{
        kete.Text{ .text = "Above" },
        kete.HorizontalDivider{},
        kete.Text{ .text = "Below" },
    }) }) });
}

fn verticalDivider(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .height = 40, .child = cx.make(kete.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
        kete.Text{ .text = "Left" },
        kete.VerticalDivider{},
        kete.Text{ .text = "Right" },
    }) }) });
}

// --- Navigation --------------------------------------------------------------

fn navigationRail(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .height = 180, .child = cx.make(kete.NavigationRail{
        .items = &.{
            .{ .label = "Home", .icon = .home },
            .{ .label = "Inbox", .icon = .mail, .badge = 4 },
            .{ .label = "Settings", .icon = .settings },
        },
        .selected = 0,
        .on_select = .of(state, State.select),
        .width = 220,
    }) });
}

fn tabBar(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 480, .child = cx.make(kete.TabBar{
        .tabs = &.{
            .{ .label = "Flights", .icon = .flight },
            .{ .label = "Hotels", .icon = .hotel, .badge = 2 },
            .{ .label = "Cars", .icon = .directions_car },
        },
        .selected = 1,
        .on_select = .of(state, State.select),
    }) });
}

// --- Feedback ----------------------------------------------------------------

fn snackbar(cx: *BuildContext) Widget {
    return cx.make(kete.Snackbar{
        .message = "Message archived",
        .action_label = "Undo",
        .on_action = .of(state, State.save),
        .on_dismiss = .of(state, State.save),
    });
}

fn dialog(cx: *BuildContext) Widget {
    return cx.make(kete.Dialog{
        .icon = .delete,
        .title = "Delete the file?",
        .description = "It will be removed from every device.",
        .confirm_label = "Delete",
        .on_confirm = .of(state, State.save),
        .dismiss_label = "Cancel",
        .on_dismiss = .of(state, State.save),
        .child = cx.make(kete.SizedBox{}),
    });
}

fn tooltip(cx: *BuildContext) Widget {
    return cx.make(kete.Tooltip{
        .text = "Add to favourites",
        .child = cx.make(kete.IconButton{ .icon = .favorite, .variant = .tonal, .on_press = .of(state, State.save) }),
    });
}

fn hoverTooltip(u: *Ui) void {
    const find = struct {
        fn f(n: *kete.WidgetNode) ?*kete.WidgetNode {
            if (n.widget.is(kete.Tooltip)) return n;
            for (n.children.items) |ch| if (f(ch)) |x| return x;
            return null;
        }
    }.f;
    const n = find(u.root.?) orelse return;
    const at = n.position();
    u.pointerMotion(.{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 });
}

fn menu(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{});
}

fn openMenu(u: *Ui) void {
    u.openMenu(u.root.?, .{ 24, 16 }, &.{
        .{ .label = "Cut", .leading_icon = .content_cut, .shortcut = "Ctrl+X", .on_press = .of(state, State.save) },
        .{ .label = "Copy", .leading_icon = .content_copy, .shortcut = "Ctrl+C", .on_press = .of(state, State.save) },
        .{ .label = "Paste", .leading_icon = .content_paste, .shortcut = "Ctrl+V" },
        kete.MenuItem.divider,
        .{ .label = "Sort by", .leading_icon = .sort, .submenu = &.{
            .{ .label = "Name", .kind = .radio, .checked = true, .on_press = .of(state, State.save) },
            .{ .label = "Date", .kind = .radio, .on_press = .of(state, State.save) },
        } },
        .{ .label = "Delete", .leading_icon = .delete, .destructive = true, .on_press = .of(state, State.save) },
    });
}

// --- Layout ------------------------------------------------------------------

fn row(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 320, .child = cx.make(kete.Row{
        .main_axis_alignment = .space_between,
        .cross_axis_alignment = .center,
        .children = cx.makeAll(.{
            box(cx, "A", 48, 48),
            box(cx, "B", 48, 80),
            box(cx, "C", 48, 32),
        }),
    }) });
}

fn column(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .height = 200, .child = cx.make(kete.Column{
        .main_axis_alignment = .space_between,
        .cross_axis_alignment = .start,
        .children = cx.makeAll(.{
            box(cx, "A", 80, 40),
            box(cx, "B", 120, 40),
            box(cx, "C", 60, 40),
        }),
    }) });
}

fn expanded(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 360, .child = cx.make(kete.Row{ .spacing = 8, .children = cx.makeAll(.{
        box(cx, "Fixed", 72, 48),
        kete.Expanded{ .child = box(cx, "Expanded", 0, 48) },
        kete.Expanded{ .flex = 2, .child = box(cx, "Twice as much", 0, 48) },
    }) }) });
}

fn paddingWidget(cx: *BuildContext) Widget {
    return cx.make(kete.RoundedBox{
        .border_color = cx.theme().outline,
        .child = cx.make(kete.Padding{ .padding = .symmetric(32, 12), .child = box(cx, "Padded", 80, 32) }),
    });
}

fn alignWidget(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 240, .height = 120, .child = cx.make(kete.RoundedBox{
        .border_color = cx.theme().outline,
        .child = cx.make(kete.Align{ .alignment = .bottom_right, .child = box(cx, "Corner", 72, 36) }),
    }) });
}

fn transformWidget(cx: *BuildContext) Widget {
    return cx.make(kete.Padding{ .padding = .all(16), .child = cx.make(kete.Row{ .spacing = 32, .children = cx.makeAll(.{
        kete.Transform.rotate(-std.math.pi / 12.0, box(cx, "Turned", 80, 48)),
        kete.Transform.scale(1.25, box(cx, "Scaled", 80, 48)),
        kete.Transform.translate(0, 12, box(cx, "Moved", 80, 48)),
    }) }) });
}

fn sizedBox(cx: *BuildContext) Widget {
    return cx.make(kete.RoundedBox{
        .border_color = cx.theme().outline,
        .child = cx.make(kete.SizedBox{ .width = 160, .height = 64, .child = cx.make(kete.Align.center(cx.make(kete.Text{ .text = "160 by 64", .wrap = false }))) }),
    });
}

fn constrainedBox(cx: *BuildContext) Widget {
    return cx.make(kete.RoundedBox{
        .border_color = cx.theme().outline,
        .child = cx.make(kete.ConstrainedBox{
            .constraints = .{ .min_w = 200, .min_h = 56 },
            .child = box(cx, "Small", 60, 24),
        }),
    });
}

fn roundedBox(cx: *BuildContext) Widget {
    const t = cx.theme();
    return cx.make(kete.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
        kete.RoundedBox{ .color = t.primary_container, .radius = .all(16), .child = cx.make(kete.SizedBox{ .width = 72, .height = 56 }) },
        kete.RoundedBox{ .border_color = t.primary, .border_width = 2, .radius = .all(28), .child = cx.make(kete.SizedBox{ .width = 72, .height = 56 }) },
        kete.RoundedBox{ .color = t.secondary_container, .radius = .{ .tl = 4, .tr = 24, .br = 4, .bl = 24 }, .child = cx.make(kete.SizedBox{ .width = 72, .height = 56 }) },
    }) });
}

fn overlay(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 200, .height = 120, .child = cx.make(kete.Overlay{ .children = cx.makeAll(.{
        kete.Align{ .alignment = .top_left, .child = box(cx, "Behind", 120, 72) },
        kete.Align{ .alignment = .bottom_right, .child = box(cx, "In front", 120, 72) },
    }) }) });
}

fn gridWidget(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 260, .height = 140, .child = cx.make(kete.Grid.fixed(cx, &.{
        box(cx, "1", 0, 0),
        box(cx, "2", 0, 0),
        box(cx, "3", 0, 0),
        box(cx, "4", 0, 0),
        box(cx, "5", 0, 0),
        box(cx, "6", 0, 0),
    }, .{ .w = 80, .h = 60 }, 8)) });
}

fn scrollView(cx: *BuildContext) Widget {
    return cx.make(kete.SizedBox{ .width = 240, .height = 140, .child = cx.make(kete.ScrollView{ .child = cx.make(kete.Column{
        .fill = false,
        .cross_axis_alignment = .stretch,
        .children = cx.makeAll(.{
            kete.ListItem{ .headline = "One" },
            kete.ListItem{ .headline = "Two" },
            kete.ListItem{ .headline = "Three" },
            kete.ListItem{ .headline = "Four" },
            kete.ListItem{ .headline = "Five" },
            kete.ListItem{ .headline = "Six" },
        }),
    }) }) });
}

fn themed(cx: *BuildContext) Widget {
    return cx.make(kete.Themed{ .theme = .dark, .child = cx.make(kete.Card{
        .child = cx.make(kete.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
            kete.Text{ .text = "Dark inside", .wrap = false },
            kete.FilledButton{ .label = "Go", .on_press = .of(state, State.save) },
        }) }),
    }) });
}

/// Every example, in the order of the files they are in.
pub const all = .{
    Example("FilledButton", filledButton, .{}),
    Example("TonalButton", tonalButton, .{}),
    Example("OutlinedButton", outlinedButton, .{}),
    Example("TextButton", textButton, .{}),
    Example("IconButton", iconButton, .{}),
    Example("PillBar", pillBar, .{}),
    Example("Checkbox", checkbox, .{}),
    Example("CheckboxRow", checkboxRow, .{}),
    Example("Radio", radio, .{}),
    Example("RadioRow", radioRow, .{}),
    Example("Switch", switchWidget, .{}),
    Example("SwitchRow", switchRow, .{}),
    Example("Slider", slider, .{}),
    Example("DropdownMenu", dropdownMenu, .{}),
    Example("Select", select, .{}),
    Example("Text", text, .{}),
    Example("TextField", textField, .{}),
    Example("TextArea", textArea, .{}),
    Example("Icon", icon, .{}),
    Example("Image", image, .{}),
    Example("QrCode", qrCode, .{}),
    Example("Card", card, .{}),
    Example("ListItem", listItem, .{}),
    Example("Chip", chip, .{}),
    Example("Badge", badge, .{}),
    Example("ProgressBar", progressBar, .{}),
    Example("Spinner", spinner, .{}),
    Example("HorizontalDivider", horizontalDivider, .{}),
    Example("VerticalDivider", verticalDivider, .{}),
    Example("NavigationRail", navigationRail, .{}),
    Example("TabBar", tabBar, .{}),
    Example("Snackbar", snackbar, .{}),
    Example("Dialog", dialog, .{ .width = 440, .height = 300 }),
    Example("Tooltip", tooltip, .{ .width = 200, .height = 110, .after = hoverTooltip }),
    Example("Menu", menu, .{ .width = 400, .height = 280, .after = openMenu }),
    Example("Row", row, .{}),
    Example("Column", column, .{}),
    Example("Expanded", expanded, .{}),
    Example("Padding", paddingWidget, .{}),
    Example("Align", alignWidget, .{}),
    Example("Transform", transformWidget, .{}),
    Example("SizedBox", sizedBox, .{}),
    Example("ConstrainedBox", constrainedBox, .{}),
    Example("RoundedBox", roundedBox, .{}),
    Example("Overlay", overlay, .{}),
    Example("Grid", gridWidget, .{}),
    Example("ScrollView", scrollView, .{}),
    Example("Themed", themed, .{}),
};
