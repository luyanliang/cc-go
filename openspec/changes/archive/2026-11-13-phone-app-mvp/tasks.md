# Tasks

## 1. daemon TLS（secure-transport）

- [x] 1.1 引入 `selfsigned` 依赖，实现首启生成 ECDSA P-256 自签证书并落盘 `~/.cc-go/`（0600），重启复用；验证：删除证书文件后重启重新生成、不删则指纹不变
- [x] 1.2 `server.ts` 换 `https.createServer` 承载全部端点与 `ws`，新增 `--no-tls` 旗标（仅回环监听）；验证：`curl https://.../health` 通过、明文连接被拒、`--no-tls` 下冒烟全流程照跑
- [x] 1.3 启动横幅打印证书 SHA-256 指纹（与配对码同屏）；验证：指纹与 `openssl x509 -fingerprint -sha256` 输出一致
- [x] 1.4 冒烟客户端 `test/smoke-client.mjs` 增加 TOFU：首连记录并打印指纹，支持 `--fingerprint` 比对，不一致退出非零；验证：改证书后重跑退出非零，正常时全流程通过
- [x] 1.5 将 TLS 决策补进 `docs/ARCHITECTURE.md` 设计决策表与 `CLAUDE.md` 运行说明；验证：文档命令按原文可执行

## 2. Flutter 工具链与工程骨架

- [x] 2.1 安装 Flutter SDK + Android cmdline-tools + JDK17，`flutter doctor --android-licenses` 全绿；验证：`flutter doctor` 无阻断项
- [x] 2.2 `flutter create` 建立 `app/` 工程（org、Android min SDK），`flutter analyze` 通过；验证：仓库内 analyze 零告警
- [x] 2.3 构建 debug APK 并安装到真机；验证：手机上出现 cc-go 图标且能打开空壳页
- [x] 2.4 在 `CLAUDE.md` 补充 app 侧构建/运行命令；验证：按文档命令能复现 APK 构建

## 3. HostLink Dart 客户端（transport 层）

- [x] 3.1 实现 WS 连接 + JSON-RPC 请求/响应 + 事件流（翻译 `smoke-client.mjs` 为 `lib/transport/host_link.dart`）；验证：单元测试覆盖帧编解码与请求配对
- [x] 3.2 实现 TLS TOFU：`badCertificateCallback` 指纹比对、首连记录、不匹配拒连、忘记主机清除；验证：对 1.x 的 daemon 真机连通，篡改指纹的测试用例拒连
- [x] 3.3 实现指数退避重连与重连后自动 `hello` + 重订阅补快照；验证：杀 daemon 再启动，客户端自动恢复且转录补齐
- [x] 3.4 加"原始事件调试页"临时入口，展示收到的全部事件帧；验证：真机上可见配对/会话/权限事件实时滚动

## 4. 配对屏与凭据持久化

- [x] 4.1 配对屏 UI：地址/端口/配对码输入与提交、错误反馈（码错/网络不通）；验证：错误码与不通两种场景均给出可理解提示
- [x] 4.2 token + 指纹写入 secure storage，App 重启免配对直达会话列表；验证：杀进程重开不要求重新配对
- [x] 4.3 token 失效（daemon 重置/解绑）时引导重新配对；验证：删除 daemon 端设备记录后 App 收到引导而非死循环报错

## 5. 会话列表

- [x] 5.1 会话列表页：标题/工作目录/状态徽标/更新时间，`sessions.changed` 自动刷新；验证：电脑侧建会话，手机列表秒级出现
- [x] 5.2 新建会话（daemon defaultCwd）并导航进聊天页；验证：新建后列表更新且直接进入空转录
- [x] 5.3 待权限会话醒目呈现（置顶/金色徽标）；验证：制造一个待权限会话，列表呈现符合 specs 场景

## 6. 聊天页

- [x] 6.1 聊天页骨架（header/list/rows/composer 四件套）+ 快照加载与实时流合并（按条目 id 整体替换）；验证：反复进出会话转录不重不漏
- [x] 6.2 四种条目渲染：用户气泡、助手流式文本、工具折叠行（点按展开输入/结果）、notice 提示条；验证：跑一次含工具调用的轮次，四类条目齐全且流式可见
- [x] 6.3 发送与排队：空闲发送开新轮、运行中发送显示排队；验证：运行中连发两条，轮次结束后依序送出
- [x] 6.4 打断按钮（running 时可见）；验证：打断后转录停止增长、未决权限显示已拒绝

## 7. 权限卡片

- [x] 7.1 内联权限卡片：工具名 + 等宽参数展示 + 允许/拒绝 + "本次会话不再询问"勾选；验证：允许/拒绝/勾选拒绝三场景符合 specs
- [x] 7.2 应答后卡片转为最终状态工具行；验证：应答后卡片消失、对应工具行状态正确

## 8. 保活与通知（phone-connectivity）

- [x] 8.1 前台服务持有 HostLink 连接，常驻通知如实展示连接状态；验证：锁屏 30 分钟后事件仍实时到达
- [x] 8.2 权限请求高优先级通知 + 点按直达对应会话；验证：后台时电脑侧触发权限，手机通知点击落到权限卡片
- [x] 8.3 轮次结束通知（后台时 phase running→idle 边沿触发）；验证：后台等待一轮跑完收到通知，前台不通知
- [x] 8.4 断线状态 UI 明示 + 电池优化豁免引导；验证：飞行模式开关后自动恢复，引导可跳过

## 9. 端到端验收与发布

- [x] 9.1 公网真机全流程演练：配对 → 新建 → 发任务 → 后台收权限通知 → 应答 → 轮次结束通知 → 断网重连；验证：全链路无人工干预恢复，`--fingerprint` 冒烟同步通过
- [x] 9.2 `flutter build apk --release` 产出可安装 APK 并真机安装验证；验证：release 包完成一次全新配对
- [x] 9.3 收尾文档：`CLAUDE.md`/`docs/ARCHITECTURE.md` 与实现一致；验证：按文档从零构建出同样行为
