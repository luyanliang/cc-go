# Proposal

## Why

Change A（chat-reading-experience）补齐了读的体验，但转录数据本身仍是"骨架"：工具结果只有 400 字单行摘要、用量/成本数据 daemon 收到即丢、附件字段是 schema 占位、模型只能盲填字符串、斜杠指令没有目录。协议层补上这些数据，手机端才能从"能看"走到"好用"。

## What Changes

- **附件链路**：打通 `session.prompt` 的 `attachments` 占位 —— daemon 把附件组装成 Messages API image block 随 prompt 送入 SDK；app 提供图片选择（相册/拍照）、发送前预览与缩放、转录内回显附件。
- **工具原始输出**：`ToolItem` 增加结构化结果（完整文本，含换行；bounded）与结果图片（bounded）；历史回放（history.ts）同步填充；app 工具行升级为完整输出视图（Bash 完整输出、ANSI 着色基础、Read 行号窗口）。
- **用量与成本**：daemon 从 result 消息提取 token 用量与 `total_cost_usd`，随会话摘要下发；app 在聊天页头部展示当前会话成本与上下文用量。
- **模型列表与切换**：daemon 经 SDK（init 消息 + `supportedModels()`）缓存可用模型目录并下发；app 聊天页提供模型选择（列表 + 自由输入回退）。
- **斜杠指令面板**：daemon 从 init 消息缓存 `slash_commands`（按 `terminal_slash_commands` 过滤终端专属指令）；app 输入区在 `/` 开头时弹出指令面板，选中作为 prompt 文本发送。
- **捎带重构（multi-project-history 7.10）**：抽取 `ProjectsNotifier` / `SessionsNotifier` 的共享连接管道基类，行为不变。

不改变：wire 的既有帧语义（item 按 id 整体替换、快照+实时幂等合并保持）；安全模型（TLS/TOFU/项目白名单不动）。

## Capabilities

### New Capabilities

- `session-attachments`: 图片附件端到端 —— 手机选择/预览/发送，daemon 组装 image block，转录回显。
- `transcript-detail`: 转录与会话数据细节 —— 工具原始输出（文本/图片）与用量成本展示。
- `session-models`: 模型目录下发与按会话切换。
- `session-slash-commands`: 斜杠指令目录下发与输入面板。

### Modified Capabilities

（无——四个能力均为新增边界；`phone-client` 既有需求不变。）

## Impact

- daemon：`protocol.ts`（ToolItem 扩展、新 RPC、summary 扩展）、`agent/session.ts`（附件组装、init/result 捕获）、`agent/manager.ts`（模型/指令目录缓存）、`history.ts`（回放填充原始输出）、`server.ts`（新端点）。
- app：`state/`（传输模型、chat_controller 附件发送）、`ui/chat/`（composer 附件与斜杠面板、头部用量与模型、工具行升级）、新依赖 `image_picker`（图片选择；许可证引入时核对）。
- 兼容性：新增字段全部可选 + 默认值，旧客户端忽略新字段不破坏；daemon 对旧 CLI（无 supportedModels）降级为空目录 + 自由输入。
- `reference/` 只读不触碰；借鉴 dsh-Go 结构思路、代码不拷贝（AGPL）。
