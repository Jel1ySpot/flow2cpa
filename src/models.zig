const std = @import("std");
const types = @import("types.zig");

pub const ModelType = enum {
    image,
    video,
};

pub const ResolvedModelConfig = struct {
    model_type: ModelType,
    upstream_model_name: []const u8,
    aspect_ratio: []const u8,
    upsample: ?[]const u8 = null,
    is_i2v: bool = false,
};

pub const ModelMeta = struct {
    id: []const u8,
    display_name: []const u8,
    model_type: ModelType,
    upstream_name: []const u8,
    aspect_ratio: []const u8,
    upsample: ?[]const u8 = null,
    is_i2v: bool = false,
};

pub const ALL_MODELS = [_]ModelMeta{
    // Gemini 3.0 Pro Image (GEM_PIX_2)
    .{
        .id = "gemini-3.0-pro-image",
        .display_name = "Gemini 3.0 Pro Image (GEM_PIX_2)",
        .model_type = .image,
        .upstream_name = "GEM_PIX_2",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE",
    },
    .{
        .id = "gemini-3.0-pro-image-landscape",
        .display_name = "Gemini 3.0 Pro Image Landscape (16:9)",
        .model_type = .image,
        .upstream_name = "GEM_PIX_2",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE",
    },
    .{
        .id = "gemini-3.0-pro-image-portrait",
        .display_name = "Gemini 3.0 Pro Image Portrait (9:16)",
        .model_type = .image,
        .upstream_name = "GEM_PIX_2",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_PORTRAIT",
    },
    .{
        .id = "gemini-3.0-pro-image-square",
        .display_name = "Gemini 3.0 Pro Image Square (1:1)",
        .model_type = .image,
        .upstream_name = "GEM_PIX_2",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_SQUARE",
    },
    .{
        .id = "gemini-3.0-pro-image-four-three",
        .display_name = "Gemini 3.0 Pro Image 4:3",
        .model_type = .image,
        .upstream_name = "GEM_PIX_2",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE_FOUR_THREE",
    },
    .{
        .id = "gemini-3.0-pro-image-three-four",
        .display_name = "Gemini 3.0 Pro Image 3:4",
        .model_type = .image,
        .upstream_name = "GEM_PIX_2",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_PORTRAIT_THREE_FOUR",
    },
    .{
        .id = "gemini-3.0-pro-image-2k",
        .display_name = "Gemini 3.0 Pro Image 2K",
        .model_type = .image,
        .upstream_name = "GEM_PIX_2",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE",
        .upsample = "UPSAMPLE_IMAGE_RESOLUTION_2K",
    },
    .{
        .id = "gemini-3.0-pro-image-4k",
        .display_name = "Gemini 3.0 Pro Image 4K",
        .model_type = .image,
        .upstream_name = "GEM_PIX_2",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE",
        .upsample = "UPSAMPLE_IMAGE_RESOLUTION_4K",
    },

    // Gemini 3.1 Flash Image (NARWHAL)
    .{
        .id = "gemini-3.1-flash-image",
        .display_name = "Gemini 3.1 Flash Image (NARWHAL)",
        .model_type = .image,
        .upstream_name = "NARWHAL",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE",
    },
    .{
        .id = "gemini-3.1-flash-image-landscape",
        .display_name = "Gemini 3.1 Flash Image Landscape",
        .model_type = .image,
        .upstream_name = "NARWHAL",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE",
    },
    .{
        .id = "gemini-3.1-flash-image-portrait",
        .display_name = "Gemini 3.1 Flash Image Portrait",
        .model_type = .image,
        .upstream_name = "NARWHAL",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_PORTRAIT",
    },
    .{
        .id = "gemini-3.1-flash-image-square",
        .display_name = "Gemini 3.1 Flash Image Square",
        .model_type = .image,
        .upstream_name = "NARWHAL",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_SQUARE",
    },
    .{
        .id = "gemini-3.1-flash-image-2k",
        .display_name = "Gemini 3.1 Flash Image 2K",
        .model_type = .image,
        .upstream_name = "NARWHAL",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE",
        .upsample = "UPSAMPLE_IMAGE_RESOLUTION_2K",
    },
    .{
        .id = "gemini-3.1-flash-image-4k",
        .display_name = "Gemini 3.1 Flash Image 4K",
        .model_type = .image,
        .upstream_name = "NARWHAL",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE",
        .upsample = "UPSAMPLE_IMAGE_RESOLUTION_4K",
    },

    // Imagen 4.0 (IMAGEN_3_5)
    .{
        .id = "imagen-4.0-generate-preview",
        .display_name = "Imagen 4.0 Preview (IMAGEN_3_5)",
        .model_type = .image,
        .upstream_name = "IMAGEN_3_5",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE",
    },
    .{
        .id = "imagen-4.0-generate-preview-landscape",
        .display_name = "Imagen 4.0 Preview Landscape",
        .model_type = .image,
        .upstream_name = "IMAGEN_3_5",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_LANDSCAPE",
    },
    .{
        .id = "imagen-4.0-generate-preview-portrait",
        .display_name = "Imagen 4.0 Preview Portrait",
        .model_type = .image,
        .upstream_name = "IMAGEN_3_5",
        .aspect_ratio = "IMAGE_ASPECT_RATIO_PORTRAIT",
    },

    // Veo 3.1 Video
    .{
        .id = "veo_3_1_t2v",
        .display_name = "Veo 3.1 Text to Video",
        .model_type = .video,
        .upstream_name = "veo_3_1_t2v_fast",
        .aspect_ratio = "VIDEO_ASPECT_RATIO_LANDSCAPE",
    },
    .{
        .id = "veo_3_1_t2v_fast_landscape",
        .display_name = "Veo 3.1 T2V Fast Landscape",
        .model_type = .video,
        .upstream_name = "veo_3_1_t2v_fast",
        .aspect_ratio = "VIDEO_ASPECT_RATIO_LANDSCAPE",
    },
    .{
        .id = "veo_3_1_t2v_fast_portrait",
        .display_name = "Veo 3.1 T2V Fast Portrait",
        .model_type = .video,
        .upstream_name = "veo_3_1_t2v_fast_portrait",
        .aspect_ratio = "VIDEO_ASPECT_RATIO_PORTRAIT",
    },
    .{
        .id = "veo_3_1_t2v_landscape",
        .display_name = "Veo 3.1 T2V Landscape",
        .model_type = .video,
        .upstream_name = "veo_3_1_t2v_fast",
        .aspect_ratio = "VIDEO_ASPECT_RATIO_LANDSCAPE",
    },
    .{
        .id = "veo_3_1_t2v_portrait",
        .display_name = "Veo 3.1 T2V Portrait",
        .model_type = .video,
        .upstream_name = "veo_3_1_t2v_fast_portrait",
        .aspect_ratio = "VIDEO_ASPECT_RATIO_PORTRAIT",
    },
    .{
        .id = "veo_3_1_i2v_s_fast_fl",
        .display_name = "Veo 3.1 Image to Video Fast Landscape",
        .model_type = .video,
        .upstream_name = "veo_3_1_i2v_s_fast_fl",
        .aspect_ratio = "VIDEO_ASPECT_RATIO_LANDSCAPE",
        .is_i2v = true,
    },
    .{
        .id = "veo_3_1_i2v_s_fast_portrait_fl",
        .display_name = "Veo 3.1 Image to Video Fast Portrait",
        .model_type = .video,
        .upstream_name = "veo_3_1_i2v_s_fast_portrait_fl",
        .aspect_ratio = "VIDEO_ASPECT_RATIO_PORTRAIT",
        .is_i2v = true,
    },
};

/// Resolves model ID + optional requested aspect ratio / size to upstream config
pub fn resolveModelConfig(model_id: []const u8, requested_aspect: ?[]const u8, requested_size: ?[]const u8) ResolvedModelConfig {
    // 1. Exact match in catalog
    for (ALL_MODELS) |m| {
        if (std.ascii.eqlIgnoreCase(m.id, model_id)) {
            var aspect = m.aspect_ratio;
            var upsample = m.upsample;

            if (requested_aspect) |ra| {
                if (parseAspectRatio(ra, m.model_type)) |pa| {
                    aspect = pa;
                }
            }
            if (requested_size) |rs| {
                if (parseUpsampleSize(rs)) |pu| {
                    upsample = pu;
                }
            }

            return ResolvedModelConfig{
                .model_type = m.model_type,
                .upstream_model_name = m.upstream_name,
                .aspect_ratio = aspect,
                .upsample = upsample,
                .is_i2v = m.is_i2v,
            };
        }
    }

    // 2. Video fallback by prefix or keyword
    if (std.mem.indexOf(u8, model_id, "veo") != null or std.mem.indexOf(u8, model_id, "video") != null) {
        const is_portrait = std.mem.indexOf(u8, model_id, "portrait") != null;
        const is_i2v = std.mem.indexOf(u8, model_id, "i2v") != null;
        return ResolvedModelConfig{
            .model_type = .video,
            .upstream_model_name = if (is_portrait) "veo_3_1_t2v_fast_portrait" else "veo_3_1_t2v_fast",
            .aspect_ratio = if (is_portrait) "VIDEO_ASPECT_RATIO_PORTRAIT" else "VIDEO_ASPECT_RATIO_LANDSCAPE",
            .is_i2v = is_i2v,
        };
    }

    // 3. Image fallback: default to GEM_PIX_2
    var aspect: []const u8 = "IMAGE_ASPECT_RATIO_LANDSCAPE";
    if (std.mem.indexOf(u8, model_id, "portrait") != null) {
        aspect = "IMAGE_ASPECT_RATIO_PORTRAIT";
    } else if (std.mem.indexOf(u8, model_id, "square") != null) {
        aspect = "IMAGE_ASPECT_RATIO_SQUARE";
    }

    var upsample: ?[]const u8 = null;
    if (std.mem.indexOf(u8, model_id, "4k") != null) {
        upsample = "UPSAMPLE_IMAGE_RESOLUTION_4K";
    } else if (std.mem.indexOf(u8, model_id, "2k") != null) {
        upsample = "UPSAMPLE_IMAGE_RESOLUTION_2K";
    }

    const upstream = if (std.mem.indexOf(u8, model_id, "flash") != null)
        "NARWHAL"
    else if (std.mem.indexOf(u8, model_id, "imagen") != null)
        "IMAGEN_3_5"
    else
        "GEM_PIX_2";

    return ResolvedModelConfig{
        .model_type = .image,
        .upstream_model_name = upstream,
        .aspect_ratio = aspect,
        .upsample = upsample,
    };
}

fn parseAspectRatio(raw: []const u8, model_type: ModelType) ?[]const u8 {
    if (model_type == .video) {
        if (std.ascii.eqlIgnoreCase(raw, "portrait") or std.mem.eql(u8, raw, "9:16")) return "VIDEO_ASPECT_RATIO_PORTRAIT";
        if (std.ascii.eqlIgnoreCase(raw, "landscape") or std.mem.eql(u8, raw, "16:9")) return "VIDEO_ASPECT_RATIO_LANDSCAPE";
        return null;
    }
    if (std.ascii.eqlIgnoreCase(raw, "landscape") or std.mem.eql(u8, raw, "16:9")) return "IMAGE_ASPECT_RATIO_LANDSCAPE";
    if (std.ascii.eqlIgnoreCase(raw, "portrait") or std.mem.eql(u8, raw, "9:16")) return "IMAGE_ASPECT_RATIO_PORTRAIT";
    if (std.ascii.eqlIgnoreCase(raw, "square") or std.mem.eql(u8, raw, "1:1")) return "IMAGE_ASPECT_RATIO_SQUARE";
    if (std.ascii.eqlIgnoreCase(raw, "four-three") or std.mem.eql(u8, raw, "4:3")) return "IMAGE_ASPECT_RATIO_LANDSCAPE_FOUR_THREE";
    if (std.ascii.eqlIgnoreCase(raw, "three-four") or std.mem.eql(u8, raw, "3:4")) return "IMAGE_ASPECT_RATIO_PORTRAIT_THREE_FOUR";
    return null;
}

fn parseUpsampleSize(raw: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "4k")) return "UPSAMPLE_IMAGE_RESOLUTION_4K";
    if (std.ascii.eqlIgnoreCase(raw, "2k")) return "UPSAMPLE_IMAGE_RESOLUTION_2K";
    return null;
}

/// Generates ModelResponse JSON for model.static and model.for_auth
pub fn generateModelResponse(allocator: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"Provider\":\"gemini-web\",\"Models\":[");

    for (ALL_MODELS, 0..) |m, idx| {
        if (idx > 0) try list.appendSlice(allocator, ",");
        try list.appendSlice(allocator, "{\"ID\":\"");
        try types.jsonEscape(&list, allocator, m.id);
        try list.appendSlice(allocator, "\",\"Object\":\"model\",\"OwnedBy\":\"gemini-web\",\"DisplayName\":\"");
        try types.jsonEscape(&list, allocator, m.display_name);
        try list.appendSlice(allocator, "\",\"SupportedGenerationMethods\":[\"chat\",\"images\",\"generateContent\"],\"ContextLength\":8192,\"MaxCompletionTokens\":4096,\"UserDefined\":true}");
    }

    try list.appendSlice(allocator, "]}");

    return types.wrapOk(allocator, list.items);
}

test "models resolution" {
    const cfg = resolveModelConfig("gemini-3.0-pro-image-portrait-4k", null, null);
    try std.testing.expectEqual(ModelType.image, cfg.model_type);
    try std.testing.expectEqualStrings("GEM_PIX_2", cfg.upstream_model_name);
    try std.testing.expectEqualStrings("IMAGE_ASPECT_RATIO_PORTRAIT", cfg.aspect_ratio);

    const video_cfg = resolveModelConfig("veo_3_1_t2v_fast_portrait", null, null);
    try std.testing.expectEqual(ModelType.video, video_cfg.model_type);
    try std.testing.expectEqualStrings("VIDEO_ASPECT_RATIO_PORTRAIT", video_cfg.aspect_ratio);
}

test "generate model response" {
    const allocator = std.testing.allocator;
    const resp = try generateModelResponse(allocator);
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"gemini-3.0-pro-image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"veo_3_1_t2v\"") != null);
}
