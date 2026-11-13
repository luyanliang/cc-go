# cc-go

cc-go 让 Android 手机通过电脑端 daemon 连接 Claude Code 会话，查看转录、发送任务和处理工具权限。当前是个人侧载的开发版本；功能范围与未完成验收见 [OpenSpec 任务](openspec/changes/phone-app-mvp/tasks.md)。

## 环境与安装

- Node.js 22（见 `.node-version`）
- Flutter 3.50.0 / Dart 3.14（见 `.fvmrc`）
- Android SDK、JDK 17；真机运行需 `adb devices` 能看到设备
- daemon 运行时需已安装并登录的 `claude` CLI
- 开发检查需 OpenSpec CLI 1.13.1

```bash
cd daemon && npm ci
cd ../app && flutter pub get
cd ..
bash scripts/check.sh
```

首次检查可直接执行 `bash scripts/check.sh --setup`，由脚本安装锁文件中的依赖后运行 daemon 类型检查、测试与构建、Flutter 分析与测试、OpenSpec 严格校验。CI 运行同一命令。项目不要求每次提交都构建 APK；发布前需另行构建并按 [真机验收步骤](docs/VERIFICATION.md)检查。

若所在网络无法直接下载 Flutter 包，可在首次安装时设置镜像：`PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn bash scripts/check.sh --setup`。CI 使用默认源。

## 本地运行

```bash
cd daemon
node bin/cc-go.mjs --code 654321
```

另开终端：

```bash
cd app
flutter run
```

默认使用自签证书的 HTTPS/WSS；首次配对请核对 daemon 输出的证书指纹。`--no-tls` 只用于本机回环调试。运行参数、冒烟客户端及协议说明见 [开发约定](CLAUDE.md)和[架构文档](docs/ARCHITECTURE.md)。

## 开发与验收约定

按一个可验证的行为拆分改动。提交前运行 `bash scripts/check.sh`；涉及连接、通知和 Android 生命周期的改动，还须按 [真机验收步骤](docs/VERIFICATION.md)记录设备、版本、步骤与结果。OpenSpec 任务只有在任务所列行为及验证都完成后才勾选。自动测试通过不代替真机验收。
