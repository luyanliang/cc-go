# Design

## Context

现有四层架构 `server.ts → manager.ts → session.ts`，`protocol.ts` 定义全部线上类型。`SessionSummary` 已含 `cwd`，`session.create` 已接受可选 `cwd`——多项目缺的是"目录枚举 + 分组视图 + 安全边界"，不是数据模型改造。Claude Code 会话存储为 `~/.claude/projects/<cwd 编码为连字符>/<sessionId>.jsonl`（逐行 JSON，含 `user`/`assistant`/`system` 对话行与 `file-history-snapshot` 等内部行）。daemon 重启后 `ensureLive()` 用 `resume: claudeSessionId` 复活会话，但手机端条目历史从零开始（正是本变更要补的缺口之一）。参考实现：`reference/happy-main`（MIT）的 `sessionScanner` / `sessionProtocolMapper`。

## Goals / Non-Goals

**Goals:**

- 一套 JSONL→`Item` 映射器同时服务历史回放与（尾段）外部写入同步
- 手机端零新渲染逻辑：回放结果与现有快照同构
- 白名单边界明确：未注册目录不可创建/导入会话

**Non-Goals:**

- 聊天 UI 视觉升级（独立变更）
- "任意活跃会话发现/镜像"（只做已接管会话的同步，见 proposal）
- 转录文件写入/修改（cc-go 对其只读）
- 手机端文件系统浏览 RPC（不采用 Happy 的放开模式）

## Decisions

### D1：项目 = 注册表里的目录，不建实体（Happy 模式）

会话归属由其 `cwd` 决定，"项目"只是注册表中一个规范化目录路径。不建 Project 表、不加 sessionId→projectId 外键。
*备选*：显式项目实体（SeaWork/官方模式）。放弃理由：状态最少、与 Claude Code 自己的目录语义一致、手机端分组只是视图层的 `groupBy(cwd)`。

### D2：目录白名单，注册仅限已配对设备

- 注册表持久化在现有 `store.json`（新增 `projects: string[]`，存 `path.resolve` 后的规范路径）
- 注册途径：`--project <dir>` 启动参数；以及已认证连接的 `projects.register`（手机端"添加项目"用）
- 一切按目录操作（创建/发现/导入）必须 `path.resolve` 后与注册表**精确匹配**（防 `..` 与符号链接绕过；符号链接需 `realpath` 归一后再比对）
- 信任论证：配对 = 6 位码强信任（等价于 SSH 授权登录），已配对设备注册目录 ≈ 登录后 `cd`；但不提供任意路径浏览/列目录 RPC，公网暴露面仍限于注册过的目录
- *备选*：Happy 式全盘浏览 + 建目录审批往返。放弃理由：我们无人在 daemon 端审批，全盘浏览徒增暴露面

### D3：发现与回放按需扫描，不建索引、不常驻 watch

`sessions.discover` 每次 readdir + 逐文件读取首条用户消息（标题）与末行时间；`session.history` 打开文件流式逐行解析，从最新往旧分页（cursor = 行号）。个人服务器规模（每目录数十文件、单文件 ≤ 数 MB）下 O(扫描) 完全够；mtime 不变的文件结果可做内存缓存。
*备选*：常驻 file watcher 维护会话索引。放弃理由：为低频浏览引入常驻状态与竞态，不值。

### D4：单一映射器，输出复用 `Item` 模型

- 行类型白名单：`user`（字符串内容 → UserItem；`tool_result` 内容 → 配对进 ToolItem）、`assistant`（`text` 块 → AssistantItem；`tool_use` 块 → ToolItem 骨架）
- 跳过：`file-history-snapshot`、`change`、`queue-operation` 等 Claude 内部行，以及 `isMeta` / `isCompactSummary` 标记的行；v1 同时跳过 `thinking` 块与 sidechain 行（`isSidechain`，子代理）——现 `Item` 模型无对应呈现，留给后续 UI 变更
- `tool_use` 与 `tool_result` 按 `tool_use_id` 配对成完整 ToolItem（status: done/error）
- 回放条目 id 规则：`hist-<claudeSessionId>-<行uuid>`，稳定且与实时条目不冲突

### D5：导入 = 新建会话 + `resume` + 预填充回放条目

`session.import` 创建一个常规 cc-go 会话（`cwd` = 项目目录），首个 `query()` 带 `resume: claudeSessionId`；把 `session.history` 的条目直接作为该会话的初始 items（内存 + 持久化摘要），手机端快照即含完整历史。幂等：store 中已有同 `claudeSessionId` 的 imported 会话则直接返回。原 JSONL 文件不动。
*备选*：不预填充、沿用 ensureLive 的 notice 提示。放弃理由：正是本次要消除的体验。

### D6：外部写入同步只在已接管 live 会话上启用（可选尾段）

- 触发条件：会话为 live 且 `claudeSessionId` 已知；daemon 侧 3s 定时 stat 该 JSONL，文件增长则增量读取，**只处理以换行结束的完整行**
- 去重：行 uuid 天然去重（重复读跳过）；手机自发消息的回显沿用现有 90s echo-guard 思想（内容匹配环形缓冲，参照 Happy 的 5 分钟窗）
- Claude fork 换新文件：沿用现有 `trackClaudeSession` 的 id 追踪，tail 目标跟随切换

### D7：协议纯增量

新方法 `projects.list / projects.register / sessions.discover / session.history / session.import` 走现有 request/response 通道；`SessionSummary` 增加可选 `origin` 字段。Zod schema 全部在 `protocol.ts`，handler 用 `safeParse` 验参（沿用现行约定）。

## Risks / Trade-offs

- [JSONL 是 Claude Code 内部格式，无稳定性承诺] → 解析宽容（未知行类型跳过而非报错）+ 用固定样本文件做单测夹具 + 内部类型用黑名单而非白名单收窄
- [并发写文件读到半行] → 只处理完整行，尾部残行下次轮询补上
- [超大 JSONL 回放慢] → 流式解析 + 分页；标题/时间从首尾行提取而非全量解析
- [公网暴露面上多了"注册目录"入口] → 仅已配对设备可注册；路径规范化后精确匹配；注册不等于提供文件浏览
- [发现扫描与 Claude 写入竞争（正在跑的终端会话）] → 发现结果只做展示，正确性由回放时的宽容解析兜底

## Migration Plan

全部为新增方法与可选字段，旧客户端零影响。部署即用；回滚 = 停用新方法（不注册项目即回到现状）。`store.json` 读入旧文件时 `projects` 缺省为空数组，无需迁移。

## Open Questions

- 外部写入同步（D6）本期收尾还是顺延下个变更：任务表中标注为独立尾段，不阻塞其余验收。
- `thinking` / 子代理行的呈现方式：随聊天 UI 变更一并设计（届时扩展 Item 模型）。
