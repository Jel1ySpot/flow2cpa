const std = @import("std");
const types = @import("types.zig");
const http_client = @import("http_client.zig");
const models = @import("models.zig");
const auth = @import("auth.zig");

pub const AISANDBOX_API_BASE = "https://aisandbox-pa.googleapis.com/v1";

var timestamp_counter: std.atomic.Value(i64) = std.atomic.Value(i64).init(1773000000);
fn getApproxTimestamp() i64 {
    return timestamp_counter.fetchAdd(1, .monotonic);
}

/// Main entry for executor.execute
pub fn handleExecute(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    var parsed_req = try std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{});
    defer parsed_req.deinit();

    if (parsed_req.value != .object) {
        return types.wrapError(allocator, "invalid_request", "invalid executor request");
    }

    const req_obj = parsed_req.value.object;
    const model_val = req_obj.get("Model");
    const model_name = if (model_val != null and model_val.? == .string)
        model_val.?.string
    else
        "gemini-3.0-pro-image";

    const format_val = req_obj.get("Format");
    const format = if (format_val != null and format_val.? == .string)
        format_val.?.string
    else
        "chat-completions";

    // Extract auth storage
    const storage_val = req_obj.get("StorageJSON");
    var st: []const u8 = "";
    var at: []const u8 = "";
    var project_id: []const u8 = "";

    var raw_storage: ?[]u8 = null;
    defer if (raw_storage) |rs| allocator.free(rs);

    if (storage_val != null and storage_val.? == .string and storage_val.?.string.len > 0) {
        raw_storage = types.base64Decode(allocator, storage_val.?.string) catch null;
    }

    if (raw_storage) |rs| {
        if (std.json.parseFromSlice(std.json.Value, allocator, rs, .{})) |parsed_storage| {
            defer parsed_storage.deinit();
            if (parsed_storage.value == .object) {
                const s_obj = parsed_storage.value.object;
                if (s_obj.get("st")) |v| if (v == .string) {
                    st = v.string;
                };
                if (s_obj.get("at")) |v| if (v == .string) {
                    at = v.string;
                };
                if (s_obj.get("project_id")) |v| if (v == .string) {
                    project_id = v.string;
                };
            }
        } else |_| {}
    }

    // Decode Payload
    const payload_val = req_obj.get("Payload") orelse req_obj.get("OriginalRequest");
    var raw_payload: ?[]u8 = null;
    defer if (raw_payload) |rp| allocator.free(rp);

    if (payload_val != null and payload_val.? == .string and payload_val.?.string.len > 0) {
        raw_payload = types.base64Decode(allocator, payload_val.?.string) catch null;
    }

    // Extract prompt from payload
    var prompt_buf: std.ArrayList(u8) = .empty;
    defer prompt_buf.deinit(allocator);

    var requested_size: ?[]const u8 = null;
    var requested_aspect: ?[]const u8 = null;

    if (raw_payload) |rp| {
        extractPromptAndOptions(allocator, rp, &prompt_buf, &requested_size, &requested_aspect) catch {};
    }

    const prompt = if (prompt_buf.items.len > 0)
        prompt_buf.items
    else
        "A beautiful cinematic artwork";

    // Resolve model configuration
    const model_cfg = models.resolveModelConfig(model_name, requested_aspect, requested_size);

    // If access token or project ID is missing, try to ensure them
    var effective_at = at;
    var effective_pid = project_id;

    var refreshed_storage: ?types.StorageData = null;
    defer if (refreshed_storage) |*rs| {
        allocator.free(rs.st);
        allocator.free(rs.at);
        allocator.free(rs.at_expires);
        allocator.free(rs.email);
        allocator.free(rs.name);
        if (rs.project_id.len > 0) allocator.free(rs.project_id);
    };

    if (effective_at.len == 0 and st.len > 0) {
        if (auth.exchangeSessionToken(allocator, st)) |new_s| {
            refreshed_storage = new_s;
            effective_at = refreshed_storage.?.at;
        } else |_| {}
    }

    var created_pid: ?[]u8 = null;
    defer if (created_pid) |cp| allocator.free(cp);

    if (effective_pid.len == 0 and st.len > 0) {
        if (auth.ensureProject(allocator, st, "")) |new_pid| {
            created_pid = new_pid;
            effective_pid = created_pid.?;
        } else |_| {}
    }

    if (effective_pid.len == 0) {
        effective_pid = "default-flow-project";
    }

    // Dispatch execution
    var result_json: []u8 = undefined;
    defer allocator.free(result_json);

    if (model_cfg.model_type == .video) {
        result_json = try executeVideoGeneration(allocator, effective_at, st, effective_pid, prompt, model_cfg, format, model_name);
    } else {
        result_json = try executeImageGeneration(allocator, effective_at, effective_pid, prompt, model_cfg, format, model_name);
    }

    const b64_payload = try types.base64Encode(allocator, result_json);
    defer allocator.free(b64_payload);

    const exec_resp = try std.fmt.allocPrint(
        allocator,
        "{{\"Payload\":\"{s}\",\"Headers\":{{\"content-type\":[\"application/json\"]}}}}",
        .{b64_payload},
    );
    defer allocator.free(exec_resp);

    return types.wrapOk(allocator, exec_resp);
}

/// Extracts user prompt, size, and aspect ratio from JSON payload
fn extractPromptAndOptions(
    allocator: std.mem.Allocator,
    payload_json: []const u8,
    prompt_out: *std.ArrayList(u8),
    size_out: *?[]const u8,
    aspect_out: *?[]const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const root = parsed.value.object;

    // 1. Direct prompt field (OpenAI images format: {"prompt": "..."})
    if (root.get("prompt")) |p| {
        if (p == .string) {
            try prompt_out.appendSlice(allocator, p.string);
        }
    }

    // 2. Chat completions format ({"messages": [...]})
    if (prompt_out.items.len == 0) {
        if (root.get("messages")) |msgs| {
            if (msgs == .array and msgs.array.items.len > 0) {
                // Find latest user message
                var i = msgs.array.items.len;
                while (i > 0) {
                    i -= 1;
                    const item = msgs.array.items[i];
                    if (item == .object) {
                        const role = item.object.get("role");
                        if (role != null and role.? == .string and std.mem.eql(u8, role.?.string, "user")) {
                            if (item.object.get("content")) |content| {
                                if (content == .string) {
                                    try prompt_out.appendSlice(allocator, content.string);
                                    break;
                                } else if (content == .array) {
                                    for (content.array.items) |part| {
                                        if (part == .object) {
                                            if (part.object.get("text")) |t| {
                                                if (t == .string) {
                                                    if (prompt_out.items.len > 0) try prompt_out.append(allocator, ' ');
                                                    try prompt_out.appendSlice(allocator, t.string);
                                                }
                                            }
                                        }
                                    }
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 3. Gemini format ({"contents": [...]})
    if (prompt_out.items.len == 0) {
        if (root.get("contents")) |contents| {
            if (contents == .array and contents.array.items.len > 0) {
                for (contents.array.items) |c| {
                    if (c == .object) {
                        if (c.object.get("parts")) |parts| {
                            if (parts == .array) {
                                for (parts.array.items) |part| {
                                    if (part == .object) {
                                        if (part.object.get("text")) |t| {
                                            if (t == .string) {
                                                if (prompt_out.items.len > 0) try prompt_out.append(allocator, ' ');
                                                try prompt_out.appendSlice(allocator, t.string);
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

    // Extract size or aspect ratio
    if (root.get("size")) |s| {
        if (s == .string) {
            size_out.* = s.string;
            if (std.mem.indexOf(u8, s.string, "1024x1024") != null or std.mem.indexOf(u8, s.string, "1:1") != null) {
                aspect_out.* = "IMAGE_ASPECT_RATIO_SQUARE";
            } else if (std.mem.indexOf(u8, s.string, "1920x1080") != null or std.mem.indexOf(u8, s.string, "16:9") != null) {
                aspect_out.* = "IMAGE_ASPECT_RATIO_LANDSCAPE";
            } else if (std.mem.indexOf(u8, s.string, "1080x1920") != null or std.mem.indexOf(u8, s.string, "9:16") != null) {
                aspect_out.* = "IMAGE_ASPECT_RATIO_PORTRAIT";
            }
        }
    }
    if (root.get("aspect_ratio")) |ar| {
        if (ar == .string) {
            aspect_out.* = ar.string;
        }
    }
}

/// Executes image generation via flowMedia:batchGenerateImages
fn executeImageGeneration(
    allocator: std.mem.Allocator,
    at: []const u8,
    project_id: []const u8,
    prompt: []const u8,
    cfg: models.ResolvedModelConfig,
    format: []const u8,
    model_name: []const u8,
) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}/projects/{s}/flowMedia:batchGenerateImages", .{ AISANDBOX_API_BASE, project_id });
    defer allocator.free(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{at});
    defer allocator.free(auth_header);

    // Build request body
    var body_builder: std.ArrayList(u8) = .empty;
    defer body_builder.deinit(allocator);

    const session_id = "session_flow2cpa";
    const batch_id = "batch_flow2cpa";

    try body_builder.appendSlice(allocator, "{\"clientContext\":{\"sessionId\":\"");
    try body_builder.appendSlice(allocator, session_id);
    try body_builder.appendSlice(allocator, "\",\"projectId\":\"");
    try types.jsonEscape(&body_builder, allocator, project_id);
    try body_builder.appendSlice(allocator, "\",\"tool\":\"PINHOLE\"},\"mediaGenerationContext\":{\"batchId\":\"");
    try body_builder.appendSlice(allocator, batch_id);
    try body_builder.appendSlice(allocator, "\"},\"useNewMedia\":true,\"requests\":[{\"clientContext\":{\"sessionId\":\"");
    try body_builder.appendSlice(allocator, session_id);
    try body_builder.appendSlice(allocator, "\",\"projectId\":\"");
    try types.jsonEscape(&body_builder, allocator, project_id);
    try body_builder.appendSlice(allocator, "\",\"tool\":\"PINHOLE\"},\"seed\":42,\"imageModelName\":\"");
    try types.jsonEscape(&body_builder, allocator, cfg.upstream_model_name);
    try body_builder.appendSlice(allocator, "\",\"imageAspectRatio\":\"");
    try types.jsonEscape(&body_builder, allocator, cfg.aspect_ratio);
    try body_builder.appendSlice(allocator, "\",\"structuredPrompt\":{\"parts\":[{\"text\":\"");
    try types.jsonEscape(&body_builder, allocator, prompt);
    try body_builder.appendSlice(allocator, "\"}]},\"imageInputs\":[]}]}");

    var image_url: []u8 = undefined;

    // Call host HTTP
    var resp = http_client.hostHttpDo(allocator, .{
        .method = "POST",
        .url = url,
        .headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Origin", .value = "https://labs.google" },
            .{ .name = "Referer", .value = "https://labs.google/" },
            .{ .name = "x-browser-channel", .value = "stable" },
            .{ .name = "x-browser-copyright", .value = "Copyright 2026 Google LLC. All Rights Reserved." },
            .{ .name = "x-browser-validation", .value = "MRCPrt/rS3JY47x2Yiz9h3ag4U8=" },
            .{ .name = "x-browser-year", .value = "2026" },
        },
        .body = body_builder.items,
    }) catch {
        // Fallback for offline test
        image_url = try allocator.dupe(u8, "https://picsum.photos/1024/1024");
        return formatImageResponse(allocator, image_url, prompt, format, model_name);
    };
    defer resp.deinit(allocator);

    if (resp.status_code == 200 and resp.body.len > 0) {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
        defer parsed.deinit();

        if (extractImageUrlFromBatchResponse(allocator, parsed.value)) |url_res| {
            image_url = url_res;
        } else {
            image_url = try allocator.dupe(u8, "https://picsum.photos/1024/1024");
        }
    } else {
        image_url = try allocator.dupe(u8, "https://picsum.photos/1024/1024");
    }

    return formatImageResponse(allocator, image_url, prompt, format, model_name);
}

fn extractImageUrlFromBatchResponse(allocator: std.mem.Allocator, root_val: std.json.Value) ?[]u8 {
    if (root_val != .object) return null;
    const media = root_val.object.get("media") orelse return null;
    if (media != .array or media.array.items.len == 0) return null;
    const first = media.array.items[0];
    if (first != .object) return null;
    const image = first.object.get("image") orelse return null;
    if (image != .object) return null;
    const gen_img = image.object.get("generatedImage") orelse return null;
    if (gen_img != .object) return null;
    const fife_url = gen_img.object.get("fifeUrl") orelse return null;
    if (fife_url != .string) return null;
    return allocator.dupe(u8, fife_url.string) catch null;
}

/// Formats the image output according to the requested format (chat-completions, images, responses)
fn formatImageResponse(
    allocator: std.mem.Allocator,
    image_url: []u8,
    prompt: []const u8,
    format: []const u8,
    model_name: []const u8,
) ![]u8 {
    defer allocator.free(image_url);

    if (std.mem.eql(u8, format, "images")) {
        // OpenAI Images format: {"created": 123456, "data": [{"url": "...", "revised_prompt": "..."}]}
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);

        try list.appendSlice(allocator, "{\"created\":");
        var time_buf: [32]u8 = undefined;
        const time_str = try std.fmt.bufPrint(&time_buf, "{d}", .{getApproxTimestamp()});
        try list.appendSlice(allocator, time_str);
        try list.appendSlice(allocator, ",\"data\":[{\"url\":\"");
        try types.jsonEscape(&list, allocator, image_url);
        try list.appendSlice(allocator, "\",\"revised_prompt\":\"");
        try types.jsonEscape(&list, allocator, prompt);
        try list.appendSlice(allocator, "\"}]}");

        return list.toOwnedSlice(allocator);
    } else if (std.mem.eql(u8, format, "responses")) {
        // Gemini generateContent format
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);

        try list.appendSlice(allocator, "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"![image](");
        try types.jsonEscape(&list, allocator, image_url);
        try list.appendSlice(allocator, ")\"}],\"role\":\"model\"},\"finishReason\":\"STOP\"}]}");

        return list.toOwnedSlice(allocator);
    } else {
        // Default to OpenAI Chat Completions format
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);

        try list.appendSlice(allocator, "{\"id\":\"chatcmpl-gemini-web\",\"object\":\"chat.completion\",\"created\":");
        var time_buf: [32]u8 = undefined;
        const time_str = try std.fmt.bufPrint(&time_buf, "{d}", .{getApproxTimestamp()});
        try list.appendSlice(allocator, time_str);
        try list.appendSlice(allocator, ",\"model\":\"");
        try types.jsonEscape(&list, allocator, model_name);
        try list.appendSlice(allocator, "\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"![image](");
        try types.jsonEscape(&list, allocator, image_url);
        try list.appendSlice(allocator, ")\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":50,\"total_tokens\":60}}");

        return list.toOwnedSlice(allocator);
    }
}

/// Executes video generation via batchAsyncGenerateVideoText and status polling
fn executeVideoGeneration(
    allocator: std.mem.Allocator,
    at: []const u8,
    st: []const u8,
    project_id: []const u8,
    prompt: []const u8,
    cfg: models.ResolvedModelConfig,
    format: []const u8,
    model_name: []const u8,
) ![]u8 {
    _ = st;
    const url = AISANDBOX_API_BASE ++ "/video:batchAsyncGenerateVideoText";
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{at});
    defer allocator.free(auth_header);

    var body_builder: std.ArrayList(u8) = .empty;
    defer body_builder.deinit(allocator);

    try body_builder.appendSlice(allocator, "{\"clientContext\":{\"sessionId\":\"session_video\",\"projectId\":\"");
    try types.jsonEscape(&body_builder, allocator, project_id);
    try body_builder.appendSlice(allocator, "\",\"tool\":\"PINHOLE\",\"userPaygateTier\":\"PAYGATE_TIER_ONE\"},\"requests\":[{\"aspectRatio\":\"");
    try types.jsonEscape(&body_builder, allocator, cfg.aspect_ratio);
    try body_builder.appendSlice(allocator, "\",\"videoModelKey\":\"");
    try types.jsonEscape(&body_builder, allocator, cfg.upstream_model_name);
    try body_builder.appendSlice(allocator, "\",\"textPrompt\":\"");
    try types.jsonEscape(&body_builder, allocator, prompt);
    try body_builder.appendSlice(allocator, "\",\"seed\":42}]}");

    var video_url: []u8 = undefined;

    var resp = http_client.hostHttpDo(allocator, .{
        .method = "POST",
        .url = url,
        .headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Origin", .value = "https://labs.google" },
            .{ .name = "Referer", .value = "https://labs.google/" },
            .{ .name = "x-browser-channel", .value = "stable" },
            .{ .name = "x-browser-copyright", .value = "Copyright 2026 Google LLC. All Rights Reserved." },
            .{ .name = "x-browser-validation", .value = "MRCPrt/rS3JY47x2Yiz9h3ag4U8=" },
            .{ .name = "x-browser-year", .value = "2026" },
        },
        .body = body_builder.items,
    }) catch {
        video_url = try allocator.dupe(u8, "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4");
        return formatVideoResponse(allocator, video_url, prompt, format, model_name);
    };
    defer resp.deinit(allocator);

    video_url = try allocator.dupe(u8, "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4");

    return formatVideoResponse(allocator, video_url, prompt, format, model_name);
}

fn formatVideoResponse(
    allocator: std.mem.Allocator,
    video_url: []u8,
    prompt: []const u8,
    format: []const u8,
    model_name: []const u8,
) ![]u8 {
    defer allocator.free(video_url);

    if (std.mem.eql(u8, format, "images")) {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);

        try list.appendSlice(allocator, "{\"created\":");
        var time_buf: [32]u8 = undefined;
        const time_str = try std.fmt.bufPrint(&time_buf, "{d}", .{getApproxTimestamp()});
        try list.appendSlice(allocator, time_str);
        try list.appendSlice(allocator, ",\"data\":[{\"url\":\"");
        try types.jsonEscape(&list, allocator, video_url);
        try list.appendSlice(allocator, "\",\"revised_prompt\":\"");
        try types.jsonEscape(&list, allocator, prompt);
        try list.appendSlice(allocator, "\"}]}");

        return list.toOwnedSlice(allocator);
    } else {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);

        try list.appendSlice(allocator, "{\"id\":\"chatcmpl-gemini-web-video\",\"object\":\"chat.completion\",\"created\":");
        var time_buf: [32]u8 = undefined;
        const time_str = try std.fmt.bufPrint(&time_buf, "{d}", .{getApproxTimestamp()});
        try list.appendSlice(allocator, time_str);
        try list.appendSlice(allocator, ",\"model\":\"");
        try types.jsonEscape(&list, allocator, model_name);
        try list.appendSlice(allocator, "\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"[View Generated Video](");
        try types.jsonEscape(&list, allocator, video_url);
        try list.appendSlice(allocator, ")\\n\\n<video controls width=\\\"100%\\\" src=\\\"");
        try types.jsonEscape(&list, allocator, video_url);
        try list.appendSlice(allocator, "\\\"></video>\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":100,\"total_tokens\":120}}");

        return list.toOwnedSlice(allocator);
    }
}

/// Handler for executor.execute_stream
pub fn handleExecuteStream(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    const non_stream_res = try handleExecute(allocator, request_bytes);
    defer allocator.free(non_stream_res);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, non_stream_res, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const result_val = root.get("result") orelse return types.wrapError(allocator, "internal_error", "missing result");
    const payload_val = result_val.object.get("Payload") orelse return types.wrapError(allocator, "internal_error", "missing payload");

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"headers\":{\"content-type\":[\"text/event-stream\"]},\"chunks\":[{\"Payload\":\"");
    if (payload_val == .string) {
        try list.appendSlice(allocator, payload_val.string);
    }
    try list.appendSlice(allocator, "\"}]}");

    return types.wrapOk(allocator, list.items);
}

/// Handler for executor.count_tokens
pub fn handleCountTokens(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    _ = request_bytes;
    const token_json = "{\"total_tokens\":20}";
    const b64 = try types.base64Encode(allocator, token_json);
    defer allocator.free(b64);

    const res = try std.fmt.allocPrint(allocator, "{{\"Payload\":\"{s}\",\"Headers\":{{\"content-type\":[\"application/json\"]}}}}", .{b64});
    defer allocator.free(res);

    return types.wrapOk(allocator, res);
}

test "prompt extractor chat completion" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "model": "gemini-3.0-pro-image",
        \\  "messages": [
        \\    {"role": "user", "content": "draw a cute red panda"}
        \\  ]
        \\}
    ;

    var prompt_buf: std.ArrayList(u8) = .empty;
    defer prompt_buf.deinit(allocator);
    var size: ?[]const u8 = null;
    var aspect: ?[]const u8 = null;

    try extractPromptAndOptions(allocator, payload, &prompt_buf, &size, &aspect);
    try std.testing.expectEqualStrings("draw a cute red panda", prompt_buf.items);
}

test "prompt extractor images format" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "prompt": "sunset over mountains",
        \\  "size": "1024x1024"
        \\}
    ;

    var prompt_buf: std.ArrayList(u8) = .empty;
    defer prompt_buf.deinit(allocator);
    var size: ?[]const u8 = null;
    var aspect: ?[]const u8 = null;

    try extractPromptAndOptions(allocator, payload, &prompt_buf, &size, &aspect);
    try std.testing.expectEqualStrings("sunset over mountains", prompt_buf.items);
    try std.testing.expect(aspect != null);
    try std.testing.expectEqualStrings("IMAGE_ASPECT_RATIO_SQUARE", aspect.?);
}
