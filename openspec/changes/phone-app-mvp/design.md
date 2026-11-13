# Design

## Context

M1 daemon（`daemon/`）已实现完整线上协议（`protocol.ts`，Zod 校验的 WS JSON 帧）与配对/鉴权，但伺服为明文 HTTP/WS，且没有任何手机端实现。本变更同时触碰两端：daemon 加 TLS（见 specs/secure-transport）、新建 `app/` Flutter 工程（见 specs/phone-client、phone-connectivity）。约束：

- 服务器固定公网 IP、无域名 → 无法走 CA 签发，自签 + 客户端锁定是自然选择；
- 日常可用（daily driver）为验收标准 → 保活/通知/重连是必做，不是打磨项；
- 本机尚无 Flutter/Android 工具链 → 任务序列以环境搭建起步；
- 通知所需的服务端事件已齐备：`permission.request` 与 `sessions.changed` 均广播给全部已认证连接，daemon 仅需 TLS 改造，协议帧不动。
- 参考代码只读：`reference/dsh-Go/app/lib/ui/chat/`（聊天页四件套骨架）、`reference/dsh-Go/app/lib/remote/ssh/ssh_transport.dart`（TOFU 指纹确认的交互模式）。

## Goals / Non-Goals

**Goals:**

- 公网明文风险消除：全端点 TLS + 客户端 TOFU 锁定，信任模型与 dsh-Go/Happy 同源（首次指纹确认、变更 fail-closed）。
- 手机端最小闭环可用：配对 → 会话列表 → 聊天（发送/排队/打断）→ 权限应答 → 后台通知 → 断线重连。
- 每个任务阶段结束时都有可安装到真机的 APK 产物，便于持续验收。

**Non-Goals:**

- 不改线上协议帧格式（`protocol.ts` 不动）；不引入中继服务器、E2E 加密、多设备同步（Happy 路线）。
- 不做 SSH 隧道（M4，届时参考 dsh-Go `ssh_transport.dart`）、扫码、mDNS、steer、附件、多主机、主题精修。
- 不做服务端 transcript 回放——daemon 重启后手机端条目历史从提示条重新开始（Claude 上下文仍经 resume 存活）。

## Decisions

### D1. 证书生成：daemon 内置 `selfsigned`（node-forge）而非 shell 出 `openssl`

Node 原生 crypto 不能签发 X.509。两个选项：shell 出 `openssl req -x509 -newkey ec ...`（依赖系统二进制、错误处理丑）vs 纯 JS 的 `selfsigned` npm 包（跨平台、API 简单，daemon 当前依赖极简的风格也兼容）。选后者：`selfsigned` 5.x 支持 EC 密钥生成——密钥对 ECDSA P-256、CN=cc-go、10 年有效期（注意其 `generate()` 为异步、有效期经 `notAfterDate` 指定），落盘 `~/.cc-go/` 的 `tls-cert.pem` + `tls-key.pem`（0600），首次生成后复用。指纹为证书 DER 的 SHA-256，格式与 `openssl x509 -fingerprint -sha256` 一致（冒号分隔大写 hex），随启动横幅与配对码一并打印。

### D2. TLS 伺服：现有 `http.createServer` 换 `https.createServer`，`ws` 挂同一 server

`server.ts` 的端点结构（/health /info /pair /ws）不变，只换底层 server 对象与 URL scheme（`ws://`→`wss://`）。`--no-tls` 开发旗标：跳过证书加载、监听回环。冒烟客户端用 Node 的 `https`/`ws` 选项实现同一 TOFU：首连取对端证书指纹、打印并（非交互模式）与 `--fingerprint` 参数比对；不一致退出非零。

### D3. 手机端指纹校验：`badCertificateCallback` + 存储侧绑定

Dart `WebSocket.connect` 支持 `customClient`（`HttpClient.badCertificateCallback` 回调里拿 X509 证书，算 SHA-256 与已存指纹比对）。注意该回调无法 await——指纹读取需同步完成，因此**每主机只存一个指纹**，配对时写入。配对流程顺序：先 TLS 连接（此刻 TOFU 记录指纹）→ `/pair` 换 token → 两者一同落 secure storage。指纹不匹配时回调返回 false，连接失败，UI 呈现安全错误 + "忘记主机"入口。

### D4. App 架构：四件套骨架 + 三屏导航，状态管理 Riverpod

- `lib/transport/host_link.dart`：把 `smoke-client.mjs` 翻译成 Dart——WS 连接、递增 id 的 JSON-RPC、事件流广播（`Stream<DaemonEvent>`）、指数退避重连、`hello` 鉴权。TLS/TOFU 逻辑内聚于此，UI 不碰证书细节。
- 三屏：`PairScreen` → `SessionListScreen` → `ChatScreen`（`chat_header` / `chat_list` / `chat_rows` / `composer` 与 dsh-Go 同构，先 Material 默认样式）。
- Riverpod（架构文档既定）：每会话一个 controller（`autoDispose.family`），条目列表按 id 整体替换合并（协议已保证幂等），不引入更重的持久化层。

### D5. 保活与通知：前台服务 + flutter_local_notifications，事件驱动映射

- 前台服务（如 `flutter_foreground_task`）持有 `HostLink` 连接与常驻状态通知；App 进程存活即连接存活。
- 通知触发映射：`permission.request` → 高优先级通知（会话标题 + 工具名），点按 deep-link 到 `ChatScreen(sessionId)`；`sessions.changed` 后比对关注的会话 phase running→idle → "轮次结束"通知。仅后台时发（前台由 UI 直接呈现），通知渠道分开可独立静音。
- 重连后自动 `hello` → 对所有打开过的会话重新 `session.watch` 补快照（幂等合并保证无损）。

### D6. APK 交付：debug 签名 release 构建，暂不上应用商店

个人侧载场景：`flutter build apk --release` 以默认 debug keystore 签名即可安装（后续需要正式签名/分发时再引入 keystore 管理）。构建脚本落在 `app/`，任务中以"真机安装并完成配对"为验收。

### D7. 实现期发现的 daemon 缺口（属 bug 修复，不动协议）

手机端规格依赖的三个 M1 行为在实现期被证实缺失/有 bug，已在 daemon `session.ts` 修复（协议帧不变）：

1. **轮次自然结束后 phase 永远停在 running**：query 的 prompt 流（PushablePrompt）从不关闭，`for await` 永久等待下一条 prompt。修复：`result` 消息到达且队列无待办、无待权限时关闭 pushable，让 pump 回到 idle（5.x 徽标 / 6.3 手机侧队列的 idle 边沿 / 8.3 轮次结束通知都依赖它）。
2. **工具条目永不 done**：顶层 tool_result 随 `parent_tool_use_id == null` 的 user 消息到达，被 echo 分支静默丢弃。修复：handleUserEcho 先处理 tool_result 再走 echo 逻辑；`denied` 为终态，不被 is_error 改写。
3. **拒绝+勾选免问未被记住**：`allowedForSession` 只记允许。补 `deniedForSession` 对称集合，canUseTool 命中时自动拒绝（含条目兜底创建）。

## Risks / Trade-offs

- [国产 ROM 杀后台，前台服务也可能被杀] → 设置期引导电池优化豁免/自启动白名单（specs 已立要求）；通知点击在进程被杀后走冷启动路径，`HostLink` 需能从通知参数恢复会话定位。
- [TOFU 首连窗口可被主动 MITM] → 与 SSH 同级的风险接受；缓解：daemon 启动打印指纹供偏执用户人工核对，配对码走 TLS 之后的通道。M4 SSH 隧道天然消除此窗口。
- [dart:io `badCertificateCallback` 是同步回调，无法做异步指纹确认 UI] → 指纹在配对时一次锁定（D3），后续校验纯内存比对，不涉及异步。
- [daemon 重启后手机端条目历史清零] → MVP 接受：notice 提示 + Claude 上下文经 resume 存活；离线回放是后续里程碑。
- [`sessions.changed` 触发过频导致通知误报（非轮次结束的变更也触发）] → 客户端侧以 phase 边沿（running→idle）判定，不在服务端加新事件；若实践中不精确，再考虑 daemon 增加 `turn.completed` 广播（协议小改，向后兼容）。
- [Flutter/Android 工具链从零搭建] → 任务 1 独立成步，`flutter doctor` 全绿 + 空壳 APK 上机为验收，不让环境问题渗透进功能任务。

## Migration Plan

daemon 侧：TLS 为默认行为，属**对既有明文客户端的 BREAKING 变更**（仅影响冒烟客户端，同仓库同步改造，无外部用户）。`--no-tls` 保留本机调试路径。回滚 = git revert，无数据迁移（证书文件为新增产物，删除即回到首启状态）。

## Open Questions

- 前台服务与通知插件的具体选型（`flutter_foreground_task` vs `flutter_background_service` 等）——实现期以"能保活 WS + 常驻通知可更新"为准测标准，不影响本设计结构。
- "轮次结束"通知是否需要按会话粒度静音开关——打磨期决定。
