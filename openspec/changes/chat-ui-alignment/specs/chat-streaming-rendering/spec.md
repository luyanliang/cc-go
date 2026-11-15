# Spec Delta

## Purpose

流式渲染体验升级：文字匀速吐出、流式光标、更强的残缺 Markdown 容错、LaTeX 公式与 mermaid 图渲染、列表 gutter 对齐，使流式过程稳定不跳版、正文表达力对齐成熟客户端。

## ADDED Requirements

### Requirement: 流式匀速吐出

成块到达的流式文字 SHALL 按平滑速率渲染（pacer）：落后时加速追赶但 MUST 设积压上限防止无限延迟；回合完成时 MUST 以服务端最终全文整体替换，不留 pacer 残余偏差。现有的残缺 Markdown 容错与整体替换语义 MUST 保持。

#### Scenario: 大块增量不闪跳
- **WHEN** SDK 一次性推送一大段增量文本
- **THEN** 屏幕上文字按平滑速率逐步出现，而非整块闪现

#### Scenario: 完成时对齐最终全文
- **WHEN** 回合完成、最终 assistant 消息整体替换流式草稿
- **THEN** 渲染内容与最终全文一致，无残留半截句子

### Requirement: 流式光标

流式期间助手正文末尾 SHALL 显示流式光标指示；回合结束后光标 MUST 消失。光标 MUST NOT 破坏 Markdown 解析（包括流式修复后的结构）。

#### Scenario: 光标出现与消失
- **WHEN** 助手回复开始流式输出并在结束后
- **THEN** 输出期间正文末尾有光标，完成后光标消失

### Requirement: 残缺 Markdown 修复扩展

流式期间的容错渲染 SHALL 覆盖：未闭合代码围栏（已有）、截断表格行（已有）、未闭合粗体/斜体标记、半截链接与未闭合标题——均按"将要变成的样子"渲染或暂扣，闭合符到达时 MUST NOT 发生可见的跳版重排。修复 MUST 幂等且不影响完成后的最终渲染。

#### Scenario: 半截粗体不闪跳
- **WHEN** 流式文本停在 `**部分加粗`（闭合符未到）
- **THEN** 已有部分按加粗预览渲染，`**` 闭合后无跳版

#### Scenario: 半截表格逐行呈现
- **WHEN** 表格行逐段到达
- **THEN** 每行到达即按表格行渲染，最终与完整表格一致

### Requirement: LaTeX 公式渲染

助手 Markdown 中的行内公式 `$…$` 与展示公式 `$$…$$` SHALL 渲染为公式；判定规则 MUST 遵循通行约定（价格语境如"$5 和 $10"不判定为公式），流式期间未闭合的展示公式 SHALL 以占位形式呈现避免半截解析。

#### Scenario: 展示公式渲染
- **WHEN** 助手消息包含 `$$E=mc^2$$`
- **THEN** 渲染为公式而非纯文本

#### Scenario: 价格不误判
- **WHEN** 助手消息包含"套餐价格 $5 和 $10"
- **THEN** 文本原样显示，不渲染为公式

### Requirement: mermaid 块渲染

回复中的 ```` ```mermaid ```` 代码块 SHALL 默认显示源码（可复制），并提供全屏渲染视图（WebView 加载渲染引擎）；渲染引擎不可达时 SHALL 显示可复制的源码与可理解的错误提示，MUST NOT 令消息渲染失败。

#### Scenario: mermaid 全屏渲染
- **WHEN** 用户点击一条含 mermaid 块的渲染入口
- **THEN** 全屏显示渲染后的图，返回后消息仍显示源码

#### Scenario: 渲染引擎不可达降级
- **WHEN** 设备无法加载渲染引擎（如无网络）
- **THEN** 显示错误提示与可复制的源码，消息其余部分渲染不受影响

### Requirement: 列表 marker 对齐

Markdown 有序列表与嵌套列表 SHALL 按 marker gutter 对齐渲染：嵌套子列表的 marker 与父级文字列对齐，编号列宽度随位数自适应加宽，不与正文文字挤压错位。

#### Scenario: 多级嵌套列表对齐
- **WHEN** 助手消息包含三级嵌套有序列表
- **THEN** 每级 marker 与上一级文字列左缘对齐，编号不挤压正文
