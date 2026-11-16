//! LeftToRight: what stays left to right in a right-to-left interface.

const widget = @import("widget.zig");

const Widget = widget.Widget;

/// Its child laid out left to right however the interface runs (see
/// `SharedResources.right_to_left`): not mirrored. For what has a left and
/// right of its own: a drawing of a board, a map, a timeline, a keyboard.
pub const LeftToRight = struct {
    child: Widget,

    pub const left_to_right = true;
};
