# Design

## Context

断线检测现状：`ReconnectingHostLink`（`app/lib/transport/reconnecting_link.dart`）持有退避重连循环，断线只能被动发现——事件流 onDone/onError 或重试时 connector 抛错。半开连接（网络切换后旧 socket 不报错）最坏等 `maxDelay`（30s）才被重试发现。生命周期接线集中在 `lifecycle_host.dart`（已实现 `didChangeAppLifecycleState`，目前只用于通知抑制与电池引导）；`AppLink` 是 `ReconnectingHostLink` 的唯一宿主（`tokenInvalid` 一次性事件即在此层）。WS 层当前无任何心跳（`host_link.dart` 未设 `pingInterval`）。参考实现：`reference/dsh-Go-main/app/lib/remote/network_watch.dart` 与 `ssh_link.dart` 的 `kick()`（注意：dsh-Go 的 kick 会重置退避梯子，但它有 mux 层兜底，cc-go 没有等效层，不应照抄）。

## Goals / Non-Goals

- **Goals**：网络切换与回前台主动触发连接检查；退避等待可被 kick 提前打断；半开连接在秒级被发现；直连与 SSH 隧道模式统一适用；事件源与分派逻辑纯 Dart 可测。
- **Non-Goals**：SSH 隧道端口常驻（另一个 change）；SSH 连接级 keepalive/probe；探针方法/线协议改动；iOS 适配（项目仅 Android）。

## Decisions

- **D1 kick 事件源独立成纯 Dart 模块**（`app/lib/transport/network_kicks.dart`）：暴露可注入构造（connectivity 流 + resume 回调 → 广播 `Stream<void>`），合并两个信号源并承载去重规则：
  - 订阅后的首次 connectivity 回调只是初始状态，不发事件（`last == null` 跳过）；
  - 结果含 `none`（纯掉线）不发——半开判死由 D6 的 WS 心跳兜底；只有"回到在线或切换网络"（结果不含 `none`）才发；
  - 回前台信号由 `lifecycle_host` 既有的 `didChangeAppLifecycleState` 供给（见 D3），本模块不另起 `AppLifecycleListener`——生命周期入口保持单一。
  已知盲区（平台限制，如实记录）：`connectivity_plus` 只报告传输类型且自带去重，**Wi-Fi ↔ Wi-Fi 同类型切换不产生事件**，该场景由 D6 心跳兜底。去重靠"只对值得检查的时刻发事件 + 下游分派幂等"，不引入时间窗防抖。
- **D2 `ReconnectingHostLink.kick()` 三态分派**，只加速既有机制、不新增并行重连路径：
  - 退避等待中（判别式：`_backoffWait != null && !_backoffWait!.isCompleted`，对齐 `stop()` 的既有守卫写法；禁止以 `_retryTimer != null` 或裸 `state == connecting` 作判据）：complete `_backoffWait` 打断等待，**不重置 `_attempt`**——立即重试语义由打断达成，成功后循环既有逻辑本就归零；失败则梯子继续爬升，daemon 不可达期间连续 kick 不会把重试钉死在 1s；
  - **直连拨号上界超时（真机验收补充，2026-11-14）**：直连模式的 TCP 拨号无内建超时，双卡手机关 Wi-Fi 后切流量时，拨号打到局域网 IP 会 SYN 黑洞挂死分钟级——kick 到达只能锁存在挂死拨号后面，锁存的消费依赖拨号失败，等于失效。`AppLink` 直连 connector 统一走 `dialDirect`（`HostLink.connect` + `.timeout(8s)`；LAN 正常拨号亚秒级，8s 足够宽松；SSH 模式已有 `SshEndpoint.connectTimeout` 12s），拨号挂死窗口从分钟级收窄到 8s；
  - 已连接：一次带超时（5s）的廉价 RPC 探测。探针方法必须真实存在于 daemon（已核对该 change 评审结论）：用 `host.info`（`server.ts` 既有 handler，内存态）。**必须钉住被探测对象**：捕获发起探测的 link，失败/超时后在 `identical(_current, probedLink)` 闸下才 `close()`，防止误杀探测期间刚重连的新链路；`_probing` 标志防并发；探测失败路径不得 `await` 任何可让出事件循环的步骤后再 close；
  - 拨号中 / 探测中收到的 kick **锁存不丢弃**（`_kickPending` 标志）：退避等待被打断后、以及每轮 connector 失败进入下一轮前检查并消费——kick 是"值得检查的时刻"（电平语义），丢弃即永久丢失加速机会；
  - `stop()` 后的 kick 安全忽略（`_stopped` 显式守卫；rxdart `BehaviorSubject.value` 在 close 后返回旧值，不可依赖）。
- **D3 接线**：kick 流的订阅下沉到 `AppLink`（它持有 `ReconnectingHostLink`，与 `tokenInvalid` 同模式），lifecycle_host 不再直接消费 transport 信号；`resumed` 分支在 `lifecycle_host` 既有的 `didChangeAppLifecycleState` 里追加调用 `appLink.link.kick()`——UI 层只递事件、不建流。
- **D4 模式无关性**：kick 位于 `ReconnectingHostLink` 层，不感知 direct/ssh。SSH 模式下探测失败 `close()` 会连同隧道一起拆除（`_TunnelLink.close` 语义），随后全量重建——隧道端口常驻改造前这是必然行为，接受。
- **D5 新依赖 `connectivity_plus`**（^7.x）：Android 端 `ACCESS_NETWORK_STATE` 由插件 manifest 合并自带，无需改 `AndroidManifest.xml`；网络镜像 `README.md` 已有 pub.dev 镜像命令可安装。
- **D6 WS 心跳作为基线判死器（红队/脑暴共同命中，纳入本 change）**：`host_link.dart` 的 `WebSocket.connect` 启用内置 `pingInterval`（15s）——OS 定期发 ping 帧，连续无 pong 触发 socket 错误走既有重连循环。它兜住 kick 覆盖不了的两类场景：Wi-Fi ↔ Wi-Fi 同类型切换（无 connectivity 事件）与纯掉线后的半开连接；与 kick 互补（心跳管"判死"，kick 管"别等退避"）。daemon 侧不动（WS 服务端自动回 pong）。

## Risks / Trade-offs

- **探针误伤活连接**：弱网下 `host.info` 超时会误判半开 → 关闭重连；SSH 模式下探测与快照推送共享单通道，回前台恰逢大快照灌入时可能队头阻塞造成误杀，且存在"重连→更大快照→更易超时"的弱正反馈环。重连本身幂等（快照补齐），短期接受；根治依赖端口常驻 change（通道级恢复）。超时取 5s 宽松值。
- **connectivity 事件风暴**：部分 ROM 切换时连发多次回调 → 去重后下游最多多做几次幂等 kick，无实际影响。
- **Android 15+ dataSync 前台服务有 6h/24h 系统上限**：超时后前台服务被系统停掉，kick 流与连接一起失效——属既有保活机制的系统约束，本 change 不解决，真机验收记录现象即可。
- **`connectivity_plus` API 变动**：v7 的 `onConnectivityChanged` 返回 `List<ConnectivityResult>`，注入式设计把插件类型隔离在构造入口，测试与未来升级不受影响。

## Migration Plan

纯增量：新模块 + 新方法 + 一处接线 + `pingInterval` 一个参数，无存量行为变更；未引入 kick 前所有既有重连语义不变。

## Open Questions

- 无。
