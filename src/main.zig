const std = @import("std");
const types = @import("types.zig");
const http_client = @import("http_client.zig");
const auth = @import("auth.zig");
const models = @import("models.zig");
const executor = @import("executor.zig");
const cli = @import("cli.zig");
const management = @import("management.zig");
const oauth_login = @import("oauth_login.zig");

const allocator = std.heap.page_allocator;

const REGISTRATION_RESPONSE =
    \\{
    \\  "ok": true,
    \\  "result": {
    \\    "schema_version": 1,
    \\    "metadata": {
    \\      "Name": "gemini-web",
    \\      "Version": "1.0.3",
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
        return try oauth_login.handleLoginStart(allocator, request);
    } else if (std.mem.eql(u8, method, "auth.login.poll")) {
        return try oauth_login.handleLoginPoll(allocator, request);
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

test "main oauth login start and poll" {
    var start_resp: types.cliproxy_buffer = .{ .ptr = null, .len = 0 };
    const ret1 = pluginCall("auth.login.start", null, 0, &start_resp);
    try std.testing.expectEqual(@as(c_int, 0), ret1);
    try std.testing.expect(start_resp.ptr != null);
    defer pluginFree(start_resp.ptr, start_resp.len);

    const start_slice = @as([*]const u8, @ptrCast(start_resp.ptr.?))[0..start_resp.len];
    try std.testing.expect(std.mem.indexOf(u8, start_slice, "/v0/resource/plugins/gemini-web/auth") != null);

    var poll_resp: types.cliproxy_buffer = .{ .ptr = null, .len = 0 };
    const ret2 = pluginCall("auth.login.poll", null, 0, &poll_resp);
    try std.testing.expectEqual(@as(c_int, 0), ret2);
    try std.testing.expect(poll_resp.ptr != null);
    defer pluginFree(poll_resp.ptr, poll_resp.len);

    const poll_slice = @as([*]const u8, @ptrCast(poll_resp.ptr.?))[0..poll_resp.len];
    try std.testing.expect(std.mem.indexOf(u8, poll_slice, "pending") != null);
}

test "main auth parse call" {
    const parse_req =
        \\{"Provider":"gemini-web","Path":"/data/auth/gemini-web-test.json","FileName":"gemini-web-test.json","RawJSON":"eyJzdCI6InRlc3Rfc3QiLCJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20ifQ=="}
    ;
    var parse_resp: types.cliproxy_buffer = .{ .ptr = null, .len = 0 };
    const ret = pluginCall("auth.parse", parse_req.ptr, parse_req.len, &parse_resp);
    try std.testing.expectEqual(@as(c_int, 0), ret);
    try std.testing.expect(parse_resp.ptr != null);
    defer pluginFree(parse_resp.ptr, parse_resp.len);

    const slice = @as([*]const u8, @ptrCast(parse_resp.ptr.?))[0..parse_resp.len];
    try std.testing.expect(std.mem.indexOf(u8, slice, "\"Handled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, slice, "gemini-web-test@example.com") != null);
}

test "main auth parse other provider call" {
    const parse_req =
        \\{"Provider":"claude","Path":"/data/auth/claude.json","FileName":"claude.json","RawJSON":"eyJzdCI6ImFiYyJ9"}
    ;
    var parse_resp: types.cliproxy_buffer = .{ .ptr = null, .len = 0 };
    const ret = pluginCall("auth.parse", parse_req.ptr, parse_req.len, &parse_resp);
    try std.testing.expectEqual(@as(c_int, 0), ret);
    try std.testing.expect(parse_resp.ptr != null);
    defer pluginFree(parse_resp.ptr, parse_resp.len);

    const slice = @as([*]const u8, @ptrCast(parse_resp.ptr.?))[0..parse_resp.len];
    try std.testing.expect(std.mem.indexOf(u8, slice, "\"Handled\":false") != null);
}
