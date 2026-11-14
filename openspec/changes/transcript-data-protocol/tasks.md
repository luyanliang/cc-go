# Tasks

## 1. 协议与 daemon 基础

- [x] 1.1 `protocol.ts`：`UserItem.attachments`、`ToolItem.resultText/resultTruncated/resultImages`、`SessionSummary.usage` 及新 RPC（`host.models`、`session.commands`）的 schema 与类型；`npm run typecheck` 通过
- [x] 1.2 `agent/session.ts`：init 消息捕获（model、slash_commands、terminal_slash_commands）与 result 消息的 usage/total_cost_usd 提取，进 summary 与 manager 缓存；单测覆盖捕获与降级（旧 CLI 无字段）
- [x] 1.3 `history.ts`：工具原始输出提取（extractToolResult，与实时同源）与 user 消息 image block 还原为附件，接入回放/导入路径；既有回放测试全绿 + 新增回放填充测试

## 2. 附件链路

- [x] 2.1 daemon：`session.prompt` 组装 image block（文本 + 图片块同条 user 消息），echo-guard 兼容带附件消息；边界测试覆盖带附件入模与运行中排队
- [x] 2.2 app 依赖：引入 `image_picker` 与 `image`，核对许可证并记入 change 目录；`flutter pub get` + `flutter analyze` 零告警
- [x] 2.3 app：选图、缩放压缩（长边/质量迭代）、预览条与移除、随消息发送；widget 测试覆盖预览/移除/发送参数（mock picker）
- [x] 2.4 app：用户气泡附件缩略图回显与点开全屏查看（含快照路径）；widget 测试覆盖回显与旧数据无附件不报错

## 3. 工具原始输出与用量展示

- [x] 3.1 app：传输模型与转录合并兼容新字段（resultText/resultImages/usage），旧数据回退；transcript 单测覆盖新旧字段合并幂等
- [x] 3.2 app：Bash 视图升级完整输出 + 自研 ANSI SGR 着色纯函数（畸形序列容错）；ANSI 解析单测 + Bash 视图 widget 测试（多行输出、截断标记、旧数据回退摘要）
- [x] 3.3 app：Read/Grep 完整内容渲染 resultText（Read 结果自带 cat -n 行号、原样呈现不自造 gutter —— 评审修正，初版误加了第二层行号）；widget 测试验证行号不重复、截断标记与旧数据回退
- [x] 3.4 app：结果图片展示与放大查看；widget 测试（有图/无图/超量裁剪）
- [x] 3.5 daemon+app：usage 随 summary 下发，聊天页头部成本/上下文 chip（null 不渲染）；widget 测试覆盖更新刷新与无数据隐藏

## 4. 模型与指令目录

- [x] 4.1 daemon：`host.models` RPC（init 缓存 → live session supportedModels → 短命 probe 降级链）；单测覆盖三级降级
- [x] 4.2 daemon：`session.commands` RPC（init 捕获 + terminal 过滤 + supportedCommands 描述尽力而为）；单测覆盖过滤与空目录
- [x] 4.3 app：头部模型 chip + 选择面板（列表/自由输入回退），经 `session.configure` 生效并回显；widget 测试覆盖选择、回退、切换后摘要回显
- [x] 4.4 app：composer 斜杠面板（`/` 前缀触发、过滤、补全、发送不变、空目录不弹）；widget 测试覆盖触发/过滤/补全/降级

## 5. 7.10 重构（multi-project-history 捎带）

- [x] 5.1 抽取 `LinkScopedListNotifier` 共享基类，`ProjectsNotifier`/`SessionsNotifier` 迁移，行为不变；既有 projects/sessions/widget 测试全绿为准

## 6. 集成与验收

- [x] 6.1 全量检查：`bash scripts/check.sh` 成功（daemon typecheck/test/build + flutter analyze/test + openspec strict）
- [ ] 6.2 真机验收（按 `docs/VERIFICATION.md` 记录）：发图给 Claude（拍照/相册各一）、长输出工具完整显示与 ANSI 着色、成本/用量随轮次刷新、模型切换生效、`/compact` 面板补全与发送、旧会话回放回退正常
