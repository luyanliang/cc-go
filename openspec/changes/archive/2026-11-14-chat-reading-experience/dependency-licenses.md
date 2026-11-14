# 依赖许可证核对（task 1.1）

引入的两个直接依赖（实际解析版本，来源 `flutter pub add` 解析结果 + `~/.pub-cache/hosted/pub.flutter-io.cn/<pkg>/LICENSE` 原文核对，2026-11-14）：

| 包 | 解析版本 | 许可证 | 备注 |
|---|---|---|---|
| gpt_markdown | 1.3.4 | BSD 3-Clause（Plusfinity AI, Inc. 及贡献者） | 1.4.1 与现有依赖约束不兼容，解析落在 1.3.4 |
| re_highlight | 0.0.3 | MIT（Reqable） | highlight.js 语法定义的 Dart 移植 |
| url_launcher | 6.3.3 | BSD 3-Clause（Flutter Authors） | 聊天内链接经系统浏览器打开（评审修复引入） |

随之带入的传递依赖（均 BSD 3-Clause，Plusfinity AI, Inc.）：val_highlight 0.1.1、val_highlight_flutter 0.1.2、val_latex 0.1.4、val_latex_flutter 0.1.4。

结论：全部为宽松许可证（BSD/MIT），与本项目兼容；不涉及 dsh-Go 的 AGPL 代码。
