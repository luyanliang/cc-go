# Spec Delta

## ADDED Requirements

### Requirement: 语音目录与转录帧

WebSocket 会话协议 SHALL 新增两类请求/响应（沿用既有 `{id, method, params}` → `{id, ok, result|error}` 帧）：

- `speech.catalog`：返回转录服务目录——providers 列表（id/name/location/languages/准备状态/可用性）、当前选中 provider、语言、最大音频字节数与最大时长（秒）；daemon 未配置转录服务时 SHALL 返回空 providers 列表（`ok: true`），而非错误。
- `speech.transcribe`：接收单条 16kHz 单声道 PCM16 WAV 的 base64（上限取 catalog 声明的 maxAudioBytes）、可选 providerId 与语言；返回转录文本。超限、provider 不可用或转录服务失败 SHALL 返回结构化错误（带稳定错误码）。

新增帧 MUST NOT 影响既有消息类型；未配置转录服务的 daemon 对 `speech.transcribe` SHALL 返回可识别的"未配置"错误码。

#### Scenario: 未配置转录服务的 daemon
- **WHEN** 客户端发送 `speech.catalog`
- **THEN** daemon 返回 `ok: true` 且 providers 为空数组；`speech.transcribe` 返回"未配置"错误码

#### Scenario: 转录成功
- **WHEN** 客户端发送合法 WAV 的 `speech.transcribe`
- **THEN** daemon 调用所配置的转录服务（OpenAI 兼容转写 API 或本地 whisper）并返回非空文本

#### Scenario: 音频超限
- **WHEN** `speech.transcribe` 的音频超过 catalog 声明的字节上限
- **THEN** daemon 返回带稳定错误码的失败帧，MUST NOT 调用上游转录服务
