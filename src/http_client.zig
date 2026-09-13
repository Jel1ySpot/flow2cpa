const std = @import("std");
const types = @import("types.zig");

pub var stored_host: ?*const types.cliproxy_host_api = null;

pub fn setHost(host: ?*const types.cliproxy_host_api) void {
    stored_host = host;
}

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpRequest = struct {
    method: []const u8,
    url: []const u8,
    headers: []const HeaderEntry = &.{},
    body: ?[]const u8 = null,
};

pub const HttpResponse = struct {
    status_code: i64,
    body: []u8,
    raw_response: []u8,
    headers_json: ?std.json.Value = null,

    pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.raw_response);
    }

    /// Helper to find a header value (case-insensitive)
    pub fn getHeader(self: HttpResponse, name: []const u8) ?[]const u8 {
        if (self.headers_json == null or self.headers_json.? != .object) return null;
        var it = self.headers_json.?.object.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
                if (entry.value_ptr.* == .string) return entry.value_ptr.*.string;
                if (entry.value_ptr.* == .array and entry.value_ptr.*.array.items.len > 0) {
                    const first = entry.value_ptr.*.array.items[0];
                    if (first == .string) return first.string;
                }
            }
        }
        return null;
    }

    /// Helper to extract all Set-Cookie values
    pub fn getSetCookies(self: HttpResponse, allocator: std.mem.Allocator) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(allocator);

        if (self.headers_json == null or self.headers_json.? != .object) return list.toOwnedSlice(allocator);

        var it = self.headers_json.?.object.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "set-cookie")) {
                if (entry.value_ptr.* == .string) {
                    try list.append(allocator, entry.value_ptr.*.string);
                } else if (entry.value_ptr.* == .array) {
                    for (entry.value_ptr.*.array.items) |item| {
                        if (item == .string) {
                            try list.append(allocator, item.string);
                        }
                    }
                }
            }
        }
        return list.toOwnedSlice(allocator);
    }
};

/// Invoke a host API method
pub fn callHost(allocator: std.mem.Allocator, method: []const u8, payload: []const u8) ![]u8 {
    const host = stored_host orelse return error.HostNotAvailable;
    const call_fn = host.call orelse return error.HostCallNotAvailable;

    const method_z = try allocator.dupeZ(u8, method);
    defer allocator.free(method_z);

    var response: types.cliproxy_buffer = .{ .ptr = null, .len = 0 };

    const ret = call_fn(
        host.host_ctx,
        method_z.ptr,
        if (payload.len > 0) payload.ptr else null,
        payload.len,
        &response,
    );

    if (ret != 0) {
        if (response.ptr != null and host.free_buffer != null) {
            host.free_buffer.?(response.ptr, response.len);
        }
        return error.HostCallFailed;
    }

    if (response.ptr == null or response.len == 0) {
        return try allocator.dupe(u8, "{}");
    }

    const resp_bytes = @as([*]const u8, @ptrCast(response.ptr.?))[0..response.len];
    const out = try allocator.dupe(u8, resp_bytes);

    if (host.free_buffer) |free_fn| {
        free_fn(response.ptr, response.len);
    }

    return out;
}

/// Log to host logger
pub fn hostLog(allocator: std.mem.Allocator, level: []const u8, message: []const u8) void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    list.appendSlice(allocator, "{\"level\":\"") catch return;
    types.jsonEscape(&list, allocator, level) catch return;
    list.appendSlice(allocator, "\",\"message\":\"") catch return;
    types.jsonEscape(&list, allocator, message) catch return;
    list.appendSlice(allocator, "\",\"fields\":{\"plugin\":\"gemini-web\"}}") catch return;

    const payload = list.toOwnedSlice(allocator) catch return;
    defer allocator.free(payload);

    const res = callHost(allocator, "host.log", payload) catch return;
    allocator.free(res);
}

/// Execute HTTP request through host HTTP bridge
pub fn hostHttpDo(allocator: std.mem.Allocator, req: HttpRequest) !HttpResponse {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.appendSlice(allocator, "{\"Method\":\"");
    try types.jsonEscape(&payload, allocator, req.method);
    try payload.appendSlice(allocator, "\",\"URL\":\"");
    try types.jsonEscape(&payload, allocator, req.url);
    try payload.appendSlice(allocator, "\",\"Headers\":{");

    for (req.headers, 0..) |h, idx| {
        if (idx > 0) try payload.appendSlice(allocator, ",");
        try payload.appendSlice(allocator, "\"");
        try types.jsonEscape(&payload, allocator, h.name);
        try payload.appendSlice(allocator, "\":[\"");
        try types.jsonEscape(&payload, allocator, h.value);
        try payload.appendSlice(allocator, "\"]");
    }
    try payload.appendSlice(allocator, "}");

    if (req.body) |b| {
        const b64 = try types.base64Encode(allocator, b);
        defer allocator.free(b64);
        try payload.appendSlice(allocator, ",\"Body\":\"");
        try payload.appendSlice(allocator, b64);
        try payload.appendSlice(allocator, "\"");
    }
    try payload.appendSlice(allocator, "}");

    const raw_host_resp = try callHost(allocator, "host.http.do", payload.items);
    errdefer allocator.free(raw_host_resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_host_resp, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const ok = root.get("ok");
    if (ok == null or !ok.?.bool) {
        if (root.get("error")) |err_val| {
            if (err_val.object.get("message")) |msg| {
                std.debug.print("host.http.do error: {s}\n", .{msg.string});
            }
        }
        return error.HostHttpFailed;
    }

    const result = root.get("result") orelse return error.InvalidHostResponse;
    const res_obj = result.object;

    var status_code: i64 = 200;
    if (res_obj.get("StatusCode")) |sc| {
        status_code = sc.integer;
    } else if (res_obj.get("status_code")) |sc| {
        status_code = sc.integer;
    }

    var body_bytes: []u8 = try allocator.alloc(u8, 0);
    errdefer allocator.free(body_bytes);

    const b64_body = res_obj.get("Body") orelse res_obj.get("body");
    if (b64_body) |bb| {
        if (bb == .string and bb.string.len > 0) {
            allocator.free(body_bytes);
            body_bytes = try types.base64Decode(allocator, bb.string);
        }
    }

    var headers_val: ?std.json.Value = null;
    if (res_obj.get("Headers")) |h| {
        headers_val = h;
    } else if (res_obj.get("headers")) |h| {
        headers_val = h;
    }

    return HttpResponse{
        .status_code = status_code,
        .body = body_bytes,
        .raw_response = raw_host_resp,
        .headers_json = headers_val,
    };
}

/// Save an auth file via host.auth.save
pub fn hostAuthSave(allocator: std.mem.Allocator, filename: []const u8, json_payload: []const u8) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.appendSlice(allocator, "{\"name\":\"");
    try types.jsonEscape(&payload, allocator, filename);
    try payload.appendSlice(allocator, "\",\"json\":");
    try payload.appendSlice(allocator, json_payload);
    try payload.appendSlice(allocator, "}");

    const raw_resp = try callHost(allocator, "host.auth.save", payload.items);
    defer allocator.free(raw_resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_resp, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("ok")) |ok| {
        if (!ok.bool) {
            return error.HostAuthSaveFailed;
        }
    }
}

test "http client serialize" {
    const req = HttpRequest{
        .method = "POST",
        .url = "https://example.com/api",
        .headers = &.{
            .{ .name = "Authorization", .value = "Bearer test" },
        },
        .body = "{\"prompt\": \"test\"}",
    };
    try std.testing.expectEqualStrings("POST", req.method);
}
