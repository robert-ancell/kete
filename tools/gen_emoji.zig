//! Makes src/ui/emoji_names.zig from Unicode's emoji-test.txt: each emoji
//! (fully qualified, without its skin-tone variants) and its name, in
//! Unicode's order (smileys and people first), for finding emoji by name
//! (see emoji.zig). Run it again for a new version of Unicode's emoji:
//!
//!     zig run tools/gen_emoji.zig -- /usr/share/unicode/emoji/emoji-test.txt src/ui/emoji_names.zig

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: gen_emoji <emoji-test.txt> <out.zig>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, args[1], arena, .limited(8 << 20));

    var out: std.ArrayList(u8) = .empty;
    var version: []const u8 = "?";
    var count: usize = 0;
    try out.appendSlice(arena,
        \\//! Made by tools/gen_emoji.zig from Unicode's emoji-test.txt: each
        \\//! emoji (fully qualified, without its skin-tone variants) and its
        \\//! name, in Unicode's order.
        \\
        \\pub const Emoji = struct { name: []const u8, text: []const u8 };
        \\
        \\pub const all = [_]Emoji{
        \\
    );
    var lines = std.mem.tokenizeAny(u8, input, "\r\n");
    while (lines.next()) |line| {
        // # Version: 15.1
        if (std.mem.startsWith(u8, line, "# Version: ")) version = line["# Version: ".len..];
        // 1F600 ; fully-qualified # 😀 E1.0 grinning face
        if (line.len == 0 or line[0] == '#') continue;
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const hash = std.mem.indexOfScalar(u8, line, '#') orelse continue;
        const status = std.mem.trim(u8, line[semi + 1 .. hash], " ");
        if (!std.mem.eql(u8, status, "fully-qualified")) continue;
        // "😀 E1.0 grinning face": the emoji, its version, its name.
        var rest = std.mem.trim(u8, line[hash + 1 ..], " ");
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        const text = rest[0..sp];
        rest = std.mem.trimStart(u8, rest[sp + 1 ..], " ");
        const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        const name = rest[sp2 + 1 ..];
        if (std.mem.indexOf(u8, name, "skin tone") != null) continue;
        try out.appendSlice(arena, "    .{ .name = \"");
        for (name) |c| {
            if (c == '"' or c == '\\') try out.append(arena, '\\');
            try out.append(arena, c);
        }
        try out.print(arena, "\", .text = \"{s}\" }},\n", .{text});
        count += 1;
    }
    try out.appendSlice(arena, "};\n");
    try out.print(arena, "\n/// The version of Unicode's emoji it is made from.\npub const version = \"{s}\";\n", .{version});
    const file = try cwd.createFile(init.io, args[2], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, out.items);
    std.debug.print("{d} emoji\n", .{count});
}
