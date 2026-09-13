const std = @import("std");
const types = @import("types.zig");
const http_client = @import("http_client.zig");
const auth = @import("auth.zig");
const models = @import("models.zig");
const executor = @import("executor.zig");
const cli = @import("cli.zig");
const management = @import("management.zig");

const allocator = std.heap.page_allocator;

const REGISTRATION_RESPONSE =
    \\{
    \\  "ok": true,
    \\  "result": {
    \\    "schema_version": 1,
    \\    "metadata": {
    \\      "Name": "gemini-web",
    \\      "Version": "1.0.0",
    \\      "Author": "flow2cpa",
    \\      "Description": "Gemini Web & VideoFX Image/Video Generation Plugin for CLIProxyAPI",
    \\      "GitHubRepository": "https://github.com/flow2cpa/flow2cpa",
    \\      "Logo": "https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/main/docs/logo.png",
    \\      "ConfigFields": [
    \\        {
    \\          "Name": "proxy_url",
    \\          "Type": "string",
    \\          "Description": "Optional HTTP/SOCKS5 proxy URL for upstream calls (e.g. http://127.0.0.1:7890)"
    \\        }
    \\      ]
    \\    },
    \\    "capabilities": {
    \\      "model_registrar": true,
    \\      "model_provider": true,
    \\      "auth_provider": true,
    \\      "executor": true,
    \\      "executor_model_scope": "both",
    \\      "executor_input_formats": ["chat-completions", "images", "responses"],
    \\      "executor_output_formats": ["chat-completions", "images", "responses"],
    \\      "command_line_plugin": true,
    \\      "management_api": true
    \\    }
    \\  }
    \\}
;

const IDENTIFIER_RESPONSE = "{\"ok\":true,\"result\":{\"identifier\":\"gemini-web\"}}";

const LOGIN_START_RESPONSE =
    \\{
    \\  "ok": true,
    \\  "result": {
    \\    "Provider": "gemini-web",
    \\    "URL": "https://labs.google/fx",
    \\    "State": "gemini-web-state",
    \\    "ExpiresAt": "2030-01-01T00:00:00Z",
    \\    "Metadata": {
    \\      "instructions": "Copy Cookie header or session-token from labs.google/fx and import using --gemini-web-auth in CLI or via Management Web UI."
    \\    }
    \\  }
    \\}
;

const LOGIN_POLL_RESPONSE =
    \\{
    \\  "ok": true,
    \\  "result": {
    \\    "Status": "pending",
    \\    "Message": "Waiting for cookie import via --gemini-web-auth or Management UI"
    \\  }
    \\}
;

fn writeResponse(response: [*c]types.cliproxy_buffer, raw_text: []const u8) void {
    if (response == null) return;

    if (raw_text.len == 0) {
        response.*.ptr = null;
        response.*.len = 0;
        return;
    }

    const mem = allocator.alloc(u8, raw_text.len) catch {
        response.*.ptr = null;
        response.*.len = 0;
        return;
    };
    @memcpy(mem, raw_text);

    response.*.ptr = mem.ptr;
    response.*.len = mem.len;
}

fn handleMethod(method: []const u8, request: []const u8) ![]u8 {
    if (std.mem.eql(u8, method, "plugin.register") or std.mem.eql(u8, method, "plugin.reconfigure")) {
        return try allocator.dupe(u8, REGISTRATION_RESPONSE);
    } else if (std.mem.eql(u8, method, "model.register") or std.mem.eql(u8, method, "model.static") or std.mem.eql(u8, method, "model.for_auth")) {
        return try models.generateModelResponse(allocator);
    } else if (std.mem.eql(u8, method, "auth.identifier") or std.mem.eql(u8, method, "executor.identifier")) {
        return try allocator.dupe(u8, IDENTIFIER_RESPONSE);
    } else if (std.mem.eql(u8, method, "auth.parse")) {
        return try auth.handleAuthParse(allocator, request);
    } else if (std.mem.eql(u8, method, "auth.login.start")) {
        return try allocator.dupe(u8, LOGIN_START_RESPONSE);
    } else if (std.mem.eql(u8, method, "auth.login.poll")) {
        return try allocator.dupe(u8, LOGIN_POLL_RESPONSE);
    } else if (std.mem.eql(u8, method, "auth.refresh")) {
        return try auth.handleAuthRefresh(allocator, request);
    } else if (std.mem.eql(u8, method, "executor.execute")) {
        return try executor.handleExecute(allocator, request);
    } else if (std.mem.eql(u8, method, "executor.execute_stream")) {
        return try executor.handleExecuteStream(allocator, request);
    } else if (std.mem.eql(u8, method, "executor.count_tokens")) {
        return try executor.handleCountTokens(allocator, request);
    } else if (std.mem.eql(u8, method, "command_line.register")) {
        return try cli.handleCommandLineRegister(allocator);
    } else if (std.mem.eql(u8, method, "command_line.execute")) {
        return try cli.handleCommandLineExecute(allocator, request);
    } else if (std.mem.eql(u8, method, "management.register")) {
        return try management.handleManagementRegister(allocator);
    } else if (std.mem.eql(u8, method, "management.handle")) {
        return try management.handleManagementHandle(allocator, request);
    } else {
        return try types.wrapError(allocator, "unknown_method", "unknown method");
    }
}

fn pluginCall(
    method_ptr: [*c]const u8,
    request_ptr: [*c]const u8,
    request_len: usize,
    response_ptr: [*c]types.cliproxy_buffer,
) callconv(.c) c_int {
    if (response_ptr != null) {
        response_ptr.*.ptr = null;
        response_ptr.*.len = 0;
    }

    if (method_ptr == null) {
        const err_env = types.wrapError(allocator, "invalid_method", "method is required") catch return 1;
        defer allocator.free(err_env);
        writeResponse(response_ptr, err_env);
        return 1;
    }

    const method = std.mem.span(method_ptr);
    const request = if (request_ptr != null and request_len > 0)
        request_ptr[0..request_len]
    else
        "";

    const out = handleMethod(method, request) catch |err| {
        const err_name = @errorName(err);
        const err_env = types.wrapError(allocator, "plugin_error", err_name) catch return 1;
        defer allocator.free(err_env);
        writeResponse(response_ptr, err_env);
        return 1;
    };
    defer allocator.free(out);

    writeResponse(response_ptr, out);
    return 0;
}

fn pluginFree(ptr: ?*anyopaque, len: usize) callconv(.c) void {
    if (ptr) |p| {
        const byte_slice: []u8 = @as([*]u8, @ptrCast(p))[0..len];
        allocator.free(byte_slice);
    }
}

fn pluginShutdown() callconv(.c) void {}

pub export fn cliproxy_plugin_init(
    host: ?*const types.cliproxy_host_api,
    plugin: ?*types.cliproxy_plugin_api,
) callconv(.c) c_int {
    if (plugin == null) return 1;

    http_client.setHost(host);

    plugin.?.*.abi_version = types.ABI_VERSION;
    plugin.?.*.call = pluginCall;
    plugin.?.*.free_buffer = pluginFree;
    plugin.?.*.shutdown = pluginShutdown;

    return 0;
}

test "main register call" {
    var resp: types.cliproxy_buffer = .{ .ptr = null, .len = 0 };
    const ret = pluginCall("plugin.register", null, 0, &resp);
    try std.testing.expectEqual(@as(c_int, 0), ret);
    try std.testing.expect(resp.ptr != null);
    defer pluginFree(resp.ptr, resp.len);

    const slice = @as([*]const u8, @ptrCast(resp.ptr.?))[0..resp.len];
    try std.testing.expect(std.mem.indexOf(u8, slice, "gemini-web") != null);
}

test "main identifier call" {
    var resp: types.cliproxy_buffer = .{ .ptr = null, .len = 0 };
    const ret = pluginCall("auth.identifier", null, 0, &resp);
    try std.testing.expectEqual(@as(c_int, 0), ret);
    try std.testing.expect(resp.ptr != null);
    defer pluginFree(resp.ptr, resp.len);

    const slice = @as([*]const u8, @ptrCast(resp.ptr.?))[0..resp.len];
    try std.testing.expect(std.mem.indexOf(u8, slice, "gemini-web") != null);
}
