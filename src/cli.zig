const std = @import("std");
const types = @import("types.zig");
const auth = @import("auth.zig");
const http_client = @import("http_client.zig");

/// Registers the --gemini-web-auth CLI flag
pub fn handleCommandLineRegister(allocator: std.mem.Allocator) ![]u8 {
    const reg_json =
        \\{
        \\  "Flags": [
        \\    {
        \\      "Name": "gemini-web-auth",
        \\      "Usage": "Import Gemini Web authentication cookie in header format (e.g. Cookie: __Secure-next-auth.session-token=... or Google cookies)",
        \\      "Type": "string",
        \\      "DefaultValue": ""
        \\    }
        \\  ]
        \\}
    ;
    return types.wrapOk(allocator, reg_json);
}

/// Executes the CLI command when --gemini-web-auth is triggered
pub fn handleCommandLineExecute(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) {
        return types.wrapError(allocator, "invalid_request", "invalid command line execution request");
    }

    const root = parsed.value.object;
    const flags_val = root.get("Flags");

    var cookie_text: ?[]const u8 = null;

    if (flags_val != null and flags_val.? == .object) {
        if (flags_val.?.object.get("gemini-web-auth")) |flag_obj| {
            if (flag_obj == .object) {
                if (flag_obj.object.get("Value")) |val| {
                    if (val == .string and val.string.len > 0) {
                        cookie_text = val.string;
                    }
                }
            }
        }
    }

    // Fallback: check Args array for --gemini-web-auth <val>
    if (cookie_text == null) {
        if (root.get("Args")) |args_val| {
            if (args_val == .array) {
                for (args_val.array.items, 0..) |arg, idx| {
                    if (arg == .string) {
                        if (std.mem.startsWith(u8, arg.string, "--gemini-web-auth=")) {
                            cookie_text = arg.string["--gemini-web-auth=".len..];
                            break;
                        } else if (std.mem.eql(u8, arg.string, "--gemini-web-auth") and idx + 1 < args_val.array.items.len) {
                            const next_arg = args_val.array.items[idx + 1];
                            if (next_arg == .string) {
                                cookie_text = next_arg.string;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    if (cookie_text == null or cookie_text.?.len == 0) {
        const msg = "[flow2cpa] No cookie provided. Usage: --gemini-web-auth \"Cookie: __Secure-next-auth.session-token=...\"\n";
        const b64_stdout = try types.base64Encode(allocator, msg);
        defer allocator.free(b64_stdout);

        const res = try std.fmt.allocPrint(
            allocator,
            "{{\"Stdout\":\"{s}\",\"Stderr\":\"\",\"Auths\":[],\"ExitCode\":0}}",
            .{b64_stdout},
        );
        defer allocator.free(res);
        return types.wrapOk(allocator, res);
    }

    // Run import pipeline
    const storage = auth.importAuthentication(allocator, cookie_text.?) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = try std.fmt.bufPrint(&err_buf, "[flow2cpa] Failed to import authentication from cookie: {s}\n", .{@errorName(err)});
        const b64_stderr = try types.base64Encode(allocator, err_msg);
        defer allocator.free(b64_stderr);

        const res = try std.fmt.allocPrint(
            allocator,
            "{{\"Stdout\":\"\",\"Stderr\":\"{s}\",\"Auths\":[],\"ExitCode\":1}}",
            .{b64_stderr},
        );
        defer allocator.free(res);
        return types.wrapOk(allocator, res);
    };
    defer {
        allocator.free(storage.st);
        allocator.free(storage.at);
        allocator.free(storage.at_expires);
        allocator.free(storage.email);
        allocator.free(storage.name);
        if (storage.project_id.len > 0) allocator.free(storage.project_id);
    }

    // Construct AuthData JSON
    const auth_json = try auth.buildAuthDataJSON(allocator, storage);
    defer allocator.free(auth_json);

    // Save physical auth file via host.auth.save callback
    const filename = if (storage.email.len > 0)
        try std.fmt.allocPrint(allocator, "gemini-web-{s}.json", .{storage.email})
    else
        try allocator.dupe(u8, "gemini-web.json");
    defer allocator.free(filename);

    _ = http_client.hostAuthSave(allocator, filename, auth_json) catch {};

    // Build success message for stdout
    const email_display = if (storage.email.len > 0) storage.email else "authenticated account";
    const pid_display = if (storage.project_id.len > 0) storage.project_id else "default";

    const msg = try std.fmt.allocPrint(
        allocator,
        "[flow2cpa] Successfully imported Gemini Web authentication!\n" ++
            "  Account: {s}\n" ++
            "  Project: {s}\n" ++
            "  File: {s}\n" ++
            "  Status: Active & ready for image/video generation\n",
        .{ email_display, pid_display, filename },
    );
    defer allocator.free(msg);

    const b64_stdout = try types.base64Encode(allocator, msg);
    defer allocator.free(b64_stdout);

    const res = try std.fmt.allocPrint(
        allocator,
        "{{\"Stdout\":\"{s}\",\"Stderr\":\"\",\"Auths\":[{s}],\"ExitCode\":0}}",
        .{ b64_stdout, auth_json },
    );
    defer allocator.free(res);

    return types.wrapOk(allocator, res);
}

test "cli register" {
    const allocator = std.testing.allocator;
    const resp = try handleCommandLineRegister(allocator);
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "gemini-web-auth") != null);
}
