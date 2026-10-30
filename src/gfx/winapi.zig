//! The Windows API: kernel32's functions (linked, as every program has
//! them), and the other system DLLs' (user32, gdi32, dwmapi, d3d11, dxgi,
//! ...) loaded when first used (as kete loads Vulkan, EGL and AppKit), so
//! nothing else is linked. COM objects (Direct3D's, DXGI's) are called
//! through their vtables (`Com`).

const std = @import("std");

/// The calling convention of the Windows API (and COM), on Windows (the C
/// one elsewhere, where none of it is called, so that it still compiles).
pub const cc: std.builtin.CallingConvention = if (@import("builtin").os.tag == .windows) .winapi else .c;

pub const BOOL = c_int;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WORD = u16;
pub const LONG = c_long;
pub const HRESULT = c_long;
pub const WCHAR = u16;
pub const HANDLE = *anyopaque;
pub const HMODULE = *opaque {};
pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HDC = *opaque {};
pub const HCURSOR = *opaque {};
pub const HMONITOR = *opaque {};
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const FARPROC = *const anyopaque;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const INFINITE: DWORD = 0xffffffff;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 0x102;
pub const WAIT_FAILED: DWORD = 0xffffffff;

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    /// From its usual text: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
    pub fn parse(comptime s: []const u8) GUID {
        return comptime blk: {
            std.debug.assert(s.len == 36);
            const hex = struct {
                fn f(t: []const u8) u64 {
                    return std.fmt.parseInt(u64, t, 16) catch unreachable;
                }
            }.f;
            var g: GUID = .{
                .data1 = @intCast(hex(s[0..8])),
                .data2 = @intCast(hex(s[9..13])),
                .data3 = @intCast(hex(s[14..18])),
                .data4 = undefined,
            };
            g.data4[0] = @intCast(hex(s[19..21]));
            g.data4[1] = @intCast(hex(s[21..23]));
            for (0..6) |i| g.data4[2 + i] = @intCast(hex(s[24 + i * 2 ..][0..2]));
            break :blk g;
        };
    }
};

pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

// --- kernel32 ---------------------------------------------------------------------

pub extern "kernel32" fn LoadLibraryW(name: [*:0]const WCHAR) callconv(cc) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(cc) ?FARPROC;
pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const WCHAR) callconv(cc) ?HMODULE;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(cc) BOOL;
pub extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const WCHAR) callconv(cc) ?HANDLE;
pub extern "kernel32" fn SetEvent(h: HANDLE) callconv(cc) BOOL;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(cc) DWORD;
pub extern "kernel32" fn CreateWaitableTimerExW(attrs: ?*anyopaque, name: ?[*:0]const WCHAR, flags: DWORD, access: DWORD) callconv(cc) ?HANDLE;
pub extern "kernel32" fn SetWaitableTimer(h: HANDLE, due: *const i64, period: LONG, routine: ?*const anyopaque, arg: ?*anyopaque, resume_: BOOL) callconv(cc) BOOL;
pub extern "kernel32" fn CancelWaitableTimer(h: HANDLE) callconv(cc) BOOL;
pub extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(cc) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(cc) BOOL;
pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(cc) ?HANDLE;
pub extern "kernel32" fn GlobalFree(h: HANDLE) callconv(cc) ?HANDLE;
pub extern "kernel32" fn GlobalLock(h: HANDLE) callconv(cc) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(h: HANDLE) callconv(cc) BOOL;
pub extern "kernel32" fn GlobalSize(h: HANDLE) callconv(cc) usize;

pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: DWORD = 0x2;
pub const TIMER_ALL_ACCESS: DWORD = 0x1f0003;
pub const GMEM_MOVEABLE: UINT = 0x2;

/// The performance counter in nanoseconds (the clock DXGI's and DWM's
/// timings are on, as `QueryPerformanceCounter` gives them).
pub fn qpcToNs(qpc: i64) u64 {
    const S = struct {
        var freq: i64 = 0;
    };
    if (S.freq == 0) _ = QueryPerformanceFrequency(&S.freq);
    const f: u128 = @intCast(@max(S.freq, 1));
    const q: u128 = @intCast(@max(qpc, 0));
    return @intCast(q * std.time.ns_per_s / f);
}

pub fn nowQpc() i64 {
    var q: i64 = 0;
    _ = QueryPerformanceCounter(&q);
    return q;
}

// --- Loading DLLs -------------------------------------------------------------------

/// A system DLL, loaded once (null if it is not there).
pub fn dll(comptime name: []const u8) ?HMODULE {
    const s = dllSlot(name);
    if (!s.loaded) {
        s.loaded = true;
        s.module = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral(name));
    }
    return s.module;
}

const DllSlot = struct {
    loaded: bool = false,
    module: ?HMODULE = null,
};

fn dllSlot(comptime name: []const u8) *DllSlot {
    const S = struct {
        const key = name;
        var slot: DllSlot = .{};
    };
    _ = S.key;
    return &S.slot;
}

test "each DLL name has its own loaded module slot" {
    try std.testing.expect(dllSlot("d3d11.dll") != dllSlot("user32.dll"));
    try std.testing.expect(dllSlot("d3d11.dll") != dllSlot("gdi32.dll"));
}

/// Function `name` of DLL `lib` (null if either is not there).
pub fn proc(comptime T: type, comptime lib: []const u8, name: [*:0]const u8) ?T {
    const m = dll(lib) orelse return null;
    const p = GetProcAddress(m, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Functions of DLL `lib`, as the fields of `T` (function pointers named
/// as the DLL's functions), looked up once: null if any is missing.
pub fn procs(comptime T: type, comptime lib: []const u8) ?*const T {
    const S = struct {
        var looked = false;
        var table: ?T = null;
    };
    if (!S.looked) {
        S.looked = true;
        var t: T = undefined;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |name, F| {
            @field(t, name) = proc(F, lib, name) orelse return null;
        }
        S.table = t;
    }
    return if (S.table) |*t| t else null;
}

// --- COM ------------------------------------------------------------------------

/// A COM object's method in slot `slot` of its vtable (counting
/// IUnknown's three), of type `F` (`fn (*anyopaque, ...) callconv(cc) R`),
/// called on it with `args`.
pub fn call(obj: anytype, comptime slot: usize, comptime F: type, args: anytype) @typeInfo(F).@"fn".return_type.? {
    const self: *anyopaque = @ptrCast(obj);
    const vtable: [*]const *const anyopaque = @as(*const [*]const *const anyopaque, @ptrCast(@alignCast(self))).*;
    const f: *const F = @ptrCast(@alignCast(vtable[slot]));
    return @call(.auto, f, .{self} ++ args);
}

const QueryInterface = fn (*anyopaque, *const GUID, *?*anyopaque) callconv(cc) HRESULT;
const AddRefRelease = fn (*anyopaque) callconv(cc) u32;

/// IUnknown's `QueryInterface` (slot 0): the object as interface `iid`.
pub fn query(obj: anytype, iid: *const GUID) ?*anyopaque {
    var out: ?*anyopaque = null;
    if (!succeeded(call(obj, 0, QueryInterface, .{ iid, &out }))) return null;
    return out;
}

/// IUnknown's `AddRef` (slot 1).
pub fn addRef(obj: anytype) void {
    _ = call(obj, 1, AddRefRelease, .{});
}

/// IUnknown's `Release` (slot 2), if there is an object.
pub fn release(obj: anytype) void {
    const o: ?*anyopaque = @ptrCast(obj);
    if (o) |p| _ = call(p, 2, AddRefRelease, .{});
}

// --- UTF-16 ------------------------------------------------------------------------

/// `text` (UTF-8) as UTF-16 with a 0 at its end, in `buf` (cut short if it
/// does not fit).
pub fn wide(buf: []u16, text: []const u8) [:0]const u16 {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        var units: [2]u16 = undefined;
        const len: usize = if (cp >= 0x10000) blk: {
            const v = cp - 0x10000;
            units = .{ @intCast(0xd800 + (v >> 10)), @intCast(0xdc00 + (v & 0x3ff)) };
            break :blk 2;
        } else blk: {
            units[0] = @intCast(cp);
            break :blk 1;
        };
        if (n + len + 1 > buf.len) break;
        @memcpy(buf[n..][0..len], units[0..len]);
        n += len;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

test "UTF-8 becomes UTF-16, with a 0 at its end, cut short to fit" {
    var buf: [8]u16 = undefined;
    const w = wide(&buf, "a\u{e9}\u{1f600}");
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xe9, 0xd83d, 0xde00 }, w);
    try std.testing.expectEqual(@as(u16, 0), w.ptr[w.len]);
    var small: [3]u16 = undefined;
    // The emoji's two units do not fit after "a\u{e9}" and the 0.
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xe9 }, wide(&small, "a\u{e9}\u{1f600}"));
}

test "a COM method is called through its object's vtable" {
    const Impl = struct {
        var released: u32 = 0;
        fn qi(_: *anyopaque, _: *const GUID, out: *?*anyopaque) callconv(cc) HRESULT {
            out.* = null;
            return -1;
        }
        fn addRef(_: *anyopaque) callconv(cc) u32 {
            return 1;
        }
        fn rel(_: *anyopaque) callconv(cc) u32 {
            released += 1;
            return 0;
        }
    };
    const vt = [3]*const anyopaque{ @ptrCast(&Impl.qi), @ptrCast(&Impl.addRef), @ptrCast(&Impl.rel) };
    var obj: extern struct { vt: *const [3]*const anyopaque } = .{ .vt = &vt };
    release(&obj);
    try std.testing.expectEqual(@as(u32, 1), Impl.released);
    try std.testing.expect(query(&obj, &comptime GUID.parse("00000000-0000-0000-c000-000000000046")) == null);
}

test "GUIDs are read from their text" {
    const g = GUID.parse("db6f6ddb-ac77-4e88-8253-819df9bbf140");
    try std.testing.expectEqual(@as(u32, 0xdb6f6ddb), g.data1);
    try std.testing.expectEqual(@as(u16, 0xac77), g.data2);
    try std.testing.expectEqual(@as(u16, 0x4e88), g.data3);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40 }, &g.data4);
}

// --- user32, gdi32, dwmapi, advapi32 (loaded when first used) ---------------------

pub const POINT = extern struct { x: LONG, y: LONG };
pub const RECT = extern struct { left: LONG = 0, top: LONG = 0, right: LONG = 0, bottom: LONG = 0 };

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD = 0,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(cc) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const WCHAR = null,
    lpszClassName: [*:0]const WCHAR,
    hIconSm: ?*anyopaque = null,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD = 0,
};

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
};

pub const WINDOWPLACEMENT = extern struct {
    length: UINT = @sizeOf(WINDOWPLACEMENT),
    flags: UINT = 0,
    showCmd: UINT = 0,
    ptMinPosition: POINT = .{ .x = 0, .y = 0 },
    ptMaxPosition: POINT = .{ .x = 0, .y = 0 },
    rcNormalPosition: RECT = .{},
};

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: WORD = 1,
    biBitCount: WORD = 32,
    biCompression: DWORD = 0, // BI_RGB
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: LONG = 0,
    biYPelsPerMeter: LONG = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

pub const User32 = struct {
    RegisterClassExW: *const fn (*const WNDCLASSEXW) callconv(cc) WORD,
    CreateWindowExW: *const fn (DWORD, [*:0]const WCHAR, [*:0]const WCHAR, DWORD, c_int, c_int, c_int, c_int, ?HWND, ?*anyopaque, ?HINSTANCE, ?*anyopaque) callconv(cc) ?HWND,
    DestroyWindow: *const fn (HWND) callconv(cc) BOOL,
    DefWindowProcW: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(cc) LRESULT,
    ShowWindow: *const fn (HWND, c_int) callconv(cc) BOOL,
    SetWindowTextW: *const fn (HWND, [*:0]const WCHAR) callconv(cc) BOOL,
    GetClientRect: *const fn (HWND, *RECT) callconv(cc) BOOL,
    GetWindowRect: *const fn (HWND, *RECT) callconv(cc) BOOL,
    SetWindowPos: *const fn (HWND, ?HWND, c_int, c_int, c_int, c_int, UINT) callconv(cc) BOOL,
    GetWindowLongPtrW: *const fn (HWND, c_int) callconv(cc) isize,
    SetWindowLongPtrW: *const fn (HWND, c_int, isize) callconv(cc) isize,
    PeekMessageW: *const fn (*MSG, ?HWND, UINT, UINT, UINT) callconv(cc) BOOL,
    TranslateMessage: *const fn (*const MSG) callconv(cc) BOOL,
    DispatchMessageW: *const fn (*const MSG) callconv(cc) LRESULT,
    PostMessageW: *const fn (?HWND, UINT, WPARAM, LPARAM) callconv(cc) BOOL,
    MsgWaitForMultipleObjectsEx: *const fn (DWORD, ?[*]const HANDLE, DWORD, DWORD, DWORD) callconv(cc) DWORD,
    SetTimer: *const fn (?HWND, usize, UINT, ?*const anyopaque) callconv(cc) usize,
    KillTimer: *const fn (?HWND, usize) callconv(cc) BOOL,
    LoadCursorW: *const fn (?HINSTANCE, usize) callconv(cc) ?HCURSOR,
    SetCursor: *const fn (?HCURSOR) callconv(cc) ?HCURSOR,
    SetCapture: *const fn (HWND) callconv(cc) ?HWND,
    ReleaseCapture: *const fn () callconv(cc) BOOL,
    SendMessageW: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(cc) LRESULT,
    GetSystemMetricsForDpi: *const fn (c_int, UINT) callconv(cc) c_int,
    TrackMouseEvent: *const fn (*TRACKMOUSEEVENT) callconv(cc) BOOL,
    GetDC: *const fn (?HWND) callconv(cc) ?HDC,
    ReleaseDC: *const fn (?HWND, HDC) callconv(cc) c_int,
    BeginPaint: *const fn (HWND, *PAINTSTRUCT) callconv(cc) ?HDC,
    EndPaint: *const fn (HWND, *const PAINTSTRUCT) callconv(cc) BOOL,
    IsZoomed: *const fn (HWND) callconv(cc) BOOL,
    IsIconic: *const fn (HWND) callconv(cc) BOOL,
    GetDpiForWindow: *const fn (HWND) callconv(cc) UINT,
    SetProcessDpiAwarenessContext: *const fn (isize) callconv(cc) BOOL,
    AdjustWindowRectExForDpi: *const fn (*RECT, DWORD, BOOL, DWORD, UINT) callconv(cc) BOOL,
    MonitorFromWindow: *const fn (HWND, DWORD) callconv(cc) ?HMONITOR,
    GetMonitorInfoW: *const fn (HMONITOR, *MONITORINFO) callconv(cc) BOOL,
    GetWindowPlacement: *const fn (HWND, *WINDOWPLACEMENT) callconv(cc) BOOL,
    SetWindowPlacement: *const fn (HWND, *const WINDOWPLACEMENT) callconv(cc) BOOL,
    MapVirtualKeyW: *const fn (UINT, UINT) callconv(cc) UINT,
    GetKeyState: *const fn (c_int) callconv(cc) i16,
    SystemParametersInfoW: *const fn (UINT, UINT, ?*anyopaque, UINT) callconv(cc) BOOL,
    OpenClipboard: *const fn (?HWND) callconv(cc) BOOL,
    CloseClipboard: *const fn () callconv(cc) BOOL,
    EmptyClipboard: *const fn () callconv(cc) BOOL,
    SetClipboardData: *const fn (UINT, ?HANDLE) callconv(cc) ?HANDLE,
    GetClipboardData: *const fn (UINT) callconv(cc) ?HANDLE,
    ValidateRect: *const fn (HWND, ?*const RECT) callconv(cc) BOOL,
    GetQueueStatus: *const fn (UINT) callconv(cc) DWORD,
    ClientToScreen: *const fn (HWND, *POINT) callconv(cc) BOOL,
    MonitorFromPoint: *const fn (POINT, DWORD) callconv(cc) ?HMONITOR,
    GetCursorPos: *const fn (*POINT) callconv(cc) BOOL,
    WindowFromPoint: *const fn (POINT) callconv(cc) ?HWND,
    UpdateLayeredWindow: *const fn (HWND, ?HDC, ?*const POINT, ?*const SIZE, ?HDC, ?*const POINT, DWORD, ?*const BLENDFUNCTION, DWORD) callconv(cc) BOOL,
    IsWindowVisible: *const fn (HWND) callconv(cc) BOOL,
};

pub const SIZE = extern struct { cx: LONG, cy: LONG };

pub const BLENDFUNCTION = extern struct {
    BlendOp: u8 = 0, // AC_SRC_OVER
    BlendFlags: u8 = 0,
    SourceConstantAlpha: u8 = 255,
    AlphaFormat: u8 = 1, // AC_SRC_ALPHA: premultiplied per pixel
};

pub const ULW_ALPHA: DWORD = 2;

pub fn user32() ?*const User32 {
    return procs(User32, "user32.dll");
}

pub const Gdi32 = struct {
    SetDIBitsToDevice: *const fn (HDC, c_int, c_int, DWORD, DWORD, c_int, c_int, UINT, UINT, *const anyopaque, *const BITMAPINFOHEADER, UINT) callconv(cc) c_int,
    CreateCompatibleDC: *const fn (?HDC) callconv(cc) ?HDC,
    DeleteDC: *const fn (HDC) callconv(cc) BOOL,
    CreateDIBSection: *const fn (?HDC, *const BITMAPINFOHEADER, UINT, *?*anyopaque, ?HANDLE, DWORD) callconv(cc) ?HANDLE,
    SelectObject: *const fn (HDC, HANDLE) callconv(cc) ?HANDLE,
    DeleteObject: *const fn (HANDLE) callconv(cc) BOOL,
};

pub fn gdi32() ?*const Gdi32 {
    return procs(Gdi32, "gdi32.dll");
}

/// How far the window's frame is extended into its client area.
pub const MARGINS = extern struct { cxLeftWidth: c_int = 0, cxRightWidth: c_int = 0, cyTopHeight: c_int = 0, cyBottomHeight: c_int = 0 };

/// What `WM_NCCALCSIZE` says about the window's size (`lParam`, when
/// `wParam` is true).
pub const NCCALCSIZE_PARAMS = extern struct { rgrc: [3]RECT, lppos: ?*anyopaque };

pub const Dwmapi = struct {
    DwmGetCompositionTimingInfo: *const fn (?HWND, *anyopaque) callconv(cc) HRESULT,
    DwmSetWindowAttribute: *const fn (HWND, DWORD, *const anyopaque, DWORD) callconv(cc) HRESULT,
    DwmGetWindowAttribute: *const fn (HWND, DWORD, *anyopaque, DWORD) callconv(cc) HRESULT,
    DwmExtendFrameIntoClientArea: *const fn (HWND, *const MARGINS) callconv(cc) HRESULT,
    DwmDefWindowProc: *const fn (HWND, UINT, WPARAM, LPARAM, *LRESULT) callconv(cc) BOOL,
};

pub fn dwmapi() ?*const Dwmapi {
    return procs(Dwmapi, "dwmapi.dll");
}

pub const Advapi32 = struct {
    RegGetValueW: *const fn (usize, [*:0]const WCHAR, [*:0]const WCHAR, DWORD, ?*DWORD, ?*anyopaque, ?*DWORD) callconv(cc) LONG,
};

pub fn advapi32() ?*const Advapi32 {
    return procs(Advapi32, "advapi32.dll");
}

/// DWM's timing of the display's refreshes (`DWM_TIMING_INFO`, packed: only
/// what kete reads of it is named), when the next is and how long each is,
/// on the performance counter.
pub const CompositionTiming = struct {
    refresh_qpc: u64,
    vblank_qpc: u64,

    /// The size of `DWM_TIMING_INFO` (packed to 1 byte), and where its
    /// `qpcRefreshPeriod` and `qpcVBlank` are.
    const size = 292;
    const refresh_at = 12;
    const vblank_at = 28;

    pub fn get() ?CompositionTiming {
        const d = dwmapi() orelse return null;
        var info: [size]u8 align(8) = @splat(0);
        std.mem.writeInt(u32, info[0..4], size, .little);
        if (!succeeded(d.DwmGetCompositionTimingInfo(null, &info))) return null;
        const refresh = std.mem.readInt(u64, info[refresh_at..][0..8], .little);
        if (refresh == 0) return null;
        return .{ .refresh_qpc = refresh, .vblank_qpc = std.mem.readInt(u64, info[vblank_at..][0..8], .little) };
    }
};

pub const HKEY_CURRENT_USER: usize = 0x80000001;
pub const RRF_RT_REG_DWORD: DWORD = 0x10;

/// Whether apps are to be dark, by the user's choice in Settings (null if
/// it cannot be read).
pub fn appsUseDark() ?bool {
    const a = advapi32() orelse return null;
    var value: DWORD = 1;
    var len: DWORD = @sizeOf(DWORD);
    const key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    const name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    if (a.RegGetValueW(HKEY_CURRENT_USER, key, name, RRF_RT_REG_DWORD, null, &value, &len) != 0) return null;
    return value == 0;
}
