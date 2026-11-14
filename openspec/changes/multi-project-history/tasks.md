# Tasks

## 1. 协议与存储基础

- [x] 1.1 `store.ts` 增加项目注册表：`projects: string[]` 持久化（读入旧 store.json 时缺省为空数组）、注册/注销/查询 API，路径一律 `path.resolve` 规范化后存取；`npm test` 含注册表单测（持久化往返、去重、空缺省）
- [x] 1.2 `protocol.ts` 新增 schema：`projects.list` / `projects.register` / `sessions.discover` / `session.history`（含分页 cursor）/ `session.import` 的 params 与 result，`SessionSummary` 增加可选 `origin` 字段；`npm run typecheck` 通过
- [x] 1.3 `bin/cc-go.mjs` 支持 `--project <dir>`（可重复）注册目录；注册表为空时把启动目录注册为默认项目。验证：以 `--project` 启动后检查 `~/.cc-go/store.json` 的 projects 内容

## 2. JSONL 映射器与发现（daemon 新模块 `src/history.ts`）

- [x] 2.1 JSONL→`Item` 映射器：行类型处理（user 字符串→UserItem、assistant text→AssistantItem、tool_use/tool_result 按 `tool_use_id` 配对→ToolItem）、内部行黑名单（`file-history-snapshot` 等）、`isMeta`/`isCompactSummary`/`isSidechain`/thinking 跳过、条目 id 规则 `hist-<claudeSessionId>-<uuid>`；用仓库内固定样本 JSONL 做单测夹具，`npm test` 通过
- [x] 2.2 会话发现：cwd→编码目录名换算、readdir 枚举 `.jsonl`、每文件提取会话 id/mtime/首条用户消息标题/消息数、按 mtime 倒序、标注已托管（对照 store 会话的 claudeSessionId）；单测覆盖编码换算与标题回退
- [x] 2.3 历史回放分页：流式逐行解析、从新到旧分页（cursor=行号）、文件缺失/不可解析返回结构化错误；单测覆盖分页边界与坏文件

## 3. daemon 方法接线（`server.ts` + `agent/manager.ts`）

- [x] 3.1 `projects.list` / `projects.register` handler：枚举含失效目录标记；注册路径 `realpath` 归一后精确匹配校验（拒绝 `..`/符号链接绕过）；未认证请求与未注册目录操作被拒（单测 + `sessions.discover` 对未注册目录返回错误的用例）
- [x] 3.2 `sessions.discover` / `session.history` handler 接入 history 模块，`safeParse` 验参沿用现行约定；单测或冒烟验证两个方法端到端返回
- [x] 3.3 `session.import`：幂等（同 claudeSessionId 返回既有会话）、创建会话并预填充回放条目、首个 query 带 `resume`、原 JSONL 文件字节不变（单测前后 hash 断言）

## 4. 手机端：项目分组与历史

- [x] 4.1 `lib/transport` + `lib/state`：projects / discover / history / import 的方法封装与 provider（纯 Dart、headless 可测）；单测覆盖方法调用与分组归并逻辑
- [x] 4.2 会话列表按项目分组：分组标题（项目显示名）、空分组提示、失效目录分组标记、来源标识（创建/导入）；`flutter analyze` 零警告 + widget 测试覆盖分组渲染
- [x] 4.3 新建会话目录选择：单项目直建、多项目先选目录；widget 测试覆盖两条路径
- [x] 4.4 历史列表页（某项目的会话历史）与只读聊天页（回放条目渲染、composer 禁用、接管入口，接管后转入正常聊天）；widget 测试覆盖只读态与接管动作

## 5. 端到端验收

- [x] 5.1 端到端脚本（放 `daemon/tool/`）：临时目录注册 → 用 claude CLI 造一个终端会话 → discover 可见 → history 回放条目正确 → import 接管 → 经协议发消息获得基于原上下文的回复；脚本可重复执行
- [x] 5.2 真机验收（用户参与）：多项目分组可见、终端历史可浏览、接管后续聊成功、daemon 重启后导入会话历史仍在

## 6. 可选尾段：已接管会话的外部写入同步（design D6，不阻塞 1–5 验收）

- [x] 6.1 tail 器：3s stat 增量读、仅处理完整行、行 uuid 去重、`trackClaudeSession` 换文件跟随；单测用追加写 fixture 验证增量并入
- [x] 6.2 防回显：内容+时间窗环形缓冲去重手机自发消息的落盘回显（与现有 echo-guard 思想一致）；单测覆盖回显抑制
- [x] 6.3 端到端：脚本模拟终端侧 `claude --resume` 追加消息，断言手机协议流在轮询间隔内收到新条目且无重复

## 7. 评审修复（code-review 2026-11-14）

- [x] 7.1 tail fork 跟随加血缘校验：仅当新转录文件含已知 uuid 才切换，防止同项目无关终端会话劫持会话身份（session.ts + history.ts `transcriptSharesLineage`；原有 fork 跟随单测覆盖正向路径）
- [x] 7.2 导入幂等跨 fork：`SessionSummary.originClaudeSessionId` 稳定记录导入源，幂等判定与发现 managed 映射同时匹配两个 id（manager.ts / server.ts / protocol.ts；新增 fork 后重复导入回归测试）
- [x] 7.3 `session.create` 空 cwd 回退改为"首个已注册且存在的项目"（原回退 daemon 进程目录可能未注册；server 集成测试覆盖）
- [x] 7.4 tail 偏移随 claudeSessionId 变更重置：SDK resume fork 与终端 fork 统一走"新文件从头重读 + uuid 去重"路径
- [x] 7.5 tail 改增量读（openSync/readSync 从 offset 读，不再每 3s 全量 readFileSync）；`parseTranscriptItems` 按 (mtime,size) 缓存（上限 32 文件），回放翻页与重复发现不再整文件重解析
- [x] 7.6 外部写入合并后按批触发 onSummary（持久化 updatedAt + sessions.changed 广播，不再仅内存 touch）
- [x] 7.7 合并重复的工具结果摘要器（session.ts 复用 history.ts `summarizeToolContent`，仅 max 参数差异）
- [x] 7.8 `--project` 校验 isDirectory（拒绝把普通文件注册为项目）
- [x] 7.9 e2e 脚本退出时从真实 ~/.cc-go/store.json 移除临时项目与 'e2e' 设备条目（可重复运行零残留，已实测验证）
- [ ] 7.10 app 侧 `ProjectsNotifier` 与 `SessionsNotifier` 连接管道重复，抽取共享基类（重构类，不影响行为，随下个 app 变更一并做）
