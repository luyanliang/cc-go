# Proposal

## Why

当前 App 只能直连 daemon（局域网或公网暴露端口）。用户出门在外时要么把 daemon 暴露到公网，要么无法使用。M4 规划的 SSH 隧道让 daemon 只监听 `127.0.0.1`，手机经任意 SSH 跳板（公网服务器/内网穿透）即可安全使用；mDNS 发现与扫码配对则消除局域网内手动输入地址/端口/指纹的摩擦。这是 `docs/ARCHITECTURE.md` 里程碑 M4 的既定范围。

## What Changes

- **SSH 隧道传输层**：App 内嵌 SSH 客户端（dartssh2），通过 direct-tcpip 通道把 daemon 的回环端口转发到手机本地，WebSocket 跑在隧道之上；支持密码与私钥两种认证，SSH 主机指纹 TOFU 持久化；隧道断开后沿用现有 `ReconnectingHostLink` 退避重连。daemon 侧复用既有 `--localhost` 绑定模式。
- **mDNS 局域网发现**：daemon 以 `_ccgo._tcp` 广播自身（名称/端口/指纹）；App 在配对屏列出局域网内发现的 daemon，点选即填入地址与指纹。
- **扫码配对**：daemon 启动横幅在配对码旁输出二维码（`ccgo://pair?host=...&port=...&code=...&fingerprint=...`）；App 配对屏提供扫码入口，扫描后自动填参并提交配对。
- **主机管理 UI**：App 支持保存多台主机，每台可选择"直连"或"SSH 隧道"连接方式；SSH 主机可保存地址/端口/用户名/认证方式。

## Capabilities

### New Capabilities

- `ssh-tunnel`: App 经 SSH direct-tcpip 隧道连接 daemon 的传输能力——SSH 认证（密码/私钥）、主机指纹 TOFU、隧道建立与 WebSocket 复用、断线重连，以及与直连模式下等价的安全保障（TLS+证书 TOFU 仍然生效）。
- `host-discovery`: 局域网内的主机发现与快速配对——daemon 的 mDNS 广播与生命周期、App 的发现列表，以及扫码配对（二维码载荷格式、解析与错误处理）。

### Modified Capabilities

（无。注意：`phone-client` 等能力目前仍以 delta 形式存在于未归档的 phone-app-mvp 变更中，主 specs 尚未生成；为避免跨变更的归档顺序耦合，扫码/发现配对入口作为 `host-discovery` 的 ADDED Requirement 表达，不修改 `phone-client` 的既有 Requirement。配对成功后的凭据持久化行为不变。）

## Impact

- **App（Flutter）**：新增依赖 `dartssh2`（SSH 客户端）、`bonsoir`（mDNS）、`mobile_scanner`（二维码）；`lib/transport/` 新增 SSH 隧道 connector（实现 `HostLinkBase` 所需的 socket 注入点）；新增主机管理/SSH 凭据 UI 与安全存储扩展；`lib/state/credentials.dart` 需容纳连接方式与 SSH 凭据。
- **Daemon（Node.js）**：新增依赖 `bonjour-service`（mDNS 广播）与二维码终端输出（如 `qrcode-terminal`）；启动横幅增加二维码；`--localhost` 模式已有，无需协议变更。
- **风险**：dartssh2 在 Android 上的兼容性与后台保活的相互作用需真机验证；mDNS 在部分路由器的组播抑制下不可靠，发现失败必须不影响手动配对。
- **文档**：`docs/ARCHITECTURE.md`（M4 决策落表）、`CLAUDE.md`（运行说明）、`docs/VERIFICATION.md`（真机步骤）随实现更新。
