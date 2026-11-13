# Android App

本目录是 cc-go 的 Flutter 手机端。环境准备、检查命令和运行方式见[项目 README](../README.md)。手机端当前覆盖配对、会话列表、聊天、权限应答，以及保活和通知的实现；后台与公网行为的验收状态以 [OpenSpec 任务](../openspec/changes/phone-app-mvp/tasks.md)为准。

单独检查手机端：

```bash
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

真机安装及后台验收步骤见[验证文档](../docs/VERIFICATION.md)。
