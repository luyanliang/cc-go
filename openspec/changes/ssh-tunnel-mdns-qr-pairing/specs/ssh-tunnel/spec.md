# Spec Delta

## Purpose

App 经 SSH 服务器（direct-tcpip 通道）连接本机回环地址上的 daemon，使 daemon 无需暴露公网端口即可在外网使用。覆盖 SSH 认证、主机指纹 TOFU、隧道建立、WebSocket 复用与断线重连。

## ADDED Requirements

### Requirement: SSH 隧道建立
App SHALL 支持通过 SSH 服务器建立 direct-tcpip 通道，把 daemon 所在主机的回环地址端口转发到手机本地，并在隧道之上建立与直连模式等价的 TLS WebSocket 连接。SSH 认证 SHALL 支持密码与私钥两种方式；认证或隧道建立失败时 SHALL 给出可区分的错误（认证失败 / 无法连接 SSH 主机 / 端口转发失败）。

#### Scenario: 密码认证建隧道
- **WHEN** 用户配置 SSH 主机地址、端口、用户名与密码并连接
- **THEN** 隧道建立，App 在其上完成 TLS 连接与 `hello` 握手，进入会话列表

#### Scenario: 私钥认证建隧道
- **WHEN** 用户选择私钥认证并提供私钥（可含口令）
- **THEN** 隧道以该私钥认证建立，后续行为与密码方式一致

#### Scenario: SSH 认证失败
- **WHEN** SSH 服务器拒绝所提供的密码或私钥
- **THEN** App 显示认证失败错误，不建立连接，不将错误误报为网络不可达

#### Scenario: 端口转发失败
- **WHEN** SSH 连接成功但 daemon 未在目标回环端口监听
- **THEN** App 显示转发失败错误，与 SSH 认证错误可区分

### Requirement: SSH 主机指纹 TOFU
App SHALL 在首次连接某 SSH 主机时记录其主机公钥指纹（TOFU），后续连接 MUST 校验指纹一致；指纹变化时 SHALL 拒绝连接并明确提示主机身份可能已变化，仅当用户显式确认后 SHALL 更新已记录的指纹。

#### Scenario: 首次连接记录指纹
- **WHEN** App 首次连接某 SSH 主机
- **THEN** 记录该主机公钥指纹并完成连接

#### Scenario: 主机指纹变更拒连
- **WHEN** 已记录指纹的 SSH 主机返回了不同的主机公钥
- **THEN** App 拒绝连接并提示指纹变化，用户确认更新后方可再次连接

### Requirement: 隧道断线重连
SSH 隧道断开时，App SHALL 沿用既有连接状态展示与指数退避重连语义自动重建隧道；重连成功后 SHALL 重新完成 `hello` 握手与 `session.watch` 快照补齐，行为与直连模式断线重连一致。

#### Scenario: SSH 主机不可达自动重试
- **WHEN** 隧道使用期间 SSH 主机不可达
- **THEN** App 展示断线状态并按退避策略自动重试，恢复后无需人工干预回到可用状态

#### Scenario: 重连后转录补齐
- **WHEN** 隧道恢复且正在观看的会话有新增条目
- **THEN** 快照与实时流按条目 id 幂等合并，不重不漏

### Requirement: 隧道模式安全等价
SSH 隧道 MUST NOT 替代应用层安全：隧道之上仍 MUST 走 daemon 的 TLS 连接，且证书指纹 TOFU 校验 MUST 与直连模式完全一致。

#### Scenario: 隧道上证书指纹不匹配拒连
- **WHEN** 经隧道连到的 daemon 证书指纹与已记录的不一致
- **THEN** App 拒绝连接，报错方式与直连模式相同
