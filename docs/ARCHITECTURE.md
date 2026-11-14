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
| SSH 隧道实现 | dartssh2（纯 Dart）+ 手机本地 127.0.0.1 回环转发到 direct-tcpip 通道，`HostLink` 照常拨 `wss://127.0.0.1:<临时端口>` | dart:io 的 TLS/证书校验只能挂在 dart:io Socket 上，无法套任意 duplex stream；回环转发让既有 TLS + 证书 TOFU 栈零改动复用（dsh-Go `local_forward.dart` 同构模式） |
| SSH 信任模型 | SSH 主机指纹 TOFU（`SHA256:<base64>`，按 `host:port` 独立存储）与 daemon 证书 TOFU 并存 | 两层各防各的：SSH 层防主机替换，TLS 层防 daemon 替换；base64 大小写敏感，不能用 TLS 指纹的归一化逻辑 |
| 局域网发现与扫码 | daemon 侧 mDNS 广播 `_ccgo._tcp`（TXT 带指纹）+ 启动横幅二维码 `ccgo://pair?host=&port=&code=&fingerprint=`；App 侧 bonsoir 发现 + mobile_scanner 扫码 | 消除手动输入地址/端口/指纹；`--localhost`/`--no-tls` 不广播（回环/明文模式无发现意义）；发现不可用时空态降级，手动配对永不受阻 |
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

> 当前实现为最简可用版：状态管理（Riverpod `autoDispose.family`）、工具行折叠、权限卡片、断线重连已落地；Markdown/代码高亮、会话抽屉、centered-anchor 列表、主题系统等 UI 精修项按 proposal 明确推迟（见 M4）。

## 目录规划

```
cc-go/
├── daemon/          # 电脑端（Node/TS）：cc-go daemon
│   ├── src/
│   │   ├── server.ts    # https/wss 服务、鉴权、配对、事件路由
│   │   ├── agent/       # Agent SDK 包装：manager + session（会话、权限、事件转换）
│   │   ├── protocol.ts  # 消息 schema（Zod）
│   │   ├── store.ts     # ~/.cc-go/store.json（设备 token / 会话摘要）
│   │   ├── tls.ts       # 自签证书生命周期与指纹
│   │   └── index.ts     # CLI 入口
│   └── test/            # 单测 + smoke-client.mjs（含 TOFU）
├── app/             # 手机端（Flutter，Android）
│   ├── lib/
│   │   ├── transport/   # HostLink: host_link / reconnecting_link / tofu（纯 Dart）
│   │   ├── state/       # Riverpod providers、transcript 快照合并
│   │   ├── notify/      # 前台服务 + 本地通知 + NotificationPolicy
│   │   └── ui/          # pair / session_list / chat / lifecycle_host / debug_events
│   └── test/            # 每层对应 *_test.dart
├── docs/
├── openspec/
└── reference/       # 参考项目（只读）
```

## 里程碑

实施与验收状态以各变更的 [OpenSpec 任务清单](../openspec/changes/)（勾选即验收记录）与[真机验收步骤](VERIFICATION.md)为准；下列里程碑描述的是规划范围，不代表全部已验收。M1–M3 与 M4（SSH 隧道、mDNS 发现、扫码配对）已实现并经真机验收（2026-11-14）。

1. **M1 daemon MVP** ✅：Agent SDK 包装（建会话/发消息/流式事件/权限/cancel）+ WS 协议 + 配对码 + TLS/TOFU；命令行测试客户端跑通全流程。
2. **M2 APP 骨架** ✅：Flutter 工程 + 配对 + 会话列表 + 聊天 UI（工具行/输入条）。
3. **M3 完整交互** ✅（steer 插话留待后续）：会话接管（快照+续播）、权限卡片、queue、打断、后台保活与本地通知、断线重连；release APK 真机可用。
4. **M4 SSH 隧道** ✅：dartssh2 direct-tcpip 转发传输层、mDNS 发现、扫码配对、多主机凭据管理（真机验收通过，change 已归档）。
5. **多项目与会话历史**（代码已并入，待真机验收，见 `multi-project-history` 变更）：项目目录白名单、按项目分组、`~/.claude/projects` 会话发现/回放/接管、外部写入同步。
6. **后续**：聊天 UI 精修（Markdown/代码高亮，对齐 dsh-Go 视觉）、steer 插话、发布打包。
