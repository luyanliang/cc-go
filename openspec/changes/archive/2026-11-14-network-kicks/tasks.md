# Tasks

## 1. kick 事件源模块

- [x] 1.1 `app/pubspec.yaml` 引入 `connectivity_plus`（^7.x），`flutter pub get` 成功且 `flutter analyze` 零告警
- [x] 1.2 新建 `app/lib/transport/network_kicks.dart`：可注入合并流（connectivity 流 + resume 回调 → 广播 `Stream<void>`），实现去重规则——首次回调不发、结果含 `none` 不发、其余发；单测覆盖三类输入（初始状态、纯掉线、恢复/切换）与回前台信号，`flutter test` 通过

## 2. ReconnectingHostLink.kick() 与 WS 心跳

- [x] 2.1 `host_link.dart` 的 `WebSocket.connect` 启用 `pingInterval: 15s`（D6 基线判死器）；`flutter analyze` 零告警，既有连接测试保持通过
- [x] 2.2 `reconnecting_link.dart` 新增 `kick()`：
  - 退避等待中（判别式 `_backoffWait != null && !_backoffWait!.isCompleted`）：打断等待立即重试，**不重置 `_attempt`**；单测覆盖连续 kick 打断下退避序列仍单调爬升至 `maxDelay`（防 1s 风暴）、退避自然到期后再 kick 不抛 `StateError`
  - 已连接：捕获被探测 link，5s 超时调用 `host.info`，失败/超时经 `identical(_current, probedLink)` 闸后 `close()`；`_probing` 防并发；单测覆盖：探测成功连接不动、探测失败触发重连、超时触发重连、并发 kick 只一个在途探针、探测期间旧链路自然断开且新链路已建时不误杀新链路
  - 拨号中/探测中的 kick 锁存（`_kickPending`），退避打断后与每轮失败进入下一轮前消费；单测覆盖拨号挂起期间到达的 kick 在拨号失败后立即触发下一次尝试
- [x] 2.3 边界：`stop()` 后的 kick 经 `_stopped` 守卫安全忽略；既有退避/重连/快照补齐测试全部保持通过
- [x] 2.4 （真机验收驱动的补充）直连拨号加上界超时（8s）：双卡手机关 Wi-Fi 后切流量，dialing 流量路径访问局域网 IP 会 SYN 黑洞挂死分钟级，堵死 kick 锁存的消费；`AppLink` 直连 connector 统一走 `dialDirect`（`HostLink.connect` + `.timeout(8s)`），单测用"接受连接但不回应握手"的本地 socket 验证 8s 内以 TimeoutException 收场

## 3. 接线与真机

- [x] 3.1 `AppLink` 订阅 kick 流 → `link.kick()`（与 `tokenInvalid` 同模式，UI 层不建流）；`lifecycle_host.dart` 的 `resumed` 分支追加 `appLink.link.kick()`；`flutter analyze` 零告警
- [x] 3.2 `bash scripts/check.sh` 全绿；真机验收：
  - Wi-Fi ↔ 流量切换后秒级恢复连接且转录无损；SSH 隧道模式重复
  - 回前台连接存活时用户无感知（直连 + SSH）
  - Wi-Fi ↔ Wi-Fi 同类型切换（无 connectivity 事件场景）：确认由 WS 心跳在秒级判死并恢复
