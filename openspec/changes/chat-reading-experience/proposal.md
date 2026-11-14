# Proposal

## Why

聊天页目前以纯文本渲染助手回复、以通用 JSON 折叠行渲染一切工具调用，长回复（Markdown、代码块、diff）与长工具序列在手机上几乎不可读。聊天是本项目的核心使用场景，读的体验是当前最大的短板；对标 dsh-Go 已验证的成熟聊天 UI，先补齐"看得舒服"。

## What Changes

- 助手消息以 Markdown 渲染：代码块（语法高亮、可复制）、表格、列表、链接等；流式期间对残缺 Markdown 容错渲染（半篇代码块/表格不撕裂布局），完成后整体替换为最终渲染。
- 工具调用行按工具定制视图，替代通用 JSON 折叠：Bash（命令 + 退出状态）、Edit/Write（参数内 diff 视图）、Read/Grep/Glob（路径摘要）、TodoWrite（清单）、其他工具回退到通用折叠行；数据全部来自现有 `ToolItem.input`。
- 连续 ≥3 次同类工具调用自动收成一组折叠行，展开可见明细。
- 助手消息的 thinking 内容以可折叠形式展示（数据已在协议中流动，纯 UI 补齐）。
- 已完成轮次的过程（工具调用与中间消息）折叠为一行摘要，可展开；被打断或出错的轮次不折叠。
- 消息级复制操作：助手消息提供复制按钮，用户气泡文本可选中复制。

不改动 daemon 与 wire 协议：本 change 的全部输入来自现有 `AssistantItem`（含 `thinking`）与 `ToolItem`（含 `input`）。工具完整原始输出、附件、用量等需要协议扩展的能力属于后续独立 change（transcript-data-protocol），本 change 的渲染层按"将来有原始输出"的结构预留即可。

## Capabilities

### New Capabilities

（无——本 change 全部落在既有 phone-client 能力的需求变更上。）

### Modified Capabilities

- `phone-client`: "聊天转录渲染"需求升级为 Markdown 渲染 + 逐工具定制视图 + thinking 展示；新增"工具调用分组""回合折叠""消息复制"三个需求。

## Impact

- `app/lib/ui/chat/`：`chat_rows.dart` 重构为"条目 → 行"的纯函数推导 + 各渲染器（Markdown、逐工具视图、分组行、折叠行）；`chat_screen.dart` 组装方式随之调整。
- `app/pubspec.yaml`：新增 Markdown 渲染与代码高亮依赖。
- daemon（`daemon/src/**`）与 wire 协议：不动。
- `reference/dsh-Go`（AGPL）：仅作只读参考，借鉴 `deriveRows` 折叠推导、流式容错渲染等结构思路，代码一律重写，不拷贝。
- 测试：行推导（分组/折叠边界）、diff 计算、Markdown 流式容错为纯 Dart 单测；渲染行为加 widget 测试。
