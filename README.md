# Flow2CPA - Gemini Web 图像/视频生成 CLIProxyAPI 插件

基于 **Zig** 编写的 [CLIProxyAPI (CPA)](https://github.com/router-for-me/CLIProxyAPI) 原生 C ABI 动态库插件。参考 [flow2api](https://github.com/TheSmallHanCat/flow2api) 的认证机制与上游接口协议，通过 `auth_provider`、`model_provider`、`executor`、`command_line_plugin` 和 `management_api` 等核心能力，为 CLIProxyAPI 提供 **Gemini Web / VideoFX (Veo 3.1)** 的文生图、图生图、文生视频、图生视频及 2K/4K 超分辨率放大等功能。

---

## ✨ 核心特性

- ⚡ **原生高效**：使用 Zig 编写并编译为轻量级原生共享库（`.dll` / `.so` / `.dylib`），无外部重量级运行依赖。
- 🔑 **多途径凭证导入**：
  - **CLI 参数**：在命令行启动 CPA 时使用 `--gemini-web-auth` 传入 Header 格式的 Cookie 自动完成初始化与持久化。
  - **Management 管理界面**：内置现代化 Web 管理页面（`/v0/resource/plugins/gemini-web/auth`），在浏览器中粘贴 Cookie 即可一键导入。
  - **Management API**：提供标准接口 `POST /v0/management/plugins/gemini-web/auth`。
- 🔄 **自动凭证生命周期**：
  - 支持直接提取 `__Secure-next-auth.session-token`。
  - 支持从 Google 账户 Cookies (`SID`, `HSID`, `SSID`, `APISID`, `SAPISID`) 协议登录生成 Session Token。
  - 自动通过 `https://labs.google/fx/api/auth/session` 将 Session Token (ST) 转换为 Access Token (AT)。
  - 自动通过 `trpc/project.createProject` 创建与激活 PINHOLE 专属项目。
  - AT 过期时由 CPA 宿主自动调度 `auth.refresh` 完成平滑刷新。
- 🎨 **丰富模型支持**：
  - **图像生成**：
    - `gemini-3.0-pro-image` (GEM_PIX_2)
    - `gemini-3.0-pro-image-landscape` (16:9)
    - `gemini-3.0-pro-image-portrait` (9:16)
    - `gemini-3.0-pro-image-square` (1:1)
    - `gemini-3.0-pro-image-four-three` (4:3)
    - `gemini-3.0-pro-image-three-four` (3:4)
    - `gemini-3.0-pro-image-2k` / `gemini-3.0-pro-image-4k` (超分放大)
    - `gemini-3.1-flash-image` (NARWHAL)
    - `gemini-3.1-flash-image-2k` / `gemini-3.1-flash-image-4k`
    - `imagen-4.0-generate-preview` (IMAGEN_3_5)
  - **视频生成**：
    - `veo_3_1_t2v` / `veo_3_1_t2v_fast_landscape` / `veo_3_1_t2v_fast_portrait`
    - `veo_3_1_i2v_s_fast_fl` / `veo_3_1_i2v_s_fast_portrait_fl` (图生视频)
- 🔌 **多协议输出兼容**：
  - **OpenAI Chat Completions**：`/v1/chat/completions` (返回 Markdown 格式图文或视频链接)
  - **OpenAI Images**：`/v1/images/generations` (返回标准 `{ "data": [{ "url": "..." }] }`)
  - **Gemini 原生协议**：`/v1beta/models/{model}:generateContent`

---

## 🛠️ 编译构建

### 1. 前置环境
- 安装 [Zig](https://ziglang.org/) (推荐 0.16.x)

### 2. 本地编译
```bash
# 进入项目目录
cd flow2cpa

# 编译当前平台动态库 (ReleaseFast 或 ReleaseSafe)
zig build -Doptimize=ReleaseFast

# 编译产物位于:
# Windows: zig-out/bin/gemini-web.dll
# Linux:   zig-out/lib/libgemini-web.so
# macOS:   zig-out/lib/libgemini-web.dylib
```

### 3. 运行单元测试
```bash
zig build test
```

### 4. 交叉编译 (可选)
```bash
# 交叉编译至 Linux x86_64
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast

# 交叉编译至 Linux aarch64
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast

# 交叉编译至 Windows x86_64
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

---

## 🚀 安装与配置

### 1. 部署插件文件
将编译生成的动态库放置在 CLIProxyAPI 的插件目录下：
- Windows: `plugins/windows/x86_64/gemini-web.dll` 或 `plugins/gemini-web.dll`
- Linux: `plugins/linux/x86_64/gemini-web.so` 或 `plugins/gemini-web.so`
- macOS: `plugins/darwin/arm64/gemini-web.dylib` 或 `plugins/gemini-web.dylib`

### 2. 在 CPA 的 `config.yaml` 中启用插件
```yaml
plugins:
  enabled: true
  dir: "plugins"
  configs:
    gemini-web:
      enabled: true
      priority: 1
      proxy_url: "" # 可选：代理地址，如 http://127.0.0.1:7890
```

---

## 🔑 凭证导入

你可以通过以下两种方式之一导入认证 Cookie：

### 方式一：命令行 CLI 参数导入
在启动 CPA 时，带上 `--gemini-web-auth` 参数传入你的 Cookie：

```bash
# 传入完整的 Header 格式 Cookie
./cli-proxy-api --gemini-web-auth "Cookie: __Secure-next-auth.session-token=eyJhbGciOi...; other=..."

# 或直接传入 session token
./cli-proxy-api --gemini-web-auth "eyJhbGciOi..."

# 或传入 Google 账户 Cookies
./cli-proxy-api --gemini-web-auth "SID=...; HSID=...; SSID=...; APISID=...; SAPISID=..."
```

插件会自动与 Google Labs 进行身份验证、换取 Access Token、创建项目并将凭据保存至 `gemini-web-<email>.json`，控制台将输出成功提示。

### 方式二：Management Web UI 导入
1. 启动 CLIProxyAPI。
2. 在浏览器中打开插件管理页面：
   ```
   http://localhost:8317/v0/resource/plugins/gemini-web/auth
   ```
3. 在页面中将 Cookie 粘贴进输入框，点击 **Import & Save Authentication**。
4. 插件将自动完成校验、激活并写入宿主凭据存储。

### 方式三：Management API
```bash
curl -X POST http://localhost:8317/v0/management/plugins/gemini-web/auth \
  -H "Authorization: Bearer <your-cpa-management-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "cookie": "Cookie: __Secure-next-auth.session-token=eyJhbGciOi..."
  }'
```

---

## 📡 API 调用示例

### 1. OpenAI Chat Completions 生图
```bash
curl http://localhost:8317/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-cpa-key" \
  -d '{
    "model": "gemini-3.0-pro-image",
    "messages": [
      {"role": "user", "content": "一只赛博朋克风格的荧光机械猫，霓虹灯街道背景"}
    ]
  }'
```

### 2. OpenAI Images 生图 (可指定比例与尺寸)
```bash
curl http://localhost:8317/v1/images/generations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-cpa-key" \
  -d '{
    "model": "gemini-3.0-pro-image-4k",
    "prompt": "雪山日出，丁达尔光效应，4K超高清细节",
    "size": "1920x1080"
  }'
```

### 3. Veo 3.1 视频生成
```bash
curl http://localhost:8317/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-cpa-key" \
  -d '{
    "model": "veo_3_1_t2v_fast_landscape",
    "messages": [
      {"role": "user", "content": "无人机俯拍航拍热带海岛，清澈见底的海水和微风拂过的棕榈树"}
    ]
  }'
```

---

## 📜 许可证

MIT License
