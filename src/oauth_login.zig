const std = @import("std");
const types = @import("types.zig");
const auth = @import("auth.zig");
const http_client = @import("http_client.zig");

// Global pending login state holder
pub var pending_login_state: ?[]const u8 = null;
pub var pending_imported_storage: ?types.StorageData = null;

/// Starts login flow for CPA OAuth page / Management OAuth tab
pub fn handleLoginStart(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    _ = request_bytes;

    // Generate a random state
    var state_buf: [16]u8 = undefined;
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    var prng = std.Random.DefaultPrng.init(0x918273645a4b3c2d);
    const rand = prng.random();
    for (0..16) |i| {
        state_buf[i] = chars[rand.uintLessThan(usize, chars.len)];
    }

    if (pending_login_state) |ps| {
        allocator.free(ps);
    }
    pending_login_state = try allocator.dupe(u8, &state_buf);

    // URL directs user to the plugin resource auth page
    const login_url = "/v0/resource/plugins/gemini-web/auth";

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"Provider\":\"gemini-web\",\"URL\":\"");
    try list.appendSlice(allocator, login_url);
    try list.appendSlice(allocator, "\",\"State\":\"");
    try list.appendSlice(allocator, pending_login_state.?);
    try list.appendSlice(allocator, "\",\"ExpiresAt\":\"2030-01-01T00:00:00Z\",\"Metadata\":{\"instructions\":\"Open Gemini Web auth page to paste cookies or session-token.\"}}");

    return types.wrapOk(allocator, list.items);
}

/// Polls login flow for CPA OAuth page
pub fn handleLoginPoll(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    _ = request_bytes;

    if (pending_imported_storage) |storage| {
        // We have successfully imported authentication from the page!
        const auth_json = try auth.buildAuthDataJSON(allocator, storage);
        defer allocator.free(auth_json);

        // Clear after successful poll
        pending_imported_storage = null;

        const res = try std.fmt.allocPrint(
            allocator,
            "{{\"Status\":\"success\",\"Message\":\"Gemini Web authentication imported!\",\"Auth\":{s}}}",
            .{auth_json},
        );
        defer allocator.free(res);

        return types.wrapOk(allocator, res);
    }

    // Still waiting for cookie input
    return types.wrapOk(
        allocator,
        "{\"Status\":\"pending\",\"Message\":\"Waiting for cookie submission in Gemini Web page (/v0/resource/plugins/gemini-web/auth)...\"}",
    );
}
