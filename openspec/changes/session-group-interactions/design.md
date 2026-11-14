# Design

## Context

`_GroupHeader`（`session_list_screen.dart`）是纯展示 ListTile，无手势；分组数据来自 `groupSessionsByProject` 纯函数；daemon 侧项目注册表只有 register/list，注销只能靠重启（`--project` 参数重启后重新注册）。见 proposal.md。

## Goals / Non-Goals

**Goals:**
- 分组行点击折叠/展开（纯 UI 状态，不进 provider）
- 空未注册分组隐藏（数据层纯函数规则，单测覆盖）
- `projects.unregister` RPC + 长按注销确认流

**Non-Goals:**
- 不做项目注册的手机端入口（register RPC 已有，UI 入口留待后续）
- 注销不持久化排除名单：`--project` 注册的项目重启后会重新出现（daemon 启动参数语义不变，文档说明即可）
- 不改既有分组归并的其余规则

## Decisions

### D1：折叠状态放 UI 本地，不进 provider
折叠是纯视觉偏好，`StatefulWidget` 局部 `Set<String>`（组键 = 路径或兜底名）即可；跨会话记忆无需求。
- 备选：provider 持久化到 storage——为"列表折叠状态"引入持久化过度设计，弃。

### D2：注销用新 RPC `projects.unregister`，幂等
`ProjectsUnregisterParams = { path }`，server 端 `store.removeProject(canonicalize(path))`，重复注销不报错（返回 `{removed: boolean}`）。仅影响运行时注册表。
- 备选：复用 register 传 `register: false`——一个方法两个语义，弃。

### D3：隐藏规则放数据层纯函数
`groupSessionsByProject` 输出过滤"未注册且无会话"的组（和折叠解耦，纯函数可单测）；已注册空组保留（时钟图标是唯一的历史导入入口）。

## Risks / Trade-offs

- [注销后 daemon 重启项目"复活"] → 启动参数语义即如此；长按对话框文案说明"重启后若以 --project 启动会重新注册"
- [折叠状态在列表刷新后丢失] → 组键稳定（路径/兜底名），刷新重建 widget 时局部 state 保留（screen 不重建）；可接受

## Migration Plan

纯增量，无迁移。回滚 = 回退版本。

## Open Questions

（无）
