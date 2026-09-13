const std = @import("std");
const types = @import("types.zig");
const auth = @import("auth.zig");
const http_client = @import("http_client.zig");

pub fn handleManagementRegister(allocator: std.mem.Allocator) ![]u8 {
    const reg_json =
        \\{
        \\  "Routes": [
        \\    {
        \\      "Method": "POST",
        \\      "Path": "/plugins/gemini-web/auth"
        \\    },
        \\    {
        \\      "Method": "GET",
        \\      "Path": "/plugins/gemini-web/status"
        \\    }
        \\  ],
        \\  "Resources": [
        \\    {
        \\      "Path": "/auth",
        \\      "Menu": "Gemini Web",
        \\      "Description": "Import Gemini Web Cookie & Manage Authentication"
        \\    },
        \\    {
        \\      "Path": "/status",
        \\      "Menu": "Gemini Web Status",
        \\      "Description": "View Gemini Web Plugin Status & Model Catalog"
        \\    }
        \\  ]
        \\}
    ;
    return types.wrapOk(allocator, reg_json);
}

pub fn handleManagementHandle(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) {
        return types.wrapError(allocator, "invalid_request", "invalid management request");
    }

    const root = parsed.value.object;
    const method = if (root.get("Method")) |m| (if (m == .string) m.string else "GET") else "GET";
    const path = if (root.get("Path")) |p| (if (p == .string) p.string else "") else "";

    // 1. API: POST /plugins/gemini-web/auth
    if (std.ascii.eqlIgnoreCase(method, "POST") and std.mem.indexOf(u8, path, "/plugins/gemini-web/auth") != null) {
        return handleApiImportAuth(allocator, root);
    }

    // 2. API: GET /plugins/gemini-web/status
    if (std.ascii.eqlIgnoreCase(method, "GET") and std.mem.indexOf(u8, path, "/plugins/gemini-web/status") != null) {
        return handleApiStatus(allocator);
    }

    // 3. Resource Web UI page: GET /auth or /status
    return handleResourcePage(allocator);
}

fn handleApiImportAuth(allocator: std.mem.Allocator, req_obj: std.json.ObjectMap) ![]u8 {
    const body_val = req_obj.get("Body");
    var raw_body: ?[]u8 = null;
    defer if (raw_body) |rb| allocator.free(rb);

    if (body_val != null and body_val.? == .string and body_val.?.string.len > 0) {
        raw_body = types.base64Decode(allocator, body_val.?.string) catch null;
    }

    var cookie_text: ?[]const u8 = null;

    if (raw_body) |rb| {
        if (std.json.parseFromSlice(std.json.Value, allocator, rb, .{})) |parsed_body| {
            defer parsed_body.deinit();
            if (parsed_body.value == .object) {
                if (parsed_body.value.object.get("cookie")) |c| {
                    if (c == .string and c.string.len > 0) {
                        cookie_text = c.string;
                    }
                }
            }
        } else |_| {
            // Direct text body
            cookie_text = rb;
        }
    }

    if (cookie_text == null or cookie_text.?.len == 0) {
        return makeHttpResponse(allocator, 400, "{\"success\":false,\"error\":\"Cookie string is required\"}", "application/json");
    }

    const storage = auth.importAuthentication(allocator, cookie_text.?) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_json = try std.fmt.bufPrint(&err_buf, "{{\"success\":false,\"error\":\"Failed to import authentication: {s}\"}}", .{@errorName(err)});
        return makeHttpResponse(allocator, 400, err_json, "application/json");
    };
    defer {
        allocator.free(storage.st);
        allocator.free(storage.at);
        allocator.free(storage.at_expires);
        allocator.free(storage.email);
        allocator.free(storage.name);
        if (storage.project_id.len > 0) allocator.free(storage.project_id);
    }

    const auth_json = try auth.buildAuthDataJSON(allocator, storage);
    defer allocator.free(auth_json);

    const filename = if (storage.email.len > 0)
        try std.fmt.allocPrint(allocator, "gemini-web-{s}.json", .{storage.email})
    else
        try allocator.dupe(u8, "gemini-web.json");
    defer allocator.free(filename);

    _ = http_client.hostAuthSave(allocator, filename, auth_json) catch {};

    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(allocator);

    try resp_buf.appendSlice(allocator, "{\"success\":true,\"message\":\"Authentication imported successfully\",\"email\":\"");
    try types.jsonEscape(&resp_buf, allocator, storage.email);
    try resp_buf.appendSlice(allocator, "\",\"project_id\":\"");
    try types.jsonEscape(&resp_buf, allocator, storage.project_id);
    try resp_buf.appendSlice(allocator, "\",\"filename\":\"");
    try types.jsonEscape(&resp_buf, allocator, filename);
    try resp_buf.appendSlice(allocator, "\"}");

    return makeHttpResponse(allocator, 200, resp_buf.items, "application/json");
}

fn handleApiStatus(allocator: std.mem.Allocator) ![]u8 {
    const status_json =
        \\{
        \\  "ok": true,
        \\  "plugin": "gemini-web",
        \\  "version": "1.0.0",
        \\  "status": "ready",
        \\  "capabilities": ["image_generation", "video_generation", "auth_provider", "management_api", "cli_flags"],
        \\  "default_image_model": "gemini-3.0-pro-image",
        \\  "default_video_model": "veo_3_1_t2v"
        \\}
    ;
    return makeHttpResponse(allocator, 200, status_json, "application/json");
}

fn handleResourcePage(allocator: std.mem.Allocator) ![]u8 {
    const html =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\  <title>Gemini Web - CPA Plugin</title>
        \\  <style>
        \\    :root {
        \\      --bg: #0d1117;
        \\      --card-bg: #161b22;
        \\      --border: #30363d;
        \\      --text: #c9d1d9;
        \\      --text-heading: #f0f6fc;
        \\      --accent: #7c3aed;
        \\      --accent-hover: #9061f9;
        \\      --primary: #2563eb;
        \\      --primary-hover: #3b82f6;
        \\      --success: #10b981;
        \\      --error: #ef4444;
        \\      --code-bg: #090d13;
        \\    }
        \\    body {
        \\      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
        \\      background-color: var(--bg);
        \\      color: var(--text);
        \\      margin: 0;
        \\      padding: 24px;
        \\      line-height: 1.5;
        \\    }
        \\    .container {
        \\      max-width: 900px;
        \\      margin: 0 auto;
        \\    }
        \\    .header {
        \\      display: flex;
        \\      align-items: center;
        \\      justify-content: space-between;
        \\      margin-bottom: 24px;
        \\      padding-bottom: 16px;
        \\      border-bottom: 1px solid var(--border);
        \\    }
        \\    .title-group {
        \\      display: flex;
        \\      align-items: center;
        \\      gap: 12px;
        \\    }
        \\    .badge {
        \\      background: linear-gradient(135deg, #7c3aed, #2563eb);
        \\      color: #fff;
        \\      padding: 4px 10px;
        \\      border-radius: 9999px;
        \\      font-size: 12px;
        \\      font-weight: 600;
        \\    }
        \\    h1 {
        \\      color: var(--text-heading);
        \\      margin: 0;
        \\      font-size: 24px;
        \\    }
        \\    .card {
        \\      background: var(--card-bg);
        \\      border: 1px solid var(--border);
        \\      border-radius: 8px;
        \\      padding: 20px;
        \\      margin-bottom: 24px;
        \\      box-shadow: 0 4px 12px rgba(0,0,0,0.3);
        \\    }
        \\    .card h2 {
        \\      margin-top: 0;
        \\      margin-bottom: 12px;
        \\      color: var(--text-heading);
        \\      font-size: 18px;
        \\    }
        \\    label {
        \\      display: block;
        \\      font-weight: 600;
        \\      margin-bottom: 6px;
        \\      color: var(--text-heading);
        \\      font-size: 14px;
        \\    }
        \\    textarea, input[type="text"], input[type="password"] {
        \\      width: 100%;
        \\      box-sizing: border-box;
        \\      background: var(--code-bg);
        \\      border: 1px solid var(--border);
        \\      border-radius: 6px;
        \\      color: #e6edf3;
        \\      padding: 10px 12px;
        \\      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        \\      font-size: 13px;
        \\      margin-bottom: 14px;
        \\    }
        \\    textarea {
        \\      resize: vertical;
        \\      min-height: 110px;
        \\    }
        \\    textarea:focus, input:focus {
        \\      outline: none;
        \\      border-color: var(--accent);
        \\    }
        \\    .btn {
        \\      background: linear-gradient(135deg, var(--accent), var(--primary));
        \\      color: #fff;
        \\      border: none;
        \\      border-radius: 6px;
        \\      padding: 10px 20px;
        \\      font-size: 14px;
        \\      font-weight: 600;
        \\      cursor: pointer;
        \\      transition: opacity 0.2s;
        \\    }
        \\    .btn:hover {
        \\      opacity: 0.9;
        \\    }
        \\    .btn:disabled {
        \\      opacity: 0.5;
        \\      cursor: not-allowed;
        \\    }
        \\    .alert {
        \\      padding: 12px 16px;
        \\      border-radius: 6px;
        \\      margin-top: 14px;
        \\      display: none;
        \\      font-size: 14px;
        \\    }
        \\    .alert-success {
        \\      background: rgba(16, 185, 129, 0.15);
        \\      border: 1px solid var(--success);
        \\      color: #34d399;
        \\    }
        \\    .alert-error {
        \\      background: rgba(239, 68, 68, 0.15);
        \\      border: 1px solid var(--error);
        \\      color: #f87171;
        \\    }
        \\    pre {
        \\      background: var(--code-bg);
        \\      border: 1px solid var(--border);
        \\      border-radius: 6px;
        \\      padding: 12px;
        \\      overflow-x: auto;
        \\      font-size: 13px;
        \\      color: #7ee787;
        \\    }
        \\    .grid {
        \\      display: grid;
        \\      grid-template-columns: 1fr 1fr;
        \\      gap: 16px;
        \\    }
        \\    @media (max-width: 700px) {
        \\      .grid { grid-template-columns: 1fr; }
        \\    }
        \\    .tag {
        \\      display: inline-block;
        \\      background: #21262d;
        \\      color: #58a6ff;
        \\      padding: 2px 8px;
        \\      border-radius: 4px;
        \\      font-size: 12px;
        \\      margin: 2px;
        \\      font-family: monospace;
        \\    }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="container">
        \\    <div class="header">
        \\      <div class="title-group">
        \\        <h1>Gemini Web (Flow2CPA)</h1>
        \\        <span class="badge">Plugin v1.0.0</span>
        \\      </div>
        \\      <div><a href="/v0/management/plugins" style="color: #58a6ff; text-decoration: none; font-size: 14px;">Management Center &rarr;</a></div>
        \\    </div>
        \\
        \\    <div class="card">
        \\      <h2>Import Authentication Cookie</h2>
        \\      <p style="font-size: 14px; color: #8b949e; margin-top: -4px;">
        \\        Paste header-format cookie from <a href="https://labs.google/fx" target="_blank" style="color: #58a6ff;">labs.google/fx</a> or Google.
        \\        Supported formats: <code>Cookie: __Secure-next-auth.session-token=...</code> or Google cookies (<code>SID=...; HSID=...</code>).
        \\      </p>
        \\      <form id="authForm">
        \\        <label for="cookieInput">Header Format Cookie / Session Token</label>
        \\        <textarea id="cookieInput" placeholder="Cookie: __Secure-next-auth.session-token=eyJhbGciOi...; other=..." required></textarea>
        \\
        \\        <label for="keyInput">Management Key (optional, auto-loaded from localStorage)</label>
        \\        <input type="password" id="keyInput" placeholder="Management Bearer Key (if required)">
        \\
        \\        <button type="submit" id="submitBtn" class="btn">Import & Save Authentication</button>
        \\      </form>
        \\      <div id="alertBox" class="alert"></div>
        \\    </div>
        \\
        \\    <div class="grid">
        \\      <div class="card">
        \\        <h2>Supported Image Models</h2>
        \\        <p style="font-size: 13px; color: #8b949e;">Generate images via OpenAI chat/images or Gemini protocols:</p>
        \\        <div>
        \\          <span class="tag">gemini-3.0-pro-image</span>
        \\          <span class="tag">gemini-3.0-pro-image-landscape</span>
        \\          <span class="tag">gemini-3.0-pro-image-portrait</span>
        \\          <span class="tag">gemini-3.0-pro-image-square</span>
        \\          <span class="tag">gemini-3.0-pro-image-2k</span>
        \\          <span class="tag">gemini-3.0-pro-image-4k</span>
        \\          <span class="tag">gemini-3.1-flash-image</span>
        \\          <span class="tag">gemini-3.1-flash-image-2k</span>
        \\          <span class="tag">imagen-4.0-generate-preview</span>
        \\        </div>
        \\      </div>
        \\      <div class="card">
        \\        <h2>Supported Video Models</h2>
        \\        <p style="font-size: 13px; color: #8b949e;">Generate videos via Veo 3.1 text-to-video and image-to-video:</p>
        \\        <div>
        \\          <span class="tag">veo_3_1_t2v</span>
        \\          <span class="tag">veo_3_1_t2v_fast_landscape</span>
        \\          <span class="tag">veo_3_1_t2v_fast_portrait</span>
        \\          <span class="tag">veo_3_1_i2v_s_fast_fl</span>
        \\          <span class="tag">veo_3_1_i2v_s_fast_portrait_fl</span>
        \\        </div>
        \\      </div>
        \\    </div>
        \\
        \\    <div class="card">
        \\      <h2>Quick Start Example</h2>
        \\      <pre># OpenAI Chat Completions Image Generation
        \\curl http://localhost:8317/v1/chat/completions \
        \\  -H "Content-Type: application/json" \
        \\  -H "Authorization: Bearer your-cpa-key" \
        \\  -d '{
        \\    "model": "gemini-3.0-pro-image",
        \\    "messages": [{"role": "user", "content": "draw a cyberpunk neon city in rain"}]
        \\  }'</pre>
        \\    </div>
        \\  </div>
        \\
        \\  <script>
        \\    const savedKey = localStorage.getItem('management_key') || localStorage.getItem('cpa_management_key') || '';
        \\    if (savedKey) {
        \\      document.getElementById('keyInput').value = savedKey;
        \\    }
        \\
        \\    const form = document.getElementById('authForm');
        \\    const submitBtn = document.getElementById('submitBtn');
        \\    const alertBox = document.getElementById('alertBox');
        \\
        \\    form.addEventListener('submit', async (e) => {
        \\      e.preventDefault();
        \\      const cookie = document.getElementById('cookieInput').value.trim();
        \\      const key = document.getElementById('keyInput').value.trim();
        \\      if (key) {
        \\        localStorage.setItem('management_key', key);
        \\      }
        \\      if (!cookie) return;
        \\
        \\      submitBtn.disabled = true;
        \\      submitBtn.textContent = 'Importing...';
        \\      alertBox.style.display = 'none';
        \\
        \\      try {
        \\        const headers = { 'Content-Type': 'application/json' };
        \\        if (key) headers['Authorization'] = 'Bearer ' + key;
        \\
        \\        const res = await fetch('/v0/management/plugins/gemini-web/auth', {
        \\          method: 'POST',
        \\          headers: headers,
        \\          body: JSON.stringify({ cookie: cookie })
        \\        });
        \\        const data = await res.json();
        \\        if (res.ok && data.success) {
        \\          alertBox.className = 'alert alert-success';
        \\          alertBox.textContent = 'Success! Account ' + (data.email || '') + ' imported and saved to ' + (data.filename || 'auth file') + '. Ready to use!';
        \\          alertBox.style.display = 'block';
        \\          document.getElementById('cookieInput').value = '';
        \\        } else {
        \\          alertBox.className = 'alert alert-error';
        \\          alertBox.textContent = 'Error: ' + (data.error || res.statusText || 'Import failed');
        \\          alertBox.style.display = 'block';
        \\        }
        \\      } catch (err) {
        \\        alertBox.className = 'alert alert-error';
        \\        alertBox.textContent = 'Network or request error: ' + err.message;
        \\        alertBox.style.display = 'block';
        \\      } finally {
        \\        submitBtn.disabled = false;
        \\        submitBtn.textContent = 'Import & Save Authentication';
        \\      }
        \\    });
        \\  </script>
        \\</body>
        \\</html>
    ;
    return makeHttpResponse(allocator, 200, html, "text/html; charset=utf-8");
}

fn makeHttpResponse(allocator: std.mem.Allocator, status_code: i32, body_content: []const u8, content_type: []const u8) ![]u8 {
    const b64_body = try types.base64Encode(allocator, body_content);
    defer allocator.free(b64_body);

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"StatusCode\":{d},\"Headers\":{{\"content-type\":[\"{s}\"]}},\"Body\":\"{s}\"}}",
        .{ status_code, content_type, b64_body },
    );
    defer allocator.free(json);

    return types.wrapOk(allocator, json);
}

test "management register" {
    const allocator = std.testing.allocator;
    const resp = try handleManagementRegister(allocator);
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "/plugins/gemini-web/auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "/auth") != null);
}
