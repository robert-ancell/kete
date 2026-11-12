//! Fonts from files: reading one (`read`), and finding the ones kete draws
//! with among the system's fonts (`find`), for a kete built without its
//! own (`-Dembed-fonts=false`).
//!
//! Fonts are looked for, by file name, in the directories `KETE_FONT_PATH`
//! names (separated as `PATH` is), then the user's and the system's font
//! directories (`searchDirs`), and the directories in them.

const std = @import("std");
const builtin = @import("builtin");

/// The biggest font file read.
pub const max_size = 64 << 20;

/// How deep into a font directory's directories fonts are looked for
/// (`/usr/share/fonts/truetype/fira/`, say).
pub const max_depth = 4;

/// Reads the font file at `path` (allocated in `gpa`).
pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_size));
}

/// The directories fonts are looked for in, in order (each allocated in
/// `gpa`, as is the list: see `freeDirs`): those `KETE_FONT_PATH` names,
/// then the user's, then the system's.
pub fn searchDirs(gpa: std.mem.Allocator, environ: std.process.Environ) ![][]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    errdefer freeDirs(gpa, dirs.items);
    defer dirs.deinit(gpa);

    if (env(gpa, environ, "KETE_FONT_PATH")) |list| {
        defer gpa.free(list);
        var it = std.mem.tokenizeScalar(u8, list, if (builtin.os.tag == .windows) ';' else ':');
        while (it.next()) |d| try dirs.append(gpa, try gpa.dupe(u8, d));
    }

    switch (builtin.os.tag) {
        .windows => {
            if (env(gpa, environ, "LOCALAPPDATA")) |local| {
                defer gpa.free(local);
                try dirs.append(gpa, try std.fs.path.join(gpa, &.{ local, "Microsoft", "Windows", "Fonts" }));
            }
            const windir = env(gpa, environ, "WINDIR") orelse try gpa.dupe(u8, "C:\\Windows");
            defer gpa.free(windir);
            try dirs.append(gpa, try std.fs.path.join(gpa, &.{ windir, "Fonts" }));
        },
        .macos => {
            if (env(gpa, environ, "HOME")) |home| {
                defer gpa.free(home);
                try dirs.append(gpa, try std.fs.path.join(gpa, &.{ home, "Library", "Fonts" }));
            }
            for ([_][]const u8{ "/Library/Fonts", "/System/Library/Fonts" }) |d| try dirs.append(gpa, try gpa.dupe(u8, d));
        },
        else => {
            // The XDG base directories' fonts, and ~/.fonts.
            if (env(gpa, environ, "XDG_DATA_HOME")) |data_home| {
                defer gpa.free(data_home);
                try dirs.append(gpa, try std.fs.path.join(gpa, &.{ data_home, "fonts" }));
            } else if (env(gpa, environ, "HOME")) |home| {
                defer gpa.free(home);
                try dirs.append(gpa, try std.fs.path.join(gpa, &.{ home, ".local", "share", "fonts" }));
            }
            if (env(gpa, environ, "HOME")) |home| {
                defer gpa.free(home);
                try dirs.append(gpa, try std.fs.path.join(gpa, &.{ home, ".fonts" }));
            }
            const data_dirs = env(gpa, environ, "XDG_DATA_DIRS") orelse try gpa.dupe(u8, "/usr/local/share:/usr/share");
            defer gpa.free(data_dirs);
            var it = std.mem.tokenizeScalar(u8, data_dirs, ':');
            while (it.next()) |d| try dirs.append(gpa, try std.fs.path.join(gpa, &.{ d, "fonts" }));
        },
    }
    return dirs.toOwnedSlice(gpa);
}

pub fn freeDirs(gpa: std.mem.Allocator, dirs: []const []const u8) void {
    for (dirs) |d| gpa.free(d);
    gpa.free(dirs);
}

/// An environment variable's value (allocated in `gpa`), if it is set and
/// not empty.
fn env(gpa: std.mem.Allocator, environ: std.process.Environ, key: []const u8) ?[]u8 {
    const v = environ.getAlloc(gpa, key) catch return null;
    if (v.len == 0) {
        gpa.free(v);
        return null;
    }
    return v;
}

/// Finds the files called `names` in `dirs` (or the directories in them,
/// `max_depth` deep): each one's path (allocated in `gpa`) goes in `found`
/// at its name's index, the first found, or null if none is. Directories
/// that cannot be read are passed over.
pub fn find(io: std.Io, gpa: std.mem.Allocator, dirs: []const []const u8, names: []const []const u8, found: []?[]u8) !void {
    std.debug.assert(found.len == names.len);
    @memset(found, null);
    errdefer for (found) |*f| if (f.*) |p| {
        gpa.free(p);
        f.* = null;
    };
    for (dirs) |dir_path| {
        // All found: no need to look further.
        if (for (found) |f| {
            if (f == null) break false;
        } else true) return;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            switch (entry.kind) {
                .directory => if (entry.depth() < max_depth) walker.enter(io, entry) catch {},
                .file, .sym_link => for (names, found) |name, *f| {
                    if (f.* == null and std.mem.eql(u8, entry.basename, name)) {
                        f.* = try std.fs.path.join(gpa, &.{ dir_path, entry.path });
                    }
                },
                else => {},
            }
        }
    }
}

const testing = std.testing;

test "fonts are found by name in the directories given, and those in them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a/truetype/fira");
    try tmp.dir.createDirPath(testing.io, "b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/truetype/fira/Text.ttf", .data = "text" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/Text.ttf", .data = "later" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/Emoji.ttf", .data = "emoji" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const a = try std.fs.path.join(testing.allocator, &.{ root, "a" });
    defer testing.allocator.free(a);
    const b = try std.fs.path.join(testing.allocator, &.{ root, "b" });
    defer testing.allocator.free(b);

    var found: [3]?[]u8 = undefined;
    try find(testing.io, testing.allocator, &.{ "/no/such/dir", a, b }, &.{ "Text.ttf", "Emoji.ttf", "Missing.ttf" }, &found);
    defer for (found) |f| if (f) |p| testing.allocator.free(p);
    // The first directory's, though deep in it.
    const text = try read(testing.io, testing.allocator, found[0].?);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("text", text);
    const emoji = try read(testing.io, testing.allocator, found[1].?);
    defer testing.allocator.free(emoji);
    try testing.expectEqualStrings("emoji", emoji);
    try testing.expectEqual(@as(?[]u8, null), found[2]);
}

test "KETE_FONT_PATH's directories are looked in first" {
    // An environment of the test's own (Windows has only the process's).
    if (std.process.Environ.Block != std.process.Environ.PosixBlock) return error.SkipZigTest;
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    try map.put("KETE_FONT_PATH", "/one:/two");
    try map.put("HOME", "/home/me");
    const block = try map.createPosixBlock(testing.allocator, .{});
    defer block.deinit(testing.allocator);
    const dirs = try searchDirs(testing.allocator, .{ .block = block });
    defer freeDirs(testing.allocator, dirs);
    try testing.expect(dirs.len > 2);
    try testing.expectEqualStrings("/one", dirs[0]);
    try testing.expectEqualStrings("/two", dirs[1]);
}
