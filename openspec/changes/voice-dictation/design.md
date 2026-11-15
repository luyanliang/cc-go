# Design

## Context

现有语音听写（`app/lib/ui/chat/composer.dart` + `speech_to_text` 插件）只有系统 `SpeechRecognizer` 单路径：荣耀/华为等无 GMS 设备的系统引擎（`voice_recognition_service` → Google Speech Services）录音正常但永远返回空结果且无错误码，表现为静默失败。dsh-Go 的语音方案（`reference/dsh-Go-main/app/lib/ui/chat/voice/` 与 `app/android/.../voice/`）用"双引擎 + 自动降级 + 健康记忆"解决了同一问题，且其转录发生在 PC 端引擎——cc-go 天然有 daemon 通道可承载同构设计。本 change 是多端改动（App 原生插件 + Dart 控制器 + daemon 端点 + 协议帧），故立 design。

## Goals / Non-Goals

**Goals:**

- 在任何 ROM 上，语音入口要么产出文本、要么给出人话原因，MUST NOT 静默失败
- 无 GMS 设备通过"录音 → daemon 转录"路径可用
- 系统引擎不可靠的环境被记住，不重复尝试已知失败的服务
- 参照 dsh-Go 移植，保持其行为语义（状态机/降级/诊断），适配 cc-go 的通道与 provider

**Non-Goals:**

- 不接华为 HMS ML Kit / 荣耀 voiceengine 私有 API
- 不做流式（边说边转写）——引擎路径为整段录音转录；系统路径 partial 仅来自系统引擎自身
- 不做语音命令、TTS、多语言切换 UI（语言由 daemon 配置决定）
- 不改既有"识别文本落草稿、不自动发送"的交互契约（chat-ui-alignment 已定义）

## Decisions

### D1: 原生插件自写而非继续用 speech_to_text 插件

`speech_to_text` 只包了系统识别，且错误回调设计（initialize 级）导致我们第一版吞错。参照 dsh-Go `VoicePlugin.kt` 自写 `cc_go/voice` 双通道（MethodChannel + EventChannel），一次拿到系统识别 + WAV 录音两个能力与全部错误码。语音能力相关代码集中在 `app/android/.../voice/`（VoicePlugin、WavRecorder、VoiceDiagnostics、VoicePolicy 四文件，可基本平移，包名/渠道名替换）。

### D2: 转录服务放 daemon，协议加两帧

转录是"电脑侧资源"（与 dsh 引擎 SenseVoice 同位置），daemon 是唯一常驻通道。协议加 `speech.catalog` / `speech.transcribe` 两帧（`protocol.ts` zod schema + handler + 客户端 `host_link` 调用）。daemon 转录后端做成 provider 接口：`openai`（OpenAI 兼容 `/audio/transcriptions`，覆盖 Whisper API 及各兼容云）与 `whisper-cpp`（本地二进制，后置）；启动参数 `--speech-provider <openai> --speech-model <id> --speech-api-key-file <path>`，未配置时 catalog 返回空列表。**默认关闭**：不改变现有部署的安全面（音频不出机器）。

### D3: 自动模式决策与降级语义照搬 dsh-Go

启动顺序：权限确认 → 读模式 → 探测能力 → (自动且录音可用且模型就绪→先查 catalog) → 系统识别 / 引擎录音。系统服务失败分类（`VoicePolicy.serviceFailure`：非 6/7/9 即服务类失败）→ 本次操作内一次性 fallback 到引擎；no-speech/no-match/权限不降级（重试无意义或属用户可解）。环境 identity（SDK+build+服务包+版本+更新时间的 SHA-256）持久化标记 unreliable，版本更新自动失效——直接移植 `VoiceDiagnostics/VoicePolicy`。

### D4: 控制器状态机与草稿锚点插入照搬 dsh-Go

`VoiceInputController`（idle→starting→listening→transcribing；operation 计数防串台；sessionId 匹配事件）与 `_apply` 锚点插入（含 `_needsSpace` 中英拼接规则）按 dsh-Go 平移，适配点：输入控制器是普通 `TextEditingController`（无 mention provisional 概念，删除对应分支）；`onMessage` 接 composer 的 SnackBar 通道；模式选择暂存 shared_preferences（key `voice.mode`）。

### D5: 音量电平与 UI 状态

composer 听写中呈现：音量条（level 事件，沿用现有 LinearProgressIndicator）、"转写中"态（transcribing 阶段发送键位转 spinner）、错误 SnackBar。右侧键位状态机不变（mic ↔ stopVoice ↔ send）。

## Risks / Trade-offs

- **音频隐私**：引擎路径把语音发到 daemon 所在机器并可能转发到配置的云 API——默认关闭 + 文案明示，用户显式开启
- **传输带宽**：16kHz PCM16 约 32KB/s，10 秒 ≈ 320KB base64 ≈ 426KB，走 Wi-Fi/局域网可接受；SSH 隧道场景同样可用
- **catalog 探测频率**：参照 dsh 的去抖（同 client+generation 不重复探测；4s 超时），避免每次点 mic 都打 daemon
- **并行录音冲突**：全局单麦克风（dsh 的 MicArbiter 语义简化为"听写中禁止二次启动"，cc-go 无其他录音组件，暂不需完整仲裁器）
- **whisper-cpp 后置**：先交付 openai provider（多数用户可用兼容云），本地 whisper 作为独立后续任务
