//! The keys for part of the window that what is in it leaves: its
//! keyboard shortcuts (Ctrl+C, Delete, Escape, ...), whatever in it has
//! the keyboard (as Flutter's `Focus.onKeyEvent` and `CallbackShortcuts`).
//!
//! A key goes to what has the keyboard, then to what that is in, until one
//! takes it: a `KeyHandler` around it is given the keys its child does not
//! take (a text field takes what it types, and Backspace; a button, Space
//! and Enter). With nothing having the keyboard, a key goes to the
//! window's `KeyHandler`s, the innermost first, until one takes it.
//!
//!     cx.make(kete.KeyHandler{ .on_key = .of(state, State.key), .child = ... })
//!
//! `on_key` is given every key that comes to it, down and up, modifiers
//! too (`Event.Key`), and returns whether it took it. Keys are where they
//! are on the keyboard (`KeyboardKey`), whatever the layout: `.char` is
//! what one types, without Control.
//!
//! One that `watch`es sees every key on its way to what has the keyboard
//! in it (or, with nothing having it, every key), before it goes there,
//! and takes none: to show the keys being pressed, say, while a text field
//! in it types them.

const widget = @import("widget.zig");

const Widget = widget.Widget;
const Node = widget.WidgetNode;
const Event = widget.Event;

pub const KeyHandler = struct {
    /// Given each key that comes to it: whether it took it.
    on_key: widget.Handler(Event.Key),
    /// The part of the window whose keys it handles.
    child: ?Widget = null,
    /// It sees every key on its way (before what is in it does), and takes
    /// none (what `on_key` returns does not matter).
    watch: bool = false,

    pub fn event(self: *const KeyHandler, _: *Node, e: Event) bool {
        // A watcher has seen it already (`WindowUi.key`).
        if (self.watch) return false;
        return switch (e) {
            .key => |k| self.on_key.call(k),
            else => false,
        };
    }
};
