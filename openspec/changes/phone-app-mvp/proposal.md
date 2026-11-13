# Proposal

## Why

M1 daemon 已经协议完备（建会话/发消息/流式事件/权限/打断/配对），但只能用命令行冒烟客户端驱动——项目"手机远程控制电脑上的 Claude Code"的核心价值还没有任何真实用户界面。目标是一次做到**日常可用**（daily driver）：手机经公网直连固定 IP 服务器，口袋里收到权限通知、点开处理、继续跑任务，替代守在电脑前。公网直连意味着明文 WebSocket 出局，加密传输是本次变更的前置部分。

## What Changes

- **daemon 增加 TLS**：首次运行自动生成自签证书（存 `~/.cc-go/`），HTTP/WS 全部改走 `https`/`wss`；启动时打印证书 SHA-256 指纹。保留 `--no-tls` 仅供本机开发调试。
- **冒烟客户端支持 TOFU**：`test/smoke-client.mjs` 增加首连记指纹、后续校验的逻辑，公网照跑。
- **新增 Flutter Android App（`app/`，M2 骨架 + M3 核心交互的最简交集）**：
  - 配对屏：输入 IP/端口/6 位配对码 → token 与证书指纹持久化（secure storage）；
  - 会话列表：`session.list` + 新建，`sessions.changed` 驱动刷新，待权限会话优先提示；
  - 聊天页：4 种 item（user/assistant/tool/notice）渲染、流式更新、发送（queue 模式）、打断；
  - 权限卡片：内联在对话流中，allow/deny + "本次会话不再询问此类工具"；
  - 后台保活 + 本地通知：前台服务维持 WS 连接，`permission.request` → 高优先级通知，轮次结束（running→idle）→ 通知；点通知直达对应会话；
  - 断线自动重连：指数退避，重连后重新 `hello` + `session.watch` 补快照；
  - 产出可直接安装的 release APK。
- **明确不做（留待后续里程碑）**：相机扫码、mDNS 发现、SSH 隧道（M4）、steer 插话、附件上传 UI、多主机管理、markdown/代码高亮精修、主题系统、daemon 重启后的 transcript 回放、`session.configure` UI。

## Capabilities

### New Capabilities

- `secure-transport`: daemon 的公网加密传输——自签证书生命周期、https/wss 服务、指纹公示、客户端 TOFU 锁定与变更即拒连（fail-closed）。
- `phone-client`: 手机 App 的用户可见能力——配对与主机凭据持久化、会话列表、聊天转录渲染与输入、权限应答、release APK 交付。
- `phone-connectivity`: App 在后台维持可用连接的能力——前台服务保活、本地通知（权限请求/轮次结束）、断线重连与状态恢复。

### Modified Capabilities

（无——项目尚无既有 spec，本变更为首批能力。）

## Impact

- **daemon/**：`src/index.ts`（证书生成与 CLI 旗标）、`src/server.ts`（http→https、ws 挂载）、`package.json`（新增证书生成依赖）；`test/smoke-client.mjs`（TOFU）。
- **app/**（新建）：Flutter 工程——transport（HostLink Dart 客户端）、state（Riverpod）、ui（配对屏/会话列表/聊天页）、后台服务与通知插件。
- **工具链**：本机需安装 Flutter SDK + Android cmdline-tools + JDK17（当前未配置，含在任务内）。
- **协议**：`protocol.ts` 不变——本变更不动线上帧格式，只动传输层加密与端侧实现。
- **参考**：`reference/dsh-Go`（聊天页骨架 chat_screen/header/list/rows/composer、ssh_transport 的 TOFU 模式）、`reference/happy-main`（通知触发时机的事件模型）——只读，不修改。
