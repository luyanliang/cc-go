# Proposal

## Why

会话列表的项目分组行（`_GroupHeader`）渲染成可点击的 ListTile 样式却没有绑定任何点击事件，用户预期落空；同时未注册目录的空分组长期占据列表，且注销项目只能改 daemon 启动参数，手机端无入口。

## What Changes

- 点分组行 = 折叠/展开该组（组头右侧加展开状态箭头）。
- 未注册目录且组内无会话的分组自动隐藏（已注册项目即便无会话仍显示——历史导入入口有用）。
- 长按已注册项目的分组行 → 确认对话框 → 调用新增的 `projects.unregister` RPC 注销该项目（运行时注册表；`--project` 启动参数的项目重启后仍会重新注册）。注销后：该目录不能再新建/发现会话；组内既有会话保留为未注册兜底组。
- （说明：原方向"点分组行打开历史页"与折叠点击冲突，历史入口保留为分组行右侧时钟图标，语义不重复。）

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `phone-client`: 新增 ADDED Requirement「项目分组交互」——分组行点击折叠/展开、空未注册分组隐藏、长按注销项目。

## Impact

- **daemon**：`protocol.ts` 新增 `ProjectsUnregisterParams`；`server.ts` 新增 `projects.unregister` handler（幂等，`store.removeProject`）；单测覆盖注销后 `projects.list` 不再包含、组内会话转为未注册兜底。
- **app**：`history_api.dart` 加 `unregisterProject`；`session_list_screen.dart` 分组行点击折叠/长按注销、空未注册分组隐藏；`project_models.dart` 纯函数增加隐藏规则及单测。
- 风险小：纯交互增量，不改既有协议字段；`projects.unregister` 为新方法，旧 App 不调用不受影响。
