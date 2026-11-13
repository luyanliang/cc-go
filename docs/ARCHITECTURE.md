# CC-Go 架构设计

> 手机 APP 远程连接控制电脑上的 Claude Code。
> UI 参考 dsh-Go（Flutter），Claude Code 控制技术参考 Happy Coder（happy-cli）。

## 总体架构

```
┌─────────────── 手机 APP（Flutter / Android 先行）───────────────┐
│  聊天式会话 UI · 会话列表/接管 · 权限卡片 · 输入(发送/打断/排队)      │
│  HostLink 传输抽象： direct(WS) │ ssh(隧道) │ …预留 relay         │
└──────────────┬────────────────────────────┬─────────────────────┘
               │ LAN: ws://ip:port + token   │ 外网: SSH 隧道(手机跑 SSH 客户端
               │ (扫码/配对码配对)             │  direct-tcpip 转发到本机端口)
               ▼                             ▼
┌────────────────────────── 电脑端 daemon（Node.js / TypeScript）──────────────────────────┐
│  WebSocket 服务 + 配对/会话鉴权                                                             │
│  会话管理器：  session.create / list / resume / watch(快照+实时流) / prompt / cancel         │
│  Claude 适配层： @anthropic-ai/claude-agent-sdk → 统一事件协议(SessionEnvelope 风格)         │
│  权限拦截：    canUseTool → 挂起 + 推送到手机 → permission.respond RPC → resolve            │
└──────────────────────────────────┬──────────────────────────────────────────────────────┘
                                   │ spawn + stream-json
                                   ▼
                          `claude` CLI（用户已装的 Claude Code）
```

## 设计决策（已确认）

| 决策点 | 选择 | 理由 |
|---|---|---|
| 电脑端技术栈 | Node.js/TypeScript | 直接用官方 `@anthropic-ai/claude-agent-sdk`，canUseTool/resume 开箱即用（Happy 验证过的路线） |
| 连接方式 | v1: 直连（LAN/公网，TLS）+ SSH 隧道（M4） | 不依赖自建中继服务器；传输层抽象（HostLink）预留 relay 扩展 |
| 公网传输安全 | daemon 全端点 TLS：自签证书（首启生成、`~/.cc-go/` 持久化）+ 客户端 TOFU 指纹锁定 | 公网明文不可接受；固定 IP 无域名、无法走 CA 签发；TOFU 与 SSH/dsh-Go（host key pinning）/Happy（E2E 密钥）同源信任模型；`--no-tls` 仅限本机回环调试 |
| 手机端 | Flutter，Android 先行 | 参考 dsh-Go 的 UI 实现与代码模式；本机 Linux 无法构建 iOS |
| 消息协议 | WebSocket + JSON（Zod 校验） | 借鉴 happy-wire 的 SessionEnvelope 事件模型，但无需 E2E 加密（直连/SSH 已有保障） |

## 关键技术方案（从参考项目提炼）

### 1. Claude Code 控制（参考 happy-cli）

- **SDK 驱动**：`@anthropic-ai/claude-agent-sdk` 的 `query()`，prompt 传 `PushableAsyncIterable` 支持连续多轮输入（见 happy `src/claude/claudeRemote.ts`）。
- **每轮选项**：`resume`（续接 Claude 原生会话）、`permissionMode`、`model`、`allowedTools`、`canUseTool`、`abort`。
- **消息转换**：SDKMessage → 统一事件协议（Happy 的 `sessionProtocolMapper` 思路）：
  - `text {text, thinking?}` — 助手文本/思考
  - `tool-call-start {call, name, title, args}` / `tool-call-end`
  - `turn-start` / `turn-end {status}`
  - `permission-request {id, tool, input, options}` — 权限确认
- **会话恢复三层**（Happy 模式简化版）：
  1. daemon 内会话状态（事件日志，seq 单调）
  2. Claude 原生 transcript（`~/.claude/projects/...`）+ SDK `resume`
  3. daemon 重启后从磁盘转录重建会话列表

### 2. 连接与配对

- **直连**：daemon 监听 `0.0.0.0:<port>`，首次连接手机扫二维码（`ccgo://pair?host=...&port=...&token=...`）或输配对码；配对成功换发设备 token，后续免配对。局域网可用 mDNS（`_ccgo._tcp`）自动发现。
- **SSH 隧道**（dsh-Go 模式）：daemon 只需监听 `127.0.0.1`；手机内嵌 SSH 客户端（dartssh2）连电脑 sshd，direct-tcpip 通道转发到本地端口。认证：密码/私钥；主机指纹 TOFU。出门在外用任意公网 SSH 跳板/内网穿透即可。
- **协议**：单一 WebSocket，JSON 帧：请求/响应（`{id, method, params}` / `{id, result|error}`）+ 事件推送（`{type: "event", event, payload}`）。

### 3. 会话接管（“电脑上跑着的，手机接着用”）

dsh-Go 的模式：手机零状态，状态全在 daemon。
- `session.list` 返回 daemon 管理的全部会话（含运行中）；
- `session.watch` 先回**全量快照**（历史事件窗口）再续播实时事件；按 `seq` 幂等合并；
- 手机发送支持三种模式：`send`（新轮次）/ `steer`（插话并入当前轮）/ `queue`（排队下一轮）+ `cancel`（打断）。

### 4. 权限确认

Happy 模式：`canUseTool` 回调挂起 Promise → 手机渲染权限卡片（工具名/参数/always-allow 选项）→ `permission.respond {id, behavior: allow|deny, updatedInput?, alwaysAllow?}` → resolve。

### 5. 手机 APP（参考 dsh-Go）

- **状态管理**：flutter_riverpod（`Notifier` + `autoDispose.family` 管每会话/每主机生命周期）。
- **UI**：
  - 聊天页：玻璃质感顶栏/输入条，Markdown（gpt_markdown）+ 代码高亮（re_highlight）；
  - 工具调用折叠为单行（32dp），点击展开详情；
  - 权限卡片内联在对话流中；
  - 会话抽屉（左缘手势）：会话列表/置顶/搜索 + 主机切换 chip；
  - **centered-anchor 列表**：解决流式输出 + 历史加载的滚动跳动（dsh-Go 教科书级实现，见 `app/lib/ui/chat/chat_list.dart`）。
- **主题**：亮/暗双色，层次靠材质（模糊+细线）不靠阴影，OKLCH 色彩。

## 目录规划

```
cc-go/
├── daemon/          # 电脑端（Node/TS）：cc-go daemon
│   ├── src/
│   │   ├── server/      # WS 服务、鉴权、配对
│   │   ├── agent/       # Agent SDK 包装：会话、权限、事件转换
│   │   ├── protocol/    # 消息 schema（Zod）与序列化
│   │   └── index.ts     # CLI 入口（cc-go / cc-go daemon）
│   └── package.json
├── app/             # 手机端（Flutter，Android 先行）
│   ├── lib/
│   │   ├── transport/   # HostLink: direct_ws / ssh_tunnel
│   │   ├── state/       # Riverpod providers
│   │   ├── ui/          # shell / chat / sessions / hosts / settings
│   │   └── theme/
│   └── pubspec.yaml
├── docs/
└── reference/       # 参考项目（只读）
```

## 里程碑

当前实施与验收状态以 [OpenSpec 任务清单](../openspec/changes/phone-app-mvp/tasks.md)为准。M1 和手机端主要交互已有实现；第 8 节后台保活、通知及第 9 节公网全链路仍需按[真机验收步骤](VERIFICATION.md)验证。下列里程碑描述的是规划范围，不代表全部已验收。

1. **M1 daemon MVP**：Agent SDK 包装（建会话/发消息/流式事件/权限/cancel）+ WS 协议 + 配对码；命令行测试客户端跑通全流程。
2. **M2 APP 骨架**：Flutter 工程 + 主机管理（扫码/配对）+ 会话列表 + 聊天 UI（Markdown/工具行/输入条）。
3. **M3 完整交互**：会话接管（快照+续播）、权限卡片、steer/queue、打断、通知。
4. **M4 SSH 隧道**：dartssh2 direct-tcpip 转发传输层；mDNS 发现；打磨与发布打包。
