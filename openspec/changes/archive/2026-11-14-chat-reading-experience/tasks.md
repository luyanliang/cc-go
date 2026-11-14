# Tasks

## 1. 依赖与 Markdown 渲染基础

- [x] 1.1 在 `app/pubspec.yaml` 引入 gpt_markdown 与代码高亮包，核对两个包的许可证与版本并把结论记入本 change 目录；验证 `flutter pub get` 成功且 `flutter analyze` 零告警
- [x] 1.2 实现助手消息 Markdown 渲染组件（代码块语法高亮 + 代码复制按钮、表格、列表、链接），替换 `_AssistantText` 的纯文本渲染；用 widget 测试验证代码块/表格/列表渲染与复制按钮写入剪贴板
- [x] 1.3 用户气泡改为可选中文本，助手消息增加整条复制操作；用 widget 测试验证选中复制与整条复制进入剪贴板

## 2. 流式残缺 Markdown 容错

- [x] 2.1 实现流式文本补全预处理纯函数（闭合未闭合代码围栏、修补截断表格），单测覆盖未闭合围栏、半表格、正常文本三类输入
- [x] 2.2 接入流式渲染路径：条目 `status=streaming` 时渲染补全后文本，`status=done` 时以原始全文整体替换；用 widget 测试模拟增量到完成的整个流式过程，断言最终文本为原始全文

## 3. 行推导层与工具分组

- [x] 3.1 实现 derive 纯函数：条目列表 → 行列表（用户/助手/工具/notice/权限卡/排队气泡），行主键派生自条目 id；单测验证幂等（同输入两次推导一致）与主键稳定
- [x] 3.2 在 derive 层实现连续 ≥3 次工具调用成组（组键为组首条目 id），少于 3 次不成组；单测覆盖 2/3/4 次调用与被其他条目打断的序列边界
- [x] 3.3 `TranscriptListView` 改为渲染 derive 出的行列表，快照+实时合并、权限卡内联等现有行为保持；验证既有转录相关测试全部通过且 `flutter analyze` 零告警

## 4. 工具定制视图

- [x] 4.1 实现行级 LCS diff 纯函数；单测覆盖空输入、全同、全改、首尾差异
- [x] 4.2 建立工具名 → 视图构建器注册表，未命中回退通用折叠行；单测验证未知工具名走回退
- [x] 4.3 实现 Bash（命令+状态+摘要）、Edit/Write（参数 diff 视图）、Read/Grep/Glob（路径/模式摘要）、TodoWrite（清单）视图；各视图配 widget 测试验证关键内容呈现

## 5. thinking 展示

- [x] 5.1 助手条目非空 thinking 以可折叠区域展示，默认收起；widget 测试验证有/无 thinking 的渲染差异与展开交互

## 6. 回合折叠

- [x] 6.1 实现回合边界与折叠资格判定纯函数（从严规则：轮内无 error 级 notice、无 denied 条目、末条助手 `status=done` 才折叠，歧义不折叠）；单测覆盖正常轮、打断轮、出错轮、运行中插话切分
- [x] 6.2 在 derive 层接入回合折叠并实现折叠摘要行（可展开还原全部过程条目，最终回答留在折叠行外）；widget 测试验证展开/收起与最终回答位置

## 7. 集成与验收

- [x] 7.1 全量检查通过：`flutter analyze` 零告警、`flutter test` 全绿、`bash scripts/check.sh` 成功
- [x] 7.2 按 `docs/VERIFICATION.md` 真机验收：用真实 Claude 会话验证 Markdown/代码块渲染、逐工具视图、分组、折叠、复制与 thinking 展示
