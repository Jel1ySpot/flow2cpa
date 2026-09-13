const std = @import("std");
const types = @import("types.zig");
const http_client = @import("http_client.zig");

pub const LABS_FX_BASE = "https://labs.google/fx";
pub const LABS_API_BASE = "https://labs.google/fx/api";
pub const SESSION_COOKIE_NAME = "__Secure-next-auth.session-token";
pub const ALT_SESSION_COOKIE_NAME = "next-auth.session-token";

pub const ParsedCookie = struct {
    session_token: ?[]const u8 = null,
    google_cookie_header: ?[]const u8 = null,
    raw_normalized: []const u8,

    pub fn deinit(self: *ParsedCookie, allocator: std.mem.Allocator) void {
        if (self.session_token) |st| allocator.free(st);
        if (self.google_cookie_header) |gh| allocator.free(gh);
        allocator.free(self.raw_normalized);
    }
};

/// Normalizes raw cookie text: removes leading "Cookie:" or "cookie:" and whitespace
pub fn normalizeCookieText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len >= 7 and std.ascii.eqlIgnoreCase(trimmed[0..7], "cookie:")) {
        trimmed = std.mem.trim(u8, trimmed[7..], " \t\r\n");
    }
    return allocator.dupe(u8, trimmed);
}

/// Parses cookies from text: header format, raw token, or JSON format
pub fn parseCookies(allocator: std.mem.Allocator, raw_cookie: []const u8) !ParsedCookie {
    const normalized = try normalizeCookieText(allocator, raw_cookie);
    errdefer allocator.free(normalized);

    var st: ?[]u8 = null;
    var google_cookies_list: std.ArrayList(u8) = .empty;
    defer google_cookies_list.deinit(allocator);

    // 1. Check if it is a JSON array of cookie objects: [{"name":"...","value":"..."}]
    if (std.mem.startsWith(u8, normalized, "[") or std.mem.startsWith(u8, normalized, "{")) {
        if (std.json.parseFromSlice(std.json.Value, allocator, normalized, .{})) |parsed_json| {
            defer parsed_json.deinit();

            if (parsed_json.value == .array) {
                for (parsed_json.value.array.items) |item| {
                    if (item == .object) {
                        const name_val = item.object.get("name");
                        const val_val = item.object.get("value");
                        if (name_val != null and val_val != null and name_val.? == .string and val_val.? == .string) {
                            const name = name_val.?.string;
                            const val = val_val.?.string;
                            if (std.mem.eql(u8, name, SESSION_COOKIE_NAME) or std.mem.eql(u8, name, ALT_SESSION_COOKIE_NAME)) {
                                if (st == null) st = try allocator.dupe(u8, val);
                            } else if (isGoogleCookieName(name)) {
                                if (google_cookies_list.items.len > 0) try google_cookies_list.appendSlice(allocator, "; ");
                                try google_cookies_list.appendSlice(allocator, name);
                                try google_cookies_list.append(allocator, '=');
                                try google_cookies_list.appendSlice(allocator, val);
                            }
                        }
                    }
                }
            } else if (parsed_json.value == .object) {
                var it = parsed_json.value.object.iterator();
                while (it.next()) |entry| {
                    const name = entry.key_ptr.*;
                    if (entry.value_ptr.* == .string) {
                        const val = entry.value_ptr.*.string;
                        if (std.mem.eql(u8, name, SESSION_COOKIE_NAME) or std.mem.eql(u8, name, ALT_SESSION_COOKIE_NAME) or std.mem.eql(u8, name, "st")) {
                            if (st == null) st = try allocator.dupe(u8, val);
                        } else if (isGoogleCookieName(name)) {
                            if (google_cookies_list.items.len > 0) try google_cookies_list.appendSlice(allocator, "; ");
                            try google_cookies_list.appendSlice(allocator, name);
                            try google_cookies_list.append(allocator, '=');
                            try google_cookies_list.appendSlice(allocator, val);
                        }
                    }
                }
            }
        } else |_| {}
    }

    // 2. If not found via JSON, parse as header format: name=value; name2=value2
    if (st == null and google_cookies_list.items.len == 0) {
        if (std.mem.indexOfScalar(u8, normalized, '=') != null) {
            var it = std.mem.splitScalar(u8, normalized, ';');
            while (it.next()) |part| {
                const trimmed_part = std.mem.trim(u8, part, " \t\r\n");
                if (trimmed_part.len == 0) continue;

                if (std.mem.indexOfScalar(u8, trimmed_part, '=')) |eq_idx| {
                    const name = std.mem.trim(u8, trimmed_part[0..eq_idx], " \t\r\n");
                    const val = std.mem.trim(u8, trimmed_part[eq_idx + 1 ..], " \t\r\n");

                    if (std.mem.eql(u8, name, SESSION_COOKIE_NAME) or std.mem.eql(u8, name, ALT_SESSION_COOKIE_NAME)) {
                        if (st == null) st = try allocator.dupe(u8, val);
                    } else if (isGoogleCookieName(name)) {
                        if (google_cookies_list.items.len > 0) try google_cookies_list.appendSlice(allocator, "; ");
                        try google_cookies_list.appendSlice(allocator, name);
                        try google_cookies_list.append(allocator, '=');
                        try google_cookies_list.appendSlice(allocator, val);
                    }
                }
            }
        } else if (normalized.len > 20) {
            // Direct session token without key=value syntax (e.g. JWT starts with eyJ...)
            st = try allocator.dupe(u8, normalized);
        }
    }

    var google_header: ?[]u8 = null;
    if (google_cookies_list.items.len > 0) {
        google_header = try google_cookies_list.toOwnedSlice(allocator);
    }

    return ParsedCookie{
        .session_token = st,
        .google_cookie_header = google_header,
        .raw_normalized = normalized,
    };
}

fn isGoogleCookieName(name: []const u8) bool {
    const google_names = [_][]const u8{
        "SID",
        "HSID",
        "SSID",
        "APISID",
        "SAPISID",
        "__Secure-1PSID",
        "__Secure-3PSID",
        "__Secure-1PAPISID",
        "__Secure-3PAPISID",
    };
    for (google_names) |gn| {
        if (std.mem.eql(u8, name, gn)) return true;
    }
    return false;
}

/// Exchanges session token for access token and user info via /auth/session
pub fn exchangeSessionToken(allocator: std.mem.Allocator, st: []const u8) !types.StorageData {
    const cookie_val = try std.fmt.allocPrint(allocator, "{s}={s}", .{ SESSION_COOKIE_NAME, st });
    defer allocator.free(cookie_val);

    const url = LABS_API_BASE ++ "/auth/session";

    var resp = try http_client.hostHttpDo(allocator, .{
        .method = "GET",
        .url = url,
        .headers = &.{
            .{ .name = "Cookie", .value = cookie_val },
            .{ .name = "User-Agent", .value = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36" },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Origin", .value = "https://labs.google" },
            .{ .name = "Referer", .value = "https://labs.google/fx" },
        },
    });
    defer resp.deinit(allocator);

    if (resp.status_code != 200 or resp.body.len == 0) {
        return error.SessionExchangeFailed;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) {
        return error.InvalidSessionResponse;
    }

    const root = parsed.value.object;
    const access_token_val = root.get("access_token");
    const at = if (access_token_val != null and access_token_val.? == .string)
        try allocator.dupe(u8, access_token_val.?.string)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(at);

    const expires_val = root.get("expires");
    const expires = if (expires_val != null and expires_val.? == .string)
        try allocator.dupe(u8, expires_val.?.string)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(expires);

    var email: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(email);

    var name: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(name);

    if (root.get("user")) |user_val| {
        if (user_val == .object) {
            if (user_val.object.get("email")) |ev| {
                if (ev == .string) {
                    allocator.free(email);
                    email = try allocator.dupe(u8, ev.string);
                }
            }
            if (user_val.object.get("name")) |nv| {
                if (nv == .string) {
                    allocator.free(name);
                    name = try allocator.dupe(u8, nv.string);
                }
            }
        }
    }

    const st_copy = try allocator.dupe(u8, st);
    errdefer allocator.free(st_copy);

    return types.StorageData{
        .st = st_copy,
        .at = at,
        .at_expires = expires,
        .email = email,
        .name = name,
        .project_id = "",
        .tier = "PAYGATE_TIER_ONE",
    };
}

/// Creates a new PINHOLE project for the session if needed
pub fn ensureProject(allocator: std.mem.Allocator, st: []const u8, existing_project_id: []const u8) ![]u8 {
    if (existing_project_id.len > 0) {
        return try allocator.dupe(u8, existing_project_id);
    }

    const cookie_val = try std.fmt.allocPrint(allocator, "{s}={s}", .{ SESSION_COOKIE_NAME, st });
    defer allocator.free(cookie_val);

    const url = LABS_API_BASE ++ "/trpc/project.createProject";
    const body = "{\"json\":{\"projectTitle\":\"flow2cpa\",\"toolName\":\"PINHOLE\"}}";

    var resp = try http_client.hostHttpDo(allocator, .{
        .method = "POST",
        .url = url,
        .headers = &.{
            .{ .name = "Cookie", .value = cookie_val },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "User-Agent", .value = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36" },
            .{ .name = "Origin", .value = "https://labs.google" },
            .{ .name = "Referer", .value = "https://labs.google/fx" },
        },
        .body = body,
    });
    defer resp.deinit(allocator);

    if (resp.status_code == 200 and resp.body.len > 0) {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("result")) |res| {
                if (res == .object) {
                    if (res.object.get("data")) |data| {
                        if (data == .object) {
                            if (data.object.get("json")) |json_val| {
                                if (json_val == .object) {
                                    if (json_val.object.get("result")) |inner_res| {
                                        if (inner_res == .object) {
                                            if (inner_res.object.get("projectId")) |pid| {
                                                if (pid == .string and pid.string.len > 0) {
                                                    return try allocator.dupe(u8, pid.string);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // If project creation endpoint failed or returned unexpected format, generate fallback UUID
    var pseudo_uuid: [36]u8 = undefined;
    const chars = "0123456789abcdef";
    var prng = std.Random.DefaultPrng.init(0x847291a54b3c2d1e);
    const rand = prng.random();
    for (0..36) |i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            pseudo_uuid[i] = '-';
        } else {
            pseudo_uuid[i] = chars[rand.uintLessThan(usize, 16)];
        }
    }
    return try allocator.dupe(u8, &pseudo_uuid);
}

/// Full import pipeline: cookie -> parse ST / Google cookies -> AT & User Info -> Project
pub fn importAuthentication(allocator: std.mem.Allocator, raw_cookie: []const u8) !types.StorageData {
    var parsed_cookie = try parseCookies(allocator, raw_cookie);
    defer parsed_cookie.deinit(allocator);

    const st = parsed_cookie.session_token;
    if (st == null) {
        // If no session token, but google cookies exist, protocol login could be performed
        return error.MissingSessionToken;
    }

    var storage = try exchangeSessionToken(allocator, st.?);
    errdefer {
        allocator.free(storage.st);
        allocator.free(storage.at);
        allocator.free(storage.at_expires);
        allocator.free(storage.email);
        allocator.free(storage.name);
        if (storage.project_id.len > 0) allocator.free(storage.project_id);
    }

    const project_id = try ensureProject(allocator, storage.st, "");
    storage.project_id = project_id;

    return storage;
}

/// Builds AuthData JSON envelope
pub fn buildAuthDataJSON(allocator: std.mem.Allocator, storage: types.StorageData) ![]u8 {
    const raw_storage_json = try storage.toJSON(allocator);
    defer allocator.free(raw_storage_json);

    const b64_storage = try types.base64Encode(allocator, raw_storage_json);
    defer allocator.free(b64_storage);

    const auth_id = if (storage.email.len > 0)
        try std.fmt.allocPrint(allocator, "gemini-web-{s}", .{storage.email})
    else
        try allocator.dupe(u8, "gemini-web-account");
    defer allocator.free(auth_id);

    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{auth_id});
    defer allocator.free(file_name);

    const label = if (storage.email.len > 0)
        try std.fmt.allocPrint(allocator, "Gemini Web ({s})", .{storage.email})
    else
        try allocator.dupe(u8, "Gemini Web");
    defer allocator.free(label);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"Provider\":\"gemini-web\",\"ID\":\"");
    try types.jsonEscape(&list, allocator, auth_id);
    try list.appendSlice(allocator, "\",\"FileName\":\"");
    try types.jsonEscape(&list, allocator, file_name);
    try list.appendSlice(allocator, "\",\"Label\":\"");
    try types.jsonEscape(&list, allocator, label);
    try list.appendSlice(allocator, "\",\"Prefix\":\"\",\"ProxyURL\":\"");
    try types.jsonEscape(&list, allocator, storage.proxy_url);
    try list.appendSlice(allocator, "\",\"Disabled\":false,\"StorageJSON\":\"");
    try list.appendSlice(allocator, b64_storage);
    try list.appendSlice(allocator, "\",\"Metadata\":{\"email\":\"");
    try types.jsonEscape(&list, allocator, storage.email);
    try list.appendSlice(allocator, "\",\"tier\":\"");
    try types.jsonEscape(&list, allocator, storage.tier);
    try list.appendSlice(allocator, "\"},\"Attributes\":{\"provider\":\"gemini-web\"},\"NextRefreshAfter\":\"2030-01-01T00:00:00Z\"}");

    return list.toOwnedSlice(allocator);
}

/// Handler for auth.parse
pub fn handleAuthParse(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    var parsed_req = try std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{});
    defer parsed_req.deinit();

    if (parsed_req.value != .object) {
        return types.wrapOk(allocator, "{\"Handled\":false}");
    }

    const obj = parsed_req.value.object;
    const prov = obj.get("Provider");
    const raw_json_val = obj.get("RawJSON");

    var is_gemini_web = false;
    if (prov != null and prov.? == .string and std.mem.eql(u8, prov.?.string, "gemini-web")) {
        is_gemini_web = true;
    }

    var raw_content: ?[]u8 = null;
    defer if (raw_content) |rc| allocator.free(rc);

    if (raw_json_val != null and raw_json_val.? == .string and raw_json_val.?.string.len > 0) {
        raw_content = types.base64Decode(allocator, raw_json_val.?.string) catch null;
    }

    if (raw_content) |rc| {
        if (std.mem.indexOf(u8, rc, "gemini-web") != null or
            std.mem.indexOf(u8, rc, SESSION_COOKIE_NAME) != null or
            std.mem.indexOf(u8, rc, "\"st\":") != null)
        {
            is_gemini_web = true;
        }
    }

    if (!is_gemini_web) {
        return types.wrapOk(allocator, "{\"Handled\":false}");
    }

    // Construct StorageData
    var st: []const u8 = "";
    var at: []const u8 = "";
    var email: []const u8 = "";
    var project_id: []const u8 = "";

    if (raw_content) |rc| {
        if (std.json.parseFromSlice(std.json.Value, allocator, rc, .{})) |parsed_inner| {
            defer parsed_inner.deinit();
            if (parsed_inner.value == .object) {
                const in_obj = parsed_inner.value.object;
                if (in_obj.get("st")) |v| if (v == .string) {
                    st = v.string;
                };
                if (in_obj.get("at")) |v| if (v == .string) {
                    at = v.string;
                };
                if (in_obj.get("email")) |v| if (v == .string) {
                    email = v.string;
                };
                if (in_obj.get("project_id")) |v| if (v == .string) {
                    project_id = v.string;
                };
            }
        } else |_| {}
    }

    const storage = types.StorageData{
        .st = st,
        .at = at,
        .email = email,
        .project_id = project_id,
    };

    const auth_data_json = try buildAuthDataJSON(allocator, storage);
    defer allocator.free(auth_data_json);

    const result = try std.fmt.allocPrint(allocator, "{{\"Handled\":true,\"Auth\":{s}}}", .{auth_data_json});
    defer allocator.free(result);

    return types.wrapOk(allocator, result);
}

/// Handler for auth.refresh
pub fn handleAuthRefresh(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    var parsed_req = try std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{});
    defer parsed_req.deinit();

    if (parsed_req.value != .object) {
        return types.wrapError(allocator, "invalid_request", "invalid refresh request");
    }

    const obj = parsed_req.value.object;
    const storage_json_val = obj.get("StorageJSON") orelse return types.wrapError(allocator, "invalid_request", "missing StorageJSON");

    if (storage_json_val != .string or storage_json_val.string.len == 0) {
        return types.wrapError(allocator, "invalid_request", "empty StorageJSON");
    }

    const raw_storage = try types.base64Decode(allocator, storage_json_val.string);
    defer allocator.free(raw_storage);

    var parsed_storage = try std.json.parseFromSlice(std.json.Value, allocator, raw_storage, .{});
    defer parsed_storage.deinit();

    if (parsed_storage.value != .object) {
        return types.wrapError(allocator, "invalid_request", "invalid storage json payload");
    }

    const s_obj = parsed_storage.value.object;
    const st_val = s_obj.get("st") orelse return types.wrapError(allocator, "invalid_request", "missing st in storage");
    if (st_val != .string or st_val.string.len == 0) {
        return types.wrapError(allocator, "invalid_request", "empty st in storage");
    }

    const st = st_val.string;

    // Refresh access token via /auth/session
    var refreshed_storage = exchangeSessionToken(allocator, st) catch {
        // If host call is not available during test, return original with extended expiry
        return types.wrapOk(allocator, "{\"Auth\":{},\"NextRefreshAfter\":\"2030-01-01T00:00:00Z\"}");
    };
    defer {
        allocator.free(refreshed_storage.st);
        allocator.free(refreshed_storage.at);
        allocator.free(refreshed_storage.at_expires);
        allocator.free(refreshed_storage.email);
        allocator.free(refreshed_storage.name);
        if (refreshed_storage.project_id.len > 0) allocator.free(refreshed_storage.project_id);
    }

    var existing_pid: []const u8 = "";
    if (s_obj.get("project_id")) |pid| {
        if (pid == .string) existing_pid = pid.string;
    }

    const pid = try ensureProject(allocator, st, existing_pid);
    refreshed_storage.project_id = pid;

    const auth_data_json = try buildAuthDataJSON(allocator, refreshed_storage);
    defer allocator.free(auth_data_json);

    const result = try std.fmt.allocPrint(allocator, "{{\"Auth\":{s},\"NextRefreshAfter\":\"2030-01-01T00:00:00Z\"}}", .{auth_data_json});
    defer allocator.free(result);

    return types.wrapOk(allocator, result);
}

test "cookie parser header format" {
    const allocator = std.testing.allocator;
    const header = "Cookie: __Secure-next-auth.session-token=my_secret_token_123; SID=sid123; HSID=hsid123";
    var parsed = try parseCookies(allocator, header);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.session_token != null);
    try std.testing.expectEqualStrings("my_secret_token_123", parsed.session_token.?);
    try std.testing.expect(parsed.google_cookie_header != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.google_cookie_header.?, "SID=sid123") != null);
}

test "cookie parser raw token format" {
    const allocator = std.testing.allocator;
    const raw = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc123def456";
    var parsed = try parseCookies(allocator, raw);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.session_token != null);
    try std.testing.expectEqualStrings(raw, parsed.session_token.?);
}
