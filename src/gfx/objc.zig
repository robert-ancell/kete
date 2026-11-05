//! Calling Objective-C (AppKit, Metal and friends) from Zig, on macOS: the
//! Objective-C runtime, and the frameworks' C functions and constants,
//! loaded when first used (as kete loads Vulkan and EGL), so no SDK is
//! needed to build, and nothing to link but the C library.
//!
//!     const app = objc.msg(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
//!     objc.msg(void, window, "setTitle:", .{objc.nsString("Hello")});

const std = @import("std");
const builtin = @import("builtin");

pub const Id = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const Sel = ?*anyopaque;
pub const Ivar = ?*anyopaque;
/// Objective-C's BOOL (a byte: 0 or 1).
pub const Bool = u8;
pub const yes: Bool = 1;
pub const no: Bool = 0;

pub const CGFloat = f64;
pub const Point = extern struct { x: CGFloat, y: CGFloat };
pub const Size = extern struct { width: CGFloat, height: CGFloat };
pub const Rect = extern struct { origin: Point, size: Size };

pub const Error = error{ NoObjcRuntime, NoAppKit };

const Runtime = struct {
    objc: ?*anyopaque,
    appkit: ?*anyopaque,
    foundation: ?*anyopaque,
    graphics: ?*anyopaque,
    core: ?*anyopaque,
    metal: ?*anyopaque,
    msgSend: *const anyopaque,
    msgSend_stret: ?*const anyopaque,
    getClass: *const fn ([*:0]const u8) callconv(.c) Class,
    registerName: *const fn ([*:0]const u8) callconv(.c) Sel,
    allocateClassPair: *const fn (Class, [*:0]const u8, usize) callconv(.c) Class,
    registerClassPair: *const fn (Class) callconv(.c) void,
    addMethod: *const fn (Class, Sel, *const anyopaque, [*:0]const u8) callconv(.c) Bool,
    addIvar: *const fn (Class, [*:0]const u8, usize, u8, [*:0]const u8) callconv(.c) Bool,
    getInstanceVariable: *const fn (Class, [*:0]const u8) callconv(.c) Ivar,
    getIvar: *const fn (Id, Ivar) callconv(.c) Id,
    setIvar: *const fn (Id, Ivar, Id) callconv(.c) void,
    poolPush: *const fn () callconv(.c) ?*anyopaque,
    poolPop: *const fn (?*anyopaque) callconv(.c) void,
};

var runtime: ?Runtime = null;

const RTLD_NOW = 0x2;
extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// Loads the runtime and AppKit (once); an error if they are not there
/// (not macOS).
pub fn load() Error!void {
    if (runtime != null) return;
    const objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW) orelse return error.NoObjcRuntime;
    const appkit = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW) orelse return error.NoAppKit;
    const foundation = dlopen("/System/Library/Frameworks/Foundation.framework/Foundation", RTLD_NOW);
    const graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
    const core = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
    _ = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    const metal = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_NOW);
    const sym = struct {
        fn f(comptime T: type, h: ?*anyopaque, name: [*:0]const u8) Error!T {
            return @ptrCast(@alignCast(dlsym(h, name) orelse return error.NoObjcRuntime));
        }
    }.f;
    runtime = .{
        .objc = objc,
        .appkit = appkit,
        .foundation = foundation,
        .graphics = graphics,
        .core = core,
        .metal = metal,
        .msgSend = try sym(*const anyopaque, objc, "objc_msgSend"),
        .msgSend_stret = if (builtin.cpu.arch == .x86_64) try sym(*const anyopaque, objc, "objc_msgSend_stret") else null,
        .getClass = try sym(@FieldType(Runtime, "getClass"), objc, "objc_getClass"),
        .registerName = try sym(@FieldType(Runtime, "registerName"), objc, "sel_registerName"),
        .allocateClassPair = try sym(@FieldType(Runtime, "allocateClassPair"), objc, "objc_allocateClassPair"),
        .registerClassPair = try sym(@FieldType(Runtime, "registerClassPair"), objc, "objc_registerClassPair"),
        .addMethod = try sym(@FieldType(Runtime, "addMethod"), objc, "class_addMethod"),
        .addIvar = try sym(@FieldType(Runtime, "addIvar"), objc, "class_addIvar"),
        .getInstanceVariable = try sym(@FieldType(Runtime, "getInstanceVariable"), objc, "class_getInstanceVariable"),
        .getIvar = try sym(@FieldType(Runtime, "getIvar"), objc, "object_getIvar"),
        .setIvar = try sym(@FieldType(Runtime, "setIvar"), objc, "object_setIvar"),
        .poolPush = try sym(@FieldType(Runtime, "poolPush"), objc, "objc_autoreleasePoolPush"),
        .poolPop = try sym(@FieldType(Runtime, "poolPop"), objc, "objc_autoreleasePoolPop"),
    };
}

fn rt() *const Runtime {
    return &runtime.?;
}

pub fn class(name: [*:0]const u8) Class {
    return rt().getClass(name);
}

pub fn sel(name: [*:0]const u8) Sel {
    return rt().registerName(name);
}

/// Sends `name` to `target` with `args`, returning a `Ret` (not a struct
/// bigger than two words: see `msgRect`).
pub fn msg(comptime Ret: type, target: anytype, name: [*:0]const u8, args: anytype) Ret {
    const t: Id = @ptrCast(target);
    const s = sel(name);
    const A = @TypeOf(args);
    const f = rt().msgSend;
    const n = @typeInfo(A).@"struct".field_names.len;
    return switch (n) {
        0 => @as(*const fn (Id, Sel) callconv(.c) Ret, @ptrCast(@alignCast(f)))(t, s),
        1 => @as(*const fn (Id, Sel, @TypeOf(args[0])) callconv(.c) Ret, @ptrCast(@alignCast(f)))(t, s, args[0]),
        2 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1])) callconv(.c) Ret, @ptrCast(@alignCast(f)))(t, s, args[0], args[1]),
        3 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2])) callconv(.c) Ret, @ptrCast(@alignCast(f)))(t, s, args[0], args[1], args[2]),
        4 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3])) callconv(.c) Ret, @ptrCast(@alignCast(f)))(t, s, args[0], args[1], args[2], args[3]),
        5 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4])) callconv(.c) Ret, @ptrCast(@alignCast(f)))(t, s, args[0], args[1], args[2], args[3], args[4]),
        9 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4]), @TypeOf(args[5]), @TypeOf(args[6]), @TypeOf(args[7]), @TypeOf(args[8])) callconv(.c) Ret, @ptrCast(@alignCast(f)))(t, s, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8]),
        10 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4]), @TypeOf(args[5]), @TypeOf(args[6]), @TypeOf(args[7]), @TypeOf(args[8]), @TypeOf(args[9])) callconv(.c) Ret, @ptrCast(@alignCast(f)))(t, s, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9]),
        else => @compileError("too many arguments"),
    };
}

/// Sends a message that returns a rectangle (`frame`, `bounds`), which on
/// x86-64 comes back through memory.
pub fn msgRect(target: Id, name: [*:0]const u8) Rect {
    if (builtin.cpu.arch == .x86_64) {
        var out: Rect = undefined;
        const f: *const fn (*Rect, Id, Sel) callconv(.c) void = @ptrCast(@alignCast(rt().msgSend_stret.?));
        f(&out, target, sel(name));
        return out;
    }
    return msg(Rect, target, name, .{});
}

/// `[[cls alloc] init]`.
pub fn new(cls: Class) Id {
    return msg(Id, msg(Id, cls, "alloc", .{}), "init", .{});
}

/// Lets an object go (one we made, or kept with `retain`); nothing for
/// null.
pub fn release(obj: Id) void {
    if (obj != null) msg(void, obj, "release", .{});
}

/// Keeps an object (until `release`).
pub fn retain(obj: Id) Id {
    return if (obj == null) null else msg(Id, obj, "retain", .{});
}

/// An `NSString` of UTF-8 `s` (autoreleased).
pub fn nsString(s: []const u8) Id {
    const alloc_str = msg(Id, class("NSString"), "alloc", .{});
    const str = msg(Id, alloc_str, "initWithBytes:length:encoding:", .{ s.ptr, s.len, @as(usize, 4) });
    return msg(Id, str, "autorelease", .{});
}

/// The UTF-8 of an `NSString` (good while it is).
pub fn utf8(str: Id) []const u8 {
    if (str == null) return "";
    const p = msg(?[*:0]const u8, str, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

/// A pool for the objects made while it is open (`pop` lets them go).
pub fn push() ?*anyopaque {
    return rt().poolPush();
}

pub fn pop(pool: ?*anyopaque) void {
    rt().poolPop(pool);
}

/// A symbol of the frameworks (a C function, or a constant's address).
pub fn symbol(comptime T: type, name: [*:0]const u8) ?T {
    const r = rt();
    for ([_]?*anyopaque{ r.appkit, r.foundation, r.graphics, r.core, r.metal, r.objc }) |h| {
        if (dlsym(h, name)) |p| return @ptrCast(@alignCast(p));
    }
    return null;
}

/// A block (`^`) without captures: what an API that takes one is given.
pub const Block = extern struct {
    isa: ?*const anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};
const BlockDescriptor = extern struct { reserved: c_ulong = 0, size: c_ulong };
const block_descriptor: BlockDescriptor = .{ .size = @sizeOf(Block) };

/// Makes `block` a global block (one that is never copied or freed, so it
/// must live as long as it is used) that calls `invoke`, whose first
/// argument is the block. Null without the blocks runtime.
pub fn globalBlock(block: *Block, invoke: *const anyopaque) ?*Block {
    const isa = symbol(*const anyopaque, "_NSConcreteGlobalBlock") orelse return null;
    const block_is_global = 1 << 28;
    block.* = .{ .isa = isa, .flags = block_is_global, .invoke = invoke, .descriptor = &block_descriptor };
    return block;
}

/// The value of a framework's constant object (`NSDefaultRunLoopMode`).
pub fn constant(name: [*:0]const u8) Id {
    const p = symbol(*const Id, name) orelse return null;
    return p.*;
}

/// Makes a class of our own, `name`, a subclass of `super`, with the
/// methods `methods` (selector, implementation, type encoding) and a
/// pointer-sized ivar `kete` (for the Zig object it belongs to).
pub fn makeClass(name: [*:0]const u8, super: [*:0]const u8, methods: []const Method) Class {
    if (class(name)) |existing| return existing;
    const cls = rt().allocateClassPair(class(super), name, 0);
    _ = rt().addIvar(cls, "kete", @sizeOf(usize), std.math.log2_int(usize, @sizeOf(usize)), "^v");
    for (methods) |m| _ = rt().addMethod(cls, sel(m.sel), m.imp, m.types);
    rt().registerClassPair(cls);
    return cls;
}

pub const Method = struct { sel: [*:0]const u8, imp: *const anyopaque, types: [*:0]const u8 };

/// The Zig object an object of one of our classes belongs to.
pub fn owner(comptime T: type, obj: Id) ?*T {
    const cls = msg(Class, obj, "class", .{});
    const ivar = rt().getInstanceVariable(cls, "kete");
    return @ptrCast(@alignCast(rt().getIvar(obj, ivar)));
}

pub fn setOwner(obj: Id, ptr: ?*anyopaque) void {
    const cls = msg(Class, obj, "class", .{});
    const ivar = rt().getInstanceVariable(cls, "kete");
    rt().setIvar(obj, ivar, ptr);
}
