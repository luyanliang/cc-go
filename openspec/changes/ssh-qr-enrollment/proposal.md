# Proposal

## Why

SSH 隧道模式的首次配置要六步手工操作（服务器生成密钥 → 复制私钥 → 粘贴进 App → 填主机/端口/用户名 → 两次指纹确认 → 输配对码），与 LAN 模式"扫码即用"的体验差距悬殊——这是 SSH 隧道可用性的最大摩擦，也是 2026-11-14 公网真机部署时实测踩中的痛点；且手工流程诱导弱实践（私钥经剪贴板/聊天工具搬运、复用长期管理密钥）。

## What Changes

- daemon 新增手机注册命令（`--enroll-phone` 或独立子命令，design 定；参数含 `--host` 对外地址、`--ssh-port`、`--name` 设备标签）：生成**专用受限** ed25519 密钥——authorized_keys 行 `restrict,port-forwarding,permitopen="127.0.0.1:<daemonPort>",permitlisten="127.0.0.1:1",command="/bin/false"`（经用户态 sshd 实测验证：禁命令执行、禁 `-R` 反向转发、仅放行 `-L` 到 daemon 端口），以用户态追加进 `~/.ssh/authorized_keys`，并在终端打印注册二维码。
- 注册二维码使用**独立 URI** `ccgo://enroll`（不动 `ccgo://pair`，旧 App 扫到走既有"无效二维码"拒绝路径）：字段含 `host`、`sshPort`、`user`、`daemonPort`、`code`、`fingerprint`、`sshFp`（经 `ssh-keyscan -t ed25519` 获取，无需 root）、`key`（ed25519 私钥种子，base64url）；载荷预算 ≤420 字符（QR v14-L）并带运行时断言。
- App 扫注册码后**一键创建 SSH 主机条目并自动完成配对**：SSH 主机指纹与 daemon 证书指纹随码预锁——TOFU 锚点从"首连静默记录"**前移**到二维码通道（防首连中间人，非省弹窗）；既有手动表单保留为高级入口。
- 每台手机独立钥匙（注释含公钥指纹前 8 位 + 设备标签），daemon 提供列出/吊销（以公钥指纹为键），删一行 authorized_keys 即吊销；App 侧对被吊销/忘记主机给出对应提示文案。
- 不改变：既有协议帧、LAN 配对语义（`ccgo://pair` 二维码原样工作、`host-discovery` spec 无需变更）、daemon 仅回环监听的部署形态、sshd 仅密钥登录的加固状态。

## Capabilities

### New Capabilities

- `ssh-enrollment`: 把一台 SSH 隧道主机的全部连接材料（地址、端口、用户、daemon 端口、双指纹、受限密钥、配对码）经一张二维码安全交付给手机；覆盖 daemon 侧注册命令行为（受限密钥策略、二维码契约、钥匙生命周期管理）与 App 侧扫码建条目行为。

### Modified Capabilities

- `ssh-tunnel`: 「SSH 主机指纹 TOFU」的锚定来源扩展——二维码携带的 `sshFp` 成为与"首连记录"等价的合法锚点（fail-closed 语义不变：不匹配仍拒连）。

## Impact

- **daemon**：`bin/cc-go.mjs` 参数/子命令层新增注册入口；新增 enroll 模块（密钥生成、authorized_keys 受限行写入、`ssh-keyscan`、`ccgo://enroll` 二维码渲染）；配对码获取通道为开放问号（码在 daemon 进程内存，不落盘）；不动 `server.ts` 协议行为。
- **app**：`transport/pair_qr.dart` 新增 `ccgo://enroll` 载荷解析（与 LAN 码分流）；`state/host_entry.dart` 新增扫码建 SSH 条目路径；`ui/scan_pair_qr_screen.dart` 双码分流提示；`tofu.dart`/`ssh_host_key.dart` 支持预锁值写入；密钥经 `OpenSSHEd25519KeyPair` 重建后入 `ssh_secrets.dart`。
- **安全边界**：私钥进入二维码（信任根 = 二维码通道，与配对码同源；寿命不对称靠加固行+吊销+可选过期补偿）；authorized_keys 用户态写入不需 root；受限密钥行把泄漏爆炸半径限到"仅可敲 daemon 的 TLS 门"（实测验证）。
- **不影响**：`reference/`、`docs/ARCHITECTURE.md` 的 M1–M4 已验收行为。
