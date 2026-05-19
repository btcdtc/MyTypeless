# Typeforme

Typeforme 是一套跨 macOS 和 iOS 的语音输入系统。Mac Server 提供语音识别、文本整理和 Bridge API；Mac Client 负责本机录音和文本提交，并将音频交给 Mac Server 处理。iOS host app 与键盘扩展通过同一套 Bridge API 使用 Mac Server 的能力。

首次启动进入 Client mode。切换到 Server mode 后，可以启用 Bridge、本地语音识别和文本整理。

## 功能

- 语音识别：Qwen3-ASR GGUF 或 WhisperKit。
- 文本整理：本地 Qwen3.5 GGUF，或 LM Studio / OpenAI-compatible endpoint。
- 输出模式：Clean、Polish、Polish+、Structure+、Formal+。
- 输入提交：默认写入剪贴板并通过 Accessibility 触发 `Cmd+V`。
- 选区编辑：选中错误片段后录音修复，或用语音指令对选区/当前输入框内容做自由改写。
- iOS 键盘：Tap to speak、Hold to speak、选区修复、wand 指令编辑、模式切换。
- Bridge：Mac Server 提供 `/v1/dictate`、`/v1/restyle`、`/v1/edit-text`、`/v1/settings` 等 HTTP API。
- Pairing JSON：包含 token、启用的 LAN URL 候选和启用的 Public Bridge URL；语言、默认模式和模型状态由 iOS 通过 `/v1/settings` 拉取。

## 音频处理

- Mac 和 iOS 都录制临时 M4A/AAC 音频文件。
- iOS 和 Mac Client 将临时音频上传到 Mac Bridge；Mac Server 本机录音直接进入本机语音识别和文本整理流程。
- Bridge 使用 `multipart/form-data` 接收音频文件。
- Server 侧进入 ASR 前按 provider 需要转成 16k mono WAV。
- Debug mode 开启时，音频和处理结果会复制到 `DebugCaptures/`；正常处理流程使用临时文件，并在处理结束后清理。

## 系统要求

- macOS 14+，Apple Silicon。
- Xcode，用于构建 macOS app、iOS app 和 KeyboardShortcuts 资源。
- 麦克风权限。
- Accessibility 权限，用于提交整理后的文本。
- iOS 17+；键盘扩展需要开启 Full Access。
- Qwen3-ASR 和本地 Qwen3.5 需要内置 `llama-server` 及对应 GGUF 模型；Qwen3.5 4B / 9B 与 Qwen3-ASR 1.7B 建议使用 32GB 以上内存。

## 快速开始

使用 Qwen3-ASR GGUF 或本地 Qwen3.5 前，准备本地 llama.cpp 运行时。WhisperKit 与 LM Studio endpoint 不依赖内置 `llama-server`。

```sh
scripts/vendor-llama.sh <path-to-llama.cpp/build/bin>
```

构建 macOS app：

```sh
scripts/build-app.sh debug
scripts/build-app.sh release
IDENTITY="Developer ID Application: ..." scripts/build-app.sh release
```

运行 macOS 测试：

```sh
scripts/run-tests.sh
```

构建并安装 iOS app 和键盘扩展到已配对 iPhone：

```sh
scripts/deploy-ios.sh
```

也可以在 Xcode 中打开 `iOS/TypeformeIOS.xcodeproj` 构建。键盘扩展的真机验证建议使用 Release 构建。

## 配对 iOS

1. 在 Mac app 切到 Server 模式并打开 Bridge。
2. 需要局域网访问时打开 LAN access，并选择 `All adapters` 或具体 LAN adapter。
3. 需要公网、隧道、VPN 或反向代理访问时打开 Public Bridge URL，填入客户端实际访问的 URL。
4. 复制 Pairing JSON 到 iOS host app 并保存。
5. iOS 在 Wi-Fi 下优先探测可达的 LAN URL；LAN 不可达时使用 Public Bridge URL。网络变化后会重新探测。

## 运行时文件

`scripts/vendor-llama.sh` 将 `llama-server-arm64` 及相关动态库复制到 `vendor/`。`scripts/build-app.sh` 将这些文件打包到 `dist/Typeforme.app`，并在可用时签名内置 `llama-server`。

缺少 `vendor/llama-server-arm64` 时，相关本地 GGUF 功能会报告不可用。

设置存放在 `UserDefaults` 域 `com.btcdtc.typeforme.mac`。运行数据默认在：

```text
~/Library/Application Support/Typeforme/
```

主要子目录：

- `Models/`：Qwen3.5 correction 模型。
- `Models/WhisperKit/`：WhisperKit cache。
- `Models/Qwen3ASR/`：Qwen3-ASR GGUF 和 mmproj。
- `prompts/`：`system.md` 和 `mode-*.md` prompt override。
- `Bridge/`：临时上传音频。
- `ASRWork/`：ASR 前的临时转码音频。
- `DebugCaptures/`：debug mode 下保留的最近记录。
- `Logs/`：本地服务日志。

## 项目结构

```text
Sources/Typeforme/
  App/             macOS app lifecycle 和 DictationCoordinator
  ASR/             WhisperKit、Qwen3-ASR、音频转码
  Audio/           macOS M4A 录音
  Bridge/          本地 HTTP Bridge 和远端 Bridge client
  Hotkey/          快捷键和双击修饰键监听
  LLM/             文本整理后端、llama-server 管理、输出校验
  Memory/          AppSettings、AppPaths、模型下载、用户词典
  Models/          领域模型和 enum
  Prompts/         内置 prompt、prompt builder、override store
  TextCommit/      剪贴板提交和输入法处理
  UI/              Settings、HUD、菜单栏 UI
  Diagnostics/     Debug capture

iOS/
  TypeformeIOS.xcodeproj
  TypeformeIOS/       iOS host app
  TypeformeKeyboard/  自定义键盘扩展
  Shared/             host app 和键盘扩展共用模型

Tests/TypeformeTests/
Resources/
scripts/
vendor/
dist/
AGENTS.md          coding agent 项目规则
```

## 验证

基础验证：

```sh
scripts/run-tests.sh
```

iOS 或共享 Bridge 改动需要执行 iOS simulator build：

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project iOS/TypeformeIOS.xcodeproj \
  -scheme TypeformeIOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios-derived \
  build
```

Benchmark 脚本改动需要通过 Swift typecheck：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift -frontend -typecheck \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
  scripts/benchmark-correctors.swift
```

Bridge 和 iOS 键盘行为需要真机链路验证。

## Benchmark

Benchmark 环境：本机 Apple M4 Max 16-core / 64GB，远端 LM Studio 测试机为 RTX 5090。数据记录 warm path；首次下载、首次 Metal 编译和进程冷启动不计入。

ASR benchmark 使用 Bridge `/v1/dictate` 执行标准应用流程，音频样本来自本机 `DebugCaptures/*/audio.m4a`。表内 ASR latency 来自 Bridge response 的 `transcription_latency_ms`；`Median wall` 为脚本端到端耗时。运行期间，脚本将文本整理后端临时设置为 `qwen35_2b`，并将 `correction_timeout_ms` 设置为 `100`，结束后恢复原设置。

| ASR 模型 | Median ASR | P95 ASR | Median wall | Median RTF |
|---|---:|---:|---:|---:|
| WhisperKit large-v3_947MB (Whisper v3 full) | 4044 ms | 6976 ms | 4773 ms | 0.323 |
| Qwen3-ASR 1.7B BF16 | 738 ms | 1134 ms | 2139 ms | 0.062 |

ASR 表记录性能指标。

文本整理 benchmark 需要连接正在运行的 Typeforme Bridge。`scripts/benchmark-correctors.swift` 通过 `/v1/settings` 切换后端，并通过 `/v1/restyle`、`/v1/edit-text` 覆盖 app 内部的 settings、PromptBuilder、CorrectorFactory、validator、post-processor 和 Bridge response path。

| 文本整理后端 | Hardware | OK/Total | Median wall | P95 wall | Median app | P95 app |
|---|---|---:|---:|---:|---:|---:|
| Qwen3.5 2B Q4_K_M | Apple M4 Max 16-core / 64GB | 55/65 | 290 ms | 853 ms | 288 ms | 851 ms |
| Qwen3.5 4B Q4_K_M | Apple M4 Max 16-core / 64GB | 59/65 | 650 ms | 2121 ms | 648 ms | 2119 ms |
| Qwen3.5 9B Q4_K_M | Apple M4 Max 16-core / 64GB | 59/65 | 1084 ms | 3668 ms | 1082 ms | 3665 ms |
| LM Studio local qwen3.6-35b-a3b | Apple M4 Max 16-core / 64GB | 61/65 | 799 ms | 2480 ms | 797 ms | 2477 ms |
| LM Studio remote qwen3.6-27b-nvfp4 | RTX 5090 | 63/65 | 646 ms | 1403 ms | 644 ms | 1401 ms |

```sh
TYPEFORME_BRIDGE_URL="http://127.0.0.1:18081" \
TYPEFORME_BRIDGE_TOKEN="<bridge-token>" \
TYPEFORME_BENCHMARK_BACKENDS="qwen35_2b,qwen35_4b,qwen35_9b,lmstudio_local,lmstudio_remote" \
TYPEFORME_BENCHMARK_RUN_LABEL="mac-m4max-local-vs-5090-lmstudio" \
TYPEFORME_BENCHMARK_LOCAL_HARDWARE="Apple M4 Max 16-core / 64GB" \
TYPEFORME_BENCHMARK_LOCAL_LMSTUDIO_URL="http://127.0.0.1:1234/v1" \
TYPEFORME_BENCHMARK_LOCAL_LMSTUDIO_MODEL="qwen3.6-35b-a3b" \
TYPEFORME_BENCHMARK_REMOTE_HARDWARE="RTX 5090" \
TYPEFORME_BENCHMARK_REMOTE_LMSTUDIO_URL="http://<remote-lmstudio-host>:1234/v1" \
TYPEFORME_BENCHMARK_REMOTE_LMSTUDIO_MODEL="<remote-model-id>" \
TYPEFORME_BENCHMARK_TIMEOUT_MS=30000 \
TYPEFORME_BENCHMARK_HTTP_TIMEOUT_MS=60000 \
swift scripts/benchmark-correctors.swift
```

`TYPEFORME_BENCHMARK_TIMEOUT_MS`、`TYPEFORME_BENCHMARK_LOCAL_LMSTUDIO_*`、`TYPEFORME_BENCHMARK_REMOTE_LMSTUDIO_*` 会临时更新 Bridge server 的 correction timeout 和 LM Studio URL/model，脚本结束后通过 `/v1/settings` 恢复原设置。脚本输出 latency summary 和 per-sample JSONL。

## 隐私

- 使用本地模型时，Mac Server 在本机完成语音识别和文本整理。
- Mac Client 模式会将音频发送到配置的 Mac Bridge；配置 LM Studio 或 OpenAI-compatible endpoint 时，文本会发送到该 endpoint。
- 正常日志记录 provider、延迟、长度、hash 和错误，不包含正文。
- Debug mode 会保存原始音频、转写结果和整理结果，用于问题复现。
- Bridge token、prompt、词典和模型都在本机用户目录下。

## 已知限制

- iOS 键盘扩展必须开启 Full Access 才能和 host app / Mac Bridge 通讯。
- iOS 键盘扩展建议使用 Release 构建做真机测试。
- Qwen3.5 9B、Qwen3-ASR 1.7B BF16 占用较高内存和磁盘空间。
- 完整 iOS 构建需要 Xcode。
- ad-hoc 签名的内置 `llama-server` 首次运行可能被 Gatekeeper 拦截；正式分发应使用 Developer ID 签名。
