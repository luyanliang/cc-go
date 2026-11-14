# Tasks

## 1. daemon：mDNS 广播 + 二维码配对横幅（host-discovery）

- [x] 1.1 引入 `bonjour-service`，LAN 绑定模式广播 `_ccgo._tcp`（TXT 携带 `fp=<证书指纹>`），`--localhost`/`--no-tls` 不广播；验证：单元测试断言广播生命周期，`dns-sd -B _ccgo._tcp` 可见、`--localhost` 下不可见
- [x] 1.2 启动横幅用 `qrcode-terminal` 输出 `ccgo://pair?host=&port=&code=&fingerprint=` 二维码；验证：终端二维码解码后各字段与横幅文本及 `/info` 一致
- [x] 1.3 `CLAUDE.md` 运行说明补充广播与二维码行为；验证：按文档命令可复现

## 2. App：HostLink socket 接缝泛化（ssh-tunnel 前置）

- [x] 2.1 为直连路径补传输层回归测试（连接、hello、请求配对、事件流、TOFU 拒连）；验证：`flutter test` 全绿后才动接缝
- [x] 2.2 回环转发方案确认后回归验证直连路径零改动（见 design D1）：跑 2.1 测试与既有全量测试；验证：`flutter test` 全绿、`flutter analyze` 零告警，`host_link.dart` 无接缝改动

## 3. App：SSH 隧道传输层（ssh-tunnel）

- [x] 3.1 引入 `dartssh2`；扩展 secure storage：SSH 凭据（密码/私钥，口令不存）与 SSH 主机指纹按 `host:port` TOFU 持久化；验证：单元测试覆盖存取与隔离，凭据不出现在日志
- [x] 3.2 实现 `SshTunnelLink` connector：SSH 连接 → 本地 `ServerSocket` 回环转发桥接 `forwardLocal` direct-tcpip 通道 → `HostLink` 经 `wss://127.0.0.1:<临时端口>/ws` 走既有 TLS+TOFU 握手；验证：对子进程内 mock/本机 sshd 建隧道完成 hello，`ReconnectingHostLink` 无需改动即接入
- [x] 3.3 SSH 主机指纹 TOFU：首连记录、指纹变更拒连、用户显式确认后更新；验证：单测三场景，变更指纹时连接被拒且给出可理解错误
- [x] 3.4 认证/隧道错误分类：认证失败、无法连接 SSH 主机、端口转发失败三态可区分，不误报为网络不可达；验证：单测覆盖三类异常映射
- [x] 3.5 隧道断线重连集成：隧道断开走既有指数退避，恢复后 hello + watch 快照补齐；验证：单测模拟通道中断，恢复后事件流恢复且快照幂等合并

## 4. App：多主机凭据模型与主机管理 UI（ssh-tunnel / phone-client 交互）

- [x] 4.1 凭据模型从单主机改为主机列表（显示名/连接方式 direct|ssh/地址/端口/SSH 认证配置/两枚指纹），旧格式读取回填为默认主机；验证：单测覆盖迁移与新格式读写
- [x] 4.2 主机管理 UI：主机列表、新增/编辑（direct 与 SSH 两套表单）、SSH 指纹变更确认对话框；验证：真机可完成"添加 SSH 主机 → 连接 → 忘记主机"全流程

## 5. App：mDNS 发现与扫码配对 UI（host-discovery）

- [x] 5.1 引入 `bonsoir`，配对屏展示发现列表（名称/地址/指纹），点选自动填参，发现超时空态可手动输入；验证：单测覆盖解析与空态，真机局域网可见 daemon 条目
- [x] 5.2 引入 `mobile_scanner`：扫码入口解析 `ccgo://pair` 填表 + 一键提交，非配对码内容提示无效且不改表单；验证：解析器单测覆盖合法/非法载荷，真机扫码完成配对

## 6. 端到端验收与文档

- [x] 6.1 LAN 端到端：mDNS 发现 → 点选 → 扫码两种路径完成配对 → 聊天全流程；验证：全程无手动输入地址/端口/指纹
- [x] 6.2 SSH 真机演练：本机 sshd 隧道全流程；公网 SSH 跳板场景配对 → 发任务 → 权限应答 → 断网重连；锁屏期间隧道存活；验证：`docs/VERIFICATION.md` 新增步骤全部通过
- [x] 6.3 文档收尾：`docs/ARCHITECTURE.md` 决策表补 SSH/mDNS/扫码决策，`CLAUDE.md`/`docs/VERIFICATION.md` 与实现一致；验证：按文档从零构建出同样行为
