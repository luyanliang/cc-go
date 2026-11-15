# Proposal

## Why

聊天窗口目前是"能用"的 M3 默认形态：贴底跟随靠启发式（历史加载会跳动）、行形态是清一色 ExpansionTile、几乎没有视觉体系与消息级交互。对照参考实现 dsh-Go（只读参考，AGPL——只借鉴结构思路，不拷贝代码）做了一次完整盘点，差距集中在三件事：居中锚定的滚动结构、共享视觉层（雾蓝玻璃体系）、消息行形态与交互密度。`transcript-data-protocol` 已把数据地基（附件/工具原始输出/用量/模型目录/斜杠目录）铺完，现在是做界面精修的时机——ARCHITECTURE.md 里程碑也把"聊天 UI 精修、对齐 dsh-Go 视觉"列为后续项。

## What Changes

范围 = 全部**同域差距**（dsh-Go 也是聊天客户端、纯 App 侧可落地、不需要 daemon 新增协议的部分）+ 视觉层整体对齐雾蓝玻璃体系。不包含依赖后端新能力的部分（见 Impact 末尾）。

- **视觉体系**：建立 app 级主题 token 层——OKLCH 手工调色（不用 `ColorScheme.fromSeed`）、玻璃表面分级（chrome/sheet/card）、连续曲率（squircle）圆角、三档动效 token（反馈 ≤160ms / 结构 240–340ms / 环境 ≥2s）、共享视觉件（玻璃胶囊、胶囊 chip、状态点、工具类别图形映射等）；落地范围为本 change 的聊天窗口。
- **聊天页骨架**：顶栏从标准 AppBar 改为浮动玻璃胶囊组（会话键 + 标题胶囊 + 模型胶囊 + 新对话键）并实现空间不够时的逐级让出（宽度协商）；状态行"一句人话"（生成中/已就绪/等权限）；消息内容滚动到玻璃 chrome 之下（scrim 随滚动渐隐）；空态升级（时段问候 + 建议卡片）。
- **居中锚定滚动**：列表改为视口分 before/after 两段的居中锚定结构——历史向上增长、流式向下增长都不移动用户正在看的内容；贴底时同一次布局内跟随；提供"回到底部"浮动键。
- **消息行形态**：过程行（思考/工具/通知）统一为"左图形列 + 文字列"的两列解剖；工具行改为 32dp 单行 + 点开下方长出详情，长输出只排头尾、全文进独立页；思考过程收成思考 pill（流式时跟随最新字符）；权限卡片按审批卡形态重绘（醒目但不靠大红）并增加输入条上方的权限/自动允许状态胶囊；notice 行升级（出错图形 + 详情展开）；回合末增加脚注行（时长 · 步数 · tokens · 成本，点开本轮摘要）；运行中在输入条上方显示活动胶囊（此刻在做什么 + 走秒）；只读回放会话用只读条替代输入条。
- **消息级交互**：长按消息弹出菜单（复制/选择文字/引用）；输入条上方引用胶囊（引用追问，引文随消息以 blockquote 发出）；排队消息可撤回、可编辑后重发；回合末助手消息下方安静操作行（复制/分享/引用）；用户消息中的疑似密钥/令牌屏显遮罩（只改显示，复制/发送仍是原文）；图片消息长按保存到相册/分享。
- **流式渲染升级**：成块到达的文字按平滑速率匀速吐出（pacer）；流式光标；stream repair 扩展到未闭合粗体/链接/标题；LaTeX 公式渲染（`$…$`/`$$…$$`，遵循 remark-math 判定，价格不当公式）；```mermaid 块源码可复制 + 点开 WebView 渲染；Markdown 列表 marker gutter 对齐。
- **输入区**：发送键在草稿为空时形态切换（语音入口，系统识别引擎）；听写状态（识别结果 + 音量条 + 停止键）；输入草稿按会话持久化（切走再回来不丢）；斜杠面板补中文说明文案与"发送会选中"提示。

## Capabilities

### New Capabilities

- `chat-visual-system`: 聊天窗口视觉体系——主题 token 层（OKLCH 调色、玻璃表面分级、squircle、动效 token、共享视觉件）与聊天页 chrome（玻璃胶囊顶栏 + 宽度协商、状态行、内容滚到玻璃下、空态）。
- `chat-list-scroll`: 转录列表的居中锚定滚动——锚定不跳动、贴底跟随、回到底部键。
- `chat-transcript-rows`: 转录行形态升级——过程行两列解剖、工具行单行化与全文页、思考 pill、审批卡与权限胶囊、notice、回合脚注、活动胶囊、只读条。
- `chat-message-interactions`: 消息级交互——长按菜单、引用追问、排队消息撤回/编辑重发、回合末操作行、密钥屏显遮罩、图片保存/分享。
- `chat-streaming-rendering`: 流式渲染——pacer、流式光标、stream repair 扩展、LaTeX、mermaid、列表 gutter。
- `chat-composer`: 输入区升级——语音听写、草稿持久化、斜杠面板增强。

### Modified Capabilities

（无——`phone-client` 既有需求（四类条目渲染、Markdown、可折叠 thinking、工具定制视图、排队/打断/权限应答、复制能力）全部继续成立；本 change 是形态与交互的增强，不动协议与既有行为边界。）

## Impact

- **app 为主**，daemon 零改动（这正是"同域差距"的定义）：
  - `lib/theme/`（新增：palette/glass/squircle/typography/motion 与共享视觉件）。
  - `lib/ui/chat/`：`chat_screen.dart`（骨架重排、自定义布局）、`chat_rows.dart`（居中锚定、行装配）、`composer.dart`（语音/草稿/引用胶囊）、`tool_views.dart`（单行化 + 全文页）、新增长按菜单/脚注/审批卡/活动胶囊等行组件。
  - `lib/state/`：`chat_controller`（草稿持久化、排队消息撤回/编辑、引用上下文）、`transcript`（行推导扩展：脚注、活动状态）。
  - 新依赖：`webview_flutter`（mermaid）、`speech_to_text`（系统语音识别，Android）；LaTeX 用 gpt_markdown 自带引擎，无需新依赖。
- **依赖在途 change**：`transcript-data-protocol`（18/19）的附件、工具原始输出、用量、模型目录、斜杠目录是本 change 的输入；本 change 不改 wire 协议。
- **AGPL 约束**：`reference/dsh-Go-main` 只读参考，借鉴结构与视觉规格（注释里的 ASCII 线框图），不拷贝代码；所有文案入 l10n 或与项目现有做法一致。
- **明确不做（依赖 daemon 新能力，留给后续 change）**：待办/目标 dock 条、提问卡（AskUserQuestion 场景）、上下文窗口分项、定时任务时钟键、余额、媒体生成、dsh_ui 交互回复、@提及面板（需工作区文件列表）、`![](本地图片)` 渲染（需 daemon 文件端点）、文件附件、"重新回答/分支"（需 daemon 分叉语义）、**撤销本会话免问**（allowlist 在 daemon 侧，需撤销协议——自动允许胶囊仅做状态展示）。
