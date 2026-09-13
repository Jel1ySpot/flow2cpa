//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

extern "kernel32" fn LoadLibraryA([*c]const u8) callconv(.c) ?std.os.windows.HMODULE;
extern "kernel32" fn GetProcAddress(std.os.windows.HMODULE, [*c]const u8) callconv(.c) ?*anyopaque;
extern "kernel32" fn FreeLibrary(std.os.windows.HMODULE) callconv(.c) std.os.windows.BOOL;

test "load built dll and check cliproxy_plugin_init export" {
    const handle = LoadLibraryA("zig-out\\bin\\gemini-web.dll") orelse return error.LoadFailed;
    defer _ = FreeLibrary(handle);

    const proc = GetProcAddress(handle, "cliproxy_plugin_init");
    try std.testing.expect(proc != null);
}
