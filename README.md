# Kete

**Kete** (KEH-teh) is a fast, efficient, and beautiful declarative UI toolkit for Zig.

It makes building modern desktop applications simple: describe your interface in clean Zig code and get a responsive, native Material 3 look and feel out of the box.

- [API Documentation](https://robert-ancell.github.io/kete/docs/)

![Kete Showcase](screenshot.png)

## Features

- **Material 3 Design:** Rich set of widgets including layout containers, buttons, selection controls, text fields, code editor, dialogs, menus, tooltips, images, interactive maps, QR codes, and 3D views, with automatic light and dark themes.
- **Cross-Platform:** Runs natively on Linux, macOS, and Windows with HiDPI scaling, multiple windows, clipboard support, keyboard navigation, and accessibility.
- **Hardware Accelerated:** Renders smoothly using Vulkan, OpenGL, Metal, or Direct3D 11, with a built-in software renderer fallback.
- **Ready to Use:** Ships with bundled fonts, color emoji, and Material Icons so applications work immediately with no extra setup.

## Example

Add Kete to your project:

```sh
zig fetch --save git+https://github.com/robert-ancell/kete
```

Import the `kete` module in your `build.zig`:

```zig
const kete_dep = b.dependency("kete", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("kete", kete_dep.module("kete"));
```

To give your app its own window and render backends (SDL, a framebuffer, a game engine) instead of Kete's, pass `.backends = false`: Kete then needs nothing of the system, not even libc (see [examples/custom_backend.zig](examples/custom_backend.zig)).

Kete includes its fonts, Fira Sans and Twemoji Mozilla (about 1.6 MB). To leave them out, pass `.@"embed-fonts" = false` (or `-Dembed-fonts=false`): Kete then reads fonts from files, the app's own (`App.Options.font_path` and `emoji_font_path`) or else its own found among the system's fonts (and in the directories `KETE_FONT_PATH` names).

Then build your UI in `src/main.zig`:

```zig
const std = @import("std");
const kete = @import("kete");

pub const Counter = struct {
    pub const State = struct {
        count: i32 = 0,

        pub fn increment(s: *State) void {
            s.count += 1;
        }

        pub fn decrement(s: *State) void {
            s.count -= 1;
        }
    };

    pub fn build(_: *const Counter, cx: *kete.BuildContext, state: *State) kete.Widget {
        return cx.make(kete.Align.center(cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .center,
            .spacing = 16,
            .children = cx.makeAll(.{
                kete.Text{
                    .text = "Hello, Kete!",
                },
                kete.Text{
                    .text = cx.fmt("Count: {d}", .{state.count}),
                },
                kete.Row{
                    .fill = false,
                    .spacing = 12,
                    .children = cx.makeAll(.{
                        kete.OutlinedButton{
                            .icon = .remove,
                            .on_press = .of(state, State.decrement),
                        },
                        kete.FilledButton{
                            .icon = .add,
                            .on_press = .of(state, State.increment),
                        },
                    }),
                },
            }),
        })));
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try kete.App.init(init.gpa, init.io, init.minimal.environ, .{
        .on_quit_request = .quit,
        .on_last_window_closed = .quit,
    });
    defer app.deinit();

    const root: Counter = .{};
    _ = try app.openWindow(.{
        .title = "Hello Kete",
        .root = .of(&root),
        .size = .{ 480, 320 },
        .on_close_request = .close,
    });
    try app.run();
}
```

## Showcase

Run the interactive widget showcase from the repository root:

```sh
zig build run-showcase
```

## Special Thanks ❤️

Kete is built on the foundations of these great projects:

- [Zig](https://ziglang.org/)
- [Material Design](https://m3.material.io/)
