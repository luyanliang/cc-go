# Proposal

## Why

聊天输入框的语音听写在部分真机上静默失效：荣耀/华为等无 GMS 设备的系统识别引擎（`voice_recognition_service` 指向 Google Speech Services）录音后永远返回空结果且无错误码，用户"说完没后续"。当前实现只走系统 `SpeechRecognizer` 单路径，无降级、无诊断。dsh-Go 的语音方案（双引擎 + 自动降级 + 引擎健康记忆）已在同类设备验证可行，cc-go 具备同构的 daemon 通道，可完整移植。

## What Changes

- **App 新增原生语音插件**（`cc_go/voice` MethodChannel + `cc_go/voice/events` EventChannel）：
  - `capabilities` / `requestPermission` / `openSettings` / `startRecognizer` / `startRecorder` / `stop` / `cancel`
  - 系统引擎路径：`SpeechRecognizer` + partial 结果事件（level/partial/final/error/limit/end，sessionId 防串台）
  - 录音路径：16kHz 单声道 PCM16 WAV 录制（WavRecorder），`stop` 返回 WAV bytes
- **App 新增 `VoiceInputController`**（参照 dsh-Go 同名状态机）：`idle → starting → listening → transcribing`；听写文本按锚点插入草稿（中英文拼接空格规则）；会话/传输替换时取消进行中的听写
- **App 自动模式 + 降级**：语音模式三选（自动 / 仅系统 / 仅引擎转录）；自动模式下模型就绪优先引擎转录，否则系统服务；系统服务非 no-speech/权限类失败 → 本次会话一次性 fallback 到引擎转录
- **App 引擎健康诊断**：记录 `voice_recognition_service` 环境 identity（SHA-256），非 no-speech/权限类服务失败 → 持久化标记 `systemUnreliable`，自动模式跳过系统服务；服务版本更新后标记自动失效
- **Daemon 新增语音转录端点**：`/speech/catalog`（可用 provider 及准备状态）与 `/speech/transcribe`（WAV base64 → 文本），转录实现接 OpenAI 兼容转写 API 或本地 whisper（可配置，默认关闭=端点返回空 catalog）
- **Composer 接入**：mic 键 → 听写状态机；错误码全表映射为人话提示（不再静默）；"选择文字"等既有行为不变
- 现有 `speech_to_text` 依赖移除，由原生插件替代

## Capabilities

### New Capabilities

- `voice-dictation`: 端到端语音听写——App 侧双引擎听写（系统识别 / 录音上传 daemon 转录）与自动降级、健康诊断、错误呈现；Daemon 侧语音目录与转录端点

### Modified Capabilities

- `phone-client`: WebSocket 协议新增语音目录查询与转录请求/响应帧（`speech.catalog` / `speech.transcribe`）；无破坏性变更（增量消息类型）
