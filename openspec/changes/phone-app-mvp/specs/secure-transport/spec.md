# Spec Delta

## Purpose

daemon 面向公网的加密传输能力：自签证书生命周期、全端点 TLS、指纹公示，以及客户端首连记录指纹（TOFU）、变更即拒连的信任模型。

## ADDED Requirements

### Requirement: 首次启动自动生成自签证书
daemon 首次启动且本地不存在服务证书时，SHALL 自动生成一把自签证书并持久化到数据目录；后续启动 MUST 复用同一证书，不得每次更换。

#### Scenario: 首次启动生成
- **WHEN** daemon 在数据目录中找不到服务证书时启动
- **THEN** 生成新的自签证书并保存，后续连接均使用该证书

#### Scenario: 再次启动复用
- **WHEN** daemon 重启且数据目录中已有证书
- **THEN** daemon 使用既有证书，客户端已锁定的指纹保持有效

### Requirement: 全部端点默认走 TLS
daemon 的全部 HTTP 端点（health/info/pair）与 WebSocket 端点 SHALL 默认经由 TLS（https/wss）伺服；明文模式仅可通过显式开发旗标开启，且开启时 MUST 只监听回环地址。

#### Scenario: 默认 TLS 伺服
- **WHEN** daemon 以默认参数启动
- **THEN** 所有端点仅接受 TLS 连接，明文连接被拒绝

#### Scenario: 明文开发模式仅限本机
- **WHEN** daemon 以显式开发旗标启动明文模式
- **THEN** 监听地址为回环地址，外部主机无法连接

### Requirement: 启动时公示证书指纹
daemon 启动输出中 SHALL 打印服务证书的 SHA-256 指纹，格式与配对信息一致呈现，供用户在首次连接时人工核对。

#### Scenario: 指纹出现在启动输出
- **WHEN** daemon 完成启动
- **THEN** 控制台输出包含证书 SHA-256 指纹，与配对码/地址一同展示

### Requirement: 客户端 TOFU 指纹锁定
第一方客户端（手机 App 与冒烟客户端）SHALL 在首次 TLS 连接时记录服务证书指纹并持久化；此后每次连接 MUST 校验指纹，一致方继续，不一致 MUST 拒绝连接并给出明确的安全错误提示。客户端 SHALL 提供"忘记主机"操作以清除锁定的指纹并允许重新配对。

#### Scenario: 首次连接记录指纹
- **WHEN** 客户端首次连到一个未记录过指纹的主机
- **THEN** 连接被接受，指纹被持久化

#### Scenario: 指纹一致放行
- **WHEN** 后续连接的服务证书指纹与已记录值一致
- **THEN** 连接正常进行

#### Scenario: 指纹变更拒连
- **WHEN** 服务证书指纹与已记录值不一致（可能为中间人或服务器重装）
- **THEN** 客户端拒绝建立连接，展示安全错误，不得发送 token 或任何会话数据

#### Scenario: 忘记主机后可重连
- **WHEN** 用户执行"忘记主机"并重新配对
- **THEN** 旧的指纹记录被清除，新指纹在下次首次连接时记录
