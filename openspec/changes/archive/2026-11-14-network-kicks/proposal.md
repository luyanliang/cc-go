# Proposal

## Why

当前断线检测完全被动：WS 断开只能靠 TCP 层报错或退避循环自然到期。Wi-Fi ↔ 流量切换、App 回前台（Android 可能已冻结 socket）这两类场景下旧连接往往"半开"——不会主动报错，App 最坏要等 30 秒退避上限才发现连接已死；退避等待期间网络恢复也不会提前重试。借鉴 dsh-Go 的 network kicks 模式（`reference/dsh-Go-main/app/lib/remote/network_watch.dart` + `ssh_link.dart` 的 `kick()`），把"网络变了/回到前台"变成主动检查连接的时机。

## What Changes

- 新增统一 kick 事件流（transport 层纯 Dart 模块）：合并 `connectivity_plus` 网络切换事件与 App 回前台事件；带去重语义——订阅后的首次初始状态不触发、纯掉线事件不触发（半开判死由 WS 心跳兜底），只有"回到在线或切换网络"才发。
- `ReconnectingHostLink` 新增公开 `kick()` 方法，按当前状态分派：
  - 退避等待中 → 打断等待立即重试（不重置退避梯子，daemon 不可达期间不会形成 1s 级重试风暴）；
  - 已连接 → 用一次带超时的廉价 RPC（`host.info`）探测旧连接是否存活；失败则关闭当前链接触发既有重连循环；
  - 拨号中/探测中 → 锁存，稍后消费；停止后忽略。
- WebSocket 层启用内置心跳（`pingInterval` 15s）：兜住 connectivity 事件覆盖不了的半开场景（Wi-Fi ↔ Wi-Fi 同类型切换、纯掉线），与 kick 互补。
- 接线：kick 流订阅在 `AppLink`（与 `tokenInvalid` 同模式）；`lifecycle_host` 的 `resumed` 分支追加调用。直连与 SSH 隧道模式统一受益（kick 在 `ReconnectingHostLink` 层，与传输模式无关）。
- 新增依赖 `connectivity_plus`（Android 端，`ACCESS_NETWORK_STATE` 权限由插件自带）。
- daemon 与线协议零改动。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `phone-connectivity`：「断线自动重连」要求扩展——网络切换与回前台 SHALL 触发立即的连接检查/恢复，不再只依赖被动超时。

## Impact

- `app/pubspec.yaml`：新增 `connectivity_plus`。
- 新增 `app/lib/transport/network_kicks.dart`（事件源 + 去重，纯 Dart 可注入测试）。
- 修改 `app/lib/transport/reconnecting_link.dart`（`kick()` 三态分派、锁存、退避等待可被打断——机制已存在，翻成正门）。
- 修改 `app/lib/transport/host_link.dart`（`WebSocket.connect` 启用 `pingInterval`，单参数改动）。
- 修改 `app/lib/state/app_link.dart`（订阅 kick 流）与 `app/lib/ui/lifecycle_host.dart`（resumed 分派）。
- 不触碰 SSH 隧道、daemon。
