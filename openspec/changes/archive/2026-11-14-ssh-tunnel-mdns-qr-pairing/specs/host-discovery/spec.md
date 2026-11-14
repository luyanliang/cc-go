# Spec Delta

## Purpose

降低局域网与首次配对的输入成本：daemon 通过 mDNS 广播自身、启动横幅输出配对二维码，App 据此提供"点选发现主机"与"扫码配对"两条免手动输入路径；发现机制不可用时必须可降级为手动配对。

## ADDED Requirements

### Requirement: daemon mDNS 广播
daemon SHALL 在 LAN 绑定模式（默认）下通过 mDNS 以服务类型 `_ccgo._tcp` 广播实例名称、端口与证书指纹；`--localhost` 与 `--no-tls` 模式 MUST NOT 广播。广播 MUST 不影响 daemon 其余功能。

#### Scenario: LAN 启动可被发现
- **WHEN** daemon 以默认绑定启动
- **THEN** 同一局域网的 App 能发现该 daemon 的名称、地址、端口与证书指纹

#### Scenario: 回环模式不广播
- **WHEN** daemon 以 `--localhost` 启动
- **THEN** 不进行 mDNS 广播，App 发现列表中不出现该主机

### Requirement: App 发现主机列表
App 配对屏 SHALL 展示 mDNS 发现的 daemon 列表（名称、地址、指纹），点选某项 SHALL 自动填入地址、端口与指纹，用户只需补配对码即可提交配对；发现列表 MUST 随网络中主机的出现与消失自动更新。

#### Scenario: 点选发现项自动填参
- **WHEN** 用户在发现列表中点选一台 daemon
- **THEN** 配对表单自动填入地址、端口与证书指纹

#### Scenario: 主机上下线自动更新
- **WHEN** 网络中某 daemon 关闭或新 daemon 启动
- **THEN** 发现列表自动移除或新增对应条目

### Requirement: 扫码配对
daemon 启动横幅 SHALL 在配对码旁输出二维码，编码 `ccgo://pair?host=...&port=...&code=...&fingerprint=...`；App 配对屏 SHALL 提供扫码入口，扫描后自动填入全部参数并可一键提交配对。扫描内容不是有效配对二维码时 SHALL 提示无效且不改动表单；二维码中的配对码已失效时走既有"配对码错误"路径。

#### Scenario: 扫码自动填参并配对
- **WHEN** 用户扫描 daemon 启动横幅上的二维码
- **THEN** 地址、端口、配对码与指纹全部自动填入，一键提交后完成配对

#### Scenario: 无效二维码不误导表单
- **WHEN** 用户扫描的内容不是 `ccgo://pair` 二维码
- **THEN** App 提示二维码无效，表单保持原样

#### Scenario: 二维码中的配对码过期
- **WHEN** 提交扫码得到的配对码但 daemon 已更换配对码
- **THEN** 显示配对码错误，与手动输入错误码的行为一致

### Requirement: 发现不可用降级
mDNS 发现或扫码不可用时，App 的手动输入配对 MUST 不受影响；发现列表为空或扫码失败 SHALL 呈现为可忽略的空态/错误提示，不阻断手动配对流程。

#### Scenario: 无发现结果仍可手动配对
- **WHEN** mDNS 发现超时且列表为空
- **THEN** 配对屏保持手动输入表单可用，不因发现失败报阻塞性错误
