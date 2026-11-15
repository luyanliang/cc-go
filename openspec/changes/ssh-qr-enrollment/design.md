# Design

## Context

- 部署形态（2026-11-14 定案）：daemon 以 systemd 用户服务常驻、仅绑定 `127.0.0.1:8747`，手机经 SSH 隧道（22 端口仅密钥登录）接入；daemon 永不直接暴露公网——`/pair` 限速是**按 IP** 分窗（10 次/5 分钟），6 位静态配对码无法抵抗分布式穷举。
- **鸡生蛋约束**：daemon 在回环 → 手机首连 daemon 前必须先过 SSH → SSH 仅密钥 → 密钥必须在首次连接前到达手机。
- 既有模式可复用：LAN 启动横幅已输出 `ccgo://pair?host&port&code&fingerprint` 二维码，App 已有扫码解析与"二维码即 TOFU 锚点"的信任模型。
- 实测摩擦来源（2026-11-14 公网部署）：六步手工配置，且私钥经剪贴板搬运。
- 本设计经 4 维度多 Agent 评审 + 对抗验证修订（2026-11-14，详见 change 讨论）：D1 原密钥行经用户态 sshd **实证失效**（`restrict` 不禁命令执行、`permitopen` 不管 `-R`），已换用实测通过的加固行；独立子命令取码缺口、载荷前向兼容、QR 渲染宽度悬崖等发现已收入各决策与开放问号。

## Goals / Non-Goals

**Goals:**

- 首次配置收敛为：服务器跑一条注册命令 → 手机扫一次码（服务器侧另有打码前提示、扫后按回车清屏）。
- 密钥泄漏的爆炸半径由 authorized_keys 选项**结构性限定且经实测验证**：不能执行命令、不能 `-R` 反向转发、仅可 `-L` 转发到本机 daemon 端口。
- 信任模型与现有 LAN 配对完全同源：二维码通道即信任根，不引入新锚点。

**Non-Goals:**

- 不做 daemon 公网直连部署形态（已被 `/pair` 每 IP 限速的分布式穷举威胁分析否决）。
- 不修改 sshd 配置（authorized_keys 用户态写入即可，不需要 root）。
- 不引入密码认证、overlay VPN 或任何中继服务。
- 不改变 LAN 扫码配对（`ccgo://pair`）与手动表单的既有行为——注册码使用**独立 URI**，与 LAN 码互不干扰。

## Decisions

- **D1 受限专用密钥（加固行，实测验证）**：每台手机独立 ed25519 密钥，authorized_keys 行为：

  ```
  restrict,port-forwarding,permitopen="127.0.0.1:<daemonPort>",permitlisten="127.0.0.1:1",command="/bin/false" ssh-ed25519 AAAA… ccgo-phone-<fp8>-<date>
  ```

  实测（用户态 OpenSSH 9.6p1，2026-11-14 评审验证）：forced command 挡下 exec（无输出、exit 1）；`-R` 请求被拒（ExitOnForwardFailure 下 exit 255、无监听器）；`-L 8747` 隧道正常；dartssh2 `forwardLocal` 仅开 direct-tcpip 通道不开 session，不受 forced command 影响。
  注释含公钥指纹前 8 位（`fp8`），区分同日注册的多台手机；`--enroll-list` / `--enroll-revoke` 一律以公钥指纹为键（不按注释文本删行）。写入策略：单行 O_APPEND（< PIPE_BUF 原子），创建时确保 `~/.ssh` 700、`authorized_keys` 600 且属主为当前用户。

- **D2 密钥随二维码分发（正向，已定案）**：鸡生蛋约束排除"手机自生成密钥、经配对码注册公钥"的 daemon 协议路径。评审指出反向流程（手机本地生成密钥对、公钥一行文本回传给 `cc-go enroll --pub`，私钥不出手机）技术可行——**权衡后维持正向**：一次扫码的体验优先，私钥分发威胁面由 D1 加固行、指纹键吊销、可选过期补偿。反向流程记录为被否决的备选，不实现。

- **D3 双指纹随码预锁（取锚方式修正）**：`ssh-keyscan -t ed25519 -p <sshPort> <对外地址>`——只取 ed25519、对手机实际连接的目标取键（不假设 localhost 与对外地址是同一 sshd/同一把密钥）。注册命令因此新增 `--host`（对外地址，必填）与 `--ssh-port`（默认 22）参数。指纹格式锁定 `SHA256:<base64>`，与 dartssh2 上报逐字节同形（验收含首连对齐测试）。ssh-keyscan 不可用或无 ed25519 主机密钥时省略 `sshFp` 并终端提示，App 回退既有首连 TOFU 流程（与 D4 降级精神一致）。收益表述修正：现状首连本就是静默记录（无弹窗），本决策的真实收益是把锚点从"首连遇到的任意密钥"**前移**到二维码通道，防首连中间人。

- **D4 手动表单保留**：作为高级入口与降级路径，注册码解析失败不影响手动配对（沿用 `host-discovery` 的降级要求精神）。

- **D5 载荷契约**：
  - 注册码使用**独立 URI** `ccgo://enroll?...`（不复用 `ccgo://pair`）：旧 App 扫到会走既有"无效二维码"拒绝路径而不是误当 LAN 直连码；`host-discovery` spec 因此无需 delta，LAN 码字段语义完全不动。
  - 字段：`host`（对外地址）、`sshPort`（显式命名，消除与 LAN 码 `port`=daemon 端口的语义翻转歧义）、`user`、`daemonPort`、`code`（配对码）、`fingerprint`（daemon 证书）、`sshFp`、`key`（ed25519 种子）。
  - `key` / `sshFp` 一律 **base64url**（node 原生支持），杜绝 `+`/`=` 的百分号编码膨胀（评审实测标准 base64 最坏膨胀至 549 字符，超容量）。
  - QR 预算 **≤420 字符（v14-L）**，enroll 模块运行时断言：超预算告警并降级为纯文本输出材料。原"v15 内"上界废除（评审实测：v15 渲染宽度恰 80 字符，正卡标准终端自动换行边界，换行即毁码）。
  - App 端密钥重建：`OpenSSHEd25519KeyPair(publicKey, privateKey = seed||pub 共 64 字节, comment).toPem()` 落入 ssh_secrets 的 privateKeyPem 字段——dartssh2 2.22.5 已公开该构造器，无需手搓 openssh-key 格式；验收含"包装后 PEM 经现有 fromPem 往返解析并完成签名"单测。**原"QR 直接带整块 PEM"回退路径废除**（评审实测 80 列终端必断行毁码，兜底不成立）。

### 开放问号（spec/tasks 阶段定）

| 问号 | 候选 | 倾向 |
|---|---|---|
| **取码通道（评审新增，阻塞项）** | 配对码只存 daemon 进程内存（`index.ts` 生成、store 不落盘、`/info` 不吐）——独立子命令拿不到运行中的码。选项：配对码持久化进 store.json / daemon 自己打印注册码（与命令形态耦合）/ enroll 与 daemon IPC | 持久化最简；与命令形态联动定案 |
| 注册命令形态 | 独立子命令（`cc-go enroll`）vs daemon 参数（`--enroll-phone`） | 独立子命令：私钥不进常驻进程日志 |
| `permitopen` 严格度 | 锁死 daemonPort vs 只 `restrict,port-forwarding` | 锁死；改端口需重新注册（成本可接受） |
| 密钥过期 | `expiry-time`（Ubuntu 拼写；注意 vanilla 为 `expirytime`，未知选项会致整行拒载）默认 90 天 vs 不过期 | 默认 90 天，`--enroll-list` 展示钥匙年龄 |
| 清屏细节 | `clear`（现代 ncurses 默认输出含 `ESC[3J` 清 scrollback）+ 检测 tmux/screen 给残留警告；提示语在**展示二维码之前**打印 | 如左 |
| 扫后 UX 契约 | 隧道建立+配对的进行中状态屏；daemon 重启致码失效的失败文案与重试路径；成功后落地主机列表 | spec 阶段定文案 |
| 钥匙生命周期 App 侧反馈 | 注册命令 `--name <设备标签>` 写入注释；被吊销手机端提示"密钥可能已在服务器吊销，请重新注册"；App"忘记该主机"提示服务器侧钥匙需另行吊销 | 全部采纳进 spec |

## Risks / Trade-offs

- **私钥进二维码（D2 正向的固有代价）**：寿命与配对码不对称——配对码随 daemon 进程过期，密钥长期有效。靠 D1 加固行（泄漏仅可敲 daemon TLS 门，门后仍是 token + 限速配对）、指纹键吊销、可选 90 天过期补偿；截获注册码 = 获得与手机等价的接入能力，属已知权衡。
- **`/pair` 限速在隧道下塌缩（既有属性，评审指出）**：隧道模式下所有手机对 daemon 呈现 `127.0.0.1`，共享同一 10 次/5 分钟桶——泄漏密钥者可长期慢猜 6 位码，也可刻意耗尽配额令其他手机配对持续 429。本 change 仅记录该风险；缓解（限速键加设备维度 / 全局慢速桶 / 注册码内配对码一次性化）留 spec 阶段评估。
- **`permitopen` 锁死端口**：daemon 换端口后旧手机全部失联，需重新注册——接受，换取爆炸半径最小。
- **dartssh2 兼容性**：`OpenSSHEd25519KeyPair` 路径已读源码确认存在，但 64 字节 `seed||pub` 格式是易错点——以往返解析+签名单测兜底（验收项），不做 PEM 回退。
- **信任根单点**：注册码被第三方截获即获得等价接入——一次性输出 + 打码前提示、扫后清屏缓解。
