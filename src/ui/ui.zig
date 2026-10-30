//! Kete's declarative widget toolkit, with the look of Material 3. An app describes
//! its UI as a tree of widgets, made again each frame from its state;
//! the toolkit keeps what persists (state, layout) between frames, lays
//! the tree out, paints it with the `gfx` canvas and sends it pointer
//! and keyboard events.
//!
//! There is one kind of widget: any struct. One with `build` is made of
//! other widgets, and one with a `State` type keeps that state between
//! frames (so there is no separate stateless and stateful widget):
//!
//!     const Counter = struct {
//!         label: []const u8,
//!         pub const State = struct {
//!             count: u32 = 0,
//!             fn add(s: *State) void { s.count += 1; }
//!         };
//!         pub fn build(self: *const Counter, cx: *ui.BuildContext, state: *State) ui.Widget {
//!             return cx.make(ui.Row{ .spacing = 12, .children = cx.makeAll(.{
//!                 ui.Text{ .text = cx.fmt("{s}: {d}", .{ self.label, state.count }) },
//!                 ui.OutlinedButton{ .label = "Add", .on_press = .of(state, State.add) },
//!             }) });
//!         }
//!     };
//!
//! Any struct with `paint` draws whatever it likes: shapes and text on the
//! canvas (`p.canvas()`), or its own draws straight into the target frame
//! (`p.gpu(...)`), layered in the tree's order. `layout` and `event` give it
//! its own size and input.
//!
//! Layout never fails: unbounded space, impossible constraints and
//! children that do not fit all still give a layout. What overflows is
//! clipped and its edges are striped black and yellow. It is better to
//! look wrong than not to work.

pub const geometry = @import("geometry.zig");
pub const widget = @import("widget.zig");
pub const sized_box = @import("sized_box.zig");
pub const constrained_box = @import("constrained_box.zig");
pub const padding = @import("padding.zig");
pub const @"align" = @import("align.zig");
pub const flex = @import("flex.zig");
pub const expanded = @import("expanded.zig");
pub const grid = @import("grid.zig");
pub const overlay = @import("overlay.zig");
pub const rounded_box = @import("rounded_box.zig");
pub const pressable = @import("pressable.zig");
pub const drag = @import("drag.zig");
pub const text = @import("text.zig");
pub const theme = @import("theme.zig");
pub const button = @import("button.zig");
pub const icon_button = @import("icon_button.zig");
pub const pill_bar = @import("pill_bar.zig");
pub const spinner = @import("spinner.zig");
pub const progress_bar = @import("progress_bar.zig");
pub const slider = @import("slider.zig");
pub const dropdown_menu = @import("dropdown_menu.zig");
pub const divider = @import("divider.zig");
pub const card = @import("card.zig");
pub const list_item = @import("list_item.zig");
pub const chip = @import("chip.zig");
pub const badge = @import("badge.zig");
pub const navigation_rail = @import("navigation_rail.zig");
pub const tabs = @import("tabs.zig");
pub const dialog = @import("dialog.zig");
pub const snackbar = @import("snackbar.zig");
pub const tooltip = @import("tooltip.zig");
pub const control = @import("control.zig");
pub const checkbox = @import("checkbox.zig");
pub const radio = @import("radio.zig");
pub const @"switch" = @import("switch.zig");
pub const text_field = @import("text_field.zig");
pub const text_area = @import("text_area.zig");
pub const menu = @import("menu.zig");
pub const title_bar = @import("title_bar.zig");
pub const bar_button = @import("bar_button.zig");
pub const scroll_view = @import("scroll_view.zig");
pub const icon = @import("icon.zig");
pub const image = @import("image.zig");
pub const image_loader = @import("image_loader.zig");
pub const qr_code = @import("qr_code.zig");
pub const accessibility = @import("accessibility.zig");
pub const focus = @import("focus.zig");
pub const atspi = @import("atspi.zig");
pub const map_view = @import("map_view.zig");
pub const themed = @import("themed.zig");
pub const animated = @import("animated.zig");
pub const easing = @import("easing.zig");
pub const Easing = easing.Easing;
pub const opengl_area = @import("opengl_area.zig");
pub const vulkan_area = @import("vulkan_area.zig");
pub const metal_area = @import("metal_area.zig");
pub const d3d11_area = @import("d3d11_area.zig");
const icons = @import("icons");
pub const IconName = icons.IconName;
pub const painter = @import("painter.zig");
pub const damage = @import("damage.zig");
pub const runtime = @import("runtime.zig");

pub const Size = geometry.Size;
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Constraints = geometry.Constraints;
pub const Insets = geometry.Insets;
pub const Alignment = geometry.Alignment;

pub const Widget = widget.Widget;
pub const BuildContext = widget.BuildContext;
pub const WidgetAnchor = widget.WidgetAnchor;
pub const BackendInfo = widget.BackendInfo;
pub const WidgetNode = widget.WidgetNode;
pub const Event = widget.Event;
pub const PointerCursor = widget.PointerCursor;
pub const TextInputInfo = widget.TextInputInfo;
pub const Callback = widget.Callback;
pub const ValueCallback = widget.ValueCallback;

pub const PointerButton = widget.PointerButton;
pub const KeyboardKey = widget.KeyboardKey;

pub const SizedBox = sized_box.SizedBox;
pub const ConstrainedBox = constrained_box.ConstrainedBox;
pub const Padding = padding.Padding;
pub const Align = @"align".Align;
pub const Row = flex.Row;
pub const Column = flex.Column;
pub const Expanded = expanded.Expanded;
pub const Grid = grid.Grid;
pub const Overlay = overlay.Overlay;
pub const RoundedBox = rounded_box.RoundedBox;
pub const Pressable = pressable.Pressable;
pub const PointerInteraction = pressable.PointerInteraction;
pub const Draggable = drag.Draggable;
pub const DropTarget = drag.DropTarget;
pub const MainAxisAlignment = flex.MainAxisAlignment;
pub const CrossAxisAlignment = flex.CrossAxisAlignment;

pub const Text = text.Text;
pub const TextStyle = text.TextStyle;
pub const TextAlign = text.TextAlign;

pub const Theme = theme.Theme;
pub const Themed = themed.Themed;
pub const OutlinedButton = button.OutlinedButton;
pub const FilledButton = button.FilledButton;
pub const TonalButton = button.TonalButton;
pub const TextButton = button.TextButton;
pub const IconButton = icon_button.IconButton;
pub const PillBar = pill_bar.PillBar;
pub const PillButton = pill_bar.PillButton;
pub const Spinner = spinner.Spinner;
pub const ProgressBar = progress_bar.ProgressBar;
pub const Slider = slider.Slider;
pub const DropdownMenu = dropdown_menu.DropdownMenu;
pub const Select = dropdown_menu.Select;
pub const HorizontalDivider = divider.HorizontalDivider;
pub const VerticalDivider = divider.VerticalDivider;
pub const Card = card.Card;
pub const ListItem = list_item.ListItem;
pub const Chip = chip.Chip;
pub const Badge = badge.Badge;
pub const NavigationRail = navigation_rail.NavigationRail;
pub const TabBar = tabs.TabBar;
pub const Tab = tabs.Tab;
pub const Dialog = dialog.Dialog;
pub const Snackbar = snackbar.Snackbar;
pub const Tooltip = tooltip.Tooltip;
pub const Checkbox = checkbox.Checkbox;
pub const CheckboxRow = checkbox.CheckboxRow;
pub const Radio = radio.Radio;
pub const RadioRow = radio.RadioRow;
pub const Switch = @"switch".Switch;
pub const SwitchRow = @"switch".SwitchRow;
pub const TextField = text_field.TextField;
pub const TextArea = text_area.TextArea;
pub const TextDocument = text_area.Document;
pub const Menu = menu.Menu;
pub const MenuItem = menu.Item;
pub const TitleBar = title_bar.TitleBar;
pub const BarButton = bar_button.BarButton;
pub const ScrollView = scroll_view.ScrollView;
pub const Icon = icon.Icon;
pub const Image = image.Image;
pub const QrCode = qr_code.QrCode;
pub const Accessible = accessibility.Accessible;
pub const AccessibleInfo = accessibility.Info;
pub const MapView = map_view.MapView;
pub const MapSource = map_view.MapSource;
pub const MapStyle = map_view.MapStyle;
pub const MapPosition = map_view.MapPosition;
pub const AnimatedWidget = animated.AnimatedWidget;
pub const OpenGlArea = opengl_area.OpenGlArea;
pub const VulkanArea = vulkan_area.VulkanArea;
pub const MetalArea = metal_area.MetalArea;
pub const D3D11Area = d3d11_area.D3D11Area;

pub const Painter = painter.Painter;
pub const WindowUi = runtime.WindowUi;
pub const SharedResources = runtime.SharedResources;
pub const WindowDragArea = title_bar.WindowDragArea;
pub const App = runtime.App;
/// An app's window (see `App.openWindow`).
pub const Window = runtime.App.Window;
pub const Clipboard = runtime.Clipboard;
pub const Waker = runtime.Waker;

test {
    _ = geometry;
    _ = widget;
    _ = sized_box;
    _ = constrained_box;
    _ = padding;
    _ = @"align";
    _ = flex;
    _ = expanded;
    _ = grid;
    _ = overlay;
    _ = rounded_box;
    _ = pressable;
    _ = text;
    _ = theme;
    _ = button;
    _ = icon_button;
    _ = pill_bar;
    _ = spinner;
    _ = progress_bar;
    _ = slider;
    _ = dropdown_menu;
    _ = divider;
    _ = card;
    _ = list_item;
    _ = chip;
    _ = badge;
    _ = navigation_rail;
    _ = tabs;
    _ = dialog;
    _ = snackbar;
    _ = tooltip;
    _ = control;
    _ = checkbox;
    _ = radio;
    _ = @"switch";
    _ = text_field;
    _ = text_area;
    _ = menu;
    _ = title_bar;
    _ = bar_button;
    _ = scroll_view;
    _ = icon;
    _ = image;
    _ = image_loader;
    _ = qr_code;
    _ = accessibility;
    _ = focus;
    _ = atspi;
    _ = map_view;
    _ = @import("map/projection.zig");
    _ = @import("map/tiles.zig");
    _ = @import("map/style.zig");
    _ = @import("map/tile_painter.zig");
    _ = themed;
    _ = animated;
    _ = easing;
    _ = opengl_area;
    _ = vulkan_area;
    _ = metal_area;
    _ = d3d11_area;
    _ = painter;
    _ = damage;
    _ = runtime;
    _ = @import("tests.zig");
}
