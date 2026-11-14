# Design

## Context

聊天页现状（见 proposal.md - Why）：`chat_rows.dart` 直接按 `TranscriptItem.kind` 四分支渲染，助手是纯 `SelectableText`，工具是通用 `ExpansionTile`（JSON input + 400 字摘要）。协议语义是"条目按 id 整体替换、快照与实时幂等合并"，本 change 全部在 app 端完成，daemon 与 wire 协议不动。输入数据：`AssistantItem {text, thinking, status}`、`ToolItem {name, input, status, summary}`。

## Goals / Non-Goals

**Goals:**

- 手机上读 Claude Code 输出舒服：Markdown、代码块、逐工具视图、成组、折叠。
- 渲染层结构化：条目 → 行的推导是纯函数、可单测，与 widget 解耦。
- 为后续 change（工具原始输出等协议扩展）预留取数边界：视图只从 `input`/`summary` 取数，将来加字段不动推导层。

**Non-Goals:**

- daemon / wire 协议任何改动（附件、原始输出、ANSI、用量、模型列表属后续 change）。
- l10n、主题体系、语音、斜杠面板。
- 字符级 diff 对齐（只做行级）。

## Decisions

### D1 渲染栈：gpt_markdown + 独立代码高亮包

选 `gpt_markdown`（为 LLM 输出设计，容错好、维护活跃）+ `re_highlight`（highlight.js 语法定义集）做代码高亮，二者均为宽松许可证（引入任务中复核版本与许可）。
备选 `flutter_markdown`：面向完整文档 Markdown，对模型输出的残缺/混合内容容错弱，且高亮需要自行拼装。不拷贝 dsh-Go 代码（AGPL），仅第三方 pub 包各自的独立许可。

### D2 行推导纯函数（借鉴 dsh-Go `deriveRows` 的结构思路，重写实现）

`chat_rows.dart` 拆为两层：

```
List<TranscriptItem> --derive(items, phase, queued)--> List<ChatRow>
ChatRow = UserRow | AssistantRow | ToolRow | ToolGroupRow | TurnFoldRow
        | NoticeRow | PermissionRow | QueuedRow          （纯 Dart，单测覆盖）
List<ChatRow> --ListView.builder + 各行 widget--> 界面
```

- 分组（连续 ≥3 次工具调用）与回合折叠都在 derive 层完成，widget 层无状态推导。
- 行主键来自条目 id：整体替换语义天然幂等，分组/折叠行的键由组内首条 id 派生（如 `g<firstId>`、`tp<firstId>`），条目更新不闪跳。

### D3 流式残缺 Markdown 容错：轻量补全预处理

流式期间渲染前对文本做预处理：统计未闭合代码围栏补 ` ``` `、截断的表格行补齐列结构；条目完成后丢弃补全、以原始全文整体替换。自研约百行纯函数（可单测），不依赖渲染器自身容错。
备选：直接让 gpt_markdown 硬吃残缺文本——表格与围栏在部分场景撕裂布局，不可控。

### D4 回合边界与折叠资格：从严判定

- 回合边界：用户条目（或会话起点/恢复点）→ 下一个用户条目或 phase 回到 idle。
- 折叠仅当"明确正常完成"：轮内无 error 级 notice、无 status 为 `error`/`denied`/`running`/`awaiting-permission` 的工具条目（打断留下 denied 与中断痕迹；出错的调用即便后来恢复也要保持可见——spec"被打断或出错的轮次 MUST NOT 折叠"）、最后一个助手条目 `status == 'done'` 且是段的最后一条条目、有非空正文。
- 任何歧义（流式中断的草稿、无回答、未知状态）一律不折叠——安全默认，满足"被打断或出错的轮次 MUST NOT 折叠"。

### D5 Edit/Write diff 端上计算

`input` 里的 `old_string`/`new_string`/`content` 足够渲染行级 diff（LCS，输入规模小，手机可承受）：仅行级 +/- 着色，不做字符级对齐。Read/Grep/Glob 提取 `file_path`/`pattern` 做路径摘要行；TodoWrite 渲染清单；Bash 展示 `command` + 状态 + summary 摘要。

### D6 工具视图注册表

按工具名 → 视图构建器的映射表；未命中回退现有通用折叠行。各视图只从 `input`/`summary` 取数——Change B 引入原始 result 字段时只改各视图的取数处，derive 层与注册表不动。

## Risks / Trade-offs

- [长转录 Markdown 渲染性能] → ListView.builder 惰性构建；仅流式条目高频重绘；若实测卡顿，加"已完成条目的渲染结果缓存"（借鉴 dsh-Go 行缓存思路，自研实现）。
- [gpt_markdown 中文/代码混合边角问题] → 引入后用真实历史转录做回归验证（项目历史回放是现成的测试语料）。
- [回合折叠在运行中插话等边角出错] → 折叠资格从严（D4）+ 折叠作为最后一个任务组实现，可独立摘除（去掉 derive 的折叠分支即回退），不影响前序成果。
- [新依赖许可证或维护风险] → 任务中含许可证复核；两个包职责单一，替换成本集中在行渲染 widget。

## Migration Plan

纯 app 端变更：升级 APK 即生效，卸载装回旧版即回退；daemon 与已配对设备无需任何配合。

## Open Questions

- 代码高亮的亮/暗主题跟随系统还是跟随应用内主题（实现时定，不影响结构）。
- 折叠摘要行的具体样式与文案（实现时定）。
