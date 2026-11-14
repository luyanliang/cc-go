# Design

## Context

App 侧传输层已有清晰的接缝：`HostLinkBase`（`app/lib/transport/host_link.dart`）定义 `events/call/close`，`ReconnectingHostLink`（`reconnecting_link.dart`）持有 `LinkConnector` 回调负责重连与重订阅；TLS TOFU 在 `tofu.dart`。daemon 已支持 `--localhost` 回环绑定（SSH 隧道模式，`daemon/src/index.ts`），协议层无需任何变更。凭据目前只支持单主机（`lib/state/credentials.dart`，secure storage）。见 proposal.md 的 Why。

## Goals / Non-Goals

**Goals:**
- SSH 隧道作为与直连平级的连接方式插入既有传输抽象，重连/快照补齐/断线横幅零改动复用
- SSH 主机指纹与 daemon 证书指纹两套 TOFU 互不替代、都生效
- 局域网内从"打开 App"到"完成配对"不超过两次点击（点选发现项 + 提交，或扫码）
- mDNS/扫码任一不可用时手动配对完全不受影响

**Non-Goals:**
- 不做 relay 中继传输（架构文档明确 v1 预留）
- 不做 iOS 端适配（Android 先行）
- 不做 SSH agent 转发、端口范围转发等高级 SSH 特性；只做 direct-tcpip 单通道
- daemon 侧不新增任何 RPC 方法或协议字段（mDNS/二维码只是"发现与配对的携带方式"）

## Decisions

### D1：SSH 隧道以独立 connector 实现，不动 RPC 层
`ReconnectingHostLink` 的 `LinkConnector` 是现成的接缝：新建 `SshTunnelLink` 对外仍是 `HostLinkBase`。实现采用**手机本机回环转发**：`ServerSocket.bind('127.0.0.1', 0)`（临时端口，无占用冲突）接受到的每个 dart:io `Socket` 桥接到一条 dartssh2 `forwardLocal` direct-tcpip 通道（`stream`/`sink` 对接），`HostLink` 照常 `WebSocket.connect('wss://127.0.0.1:<临时端口>/ws')`。
- 为什么不用"把 socket 接缝泛化为 WebSocketChannel"（初稿方案）：`dart:io` 的 TLS 握手与证书校验只能挂在 dart:io `Socket` 上，套不进任意 duplex stream；手写 WebSocket 帧协议代价过大且丢掉证书 TOFU。回环转发让既有 TLS + `tofu.dart` 证书校验栈原样复用，「隧道模式安全等价」requirement 免费满足，直连路径零改动。
- dsh-Go 参照：`ssh_transport.dart` 的 `forwardLocal` + `onVerifyHostKey`（`SHA256:<base64>` 主机指纹）即同构模式；其 `TunnelRefused`（`SSHChannelOpenError.code == 2`）用于区分"转发失败：daemon 没在监听"。

### D2：SSH 客户端用 dartssh2（纯 Dart）
架构文档既定选择；纯 Dart 实现免去 platform channel 与各厂商 SSH 库绑定。备选 jcraft（platform channel）被弃：维护成本与后台生命周期都更差。
- 算法以 dartssh2 默认支持为准（ed25519/rsa host key、密码与私钥认证）；不支持的算法报明确错误。

### D3：两套 TOFU，分开存储
SSH host key 指纹（keyed by `host:port`）与 daemon 证书指纹（keyed by daemon）分别持久化在 secure storage，互不复用、互不替代。SSH 隧道之上仍是 TLS + 证书 TOFU（见 spec「隧道模式安全等价」）。主机指纹变更走显式确认才能更新；daemon 证书沿用既有 3.2 的"忘记主机"语义。

### D4：多主机凭据模型
`credentials.dart` 从单主机对象扩展为主机列表（每项：显示名、连接方式 direct/ssh、地址、端口、SSH 用户名/认证方式/密码或私钥、两枚指纹）。读取旧格式时回填为列表中的唯一默认主机——单用户单设备场景不需要迁移向导。密码与私钥继续只进 secure storage，不进任何日志或非对称存储。

### D5：mDNS 广播与发现
- daemon：`bonjour-service` 广播 `_ccgo._tcp`，TXT 记录携带 `fp=<证书 SHA-256>` 与 `name=<主机名>`；仅 LAN 绑定模式广播，`--localhost`/`--no-tls` 不广播（spec 要求）。
- App：`bonsoir` 解析发现结果，指纹经 TXT 预填后 TLS TOFU 首连即静默通过。
- 备选 UDP 自定义广播被弃：非标准、跨网段不可用、与系统 zeroconf 服务冲突风险。
- 发现超时（约 5 s）呈空态，不阻塞手动表单。

### D6：二维码内容与输出
daemon 启动横幅在配对码旁用 `qrcode-terminal` 输出 `ccgo://pair?host=<主地址>&port=<端口>&code=<配对码>&fingerprint=<sha256>`；`host` 取 LAN 绑定的主地址（IPv4 优先）。App 用 `mobile_scanner` 扫码，解析成功填表 + 一键提交，非 `ccgo://pair` 内容提示无效。二维码含配对码，但配对码本就打印在同一横幅上，无新增暴露面；daemon 运行期配对码轮换/失效逻辑不变。

## Risks / Trade-offs

- [dartssh2 在部分 Android 机型/后台被冻结时隧道中断] → 前台服务保活已就位（第 8 节）；隧道重建纳入既有退避重连；真机验收项覆盖锁屏场景
- [mDNS 在组播被抑制的路由器上不可见] → spec 已要求空态降级，手动配对永不受阻
- [HostLink socket 接缝泛化引入直连回归] → 改动前先为直连路径补传输层测试，重构后全量跑
- [SSH 私钥误存到非对称存储] → 私钥/密码仅经既有 secure storage 通道写入；验收含"导出 app 数据不含明文凭据"检查
- [二维码被旁观者扫描] → 配对码短时效 + 配对成功即失效的既有语义不变；文档提醒公共场合使用 `--code` 自选码或注意横幅可见性

## Migration Plan

纯增量：daemon 新增 flag 无破坏（mDNS 默认开、`--localhost` 模式自然关闭）；App 凭据读取兼容旧格式自动回填。回滚 = 回退两端版本，凭据存储新格式对旧版 App 不可读——回滚前需先在旧版上重新配对（单用户场景可接受，记录于 VERIFICATION）。

## Open Questions

（无——算法支持范围、TXT 字段命名等实现细节不改变 spec 行为，实现期决定。）
