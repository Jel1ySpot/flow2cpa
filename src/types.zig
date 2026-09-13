const std = @import("std");

pub const ABI_VERSION: u32 = 1;

pub const cliproxy_buffer = extern struct {
    ptr: ?*anyopaque,
    len: usize,
};

pub const cliproxy_host_call_fn = ?*const fn (
    host_ctx: ?*anyopaque,
    method: [*c]const u8,
    request: [*c]const u8,
    request_len: usize,
    response: [*c]cliproxy_buffer,
) callconv(.c) c_int;

pub const cliproxy_host_free_fn = ?*const fn (
    ptr: ?*anyopaque,
    len: usize,
) callconv(.c) void;

pub const cliproxy_host_api = extern struct {
    abi_version: u32,
    host_ctx: ?*anyopaque,
    call: cliproxy_host_call_fn,
    free_buffer: cliproxy_host_free_fn,
};

pub const cliproxy_plugin_call_fn = ?*const fn (
    method: [*c]const u8,
    request: [*c]const u8,
    request_len: usize,
    response: [*c]cliproxy_buffer,
) callconv(.c) c_int;

pub const cliproxy_plugin_free_fn = ?*const fn (
    ptr: ?*anyopaque,
    len: usize,
) callconv(.c) void;

pub const cliproxy_plugin_shutdown_fn = ?*const fn () callconv(.c) void;

pub const cliproxy_plugin_api = extern struct {
    abi_version: u32,
    call: cliproxy_plugin_call_fn,
    free_buffer: cliproxy_plugin_free_fn,
    shutdown: cliproxy_plugin_shutdown_fn,
};

/// Helper to wrap a result in {"ok":true,"result":...}
pub fn wrapOk(allocator: std.mem.Allocator, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"ok\":true,\"result\":{s}}}", .{result_json});
}

/// Helper to wrap an error in {"ok":false,"error":{"code":...,"message":...}}
pub fn wrapError(allocator: std.mem.Allocator, code: []const u8, message: []const u8) ![]u8 {
    var escaped_code: std.ArrayList(u8) = .empty;
    defer escaped_code.deinit(allocator);
    try jsonEscape(&escaped_code, allocator, code);

    var escaped_msg: std.ArrayList(u8) = .empty;
    defer escaped_msg.deinit(allocator);
    try jsonEscape(&escaped_msg, allocator, message);

    return std.fmt.allocPrint(allocator, "{{\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{
        escaped_code.items,
        escaped_msg.items,
    });
}

/// Escapes a string for JSON output
pub fn jsonEscape(list: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var hex_buf: [6]u8 = undefined;
                const hex_str = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch "\\u0000";
                try list.appendSlice(allocator, hex_str);
            },
            else => try list.append(allocator, c),
        }
    }
}

/// Base64 encode helper using standard alphabet
pub fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const size = std.base64.standard.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(buf, data);
    return buf;
}

/// Base64 decode helper
pub fn base64Decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, encoded, " \t\r\n\"");
    const exact_size = try std.base64.standard.Decoder.calcSizeForSlice(trimmed);
    const buf = try allocator.alloc(u8, exact_size);
    try std.base64.standard.Decoder.decode(buf, trimmed);
    return buf;
}

/// Persistent storage data stored in AuthData.StorageJSON
pub const StorageData = struct {
    st: []const u8,
    at: []const u8 = "",
    at_expires: []const u8 = "",
    email: []const u8 = "",
    name: []const u8 = "",
    project_id: []const u8 = "",
    credits: i64 = 0,
    tier: []const u8 = "PAYGATE_TIER_ONE",
    proxy_url: []const u8 = "",

    pub fn toJSON(self: StorageData, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);

        try list.appendSlice(allocator, "{\"st\":\"");
        try jsonEscape(&list, allocator, self.st);
        try list.appendSlice(allocator, "\",\"at\":\"");
        try jsonEscape(&list, allocator, self.at);
        try list.appendSlice(allocator, "\",\"at_expires\":\"");
        try jsonEscape(&list, allocator, self.at_expires);
        try list.appendSlice(allocator, "\",\"email\":\"");
        try jsonEscape(&list, allocator, self.email);
        try list.appendSlice(allocator, "\",\"name\":\"");
        try jsonEscape(&list, allocator, self.name);
        try list.appendSlice(allocator, "\",\"project_id\":\"");
        try jsonEscape(&list, allocator, self.project_id);
        try list.appendSlice(allocator, "\",\"tier\":\"");
        try jsonEscape(&list, allocator, self.tier);
        try list.appendSlice(allocator, "\",\"proxy_url\":\"");
        try jsonEscape(&list, allocator, self.proxy_url);

        var num_buf: [32]u8 = undefined;
        const num_str = try std.fmt.bufPrint(&num_buf, "\",\"credits\":{d}}}", .{self.credits});
        try list.appendSlice(allocator, num_str);

        return list.toOwnedSlice(allocator);
    }
};

test "types and json helpers" {
    const allocator = std.testing.allocator;
    const ok_res = try wrapOk(allocator, "{\"key\":\"value\"}");
    defer allocator.free(ok_res);
    try std.testing.expectEqualStrings("{\"ok\":true,\"result\":{\"key\":\"value\"}}", ok_res);

    const err_res = try wrapError(allocator, "invalid_request", "test \"error\"");
    defer allocator.free(err_res);
    try std.testing.expect(std.mem.indexOf(u8, err_res, "test \\\"error\\\"") != null);

    const encoded = try base64Encode(allocator, "hello world");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("aGVsbG8gd29ybGQ=", encoded);

    const decoded = try base64Decode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world", decoded);

    const s = StorageData{
        .st = "session_token_123",
        .email = "test@example.com",
        .project_id = "proj-123",
    };
    const s_json = try s.toJSON(allocator);
    defer allocator.free(s_json);
    try std.testing.expect(std.mem.indexOf(u8, s_json, "\"email\":\"test@example.com\"") != null);
}
