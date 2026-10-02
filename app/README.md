# FlTraeRelay

Trae Relay 的 **Flutter 完全重写版**：将上游 [sdn205/Trae-Relay](https://github.com/sdn205/Trae-Relay)（C++ / Win32 单 EXE）的全部后端能力用 Dart 重新实现，配上 Material 3 风格的桌面界面。

- **单进程自包含**：HTTP 服务器、Trae 账号发现与解密、上游代理、账号池全部内嵌在 Flutter 应用进程内，无外部后端、无 sidecar。
- **仅使用当前 Trae SOLO CN 客户端登录的账号**：其他发行版（Trae CN / Trae / Trae Work / 国际版）的账号不发现、不显示、不使用。

## 架构

```
┌───────────────────────────────────────────────┐
│           fltrae_relay.exe（单进程）           │
│                                               │
│  ┌─────────────┐   ┌──────────────────────┐   │
│  │ Material 3  │   │  RelayServer (:8317) │   │
│  │ 桌面前端     │──▶│  /health             │   │
│  │ · 运行总览  │   │  /v1/models          │   │
│  │ · 使用记录  │   │  /v1/status          │   │
│  │ · 偏好设置  │   │  /v1/chat/completions│   │
│  └─────────────┘   │  /v1/responses       │   │
│                    └──────────┬───────────┘   │
│  ┌────────────┐  ┌────────────▼───────────┐   │
│  │ config.json│  │ AccountPool（并发闸门 │   │
│  │ usage/*.jsonl│ │ 令牌刷新 积分 签到）  │   │
│  └────────────┘  └────────────┬───────────┘   │
│                    ┌──────────▼───────────┐   │
│                    │ Upstream (solo 通道)  │──▶ Trae 上游
│                    │ ModelCatalog         │   │ https://trae-api-cn.mchost.guru
│                    └──────────────────────┘   │
└───────────────────────────────────────────────┘
```

## Dart 侧核心模块（app/lib/core/）

| 模块 | 对应 C++ | 说明 |
| --- | --- | --- |
| `crypto_x.dart` | common/Crypto.cpp | sha512、AES-128-CBC（pointycastle）、UUID、快照增量 |
| `storage.dart` | accounts/Storage.cpp | tc 加密格式解密、storage.json 读取、设备 ID、安装目录探测（注册表 FFI） |
| `token_refresh.dart` | accounts/TokenRefresh.cpp | ExchangeToken 刷新 |
| `account_pool.dart` | accounts/AccountPool.cpp | 并发闸门、积分同步、使用记录、签到（含 9074 退避重试） |
| `upstream.dart` | upstream/Upstream*.cpp | solo 通道（/api/agent/v3/llm_utils_chat）、SSE 解析、思考档位/Max clamp |
| `model_catalog.dart` | upstream/ModelCatalog.cpp | get_detail_param 目录拉取（chat_v3 + solo_agent 合并） |
| `relay_server.dart` | api/Facade.cpp | HTTP 路由、鉴权、CORS、OpenAI 兼容 API（流式/非流式/工具调用/stop 过滤） |

与 C++ 版的行为对齐点：版本头动态探测 + 编译期兜底（3.3.102 / 20260916）、本地日界的今日用量统计、积分差值口径（补查前 − 补查后）、模型目录波动时的快速重试。

## 界面（四个页面）

- **运行总览**：服务控制（启动/停止/重启）、账号与积分（含"立即签到/刷新积分"——单进程后可直接调用，无需后端 API）、今日请求/Token/积分消耗、本地端点与密钥（复制/重新生成/任意 Key）
- **模型**：列表展示全部可用模型（含 Max/视觉/上下文窗口/倍率/默认档位），每个模型行内直接设置思考强度（默认/轻/高/极高）、Max 开关与启用状态，支持搜索过滤；设置写入 config.json 的 models 覆盖项
- **使用记录**：按日期浏览请求明细与汇总
- **偏好设置**：端口、局域网、并发、自动签到时间、Responses 缓存、日志级别；修改写入 config.json，"保存并重启后端"即时生效

## 构建

需要 Flutter 3.x（Windows 桌面支持）：

```powershell
cd app
flutter pub get
flutter run -d windows                        # 开发运行
flutter build windows --release --no-tree-shake-icons
# 或直接运行 tool\build.ps1（已带该参数）；产物在 build\windows\x64\runner\Release\
```

> 为什么禁用图标裁剪：Flutter 的 `--tree-shake-icons` 会误删部分 `selectedIcon` 字形（如 `Icons.memory`），导致侧边导航选中态图标显示为空白。

## 关于"单 exe"

Dart 重写后整个服务是**一个进程**（打开即用，无需安装 Python/Node/Docker）。Flutter Windows 的 Release 产物为 `fltrae_relay.exe` + `flutter_windows.dll` + `data\` 运行时文件——将整个 Release 目录打包分发即可；如需严格单文件，可用 Enigma Virtual Box 等打包工具把 dll 与 data 合并进 exe（不影响运行）。

首次启动会在 `%APPDATA%\FlTraeRelay` 生成 `config.json`（含自动生成的 API Key）、`accounts\` 账号私有快照与 `usage\` 使用记录。

## 兼容范围与差异（相对 C++ 版）

- ✅ Chat Completions（流式 SSE / 非流式、工具调用、reasoning_content、stop 本地截断、stream_options.include_usage）
- ✅ Responses：基础兼容（instructions、文本/多模态 input、流式 output_text.delta、usage）；`previous_response_id` 与自定义工具暂未实现
- ✅ 账号发现与 tc 解密、令牌刷新、积分实时同步、自动/手动签到
- ⚠️ Responses 会话缓存（previous_response_id）暂未实现
- 🚫 仅支持 TRAE SOLO CN 登录账号（按需求裁剪）
