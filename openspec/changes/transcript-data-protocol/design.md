# Design

## Context

协议现状（勘察结论）：`SessionPromptParams.attachments` 是 schema 占位（daemon/app 均未用）；工具结果经 `summarizeToolContent(content, 400)`（history.ts:349）压成单行摘要；result 消息的 usage 与 `total_cost_usd` 在 `handleResult`（session.ts:684）被丢弃；模型只能经 `session.configure` 盲填字符串。SDK（@anthropic-ai/claude-agent-sdk 0.3.322）已具备所需控制面：

- `SDKUserMessage.message` 是 Messages API `MessageParam` —— content 可为块数组，含 image block（base64 source）。
- init 系统消息带 `model`、`slash_commands[]`、`terminal_slash_commands?`（SDK 注释明确：给手机/远程 UI 隐藏终端专属指令用的）。
- `Query.supportedModels(): Promise<ModelInfo[]>`、`Query.supportedCommands(): Promise<SlashCommand[]>`。
- result 消息带 `input_tokens/output_tokens/cache_creation_input_tokens/cache_read_input_tokens` 与 `total_cost_usd`（会话累计）。

Change A 的 app 端结构（derive 纯函数、工具视图注册表、按条目实例缓存）为本次升级预留了取数边界：工具视图只从 `input`/`summary` 取数，本次加字段不动推导层。

## Goals / Non-Goals

**Goals:**

- wire 协议补齐转录数据（附件、原始输出、用量）与控制面（模型目录、指令目录），全部增量可选字段，旧客户端无感。
- app 端把五个能力落到 UI：附件选择/预览/回显、完整工具输出（含 ANSI 基础着色）、成本/用量展示、模型选择、斜杠面板。
- 新 CLI 能力缺失时全部优雅降级（空目录/回退摘要/自由输入）。

**Non-Goals:**

- 语音听写、@提及、引用追问（另行规划）；文件类附件（仅图片）。
- ANSI 之外的结果渲染增强（diff 已有）；用量按轮拆分统计（先做会话级累计 + 最近上下文）。

## Decisions

### D1 附件：daemon 组装 image block，条目随附件下发

- daemon：`session.prompt` 处理时把 `attachments[]` 组装进 user 消息 content：`[{type:'text',text}, {type:'image', source:{type:'base64', media_type, data}}, …]`（替换现在的 `userMessage(text)` 纯文本助手调用）；echo-guard 仍按文本键。
- 协议：`UserItem` 增 `attachments?: [{name, mimeType, dataBase64}]`——快照/实时回显需要数据本体，daemon 已持有，直接随条目整体下发（与"条目整体替换"语义一致）。上限：单条消息 ≤4 张、单张压缩后 ≤1 MiB。
- app：`image_picker` 选图 + `image` 包缩放压缩（长边 ≤1568px、质量 0.8 起步，超限迭代降质）；composer 预览条（缩略图 + 移除）；气泡内缩略图、点开全屏查看。
- 持久化：会话 store 只存 summary（现状），附件数据不额外落盘；历史回放路径（history.ts）从 JSONL 的 user message content 还原 image block 为附件。

### D2 工具原始输出：结构化 result 字段，双端同源

- 协议：`ToolItem` 增 `resultText?: string`（保留换行，上限 20000 字符，超限截断并置 `resultTruncated?: true`）与 `resultImages?: [{mimeType, dataBase64}]`（≤2 张、单张 ≤1 MiB）；`summary` 保留（列表/副标题仍用它）。
- daemon 与 history.ts 回放共用同一提取函数（summarizeToolContent 旁新增 extractToolResult），保证实时与回放同源。
- app：Bash 视图升级完整输出 + 基础 ANSI SGR 着色（自研 ~百行纯函数：ANSI 转义 → TextSpan 样式，可单测；序列匹配锚定当前位置，未识别 ESC 按原文渲染不吞正文）；Read/Grep 原样渲染 resultText —— Claude Code 的 Read 结果自带 `cat -n` 风格行号，不自造第二层 gutter（评审修正）；沿用 Change A 的 Expando 缓存模式按条目实例缓存解析结果。旧数据无字段回退 summary。

### D3 用量：SessionSummary 增量携带

- daemon：`handleResult` 提取 `usage` 与 `total_cost_usd`，`SessionSummary` 增 `usage?: {inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, contextTokens, costUsd}`；`contextTokens = input + cache_read + cache_creation`（下轮重发量级）。无数据保持 undefined。
- app：聊天页头部状态行旁挂成本/用量 chip（复用现有 AppBar 副标题区），null 不渲染。

### D4 模型目录：manager 级缓存 + 懒探测

- daemon：任一 live session 的 init 消息更新 manager 的 `{models: ModelInfo[], current: string}` 缓存；新 RPC `host.models`：有缓存直接回；无缓存但有 live session → 调 `query.supportedModels()`；无 live session → 短命 probe query（创建即弃，复用现有 query 封装）取目录；CLI 不支持 → `{models: [], current: null}`。
- app：头部模型 chip（当前模型名）→ bottom sheet 列表选择或自由输入，经既有 `session.configure {model}` 生效。

### D5 指令目录：init 捕获 + 会话级 RPC

- daemon：init 的 `slash_commands` 减去 `terminal_slash_commands` 后随 manager 缓存；RPC `session.commands {sessionId}` 返回该会话目录（含 supportedCommands() 的描述，取不到时仅名称）。
- app：composer 文本以 `/` 开头（且在首个空格前）时显示面板：前缀过滤、点选补全；发送路径不变（指令就是 prompt 文本）。目录为空不弹面板。
- 刷新时机（评审修正）：打开会话拉一次 + 轮次结束（running→idle 边沿）重拉 + 重连后 provider 重建出新 controller 时按实例身份重拉 —— 冷启动/重连场景面板不会永久缺失。

### D6 7.10 重构：共享异步列表管道基类

`ProjectsNotifier`（103 行）与 `SessionsNotifier`（114 行）抽 `LinkScopedListNotifier<T>` 基类：连接状态订阅、断线值保留、`sessions.changed`/projects 事件的刷新与去抖统一；两个 Notifier 只留各自的 RPC 与分组逻辑。行为不变，以现有 widget/状态测试锁定。

## Risks / Trade-offs

- [附件经 WS 帧传输的体积与内存] → 压缩上限 1 MiB/张、4 张/条；base64 膨胀 ~33% 已计入；回显图片用 `Image.memory` + `memCacheWidth` 控内存。
- [store/快照随附件膨胀] → 附件不进 store（summary 本就不含 items）；快照下发即传即弃。
- [旧 CLI 能力探测不全导致降级路径各异] → 全部"空即降级"统一语义：模型空目录→自由输入、指令空→无面板、结果无字段→摘要回退。
- [probe query 冷启动成本] → 仅在无缓存且用户主动打开模型面板时触发一次。
- [ANSI 解析边界（畸形序列）] → 纯函数容错：未识别序列按原文渲染，不抛错，单测锁定。

## Migration Plan

协议全为可选字段：旧 app 连新 daemon 忽略新字段；新 app 连旧 daemon 走降级。无数据迁移。daemon/app 同仓库同发，回退即回滚版本。

## Open Questions

- 附件压缩参数（长边/质量起点）与 `resultText` 上限的具体数值 —— 实现时以真机流量实测微调，不影响结构。
- 模型目录是否需要 `accountInfo`（订阅/额度）信息 —— 暂不做，后续 change 再议。
