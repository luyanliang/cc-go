# Tasks

## 1. Daemon 转录服务

- [x] 1.1 `src/speech.ts`：provider 接口 + `openai` provider（OpenAI 兼容 `/audio/transcriptions`，音频 base64 → 文本）+ 启动参数解析（`--speech-provider/--speech-model/--speech-api-key-file/--speech-language`），未配置 → 空目录
- [x] 1.2 `src/protocol.ts`：`speech.catalog` / `speech.transcribe` zod schema（含 WAV 字节上限、错误码：`speech_not_configured` / `speech_audio_too_large` / `speech_provider_unavailable` / `speech_transcribe_failed`）与 server handler 校验
- [x] 1.3 `src/server.ts`：两帧 handler 接线（catalog 查询即时返回；transcribe 大小校验后调 provider，超时上限 30s）；单测覆盖（未配置/超限/成功/上游失败四路径）

## 2. App 原生语音插件

- [x] 2.1 `android/.../voice/WavRecorder.kt`：16kHz 单声道 PCM16 录制（maxSeconds 自动停、level 回调、stop 返回 WAV bytes），单测覆盖 WAV 头与静音判定
- [x] 2.2 `android/.../voice/VoiceDiagnostics.kt` + `VoicePolicy.kt`：环境 identity（SHA-256）、失败分类（非 6/7/9 记 unreliable）、失败快照（≤20 条、内容脱敏），单测覆盖分类与失效规则
- [x] 2.3 `android/.../voice/VoicePlugin.kt`：`cc_go/voice` + `cc_go/voice/events`（capabilities/requestPermission/openSettings/startRecognizer/startRecorder/stop/cancel；sessionId 匹配；level/partial/final/error/limit/end 事件），单测覆盖 capabilities 与错误映射
- [x] 2.4 `AndroidManifest.xml` 确认 `RECORD_AUDIO` 权限；`MainActivity.kt` 挂载插件

## 3. App Dart 侧桥接与控制器

- [x] 3.1 `lib/voice/voice_bridge.dart`：`VoiceBridge` 抽象 + MethodChannel 实现 + 事件解码（sealed VoiceEvent：level/partial/final/error/limit/end），单测覆盖解码与 sessionId 过滤
- [x] 3.2 `lib/voice/voice_controller.dart`：状态机移植（idle→starting→listening→transcribing；operation 防串台；降级语义；不可靠记忆消费；后台/切会话取消；锚点插入 + `_needsSpace` 中英拼接），纯逻辑单测覆盖全部 spec scenario（fake bridge）
- [x] 3.3 `host_link.dart`：`speechCatalog()` / `speechTranscribe()` RPC 封装
- [x] 3.4 移除 `speech_to_text` 依赖与 composer 旧听写代码路径

## 4. Composer 接入

- [x] 4.1 mic 键接 `VoiceInputController`（phase → 键位：mic/stopVoice/send；transcribing 态转圈）；onMessage → SnackBar 通道
- [x] 4.2 语音模式持久化（shared_preferences `voice.mode`：auto/system/engine）与设置入口（chat 菜单或 model_sheet 旁新增"语音输入"项：模式三选 + daemon 转录状态说明）
- [x] 4.3 widget 测试：空结果提示、错误码映射提示、降级提示、权限 blocked 提示 + 去设置入口

## 5. 验证

- [ ] 5.1 模拟器（GMS 可用）：系统引擎路径听写 → 文本落草稿 → 手动发送
- [ ] 5.2 荣耀真机（无 GMS）：daemon 配置 openai provider 后走引擎转录路径全链路；未配置时提示"需要在 daemon 侧配置转录服务"
- [x] 5.3 不可靠记忆：真机上系统引擎失败一次 → 二次启动不再尝试系统服务（日志/行为确认）
- [x] 5.4 按记录模板更新 `docs/VERIFICATION.md`，勾选本 change 真机项
