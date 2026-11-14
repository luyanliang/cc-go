# Proposal

## Why

手机端的会话列表目前是平铺的，新建会话固定落在 daemon 启动目录；而且只能看到 cc-go 自己创建的会话——daemon 重启后条目历史即清空，用户在终端里用 `claude` 积累的会话（`~/.claude/projects/<编码cwd>/*.jsonl`）对手机完全不可见。用户需要：按项目组织会话、浏览 Claude Code 的全部会话与历史、并在手机上继续这些对话。

## What Changes

- **daemon 引入项目目录注册表（白名单语义）**：通过配置与 `--project <dir>` 参数声明允许的项目目录；未注册目录不可创建/导入会话（公网暴露面可控，备选方案"放开文件系统浏览"不采用，理由见 design）。
- **协议新增方法**（全部为纯新增，向后兼容）：
  - `projects.list` — 枚举已注册项目目录（含每目录的会话计数）
  - `sessions.discover` — 扫描某项目目录对应的 `~/.claude/projects` 子目录，列出 Claude Code 会话（含终端创建的），返回元信息（id、mtime、首条用户消息摘要、消息数）
  - `session.history` — 按会话 id 回放 JSONL 为 item 列表（分页）
  - `session.import` — 把一个历史会话接管为 cc-go 会话（复用现有 `resume` 机制续聊）
- **SessionSummary 增加向后兼容字段**：`origin`（`created` | `imported`）与 `claudeSessionId` 的既有语义配合，支撑列表混合展示自有/导入会话。
- **单一 JSONL→item 映射器**：daemon 内一个模块同时服务"历史回放"与（尾段）"实时 tail"，输出复用现有 `Item` 模型，手机端零新渲染逻辑。
- **手机端**：会话列表按项目分组；新建会话时选择项目目录；历史会话只读浏览 + "接管续聊"入口。
- **已接管会话的终端并行写同步（c 档降级版）**：用户在终端 `claude --resume` 同一会话时，daemon tail 该 JSONL 并把外部新消息并入手机转录（3s 轮询、uuid 去重、内容环形缓冲防回显）——本变更的可选尾段，未完成不阻塞其余交付。
- **不在本变更**：聊天 UI 视觉升级（对齐 dsh-Go）拆为独立变更（AGPL 红线：只学模式不搬代码）。

## Capabilities

### New Capabilities

- `project-sessions`: daemon 侧项目目录注册表（白名单）与按目录创建/组织会话的能力，以及手机端按项目分组的会话列表。
- `session-history`: 发现任意来源的 Claude Code 会话（含终端创建）、只读回放历史、接管续聊，以及已接管会话的外部写入同步。

### Modified Capabilities

- `phone-client`: "会话列表"要求变更为按项目分组且包含可浏览的历史会话；"新建会话"要求变更为可选择项目目录创建。

## Impact

- **daemon**：`src/protocol.ts`（新方法 schema 与字段）、`src/server.ts`（新 handler）、`src/agent/manager.ts`（发现/导入编排）、新模块 `src/history.ts`（JSONL 扫描 + 映射器 + tail）、`src/store.ts`（项目注册表持久化）、`bin/cc-go.mjs`（`--project` 参数）。
- **app**：`lib/state/`（项目与发现状态）、`session_list_screen`（分组）、历史浏览 UI、`chat_controller`（回放快照来源接入）。
- **参考实现**：`reference/happy-main`（MIT）的 `sessionScanner` / `sessionProtocolMapper` 模式。
- **兼容性**：无破坏性变更；旧客户端忽略新方法与新字段。
